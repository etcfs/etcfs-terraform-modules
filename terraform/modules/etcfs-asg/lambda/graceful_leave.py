"""Runs an etcd member remove for a node the ASG is about to terminate,
then completes the termination lifecycle hook so the ASG proceeds.

Triggered by an EventBridge rule on "EC2 Instance-terminate Lifecycle
Action" for one ASG. Without this, the ASG kills the instance outright:
etcd loses the member ungracefully, quorum math still works (self-fencing
and the generation guard both survive a bare crash), but the cluster is
left carrying a stale member entry until someone runs `member remove` by
hand, and a churn-heavy ASG (repeated scale in/out) accumulates dead
members that eventually cost quorum for real.

Uses SSM Run Command against a *surviving* peer, not the terminating
instance itself: by the time this fires the target may already be
unreachable, but any other running node can issue the etcd member remove.
"""
import boto3

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")
autoscaling = boto3.client("autoscaling")


def handler(event, context):
    detail = event["detail"]
    instance_id = detail["EC2InstanceId"]
    asg_name = detail["AutoScalingGroupName"]
    hook_name = detail["LifecycleHookName"]
    token = detail["LifecycleActionToken"]

    try:
        cluster_name, dying_ip = _lookup(instance_id)
        peer_id = _find_peer(cluster_name, instance_id)
        if peer_id and dying_ip:
            try:
                _remove_member(peer_id, dying_ip)
            except Exception as e:
                # The peer may not be SSM-registered yet (agent
                # registration lags instance boot by up to ~60s) or the
                # command may simply fail — either way this is best-effort:
                # the fencing/generation-guard path already makes an
                # ungraceful termination safe, this only saves the next
                # scrub pass from reporting a dangling member. Swallowing
                # here (instead of letting it propagate) also stops
                # Lambda's automatic retry from re-running the whole
                # handler against a lifecycle action the first attempt's
                # `finally` below already completed.
                print(f"member remove best-effort failed, continuing: {e}")
    finally:
        # Always complete the hook — a stuck lifecycle action blocks the
        # ASG from ever finishing termination, which is worse than a
        # dangling etcd member the next scrub/fsck pass will report.
        autoscaling.complete_lifecycle_action(
            LifecycleHookName=hook_name,
            AutoScalingGroupName=asg_name,
            LifecycleActionToken=token,
            InstanceId=instance_id,
            LifecycleActionResult="CONTINUE",
        )


def _lookup(instance_id):
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    inst = resp["Reservations"][0]["Instances"][0]
    tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
    return tags.get("ClusterName"), inst.get("PrivateIpAddress")


def _find_peer(cluster_name, dying_instance_id):
    resp = ec2.describe_instances(
        Filters=[
            {"Name": "tag:ClusterName", "Values": [cluster_name or ""]},
            {"Name": "tag:Role", "Values": ["etcfs-node"]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    for r in resp["Reservations"]:
        for i in r["Instances"]:
            if i["InstanceId"] != dying_instance_id:
                return i["InstanceId"]
    return None


def _remove_member(peer_instance_id, dying_ip):
    # member remove needs the member's hex ID, not its IP — resolve it on
    # the peer, in the same command, so there is only one round trip and
    # no ID goes stale between lookup and removal.
    script = f"""
set -e
MEMBER_ID=$(etcdctl --endpoints=http://127.0.0.1:2379 member list \
  | grep "{dying_ip}:2380" | cut -d, -f1)
if [ -n "$MEMBER_ID" ]; then
  etcdctl --endpoints=http://127.0.0.1:2379 member remove "$MEMBER_ID"
fi
"""
    resp = ssm.send_command(
        InstanceIds=[peer_instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": [script]},
        TimeoutSeconds=60,
    )
    ssm.get_waiter("command_executed").wait(
        CommandId=resp["Command"]["CommandId"],
        InstanceId=peer_instance_id,
    )
