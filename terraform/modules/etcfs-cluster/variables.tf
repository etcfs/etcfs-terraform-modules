variable "cluster_name" {
  description = "Cluster tag/name prefix. Every resource is tagged ClusterName=<this>, which is what destroy-infra.sh's sweep and the chaos scripts filter on."
  type        = string
  default     = "etcfuse"
}

variable "az" {
  description = "Availability zone. The instances and the shared EBS volume must be in the same AZ or the attach fails."
  type        = string
  default     = "eu-west-1a"
}

variable "node_count" {
  description = "Number of compute nodes (etcd colocated). 3 minimum for etcd quorum."
  type        = number
  default     = 3

  validation {
    condition     = var.node_count >= 1
    error_message = "node_count must be at least 1."
  }
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "volume_size_gb" {
  description = "Size of the shared raw EBS volume. EtcFS uses it as a raw block device — it is never formatted."
  type        = number
  default     = 10
}

variable "volume_iops" {
  type    = number
  default = 100
}

variable "root_volume_size_gb" {
  type    = number
  default = 20
}

variable "key_name" {
  description = "Name of the EC2 key pair to create from public_key_path. Empty derives '<cluster_name>-key'; the account-wide 'etcfuse-keypair' the bash scripts import is deliberately not reused, since Terraform would have to own (and on destroy, delete) a key pair other clusters depend on."
  type        = string
  default     = ""
}

variable "public_key_path" {
  description = "Local SSH public key uploaded as the EC2 key pair. The matching private key is what the bootstrap scripts SSH with."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "subnet_id" {
  description = "Subnet to launch into. Empty resolves the default VPC's subnet in var.az."
  type        = string
  default     = ""
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH in. Empty auto-detects the caller's public IP as a /32."
  type        = string
  default     = ""
}

variable "instance_profile" {
  description = "Pre-existing IAM instance profile the nodes run under, created once per account by scripts/infra/fencing-iam.sh. Referenced rather than managed here — see the IAM section of main.tf."
  type        = string
  default     = "etcfs-nodes"
}
