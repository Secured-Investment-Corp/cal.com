# Cal.com ECS Deployment — cal.cogonation.com

## Overview

Deploy this Cal.com fork to AWS ECS Fargate. Reuses the existing SIC infrastructure (same AWS account 289236010466, us-east-2, same VPC/ECS cluster/ALB). A host-based routing rule routes `cal.cogonation.com` traffic to a new Cal.com ECS service. SSL via ACM. Secrets via AWS Secrets Manager. CI/CD triggers on push to `main`.

---

## Architecture

```
Internet
   │
   ▼
Route 53 / DNS
cal.cogonation.com → ALB DNS name
   │
   ▼
Shared ALB (existing)
   │  HTTPS listener rule: host_header = cal.cogonation.com
   ▼
Target Group: calcom-ingress (port 3000)
   │
   ▼
ECS Fargate Task: sic-calcom
  Container: calcom-web (port 3000)
  2 vCPU / 4 GB RAM
  Image: ECR sic-calcom:{git-sha}
  Secrets: AWS Secrets Manager → sic/calcom/prod/env
   │
   ▼
RDS PostgreSQL: calcom-prod (private subnet)
```

---

## Files Changed / Created

| File | Purpose |
|---|---|
| `terraform/main.tf` | Infrastructure for ECS service, target group, listener rule, security groups |
| `.github/build.yaml` | Builds Docker image with Cal.com build args, pushes to ECR, runs terraform plan |
| `.github/deploy.yaml` | Triggered on push to main — builds image, updates SSM image tag, runs terraform apply |

---

## How Deploys Work

1. Push to `main`
2. `deploy.yaml` calls `build.yaml` which builds the Docker image with all required build args and pushes to ECR tagged with the short git SHA
3. Deploy job updates SSM parameter `/sic/calcom/prod/image-tag` to the new SHA
4. Terraform runs — it reads the SSM param to get the image tag, updates the ECS task definition, and ECS does a rolling deploy
5. New container starts, runs `prisma migrate deploy` then starts Next.js on port 3000

---

## Docker Build Args (baked at build time)

| Arg | Value |
|---|---|
| `NEXT_PUBLIC_WEBAPP_URL` | `https://cal.cogonation.com` |
| `NEXT_PUBLIC_API_V2_URL` | `https://cal.cogonation.com/api/v2` |
| `CALCOM_TELEMETRY_DISABLED` | `1` |
| `NEXT_PUBLIC_LICENSE_CONSENT` | `agree` |
| `DATABASE_URL` | From GitHub secret (needed for Prisma schema gen during build) |
| `NEXTAUTH_SECRET` | From GitHub secret |
| `CALENDSO_ENCRYPTION_KEY` | From GitHub secret |

---

## Runtime Secrets (injected by ECS from Secrets Manager)

All keys stored in `sic/calcom/prod/env` (JSON) are injected as environment variables into the container at runtime.

Minimum required keys:

| Key | Value |
|---|---|
| `DATABASE_URL` | `postgresql://calcom:PASSWORD@RDS-HOST:5432/calcom` |
| `DATABASE_DIRECT_URL` | Same as DATABASE_URL |
| `NEXTAUTH_URL` | `https://cal.cogonation.com` |
| `NEXTAUTH_SECRET` | `openssl rand -base64 32` |
| `CALENDSO_ENCRYPTION_KEY` | `openssl rand -base64 24` |
| `NEXT_PUBLIC_WEBAPP_URL` | `https://cal.cogonation.com` |
| `CALCOM_TELEMETRY_DISABLED` | `1` |
| `NEXT_PUBLIC_LICENSE_CONSENT` | `agree` |

Add email/SMTP, OAuth provider keys, and any other vars from `.env.example` as needed.

---

## Terraform Resources Created

| Resource | Name |
|---|---|
| `aws_lb_listener_certificate` | Attaches cogonation cert to shared HTTPS listener |
| `aws_lb_listener_rule` | Routes `cal.cogonation.com` → calcom target group (priority 10) |
| `aws_lb_target_group` | `calcom-ingress` — health check at `/api/health` |
| `aws_security_group` | `calcom-container-sg` — allows port 3000 in, all out |
| `aws_ecs_task_definition` | `sic-calcom` — 2048 CPU, 4096 memory |
| `aws_ecs_service` | `calcom-service` — Fargate, private subnets |

Resources referenced (not created) via data sources:
- Existing ECS cluster + ALB ARNs (from `sic/prod/terraform.tfstate` remote state)
- Existing HTTPS listener (port 443)
- Existing IAM role `GeneralECSTaskDefinitionExecutionRole`

---

## RDS Security Group

After the first `terraform apply`, the `calcom-container-sg` security group will exist. You need to manually add an inbound rule to your RDS security group:

- **Security group**: `calcom-rds-sg` (the one you attach to the RDS instance)
- **Rule**: PostgreSQL (port 5432) from source `calcom-container-sg`

---

## DNS

