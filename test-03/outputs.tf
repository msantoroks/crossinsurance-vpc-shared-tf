output "stack" {
  value = "test-03"
}

output "project_id" {
  description = "GCP project ID for this workload."
  value       = module.workload.project_id
}

output "shared_vpc_self_link" {
  description = "Existing shared VPC (read-only)."
  value       = data.google_compute_network.shared.self_link
}

output "vpc_self_link" {
  value = module.workload.network_self_link
}

output "subnet_self_links" {
  value = module.workload.subnet_self_links
}
