output "asg_name" {
  value = module.asg.asg_name
}

output "volume_id" {
  value = module.asg.volume_id
}

output "sg_id" {
  value = module.asg.sg_id
}

output "graceful_leave_function_name" {
  value = module.asg.graceful_leave_function_name
}
