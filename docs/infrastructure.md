# Terraform — infrastructure log

What this repository's infrastructure does, why, and what would break if it were removed.

Application design lives in `docs/martensa-v2-architecture-blueprint.md` **in
martensa-platform-parent** — one copy for the whole platform, deliberately not duplicated here.
Toolchain and build gates live in that repo's `docs/infrastructure.md`. This file covers only
what is true of the **AWS infrastructure**.

**This file assumes you know what the services are.** If a term below is unfamiliar,
[`aws-services-guide.md`](aws-services-guide.md) is the companion: what each AWS service is, why
it is in this design, what was rejected instead, and what to read. The two are deliberately
split — this one records *decisions and their consequences*, that one teaches *the material*.
A decision recorded twice drifts.

**Nothing here has been applied.** The code is `fmt`-clean, `validate`-clean and `tflint`-clean
across nine modules and two root configurations. That is a real check — it catches type errors,
unknown arguments, unused declarations, missing provider constraints — and it is not a plan. A
plan needs credentials and would surface the class of problem no local check can: a name already
taken, a quota, an instance class not offered in a region. Read every claim below as "designed
and validated", not "observed in production".

---

## 1. The numbers

| | |
|---|---|
| Region | `eu-central-1` (Frankfurt — nearest to Vrancea with full service coverage) |
| Modules | 9 |
| Root configurations | 2 (`bootstrap`, `environments/dev`) |
| Terraform | ≥ 1.5, AWS provider `~> 5.0` |
| Services | 7 + gateway + storefront |
| Interface endpoints | 5 — `ecr.api`, `ecr.dkr`, `logs`, `secretsmanager`, `email` (§6b) |
| Estimated cost | ~$85–100/month running, ~$45 parked — the seventh service and a fifth interface endpoint |

---

## 2. Two decisions the blueprint deferred to this step

### 2a. Kafka runs as a Fargate task, not on MSK

Blueprint §4.1 left this open on purpose — "the one choice here with a real monthly bill
attached" — with three candidates. The decision, and the reasoning in the order it actually
mattered:

| Option | Monthly | Verdict |
|---|---|---|
| MSK Serverless | ~$540 running | Correct and unaffordable for a platform serving nobody |
| Confluent Cloud free tier | $0 | Bootstrap address and API key on the public internet; teaches no AWS |
| **Fargate task, KRaft** | **~$15** | **Chosen** |

**Security first, because cheapness alone would not have been enough.** The broker sits in a
private subnet with no public IP, no internet route, and a security group that admits only the
six application tasks. There is no path to it from outside the VPC, so there is nothing to
authenticate from outside and no credential that can leak. MSK's IAM authentication is genuinely
stronger *authentication* — but it protects a surface this design does not expose. Confluent is
the opposite trade: the strongest managed operations, reached over the public internet with an
API key.

**What is given up, stated plainly: one broker, no replication.** Every partition has a single
copy. This is not a production broker and the module says so in its header.

That single broker forces three settings that would each fail loudly:

- `KAFKA_CFG_DEFAULT_REPLICATION_FACTOR=1`, and the same for the offsets and transaction-state
  topics. Left at the default of 3, every topic creation fails with
  `INVALID_REPLICATION_FACTOR` — including the internal `__consumer_offsets` topic, which fails
  at start-up and takes the broker with it.
- `deployment_maximum_percent = 100` and `minimum_healthy_percent = 0`, the opposite of every
  other service here. Two brokers must never run at once: they would share node id 1 and the
  same EFS log directory. So the old task stops before the new one starts, and every deployment
  is a short outage. That is the correct trade for a single-broker design, not an oversight.
- `desired_count` is validated to 0 or 1. Zero parks the environment; two would be the failure
  above.

> **The advertised listener is what actually breaks this.** A Kafka client connects to the
> bootstrap address, asks for metadata, and is then told where the brokers *really* are. A
> broker advertising its container IP is correct until the first task replacement; advertising
> `localhost` — the default when nothing is set — redirects every client to itself. Both produce
> the same symptom: the connection succeeds, metadata is fetched, and every `send()` times out
> with **`TimeoutException: Topic not present in metadata`**, which reads like a missing topic
> rather than a routing problem. The module advertises the Cloud Map name, which survives task
> replacement.

**EFS is not optional here.** Without it the log directories are on the task's ephemeral storage,
so a task replacement recreates every topic empty — and the platform would look healthy while
having silently lost every unconsumed event and every consumer offset. Mounted through an access
point that pins uid/gid 1001, so the container writes as the user Kafka runs as without needing
root.

