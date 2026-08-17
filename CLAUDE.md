# CLAUDE.md — Martensa v2

> **This file is canonical.** The other repos (`martensa-users`, `martensa-catalog`, …,
> `martensa-frontend`, `martensa_terraform`) hold byte-identical copies, because an agent loads
> the `CLAUDE.md` of whichever repo it is working in. Edit **this** copy and propagate outward; a
> change made in another repo will be overwritten and lost. **Eleven copies** today — check with
> `md5sum */CLAUDE.md` before assuming they are in step.

Full architecture: `docs/martensa-v2-architecture-blueprint.md` in this repo — **one copy for
the whole platform**, never duplicated into a service repo.

Summary: 7 Spring Boot microservices (Users, Catalog, Inventory, Cart, Orders, Payments,
Notification) + API Gateway. Polyrepo — one git repo per service. Database-per-service (own Postgres each, Cart uses
Redis), UUID primary keys, REST for synchronous calls, **Kafka** for asynchronous events, deploy
target AWS ECS Fargate. All services inherit the `martensa-platform-parent` POM.

**Built so far:** all seven services, the **API Gateway**, and the **storefront** — Users (auth,
RS256 JWT issuer, sign in with Google, loyalty points ledger, account-security outbox), Catalog
(products, categories, promotions, first Kafka producer), Inventory (stock, reservations, first
Kafka consumer, and since V4 a producer too), Cart (Redis, no relational database), Orders (the
first orchestrator and the generic outbox), Payments (EuPlătesc hosted page + signed IPN, the
first inbound webhook), Notification (`martensa-notification` — outbound email, seven topics
consumed and none produced, no customer-facing HTTP at all), Gateway (Spring Cloud Gateway,
reactive, owns no data at all), Frontend (`martensa-frontend` — React 19 + Vite + TypeScript +
Tailwind, talks only to the gateway, owns no data either), and the **AWS infrastructure**
(`martensa_terraform` — nine modules, written and validated, **never applied**).
**Next:** roadmap step 11, CI/CD — the deploy stage, and a gate for the frontend.

**Every topic on the platform now has a consumer.** The two that did not — `PromotionStarted` and
`PaymentFailed` — are both read by the notification service. The second was deliberately
unconsumed (blueprint §4) and the reasoning was right at the time: a declined card changes nothing
about the order, so a consumer that only logged would be machinery pretending to be a decision.
What changed is that there is now something to *do* with it. The premise fell; the rule did not.

**Three services now produce as well as consume**, which is the shape to expect from here:
Catalog (`promotion-started`), Inventory (`stock-ran-low`), Users (`account-security`). A service
that publishes needs an outbox — a marker column for one event type, the generic table for
several — and the reasoning for both is in the Kafka section below.

**The frontend is a different stack and a different rule set.** `martensa-frontend` is Node, not
Maven: `npm run verify` (typecheck + Vitest + build) is its gate, there is no Checkstyle or
SpotBugs, and none of the Java conventions below apply to it. What does carry across is the
discipline: the client formats money and never computes it, every server response is typed by
hand so a renamed field is a compile error, and each workaround in
`martensa-frontend/docs/infrastructure.md` gets a *why* and a *remove when*. Node was installed
on this machine with `winget install OpenJS.NodeJS.LTS`; the tooling does not pick it up until a
new shell, so `node: command not found` right after installing means the shell, not the project.

**The infrastructure is a third stack, and the riskiest one.** `martensa_terraform` is HCL:
`terraform fmt -check -recursive`, `terraform validate` (per root directory, after
`terraform init -backend=false`) and `tflint --recursive` are its gate. No Checkstyle, no
SpotBugs, no JaCoCo, and none of the Java conventions below apply. What is different in kind
from the other two repos is that a mistake here is not a failing test — it is a resource that
exists, is billed, and may be reachable from the internet. Rules, and every one of them comes
from writing the repo rather than from a style guide:

