output "project_id" {
  value = var.project_id
}

output "network_self_link" {
  value = module.vpc.network_self_link
}

output "subnet_self_links" {
  value = module.vpc.subnet_self_links
}

output "cidr_registry_gcs_uri" {
  description = "gs:// URI of the shared CIDR registry object (module merges only this peer_env on apply)."
  value       = local.cidr_gcs_upload_enabled ? "gs://${var.cidr_registry_gcs_bucket}/${var.cidr_registry_gcs_object}" : null
}
