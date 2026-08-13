# The AWS services this platform uses, and why

A reading guide, not a decision log. `docs/infrastructure.md` records *what was decided and what
breaks without it*; this file answers the prior question — **what is this service, why is it in
the design at all, and what would I have used instead?**

Written to be read in order the first time and dipped into afterwards. Every claim about this
platform is taken from the Terraform in this repository; every claim about AWS itself has a link
to Amazon's own documentation, because a summary written in 2026 will be wrong about pricing
before it is wrong about anything else.

> **Nothing here has been applied.** Costs are AWS list prices for `eu-central-1` at the time of
> writing, used to compare options rather than to predict a bill. The only authority on what this
> would cost is the [AWS Pricing Calculator](https://calculator.aws/).

---

## How to read this

The services are grouped by the layer they belong to, and the layers are ordered by how much
everything else depends on them. Network first, because every other service is placed inside it;
operations last, because it observes the rest.

| Layer | Services | Why it comes here |
|---|---|---|
| 1. Network | VPC, subnets, Internet Gateway, route tables, VPC endpoints, security groups, Cloud Map | Everything else is placed *inside* this |
| 2. Compute | ECR, ECS, Fargate, EFS | What actually runs the seven Spring Boot services |
| 3. Data | RDS PostgreSQL, ElastiCache Redis | The two stateful stores services own |
| 4. Edge | ALB, ACM, CloudFront, S3 | How a customer's browser reaches any of it |
| 5. Identity | IAM, Secrets Manager | Who may do what, and where the passwords live |
| 6. Operations | CloudWatch Logs, Container Insights, S3 (state) | Watching it, and remembering what exists |

**The single sentence that explains the whole design:** everything that holds data or runs
application code sits in a subnet with no route to the internet, and the only thing the internet
can talk to is a load balancer. Every service below is either enforcing that or working around it.

---

## The request path

```
                     ┌──────────────── the internet ────────────────┐
                     │                                              │
              browser│                                       browser│
                     ▼                                              ▼
         ┌───────────────────────┐                    ┌──────────────────────────┐
         │  CloudFront + ACM     │                    │  ALB + ACM (eu-central-1)│
         │  (storefront, global) │                    │  (api.<domain>)          │
         └───────────┬───────────┘                    └────────────┬─────────────┘
                     │ OAC / SigV4                                 │ :9000
                     ▼                                             ▼
         ┌───────────────────────┐               ┌──────────────────────────────┐
         │  S3 bucket (private)  │               │  gateway task (private subnet)│
         │  React build output   │               └────────────┬─────────────────┘
         └───────────────────────┘                            │ :9001-9006
                                                              ▼
                          ┌───────────────────────────────────────────────────┐
                          │  users · catalog · inventory · cart · orders ·     │
                          │  payments   —   ECS Fargate, private subnets       │
                          └───┬──────────────┬─────────────────┬──────────────┘
                              │              │                 │
                              ▼              ▼                 ▼
                     ┌────────────┐  ┌──────────────┐  ┌────────────────┐
                     │ RDS        │  │ ElastiCache  │  │ Kafka task     │
                     │ PostgreSQL │  │ Redis        │  │ + EFS          │
                     └────────────┘  └──────────────┘  └────────────────┘

                  no NAT Gateway anywhere · outbound AWS calls go through VPC endpoints
```

---

# Layer 1 — Network

## VPC (Virtual Private Cloud)

**What it is.** A private network you define inside AWS, with your own IP range. Nothing is
"on the internet" by default; a resource is reachable only if a route and a security group both
allow it. The VPC is the box every other service in this document is placed into.

**Why here.** It is not optional — Fargate tasks, RDS and ElastiCache all require one. The real
decision was the *shape*: a `/16` split into `/24`s, `.0` public and `.10+` private, across two
availability zones.

**Two availability zones, despite the cost brief.** An internet-facing ALB requires subnets in at
least two zones and AWS rejects it otherwise. This costs nothing extra here — the saving in this
design comes from having no NAT Gateway, not from having one zone.

**`enable_dns_hostnames` and `enable_dns_support` are both on, and both are load-bearing.**
Without them a VPC interface endpoint gets no private DNS name, so
`ecr.eu-central-1.amazonaws.com` keeps resolving to the public address, which has no route. The
call hangs rather than failing, with the endpoint sitting there looking correct.

**Read:** [What is a VPC](https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html) ·
[VPC sizing and subnets](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html)

---

## Subnets, Internet Gateway, route tables

**What they are.** A subnet is a slice of the VPC's IP range pinned to one availability zone. A
route table says where traffic leaving that subnet may go. An Internet Gateway is the VPC's door
to the internet — a subnet is "public" **only** because its route table has a `0.0.0.0/0` route
pointing at one. There is no flag called "public".

**Why here.** Public subnets hold the load balancer and nothing else. Private subnets hold every
task, the database, the cache and the broker, and their route table deliberately has no
`0.0.0.0/0` entry at all.

**This is the strongest control in the design, and it is a missing line rather than a rule.** A
security group is something a person can widen by accident in a hurry; an absent route is not.
Nothing in a private subnet is reachable from outside the VPC no matter what any security group
says.

**Read:** [Subnets](https://docs.aws.amazon.com/vpc/latest/userguide/configure-subnets.html) ·
[Route tables](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html)

---

## VPC endpoints — what replaces the NAT Gateway

**What they are.** A private door from your VPC to a specific AWS service, without going over the
internet. Two kinds, and the difference matters:

| Kind | How it works | Cost | Used here for |
|---|---|---|---|
| **Gateway** | A route table entry | **Free** | S3 |
| **Interface** | An ENI (a real network card) in each subnet, with private DNS | ~$7/month each + data | `ecr.api`, `ecr.dkr`, `logs`, `secretsmanager` |

**Why here.** A NAT Gateway is **$0.045/hour before a byte of traffic — about $32 a month, per
availability zone, permanently.** It exists to give private subnets outbound internet access, and
the only outbound calls these tasks make are to AWS itself. So: four interface endpoints and one
free gateway endpoint instead, which is cheaper *and* a tighter boundary — a task that cannot
reach the internet cannot exfiltrate to it either.

**The S3 endpoint is the one everybody forgets.** ECR stores image layers in S3 and hands out S3
URLs. With `ecr.api` and `ecr.dkr` but no S3 endpoint, `docker pull` authenticates cleanly and
then hangs on the first layer. It reads like a network fault rather than a missing route, and it
is the single most common way a no-NAT ECS setup fails.

> **When the no-NAT design stops working.** The moment a service needs to call anything on the
> public internet — an email provider's API, a maps service, an external payment processor over
> HTTPS — there is no route for it. Today the only such call is EuPlătesc, and it works because
> *the customer's browser* posts to them and the notification comes back inbound through the ALB.
> A **Notification service calling SES would need the `email-smtp` interface endpoint** added
> here, not a NAT Gateway.

**Read:** [VPC endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/concepts.html) ·
[Which services have endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/aws-services-privatelink-support.html) ·
[NAT Gateway pricing](https://aws.amazon.com/vpc/pricing/)

---

## Security groups

**What they are.** A stateful firewall attached to a network interface. Stateful means you allow
the inbound request and the reply is allowed automatically — you never write the return rule.
Rules can reference **another security group** rather than an IP range, which is what makes them
usable when addresses change on every deployment.

**Why here.** Three of them, chained, and the chain *is* the architecture:

- **alb** — ports 80 and 443 from anywhere. 80 only redirects to 443.
- **gateway** — port 9000, from the ALB's security group. Nothing else.
- **service** — ports 9001–9006, from the gateway's security group and from itself (Orders calls
  Cart, Catalog and Inventory over REST).

**This is what makes "not routed at the gateway" a security control rather than an omission.** The
load balancer has no target group pointing at any service, so an endpoint the gateway does not
expose has no network path from outside — a route added by mistake still cannot be reached.

**Rules are separate resources, not inline blocks.** Two security groups that reference each other
cannot be expressed inline without a dependency cycle, and Terraform reports that as `Cycle:`
followed by every resource involved — naming the symptom and not the cause.

**Read:** [Security groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html) ·
[Security groups vs network ACLs](https://docs.aws.amazon.com/vpc/latest/userguide/infrastructure-security.html)

---

## Cloud Map (AWS service discovery)

**What it is.** A private DNS namespace inside your VPC. ECS registers each task's IP under a name
as it starts and deregisters it as it stops, so `users.martensa.internal` always resolves to the
tasks currently running.

**Why here.** Fargate tasks get a new private IP on every replacement. Something has to answer
"where is Users right now", and the blueprint deferred this choice — Eureka was the alternative.
Cloud Map wins because it needs no extra running service, no client library and no Spring
dependency: it is DNS, and every HTTP client already speaks DNS.

**TTL is 10 seconds, and the JVM will ignore it if you let it.** Java caches DNS lookups in
process, historically for ever. `networkaddress.cache.ttl` has to be set or a service keeps
calling a task that stopped an hour ago.

**Read:** [Cloud Map](https://docs.aws.amazon.com/cloud-map/latest/dg/what-is-cloud-map.html) ·
[ECS service discovery](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-discovery.html)

---

# Layer 2 — Compute

## ECR (Elastic Container Registry)

**What it is.** A private Docker registry. You push an image, ECS pulls it. That is nearly all it
does, and the interesting part is the two settings on it.

**`image_tag_mutability = "IMMUTABLE"`.** A tag, once pushed, can never be moved to a different
image. This is the setting that makes a deployment reproducible: `martensa-users:a1b2c3d` means
one specific set of bytes for ever. With mutable tags, `:latest` is a different image every
afternoon, a rollback re-pulls whatever is there *now*, and two tasks in the same service can be
running different code with no way to tell.

**Lifecycle policy.** Untagged layers expire after a few days; tagged images are capped at a
count. Without it a registry grows for ever at $0.10/GB-month — small, but it is the archetypal
cost that appears years later with no owner.

**Cost.** ~$1/month at this scale. Storage only; pulls inside the same region are free.

**Read:** [ECR user guide](https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html) ·
[Image tag mutability](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html) ·
[Lifecycle policies](https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html)

---

## ECS + Fargate

**What they are.** Two separate things that are usually said as one word.

- **ECS** is the orchestrator: it holds the desired state ("run 1 copy of this task definition"),
  replaces tasks that die, and rolls out new versions.
- **Fargate** is the *capacity provider*: it runs a container without you owning an EC2 instance.
  You declare CPU and memory, AWS finds somewhere to put it, and you are billed per second.

**Why here rather than the alternatives:**

| Option | Verdict |
|---|---|
| **EC2 + Docker by hand** | Cheapest, and you now operate patching, disk, and a scheduler you wrote |
| **EKS (Kubernetes)** | $73/month for the control plane alone, before a single node. The right answer at 50 services; absurd at seven |
| **App Runner / Elastic Beanstalk** | Simpler, and hides exactly the networking this project exists to learn |
| **ECS on Fargate** | **Chosen** — no servers to patch, real VPC networking, per-second billing |

**Task definition vs service.** The task definition is the *recipe* — image, CPU, memory,
environment, secrets, health check. It is immutable and versioned: every change registers a new
revision. The service is the *running instance* of that recipe, and it is what holds the desired
count, the load balancer registration and the deployment strategy.

**`ignore_changes = [task_definition, desired_count]` on the service.** CI deploys by registering
a new revision and pointing the service at it. Without this, the next `terraform apply` reads the
running revision as drift and rolls the service back to whatever image Terraform last knew about
— **silently undoing a deployment.** This is the single most important line in the ECS module and
it protects a workflow that does not exist yet.

**The deployment circuit breaker.** Without it, a deployment whose tasks cannot start does not
fail — ECS retries for ever while the previous version keeps serving. The deploy appears to hang,
CI times out, and nothing says the new image is broken. With `rollback = true` ECS returns to the
last working revision and marks the deployment failed, which CI can act on.

**Fargate Spot for the seven services, on-demand for the broker.** Spot is roughly 70% cheaper and
can be reclaimed with two minutes' notice. Every application service tolerates that: they are
stateless, the Kafka consumers are idempotent by contract, and the outbox claim uses
`FOR UPDATE SKIP LOCKED` so an interrupted publish is simply re-claimed. A *broker* that
disappears several times a day is an outage with extra steps.

**ARM64 (Graviton), ~20% cheaper — and this one reaches outside this repository.** The images must
actually be built for ARM. An amd64-only image fails at task start with
`image Manifest does not contain descriptor matching platform`, which reads like a corrupt push
rather than an architecture mismatch. CI needs `docker buildx build --platform linux/arm64`.

**Cost.** ~512 CPU units / 1 GB per service. On Spot, roughly $4–5 per service per month.

**Read:** [ECS developer guide](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html) ·
[Fargate](https://docs.aws.amazon.com/AmazonECS/latest/userguide/what-is-fargate.html) ·
[Task definition parameters](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html) ·
[Deployment circuit breaker](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-circuit-breaker.html) ·
[Fargate Spot](https://docs.aws.amazon.com/AmazonECS/latest/userguide/fargate-capacity-providers.html)

---

## EFS (Elastic File System)

**What it is.** A managed NFS filesystem that many tasks can mount at once, and that survives a
task being replaced. Fargate's own storage is ephemeral and disappears with the container.

**Why here.** Exactly one thing needs it: the **Kafka broker's log directory.** Without it, a task
replacement recreates every topic empty — and the platform would look perfectly healthy while
having silently lost every unconsumed event and every consumer offset.

**Mounted through an access point that pins uid/gid 1001**, so the container writes as the user
Kafka runs as without the container needing root.

**Cost.** ~$0.30/GB-month. Pennies for a broker log at this volume.

**Read:** [EFS](https://docs.aws.amazon.com/efs/latest/ug/whatisefs.html) ·
[EFS volumes in ECS](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/efs-volumes.html) ·
[Access points](https://docs.aws.amazon.com/efs/latest/ug/efs-access-points.html)

---

# Layer 3 — Data

## RDS for PostgreSQL

**What it is.** A managed PostgreSQL instance: AWS handles backups, patching, failover and
point-in-time recovery. You still get a normal Postgres you connect to on 5432.

**Why here.** The platform is PostgreSQL by rule — Flyway migrations use PostgreSQL-only features
(`FOR UPDATE SKIP LOCKED`, partial indexes, `EXCLUDE`), and Testcontainers runs real Postgres 16
in tests. `db.t4g.micro`, `gp3` storage starting at 20 GB with autoscaling to 100 GB.

**One instance, six databases — and the grant is what enforces the boundary, not the naming.**

```sql
REVOKE CONNECT ON DATABASE orders FROM PUBLIC;
GRANT  CONNECT ON DATABASE orders TO orders_svc;
```

A service holding another service's credentials still cannot open a session against the wrong
database. Six separate instances would enforce the same thing at six times the cost, and the
boundary that actually matters is in the code. Splitting later is a data migration, not a
redesign: each service already reads its own `DB_URL` from its own secret.

**`multi_az = false`, and it is worth knowing what that does not buy.** Multi-AZ is *failover*,
not backups — a dropped table is replicated to the standby in milliseconds. Backups are the
7-day automated retention, which is on.

**Guard rails that must not be weakened to get past an error:** `deletion_protection = true`,
`skip_final_snapshot = false`, `allow_major_version_upgrade = false`. A major version upgrade
rewrites the catalog and can break a query that worked yesterday; minor upgrades are automatic.

**Cost.** ~$13/month for `db.t4g.micro` + ~$2.50 for 20 GB gp3.

**Read:** [RDS for PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html) ·
[Managed master password](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html) ·
[Multi-AZ](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZ.html) ·
[Performance Insights](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.html)

---

## ElastiCache for Redis

**What it is.** Managed Redis. Same protocol, same clients, AWS handles the node and the failover.

**Why here.** Cart owns no relational database — a basket is a Redis hash with a TTL, and that is
the whole store. `cache.t4g.micro`, one node.

**`maxmemory-policy = allkeys-lru`** rather than the default `noeviction`. With `noeviction`,
a full cache starts *refusing writes* — the symptom is customers unable to add to basket while
every health check is green.

**One node means losing the cache loses every open basket.** That is an accepted trade for a
cache, and it is exactly why baskets are the only thing in it. It is also why a rate limiter
must **not** share this instance: a datastore belongs to exactly one service.

**Cost.** ~$12/month.

**Read:** [ElastiCache for Redis](https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/WhatIs.html) ·
[Eviction policies](https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/ParameterGroups.Redis.html)

---

# Layer 4 — Edge

## ALB (Application Load Balancer)

**What it is.** A layer-7 load balancer. It terminates TLS, health-checks its targets, and
forwards HTTP to whatever is registered in a target group.

**Why here.** It is the only thing on the platform the internet may talk to, and it is the only
place a certificate can be presented for the API. It forwards to exactly one target group: the
gateway task, on port 9000.

**Three settings that are not defaults:**

- **Health check path is `/actuator/health/readiness`, not `/actuator/health`.** The aggregate
  endpoint goes unhealthy when a *downstream* check fails — so one service being down would take
  the whole platform out of the load balancer. Readiness also reports false while Flyway is still
  migrating, which is correct: the service must not take traffic it cannot serve.
- **`deregistration_delay = 20s`**, under the task's 30s stop timeout, which is over the
  application's 25s graceful shutdown. The load balancer stops sending before the task stops
  accepting. Get this order wrong and every rolling deploy produces a handful of 502s.
- **Port 80 exists only to redirect.** Serving anything real on it would mean a bearer token
  crossing the internet in clear text.

**Cost.** ~$16/month base + LCU charges. **The largest single line in this design**, and there is
no cheaper way to have a certificate and a stable public name for the API.

**Read:** [Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html) ·
[Target groups and health checks](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html) ·
[ALB pricing / LCUs](https://aws.amazon.com/elasticloadbalancing/pricing/)

---

## ACM (Certificate Manager)

**What it is.** Free TLS certificates that AWS issues, renews and rotates automatically, usable by
ALB and CloudFront. Free only when used with an AWS service — it cannot export a private key.

**The trap that costs an afternoon:** **CloudFront reads certificates only from `us-east-1`,
wherever everything else lives.** A certificate issued in `eu-central-1` is rejected with an error
that names neither region. So this platform needs **two certificates for the same domain**: one in
`us-east-1` for CloudFront (the storefront) and one in `eu-central-1` for the ALB (the API). The
frontend module has a validation that enforces the `us-east-1` half.

**Cost.** Free.

**Read:** [ACM](https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html) ·
[Certificates for CloudFront must be in us-east-1](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-requirements.html)

---

## CloudFront + S3 (the storefront)

**What they are.** S3 is object storage; CloudFront is the CDN that sits in front of it, caching
at edge locations worldwide and terminating TLS.

**Why here.** The storefront is a Vite build — static files. There is no server to run, so paying
for a task to serve them would be waste.

**Origin Access Control (OAC), and why a public bucket is wrong in a way that does not show.**
The bucket is private; CloudFront signs its requests with SigV4 so the bucket policy can name the
distribution and refuse everyone else. The obvious alternative — a public bucket with static
website hosting — is simpler and leaves **the bucket's own URL working**, so every file stays
reachable without passing through CloudFront. That bypasses the security headers, the TLS policy,
and any WAF attached later, and nothing in the application would ever notice.

**The bucket policy scopes the CloudFront principal with `AWS:SourceArn`.** Without that
condition it reads "any CloudFront distribution in any AWS account may read this bucket" — and
anyone can create a distribution.

**403 and 404 both rewrite to `/index.html` with a 200.** React Router owns the URL space. Without
this, `/produse/lapte` asks S3 for an object that does not exist and the customer gets
CloudFront's XML error document. Every deep link, bookmark and refresh outside `/` breaks — while
the site works perfectly when navigated from the home page, which is why it survives casual
testing.

**Cost.** ~$1–2/month at this traffic. CloudFront has a generous perpetual free tier.

**Read:** [CloudFront](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Introduction.html) ·
[Origin Access Control](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html) ·
[Hosting an SPA](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/GettingStarted.SimpleDistribution.html) ·
[S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html)

---

# Layer 5 — Identity

## IAM — two roles, and why they are not one

**What it is.** Identity and Access Management: policies that say which principal may call which
API on which resource. Nothing in AWS happens without one.

**The distinction worth internalising, because it is the one people collapse:**

| Role | Used by | When | Holds |
|---|---|---|---|
| **Execution role** | The ECS *agent* | Before the container starts | Pull the image, read secrets, create the log stream |
| **Task role** | The *application* | While it runs | Whatever the code needs — **nothing, here** |

The container never holds the execution role's credentials. The task role is what an exploited
service can actually use, and here it is **deliberately empty**: none of the seven services calls
an AWS API, because every secret arrives as an environment variable injected before start-up. A
remote-code-execution bug therefore yields an AWS identity that can do nothing.

**Merging them — the usual shortcut — would hand that same bug permission to read every secret on
the platform.** The empty role exists rather than being omitted so ECS Exec can attach to it, and
so the next service that genuinely needs a permission has an obvious place to put it, instead of
the permission being added to the execution role where every other task would inherit it.

> `AmazonECSTaskExecutionRolePolicy` covers ECR and CloudWatch Logs but **not Secrets Manager**.
> That inline policy is added separately and scoped to this environment's secret prefix rather
> than `*`.

**Read:** [IAM concepts](https://docs.aws.amazon.com/IAM/latest/UserGuide/intro-structure.html) ·
[ECS task execution role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html) ·
[ECS task role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html) ·
[Policy evaluation logic](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)

---

## Secrets Manager

**What it is.** Encrypted storage for secrets, with versioning and optional rotation. ECS can
inject a secret straight into a container's environment, so the value never appears in the task
definition.

**Why here, in three tiers — and the tier is decided by *who generates the value*:**

| Tier | Generated by | In Terraform state? |
|---|---|---|
| RDS master | RDS itself (`manage_master_user_password`) | **No** |
| Per-service DB passwords | Terraform `random_password` | **Yes** — accepted trade |
| JWT signing key, EuPlătesc merchant key | A human, once, by hand | **No** |

**Terraform records every attribute of every resource it manages**, and `random_password.result`
is an attribute. So anything Terraform generates is in the state file in plain text, in every
historical version the bucket keeps, and in the plan output of whoever runs `terraform plan`.
The master credential is admin over the whole platform; the JWT key means whoever holds it *is*
every customer including administrators; the merchant key can forge a settled payment. None of
those three is worth the trade. The six per-service passwords are, because the alternative — six
credentials managed by hand with no record of which is current — is worse.

**A secret with no version cannot be referenced by a task definition at all.** ECS fails with
`ResourceInitializationError` naming the secret but not the fact that it is empty. So the
hand-written tier is created with the literal placeholder `REPLACE-ME` and `ignore_changes` on the
value — a service reading the placeholder starts and rejects every token, which is diagnosable,
rather than a task that never runs. Without `ignore_changes`, every apply would overwrite the real
key with the placeholder and the whole platform would start rejecting tokens after an unrelated
infrastructure change.

**Cost.** $0.40 per secret per month. Eight secrets ≈ $3.20 — small, but it is why the count is
deliberate rather than one secret per variable.

**Read:** [Secrets Manager](https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html) ·
[Injecting secrets into ECS](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/specifying-sensitive-data-secrets.html) ·
[Sensitive data in Terraform state](https://developer.hashicorp.com/terraform/language/state/sensitive-data)

---

# Layer 6 — Operations

## CloudWatch Logs + Container Insights

**What they are.** Logs is where the `awslogs` driver sends container stdout. Container Insights
is the metrics layer over ECS — CPU, memory, task counts, per service.

**Why here.** A Fargate task has no disk you can SSH into. If a log line does not leave the
container it does not exist.

**Retention is set explicitly.** The default is "never expire", which is a bill that grows for
ever with no owner.

**The gap, stated plainly: nothing reads any of this.** Container Insights is on, Performance
Insights is on, the ALB publishes 5xx counts — and no alarm is configured. `martensa.outbox.abandoned`
above zero *should* wake someone and does not. **Kafka consumer lag is the one that matters most**
and is the hardest to get from a self-managed broker.

**Read:** [CloudWatch Logs](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/WhatIsCloudWatchLogs.html) ·
[Container Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ContainerInsights.html) ·
[Alarms](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/AlarmThatSendsEmail.html)

---

## S3 as the Terraform state backend

**What it is.** The state file records what Terraform believes exists and maps it to real resource
ids. Losing it does not delete anything — it makes Terraform forget, so the next plan proposes
creating everything that already exists.

**`bootstrap/` creates the bucket and keeps its own state local**, because a configuration cannot
store state in a bucket it is also creating. That local state describes one bucket; losing it
costs a `terraform import`.

- **Versioning is the most important setting in that file.** A corrupted or truncated state write
  is otherwise unrecoverable.
- **`prevent_destroy` and `force_destroy = false`.** A state bucket emptied by a `terraform
  destroy` takes every environment's state with it, and the resources those states describe become
  unmanaged — still running, still billed, invisible.
- **A bucket policy denies `aws:SecureTransport = false`.** Encryption protects the object at rest;
  this protects it in transit, and the state holds database passwords.
- **`use_lockfile = true`** — S3-native locking, which replaced the DynamoDB table in Terraform
  1.10. Without a lock, two applies running at once interleave writes and the state describes
  neither.

> **The backend block cannot use variables.** It is read before Terraform evaluates anything, so
> `bucket = var.state_bucket` fails with "Variables not allowed" — which looks like a syntax error
> rather than a lifecycle one. Hence `backend "s3" {}` plus `-backend-config=backend.hcl`, which
> also keeps the account id out of version control.

**Read:** [S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3) ·
[State locking](https://developer.hashicorp.com/terraform/language/state/locking) ·
[Purpose of state](https://developer.hashicorp.com/terraform/language/state/purpose)

---

# What this platform deliberately does *not* use

Knowing why something is absent is worth as much as knowing why something is present. Every row
here was considered and rejected for a stated reason.

| Not used | Why not | What would change the answer |
|---|---|---|
| **NAT Gateway** | ~$32/month/AZ before any traffic; the only outbound calls are to AWS | A service that must call the public internet — e.g. an email API |
| **MSK / MSK Serverless** | ~$540/month running. Correct, and unaffordable for a platform serving nobody | Real customers, or any need for replication |
| **EKS (Kubernetes)** | $73/month for the control plane before a single node | ~50 services, or a team already fluent in it |
| **Aurora** | Costs more than `db.t4g.micro` and buys throughput nobody needs | Read replicas or serious write volume |
| **DynamoDB** | The data is relational and the constraints are the design — `EXCLUDE`, `CHECK`, FKs | A genuinely key-value workload |
| **SNS / SQS** | Replaced by Kafka in blueprint §4.1: one broker, replayable log, consumer groups | — |
| **Route 53** | `api_domain` is a variable and nothing creates a record. The hosted zone may live in another account | Owning the zone in this account |
| **WAF** | ~$5/month + per-rule. Rate limiting is being done at the gateway instead | Public traffic worth attacking |
| **Elastic Beanstalk / App Runner** | Hide exactly the networking this project exists to learn | A deadline instead of a curriculum |
| **X-Ray / distributed tracing** | Deferred in the blueprint | More than one person debugging a cross-service path |
| **SES** | No Notification service yet — the one thing that would need it | Building it. Note it needs a VPC endpoint |

---

# What it costs

Nothing here has been applied; these are list prices for `eu-central-1` used to compare options.

| Service | Monthly | Note |
|---|---|---|
| ALB | ~$16 | The largest single line. No cheaper way to have TLS on a stable name |
| VPC interface endpoints (×4) | ~$28 | Still cheaper than one NAT Gateway, and a tighter boundary |
| RDS `db.t4g.micro` + 20 GB gp3 | ~$16 | |
| ElastiCache `cache.t4g.micro` | ~$12 | |
| ECS Fargate Spot, 7 services | ~$30 | ~70% off on-demand |
| Kafka task (on-demand) + EFS | ~$15 | On-demand deliberately — a reclaimed broker is an outage |
| ECR + S3 + CloudFront + Secrets | ~$6 | |
| **Total running** | **~$75–90** | |
| **Total parked** (`desired_count = 0`) | **~$40** | The ALB, endpoints, RDS and Redis still bill |

**The honest observation: parked costs half of running.** The tasks are the cheap part; the
always-on managed services are not. Taking the bill near zero means destroying the environment,
not scaling it to zero — which is exactly what a versioned state file and `terraform apply` are
for.

---

# A reading order

If you read nothing else, read these five, in this order. They are the concepts everything above
is an application of.

1. **[VPC subnets and routing](https://docs.aws.amazon.com/vpc/latest/userguide/configure-subnets.html)** — until "public subnet" means "has a route to an Internet Gateway" and nothing else, none of the rest is learnable.
2. **[ECS task definitions](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html)** — the recipe/instance split is the mental model the whole deploy story rests on.
3. **[IAM policy evaluation](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)** — explicit deny beats everything; nothing is allowed by default.
4. **[VPC endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/concepts.html)** — the piece that makes the no-NAT design work, and the piece that breaks first when a new dependency appears.
5. **[Terraform state](https://developer.hashicorp.com/terraform/language/state/purpose)** — because the failure mode is not "an error", it is Terraform quietly proposing to rebuild production.

**Then, when you are ready to apply:** the
[AWS Well-Architected Framework](https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html)
pillars, and the [Pricing Calculator](https://calculator.aws/) with the table above as a starting
point.

---

# Checking yourself

If these are answerable without looking, the material has landed.

1. Why does the ECR pull need an **S3** endpoint, and what is the symptom when it is missing?
2. What is the difference between the execution role and the task role, and which one does an
   attacker who achieves RCE in Catalog actually get?
3. Why is the ALB health check pointed at `/actuator/health/readiness` rather than
   `/actuator/health` — and what are the *two* separate reasons?
4. Why must `ignore_changes = [task_definition]` exist before CI is written rather than after?
5. Why are there two ACM certificates for the same domain?
6. Which secrets are in the Terraform state file, and which are deliberately not — and what
   decides which pile a secret lands in?
7. What breaks if the Kafka broker's `desired_count` goes to 2?
8. Why can a rate limiter not share Cart's Redis?
