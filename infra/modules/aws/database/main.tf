# infra/modules/aws/database/main.tf
#
# AWS database plane for idea-board: a private RDS PostgreSQL instance reachable
# only from allowed_cidrs, with its master password generated here and stored in
# AWS Secrets Manager at the logical key "idea-board/db". The secret payload is a
# JSON blob that includes a ready-to-use DATABASE_URL in the 12-factor form the
# app expects (postgresql+psycopg://USER:PASS@HOST:PORT/DBNAME). The External
# Secrets Operator (ClusterSecretStore "cloud-secrets") pulls this remote key and
# projects it into the K8s Secret "idea-board-db".
#
# db_secret_ref (module output) == the Secrets Manager secret ARN.

locals {
  # T-shirt -> real RDS instance class. AWS-specific half of the sizing contract.
  instance_class_by_size = {
    small  = "db.t3.micro"
    medium = "db.t3.small"
    large  = "db.t3.medium"
  }
  instance_class = local.instance_class_by_size[var.size]

  db_username = "ideas"
  db_name     = "ideas"

  # Logical key shared with the ESO ClusterSecretStore remote reference.
  secret_key = "idea-board/db"

  tags = {
    Name      = var.name
    Project   = "idea-board"
    ManagedBy = "terraform"
    Module    = "aws/database"
  }
}

# --- Master password ------------------------------------------------------
# override_special is restricted to URL-safe, RDS-safe characters so the value
# can be embedded verbatim in DATABASE_URL without escaping.
resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "-_"
}

# --- Networking -----------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.network.private_subnet_ids

  tags = merge(local.tags, { Name = "${var.name}-db" })
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "idea-board Postgres access"
  vpc_id      = var.network.network_id

  ingress {
    description = "PostgreSQL from allowed CIDRs"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    description = "Allow all egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.name}-db" })
}

# --- RDS PostgreSQL -------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-db"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = local.instance_class

  allocated_storage = var.storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = local.db_name
  username = local.db_username
  password = random_password.db.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 7
  deletion_protection     = false
  skip_final_snapshot     = true
  apply_immediately       = true

  tags = local.tags
}

# --- Secret in AWS Secrets Manager (logical key "idea-board/db") ----------

resource "aws_secretsmanager_secret" "db" {
  name        = local.secret_key
  description = "idea-board Postgres credentials + DATABASE_URL (consumed by ESO ClusterSecretStore cloud-secrets)."

  # 0 = destroy immediately on delete so ephemeral stacks can be re-created
  # without hitting the 'scheduled for deletion' name conflict.
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username     = local.db_username
    password     = random_password.db.result
    host         = aws_db_instance.this.address
    port         = aws_db_instance.this.port
    dbname       = aws_db_instance.this.db_name
    engine       = "postgres"
    DATABASE_URL = "postgresql+psycopg://${local.db_username}:${random_password.db.result}@${aws_db_instance.this.address}:${aws_db_instance.this.port}/${aws_db_instance.this.db_name}"
  })
}
