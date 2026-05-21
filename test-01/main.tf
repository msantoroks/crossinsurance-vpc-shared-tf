# Stack-local config: ./config/environments.yaml. Module: ../modules/blueprint.
# Remote state prefix: terraform-state/workloads/test-01

provider "google" {
  project = local.workload.project_id
  region  = local.workload.region
}

provider "google" {
  alias   = "shared"
  project = local.shared.project_id
  region  = local.shared.region
}

data "google_compute_network" "shared" {
  provider = google.shared
  name     = local.shared.vpc_name
}

module "workload" {
  source = "../modules/blueprint"

  providers = {
    google        = google
    google.shared = google.shared
  }

  vpc_cidr = local.workload.vpc_cidr

  cidr_registry_gcs_bucket = "terraform-sandbox-ks-test-crossinsurance-vpc-cidr-validator"
  cidr_registry_gcs_object = "cidr-registry.txt"

  project_id = local.workload.project_id
  vpc_name   = local.workload.vpc_name
  subnets    = local.workload.subnets

  shared_project_id                 = local.shared.project_id
  attach_shared_vpc_service_project = var.manage_shared_vpc_service_attachments
  peer_env                          = "test-01"
  host_vpc_name                     = local.shared.vpc_name

  depends_on = [data.google_compute_network.shared]
}
