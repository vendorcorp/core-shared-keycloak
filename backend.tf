terraform {
  backend "s3" {
    bucket         = "vendorcorp-platform-core"
    key            = "terraform-state/core-shared-keycloak"
    dynamodb_table = "vendorcorp-terraform-state-lock"
    region         = "us-east-2"
  }

  required_version = ">= 1.0.11"
  required_providers {
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.15.0"
    }
  }
}
