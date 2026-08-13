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
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

# ---- Discovery (same pattern as modules/etcfs-cluster) ----

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

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

data "http" "my_ip" {
  count = var.ssh_ingress_cidr == "" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  ssh_cidr = var.ssh_ingress_cidr != "" ? var.ssh_ingress_cidr : "${chomp(data.http.my_ip[0].response_body)}/32"
  key_name = var.key_name != "" ? var.key_name : "${var.cluster_name}-key"
  tags     = { ClusterName = var.cluster_name }
}

# ---- Key pair + security group (same shape as modules/etcfs-cluster) ----

resource "aws_key_pair" "this" {
  key_name   = local.key_name
  public_key = file(pathexpand(var.public_key_path))
  tags       = local.tags
}

resource "aws_security_group" "this" {
  name        = "${var.cluster_name}-asg-sg"
  description = "EtcFS ASG cluster ${var.cluster_name}"
  vpc_id      = data.aws_vpc.default.id
  tags        = merge(local.tags, { Name = "${var.cluster_name}-asg-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = local.ssh_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from the operator"
}

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

data "aws_iam_instance_profile" "node" {
  name = var.instance_profile
}

# ---- Shared raw EBS volume (io2 Multi-Attach) ----
# Nodes attach themselves in user-data — Multi-Attach allows concurrent
# attachment from every instance in the ASG, no operator step required.

resource "aws_ebs_volume" "shared" {
  availability_zone    = var.az
  type                 = "io2"
  size                 = var.volume_size_gb
  iops                 = var.volume_iops
  multi_attach_enabled = true

  tags = merge(local.tags, { Name = "${var.cluster_name}-data" })
}

# ---- Launch template ----

resource "aws_launch_template" "node" {
  name_prefix   = "${var.cluster_name}-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.this.key_name

  iam_instance_profile {
    name = data.aws_iam_instance_profile.node.name
  }

  vpc_security_group_ids = [aws_security_group.this.id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.root_volume_size_gb
      volume_type = "gp3"
    }
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only — user-data's imds() helper depends on it
    http_endpoint = "enabled"
  }

  user_data = base64encode(templatefile("${path.module}/templates/user-data.sh.tftpl", {
    cluster_name  = var.cluster_name
    region        = data.aws_region.current.region
    volume_id     = aws_ebs_volume.shared.id
    etcfs_version = var.etcfs_version
    etcd_version  = var.etcd_version
    lease_ttl     = var.lease_ttl
    github_repo   = var.github_repo
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Role = "etcfs-node" })
  }

  tags = local.tags
}

# ---- Auto Scaling Group ----
# Single AZ, matching the shared volume — Multi-Attach is AZ-scoped, so
# spreading the ASG across AZs would launch nodes that can never attach it.

resource "aws_autoscaling_group" "this" {
  name                = "${var.cluster_name}-asg"
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity
  vpc_zone_identifier = [data.aws_subnet.selected.id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.node.id
    version = "$Latest"
  }

  tag {
    key                 = "ClusterName"
    value               = var.cluster_name
    propagate_at_launch = true
  }
  tag {
    key                 = "Role"
    value               = "etcfs-node"
    propagate_at_launch = true
  }
  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-asg-node"
    propagate_at_launch = true
  }

  # No CREATE-side wait: instances that are still bootstrapping (peer
  # discovery, etcd member add, mount) simply aren't healthy yet, and the
  # graceful-leave path only needs the TERMINATE-side hook below.
}

# ---- Graceful scale-in: etcd member remove before the ASG kills a node ----

resource "aws_autoscaling_lifecycle_hook" "terminating" {
  name                   = "${var.cluster_name}-graceful-leave"
  autoscaling_group_name = aws_autoscaling_group.this.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  default_result         = "CONTINUE" # if the Lambda ever fails to run, don't wedge the ASG
  heartbeat_timeout      = 180
}

data "archive_file" "graceful_leave" {
  type        = "zip"
  source_file = "${path.module}/lambda/graceful_leave.py"
  output_path = "${path.module}/lambda/graceful_leave.zip"
}

resource "aws_iam_role" "graceful_leave" {
  name = "${var.cluster_name}-graceful-leave"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "graceful_leave" {
  name = "${var.cluster_name}-graceful-leave"
  role = aws_iam_role.graceful_leave.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ASGHookCompletion"
        Effect   = "Allow"
        Action   = ["autoscaling:CompleteLifecycleAction"]
        Resource = "*"
      },
      {
        Sid      = "PeerLookup"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Sid      = "RunMemberRemove"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand", "ssm:GetCommandInvocation"]
        Resource = "*"
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
    ]
  })
}

resource "aws_lambda_function" "graceful_leave" {
  function_name    = "${var.cluster_name}-graceful-leave"
  role             = aws_iam_role.graceful_leave.arn
  runtime          = "python3.13"
  handler          = "graceful_leave.handler"
  filename         = data.archive_file.graceful_leave.output_path
  source_code_hash = data.archive_file.graceful_leave.output_base64sha256
  timeout          = 90
}

resource "aws_cloudwatch_event_rule" "terminating" {
  name = "${var.cluster_name}-asg-terminating"

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = ["EC2 Instance-terminate Lifecycle Action"]
    detail = {
      AutoScalingGroupName = [aws_autoscaling_group.this.name]
    }
  })
}

resource "aws_cloudwatch_event_target" "terminating" {
  rule = aws_cloudwatch_event_rule.terminating.name
  arn  = aws_lambda_function.graceful_leave.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.graceful_leave.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.terminating.arn
}
