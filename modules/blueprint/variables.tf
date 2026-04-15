variable "project_id" {
  type = string
}

variable "vpc_name" {
  type = string
}

variable "subnets" {
  type = list(object({
    name   = string
    region = string
    cidr   = string
  }))
}

variable "shared_project_id" {
  type = string
}

variable "attach_shared_vpc_service_project" {
  type = bool
}

variable "peer_env" {
  type = string
}

variable "host_vpc_name" {
  type = string
}

variable "name_prefix" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional prefix for peering names; defaults to project_id-peer_env."
}

variable "vpc_cidr" {
  type        = string
  description = "IPv4 CIDR of this workload VPC (must match environments.yaml for this peer_env)."
}

variable "cidr_python_executable" {
  type        = string
  default     = "python3"
  description = "Python executable for the CIDR validator (data.external)."
}

variable "cidr_registry_gcs_bucket" {
  type        = string
  default     = null
  nullable    = true
  description = "GCS bucket in the shared project where the CIDR registry file is written after validation. null = no upload."
}

variable "cidr_registry_gcs_object" {
  type        = string
  default     = "cidr-registry.txt"
  description = "Object name inside the bucket (e.g. cidr-registry.txt)."
}
