# Terraform unit tests for the AWS database module (mock_provider — no creds/cost).
# Asserts the t-shirt -> RDS instance-class mapping and the size validation.

mock_provider "aws" {}
mock_provider "random" {}

variables {
  name           = "test"
  engine_version = "16.3"
  storage_gb     = 20
  network = {
    network_id         = "vpc-12345678"
    subnet_ids         = ["subnet-aaaa"]
    private_subnet_ids = ["subnet-bbbb"]
  }
  allowed_cidrs = ["10.20.0.0/16"]
}

run "small_maps_to_db_t3_micro" {
  command = plan
  variables { size = "small" }
  assert {
    condition     = aws_db_instance.this.instance_class == "db.t3.micro"
    error_message = "size=small must map to db.t3.micro on AWS"
  }
}

run "large_maps_to_db_t3_medium" {
  command = plan
  variables { size = "large" }
  assert {
    condition     = aws_db_instance.this.instance_class == "db.t3.medium"
    error_message = "size=large must map to db.t3.medium on AWS"
  }
}

run "invalid_size_is_rejected" {
  command = plan
  variables { size = "tiny" }
  expect_failures = [var.size]
}