### 2b. One RDS instance, one database per service

Blueprint §5 said "start: one instance, separate schemas per service". This uses separate
**databases**, which is stricter, and the reason is that the platform rule — no service reads
another's tables — has to be *enforced* rather than agreed.

What enforces it is the grant, not the naming:

```sql
REVOKE CONNECT ON DATABASE orders FROM PUBLIC;
GRANT  CONNECT ON DATABASE orders TO orders_svc;
```

A service holding another service's credentials still cannot open a session against the wrong
database. Six separate instances would enforce the same thing at six times the cost, and the
boundary that matters is in the code.

Splitting later is a data migration, not a redesign: every service already reads its own `DB_URL`
from its own secret, so moving one database to its own instance changes one secret.

---

## 3. No NAT Gateway, and the endpoint that gets forgotten

A NAT Gateway is $0.045/hour before a byte of traffic — about $32 a month, per availability zone,
permanently. It exists to give private subnets outbound internet access, and the only outbound
calls these tasks make are to AWS itself.

So: private subnets with no `0.0.0.0/0` route, and VPC endpoints for what the tasks actually use.
Cheaper, and a tighter boundary — a task that cannot reach the internet cannot exfiltrate to it.

| Endpoint | Type | What fails without it |
|---|---|---|
| `s3` | Gateway (free) | **ECR image pulls.** Layers are stored in S3 and the registry hands out S3 URLs |
| `ecr.api` | Interface | Authentication against the registry |
| `ecr.dkr` | Interface | The pull itself |
| `logs` | Interface | The `awslogs` driver. A task runs and logs nothing — invisible, because the thing that would tell you is the log driver |
| `secretsmanager` | Interface | The task stops before the container runs: `ResourceInitializationError: unable to pull secrets` |

> **The S3 endpoint is the one people miss.** With `ecr.api` and `ecr.dkr` but no S3, `docker
> pull` authenticates cleanly and then hangs on the first layer. It reads like a network fault
> rather than a missing route, and it is the single most common way a no-NAT ECS setup fails.

`enable_dns_hostnames` and `enable_dns_support` are both required for interface endpoints to
resolve. Without them the endpoint gets no private DNS name, so `ecr.eu-central-1.amazonaws.com`
keeps resolving to the public address — which has no route. Same silent hang, with the endpoint
sitting there looking correct.

**Two availability zones, despite the cost brief.** An internet-facing ALB requires subnets in at
least two zones; AWS rejects it otherwise. The saving comes from having no NAT Gateway, not from
having one zone.

---

## 4. What the internet can reach, and what it cannot

```
internet ──▶ ALB ──▶ gateway task ──▶ the six services ──▶ RDS · Redis · Kafka
             (public subnets)         (private subnets, no internet route)
```

Three security groups, chained:

- **alb** — 80 and 443 from anywhere. 80 only redirects.
- **gateway** — port 9000 from the ALB's security group. Nothing else.
- **service** — ports 9001–9006 from the gateway's security group, and from itself (Orders calls
  Cart, Catalog and Inventory over REST).

**This is what makes "not routed at the gateway" a security control rather than an omission.** A
service endpoint the gateway does not expose is not merely undocumented — there is no network
path to it from outside. The load balancer has no target group pointing at any service, so a
route added by mistake still cannot be reached.

Rules are separate `aws_vpc_security_group_*_rule` resources rather than inline blocks, because
two security groups that reference each other cannot be expressed inline without a cycle — and
Terraform reports that as a `Cycle:` listing every resource involved, which names the symptom and
not the cause.

Egress is open on the task security groups, and that is not the hole it looks like: the private
subnets have no route to the internet, so "anywhere" means "anywhere in this VPC, plus the
endpoints". Narrowing it per destination would add rules that duplicate what routing already
enforces.

---

## 5. Secrets: three tiers, and why they differ

| Tier | Where the value comes from | In Terraform state? |
|---|---|---|
| RDS master | RDS generates and rotates it (`manage_master_user_password`) | **No** |
| Per-service DB | `random_password`, stored as a JSON secret | **Yes** — accepted trade |
| Internal API token | `random_password`, one secret read by three services | **Yes** — and §6b argues why it is *not* in the tier below, where it looks like it belongs |
| JWT key, EuPlătesc key | Written once by hand, `ignore_changes` | **No** |

