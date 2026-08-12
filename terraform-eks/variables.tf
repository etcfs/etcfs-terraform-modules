variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "etcfs-eks"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_az" {
  type    = string
  default = "us-east-1a"
}

variable "control_plane_azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "volume_size_gb" {
  type    = number
  default = 4
}

variable "volume_iops" {
  type    = number
  default = 100
}

variable "key_name" {
  type    = string
  default = ""
}

variable "enable_ssh" {
  type    = bool
  default = false
}

variable "ssh_ingress_cidr" {
  type    = string
  default = ""
}

variable "mount_path" {
  type    = string
  default = "/mnt/etcfs"
}

# No defaults on the three image variables: an ECR/ghcr repository is
# account- and user-specific, and defaulting to one that does not exist in
# the caller's account fails opaquely at pod scheduling time rather than at
# `terraform plan`, where a missing required variable fails immediately with
# a clear message.

variable "etcfuse_meta_image" {
  type = string
}

variable "etcfuse_image" {
  type = string
}

variable "csi_image_repository" {
  type = string
}

variable "csi_image_tag" {
  type = string
}