- **Never write a secret value in Terraform.** Terraform records every attribute of every
  resource it manages, so anything it generates lands in the state file in plain text, in every
  version the bucket keeps, and in the plan output of whoever runs `terraform plan`. Three tiers
  by who generates the value: RDS generates the master credential so it never enters state;
  Terraform generates the per-service database passwords, which is an accepted trade and the
  reason the state bucket is encrypted and refuses plain HTTP; the JWT signing key and the
  EuPlătesc merchant key are created empty with `ignore_changes` and written once by hand.
- **`*.tfstate` and `*.tfvars` are never committed.** The first holds those generated passwords;
  the second names the account, the domain and the merchant.
- **Every module declares its own `required_providers` and `required_version`.** A module without
  them inherits whatever the caller happens to have, so it works here and breaks silently when
  reused — with an error naming a missing argument rather than a provider version.
- **Anything CI deploys needs `lifecycle { ignore_changes = [...] }`.** CI registers a new ECS
  task definition revision; without this the next `terraform apply` reads the running revision as
  drift and rolls the service back to whatever image Terraform knows about, silently undoing a
  deployment.
- **Cost is a design constraint, not a footnote.** A resource with a non-trivial bill states its
  price in the comment beside it. That is why there is no NAT Gateway — $32/month/AZ before a
  byte of traffic — and why the broker is a Fargate task rather than MSK.
- **Do not `apply`.** Write it, `fmt`/`validate`/`tflint` it, show the plan. Applying is Victor's
  call, and `plan` needs credentials this machine does not have.
- **Say what a check does *not* cover.** `validate` catches types, unknown arguments and unused
  declarations; it cannot catch a name already taken, a quota, or an instance class a region does
  not offer. "Validated" and "works" are different claims and must not be blurred.

Same discipline as everywhere else: one `docs/infrastructure.md` per repo, every workaround with
a *why* and a *remove when*, and comments that say what breaks without the line.

**The Kafka broker is not per-service.** It lives in
`martensa-platform-parent/docker-compose.platform.yaml` and must be started before running any
service: `docker compose -f docker-compose.platform.yaml up -d`. A forgotten start looks like a
consumer logging connection failures while the HTTP API works fine.

---

## Working style — review, don't auto-implement

I write the implementation myself. Your job is to review what I've written and point out where a
better solution exists — not to write the code for me unless I explicitly ask.

- Default mode is **review**: read the file(s) I point you at, evaluate them against this doc and
  the blueprint, and report findings (bugs, deviations from the conventions below, missed edge
  cases, a cleaner approach) as a list I can act on.
- Don't edit files on your own initiative. If you see a fix, describe it and show the change as a
  suggestion (diff or snippet) — apply it only if I say to.
- **Say *why* it's better, not just *what* to change.** I'm learning this stack; the reasoning is
  the thing I keep. A finding that doesn't explain the failure it prevents isn't finished.
- If code is functionally correct but stylistically different from what you'd write, don't flag
  it. Flag actual bugs, violations of the conventions here, missing tests, or a genuinely
  simpler/safer approach — not personal preference.
- It's fine to ask a clarifying question about intent before reviewing, if the code's purpose
  isn't obvious from context.

**When I do ask you to implement**, these override the default and you don't need to ask again:

- "fix the build" — Checkstyle/SpotBugs/test failures from `mvn verify`. Mechanical, not design.
- The `@SpringBootApplication` bootstrap class (`<Service>Application.java`) — boilerplate.
  Create it whenever a service module lacks one, at the root of `com.martensa.<service>` so
  component scanning covers the module.
- "do it", "implement it", "make it the best" and similar — that is authorisation for the whole
  task, including tests, docs and the commit. Don't stop halfway to re-ask.

---

## Build & quality gates

*Java repos. The frontend's gate is `npm run verify`; `martensa_terraform`'s is
`terraform fmt -check -recursive`, `terraform validate` per root directory, and
`tflint --recursive` — see the third-stack note above.*

- `mvn verify` runs Checkstyle + SpotBugs + unit tests + integration tests (Failsafe) + the
  JaCoCo gate (70% instruction / 60% branch). **Zero violations before a task is done** — don't
  report a task complete without running it.
