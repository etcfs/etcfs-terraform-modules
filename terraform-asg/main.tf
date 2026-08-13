terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state, same reasoning as infra/terraform: this earns a remote
  # backend only once more than one person applies against the same cluster.
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.region
}

module "asg" {
  source = "../terraform/modules/etcfs-asg"

  cluster_name     = var.cluster_name
  az               = var.az
  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity
  instance_type    = var.instance_type
  volume_size_gb   = var.volume_size_gb
  volume_iops      = var.volume_iops
  key_name         = var.key_name
  public_key_path  = var.public_key_path
  subnet_id        = var.subnet_id
  ssh_ingress_cidr = var.ssh_ingress_cidr
  instance_profile = var.instance_profile
  etcfs_version    = var.etcfs_version
  etcd_version     = var.etcd_version
}