Terraform records every attribute of every resource it manages, and `random_password.result` is
an attribute. So anything Terraform generates is in the state file in plain text, in every
historical version the bucket keeps, and in the plan output of whoever runs `terraform plan`.

- **The master credential** is admin over the whole platform. `manage_master_user_password` keeps
  it out of state entirely.
- **The per-service passwords** are scoped to one database each, and the alternative — six
  credentials managed by hand with no record of which is current — is worse. This is why the
  state bucket is encrypted, versioned, blocked from public access and refuses plain HTTP.
- **The JWT signing key** mints tokens for every account including administrators; whoever holds
  it *is* every customer. **The EuPlătesc merchant key** signs payment requests and verifies the
  notifications that settle orders; whoever holds it can forge a settled payment. Neither is
  worth the trade.

> **A secret with no version cannot be referenced by a task definition at all.** ECS fails the
> task with `ResourceInitializationError` naming the secret but not the fact that it is empty. So
> the third tier is created with the literal placeholder `REPLACE-ME` and `ignore_changes` on the
> value. A service reading the placeholder starts and rejects every token — a diagnosable
> failure, rather than a task that never runs.
>
> Without `ignore_changes`, every `terraform apply` would overwrite the real key with the
> placeholder, and the symptom would be the whole platform rejecting every token immediately
> after an unrelated infrastructure change.

Secrets carry `recovery_window_in_days = 0` so a destroy/apply cycle works. Secrets Manager
otherwise keeps a deleted secret for 7–30 days and refuses to create one with the same name,
which turns a rebuild into a week's wait or a rename. **Raise it for anything long-lived** — at
zero, a secret deleted by mistake is unrecoverable.

---

## 6. Two IAM roles, and why they are not one

- **Execution role** — used by the ECS *agent*, before the container starts: pull the image,
  fetch secrets, create the log stream. The container never holds these credentials.
- **Task role** — assumed by the *application*. This is what an exploited service can use.

The *shared* task role is **deliberately empty**, and six of the seven services still use it: every
secret arrives as an environment variable injected before start-up, so a remote-code-execution bug
in one of them yields an AWS identity that can do nothing.

> **The notification service is the exception, and it has its own role rather than widening this
> one.** It sends through the SESv2 API — the first AWS call any task on this platform makes. §6b
> has the reasoning; the short version is that granting SES here would also grant it to Cart.


Merging the two, which is the usual shortcut, would hand that same bug permission to read every
secret on the platform. The role exists rather than being omitted so that ECS Exec can attach to
it, and so the next service that genuinely needs a permission has an obvious place to put it —
rather than the permission being added to the execution role, where every other task would get it
too.

> `AmazonECSTaskExecutionRolePolicy` covers ECR and CloudWatch Logs but **not Secrets Manager**.
> That inline policy is added separately, scoped to this environment's secret prefix rather than
> `*`. The RDS-managed master credential gets an AWS-generated name outside that prefix, so it is
> named explicitly instead of widening the wildcard.

---

## 6b. The notification service — the first task that calls an AWS API

Adding the seventh service was mostly mechanical: a port, a database, an ECR repository, a task
definition. Three things were not.

### The task role stopped being empty, and got split instead

§6 said the task role is *deliberately empty*, that no service calls an AWS API, and that it exists
so **the next service that genuinely needs a permission has an obvious place to put it**. This is
that service — it sends through the SESv2 API — and the place turned out to be wrong for the same
reason the execution role was wrong.

Attaching `ses:SendEmail` to the shared task role would grant it to Cart, to Payments and to the
gateway as well. A permission held by six tasks that cannot use it is a permission nobody will
think to remove, and it converts an exploited Cart into something that can send mail signed with
this platform's domain.

So: **a role per service, starting with the one that needs something.** The other six keep sharing
the empty role, because they still need nothing. `environments/dev/notification.tf` holds the new
one — in its own file rather than among the service blocks in `main.tf`, because an IAM role there
would be the least likely thing in this configuration to be noticed.

***REMOVE WHEN*** a second service needs an AWS permission. At two this belongs in
`modules/service` as an optional policy document, not copied into a second file here.

**The policy is scoped to one identity, not to `*`.** SES identities are what a recipient's mail
client shows as the sender, so an unconstrained `ses:SendEmail` is permission to send mail
appearing to come from *anything the account has verified*. The resource is the identity ARN built
from `notification_mail_from`'s domain, so the worst a compromised task can do is send from the
address it was already sending from. It is also not `ses:*` — that includes `DeleteIdentity`, which
would let a compromised task destroy the domain verification and take the platform's ability to
send email with it, in a way that looks like SES being broken and takes a DNS round trip to undo.

