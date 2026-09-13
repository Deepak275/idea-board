# Terraform unit tests for the GCP database module (mock_provider — no creds/cost).
# Asserts the t-shirt -> Cloud SQL tier mapping, the size validation, and that
# the region is correctly derived from the subnet self_link (contract quirk).

mock_provider "google" {}
mock_provider "random" {}

variables {
  name           = "test"
  engine_version = "16"
  storage_gb     = 20
  network = {
    network_id         = "projects/p/global/networks/n"
    subnet_ids         = ["https://www.googleapis.com/compute/v1/projects/p/regions/us-central1/subnetworks/s"]
    private_subnet_ids = ["https://www.googleapis.com/compute/v1/projects/p/regions/us-central1/subnetworks/s"]
  }
  allowed_cidrs = []
}

run "small_maps_to_db_f1_micro" {
  command = plan
  variables { size = "small" }
  assert {
    condition     = google_sql_database_instance.this.settings[0].tier == "db-f1-micro"
    error_message = "size=small must map to db-f1-micro on GCP"
  }
}

run "region_is_derived_from_subnet_selflink" {
  command = plan
  variables { size = "small" }
  assert {
    condition     = google_sql_database_instance.this.region == "us-central1"
    error_message = "Cloud SQL region must be parsed from the subnet self_link"
  }
}

run "invalid_size_is_rejected" {
  command = plan
  variables { size = "mega" }
  expect_failures = [var.size]
}
