# EtcFS Terraform module

Declarative replacement for `scripts/infra/create-infra.sh` and
`destroy-infra.sh`. It provisions the infrastructure an EtcFS cluster runs
on and nothing else:

| Resource | Replaces |
|---|---|
| `aws_key_pair` | key import in `create-infra.sh` |
| `aws_security_group` + rules | SG creation in `create-infra.sh` |
| `aws_ebs_volume` (io2, Multi-Attach) | shared raw device |
| `aws_instance` (× `node_count`) | compute nodes, etcd colocated |
| `aws_volume_attachment` | `attach-volume` loop |

## Prerequisite: the fencing instance profile

Run this once per AWS account, before the first apply:

```bash
./scripts/infra/fencing-iam.sh create
```

The module *references* the resulting `etcfs-nodes` instance profile, it does
not manage it. That role is account-wide and outlives any single cluster by
design, and managing it here would demand `iam:CreateRole`, `iam:TagRole` and
`iam:ListRolePolicies` — a strictly larger permission set than provisioning
the cluster otherwise needs, which an EC2-provisioning identity often does
not have.

Without the profile the daemon degrades to single-signal fencing: it stops a
fenced node publishing metadata, it does not stop it writing bytes to the
device.

## What it deliberately does not do

Node software — etcd, both EtcFS binaries, starting the daemons — stays in
`scripts/infra/bootstrap-cluster.sh`. Those steps are ordered and imperative
(etcd up before the daemon; `etcd member add` before a joining node starts),
and expressing them as Terraform provisioners would re-create the
"re-run against a partially-up cluster" bug class that script's header
documents having already been fixed once.

## Usage

```bash
# everything: apply, export state, bootstrap the cluster software
./scripts/infra/tf-up.sh

# infra only
./scripts/infra/tf-up.sh --no-bootstrap

# override any variable
./scripts/infra/tf-up.sh -- -var node_count=5 -var instance_type=t3.large

# teardown
terraform -chdir=infra/terraform destroy
```

Or drive Terraform directly and hand off manually:

```bash
terraform -chdir=infra/terraform init
terraform -chdir=infra/terraform apply
./scripts/infra/tf-export-state.sh          # -> infra-state.json
./scripts/infra/bootstrap-cluster.sh infra-state.json
./scripts/infra/run-full-test.sh
```

`tf-export-state.sh` writes `infra-state.json` in exactly the shape
`scripts/infra/state.sh` reads, so `setup-compute.sh`, `run-full-test.sh`,
`benchmark.sh` and the chaos scripts all work unchanged against a
Terraform-provisioned cluster.

## Coexistence with the bash path

Every name is cluster-scoped (`<cluster_name>-key`, `<cluster_name>-sg`), so a Terraform cluster never adopts or deletes the
account-wide `etcfuse-keypair` that `create-infra.sh` imports. Run both paths
at once by giving them different `cluster_name` values. The `etcfs-nodes`
instance profile is the one thing shared with the bash path, read-only.

## State

Local backend (`infra/terraform/terraform.tfstate`), gitignored. A remote
backend only earns its keys once more than one person applies against the
same cluster.

## Adding a node

`node_count` drives a `for_each` over fixed numeric keys, not `count`, so
raising it adds nodes without renumbering or replacing the existing ones.
Terraform brings up the instance and attaches the volume; the new node still
has to *join* etcd, which is `scripts/infra/add-compute-node.sh`'s
`etcd member add` path.
