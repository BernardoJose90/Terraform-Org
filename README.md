# 🏢 Terraform-Org — AWS Organization + Management-Account Platform

> Terraform configuration for the **management account**. This is the **first** Terraform configuration deployed — everything else (SSO, VPCs, per-account resources) in the multi-account AWS infrastructure repo (**Terraform-Platform**) depends on the account IDs this repo publishes to SSM.
>
> The repo is two independent root modules, each with its own state:
>
> - **[`organization/`](organization/)** — bootstraps the AWS Organization itself: OUs, member accounts, SCPs, and publishes account IDs/tiers to SSM. **Never auto-applied by CI** — applied manually via the `management` AWS profile.
> - **[`platform/`](platform/)** — everything else the management account needs to run this repo's own CI safely: the `TerraformDeploy`/`TerraformPlan` IAM roles (via a module from Terraform-Platform), a read-only GitHub OIDC discovery role, the shared state bucket's policy, and a permissions boundary that caps `TerraformDeploy`. **This is the directory CI auto-applies** on merge to `main`, gated behind a `management-approval` GitHub Environment.

---

## 📋 Table of Contents

- [Overview](#overview)
- [`organization/` — What This Creates](#organization--what-this-creates)
- [`platform/` — What This Creates](#platform--what-this-creates)
- [OU & Account Layout](#ou--account-layout)
- [Region Restriction SCP](#region-restriction-scp)
- [Prerequisites](#prerequisites)
- [First-Time Setup](#first-time-setup)
- [Usage](#usage)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [State](#state)
- [CI/CD](#cicd)
- [Security Notes](#security-notes)
- [Known Issues / TODOs](#known-issues--todos)
- [License](#license)

---

## 🎯 Overview

1. `organization/` enables AWS Organizations features and Service Control Policies + Tag Policies
2. Builds the OU hierarchy: `Security` → `Infrastructure` → `Workloads` (`Prod` / `Dev`)
3. Creates 6 member accounts, one per OU, and delegates the **Security** account as org-wide admin for GuardDuty, Security Hub, Access Analyzer, and IAM Identity Center
4. Publishes every account ID (and a tier label) to **SSM Parameter Store** so this repo's own `platform/` module and the downstream **Terraform-Platform** repo can read them dynamically without hardcoding
5. `platform/` stands up the IAM roles this repo's own GitHub Actions CI assumes to plan/apply Terraform against the management account, a read-only discovery role Terraform-Platform's CI uses to look up account IDs, and the bucket policy on the shared state bucket that scopes each member account to its own state prefix

---

## 📦 `organization/` — What This Creates

| Resource | Count | Notes |
|---|---|---|
| `aws_organizations_organization` | 1 | Feature set `ALL`, SCPs + Tag Policies enabled |
| `aws_organizations_organizational_unit` | 5 | Security, Infrastructure, Workloads, Workloads/Prod, Workloads/Dev |
| `aws_organizations_account` | 6 | security, security-analytics, network, monitoring, production, development |
| `aws_organizations_delegated_administrator` | 4 | Security account delegated for GuardDuty, Security Hub, Access Analyzer, and IAM Identity Center |
| `aws_organizations_policy` | 1 | Region-restriction SCP — denies actions outside `var.allowed_regions` |
| `aws_organizations_policy_attachment` | 1 | Attaches the region-restriction SCP — currently to the **Dev OU only**, see [Region Restriction SCP](#region-restriction-scp) |
| `aws_ssm_parameter.account_ids` | 6 | `/organizations/accounts/<name>` → account ID |
| `aws_ssm_parameter.account_tier` | 7 | `/organizations/tiers/<name>` → `management-approval` or `automated`, one per account plus `management` itself |

---

## 📦 `platform/` — What This Creates

| Resource | Count | Notes |
|---|---|---|
| `module.terraform_deploy_role` | 1 | Sourced from `Terraform-Platform`'s `modules/terraform-deploy-role`, pinned to a commit SHA (not `ref=main`, see [Known Issues](#known-issues--todos)). Creates `TerraformDeploy`/`TerraformPlan` and their OIDC trust, gated behind the `management-approval` GitHub Environment |
| `aws_iam_policy.terraform_deploy_boundary` | 1 | Permissions boundary applied to `TerraformDeploy` — caps the module's shared (wider) permissions policy down to exactly the roles/policies/SSM path this account manages |
| `aws_iam_role.github_discovery` | 1 | `GitHubActionsAccountDiscovery` — read-only role assumed by **Terraform-Platform's** CI (a different repo) to discover account IDs from SSM |
| `aws_iam_role.terraform_org` | 1 | `TerraformOrgRole` — lets `organization/`'s manual applies write to SSM |
| `aws_iam_role.ssm_read_only` | 1 | `SSMReadOnly` — cross-account role each member account can assume to read `/organizations/*` |
| `aws_s3_bucket_policy.state` | 1 | Per-account, per-prefix policy on the (hand-created, not Terraform-managed) shared state bucket `james-terraform-state-2026` |
| `aws_iam_role_policy` (inline) | 4 | Gap-fill grants on `TerraformDeploy`/`TerraformPlan` for IAM management, the state bucket policy, and S3 lock-object access — see [Known Issues](#known-issues--todos) |
| `data.aws_ssm_parameter.account_ids_sso` | 6 | Reads each member account's ID back out of SSM (published by `organization/`) for use in the state bucket policy and `SSMReadOnly`'s trust policy |

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

A Service Control Policy (`aws_organizations_policy.region_restriction`) denies all actions outside `var.allowed_regions` (default: `eu-west-1`, `eu-west-2`), with an exclusion list (`not_actions`) for global services that don't run in a specific region — IAM, STS, Organizations, Billing, Support, CloudFront, Route 53, SSO/Identity Center, GuardDuty, Security Hub, Access Analyzer, and a few others.

**⚠️ Current rollout status: deployed to Dev, pending validation before promoting to root.** The policy is attached only to the **Dev OU** (`aws_organizations_organizational_unit.workloads_dev`), not the organization root. This is intentional since SCPs applied at root affect every account including the management account.

Once confident nothing is broken, change the attachment's `target_id` from the Dev OU to `local.root_id` to enforce it org-wide.

If something we rely on gets unexpectedly denied during testing, add the relevant service to the `not_actions` list in `scp.tf` and re-apply — we don't promote to root until Dev has run cleanly for a while.

---

## 🔧 Prerequisites

- Terraform `~> 1.11.0` (CI pins `1.11.4`)
- AWS CLI >= 2.0, authenticated against the **management account**
- An existing AWS Organization (this config imports it, see below, rather than creating one from scratch)
- S3 bucket `james-terraform-state-2026` in `eu-west-2` for remote state (hand-created, not managed by either root module here)
- Unique root email addresses for each of the 6 member accounts (AWS requires a distinct email per account — this repo uses Gmail `+` aliases off one inbox), supplied via `organization/secrets.auto.tfvars` locally or the `ACCOUNT_EMAILS_JSON` GitHub secret in CI

---

## 🚀 First-Time Setup

AWS Organizations can only have one root, so if an Organization already exists in the management account, **import it before running `apply`**:

```bash
cd organization
terraform init

terraform import aws_organizations_organization.aws_Org r-sywu
```

Only needs to be run once. After the import we issue `terraform plan` / `terraform apply` as normal.

`platform/` has no import step — its resources are created fresh by `terraform apply`.

---

## ▶️ Usage

```bash
# Authenticate to the management account
aws sso login   # or export static credentials for the management account

# organization/ — applied manually, not by CI
cd organization
terraform init
terraform plan
terraform apply

# platform/ — CI applies this on merge to main; run locally only for plan/testing
cd ../platform
terraform init
terraform plan
```

Outputs (account IDs, role ARNs) are also written to SSM automatically — no manual copy/paste needed for the multi-account AWS infrastructure Terraform configuration (**Terraform-Platform**) repo.

---

## 📥 Inputs

### `organization/`

| Name | Description | Type | Default |
|---|---|---|---|
| `home_region` | Primary AWS region | `string` | — (required; no default) |
| `account_emails` | Unique root email per member account (`security`, `security_analytics`, `network`, `monitoring`, `production`, `development`) | `object` | — (required) |
| `allowed_regions` | Regions permitted by the region-restriction SCP. Enforced via `aws_organizations_policy.region_restriction` — see [Region Restriction SCP](#region-restriction-scp) for current rollout scope | `list(string)` | `["eu-west-1", "eu-west-2"]` |

### `platform/`

| Name | Description | Type | Default |
|---|---|---|---|
| `home_region` | Primary AWS region | `string` | — (required) |
| `management_account_id` | AWS Account ID of the management account | `string` | — (required) |
| `account_name` | Name of the management account (`"management"`) | `string` | — (required) |
| `github_org` | GitHub organization name | `string` | — (required) |
| `github_repo` | This repo's name — used by `TerraformDeploy`/`TerraformPlan`'s trust policies, since those roles are assumed by this repo's own CI | `string` | — (required) |
| `discovery_github_repo` | Terraform-Platform's repo name — kept separate from `github_repo` because `github_discovery` is assumed by a *different* repo's CI, see `discovery-role.tf` | `string` | — (required) |

---

## 📤 Outputs

### `organization/`

| Name | Description |
|---|---|
| `organization_id` | The AWS Organization ID |
| `root_id` | Root OU ID |

Account IDs are not exposed as a Terraform output — they're mirrored to SSM at `/organizations/accounts/<name>` (and tiers at `/organizations/tiers/<name>`) for consumption by other repos and by `platform/` itself.

### `platform/`

| Name | Description |
|---|---|
| `discovery_role_arn` | ARN of `GitHubActionsAccountDiscovery`, the read-only role Terraform-Platform's CI assumes to look up account IDs from SSM |

---

## 🗄️ State

Both root modules share the same S3 backend bucket but use separate keys, so they can be planned/applied independently.

| Setting | `organization/` | `platform/` |
|---|---|---|
| Backend | S3 | S3 |
| Bucket | `james-terraform-state-2026` | `james-terraform-state-2026` |
| Key | `org/terraform.tfstate` | `platform/terraform.tfstate` |
| Region | `eu-west-2` | `eu-west-2` |
| Locking | Native S3 lockfile (`use_lockfile = true`) | Native S3 lockfile (`use_lockfile = true`) |
| Encryption | Enabled | Enabled |

---

## 🔁 CI/CD

`.github/workflows/terraform.yaml` runs against **both** directories as a matrix (`organization`, `platform`):

- **Validate** — `terraform fmt -check`, `terraform init -backend=false`, `terraform validate`, on every PR and push touching `**.tf`/`**.tfvars`/lockfiles.
- **Security Scan** — Checkov, blocking (`soft_fail: false`), with SARIF results uploaded to the repo's Security tab. A handful of findings from the vendored `terraform_deploy_role` module (broad `ec2:*`/IAM grants it needs for accounts that actually run EC2) are skipped globally since this account's own `terraform-deploy-boundary.tf` already mitigates them — see that file's header.
- **Plan** — on pull requests, assumes `TerraformPlan`, plans both directories, and posts/updates a PR comment per directory with the plan output (flagging destructive changes with a `destructive-change` label).
- **Apply** — **`platform/` only**, on push to `main`, gated behind the `management-approval` GitHub Environment (a human must approve). It downloads and applies the *exact* plan artifact reviewed on the merged PR rather than re-planning at merge time; a `workflow_dispatch` run falls back to a fresh plan+apply if no reviewed artifact is found. `organization/` has no apply job at all — see [Security Notes](#security-notes) for why.

`.github/workflows/drift-detection.yaml` runs nightly (and on demand) against both directories as a refresh-only plan, so unmanaged drift (a console edit, a manual apply) doesn't go unnoticed — this matters most for `organization/`, which never auto-applies.

---

## 🔐 Security Notes

- **Real email addresses live in `organization/secrets.auto.tfvars`**, which is gitignored via the `*.auto.tfvars` pattern (not committed). `organization/terraform.tfvars` itself contains no secrets. CI supplies the same values via the `ACCOUNT_EMAILS_JSON` GitHub secret (`TF_VAR_account_emails`), scoped only to the jobs that need it.
- **`role_name = "OrganizationAccountAccessRole"`** is the default AWS-managed role granted to the *management account* in every member account it creates. It has full administrative access in each member account — the `terraform_deploy_role` module and downstream SSO permission sets are what actually constrain day-to-day access; this role is the "break-glass" path.
- **`prevent_destroy = true`** on every account resource is intentional friction against accidentally deleting a live AWS account via `terraform destroy`.
- Delegated administration is scoped to exactly four services (GuardDuty, Security Hub, Access Analyzer, IAM Identity Center) — the Security account is not a blanket delegated admin for the whole org. IAM Identity Center resources (permission sets, groups, users, account assignments) are managed from `member-accounts/security/sso.tf` in the Terraform-Platform repo, not from here.
- The region-restriction SCP is deliberately scoped to the **Dev OU only** while it's being validated — see [Region Restriction SCP](#region-restriction-scp). Do not attach it to `local.root_id` until it's been confirmed not to break normal operations, since a mistake at root can affect the management account's own access.
- **`organization/` has no CI apply job at all.** `TerraformDeploy` (defined in `platform/`) deliberately has no `organizations:*` permissions — AWS Organizations administration (account creation, OUs, SCPs) is applied manually via an admin AWS profile (`management`), not automated, per AWS's own guidance to keep the management account's automation least-privilege. Only `platform/` auto-applies, and only on merge to `main` behind the `management-approval` environment gate.
- **`TerraformDeploy`'s permissions boundary** (`platform/terraform-deploy-boundary.tf`) caps the shared `terraform_deploy_role` module's wider policy (`ec2:*`, unconstrained `iam:CreateRole`/`AttachRolePolicy`) down to exactly the fixed set of roles, policies, and SSM path this account actually manages — closing a real privilege-escalation shape flagged by Checkov (create/modify an arbitrary role, attach `AdministratorAccess`). `TerraformDeploy` can read but not edit or detach its own boundary, so a compromised or buggy CI run can't widen its own ceiling.

---

## 🐛 Known Issues / TODOs

- **`platform/main.tf` pins `terraform_deploy_role` to a commit SHA, not `ref=main`.** Upstream (`Terraform-Platform`) deleted `modules/terraform-deploy-role` on `main` and replaced it with `modules/github-oidc-roles`, which widens `TerraformDeploy`'s OIDC trust from main-branch-only to any-ref. Migrating is a real, separate decision (importing the OIDC provider as a managed resource, `state mv` for a renamed policy, accepting or overriding the trust widening) — evaluated once, not done.
- **`TerraformDeploy`'s IAM-management permissions were gap-filled after the fact** (`platform/terraform-deploy-permissions.tf`) — the shared module's built-in policy was written for EC2/instance-profile use cases and never covered standalone customer-managed policies, inline role policies, trust-policy updates, or reading the GitHub OIDC provider, all of which this account's own resources need. Surfaced by the first real `terraform-apply` run against `platform/`, not caught earlier since that job was previously unreachable (see workflow history).

---

## 📄 License

MIT — see [LICENSE](LICENSE). Note this only covers the Terraform/CI configuration in this repo; it says nothing about the AWS account IDs, org structure, or naming conventions it happens to reference, none of which are secret but none of which are "licensed" in any meaningful sense either.
