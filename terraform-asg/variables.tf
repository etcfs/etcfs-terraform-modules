variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "cluster_name" {
  type    = string
  default = "etcfuse"
}

variable "az" {
  type    = string
  default = "eu-west-1a"
}

variable "min_size" {
  type    = number
  default = 3
}

variable "max_size" {
  type    = number
  default = 5
}

variable "desired_capacity" {
  type    = number
  default = 3
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "volume_size_gb" {
  type    = number
  default = 10
}

variable "volume_iops" {
  type    = number
  default = 100
}

variable "key_name" {
  description = "Empty derives '<cluster_name>-key'."
  type        = string
  default     = ""
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "subnet_id" {
  type    = string
  default = ""
}

variable "ssh_ingress_cidr" {
  description = "Empty auto-detects the caller's public IP as a /32."
  type        = string
  default     = ""
}

variable "instance_profile" {
  description = "IAM instance profile created by scripts/infra/fencing-iam.sh."
  type        = string
  default     = "etcfs-nodes"
}

variable "etcfs_version" {
  description = "EtcFS release tag to install on boot. Empty resolves the latest GitHub release."
  type        = string
  default     = ""
}

variable "etcd_version" {
  type    = string
  default = "v3.5.18"
}
