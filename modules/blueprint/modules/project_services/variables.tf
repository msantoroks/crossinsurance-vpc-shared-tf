variable "project_id" {
  type = string
}

variable "cidr_gate_token" {
  type        = string
  description = "Ordering dependency: CIDR validation and, when applicable, GCS upload."
  default     = ""
}

variable "services" {
  description = "Optional override list of API service names to enable (default: CRM, Compute, IAM)."
  type        = list(string)
  default     = null
  nullable    = true
}
