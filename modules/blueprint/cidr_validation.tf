# CIDR validation (geometry + VPC overlap against the GCS registry) before creating resources.
# JSON output feeds `cidr_registry_validation_token` to order APIs / the rest of the graph.

data "external" "cidr_registry_validation" {
  program = [
    var.cidr_python_executable,
    "${path.module}/scripts/cidr_registry_gcs_sync.py",
    "validate",
  ]

  query = {
    peer_env     = var.peer_env
    project_id   = var.project_id
    vpc_cidr     = var.vpc_cidr
    subnets_json = jsonencode(var.subnets)
    bucket       = coalesce(var.cidr_registry_gcs_bucket, "")
    object       = var.cidr_registry_gcs_object
  }
}

locals {
  cidr_registry_validation_token = data.external.cidr_registry_validation.result.valid
}
