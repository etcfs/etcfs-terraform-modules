# EtcFS on EKS — Terraform

Provisions a complete, working EtcFS-on-Kubernetes cluster in one
`terraform apply`: EKS control plane, worker nodes, a shared io2
Multi-Attach EBS volume, EtcFS's own etcd and daemon pair, and the CSI
driver — the same stack validated by hand in
[`docs/reports/csi-reports/2026-08-12-eks-csi-driver-validation.md`](../../docs/reports/csi-reports/2026-08-12-eks-csi-driver-validation.md),
reproducible here without the manual `eksctl`/`kubectl`/`helm` sequence that
report describes.

This is a separate root module from [`infra/terraform`](../terraform)
(the EC2-only EtcFS cluster), not an option on it: the two are different
deployment shapes — one runs EtcFS directly on EC2 instances, the other runs
it as Kubernetes workloads behind the CSI driver — and nothing is shared
between their states.

## Prerequisites

1. **AWS credentials** with permission for EKS, EC2, IAM (cluster/node role
   creation, scoped to `<cluster_name>-eks-*`), and ECR if you build images
   through step 2.
2. **Docker**, to build the three images this module deploys.
3. **Terraform >= 1.5.**

## Usage

```bash
# 1. Build and push etcfuse-meta, etcfuse and etcfs-csi to ECR, and print
#    the image -var flags the next step needs.
./scripts/infra/eks-build-push.sh

# 2. Provision everything: cluster, nodes, volume, EtcFS, CSI driver.
terraform -chdir=infra/terraform-eks init
terraform -chdir=infra/terraform-eks apply \
  -var etcfuse_meta_image=<from step 1> \
  -var etcfuse_image=<from step 1> \
  -var csi_image_repository=<from step 1> \
  -var csi_image_tag=<from step 1>

# 3. Point kubectl/helm at it.
$(terraform -chdir=infra/terraform-eks output -raw kubeconfig_command)
kubectl -n etcfs get pods

# 4. Try it: dynamic provisioning, two pods on two nodes writing to one
#    shared RWX volume.
kubectl -n etcfs apply -f csi/examples/dynamic-provisioning.yaml
kubectl -n etcfs get pvc etcfs-shared
kubectl -n etcfs logs -l app=etcfs-writer --prefix --tail=20

# Teardown, in order — the shared volume and node instances must go before
# the cluster they're attached to and joined to, which `terraform destroy`
# handles automatically via its dependency graph:
terraform -chdir=infra/terraform-eks destroy
```

Override any variable the same way — instance type, node count, region,
mount path. See
[`infra/terraform/modules/etcfs-eks/variables.tf`](../terraform/modules/etcfs-eks/variables.tf)
for the full list, or `infra/terraform-eks/variables.tf` for the subset this
root module exposes with its own defaults.

## Cost

An EKS control plane bills hourly regardless of node count
(`$0.10`/hour at the time of writing), plus the worker node instances and
the io2 volume's provisioned IOPS. Nothing here is sized for a permanent
deployment — `node_count = 2`, a 4 GiB volume at 100 IOPS, `t3.medium`
nodes — this is a validation environment, not a production sizing
recommendation. `terraform destroy` when done; nothing in this module
retains state that outlives the cluster the way `infra/terraform`'s
`etcfs-nodes` IAM profile deliberately does.
