output "asg_name" {
  value = aws_autoscaling_group.this.name
}

output "volume_id" {
  value = aws_ebs_volume.shared.id
}

output "sg_id" {
  value = aws_security_group.this.id
}

output "launch_template_id" {
  value = aws_launch_template.node.id
}

output "graceful_leave_function_name" {
  value = aws_lambda_function.graceful_leave.function_name
}
