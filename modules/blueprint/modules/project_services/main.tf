locals {
  # Reference the token to keep an explicit edge in the dependency graph.
  _cidr_gate = var.cidr_gate_token

  default_services = [
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
  ]

  other_services = toset(coalesce(var.services, local.default_services))
}

# Service Usage must be enabled before other APIs can be toggled via this API.
resource "google_project_service" "serviceusage" {
  project = var.project_id
  service = "serviceusage.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "main" {
  for_each = local.other_services

  project = var.project_id
  service = each.value

  disable_on_destroy = false

  depends_on = [google_project_service.serviceusage]
}
