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

variable "node_count" {
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
