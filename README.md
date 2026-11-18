# Outpost on AWS ECS

This standalone module deploys Outpost on AWS ECS. It owns exact
installation-named task roles, a separate image/log execution role, private worker
services, native service scaling, local logs/alarms/dashboard, and optionally a new
cluster, one on-demand EC2 capacity provider/ASG per role, and persistent Redis.
The exporter uses fixed-size Fargate capacity independently of scan instances.

Scan roles can use the built-in Fargate capacity provider or EC2 capacity. The
examples start with activation disabled.

## Call and ownership

Use Terraform >=1.11 and AWS provider >=6.71,<7.0. Provider 6.71 was checked with
Terraform 1.13.4 and OpenTofu 1.13.2 in separate provider/lock contexts. Both provider handles must be mapped explicitly:

```hcl
module "ecs" {
  source    = "assets.relyance.ai/relyance/ecs/aws"
  version   = "0.1.1"
  providers = { aws = aws, aws.secrets = aws }
  installation_facts = jsondecode(file("installation.json"))
  vpc_id = var.vpc_id
  private_subnet_ids = var.private_subnet_ids
  capacity = var.capacity
  exporter_redis_secret_arn = var.exporter_redis_secret_arn
  activated = false
}
```

`installation_facts` is the nonsecret installation-v1 contract: exact deployment,
project, route revision, cluster ARN, subscription/queue/region facts, custom S3
names and prefixes, distinct per-role task ARNs/GSAs, externally configured AWS
issuer, WIF provider/audience and immutable image digests. Pass supported-registration
validated facts; this module does not register identities or guess the account issuer.
Task-role ARN basenames must be `<deployment>-<role>` and describe **new
module-owned roles**, without IAM paths.
Do not pass existing roles managed by another state. The hosted identity module
consumes these exact role ARNs and creates no customer AWS roles.

`activated=false` is the default. All services bootstrap at zero, scaling in/out
and scheduled scaling are suspended, and step-alarm actions are disabled.
Activation sets only the exporter to one; positive valid observations wake workers.
Worker desired counts are owned by native scaling after creation and ignored by
Terraform. Task definitions, images and configuration remain tracked. **Holding an
already-active deployment suspends scaling; it does not forcibly reduce ignored
worker desired counts.** Stop new admission and reconcile/drain accepted work
before an authorized operator changes service counts. Do not delete Redis or
accepted-route state as rollback cleanup.

### Image registry access before activation

Apply the initial installation with `activated=false` to create its dedicated
`<deployment>-ecs-execution` IAM role. Read the `task_execution_role_arn` module
output and provide that exact ARN for the existing hosted Relyance ECR reader
onboarding. The execution role pulls images. Scope its access to the required
image repositories. Alternatively, use an approved customer-owned registry mirror
in the installation facts. Verify an actual image pull as the new execution role before setting
`activated=true`.

### Fargate

Use `examples/ecs-fargate` from the module archive with the supplied installation facts and
`capacity_provider = "FARGATE"` for each enabled scan role. Omit `capacity` for
Fargate roles. An existing cluster must already have `FARGATE` associated.
Worker CPU and memory must be a valid Linux Fargate pairing. The UAT task
layout used 8192 CPU units, 49152 MiB of memory, and 100 GiB of ephemeral storage.
Set `fargate_ephemeral_storage_gib` to size the full task allocation, including
image layers and the worker's scratch allocation.

Each task starts a nonessential initializer from its pinned worker image to
set ownership on the `/scratch` mount. The worker uses its configured nonroot
UID/GID, the existing ECS runtime bootstrap, and the same task role, Redis, and
Pub/Sub settings. The worker starts only after initialization succeeds. Fargate
uses platform 1.4.0, a 120-second stop timeout, and a 90-second worker drain
budget. The managed scaling policies use the same backlog signals as EC2.

### EC2

The new-capacity example owns a new cluster-wide provider association. An existing
cluster must set `create_cluster=false` and
`manage_cluster_capacity_association=false`: its external owner retains the entire
association, existing ASGs and all unrelated providers. Before activation that owner
must associate every supplied/created role provider. This module never adopts or
resizes a customer provider. Supply its exact name and a reviewed per-role reservation
proof with enough reserved tasks, independent child capacity and zero bootstrap.
Blanket pool size or current free capacity is insufficient proof.

