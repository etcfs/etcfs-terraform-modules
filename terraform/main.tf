terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state, deliberately. A remote backend only earns its keys once more
  # than one person applies against the same cluster; until then it is an S3
  # bucket and a lock table to provision and pay for before anything can be
  # created at all.
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.region
}

module "cluster" {
  source = "./modules/etcfs-cluster"

  cluster_name     = var.cluster_name
  az               = var.az
  node_count       = var.node_count
  instance_type    = var.instance_type
  volume_size_gb   = var.volume_size_gb
  volume_iops      = var.volume_iops
  key_name         = var.key_name
  public_key_path  = var.public_key_path
  subnet_id        = var.subnet_id
  ssh_ingress_cidr = var.ssh_ingress_cidr
  instance_profile = var.instance_profile
}