### `com.amazonaws.<region>.email`, and why the obvious one is wrong

There is no NAT Gateway (§3), so **every** AWS API a task calls needs an interface endpoint. SES is
the fifth entry in that list and the first that exists for one service rather than for all of them.

The trap is that SES publishes **two** endpoints and they are not interchangeable:

| Service name | Serves |
|---|---|
| `com.amazonaws.<region>.email` | the SES **API** — what the SDK calls |
| `com.amazonaws.<region>.email-smtp` | the SMTP interface |

Picking `email-smtp` produces a service that starts cleanly and cannot send: the SDK signs a
request to the SESv2 API, which the SMTP endpoint does not serve. AWS's own console distinguishes
them only by search term — *filter on `email` for the API, `smtp` for SMTP*
([Setting up VPC endpoints with Amazon SES](https://docs.aws.amazon.com/ses/latest/dg/send-email-set-up-vpc-endpoints.html)).

The Availability Zone exclusions in that same document (`use1-az2`, `cac1-az3` and the rest) apply
to the **SMTP** endpoint only, and none of them are in `eu-central-1` regardless.

This platform sends through the API rather than SMTP because the SDK signs with the task role,
where SMTP needs IAM-derived credentials — **a secret this platform would then have to create,
store and rotate**, for the same capability.

### The secret that would have worked while being wrong

`internal/api-token` opens `/api/internal/**` on Users and Catalog. Users' half is the contact
directory: every customer's name and email address, readable over plain HTTP by anything inside the
VPC holding that string.

By §5's tiers it looks like a third-tier secret — hand-filled, `ignore_changes`, never in state.
**It is generated instead, and the reason is the failure mode of the alternative.**

A hand-filled secret starts life as the literal `REPLACE-ME`. For the JWT key that is loud: the
platform rejects every token until somebody fixes it, within minutes of the first request. This one
would be **silent**. All three services read the same value, so `REPLACE-ME` on every side *matches*
— Users accepts it, Catalog accepts it, the notification service presents it, and the platform works
perfectly with a credential that is written in a committed file, in git history, and identical in
every environment anyone copied it into. Nothing fails, so nobody looks.

**A secret whose insecure state is also its working state does not get replaced.** Generating it
means the working state is the secure one, which is the only arrangement that survives somebody
being busy. The trade is the one §5 already accepts for the per-service database passwords: it
lands in state, and the state bucket is encrypted, versioned and refuses plain HTTP for exactly
this class of value.

It is also the one secret here **without** `ignore_changes`, deliberately. There, the rule protects
a real value from being overwritten by a placeholder; here Terraform owns the value, so ignoring
changes would let an out-of-band rotation silently disagree with state and leave the next apply
unable to put it back.

So §5's table gains a row:

| Tier | Where the value comes from | In Terraform state? |
|---|---|---|
| Internal API token | `random_password`, one secret read by three services | **Yes** — see above |

***REMOVE WHEN*** the platform has real service identity (blueprint §6). A bearer credential with
no expiry, no rotation story and no way to tell one caller from another is the placeholder, not the
plan.

### What this configuration deliberately does not do

**It does not verify the SES domain.** `aws_ses_domain_identity` would create an identity whose
verification is a DNS record on a zone this configuration does not manage — the storefront's domain
is a variable here, not a Route 53 zone — so it would sit in `Pending` for ever while reporting
success. Worse, `terraform destroy` would remove a verification that took a DNS propagation to earn.
The variable's description says so, because the symptom otherwise is `MessageRejected` on every
send with nothing in this repo suggesting why.

**Nor does it leave the SES sandbox.** In the sandbox every *recipient* must also be verified, so
sends fail for real customers while working perfectly for whoever is testing — which looks exactly
like a bug in the contact lookup. Leaving it is a support request, not a resource.

`notification_admin_alerts` defaults to blank and that is a supported state: the low-stock alert is
queued, found to have nowhere to go, and abandoned with a warning naming the property. The
alternative would let a missing variable here dead-letter an event on Inventory's topic.

---

## 7. ECS settings that are load-bearing

**The deployment circuit breaker.** Without it, a deployment whose tasks cannot start does not
fail — it retries for ever while the previous version keeps serving. The deploy appears to hang,
CI times out, and nothing says the new image is broken. With `rollback = true`, ECS returns to
the last working task definition and marks the deployment failed, which CI can act on.

**`ignore_changes = [task_definition, desired_count]`.** CI deploys by registering a new task
definition revision and updating the service. Without this, the next `terraform apply` sees the
running revision as drift and rolls the service back to whatever image Terraform knows about —
silently undoing a deployment.

**Health check path is `/actuator/health/readiness`, not `/actuator/health`.** Readiness reports
false while Flyway is still migrating at start-up. The aggregate endpoint can report UP before
the schema is ready, and the service then takes traffic it cannot serve. On the ALB target group
the reason is different and equally important: the aggregate endpoint would go unhealthy if a
*downstream* check failed, taking the whole platform offline because one service was down.

**`startPeriod` / `health_check_grace_period_seconds` = 120.** Flyway runs before the HTTP port
opens and a cold JVM on a burstable task is slow. Too short and ECS kills the task mid-migration,
restarts it, kills it again — a crash loop whose only symptom is a service that never stabilises,
with nothing in the log to explain why.

**`stopTimeout` 30s > the services' 25s shutdown phase.** Cut short, in-flight requests are
severed anyway and every rolling deploy produces a handful of 502s — which is exactly what
graceful shutdown was configured to prevent. The ALB's `deregistration_delay` is 20s, under both,
so the load balancer stops sending before the task stops accepting.

**`MaxRAMPercentage=75`, not the JVM's default 25.** A 1 GB task with a 256 MB heap wastes most
of what it is billed for. Not higher: the remaining quarter is metaspace, thread stacks and
direct byte buffers, and squeezing it turns a healthy service into an OOM-kill under load.

**ARM64 (Graviton), ~20% cheaper.** The images must be built for it. An amd64-only image fails at
task start with `image Manifest does not contain descriptor matching platform`, which reads like
a corrupt push rather than an architecture mismatch. *This is the one item here that requires a
change outside this repository* — the service Dockerfiles need a multi-arch build, or
`cpu_architecture` set to `X86_64`.

**The health check shells out to `curl`, and all seven images have it.** Verified rather than
assumed: every service Dockerfile runs `apk add --no-cache curl` on top of
`eclipse-temurin:21-jre-alpine`. Worth recording because the day someone switches to a distroless
or slim base to shrink the image, the health check fails for ever while the application is
perfectly healthy — and ECS kills and restarts the task with no error that names curl.

**Fargate Spot for the seven services, on-demand for the broker.** Roughly 70% off, and every
application service tolerates a two-minute reclaim: they are stateless, the Kafka consumers are
idempotent by contract, and the outbox claim uses `FOR UPDATE SKIP LOCKED` so an interrupted
publish is re-claimed. A broker that disappears several times a day is an outage with extra
steps.

---

## 8. Storefront: private bucket, OAC, and the SPA rewrite

The bucket is private and CloudFront reaches it through **Origin Access Control**, which signs
requests with SigV4 so the bucket policy can name the distribution and refuse everyone else.

The alternative — a public bucket with static website hosting — is simpler and wrong in a way
that does not show: **the bucket's own URL keeps working**, so every file stays reachable without
passing through CloudFront. That bypasses the security headers, the TLS policy, and any WAF
attached later, and nothing in the application would ever notice.

The bucket policy scopes the CloudFront principal with `AWS:SourceArn`. Without that condition it
reads "any CloudFront distribution in any AWS account may read this bucket", which is a real
exploitable misconfiguration — anyone can create a distribution.

**403 and 404 both rewrite to `/index.html` with a 200.** React Router owns the URL space;
without this, `/produse/lapte` asks S3 for an object that does not exist and the customer gets
CloudFront's XML error document. Every deep link, every bookmark and every refresh outside `/`
breaks — while the site works perfectly when navigated from the home page, which is why it
survives casual testing.

**The certificate must be in us-east-1**, wherever everything else lives. CloudFront is global
and reads certificates only from there; one issued in `eu-central-1` is rejected with an error
naming neither region. The API's certificate is a *different* certificate for the same domain, in
the load balancer's region. A module validation enforces the us-east-1 half.

**CSP is not set, and that is a gap rather than a decision.** The storefront calls the gateway on
another origin and loads map tiles from OpenStreetMap, so a correct policy has to name both — and
a wrong one breaks the map or the API with a console error nobody sees until a customer reports a
blank page. *Remove when* there is a running site to test a policy against.

---

## 9. State

`bootstrap/` creates the state bucket and keeps its own state local, because a configuration
cannot store state in a bucket it is also creating. That local state describes one bucket; losing
it costs a `terraform import`, which is why the usual advice to migrate it afterwards is more
ceremony than it is worth here.

- **Versioning is the most important setting in that file.** A corrupted or truncated state write
  is otherwise unrecoverable, and the failure is total: Terraform no longer knows what it
  manages, so the next plan proposes creating everything that already exists.
- `prevent_destroy` and `force_destroy = false`. A state bucket emptied by a `terraform destroy`
  in that directory takes every environment's state with it, and the resources those states
  describe become unmanaged — still running, still billed, invisible.
- A bucket policy denies `aws:SecureTransport = false`. Encryption protects the object at rest;
  this protects it in transit, and the state holds database passwords.
- `use_lockfile = true` — S3-native locking, which replaced the DynamoDB table in Terraform 1.10.
  Without a lock, two applies running at once interleave writes and the state describes neither.

> **The backend block cannot use variables.** It is read before Terraform evaluates anything, so
> `bucket = var.state_bucket` fails with "Variables not allowed" — which looks like a syntax error
> rather than a lifecycle one. Hence `backend "s3" {}` plus `-backend-config=backend.hcl`, which
> also keeps the account id out of version control.

---

## 10. Known gaps

Named rather than left to be discovered.

- **Never applied.** See the note at the top.
- **Nothing here has been applied**, so `USERS_BASE_URL` on the Orders task - added when Orders
  learned to hold a loyalty voucher - has never been observed working. It is the archetype of the
  variable that gets forgotten: the service starts fine without it and every checkout *without* a
  voucher succeeds, so the first failure would be a customer using one on a deployed environment.
- **The SES path has never sent a message from AWS.** `terraform validate` says the configuration
  is well-formed; it cannot say that `com.amazonaws.eu-central-1.email` exists in this region, that
  the identity ARN in the task role's policy matches what SES actually calls the identity, or that
  the SDK reaches the endpoint through private DNS. Those are three separate things that can each
  be wrong on their own, and every one of them fails the same way from the outside: the queue stops
  draining, with the reason in the task's logs rather than anywhere a health check looks.

  The endpoint's *service name* is not a guess - AWS's documentation distinguishes `email` (API)
  from `email-smtp` (SMTP) and §6b cites it - but "documented" and "available in eu-central-1 for
  this account" are different claims, and only an apply settles the second.
- **The SES domain is not verified and the account is not out of the sandbox.** Both are deliberate
  omissions with reasons in §6b, and both are also things that must happen before a single message
  reaches a customer. In the sandbox, sends succeed for verified test addresses and fail for real
  ones - which looks like a bug in the contact lookup rather than like an account setting.
- **No CI/CD.** Roadmap step 11. The pieces are here — ECR repositories, an ECS cluster name, a
  CloudFront distribution id for the invalidation — but no workflow uses them. Deploying by hand
  works; the OIDC role a GitHub Actions workflow would assume does not exist yet.
- **No DNS.** `api_domain` is a variable and nothing creates a record for it. The hosted zone may
  live in another account, and a record written into a zone Terraform does not own fails in a way
  that is tedious to unpick. Until the record exists, the ALB answers on its own name but
  presents a certificate for `api_domain`, so a browser refuses with a name mismatch — expected,
  not a misconfiguration.
- **No alarms.** Nothing pages anyone. The metrics exist (Container Insights is on, Performance
  Insights is on, the ALB publishes 5xx counts) and no alarm reads them. **Consumer lag is the
  one that matters most** and is the hardest to get from a self-managed broker — the blueprint
  requires watching it, and there is nothing here that does.
- **No WAF.** The ALB is the only public surface and has no rate limiting in front of it. The
  security review already flagged rate limiting on `/api/auth/*` as open; a WAF rule would be one
  way to close it without touching the services.
- **Single broker, single-AZ database.** Both are cost decisions, both are documented above, and
  both are wrong for anything with customers.
- **Images must be built *for* ARM64.** All seven Dockerfiles use `eclipse-temurin:21-jre-alpine`,
  which is published multi-arch, so the base is fine — but the image's architecture is whichever
  the build machine produced. CI has to target it explicitly (`docker buildx build --platform
  linux/arm64`), or the task fails at start with `image Manifest does not contain descriptor
  matching platform`. The alternative is `cpu_architecture = "X86_64"` and a ~20% premium.
