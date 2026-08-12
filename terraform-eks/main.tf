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

module "eks" {
  source = "../terraform/modules/etcfs-eks"

  cluster_name         = var.cluster_name
  kubernetes_version   = var.kubernetes_version
  node_count           = var.node_count
  instance_type        = var.instance_type
  node_az              = var.node_az
  control_plane_azs    = var.control_plane_azs
  volume_size_gb       = var.volume_size_gb
  volume_iops          = var.volume_iops
  key_name             = var.key_name
  enable_ssh           = var.enable_ssh
  ssh_ingress_cidr     = var.ssh_ingress_cidr
  mount_path           = var.mount_path
  etcfuse_meta_image   = var.etcfuse_meta_image
  etcfuse_image        = var.etcfuse_image
  csi_image_repository = var.csi_image_repository
  csi_image_tag        = var.csi_image_tag
}
