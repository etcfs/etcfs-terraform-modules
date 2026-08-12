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

# ---- IAM: the fencing instance profile ----
#
# Referenced, not created. fencing-iam.sh creates one permanent, account-wide
# role and instance profile named "etcfs-nodes" that every EtcFS node runs
# under, deliberately outside any cluster's lifecycle so tearing a cluster
# down never revokes it.
#
# Managing it here instead would mean this module needs iam:CreateRole,
# iam:TagRole, iam:ListRolePolicies and friends. That is a strictly larger
# permission set than provisioning the cluster otherwise requires, for a
# resource that by design outlives the cluster — and an identity that can
# create EC2 instances routinely cannot write IAM at all. Hit exactly that
# on 2026-08-12: apply failed on iam:TagRole, then again on
# iam:ListRolePolicies, against an account where fencing-iam.sh had already
# put the working profile in place.
#
# Bootstrap it once per account with `./scripts/infra/fencing-iam.sh create`.
# Without it the daemon degrades to single-signal fencing (generation bump on
# lease expiry, no detach) — that stops a fenced node publishing metadata, it
# does not stop it writing bytes to the device.

data "aws_iam_instance_profile" "node" {
  name = var.instance_profile
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
  iam_instance_profile        = data.aws_iam_instance_profile.node.name

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
  }

  tags = merge(local.tags, { Name = "${var.cluster_name}-compute-${each.key}" })
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