Each owned role uses one reviewed ECS-optimized AL2023 x86_64 AMI and instance type. The exact AMI
metadata must report x86_64/EBS, the instance type must admit x86_64, and its
AMI owner must be Amazon or the customer account.
Fit uses provider-reported vCPU, memory and ENI limits, reserving 1 vCPU/1GiB and
one ENI for the host, plus 30GiB OS disk and per-task scratch. Owned services use
`distinctInstance` to enforce one task per instance, so the ASG maximum covers the
role maximum without assuming scheduler CPU reserves. This is a conservative
capacity/cost baseline. ASG maximum
must fit the whole role maximum and be at least two for ECS zero-instance bootstrap.
Min/desired ASG size is zero, with ASG instance protection, provider managed
termination protection and managed draining. This is static placement/capacity
validation; regional offerings, quotas and real placement remain qualification gates.

`runtime_users` supplies each worker image's verified nonroot `{uid,gid}`, default
65532:65532; images must precreate `/scratch` with that owner for Docker volume
copy-up. The exporter image uses 10001:10001. Each EC2 task gets a task-scoped local
scratch volume, `TMPDIR=/scratch`, wrapper entrypoint, role argument, both true GAI
job flags, `runtime_mode=inhost`, installation facts and a 540-second drain budget.
Workers require the pinned modern AWS SDK interpreter at `/opt/inhost-aws/bin/python`
through `INHOST_AWS_PYTHON`; the exporter does not receive this setting.
Agent and task stop timeout are both 600 seconds. Task-role metadata, not EC2
instance identity, supplies short-lived federation. Image user/scratch, agent timeout,
actual task protection and custody through forced termination require native acceptance.

The optional sixth role `inventory-notification` runs the sampler image on its
separate Pub/Sub source with `GAI_PUBSUB_TOPIC_ID=data-pipelines-notification-gai`.
It has its own service, demand metric, task identity and capacity provider and
requires enabled `sampler-worker` capacity; it does not require the sampler
coordinator. It is enabled only for workflows whose finalizer publishes that
notification route. Existing five-role installations remain valid. Verify the exact
connector/workflow admission and notification path before making any parity claim.

Worker task definitions derive `IDENTITY_SERVICE_WORKLOAD_AUDIENCE` as
`int://identity/workloads/<deployment>/<role>` to match the hosted Identity
registration.

`application_environment` carries existing nonsecret application settings by role,
including approved API origins and the actual registered `GAI_NOTIFICATION_TENANT`
slug. Activation requires that slug for every enabled GAI role; it must never be
derived from the Identity tenant record ID. Runtime authority, credential keys,
inline JWTs/private keys and credential-bearing URLs are rejected. Sampler always
uses `GAI_PUBSUB_TOPIC_ID=gai-pipelines-gai-sampler`; the unsafe `all` default is
excluded. Native startup must still qualify all released app settings, credentials,
notification topics/subscriptions and downstream route ownership. Supplying a map
is not evidence that those application contracts converge.

Set `application_environment.data-pipelines.DP_AWS_QUERY_REGIONS` to `us-east-1`
or a comma-separated list of distinct AWS region names to bound the existing
Data Pipelines regional queries. The runtime freezes this scope with each new
inventory catalogue and rejects a different scope when replaying accepted work.
The accepted root continues to determine the resource catalogue.

## Redis and private networking

Provisioning defaults to nonclustered Redis7.1, primary/replica, Multi-AZ automatic
failover, TLS required, encryption at rest, seven-day snapshots and prevent_destroy.
Credentials must already exist in **two distinct** Secrets Manager secrets, encoded
as JSON `{ "username": "...", "password": "..." }`. Worker username defaults to
`inhost-workers`, exporter to `inhost-exporter`; configured user names and secret
usernames must match. Never supply credential values through Terraform variables.
The `aws.secrets` alias performs ephemeral reads and feeds write-only Redis password
arguments; secret values are excluded from plans/state/outputs/task JSON. Increment
`redis_auth_secret_version` only during a reviewed rotation. Runtime refresh/reconnect
and active-claim rotation must be qualified separately.

