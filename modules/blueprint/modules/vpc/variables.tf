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

variable "enable_shared_vpc_host" {
  type        = bool
  default     = false
  description = "If true, Terraform manages google_compute_shared_vpc_host_project (needs org permission). If false, enable Shared VPC host outside Terraform (e.g. Console)."
}

variable "shared_vpc_host_project_id" {
  type        = string
  default     = null
  nullable    = true
  description = "Host project ID when this stack should attach as a Shared VPC service project (see attach_shared_vpc_service_project)."
}

variable "attach_shared_vpc_service_project" {
  type        = bool
  default     = false
  description = "If true, creates google_compute_shared_vpc_service_project (requires compute.organizations.enableXpnResource). If false, attach dev/stg to the host in the Console or via an org admin."
}
