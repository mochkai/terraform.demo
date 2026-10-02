terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket               = "terraform-tfstate-731802381878-eu-north-1-an"
    region               = "eu-north-1"
    key                  = "terraform.tfstate"
    workspace_key_prefix = "terraform-demo"
    encrypt              = true
    use_lockfile         = true
  }

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
