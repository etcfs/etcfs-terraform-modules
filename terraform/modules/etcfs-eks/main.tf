terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
  }
}

# ---- Discovery ----

data "aws_region" "current" {}

data "aws_vpc" "default" {
  default = true
}

# EKS requires the control plane's own subnets to span >= 2 AZs even though
# every node lands in one (io2 Multi-Attach is single-AZ, see the node
# subnet below) — this is purely to satisfy that control-plane requirement,
# nothing schedules onto the second AZ.
data "aws_subnets" "control_plane" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = var.control_plane_azs
  }
}

data "aws_subnet" "node" {
  id = var.node_subnet_id != "" ? var.node_subnet_id : data.aws_subnets.in_node_az.ids[0]
}

data "aws_subnets" "in_node_az" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = [var.node_az]
  }
}

# EKS-optimized AL2023 AMI. Self-managed (aws_instance), not a managed node
# group: a managed node group is backed by an ASG, whose instance IDs are not
# known to Terraform until after the ASG has launched them, which makes a
# declarative aws_volume_attachment to a *specific* instance impossible. This
# module needs the same io2 Multi-Attach volume on two named instances, the
# same way infra/terraform's EC2-only module does — so nodes are aws_instance
# resources here too, joined to the cluster by the same bootstrap.sh every
# EKS-optimized AMI ships, run from user_data instead of an ASG launch template.
data "aws_ami" "eks_node" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amazon-eks-node-al2023-x86_64-standard-${var.kubernetes_version}-*"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

data "http" "my_ip" {
  count = var.ssh_ingress_cidr == "" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  ssh_cidr = var.ssh_ingress_cidr != "" ? var.ssh_ingress_cidr : "${chomp(data.http.my_ip[0].response_body)}/32"

  # Fixed keys, not count: matches the EC2 module's reasoning — adding a node
  # must not renumber or replace nodes that already hold a membership lease
  # and an attached volume.
  node_keys = toset([for i in range(1, var.node_count + 1) : tostring(i)])

  tags = { ClusterName = var.cluster_name }
}

# ---- IAM: cluster and node roles ----
#
# Unlike infra/terraform's EC2 module, these are created here rather than
# referenced: an EKS cluster role and a node role are scoped to this cluster
# by name and torn down with it, not an account-wide permanent resource like
# the fencing instance profile that module deliberately leaves alone.

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-eks-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-eks-node"
  role = aws_iam_role.node.name
  tags = local.tags
}

# ---- Security groups ----

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-eks-cluster"
  description = "EKS control plane <-> node communication for ${var.cluster_name}"
  vpc_id      = data.aws_vpc.default.id
  tags        = merge(local.tags, { Name = "${var.cluster_name}-eks-cluster" })
}

resource "aws_vpc_security_group_ingress_rule" "node_to_cluster" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.node.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "nodes -> API server"
}

resource "aws_vpc_security_group_egress_rule" "cluster_all" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-eks-node"
  description = "EKS nodes for ${var.cluster_name}"
  vpc_id      = data.aws_vpc.default.id
  tags = merge(local.tags, {
    Name                                        = "${var.cluster_name}-eks-node"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

resource "aws_vpc_security_group_ingress_rule" "node_self" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
  description                  = "node <-> node (etcd, kubelet, CNI)"
}

resource "aws_vpc_security_group_ingress_rule" "cluster_to_node" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "-1"
  description                  = "API server -> kubelet"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count = var.enable_ssh ? 1 : 0

  security_group_id = aws_security_group.node.id
  cidr_ipv4         = local.ssh_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from the operator"
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---- EKS cluster ----

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = data.aws_subnets.control_plane.ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
  tags       = local.tags
}

# The default addons (vpc-cni, kube-proxy, coredns) an eksctl-created cluster
# gets automatically; a bare aws_eks_cluster gets none of them, and nodes
# cannot reach the API server or run pod networking without vpc-cni.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"
  depends_on   = [aws_eks_addon.vpc_cni]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"
  # coredns pods need a node to schedule onto.
  depends_on = [aws_instance.node]
}

# ---- Self-managed nodes ----
#
# bootstrap.sh (baked into the AL2023 EKS-optimized AMI) joins the instance
# to the cluster; nothing beyond that runs from user_data; the etcd, EtcFS
# daemon and CSI driver all deploy as ordinary Kubernetes workloads below,
# via the kubernetes/helm providers, once the nodes are ready.
resource "aws_instance" "node" {
  for_each = local.node_keys

  ami                         = data.aws_ami.eks_node.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.node.id
  vpc_security_group_ids      = [aws_security_group.node.id]
  iam_instance_profile        = aws_iam_instance_profile.node.name
  associate_public_ip_address = true
  key_name                    = var.key_name != "" ? var.key_name : null

  user_data = base64encode(templatefile("${path.module}/templates/bootstrap-node.sh.tpl", {
    cluster_name     = aws_eks_cluster.this.name
    cluster_endpoint = aws_eks_cluster.this.endpoint
    cluster_ca       = aws_eks_cluster.this.certificate_authority[0].data
  }))

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
  }

  tags = merge(local.tags, {
    Name                                        = "${var.cluster_name}-node-${each.key}"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })

  depends_on = [aws_eks_cluster.this]
}

# aws-auth ConfigMap: without this the nodes are IAM-authenticated to AWS but
# not authorized as Kubernetes nodes, and never go Ready. eksctl and managed
# node groups do this automatically; a self-managed group has to do it itself.
resource "kubernetes_config_map_v1_data" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode([{
      rolearn  = aws_iam_role.node.arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups   = ["system:bootstrappers", "system:nodes"]
    }])
  }

  force = true

  depends_on = [aws_eks_cluster.this]
}

# ---- Shared raw EBS volume (io2 Multi-Attach) ----
#
# Same reasoning as infra/terraform's EC2 module: self-managed nodes give
# Terraform stable instance IDs, so the attachment is declarative here too,
# rather than the manual "query instance IDs after apply, attach by hand"
# step the eksctl-based validation run needed.

resource "aws_ebs_volume" "shared" {
  availability_zone    = var.node_az
  type                 = "io2"
  size                 = var.volume_size_gb
  iops                 = var.volume_iops
  multi_attach_enabled = true

  tags = merge(local.tags, { Name = "${var.cluster_name}-data" })
}

resource "aws_volume_attachment" "shared" {
  for_each = aws_instance.node

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.shared.id
  instance_id = each.value.id

  # See the EC2 module's identical setting: the volume is never formatted, and
  # destroy must not block on a daemon still holding the device open.
  force_detach = true
}