After the first `terraform apply`, add a DNS record for `cal.cogonation.com`:

- **Type**: CNAME
- **Name**: `cal`
- **Value**: ALB DNS name (find in EC2 → Load Balancers — looks like `sic-prod-xxxx.us-east-2.elb.amazonaws.com`)

---

## Verification Checklist

- [ ] `terraform plan` completes with no errors before first apply
- [ ] ECS service shows 1 task in RUNNING state
- [ ] ALB target group `calcom-ingress` shows target as Healthy
- [ ] `curl -I https://cal.cogonation.com` returns HTTP 200 or 302
- [ ] Browser visit shows Cal.com setup/login page

---

## Your To-Do List

Work through these in order. Don't push to main until all AWS steps are done.

### Step 1 — ACM Certificate
- [ ] Go to **AWS Certificate Manager → us-east-2 → Request certificate**
- [ ] Request a public cert for `cal.cogonation.com`
- [ ] Validate via DNS — ACM gives you a CNAME to add to your DNS provider for cogonation.com
- [ ] Wait until status shows **ISSUED** before continuing

### Step 2 — RDS PostgreSQL
- [ ] Go to **RDS → Create database**
- [ ] Engine: PostgreSQL 15, Template: your choice (db.t3.micro = free tier, db.t3.small = production)
- [ ] DB identifier: `calcom-prod`
- [ ] Username: `calcom`, generate a strong password and save it
- [ ] VPC: the `10.0.0.0/16` VPC (same as SIC apps)
- [ ] Subnet group: private subnets
- [ ] Public access: **No**
- [ ] Create a new security group called `calcom-rds-sg`
- [ ] Save the RDS hostname, port (5432), username, password, and database name

### Step 3 — ECR Repository
- [ ] Go to **ECR → Create repository**
- [ ] Name: `sic-calcom`, Private, defaults for everything else
- [ ] Save the full URI: `289236010466.dkr.ecr.us-east-2.amazonaws.com/sic-calcom`

### Step 4 — AWS Secrets Manager
- [ ] Go to **Secrets Manager → Store a new secret**
- [ ] Type: **Other type of secret** (key/value)
- [ ] Secret name: `sic/calcom/prod/env`
- [ ] Add every key from the "Runtime Secrets" table above with real values
- [ ] For `NEXTAUTH_SECRET`: run `openssl rand -base64 32` in your terminal and paste the output
- [ ] For `CALENDSO_ENCRYPTION_KEY`: run `openssl rand -base64 24` in your terminal and paste the output
- [ ] Save and copy the full secret ARN for your records

### Step 5 — SSM Parameter Store
- [ ] Go to **Systems Manager → Parameter Store → Create parameter**
- [ ] Name: `/sic/calcom/prod/image-tag`
- [ ] Type: String
- [ ] Value: `latest`

### Step 6 — GitHub Actions Variables
Go to this repo's **Settings → Secrets and variables → Actions**:

Variables tab — add or confirm these exist:

| Variable | Value |
|---|---|
| `ACTIONS_ROLE` | IAM role ARN used by SIC GitHub Actions (same one) |
| `AWS_REGION` | `us-east-2` |
| `ECR_REPO` | `289236010466.dkr.ecr.us-east-2.amazonaws.com/sic-calcom` |
| `TF_STATE_KEY` | `sic/calcom/prod/terraform.tfstate` |

- [ ] `ACTIONS_ROLE` set
- [ ] `AWS_REGION` set
- [ ] `ECR_REPO` set to the sic-calcom ECR URI
- [ ] `TF_STATE_KEY` set to `sic/calcom/prod/terraform.tfstate`

Secrets tab — add these:

| Secret | Value |
|---|---|
| `DATABASE_URL` | Your RDS connection string |
| `NEXTAUTH_SECRET` | Same value you put in Secrets Manager |
| `CALENDSO_ENCRYPTION_KEY` | Same value you put in Secrets Manager |

- [ ] `DATABASE_URL` set
- [ ] `NEXTAUTH_SECRET` set
- [ ] `CALENDSO_ENCRYPTION_KEY` set

### Step 7 — Push to Main
- [ ] Once all above steps are done, push to `main`
- [ ] Watch the Actions tab — build takes ~10-15 min (Cal.com is a large Next.js monorepo)
- [ ] If build fails, check the logs and let me know

### Step 8 — Wire Up RDS Security Group
- [ ] After terraform apply succeeds, go to **EC2 → Security Groups → `calcom-rds-sg`**
- [ ] Add inbound rule: PostgreSQL, port 5432, source = `calcom-container-sg`

### Step 9 — DNS
- [ ] Find your ALB DNS name in **EC2 → Load Balancers**
- [ ] Add a CNAME record: `cal.cogonation.com` → ALB DNS name
- [ ] Wait for DNS to propagate (~5 min if Route 53, up to 24h if external registrar)

### Step 10 — Verify
- [ ] Visit `https://cal.cogonation.com` — should see Cal.com