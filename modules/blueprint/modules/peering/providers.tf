terraform {
  required_providers {
    google = {
      source                = "hashicorp/google"
      version               = "7.26.0"
      configuration_aliases = [google.service, google.shared]
    }
  }
}
