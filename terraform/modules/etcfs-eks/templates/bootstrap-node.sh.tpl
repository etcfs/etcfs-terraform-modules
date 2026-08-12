#!/bin/bash
# Joins this instance to ${cluster_name}. /etc/eks/bootstrap.sh ships on every
# EKS-optimized AMI; a managed node group's launch template runs the same
# script, this just runs it from user_data instead since these are plain
# aws_instance resources, not an ASG.
set -euo pipefail

/etc/eks/bootstrap.sh ${cluster_name} \
  --b64-cluster-ca ${cluster_ca} \
  --apiserver-endpoint ${cluster_endpoint}