- `mvn spring-boot:run -Dspring-boot.run.profiles=local` starts a service against its Docker
  Compose dependencies (auto-started by Spring Boot's Docker Compose support).
- **PowerShell splits `-D` arguments at the dot.** Quote each one: `mvn verify "-Djacoco.skip=true"`.
- **Never write a `.java` file with PowerShell `Set-Content -Encoding utf8`.** Windows PowerShell
  5.1 writes a UTF-8 **BOM**, and `javac` rejects it with `illegal character: '﻿'` on line 1
  of every affected file — which reads like mass corruption rather than an encoding setting. Use
  the Write tool. To repair files that already have it, rewrite the bytes with
  `System.Text.UTF8Encoding($false)`; note that `File.ReadAllText` silently strips the BOM, so a
  check for it has to read raw bytes or it will report every file as clean.
- Integration tests need the container runtime (**Rancher Desktop**, not Docker Desktop) running.
  If `mvn verify` fails with "Could not find a valid Docker environment", that is the machine,
  not the change — say so plainly rather than reporting a failure as if the code caused it.
- **Never weaken a Checkstyle/SpotBugs rule in a service's own `pom.xml`** to make a build pass.
  Fix the code, or change it in `martensa-platform-parent` so it applies everywhere. A rule that
  fires is usually right: `IllegalCatch` on a `@Scheduled` method caught a `try/catch` that was
  reimplementing, worse, what Spring's `LOG_AND_SUPPRESS_ERROR_HANDLER` already does.

---

## Java conventions

- Package layout: `com.martensa.<service>.{api,domain,repository,service,dto,mapper,client,event,config}`.
  Don't add packages outside this set — a scheduled job is a `service`, not a `scheduler` package.
- Controllers return DTOs only — never a JPA entity in an API response.
- Entity ↔ DTO conversion goes through a `mapper` class (MapStruct preferred) — don't hand-build
  DTOs field by field in a controller or service.
- Primary keys are UUID, generated in application code (`UUID.randomUUID()` in the constructor
  that builds a *new* entity), not DB identities and **not as a bare field initializer** —
  Hibernate re-invokes the no-arg constructor on load, which would regenerate it every time.
- Cross-service HTTP calls live in `client`, using a typed `RestClient` wrapper — no ad-hoc
  `RestTemplate`/`WebClient` scattered through service classes.
- One `@ControllerAdvice GlobalExceptionHandler` per service, answering with `ProblemDetail`.
  Domain exceptions extend the service's base exception — never throw raw `RuntimeException`.
- **Never write a query, repository, or entity that reaches into another service's tables.** If a
  task seems to need that, the call should be a REST client call or an event — check the
  blueprint's communication-patterns section.
- Pass the moment explicitly (`doSomething(Instant now)`) rather than calling `Instant.now()`
  deep inside. It matches the existing code and makes "what happens tomorrow" a test that states
  a time instead of one that waits for it.

### Money and time

- Money is `BigDecimal` mapped to `NUMERIC`, never a floating-point type. Compare with
  `compareTo`/`isEqualByComparingTo`, never `equals` — `7.50` and `7.5` are unequal by `equals`.
- Time windows are **half-open** `[start, end)`, so one campaign can hand over to the next at the
  same instant with neither a gap nor an overlap.
- Timestamps are `TIMESTAMP WITH TIME ZONE` / `Instant`. No `LocalDateTime` in persisted state.

### Constraints belong in the database

A check-then-insert in a service always loses to a concurrent insert. **The constraint is the
only thing that actually holds**, so:

- Write the constraint (UNIQUE, EXCLUDE, CHECK, FK) in the migration.
- Let the violation happen, catch `DataIntegrityViolationException`, and translate it into a
  domain exception the caller can read.
- Keep the cheap pre-check too, for a readable message in the common case — but never as the
  only guard.
- **Name the constraint in the translation** when a table has more than one. Reporting an EAN
  collision as a duplicate slug sends someone to change a name that was never the problem.

---

## Migrations

- Flyway, `V<n>__<snake_case_description>.sql`, never edited once pushed.
- **A column added to an existing table almost always needs a backfill in the same migration.**
  Ask what the new column means for rows that already exist. On an empty local database the
  `UPDATE` changes nothing, which is exactly why it gets left out and only bites in production —
  a nullable `announced_at` with no backfill would have announced the entire promotion history
  on first deploy.
- Partial indexes (`... WHERE announced_at IS NULL`) for columns queried on a small subset — the
  index then stays small no matter how much history accumulates.
- PostgreSQL-only features are fine; this platform is PostgreSQL. Use a native query when JPQL
  can't express one (`FOR UPDATE SKIP LOCKED`) rather than reaching for a vendor query hint.

---

## Kafka and events

Kafka replaced the original SNS/SQS plan — blueprint §4.1 for why. Blueprint §4.2 is the
delivery-semantics contract, and it binds every service:

- **Every topic is at-least-once. Every consumer must be idempotent.** A producer cannot both
  send and record that it sent atomically, so one of the two goes first: sending first
  republishes on a crash, recording first loses the event silently. **Always take the duplicate.**
- **A producer needs an outbox** — the event recorded in the same transaction as the state change,
  published by a poller. Without it, a commit followed by an unreachable broker loses the event
  with nothing recording that it was owed. Catalog uses a marker column (`promotions.announced_at`);
  a service with several event types wants the generic outbox table.
- The claim query needs `SELECT ... FOR UPDATE SKIP LOCKED`, and the publish must happen **inside**
  the claiming transaction. More than one task runs in Fargate; without the lock every instance
  publishes every event on every tick, and committing the claim early releases the locks while
  the send is still in flight.
- `@Scheduled(fixedDelay)`, never `fixedRate` — `fixedRate` overlaps ticks inside one instance
  when downstream is slow.
- A `@Scheduled` method must live in a **different class** from the `@Transactional` method it
  calls. Calling it on `this` bypasses the proxy and runs the whole thing with no transaction —
  and a unit test with a mocked repository cannot see that.
- Declare topics as `NewTopic` beans. Auto-creation makes the topic appear on first send, after
  which an already-subscribed consumer waits for its metadata refresh — five minutes by default,
  and the symptom is a working producer that looks broken.
- Producer timeouts are interdependent: `delivery.timeout.ms >= linger.ms + request.timeout.ms`,
  enforced by throwing from `send()` rather than at startup. **Change one, check all three.**
- Event records are a **published contract**. Adding an optional field is safe; renaming or
  removing one breaks a separately deployed consumer and needs a new topic or a version field.
  Carry what the consumer needs to render the event, so it doesn't call back and read later state.

### Consuming (Inventory is the reference implementation)

- **Prefer idempotency that falls out of existing state** over a `processed_events` table. If
  the work produces a status that can only be entered once, that status *is* the record that the
  work happened — no extra write, no cleanup job, no "what if the insert succeeds and the work
  doesn't".
- **Turn off `__TypeId__` type headers** (`JsonDeserializer.setUseTypeHeaders(false)`). Trusting
  them means the producer's Java package name is the contract, so another team repackaging its
  own class breaks you at runtime in a deploy that touched neither your repo nor your tests.
- **Wrap the deserialiser in `ErrorHandlingDeserializer`** and pair it with a
  `DeadLetterPublishingRecoverer`. Deserialisation happens before the listener, so without it a
  poison record cannot be dead-lettered and the container re-reads it forever.
- **`ErrorHandlingDeserializer` delivers a null payload** — guard for it first thing in the
  listener, or the real failure is dead-lettered as a `NullPointerException` in your code.
- **Every field on an inbound event is written by another repository.** A record constructor
  does not enforce non-null and Jackson builds a fully-formed object from `{}`, so validate the
  fields you dereference. Trusting them because the type says `UUID` is how a cross-service NPE
  lands in the service that did nothing wrong.
- `enable-auto-commit: false` and `ack-mode: record`. Auto-commit advances the offset even when
  the handler crashed, which loses the event silently — the one outcome at-least-once exists to
  prevent.
- **A consumer must not create the topics it reads** (`allow.auto.create.topics: false`). The
  producer owns the topic and its partition count; a consumer that starts first would cap the
  producer's ordering guarantees forever.
- **Exclude Kafka from the health check.** A broker outage must not make the service report
  unhealthy, or the orchestrator kills a task that can still serve reads. Watch consumer lag.

---

## Testing

- Unit: JUnit 5 + Mockito, one class per class under test, `<ClassName>Test`. Mock collaborators,
  not the class under test.
- Integration: Testcontainers with the real thing (Postgres, Kafka — **not** H2, not a mock, not
  a protocol-compatible substitute), named `<Feature>IT`, run by Failsafe via `mvn verify`.
- Every new endpoint ships with both: a unit test for the service logic and an integration test
  for the full request → response path.
- **Disable scheduled jobs in the test profile.** A tick firing between arrange and assert
  consumes the rows the test set up, and the failure looks like a duplicate or a missing event
  rather than like a scheduler. Call the method directly instead.
- Reset state with one `TRUNCATE ... CASCADE`, not `deleteAll()` — `deleteAll()` deletes in
  arbitrary order and fails on a self-referencing FK.
- Consumers in tests must be positioned at the end of the topic before the code under test runs,
  and **both** the subscribe-poll and the seek must be resolved: `subscribe` assigns no
  partitions until a poll, and `seekToEnd` only marks them for reset — `position()` is what
  blocks until the broker answers. A non-blocking `poll(ZERO)` leaves the consumer positioned
  past its own test data, 20 seconds from a misleading "No records found for topic".
- If a change removes or weakens a test, say so explicitly rather than letting it pass silently.

---

## How to implement a task here

1. Identify which service owns the data (DB-ownership table in the blueprint). If a task seems to
   need two services' data, it's a cross-service call or an event, not a shared query.
2. Build order: migration → entity → repository → DTO + mapper → service (+ unit test in the same
   change) → controller (+ integration test in the same change).
3. For anything crossing a service boundary, decide synchronous REST (`client`) vs Kafka event
   per the blueprint — don't default to REST out of convenience.
4. Run the repo's gate: `mvn verify` in a Java service, `npm run verify` in the frontend,
   `terraform fmt`/`validate`/`tflint` in `martensa_terraform`.
5. Update the docs **in the same change**: the repo's own `docs/infrastructure.md` for what is
   true of that repo, this repo's for anything platform-wide, and the blueprint if the data
   model, a service boundary or a deployment target moved. Each workaround gets a *why* and a
   *remove when*.

**A change that spans a service and its infrastructure spans two repos**, and the infrastructure
half is the one that gets forgotten because nothing fails without it. A new environment variable
is a task-definition change in `martensa_terraform`; a new secret is a Secrets Manager entry and
a line in the execution role's policy. The service starts fine locally either way — it fails on
ECS, at container start, with an error that names the secret and not the missing permission.

### Writing it down

Comments and docs explain **why**, and specifically what breaks without this. "Sets the batch
size" is worthless; "bounds how long the transaction holds its row locks" is the reason the line
exists. When a bug is found, record the symptom too — the next person meets the symptom first,
and "No records found for topic" pointing at a healthy producer is worth more than a tidy
description of the fix.

---

## Don't

- Add a new microservice without flagging it first — check the blueprint's deferred-features list.
- Introduce a shared database or table between services.
- Skip inheriting `martensa-platform-parent` "just for this one service."
- Duplicate a platform-wide doc into a service repo. One copy, linked to. `CLAUDE.md` is the sole
  exception, and only because the tooling requires a copy per repo.
- Report a task complete on unit tests alone when integration tests exist and haven't run. Say
  which ones ran, which didn't, and why.
- Run `terraform apply`, or weaken a guard rail (`deletion_protection`, `skip_final_snapshot`,
  `prevent_destroy`) to get past an error. Those exist because the thing they protect cannot be
  rebuilt from source.
- Claim infrastructure "works" on the strength of `validate`. It means the configuration is
  well-formed, not that it can be created in a real account.
