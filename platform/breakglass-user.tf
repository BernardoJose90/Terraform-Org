###############################################################################
# Break-Glass IAM User
#
# WHY THIS EXISTS: every TerraformDeploy/TerraformPlan role's trust policy
# has a "ManagementAccountBreakGlass" statement (see terraform-deploy-
# role.tf and terraform-plan-role.tf in this file's own directory, and
# Terraform-Platform's modules/github-oidc-roles/main.tf) meant to let an
# MFA-authenticated human assume any of these roles directly, bypassing
# CI, for exactly the situation where CI itself is stuck and structurally
# cannot fix itself — e.g. a role needing a permission on itself that it
# doesn't have yet. See Terraform-Platform's scripts/breakglass-
# bootstrap.sh for a worked example of that exact scenario.
#
# That statement checks aws:MultiFactorAuthPresent. IAM Identity Center
# (SSO) sessions never carry that context key — confirmed directly against
# CloudTrail during a real incident (2026-08-26): every attempt to use SSO
# credentials against this condition failed identically, regardless of
# re-authenticating, clearing local caches, or genuinely completing a real
# MFA challenge at Identity Center sign-in. This is a documented, current
# AWS limitation, not something fixable on the SSO side — see
# https://repost.aws/questions/QURCTAkCd2RiugphKo3S6zIw ("you cannot pass
# MFA status from the Identity Center requirement to the 'Permission Set'
# created in an account from the IAM IC Service").
#
# The one AWS-native way to get credentials that genuinely carry
# aws:MultiFactorAuthPresent is a plain IAM user's own MFA device, used via
# `aws sts get-session-token --serial-number <device-arn> --token-code
# <code>`. That's what this user exists for, and ALL it exists for — it
# should never be used for day-to-day work. Day-to-day access stays on SSO
# (per-account profiles, "Groups over Users" — see Terraform-Platform's
# README), completely unchanged by this.
#
# WHAT TERRAFORM DELIBERATELY DOES NOT MANAGE HERE:
# - The MFA device itself. Enabling one requires providing two consecutive
#   TOTP codes to prove possession — an inherently interactive step with
#   no Terraform resource for it. Register it by hand: IAM console -> this
#   user -> Security credentials -> Assign MFA device.
# - Access keys. An `aws_iam_access_key` resource would put the secret key
#   in Terraform state in plaintext, forever. Create one key by hand (IAM
#   console, or `aws iam create-access-key` run once) after the user
#   exists, and store it somewhere access-controlled (a password manager,
#   never a repo or a chat log) — the entire point of this user is
#   emergency access, so its own credentials need to survive as securely
#   as any other break-glass secret.
# - Console access. No login profile is created here — this user should
#   only ever be used programmatically, for the one GetSessionToken ->
#   AssumeRole flow above. No console password means no console-phishing
#   surface for it at all.
###############################################################################

resource "aws_iam_user" "breakglass" {
  name = "BreakGlassAdmin"

  tags = {
    ManagedBy = "Terraform"
    Purpose   = "MFA-gated break-glass access to TerraformDeploy/TerraformPlan when CI cannot fix itself"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Every account this config already knows about (local.account_ids_sso,
# from locals.tf), plus the management account itself — terraform-deploy-
# role.tf / terraform-plan-role.tf here carry the exact same
# ManagementAccountBreakGlass statement, so this account needs to be
# reachable too, not just the six member accounts.
locals {
  breakglass_target_account_ids = merge(
    local.account_ids_sso,
    { platform = var.management_account_id }
  )
}

# A plain identity policy, not a trust policy — jsonencode to match the
# style used for other permission (non-trust) policies in this directory
# (see terraform_plan_s3_role in terraform-plan-role.tf).
resource "aws_iam_user_policy" "breakglass_assume_deploy_plan" {
  name = "AssumeTerraformDeployAndPlanWithMFA"
  user = aws_iam_user.breakglass.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AssumeTerraformDeployAndPlanAnywhere"
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Resource = concat(
        [for id in values(local.breakglass_target_account_ids) : "arn:aws:iam::${id}:role/TerraformDeploy"],
        [for id in values(local.breakglass_target_account_ids) : "arn:aws:iam::${id}:role/TerraformPlan"],
      )
      # Defense in depth, ON TOP OF the target roles' own trust-policy MFA
      # condition, not instead of it: even if this user's access keys ever
      # leaked on their own, they're useless for this action without also
      # having (or having live-captured) a valid MFA code. Plain long-term
      # access keys never carry aws:MultiFactorAuthPresent — this
      # condition can only ever be satisfied by session credentials
      # obtained via sts:GetSessionToken with a real MFA code, which is
      # exactly the one flow this user is meant to be used through.
      Condition = {
        Bool = {
          "aws:MultiFactorAuthPresent" = "true"
        }
      }
    }]
  })
}

output "breakglass_user_arn" {
  value = aws_iam_user.breakglass.arn
}
