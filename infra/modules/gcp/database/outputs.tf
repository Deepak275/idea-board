# infra/modules/gcp/database/outputs.tf
#
# EXACT cross-cloud database module contract (identical to modules/aws/database):
#   outputs { db_host, db_port, db_name, db_secret_ref }

output "db_host" {
  description = "Cloud SQL private IP address."
  value       = google_sql_database_instance.this.private_ip_address
}

output "db_port" {
  description = "PostgreSQL port."
  value       = 5432
}

output "db_name" {
  description = "Application database name."
  value       = google_sql_database.app.name
}

output "db_secret_ref" {
  description = "GCP Secret Manager secret id holding credentials + DATABASE_URL. NOTE: Secret Manager ids cannot contain '/', so this is \"idea-board-db\" (the AWS side uses \"idea-board/db\"). The per-cloud ClusterSecretStore/ExternalSecret remoteRef key differs accordingly — documented as a known leaky abstraction."
  value       = google_secret_manager_secret.db.secret_id
}
