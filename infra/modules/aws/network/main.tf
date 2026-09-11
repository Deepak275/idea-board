# infra/modules/aws/network/main.tf
#
# AWS network plane for idea-board: one VPC, one public + one private subnet
# per AZ (up to 3 AZs), an Internet Gateway for public egress, and a single
# NAT Gateway so private nodes/DB subnets can reach the internet for pulls.
#
# Subnets are tagged for EKS load-balancer auto-discovery:
#   public  -> kubernetes.io/role/elb          (internet-facing LBs)
#   private -> kubernetes.io/role/internal-elb (internal LBs, worker nodes)

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Spread across up to 3 AZs for a balance of HA and cost.
  azs = slice(data.aws_availability_zones.available.names, 0, min(3, length(data.aws_availability_zones.available.names)))

  # Carve /24s out of the VPC CIDR. Public subnets take the low indices,
  # private subnets are offset by 128 so the two ranges never collide.
  public_subnet_cidrs  = [for i, _ in local.azs : cidrsubnet(var.cidr, 8, i)]
  private_subnet_cidrs = [for i, _ in local.azs : cidrsubnet(var.cidr, 8, i + 128)]

  tags = {
    Name      = var.name
    Project   = "idea-board"
    ManagedBy = "terraform"
    Module    = "aws/network"
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-igw" })
}

# --- Public subnets -------------------------------------------------------

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name                     = "${var.name}-public-${local.azs[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

# --- Private subnets ------------------------------------------------------

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, {
    Name                              = "${var.name}-private-${local.azs[count.index]}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# --- NAT (single gateway, cost-conscious default) -------------------------

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.tags, { Name = "${var.name}-nat-eip" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(local.tags, { Name = "${var.name}-nat" })

  depends_on = [aws_internet_gateway.this]
}

# --- Routing --------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${var.name}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
