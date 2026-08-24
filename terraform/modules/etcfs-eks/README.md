# etcfs-eks Terraform module

Provisions an EKS cluster and everything EtcFS needs on it in one `apply`:
control plane, self-managed worker nodes joined to it, a shared io2
Multi-Attach EBS volume attached to every node, EtcFS's own etcd and daemon
pair, and the CSI driver installed via its Helm chart. This is the
Terraform equivalent of the manual `eksctl` + `kubectl` + `helm` sequence in
[`docs/reports/csi-reports/eks-csi-driver-validation.md`](../../../../docs/reports/csi-reports/eks-csi-driver-validation.md).

Use it via [`infra/terraform-eks/`](../../../terraform-eks), which wraps it
as a standalone root module with its own state — see that directory's
`README.md` for the usage walkthrough. This directory is the reusable
module; call it directly only if you are composing it into a larger
configuration.

## Why self-managed nodes, not a managed node group

A managed node group is backed by an Auto Scaling Group, whose instance IDs
are not known to Terraform until after the ASG has launched them — which
makes a declarative `aws_volume_attachment` to a *specific* instance
impossible. EtcFS needs the same io2 Multi-Attach volume on every node by
instance ID, the same requirement [`infra/terraform`](../../)'s EC2-only
module has, so nodes here are plain `aws_instance` resources too, joined to
the cluster with the same `/etc/eks/bootstrap.sh` a managed node group's
launch template would run, just invoked from `user_data` instead.

## What this module does not manage

- **Images.** `etcfuse_meta_image`, `etcfuse_image`, `csi_image_repository`
  and `csi_image_tag` are required variables with no default — a registry is
  account-specific. `scripts/infra/eks-build-push.sh` builds and pushes all
  three from this repository's own Dockerfiles and prints the `-var` flags.
- **The `etcfs-nodes` fencing IAM profile.** Unlike the EC2 module, this one
  does not reference it: an EKS node's fencing signal is the CSI driver's
  `ControllerUnpublishVolume` hook recording an intent for
  `pkg/fencing.Controller`'s sweep to act on (see
  [`docs/deployment/kubernetes-csi.md`](../../../../docs/deployment/kubernetes-csi.md)),
  not the node's own IAM role calling `DetachVolume` directly.
- **A remote Terraform backend.** Same reasoning as `infra/terraform`: local
  state until more than one person applies against the same cluster.

## Variables worth knowing before applying

| Variable | Default | Why it matters |
|---|---|---|
| `node_az` | `us-east-1a` | Every node and the shared volume live here — io2 Multi-Attach is single-AZ, not a per-node choice |
| `control_plane_azs` | `[us-east-1a, us-east-1b]` | EKS requires the control plane's own subnets to span >= 2 AZs even though nothing schedules onto the second one |
| `node_count` | `2` | Minimum to exercise cross-node RWX; Kubernetes owns pod placement here, so the EC2 module's etcd-quorum reasoning for 3 nodes does not carry over |
| `mount_path` | `/mnt/etcfs` | Read by both the daemon set and the CSI chart's `mountPath` — keep it one variable rather than setting it twice and having them drift |
| `enable_ssh` / `key_name` | `false` / `""` | Nodes launch with no SSH access by default; set both to debug via SSH instead of `kubectl exec` |

See `variables.tf` for the full list.

## Outputs

`cluster_name`, `cluster_endpoint`, `kubeconfig_command` (paste into a shell
to point `kubectl`/`helm` at the cluster), `node_instance_ids`, `volume_id`,
`storage_class_name`.
