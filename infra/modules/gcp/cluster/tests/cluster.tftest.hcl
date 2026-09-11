# Terraform unit tests for the GCP cluster module (mock_provider — no creds/cost).
# Mirrors the AWS cluster test: asserts the t-shirt -> machine-type mapping and
# the node_size validation, proving both clouds honour the same sizing contract.
#
# The module is written to plan cleanly under a mock provider (which returns
# null/empty for provider-computed fields): coalesce() handles the null
# data.google_project.project_id, and try() guards the master_auth-derived
# kube_ca_cert output. Neither affects a real deploy.

mock_provider "google" {}

variables {
  name        = "test"
  region      = "us-central1"
  k8s_version = "1.33"
  node_count  = 1
  network = {
    network_id         = "projects/p/global/networks/n"
    subnet_ids         = ["https://www.googleapis.com/compute/v1/projects/p/regions/us-central1/subnetworks/s"]
    private_subnet_ids = ["https://www.googleapis.com/compute/v1/projects/p/regions/us-central1/subnetworks/s"]
  }
}

run "small_maps_to_e2_medium" {
  command = plan
  variables { node_size = "small" }
  assert {
    condition     = google_container_node_pool.this.node_config[0].machine_type == "e2-medium"
    error_message = "node_size=small must map to e2-medium on GCP"
  }
}

run "large_maps_to_e2_standard_8" {
  command = plan
  variables { node_size = "large" }
  assert {
    condition     = google_container_node_pool.this.node_config[0].machine_type == "e2-standard-8"
    error_message = "node_size=large must map to e2-standard-8 on GCP"
  }
}

run "invalid_node_size_is_rejected" {
  command = plan
  variables { node_size = "extra-large" }
  expect_failures = [var.node_size]
}
