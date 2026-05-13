variable "manage_shared_vpc_service_attachments" {
  description = <<-EOT
    If true, Terraform attaches workload projects as Shared VPC service projects (requires compute.organizations.enableXpnResource on the org).
    If false (default), attach those projects in the Console (Shared VPC → Attach projects) or ask an org admin.
  EOT
  type        = bool
  default     = false
}
