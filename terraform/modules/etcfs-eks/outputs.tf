output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca" {
  value     = aws_eks_cluster.this.certificate_authority[0].data
  sensitive = true
}

output "node_instance_ids" {
  value = [for k in sort(keys(aws_instance.node)) : aws_instance.node[k].id]
}

output "volume_id" {
  value = aws_ebs_volume.shared.id
}

output "kubeconfig_command" {
  description = "Run this to point kubectl/helm at the cluster this module created."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${data.aws_region.current.region}"
}

output "storage_class_name" {
  value = var.storage_class_name
}
