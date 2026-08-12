# martensa_terraform

AWS infrastructure for the Martensa platform — roadmap step 10.

Six Spring Boot services plus an API gateway on **ECS Fargate**, one **RDS PostgreSQL** instance
holding a database per service, **ElastiCache** for the Cart basket store, **Kafka** as a Fargate
task, an **ALB** in front of the gateway, and **S3 + CloudFront** for the storefront.

Application design lives in `docs/martensa-v2-architecture-blueprint.md` **in
martensa-platform-parent** — one copy for the whole platform. Why each choice here was made, and
what breaks without it, is in [`docs/infrastructure.md`](docs/infrastructure.md).

---

## Layout

```
bootstrap/            The state bucket. Runs once, with local state.
modules/
  network/            VPC, subnets, VPC endpoints, the security group chain
  ecr/                One repository per service, immutable tags
  database/           RDS PostgreSQL, one database and one role per service
  redis/              ElastiCache for the Cart basket store
  kafka/              Single-broker Kafka in KRaft mode, on Fargate, backed by EFS
  ecs-cluster/        Cluster, the two IAM roles, Cloud Map namespace
  service/            One Spring Boot service on Fargate. Used seven times.
  alb/                Load balancer, HTTPS listener, the gateway's target group
  frontend/           Private S3 bucket behind CloudFront with OAC
environments/dev/     Everything wired together
```

## Running it

Nothing here has been applied. It is `fmt`-clean, `validate`-clean and `tflint`-clean; that
catches syntax, types, unused declarations and provider misuse, and it does not catch a name
already taken or a quota you do not have. Expect the first real `plan` to surface something.

```bash
# 1. The state bucket, once per account.
cd bootstrap
terraform init
terraform apply -var="bucket_name=martensa-tfstate-<account-id>"
terraform output backend_config     # paste into environments/dev/backend.hcl

# 2. The platform.
cd ../environments/dev
cp terraform.tfvars.example terraform.tfvars   # fill it in
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
```

### Three things Terraform does not do

**Certificates.** Two are needed and they are different: one for the API, in the same region as
the load balancer, and one for the storefront, which **must be in us-east-1** because CloudFront
reads certificates from nowhere else. Issuing one requires proving control of a domain, and a
validation record written into a zone Terraform does not own hangs in `PENDING_VALIDATION` for
ever.

**The per-service databases.** RDS has no public endpoint, and Terraform runs outside the VPC.
Giving it a path in would mean either a public database or a bastion, and both are worse than one
manual step:

```bash
terraform output -raw database_bootstrap_sql > /tmp/bootstrap.sql
# then run it against the instance through an ECS Exec session or an SSM port-forward
```

**The secret values.** The JWT signing key and the EuPlătesc merchant key are created empty and
filled in with `aws secretsmanager put-secret-value`. A value written in Terraform lands in the
state file in plain text; for a key that mints tokens for every account, that is not a trade
worth making. See `environments/dev/secrets.tf`.

## Cost

Roughly **$75–90 a month** with everything running, at the defaults in this repo.

| | |
|---|---|
| ALB | ~$17 — the floor, charged whether or not anything is served |
| RDS `db.t4g.micro` | ~$12 + storage |
| ElastiCache `cache.t4g.micro` | ~$11 |
| Fargate, 8 tasks | ~$25 with Spot on the seven services |
| VPC interface endpoints | ~$15 for four endpoints across two AZs |
| EFS, ECR, CloudWatch, CloudFront | a few dollars |

**No NAT Gateway**, which would be $32 a month per zone on its own. The private subnets reach AWS
through VPC endpoints and reach nothing else — cheaper, and a tighter boundary.

Setting every entry in `desired_counts` to zero parks the compute without destroying anything.
The ALB, the database and the cache keep billing; that is about $40 for an environment nobody is
using, which is the number to weigh against `terraform destroy`.

## Checks

```bash
terraform fmt -recursive -check
terraform validate                       # per directory, after `init -backend=false`
tflint --recursive
```
