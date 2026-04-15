# Peering: service -> host first, then host -> service.
# Uses canonical URIs (project id + network name) to avoid self_link drift from the API on each refresh.

locals {
  service_network_uri = "projects/${var.service_project_id}/global/networks/${var.service_network_name}"
  host_network_uri    = "projects/${var.host_project_id}/global/networks/${var.host_network_name}"
}

resource "google_compute_network_peering" "service_to_host" {
  provider = google.service

  name = "${var.name_prefix}-${var.peer_env}-to-shared"

  network      = local.service_network_uri
  peer_network = local.host_network_uri

  import_custom_routes = false
  export_custom_routes = false
}

resource "google_compute_network_peering" "host_to_service" {
  provider = google.shared

  name = "${var.name_prefix}-shared-to-${var.peer_env}"

  network      = local.host_network_uri
  peer_network = local.service_network_uri

  import_custom_routes = false
  export_custom_routes = false

  depends_on = [google_compute_network_peering.service_to_host]
}
