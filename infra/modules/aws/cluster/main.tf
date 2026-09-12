# infra/modules/aws/cluster/main.tf
#
# AWS cluster plane for idea-board: an EKS control plane, one EKS-managed node
# group, and an IAM OIDC provider so workloads can use IRSA (IAM Roles for
# Service Accounts) — e.g. the External Secrets Operator reads AWS Secrets
# Manager without static keys.

locals {
  # T-shirt -> real EC2 instance type. This map is the AWS-specific half of the
  # cloud-agnostic sizing contract.
  instance_type_by_size = {
    small  = "t3.medium"
    medium = "m5.large"
    large  = "m5.2xlarge"
  }
  instance_type = local.instance_type_by_size[var.node_size]

  # EKS wants the control plane wired to both public and private subnets so it
  # can place both internet-facing and internal load balancers.
  control_plane_subnet_ids = concat(var.network.subnet_ids, var.network.private_subnet_ids)

  tags = {
    Name      = var.name
    Project   = "idea-board"
    ManagedBy = "terraform"
    Module    = "aws/cluster"
  }
}

# --- IAM: EKS control-plane role -----------------------------------------

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster_amazon_eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# --- EKS control plane ----------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.k8s_version

  vpc_config {
    subnet_ids              = local.control_plane_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # API_AND_CONFIG_MAP enables EKS Access Entries (see the stack) so IAM
  # principals other than the cluster creator (e.g. the CI/CD deploy role) can
  # be granted kubectl/helm access declaratively. CONFIG_MAP-only would force
  # aws-auth ConfigMap surgery and lock out non-creator principals.
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
    # Create-only; set explicitly to match the existing cluster (omitting it reads
    # as true->null and forces REPLACEMENT of a live cluster). true also grants
    # the pipeline deploy-role admin when it creates a fresh cluster.
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster_amazon_eks_cluster_policy,
  ]
}

# --- IRSA / OIDC provider -------------------------------------------------

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = local.tags
}

# --- IAM: worker node role ------------------------------------------------

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

# --- Managed node group ---------------------------------------------------

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.network.private_subnet_ids
  instance_types  = [local.instance_type]
  # AL2 is retired for EKS >= 1.33; AL2023 is the current standard node OS.
  ami_type = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count * 3
  }

  update_config {
    max_unavailable = 1
  }

  tags = local.tags

  # Node group creation fails if the role permissions aren't attached first.
  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  lifecycle {
    # desired_size is managed by the HPA/cluster-autoscaler at runtime; don't
    # fight it on subsequent applies.
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# --- Core add-ons ---------------------------------------------------------
# Managed so kube-proxy/coredns/vpc-cni track the control-plane version.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # coredns runs on worker nodes, so the node group must exist first.
  depends_on = [aws_eks_node_group.this]

  tags = local.tags
}
