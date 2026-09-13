# Adding a 3rd cloud (worked example: Azure)

This is the detailed companion to the README's [Cloud-Agnostic
Approach](../README.md#cloud-agnostic-approach) section. It walks through adding **Azure**
(AKS + Azure Database for PostgreSQL + VNet) end to end.

The headline: because of the Terraform **module contract**, adding a cloud is *additive*.
You implement three modules with the exact same input/output signatures, add one stack,
add one `case` branch to a shell script, add one Helm overlay, add one secret-store
provider block, and extend one CI enum. **Nothing in the portable plane changes** — not
the app, not the chart templates, not the AI tooling, not the module *signatures*.

The same recipe applies to any provider — substitute Azure's services with the target
cloud's managed Kubernetes, managed Postgres, VNet/VPC equivalent, and secret store.

---

## What you will NOT touch

Confirming the blast radius up front:

- `app/backend`, `app/frontend` — the app is 12-factor and cloud-unaware.
- `charts/idea-board/templates/*`, `charts/idea-board/values.yaml`, `Chart.yaml` — the
  chart is portable.
- `ai/healthcheck`, `ai/envgen`, `ai/explain` — AI tooling is cloud-agnostic.
- The Terraform module **input/output signatures** — they are the contract.
- `docker-compose.yml`, `Makefile`, `.env.example` — local dev is unaffected.

---

## Step 1 — Implement `infra/modules/azure/{network,cluster,database}`

Create three modules that honor the contract *exactly*. Mirror the existing
`infra/modules/aws/*` and `infra/modules/gcp/*` for structure.

### `infra/modules/azure/network`

```hcl
# inputs
variable "name"   { type = string }
variable "region" { type = string }   # Azure "location", but keep the contract name
variable "cidr"   { type = string }

# ... create resource_group + azurerm_virtual_network + subnets (public + private) ...

# outputs (names MUST match the contract)
output "network_id"         { value = azurerm_virtual_network.this.id }
output "subnet_ids"         { value = [for s in azurerm_subnet.public  : s.id] }
output "private_subnet_ids" { value = [for s in azurerm_subnet.private : s.id] }
```

### `infra/modules/azure/cluster`

```hcl
# inputs
variable "name"        { type = string }
variable "region"      { type = string }
variable "k8s_version" { type = string }
variable "node_size"   { type = string }  # "small" | "medium" | "large"
variable "node_count"  { type = number }
variable "network"     { type = any }      # object from the network module outputs

# t-shirt sizing: map to Azure VM sizes internally
locals {
  vm_size = {
    small  = "Standard_B2s"
    medium = "Standard_D4s_v5"
    large  = "Standard_D8s_v5"
  }[var.node_size]
}

# ... azurerm_kubernetes_cluster (AKS) with the above node pool ...

# outputs (names MUST match the contract)
output "cluster_name"  { value = azurerm_kubernetes_cluster.this.name }
output "kube_host"     { value = azurerm_kubernetes_cluster.this.kube_config.0.host }
output "kube_ca_cert"  { value = azurerm_kubernetes_cluster.this.kube_config.0.cluster_ca_certificate } # base64
output "oidc_provider" { value = azurerm_kubernetes_cluster.this.oidc_issuer_url }
output "location"      { value = var.region } # the cluster's actual location: region on AKS/EKS, ZONE on GKE
```

> **`location` is part of the contract.** `scripts/get-kubeconfig.sh` and the CI platform
> step read it to attach to the cluster. On AWS/Azure it equals the region; on GCP it is the
> **zone** (the GKE cluster is zonal — see the module comment). AKS is regional, so returning
> `var.region` here is correct.

> Enable the OIDC issuer + Workload Identity on the AKS cluster so ESO can authenticate to
> Key Vault without static credentials (the Azure analog of IRSA / GKE Workload Identity).

### `infra/modules/azure/database`

```hcl
# inputs
variable "name"           { type = string }
variable "engine_version" { type = string }
variable "size"           { type = string }  # "small" | "medium" | "large"
variable "storage_gb"     { type = number }
variable "network"        { type = any }
variable "allowed_cidrs"  { type = list(string) }

# t-shirt sizing: map to Azure Postgres SKUs internally
locals {
  sku = {
    small  = "B_Standard_B1ms"
    medium = "GP_Standard_D2s_v3"
    large  = "GP_Standard_D4s_v3"
  }[var.size]
}

# ... azurerm_postgresql_flexible_server (+ database "ideas") ...
# ... generate a random password, then store it in Azure Key Vault at secret
#     name "idea-board-db" (Key Vault forbids "/", so NOT "idea-board/db") ...

# outputs (names MUST match the contract)
output "db_host"       { value = azurerm_postgresql_flexible_server.this.fqdn }
output "db_port"       { value = 5432 }
output "db_name"       { value = "ideas" }
output "db_secret_ref" { value = azurerm_key_vault_secret.db.id }  # points at idea-board-db
```

> **Secret-name gotcha (real, learned on GCP).** Azure Key Vault secret names allow only
> `0-9A-Za-z-` — no `/` — exactly like GCP Secret Manager. So store the password at
> **`idea-board-db`** and set `externalSecret.remoteKey: idea-board-db` in `values-azure.yaml`
> (Step 4). Only AWS Secrets Manager permits the base `idea-board/db`. This is the one small,
> well-contained overlay knob each name-restricted store needs — never a chart-template edit.

---

## Step 2 — Add `infra/stacks/azure`

Mirror `infra/stacks/aws` / `infra/stacks/gcp`: declare a `cloud` variable, call the three
modules in order, and expose the same contract outputs.

```hcl
# infra/stacks/azure/main.tf
terraform {
  # Partial backend config — do NOT hardcode the storage account/container.
  # Pass -backend-config at init time (documented in this stack's README).
  backend "azurerm" {}
}

provider "azurerm" { features {} }

variable "cloud" { default = "azure" }

module "network" {
  source = "../../modules/azure/network"
  name   = "idea-board"
  region = var.region
  cidr   = "10.0.0.0/16"
}

module "cluster" {
  source      = "../../modules/azure/cluster"
  name        = "idea-board"
  region      = var.region
  k8s_version = var.k8s_version
  node_size   = var.node_size    # small | medium | large
  node_count  = var.node_count
  network     = module.network
}

module "database" {
  source         = "../../modules/azure/database"
  name           = "idea-board"
  engine_version = var.engine_version
  size           = var.db_size
  storage_gb     = var.storage_gb
  network        = module.network
  allowed_cidrs  = var.allowed_cidrs
}

# The contract outputs every stack exposes — an IDENTICAL set across aws/gcp/azure.
# This is what CI (provision.yml / deploy.yml) and scripts/get-kubeconfig.sh read.
output "cluster_name"  { value = module.cluster.cluster_name }
output "kube_host"     { value = module.cluster.kube_host }
output "kube_ca_cert"  { value = module.cluster.kube_ca_cert }
output "oidc_provider" { value = module.cluster.oidc_provider }
output "location"      { value = module.cluster.location } # region on AWS/Azure, ZONE on GCP
output "region"        { value = var.region }
output "db_host"       { value = module.database.db_host }
output "db_secret_ref" { value = module.database.db_secret_ref }
```

Also add `infra/stacks/azure/terraform.tfvars.example` and a short `README.md` documenting
the **partial backend** init for Azure Blob state, e.g.:

```bash
terraform -chdir=infra/stacks/azure init \
  -backend-config="resource_group_name=$TF_STATE_RG" \
  -backend-config="storage_account_name=$TF_STATE_SA" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=idea-board/azure.tfstate"
```

Note the stack is structurally identical to the AWS and GCP stacks — same module call
order, same contract outputs. That sameness is the contract paying off.

> **Platform-layer state (learned on GCP).** The `infra/platform` add-ons layer also keeps
> *per-cloud* remote state (S3 on AWS, GCS on GCP — symmetric). Terraform can't switch a
> backend's **type** with `-backend-config` alone, so — exactly as `provision.yml` does for
> GCP by writing a `zz_gcs_backend_override.tf` — add an **`azurerm` backend override file**
> for the platform layer and `init -reconfigure` it against your Blob container. Masking a
> failed platform `init`/`apply` here once silently left the add-ons uninstalled, so this
> step fails hard by design.

---

## Step 3 — Add a `case` branch to `scripts/get-kubeconfig.sh`

This POSIX-sh script is the **only** cloud-specific auth shim. Add an `azure` branch that
reads the cluster/region from Terraform output, exactly like the existing branches:

```sh
# scripts/get-kubeconfig.sh   (arg $1 = cloud)
case "$1" in
  aws)
    aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
    ;;
  gcp)
    # --location (NOT --region): the GKE cluster is ZONAL, so LOCATION is the zone
    # (the `location` stack output). --location also accepts a region if you go regional.
    gcloud container clusters get-credentials "$CLUSTER" --location "$LOCATION"
    ;;
  azure)
    az aks get-credentials --name "$CLUSTER" --resource-group "$RESOURCE_GROUP"
    ;;
  *)
    echo "unknown cloud: $1" >&2
    exit 1
    ;;
esac
```

(`CLUSTER`/`REGION`/`LOCATION`/`RESOURCE_GROUP` come from `terraform -chdir=infra/stacks/azure
output` — `LOCATION` is the `location` contract output added in Step 1.)

---

## Step 4 — Add the platform provider block + Helm overlay

### ClusterSecretStore in `infra/platform`

`infra/platform` is identical for every cloud **except** the ClusterSecretStore provider
block. Add an Azure Key Vault provider option, selected by the platform's `cloud` variable:

```yaml
# ClusterSecretStore "cloud-secrets" — azure branch
spec:
  provider:
    azurekv:
      authType: WorkloadIdentity           # uses the AKS OIDC issuer from Step 1
      vaultUrl: https://<your-kv>.vault.azure.net
      serviceAccountRef:
        name: external-secrets
```

The ExternalSecret **template** (`externalsecret-db`) still references ClusterSecretStore
`cloud-secrets` and pulls its remote-key **name** from the `externalSecret.remoteKey` value —
so the only change is that one overlay value (`idea-board-db` for Key Vault), never a
template edit.

### `charts/idea-board/values-azure.yaml`

Add a per-cloud overlay carrying **only** the storageClass, LoadBalancer annotations, and —
because Key Vault forbids `/` — the Secret-store remote-key name. That is the same handful of
knobs `values-aws.yaml` / `values-gcp.yaml` carry:

```yaml
# values-azure.yaml — overlay only. Keys are TOP-LEVEL (the chart reads storageClass and
# externalSecret at the root, NOT under `global:`) — mirror values-aws.yaml / values-gcp.yaml.
storageClass: managed-csi
externalSecret:
  remoteKey: idea-board-db   # Key Vault (like GCP Secret Manager) disallows "/"; AWS keeps idea-board/db
frontend:
  service:
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "false"
```

---

## Step 5 — Extend the CI enum

In `.github/workflows/deploy.yml`, add `azure` to the `cloud` `workflow_dispatch` input
options (and the matrix, if you use one). Configure GitHub → Azure **OIDC federation**
(Workload Identity Federation for the GitHub Actions subject) so the pipeline authenticates
with **no static keys**, mirroring the AWS/GCP OIDC setup.

The pipeline body does not change: it already reads `$CLOUD` and runs
`terraform -chdir=infra/stacks/$CLOUD …`, `scripts/get-kubeconfig.sh $CLOUD`, and
`helm … -f values.yaml -f values-$CLOUD.yaml`.

---

## Step 6 — Validate

```bash
# Terraform hygiene
terraform -chdir=infra/stacks/azure init -backend=false
terraform -chdir=infra/stacks/azure validate
terraform fmt -check -recursive infra/modules/azure infra/stacks/azure

# Chart still lints with the new overlay
helm lint charts/idea-board -f charts/idea-board/values.yaml -f charts/idea-board/values-azure.yaml

# End-to-end (in a sandbox subscription)
gh workflow run deploy.yml -f cloud=azure -f environment=staging
```

A green run should: create the VNet/AKS/Postgres, fetch the kubeconfig, install the
add-ons, run the Alembic migration Job, roll out the app, and pass the AI health-check.

---

## Checklist

- [ ] `infra/modules/azure/network` — outputs `network_id`, `subnet_ids`, `private_subnet_ids`.
- [ ] `infra/modules/azure/cluster` — outputs `cluster_name`, `kube_host`, `kube_ca_cert` (base64), `oidc_provider`, `location`; t-shirt → `Standard_*` VM sizes.
- [ ] `infra/modules/azure/database` — outputs `db_host`, `db_port`, `db_name`, `db_secret_ref`; password in Key Vault at `idea-board-db` (no `/`); t-shirt → Postgres SKUs.
- [ ] `infra/stacks/azure` — `cloud` var, wires the 3 modules, exposes the contract outputs (incl. `location`, `region`, `db_secret_ref`), partial Blob backend + `terraform.tfvars.example` + README.
- [ ] `scripts/get-kubeconfig.sh` — `azure)` branch (`az aks get-credentials`).
- [ ] `infra/platform` — Key Vault ClusterSecretStore provider option **+** `azurerm` backend override file for platform state.
- [ ] `charts/idea-board/values-azure.yaml` — top-level `storageClass` + LB annotations + `externalSecret.remoteKey` (`idea-board-db`).
- [ ] `.github/workflows/deploy.yml` — `azure` added to the `cloud` enum + OIDC federation configured.
- [ ] Validated: `terraform validate/fmt`, `helm lint`, and a sandbox `deploy.yml` run.

---

## Honest caveats (read the README's leaky-abstractions note too)

- **Auth models genuinely differ.** AKS AAD/Workload Identity is not EKS access entries or
  GKE Workload Identity. The *fetch* is abstracted by the shim; the *trust setup* (OIDC
  federation) is configured per cloud and is real work.
- **T-shirt sizes are approximations.** `Standard_B2s` is *similar* to `t3.medium` /
  `e2-medium`, not identical — CPU credit behavior, **allocatable** capacity, and network
  limits differ. Real example: GKE reserves so heavily on shared-core `e2-medium` that only
  **~945m** CPU is allocatable (not ~2000m), so the GCP node pool needed `node_count = 3` to
  fit the same add-ons + app that 2× `t3.medium` runs on AWS. Size the node count to the
  cloud's *allocatable*, not its nominal vCPU.
- **`k8s_version` is advisory on channel-managed control planes.** GKE (and AKS auto-upgrade
  channels) reject a version they don't currently offer — GKE errors on a pinned `1.33`
  ("No valid versions with the prefix"). The GCP module therefore lets the release channel
  pick the version and treats `k8s_version` as a hint; do the same for AKS. Only EKS accepts
  an exact pinned version.
- **Managed Postgres knobs differ.** Flexible Server flags, backup/maintenance semantics,
  and TLS enforcement are Azure-specific and intentionally outside the common contract.
- **Overlay YAML is cloud-specific by design.** `values-azure.yaml` (storageClass + LB
  annotations) is exactly the leak we chose to contain there.

These are the same seams called out for AWS/GCP in the
[README](../README.md#honest-note-where-the-abstraction-leaks): contained to a handful of
well-marked files, not pretended away.
