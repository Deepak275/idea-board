# infra/modules/aws/database/outputs.tf
#
# EXACT cross-cloud database module contract:
#   outputs { db_host, db_port, db_name, db_secret_ref }

output "db_host" {
  description = "RDS instance hostname."
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "PostgreSQL port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Application database name."
  value       = aws_db_instance.this.db_name
}

output "db_secret_ref" {
  description = "AWS Secrets Manager secret ARN holding credentials + DATABASE_URL (remote key \"idea-board/db\")."
  value       = aws_secretsmanager_secret.db.arn
}
