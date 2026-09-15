terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket       = "castor-garage-tfstate-147495561460"
    key          = "k8s-infra/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
