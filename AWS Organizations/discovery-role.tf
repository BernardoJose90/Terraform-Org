# --- Add to the AWS Organizations bootstrap stack (management account) ---
#
# This role has exactly one capability: read the account list back out of
# SSM. It cannot deploy, modify, or read anything else. It exists purely so
# GitHub Actions can build its matrix dynamically instead of a human
# hand-editing YAML every time an account is added.
#
# This is intentionally NOT the "one god-role" pattern from before — it
# can't assume anything, can't touch resources, can't deploy. Worst case if
# this role's token is somehow misused: someone reads your account names
# and IDs, which are not secret (they're already visible to anyone in your
# AWS Organization).

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

# Reuses the same OIDC provider created in modules/terraform-deploy-role
# if you deployed that in this account already. If this account doesn't
# have one yet, uncomment the provider resource below.

# resource "aws_iam_openid_connect_provider" "github" {
#   url             = "https://token.actions.githubusercontent.com"
#   client_id_list  = ["sts.amazonaws.com"]
#   thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
# }

data "aws_iam_openid_connect_provider" "github" {
  arn = "arn:aws:iam::145678291484:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_discovery_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_discovery" {
  name               = "GitHubActionsAccountDiscovery"
  assume_role_policy = data.aws_iam_policy_document.github_discovery_trust.json
  tags = {
    ManagedBy = "github-actions"
    Purpose   = "read-only account manifest discovery"
  }
}

resource "aws_iam_role_policy" "github_discovery_ssm_read" {
  name = "ReadAccountManifestOnly"
  role = aws_iam_role.github_discovery.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParametersByPath", "ssm:GetParameter"]
      # Covers BOTH /organizations/accounts/* (existing, plain account IDs)
      # and /organizations/tiers/* (new, tier strings) — same prefix.
      Resource = "arn:aws:ssm:*:${var.management_account_id}:parameter/organizations/*"
    }]
  })
}

output "discovery_role_arn" {
  value = aws_iam_role.github_discovery.arn
}

# --- Also publish tier info, WITHOUT touching the existing account_ids parameter ---
#
# Your terraform-platform stacks already read plain account IDs from
# /organizations/accounts/<name> via data.aws_ssm_parameter.account_ids.
# That parameter's format (a raw ID string) must not change, or every
# downstream stack reading it breaks.
#
# So tier info goes in a NEW, separate path instead:
#   /organizations/tiers/<name>  →  "automated" or "production-approval"
#
# Nothing about your existing account_ids parameter changes. This is
# purely additive.

resource "aws_ssm_parameter" "account_tier" {
  for_each = local.account_tiers

  name  = "/organizations/tiers/${each.key}"
  type  = "String"
  value = each.value # "automated" or "production-approval"
}

locals {
  # The one place you declare which accounts need manual approval.
  # Adding a new account: add one line here. Nothing else in this file,
  # and nothing in the GitHub workflows, needs to change.
  account_tiers = {
    management           = "production-approval"
    security             = "production-approval"
    security-analytics = "production-approval"
    network              = "production-approval"
    monitoring           = "production-approval"
    production           = "production-approval"
    development          = "automated"
  }
}
