###############################################################################
# Terraform State Bucket Policy
#
# james-terraform-state-2026 was created by hand (AWS CLI), not Terraform —
# there is no aws_s3_bucket resource for it anywhere in this repo or in
# Terraform-Platform. We only bring its bucket policy under management here,
# via a data source against the existing bucket, so this doesn't try to
# adopt/import the bucket itself.
#
# Each member account is scoped to its own prefix only (object actions via
# resource ARN, ListBucket via an s3:prefix condition since it's a
# bucket-level action and can't be scoped by appending a path to the ARN).
# Principals are account roots (arn:...:root) — trusts anything in that
# account with sufficient IAM permissions, not just specific roles.
#
# Account IDs are read from SSM (local.account_ids_sso, sso.tf) instead of
# hardcoded, so a 7th "normal" account (same name as its state-key prefix)
# only needs one new line in local.sso_account_names — see
# state_bucket_prefix_overrides below for the one existing exception.
###############################################################################

locals {
  # State-key prefixes that differ from the SSM parameter / account name.
  # security_analytics is the only current case: its SSM parameter and SSO
  # account name use an underscore, but its backend "s3" key uses a hyphen
  # (member-accounts/security_analytics/main.tf: key = "security-analytics/terraform.tfstate").
  state_bucket_prefix_overrides = {
    security_analytics = "security-analytics"
  }

  # prefix => account_id, one entry per member account.
  state_bucket_account_prefixes = {
    for name in local.sso_account_names :
    lookup(local.state_bucket_prefix_overrides, name, name) => local.account_ids_sso[name]
  }
}

data "aws_s3_bucket" "state" {
  bucket = "james-terraform-state-2026"
}

data "aws_iam_policy_document" "state_bucket_policy" {
  # Per-account object access, scoped to that account's own prefix only.
  dynamic "statement" {
    for_each = local.state_bucket_account_prefixes
    content {
      sid       = "${title(replace(statement.key, "-", ""))}ObjectAccess"
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${data.aws_s3_bucket.state.arn}/${statement.key}/*"]

      principals {
        type        = "AWS"
        identifiers = ["arn:aws:iam::${statement.value}:root"]
      }
    }
  }

  # ListBucket is a bucket-level action (resource = the bucket itself, not a
  # path within it), so it's restricted to each account's own prefix via an
  # s3:prefix condition instead of the resource ARN.
  dynamic "statement" {
    for_each = local.state_bucket_account_prefixes
    content {
      sid       = "${title(replace(statement.key, "-", ""))}ListOwnPrefix"
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = [data.aws_s3_bucket.state.arn]

      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = ["${statement.key}/*"]
      }

      principals {
        type        = "AWS"
        identifiers = ["arn:aws:iam::${statement.value}:root"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = data.aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket_policy.json
}

# The management account's TerraformDeploy role (terraform-deploy-role.tf,
# used by CI on push to main) only has GetObject/PutObject/DeleteObject/
# ListBucket on the state bucket — none of those cover reading or writing a
# bucket *policy*. Without this, CI's apply of aws_s3_bucket_policy.state
# above would fail with AccessDenied on refresh. Scoped to this bucket only,
# and only to this account's deploy role.
resource "aws_iam_role_policy" "terraform_deploy_state_bucket_policy_access" {
  name = "StateBucketPolicyAccess"
  role = aws_iam_role.terraform_deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketPolicy",
          "s3:PutBucketPolicy",
          "s3:DeleteBucketPolicy",
          "s3:GetBucketLocation"
        ]
        Resource = "arn:aws:s3:::james-terraform-state-2026"
      }
    ]
  })
}

###############################################################################
# TerraformPlan's lock-object access.
#
# TerraformPlan only has AWS-managed ReadOnlyAccess (s3:Get*/List*/Head*, no
# Put/Delete). use_lockfile = true means every `terraform plan` — plan locks
# by default, not just apply — needs s3:PutObject + s3:DeleteObject on
# <key>.tflock to acquire/release the lock, which ReadOnlyAccess doesn't
# grant. Scoped to exactly the two .tflock objects, not the state objects
# themselves or the bucket generally — TerraformPlan still can't write real
# state or infrastructure, only this ephemeral lock marker.
###############################################################################

resource "aws_iam_role_policy" "terraform_plan_lock_access" {
  name = "StateLockObjectAccess"
  role = aws_iam_role.terraform_plan.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::james-terraform-state-2026/org/terraform.tfstate.tflock",
          "arn:aws:s3:::james-terraform-state-2026/platform/terraform.tfstate.tflock"
        ]
      }
    ]
  })
}
