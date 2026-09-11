# infra/modules/gcp/database/main.tf
#
# GCP implementation of the cross-cloud database contract: a private-IP Cloud SQL
# Postgres instance reachable from the GKE nodes over VPC peering (Private
# Service Access), with credentials + a ready-to-use DATABASE_URL stored in GCP
# Secret Manager at logical key "idea-board-db".
#
# t-shirt -> tier map (GCP side of the shared vocabulary):
#   small=db-f1-micro | medium=db-g1-small | large=db-custom-2-7680

locals {
  tier = {
    small  = "db-f1-micro"
    medium = "db-g1-small"
    large  = "db-custom-2-7680"
  }[var.size]

  pg_major         = split(".", var.engine_version)[0]
  database_version = "POSTGRES_${local.pg_major}"

  db_user = "ideas"
  db_name = "ideas"

  # Region is not part of the shared module contract (AWS reads it from the
  # provider). GCP's Cloud SQL needs it explicitly, so we derive it from the
  # subnet self_link (…/regions/<REGION>/subnetworks/…) — keeps the contract
  # identical to AWS while still being region-correct.
  region = regex("/regions/([^/]+)/", var.network.subnet_ids[0])[0]
}

# --- Private Service Access: reserve a range and peer with servicenetworking ---
resource "google_compute_global_address" "psa" {
  name          = "${var.name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = var.network.network_id
}

resource "google_service_networking_connection" "psa" {
  network                 = var.network.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
}

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "google_sql_database_instance" "this" {
  name             = "${var.name}-pg"
  database_version = local.database_version
  region           = local.region

  settings {
    tier              = local.tier
    availability_type = "ZONAL"
    disk_size         = var.storage_gb
    disk_type         = "PD_SSD"

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network.network_id
    }

    backup_configuration {
      enabled = true
    }
  }

  deletion_protection = false

  depends_on = [google_service_networking_connection.psa]
}

resource "google_sql_database" "app" {
  name     = local.db_name
  instance = google_sql_database_instance.this.name
}

resource "google_sql_user" "app" {
  name     = local.db_user
  instance = google_sql_database_instance.this.name
  password = random_password.db.result
}

# --- Secret Manager: credentials + a ready-to-consume DATABASE_URL ---
resource "google_secret_manager_secret" "db" {
  secret_id = "idea-board-db"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db" {
  secret = google_secret_manager_secret.db.id
  secret_data = jsonencode({
    username = local.db_user
    password = random_password.db.result
    host     = google_sql_database_instance.this.private_ip_address
    port     = 5432
    dbname   = local.db_name
    DATABASE_URL = format(
      "postgresql+psycopg://%s:%s@%s:5432/%s",
      local.db_user,
      random_password.db.result,
      google_sql_database_instance.this.private_ip_address,
      local.db_name,
    )
  })
}
