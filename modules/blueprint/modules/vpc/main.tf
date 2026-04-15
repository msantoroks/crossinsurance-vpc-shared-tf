resource "google_compute_network" "this" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  project = var.project_id
}

resource "google_compute_subnetwork" "this" {
  for_each = { for s in var.subnets : s.name => s }

  name          = each.value.name
  ip_cidr_range = each.value.cidr
  region        = each.value.region
  network       = google_compute_network.this.id
  project       = var.project_id
}

resource "google_compute_shared_vpc_host_project" "host" {
  count = var.enable_shared_vpc_host ? 1 : 0

  project = var.project_id

  depends_on = [
    google_compute_network.this,
    google_compute_subnetwork.this
  ]
}

resource "google_compute_shared_vpc_service_project" "attachment" {
  count = var.shared_vpc_host_project_id != null && var.attach_shared_vpc_service_project ? 1 : 0

  host_project    = var.shared_vpc_host_project_id
  service_project = var.project_id

  depends_on = [
    google_compute_network.this,
    google_compute_subnetwork.this
  ]
}
