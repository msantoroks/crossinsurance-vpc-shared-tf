terraform {
  required_providers {
    google = {
      source                = "hashicorp/google"
      version               = "7.26.0"
      configuration_aliases = [google.shared]
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
