# Submodules: APIs → VPC → peering to the host.
# Default: local paths (works offline). After publishing to GitHub, replace sources below with
# the snippets in main.git.tf.example (Terraform requires literal module sources).

module "project_services" {
  source = "./modules/project_services"

  providers = { google = google }

  project_id = var.project_id

  cidr_gate_token = local.cidr_registry_validation_token
}

module "vpc" {
  source = "./modules/vpc"

  providers = { google = google }

  project_id = var.project_id

  vpc_name = var.vpc_name
  subnets  = var.subnets

  enable_shared_vpc_host = false

  shared_vpc_host_project_id        = var.shared_project_id
  attach_shared_vpc_service_project = var.attach_shared_vpc_service_project

  depends_on = [module.project_services]
}

module "peering" {
  source = "./modules/peering"

  providers = {
    google.service = google
    google.shared  = google.shared
  }

  name_prefix = coalesce(var.name_prefix, "${var.project_id}-${var.peer_env}")
  peer_env    = var.peer_env

  service_project_id   = var.project_id
  service_network_name = module.vpc.network_name
  host_project_id      = var.shared_project_id
  host_network_name    = var.host_vpc_name

  depends_on = [module.vpc]
}
