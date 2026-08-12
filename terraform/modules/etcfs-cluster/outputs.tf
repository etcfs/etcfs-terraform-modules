# Node ordering is derived from the numeric key, not from sort() over the
# for_each keys — string-sorting "1","2","10" would put node 10 second and
# scramble the etcd node-ID assignment bootstrap-cluster.sh derives from
# list position.
locals {
  ordered_nodes = [for i in range(1, var.node_count + 1) : aws_instance.compute[tostring(i)]]
}

output "compute_instance_ids" {
  value = [for n in local.ordered_nodes : n.id]
}

output "compute_ips" {
  description = "Private IPs, in node order."
  value       = [for n in local.ordered_nodes : n.private_ip]
}

output "compute_public_ips" {
  value = [for n in local.ordered_nodes : n.public_ip]
}

output "volume_id" {
  value = aws_ebs_volume.shared.id
}

output "sg_id" {
  value = aws_security_group.this.id
}

output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "subnet_id" {
  value = data.aws_subnet.selected.id
}

output "ami_id" {
  value = data.aws_ami.al2023.id
}

output "instance_profile" {
  value = aws_iam_instance_profile.node.name
}

# The full state file the existing bash tooling reads (scripts/infra/state.sh
# and everything sourcing it). Emitted by the module so `terraform output
# -raw infra_state > infra-state.json` is the whole handoff — see
# scripts/infra/tf-export-state.sh.
output "infra_state" {
  value = jsonencode({
    cluster_name         = var.cluster_name
    region               = data.aws_region.current.region
    az                   = var.az
    key_name             = aws_key_pair.this.key_name
    vpc_id               = data.aws_vpc.default.id
    sg_id                = aws_security_group.this.id
    subnet_id            = data.aws_subnet.selected.id
    ami_id               = data.aws_ami.al2023.id
    volume_id            = aws_ebs_volume.shared.id
    compute_ips          = [for n in local.ordered_nodes : n.private_ip]
    compute_public_ips   = [for n in local.ordered_nodes : n.public_ip]
    compute_instance_ids = [for n in local.ordered_nodes : n.id]
    etcd_endpoints       = join(",", [for n in local.ordered_nodes : "http://${n.private_ip}:2379"])
    created_at           = timestamp()
  })
}
