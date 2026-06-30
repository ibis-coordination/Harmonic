terraform {
  required_version = ">= 1.6"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote, ENCRYPTED state. State is the one place managed-resource
  # credentials (DB password, Spaces keys) unavoidably land in plaintext —
  # see docs/INFRASTRUCTURE.md "Secrets and terraform state". DO Spaces is
  # S3-compatible, so the s3 backend works against it.
  #
  # Chicken-and-egg: the state bucket must exist before `terraform init` can
  # use it. Bootstrap once by hand (create a Spaces bucket in the DO console),
  # then uncomment and `terraform init -migrate-state`.
  #
  # backend "s3" {
  #   endpoints                   = { s3 = "https://nyc3.digitaloceanspaces.com" }
  #   bucket                      = "harmonic-tfstate"
  #   key                         = "harmonic/terraform.tfstate"
  #   region                      = "us-east-1" # ignored by Spaces, but required by the backend
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   skip_requesting_account_id  = true
  #   skip_s3_checksum            = true
  #   # Access keys via env: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY set to a
  #   # DO Spaces key pair (NOT your AWS keys).
  # }
}

provider "digitalocean" {
  # token            via DIGITALOCEAN_TOKEN
  # spaces_access_id via SPACES_ACCESS_KEY_ID
  # spaces_secret_key via SPACES_SECRET_ACCESS_KEY
}

provider "aws" {
  # SES only. Region must be one where you've enabled SES.
  region = var.ses_region
  # credentials via AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY or a profile
}