The worker ACL supports broker/coordination operations. Exporter ACL permits only
exact configured waiting-queue counter reads and deployment lifecycle metadata reads,
with no queue mutation, EVAL, pull or ACK. It receives only its separate ACL secret;
worker/source secret grants cannot reach the exporter. Preserve logical DBs
0=broker, 1=results, 2=coordination/lifecycle, 3=DP state. Registry keys must use
`inhost-runtime:v1:<deployment>:*` and must never contain payloads/secrets.

For supplied Redis set `provision_redis=false`, `existing_redis_verified=true` and
`existing_redis_security_group_id`. The verification attests provisioned persistent
nonclustered Redis, Multi-AZ replica, verified TLS/auth, exact host/port and a separate
read-only exporter ACL secret. This module adds exact task-SG ingress/egress rules
on that explicitly supplied group. Serverless/cluster-mode targets are unsupported.
Redis remains available at zero scan workers.

Tasks never receive public IPs or inbound service ports. Subnet VPC, public-IP
mapping and two-AZ coverage are checked. Supply private routing/NAT/endpoints to
AWS, Google, Relyance and approved vendors. Outbound TLS defaults to 0.0.0.0/0;
`egress_cidrs` can restrict approved destinations. This is not a zero-egress claim.
No public ALB, external notification destination or customer-payload metric is created.
Customer source/bucket encryption policies and exact additional source-secret/KMS
references must be reviewed for the selected integration before activation. Supply
`store_kms_key_arns` for SSE-KMS work/findings/inventory/outbox stores; workers receive only exact
Decrypt/GenerateDataKey grants constrained to S3 and those store encryption contexts.
The bucket/key owner must admit the exact new task roles; no external owner policy
is silently adopted or rewritten. Exporter has no store-key access.

Exporter ECS reads are DescribeServices for exact services, ListTasks for the exact
cluster and DescribeTasks for exact cluster task ARNs tagged with this deployment.
ListTasks has no serviceName IAM condition; the collector must still filter the exact
configured serviceName and validate returned task membership. Service tags propagate
to tasks; workers' protection permissions are additionally restricted to their role.
These tag-based boundaries and account ECS long-ARN/tag settings require native
qualification before activation.

`source_role_arns` is an explicit worker-keyed map of reviewed source roles, for
example `data-pipelines = ["arn:aws:iam::222222222222:role/sources/InventoryReader"]`.
Each configured worker receives only `sts:AssumeRole` for its exact role set;
commercial cross-account ARNs and IAM paths are supported. Wildcards, malformed
ARNs, unknown worker keys and exporter entries are rejected, including empty
exporter sets. Unconfigured workers and exporter receive no source-role assumption
permission. The source role owner must independently admit the caller and preserve
the approved ExternalId/credential contract. An IAM allow does not prove the
source role's trust policy or actual source access; qualify those separately.

When Data Pipelines is enabled, installation facts must include both explicit
`inventory_store` and `outbox_store` S3Store objects. They remain optional for
non-DP installations. Each must retain the installation account/region and a
relative traversal-free prefix. The inventory store contains the canonical
catalogue and finalized inventory; the outbox store contains durable producer and
consumer journals/batches. Their exact bucket/prefix facts drive S3 object/list
permissions and SSE-KMS encryption contexts alongside work/findings stores. No
bucket suffix, work/findings substitution or derived storage prefix is used.
Existing stores remain externally owned, and exporter receives no store access.
Only analyzer and analyzer-worker receive `s3:DeleteObject`, restricted to
`gai_document_type_pending/*` beneath the exact findings prefix. This acknowledges
captured temporary sidecars after successful Delta materialization. Durable
findings, work/inventory/outbox, source data, and object versions gain no deletion
permission.

## Scaling and evidence limits

