terraform {
  required_version = "1.14.8"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.26.0"
    }
  }
}
