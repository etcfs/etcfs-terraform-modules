output "compute_public_ips" {
  value = module.cluster.compute_public_ips
}

output "compute_ips" {
  value = module.cluster.compute_ips
}

output "compute_instance_ids" {
  value = module.cluster.compute_instance_ids
}

output "volume_id" {
  value = module.cluster.volume_id
}

# Consumed by scripts/infra/tf-export-state.sh, which writes it straight to
# infra-state.json for the existing bash tooling.
output "infra_state" {
  value = module.cluster.infra_state
}
