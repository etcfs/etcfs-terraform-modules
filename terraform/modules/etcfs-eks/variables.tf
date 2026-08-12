variable "cluster_name" {
  description = "EKS cluster name and resource tag prefix."
  type        = string
  default     = "etcfs-eks"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "node_count" {
  description = "Number of self-managed worker nodes, all in node_az. 2 minimum to exercise cross-node RWX; the fencing/chaos suites' node-count reasoning does not apply here since Kubernetes owns pod placement, not EtcFS."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1
    error_message = "node_count must be at least 1."
  }
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "root_volume_size_gb" {
  type    = number
  default = 20
}

variable "node_az" {
  description = "Availability zone every node and the shared volume live in. io2 Multi-Attach is single-AZ, so this is not a per-node choice."
  type        = string
  default     = "us-east-1a"
}

variable "control_plane_azs" {
  description = "AZs for the EKS control plane's own subnets. EKS requires at least 2; nothing schedules onto the second one."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "node_subnet_id" {
  description = "Subnet the nodes launch into. Empty resolves the default VPC's subnet in node_az."
  type        = string
  default     = ""
}

variable "volume_size_gb" {
  description = "Size of the shared raw EBS volume. Never formatted — EtcFS uses it as a raw block device."
  type        = number
  default     = 4
}

variable "volume_iops" {
  type    = number
  default = 100
}

variable "key_name" {
  description = "Existing EC2 key pair for node SSH access. Empty launches nodes with no key (SSM/console access only)."
  type        = string
  default     = ""
}

variable "enable_ssh" {
  description = "Open port 22 on the node security group to ssh_ingress_cidr. Only useful alongside key_name."
  type        = bool
  default     = false
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH in when enable_ssh is true. Empty auto-detects the caller's public IP as a /32."
  type        = string
  default     = ""
}

variable "namespace" {
  description = "Kubernetes namespace for etcd, the EtcFS daemon set and the CSI driver."
  type        = string
  default     = "etcfs"
}

variable "mount_path" {
  description = "Host path the EtcFS daemon mounts the filesystem at, and the path CSI volumes are subdirectories of. Must match across the daemon set and the CSI chart, which is why both read this one variable."
  type        = string
  default     = "/mnt/etcfs"
}

variable "lease_ttl" {
  type    = string
  default = "10s"
}

variable "etcd_image" {
  type    = string
  default = "quay.io/coreos/etcd:v3.5.18"
}

variable "etcfuse_meta_image" {
  description = "Built from deploy/docker/Dockerfile.etcfuse-meta. No public default — every user's registry differs; see the module README for the build/push commands."
  type        = string
}

variable "etcfuse_image" {
  description = "Built from deploy/docker/Dockerfile.etcfuse."
  type        = string
}

variable "csi_image_repository" {
  description = "Built from deploy/docker/Dockerfile.etcfs-csi."
  type        = string
}

variable "csi_image_tag" {
  type = string
}

variable "csi_driver_name" {
  type    = string
  default = "csi.etcfs.io"
}

variable "storage_class_name" {
  type    = string
  default = "etcfs"
}
