# infra/platform — Portable Platform Layer

This Terraform config is the **cloud-agnostic control plane** for idea-board. Given
a reachable Kubernetes cluster (from `infra/stacks/aws` or `infra/stacks/gcp`), it
installs everything the app needs and then the app itself:

1. **ingress-nginx** — LoadBalancer + the `nginx` IngressClass.
2. **cert-manager** (+ CRDs) and a **`letsencrypt` ClusterIssuer** (HTTP-01 over nginx).
3. **external-secrets-operator** (+ CRDs) and the **`cloud-secrets` ClusterSecretStore**.
4. The **idea-board Helm chart** (`../../charts/idea-board`), rendered with
   `-f values.yaml -f values-<cloud>.yaml`.

> **This layer is byte-for-byte identical on both clouds** except for exactly one
> thing: the `provider` block inside the `cloud-secrets` ClusterSecretStore (and the
> single ESO ServiceAccount annotation that authorizes it). Both are keyed off the
> `cloud` variable. See the leaky-abstraction note below for the honest caveat.

## How it authenticates to the cluster

`providers.tf` configures the `helm`, `kubernetes`, and `kubectl` providers purely
from three input variables:

| variable       | source                                             |
| -------------- | -------------------------------------------------- |
| `kube_host`    | cluster module output `kube_host`                  |
| `kube_ca_cert` | cluster module output `kube_ca_cert` (base64)      |
| `kube_token`   | short-lived bearer token (`aws eks get-token` / `gcloud ... print-access-token`) |

No local kubeconfig is read, and **no cloud SDK or cloud credentials are used by
this layer** — that is the whole point of keeping it portable. The cluster
credentials are produced upstream by the per-cloud stack and, in CI, surfaced by
`scripts/get-kubeconfig.sh`.

`kube_ca_cert` arrives base64-encoded (matching the module contract) and is
`base64decode()`d before being handed to the providers.

## Why the `kubectl` provider for the two CRs

The `ClusterIssuer` and `ClusterSecretStore` are custom resources whose CRDs are
installed by the cert-manager / external-secrets Helm releases **in the same apply**.
`kubernetes_manifest` validates against the cluster's OpenAPI schema at *plan* time,
which fails on a fresh cluster where those CRDs don't exist yet. `kubectl_manifest`
applies at *apply* time, so combined with `depends_on` ordering it works on a
first-run bootstrap.

## Install ordering

Ordering is enforced with `depends_on`:

```
input_guard
 ├─ ingress-nginx ─────────────────────────────────────────┐
 ├─ cert-manager ──► ClusterIssuer "letsencrypt" ───────────┤
 └─ external-secrets ──► ClusterSecretStore "cloud-secrets" ─┤
                                                             └─► idea-board chart
```

The app release waits on the IngressClass + issuer (for TLS) and the
ClusterSecretStore (so its `ExternalSecret` can materialize the `idea-board-db`
Secret / `DATABASE_URL`).

## Usage

```sh
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform apply
```

In CI (`.github/workflows/deploy.yml`) this runs after the cloud stack apply:

```sh
CLOUD=aws   # or gcp
terraform -chdir=infra/platform init
terraform -chdir=infra/platform apply -auto-approve \
  -var="cloud=$CLOUD" \
  -var="kube_host=$(terraform -chdir=infra/stacks/$CLOUD output -raw kube_host)" \
  -var="kube_ca_cert=$(terraform -chdir=infra/stacks/$CLOUD output -raw kube_ca_cert)" \
  -var="kube_token=$KUBE_TOKEN" \
  -var="letsencrypt_email=$LE_EMAIL" \
  -var="ingress_host=$APP_HOST" \
  -var="backend_image_repository=ghcr.io/$OWNER/idea-board-backend" \
  -var="backend_image_tag=$TAG" \
  -var="frontend_image_repository=ghcr.io/$OWNER/idea-board-frontend" \
  -var="frontend_image_tag=$TAG"
  # + the cloud-conditional vars for the selected $CLOUD
```

## What changes per cloud (and what doesn't)

**Identical:** every provider config, every Helm release, the ClusterIssuer, the
install order, and the app chart invocation.

**Cloud-conditional (the only difference):**

| input                           | aws                          | gcp                              |
| ------------------------------- | ---------------------------- | -------------------------------- |
| `cloud`                         | `"aws"`                      | `"gcp"`                          |
| ClusterSecretStore provider     | `aws` (`service: SecretsManager`) | `gcpsm` (Secret Manager)    |
| ESO SA identity annotation      | `eks.amazonaws.com/role-arn` (IRSA) | `iam.gke.io/gcp-service-account` (Workload Identity) |
| required extra vars             | `aws_region`, `aws_eso_role_arn` | `gcp_project_id`, `gcp_location`, `gcp_cluster_name`, `gcp_eso_service_account_email` |

Both providers resolve the same logical remote key **`idea-board/db`** (where the
database module stored the DB password), so the chart's `ExternalSecret` is written
once and works everywhere.

### Adding a third cloud

1. Add the value to the `cloud` variable's `validation` list.
2. Add one `else`-branch to `local.cluster_secret_store_provider` with that cloud's
   ESO provider block (e.g. `azurekv`).
3. Add the matching ESO ServiceAccount annotation `dynamic "set"` in the
   `external_secrets` release.
4. Ship `charts/idea-board/values-<cloud>.yaml`.

Nothing else in this layer changes.

## Honest leaky-abstraction note

The abstraction is *almost* clean but not perfectly so:

- **ESO auth leaks past the ClusterSecretStore.** The provider block is the headline
  difference, but it only works because the ESO controller ServiceAccount is
  annotated with a cloud-specific identity (IRSA role ARN vs. GCP SA email). So the
  cloud-conditional surface is really *two* coupled things, not one. We keep both
  behind the single `cloud` switch, but pretending it's a one-liner would be a lie.
- **The bearer token is short-lived.** `kube_token` from `aws eks get-token` /
  `gcloud` expires (~15 min). This layer assumes it's applied promptly after the
  token is minted; for long-running or drift-detection use you'd re-mint it. A truly
  provider-native setup would use an `exec` credential plugin — deliberately avoided
  here to keep the layer free of cloud SDK dependencies.
- **LoadBalancer specifics live elsewhere.** ingress-nginx is installed with plain
  defaults; the cloud-specific LB annotations (NLB scheme, GCP LB class, etc.) are
  intentionally pushed into the app chart's `values-<cloud>.yaml` overlay, not here.
- **API versions drift.** The `ClusterSecretStore` is pinned to
  `external-secrets.io/v1beta1` to match the pinned chart version; newer ESO
  releases promote this to `v1`. Bumping `external_secrets_chart_version` may require
  updating the `apiVersion` in `main.tf`.
