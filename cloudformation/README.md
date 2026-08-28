# CloudFormation

`etcfs-asg.yaml` provisions the same cluster
[`terraform/modules/etcfs-asg`](../terraform/modules/etcfs-asg) does — shared
io2 Multi-Attach volume, seed-election table, launch template, Auto Scaling
Group — for stacks that deploy with CloudFormation rather than Terraform.

## How the join protocol stays single-sourced

The template does not contain a copy of the node bootstrap. Its user-data is
a short shim that:

1. downloads `terraform/modules/etcfs-asg/templates/user-data.sh.tftpl` from
   GitHub at the ref given by `UserDataRef`,
2. renders it — Terraform's `templatefile()` syntax, so `${name}` is
   substituted from the stack's parameters and `$${` becomes a literal `${`
   the shell keeps,
3. runs the result.

Everything that decides how a node joins — the DynamoDB conditional-write
seed election, `etcd member add` against the elected seed, clearing a crashed
node's member entry before adding a replacement, writing
`/etc/etcfs/etcfuse-meta.yaml` — therefore has exactly one implementation,
shared by both deployment paths. A second copy in this template would be a
second thing to keep in step, and the discovery logic is the part where
divergence is most expensive.

`UserDataRef` defaults to `main`, which re-renders whatever is on that branch
at each instance launch. Pin it to a tag for a reproducible stack.

## Prerequisites

The `etcfs-nodes` instance profile, created once per account by
`scripts/infra/fencing-iam.sh` in [etcfs/etcfs](https://github.com/etcfs/etcfs).
It needs the fencing EC2 permissions, `dynamodb:PutItem`/`GetItem` on
`*-etcfs-seed`, and `AmazonSSMManagedInstanceCore`.

## Usage

```bash
aws cloudformation deploy \
  --template-file cloudformation/etcfs-asg.yaml \
  --stack-name etcfs \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      ClusterName=etcfuse \
      AvailabilityZone=eu-west-1a \
      SubnetId=subnet-0abc \
      VpcId=vpc-0abc \
      KeyName=my-key
```

Scale by changing `DesiredCapacity`, or directly:

```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name etcfuse-asg --desired-capacity 4
```

## What this does not have

**The graceful-leave Lambda.** The Terraform module wires an
`EC2_INSTANCE_TERMINATING` lifecycle hook to a Lambda that runs
`etcd member remove` on a surviving peer before an instance goes away; that
function's source is too long to inline in a template, and shipping it here
as an S3 artifact would mean a build step this stack otherwise does not have.

Scale-in is still safe without it — EtcFS fences a node that disappears, and
every joining node clears etcd members with no live instance before adding
itself. What is lost is the cleanup's timing: a dead member stays registered
until the *next* node joins, so a cluster that repeatedly scales in without
ever scaling back out accumulates dead members. Use the Terraform module, or
add the hook to this stack, where that pattern is expected.
