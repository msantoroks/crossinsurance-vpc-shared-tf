variable "name_prefix" {
  type = string
}

variable "peer_env" {
  type        = string
  description = "Peer environment name (e.g. dev or stg)."
}

variable "service_project_id" {
  type        = string
  description = "Workload (service-side) project ID."
}

variable "service_network_name" {
  type        = string
  description = "VPC name in the service project."
}

variable "host_project_id" {
  type        = string
  description = "Shared (host) project ID."
}

variable "host_network_name" {
  type        = string
  description = "VPC name in the host project."
}
