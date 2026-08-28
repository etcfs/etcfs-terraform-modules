# etcfs-terraform-modules

Terraform for provisioning [EtcFS](https://github.com/etcfs/etcfs) clusters
on AWS.

Split out of the main [etcfs/etcfs](https://github.com/etcfs/etcfs)
repository's `infra/` directory; commit history for these paths was
preserved in the split.

| Directory | What it is |
|---|---|
| [`terraform/`](terraform) | Reusable modules (`modules/etcfs-cluster`, `modules/etcfs-asg`, `modules/etcfs-eks`) plus a standalone EC2-only root module |
| [`terraform-asg/`](terraform-asg) | Standalone Auto Scaling Group root module |
| [`terraform-eks/`](terraform-eks) | Standalone EKS root module, wraps `terraform/modules/etcfs-eks` |

Each directory has its own `README.md` with usage details.

The node bootstrap every ASG instance runs on first boot lives at
[`terraform/modules/etcfs-asg/scripts/node-bootstrap.sh`](terraform/modules/etcfs-asg/scripts/node-bootstrap.sh).
It is plain bash configured through `ETCFS_*` environment variables, not a
Terraform template, so it can be linted, run directly against a test
instance, and reused by a launcher that is not Terraform — which is what
[etcfs-cloudformation](https://github.com/etcfs/etcfs-cloudformation) does.

## Prerequisite: the fencing instance profile

The `etcfs-nodes` IAM instance profile these modules reference (but don't
manage) is created once per AWS account by `scripts/infra/fencing-iam.sh` in
[etcfs/etcfs](https://github.com/etcfs/etcfs). See that repo for fencing
background.

## Images

The container images and, for the EKS module, the CSI driver's Helm chart
are built by CI in [etcfs/etcfs](https://github.com/etcfs/etcfs) and
[etcfs-csi-driver](https://github.com/etcfs/etcfs-csi-driver) respectively —
these modules only reference tags/versions, they don't build anything.
