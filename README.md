# 🏢 AWS Organizations — Landing Zone Bootstrap

> Terraform configuration that stands up the AWS Organization, OU hierarchy, and six member accounts for the multi-account landing zone. This is the **first** Terraform configuration deployed while everything else (SSO, VPCs, per-account resources) from the multi-account AWS infrastructure Terraform configuration  (**Terraform-platform**) repo depends on its outputs(**Accounts ID**).

---

## 📋 Table of Contents

- [Overview](#overview)
- [What This Creates](#what-this-creates)
- [OU & Account Layout](#ou--account-layout)
- [Region Restriction SCP](#region-restriction-scp)
- [Prerequisites](#prerequisites)
- [First-Time Setup](#first-time-setup)
- [Usage](#usage)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [State](#state)
- [Security Notes](#security-notes)
- [Known Issues / TODOs](#known-issues--todos)

---

## 🎯 Overview

This Terraform configuration manages **AWS Organizations** for the management account. It:

1. Enables AWS Organizations with all features and Service Control Policies + Tag Policies
2. Builds the OU hierarchy: `Security` → `Infrastructure` → `Workloads` (`Prod` / `Dev`)
3. Creates 6 member accounts, one per OU
4. Delegates the **Security** account as the org-wide administrator for GuardDuty, Security Hub, and Access Analyzer
5. Publishes every account ID to **SSM Parameter Store** so downstream Multi-Account AWS Infrastructure repo (**Terraform-platform**) (SSO, per-account VPCs, etc.) can read them without hardcoding.

---

## 📦 What This Creates

| Resource | Count | Notes |
|---|---|---|
| `aws_organizations_organization` | 1 | Feature set `ALL`, SCPs + Tag Policies enabled |
| `aws_organizations_organizational_unit` | 5 | Security, Infrastructure, Workloads, Workloads/Prod, Workloads/Dev |
| `aws_organizations_account` | 6 | security, security-analytics, network, monitoring, production, development |
| `aws_organizations_delegated_administrator` | 3 | Security account delegated for GuardDuty, Security Hub, Access Analyzer |
| `aws_organizations_policy` | 1 | Region-restriction SCP — denies actions outside `var.allowed_regions` |
| `aws_organizations_policy_attachment` | 1 | Attaches the region-restriction SCP — currently to the **Dev OU only**, see [Region Restriction SCP](#region-restriction-scp) |
| `aws_ssm_parameter` | 6 | `/organizations/accounts/<name>` → account ID |
| `terraform_deploy_role` module | 1 | Cross-account IAM role Terraform assumes to deploy into each account |

---

## 🗂️ OU & Account Layout

```
Root
├── Security
│   ├── security              (GuardDuty / Security Hub / Access Analyzer delegated admin)
│   └── security-analytics    (AI-generated security findings analysis)
├── Infrastructure
│   ├── network                (shared networking)
│   └── monitoring             (centralized observability)
└── Workloads
    ├── Prod
    │   └── production         (live workload hosting)
    └── Dev
        └── development        (dev/test)
```

Each account is created with `role_name = "OrganizationAccountAccessRole"` and `prevent_destroy = true` in its lifecycle block, so `terraform destroy` will not delete accounts by default — you'd need to remove the lifecycle rule intentionally first.

---

## 🌍 Region Restriction SCP

A Service Control Policy (`aws_organizations_policy.region_restriction`, id `p-r2cbxwc8`) denies all actions outside `var.allowed_regions` (default: `eu-west-1`, `eu-west-2`), with an exclusion list (`not_actions`) for global services that don't run in a specific region — IAM, STS, Organizations, Billing, Support, CloudFront, Route 53, SSO/Identity Center, GuardDuty, Security Hub, Access Analyzer, and a few others.

**⚠️ Current rollout status: deployed to Dev, pending validation before promoting to root.** The policy is attached only to the **Dev OU** (`aws_organizations_organizational_unit.workloads_dev`), not the organization root. This is intentional since SCPs applied at root affect every account including the management account.

1. ✅ Deploy the SCP, attached to Dev only — applied successfully
2. ⏳ Verify normal operations still work in the `development` account (SSO login, CLI workflows, anything else that account uses day-to-day)
3. ⏳ Confirm the deny actually triggers for a disallowed region, e.g.:
   ```bash
   aws ec2 describe-instances --region us-east-1 --profile development
   ```
4. ⏳ Once confident nothing is broken, change the attachment's `target_id` from the Dev OU to `local.root_id` to enforce it org-wide

If something we rely on gets unexpectedly denied during testing, add the relevant service to the `not_actions` list in `main.tf` and re-apply we don't promote to root until Dev has run cleanly for a while.

---

## 🔧 Prerequisites

- Terraform >= 1.10.0
- AWS CLI >= 2.0, authenticated against the **management account**
- An existing AWS Organization (this config imports it see below rather than creating one from scratch)
- S3 bucket `james-terraform-state-2026` in `eu-west-2` for remote state
- Unique root email addresses for each of the 6 member accounts (AWS requires a distinct email per account — this repo uses Gmail `+` aliases off one inbox)

---

## 🚀 First-Time Setup

AWS Organizations can only have one root, so if an Organization already exists in the management account, **import it before running `apply`**:

```bash
terraform init

terraform import aws_organizations_organization.this r-sywu
```

Only needs to be run once. After the import we issue `terraform plan` / `terraform apply` as normal.

---

## ▶️ Usage

```bash
# Authenticate to the management account
aws sso login   # or export static credentials for the management account

terraform init
terraform plan
terraform apply
```

Outputs (account IDs, role ARNs) are also written to SSM automatically  no manual copy/paste needed for the multi-account AWS infrastructure Terraform configuration ***Terraform-platform*** repo.

---

## 📥 Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `home_region` | Primary AWS region | `string` | — (required; no default) |
| `management_account_id` | AWS Account ID of the existing management account | `string` | — (required) |
| `account_emails` | Unique root email per member account (`security`, `security_analytics`, `network`, `monitoring`, `production`, `development`) | `object` | — (required) |
| `allowed_regions` | Regions permitted by the region-restriction SCP. Enforced via `aws_organizations_policy.region_restriction` — see [Region Restriction SCP](#region-restriction-scp) for current rollout scope | `list(string)` | `["eu-west-1", "eu-west-2"]` |

---

## 📤 Outputs

| Name | Description |
|---|---|
| `organization_id` | The AWS Organization ID |
| `root_id` | Root OU ID |
| `account_ids` | Map of account name → AWS Account ID |
| `cross_account_role_arns` | Map of account name → `OrganizationAccountAccessRole` ARN, for assuming into each member account |

Account IDs are also mirrored to SSM at `/organizations/accounts/<name>` for consumption by other repos (e.g. the `management-account` and `member-accounts` stacks).

---

## 🗄️ State

| Setting | Value |
|---|---|
| Backend | S3 |
| Bucket | `james-terraform-state-2026` |
| Key | `org/terraform.tfstate` |
| Region | `eu-west-2` |
| Locking | Native S3 lockfile (`use_lockfile = true`) |
| Encryption | Enabled |

---

## 🔐 Security Notes

- **`terraform.tfvars` contains real email addresses** for every member account. Treat it as sensitive — keep it out of version control (add to `.gitignore`) or move the values into a secrets manager / CI variable if this repo is ever made public.
- **`role_name = "OrganizationAccountAccessRole"`** is the default AWS-managed role granted to the *management account* in every member account it creates. It has full administrative access in each member account — the `terraform_deploy_role` module and downstream SSO permission sets are what actually constrain day-to-day access; this role is the "break-glass" path.
- **`prevent_destroy = true`** on every account resource is intentional friction against accidentally deleting a live AWS account via `terraform destroy`.
- Delegated administration is scoped to exactly three services (GuardDuty, Security Hub, Access Analyzer) — the Security account is not a blanket delegated admin for the whole org.
- The region-restriction SCP is deliberately scoped to the **Dev OU only** while it's being validated — see [Region Restriction SCP](#region-restriction-scp). Do not attach it to `local.root_id` until it's been confirmed not to break normal operations, since a mistake at root can affect the management account's own access.

---

## 🐛 Known Issues / TODOs
- **`terraform.tfvars` still contains real email addresses and the management account ID in plaintext.** Fine for a personal/learning setup, but gitignore it (or move to a secrets manager / CI variables) before making the repo public.
