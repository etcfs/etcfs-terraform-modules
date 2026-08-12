output "cluster_name" {
  value = module.eks.cluster_name
}

output "kubeconfig_command" {
  value = module.eks.kubeconfig_command
}

output "volume_id" {
  value = module.eks.volume_id
}

output "storage_class_name" {
  value = module.eks.storage_class_name
}
