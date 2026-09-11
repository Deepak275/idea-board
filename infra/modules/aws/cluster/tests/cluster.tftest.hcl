# Terraform unit tests for the AWS cluster module.
# Runs only under `terraform test` — never during plan/apply. Uses mock_provider
# so it needs NO AWS credentials, makes NO cloud calls, and costs nothing.
# Asserts the t-shirt -> instance-type mapping and the node_size validation.

mock_provider "aws" {}
mock_provider "tls" {}

# mock_provider generates a non-JSON stub for aws_iam_policy_document.json, which
# aws_iam_role.assume_role_policy rejects at plan time. Override both with valid
# JSON so the plan succeeds and we can assert on the sizing logic.
override_data {
  target = data.aws_iam_policy_document.cluster_assume_role
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}
override_data {
  target = data.aws_iam_policy_document.node_assume_role
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

variables {
  name        = "test"
  region      = "us-east-1"
  k8s_version = "1.33"
  node_count  = 1
  network = {
    network_id         = "vpc-12345678"
    subnet_ids         = ["subnet-aaaa"]
    private_subnet_ids = ["subnet-bbbb"]
  }
}

run "small_maps_to_t3_medium" {
  command = plan
  variables { node_size = "small" }
  assert {
    condition     = aws_eks_node_group.this.instance_types[0] == "t3.medium"
    error_message = "node_size=small must map to t3.medium on AWS"
  }
}

run "large_maps_to_m5_2xlarge" {
  command = plan
  variables { node_size = "large" }
  assert {
    condition     = aws_eks_node_group.this.instance_types[0] == "m5.2xlarge"
    error_message = "node_size=large must map to m5.2xlarge on AWS"
  }
}

run "invalid_node_size_is_rejected" {
  command = plan
  variables { node_size = "extra-large" }
  expect_failures = [var.node_size]
}