Each enabled role has zero minimum and an explicit maximum. Demand target tracking
uses Maximum, target1, scale-in disabled and cooldown60. Bootstrap adds1 after one
60s period; shrink removes1 after five; idle sets exact0 after two. All step policies
use cooldown120. Their alarms multiply `FILL(eligibility,0) * FILL(SnapshotValid,0) *
FILL(ExporterHeartbeat,0)` using current-period Minimum series and secondary
notBreaching missing handling. Missing exporter heartbeat is a health failure.
Backlog, demand and task counts are never filled with zero. The exporter must omit
invalid demand, publish health/eligibility at current evaluation time, require advancing
source timestamps for shrink/idle, and preserve unknown regional/count observations.

Native mock tests verify the infrastructure contract, including rejection of unproven
capacity. `tests/check_replan.py` exports only synthetic mock state, changes one
service count to two, and runs local refresh-disabled plans against a loopback-only
STS/subnet fixture. It checks ordinary replan count preservation and image-digest
replacement. It never loads customer state or calls cloud APIs. Terraform 1.13.4 cannot mock ephemeral resource types. Tests mock all
infrastructure while leaving the credential alias with **zero instances** using the
existing-Redis branch. They do not read any secret or provision a Redis instance.
Both examples validate the provisioned resource schema with provider aliases, but the
actual ephemeral-read/write-only credential path, Redis ACL behavior and rotation remain
explicit live qualification gaps. Standalone `terraform validate` in this aliased child
module reports missing provider configuration; validate it through the included wrappers.

CloudWatch historic-backfill behavior, actual exporter-crash alarms, protected rollouts,
job replacement costs, full workflow parity, end-to-end outputs and both termination
protection levels require separately authorized isolated acceptance. An expression test
cannot establish AWS alarm evaluation behavior or zero-cost idle.

Official references: [outbound federation policy conditions](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_outbound_policies.html),
[ECS capacity-provider behavior](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/cluster-auto-scaling.html),
[ECS IAM action/condition support](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecs.html),
[Terraform provider overrides](https://developer.hashicorp.com/terraform/language/tests/mocking).

Enabled Data Pipelines requires explicit `inventory_store` and `outbox_store`
with nonempty disjoint prefixes. Activation additionally requires the registered
slug in `application_environment["data-pipelines"].DP_TENANT`; held installations
may leave it pending. Bootstrap derives DP account, runtime, bucket, region,
project, topic and subscription settings from the validated facts. The module
rejects overrides of these settings (all `DP_` names except DP's `DP_TENANT` and `DP_AWS_QUERY_REGIONS`,
`GCP_PROJECT_ID`, `TENANT_BUCKET_PATH`, `TOPIC_NAME`, `WORKER_POOL`, and existing
reserved prefixes). `publish_topic_paths` must explicitly list each enabled
producer's execution-project topics; exporter publishing is forbidden.

For a versioned outbox, `enable_versioned_inventory_result_cleanup=true` pairs the
existing Data Pipelines runtime opt-in with `s3:DeleteObjectVersion` on only its
`__outbox__/root_run=*/results/.../batch=*.parquet` temporary result path. The
runtime deletes the captured non-null version only after commit/publication.
This permanently removes derived batch versions; source objects, inventory
Delta files and durable plans, journals and publication receipts are outside the
grant. The option defaults to false and requires an enabled Data Pipelines pool.
Qualify the exact version-deletion and retry behavior before enabling it.


`pubsub_global_zero_subscriptions` is a default-empty, exporter-only allowlist of
exact enabled Pub/Sub subscriptions. Opted-in routes may use a fresh explicit
`num_undelivered_messages=0` only after a complete successful regional read has
missing or stale coverage and no fresh regional backlog. This amends the regional
source contract explicitly; it never substitutes zero after an error or accepts a
positive global count. Invalid, foreign, conflicting, partial or capped reads
remain unknown. The exporter publishes `PubSubGlobalZeroConfirmed` provenance and
resets source-progress permission whenever the observation basis changes. Worker
facts, active-work accounting, registry completeness and native alarm periods stay
unchanged. Qualify both idle return and wake-up before customer activation.
