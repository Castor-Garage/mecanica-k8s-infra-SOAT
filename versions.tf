terraform {
  required_version = ">= 1.5.0"

  # O bucket nao fica fixo aqui: o pipeline passa
  # -backend-config="bucket=castor-garage-tfstate-<account-id>" com o ID da
  # conta AWS das credenciais em uso (ver README).
  backend "s3" {
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
