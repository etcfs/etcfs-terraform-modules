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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

# ---- Discovery: the same lookups state.sh's discover_* helpers do ----

data "aws_region" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "selected" {
  id = var.subnet_id != "" ? var.subnet_id : data.aws_subnets.in_az.ids[0]
}

data "aws_subnets" "in_az" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = [var.az]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# Mirrors create-infra.sh's `curl https://checkip.amazonaws.com` so a plain
# apply doesn't default to opening port 22 to the whole internet.
data "http" "my_ip" {
  count = var.ssh_ingress_cidr == "" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  ssh_cidr = var.ssh_ingress_cidr != "" ? var.ssh_ingress_cidr : "${chomp(data.http.my_ip[0].response_body)}/32"

  key_name = var.key_name != "" ? var.key_name : "${var.cluster_name}-key"

  # for_each over fixed keys, not count: adding a node then must not renumber
  # or replace the instances that already exist and hold etcd membership.
  node_keys = toset([for i in range(1, var.node_count + 1) : tostring(i)])

  tags = {
    ClusterName = var.cluster_name
  }
}

# ---- Key pair ----

resource "aws_key_pair" "this" {
  key_name   = local.key_name
  public_key = file(pathexpand(var.public_key_path))
  tags       = local.tags
}

# ---- Security group ----

resource "aws_security_group" "this" {
  name        = "${var.cluster_name}-sg"
  description = "EtcFS cluster ${var.cluster_name}"
  vpc_id      = data.aws_vpc.default.id
  tags        = merge(local.tags, { Name = "${var.cluster_name}-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = local.ssh_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from the operator"
}

# etcd client (2379) and peer (2380), plus the metrics ports create-infra.sh
# opened, all restricted to members of this same security group.
resource "aws_vpc_security_group_ingress_rule" "intra" {
  for_each = toset(["2379", "2380", "9090", "9100"])

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = aws_security_group.this.id
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
  ip_protocol                  = "tcp"
  description                  = "intra-cluster tcp/${each.key}"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "all egress"
}

# ---- IAM: the fencing role, per-cluster ----
#
# fencing-iam.sh creates one permanent account-wide role named "etcfs-nodes"
# shared by every bash-provisioned cluster. This module names its role after
# the cluster instead, so a Terraform-managed cluster owns its own role and
# can be destroyed without touching a cluster the scripts provisioned.
#
# Without these permissions the daemon degrades to single-signal fencing
# (generation bump on lease expiry, no detach) — that stops a fenced node
# publishing metadata, it does not stop it writing bytes to the device.

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "node" {
  statement {
    sid       = "FencingDetachReattach"
    actions   = ["ec2:DetachVolume", "ec2:AttachVolume"]
    resources = ["arn:aws:ec2:*:*:volume/*", "arn:aws:ec2:*:*:instance/*"]
  }

  # AWS supports no resource-level permissions for these Describe* actions,
  # so "*" is an API limitation rather than a choice. All read-only.
  statement {
    sid = "VolumeAndPeerVisibility"
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeVolumeStatus",
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-nodes"
  description        = "EtcFS node role (fencing detach/reattach, peer visibility)"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "node" {
  name   = "etcfs-node-permissions"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node.json
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-nodes"
  role = aws_iam_role.node.name
  tags = local.tags
}

# IAM is eventually consistent: RunInstances rejects a profile whose role
# attachment just landed, with a confusing "Invalid IAM Instance Profile
# name". fencing-iam.sh sleeps 10s for the same reason.
resource "time_sleep" "iam_propagation" {
  depends_on      = [aws_iam_instance_profile.node]
  create_duration = "15s"
}

# ---- Shared raw EBS volume (io2 Multi-Attach, never formatted) ----

resource "aws_ebs_volume" "shared" {
  availability_zone    = var.az
  type                 = "io2"
  size                 = var.volume_size_gb
  iops                 = var.volume_iops
  multi_attach_enabled = true

  tags = merge(local.tags, { Name = "${var.cluster_name}-data" })
}

# ---- Compute nodes (etcd colocated) ----

resource "aws_instance" "compute" {
  for_each = local.node_keys

  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.this.key_name
  subnet_id                   = data.aws_subnet.selected.id
  vpc_security_group_ids      = [aws_security_group.this.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.node.name

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
  }

  tags = merge(local.tags, { Name = "${var.cluster_name}-compute-${each.key}" })

  depends_on = [time_sleep.iam_propagation]
}

resource "aws_volume_attachment" "shared" {
  for_each = aws_instance.compute

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.shared.id
  instance_id = each.value.id

  # The volume is a raw block device with no filesystem to leave dirty, and
  # the fencing tests deliberately detach it out from under a running daemon
  # anyway. Without this, destroy blocks on a node whose daemon still holds
  # the device open.
  force_detach = true
}
