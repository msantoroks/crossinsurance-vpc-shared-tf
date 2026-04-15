# Incremental GCS registry (text object): apply adds/updates rows for this peer_env;
# destroy removes all rows for this peer_env (terraform destroy / null_resource replace).
#
# - triggers: any change to peer_env/CIDR/subnets/bucket/object replaces the resource → destroy
#   provisioner removes the old peer in GCS; apply provisioner writes the new merged file.
# - Python script downloads the object, edits in memory, and uploads (no committed local file).

locals {
  cidr_gcs_upload_enabled = var.cidr_registry_gcs_bucket != null && var.cidr_registry_gcs_bucket != ""
}

resource "null_resource" "cidr_registry_gcs" {
  count = local.cidr_gcs_upload_enabled ? 1 : 0

  triggers = {
    peer_env   = var.peer_env
    project_id = var.project_id
    vpc_cidr   = var.vpc_cidr
    subnets    = sha256(jsonencode(var.subnets))
    bucket     = var.cidr_registry_gcs_bucket
    object     = var.cidr_registry_gcs_object
    python     = var.cidr_python_executable
    # Script hash — avoids storing absolute paths (e.g. /Users/...) in state.
    script_sha256 = filesha256("${path.module}/scripts/cidr_registry_gcs_sync.py")
  }

  depends_on = [data.external.cidr_registry_validation]

  provisioner "local-exec" {
    command = "${var.cidr_python_executable} ${path.module}/scripts/cidr_registry_gcs_sync.py apply"
    environment = {
      PEER_ENV     = var.peer_env
      PROJECT_ID   = var.project_id
      VPC_CIDR     = var.vpc_cidr
      SUBNETS_JSON = jsonencode(var.subnets)
      BUCKET       = var.cidr_registry_gcs_bucket
      OBJECT       = var.cidr_registry_gcs_object
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${self.triggers.python} ${path.module}/scripts/cidr_registry_gcs_sync.py destroy"
    environment = {
      PEER_ENV = self.triggers.peer_env
      BUCKET   = self.triggers.bucket
      OBJECT   = self.triggers.object
    }
  }
}
