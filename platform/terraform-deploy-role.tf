###############################################################################
# TerraformDeploy — dedicated to this account, not the shared github-oidc-
# roles module.
#
# Previously this role came from Terraform-Platform's shared github-oidc-
# roles module, which is written wide (ec2:*, unconstrained
# iam:CreateRole/AttachRolePolicy, VPN/CloudWatch logging, iam:PassRole) for
# accounts like network/security that actually run that infrastructure.
# platform/ never used any of that — terraform-deploy-boundary.tf existed
# specifically to claw the shared grant back down to what this account
# actually needs, and every module version bump risked reopening that gap
# (three separate CI breakages from one such bump, 2026-08-24). Defined
# directly here instead: this account's identity policy only ever grants
# what it actually uses, so there's nothing left for an upstream change
# meant for other accounts to accidentally widen.
#
# terraform-deploy-boundary.tf is kept, unchanged, as a second layer of
# defense — even though this role's own policy is already minimal now, the
# boundary still protects against some future PR attaching an additional,
# broader policy to this role directly.
###############################################################################

locals {
  # This account only ever assumes TerraformDeploy through one GitHub
  # Environment (terraform.yaml's `environment: management-approval` on the
  # apply job). Unlike the shared module, which had to stay generic across
  # several repos/environments, this only needs to trust the one this repo
  # actually uses.
  terraform_deploy_trusted_subs = [
    "repo:${var.github_org}/${var.github_repo}:environment:management-approval",
  ]
}

data "aws_iam_policy_document" "terraform_deploy_trust_policy" {
  # Emergency access: an admin in the management account can assume this
  # role directly, but only with MFA. Kept from the shared module's
  # equivalent statement — same emergency path as before, now owned here.
  statement {
    sid     = "ManagementAccountBreakGlass"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.management_account_id}:root"]
    }
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }

  statement {
    sid     = "GitHubActionsCI"
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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.terraform_deploy_trusted_subs
    }
  }
}

resource "aws_iam_role" "terraform_deploy" {
  name                 = "TerraformDeploy"
  assume_role_policy   = data.aws_iam_policy_document.terraform_deploy_trust_policy.json
  max_session_duration = 3600
  # Same boundary as before, unchanged — see terraform-deploy-boundary.tf.
  permissions_boundary = aws_iam_policy.terraform_deploy_boundary.arn

  tags = {
    ManagedBy   = "Terraform"
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }

  # Matches the shared module's own safeguard — this is the role CI itself
  # assumes to run `apply`; Terraform must never be allowed to delete it
  # out from under a running pipeline.
  lifecycle {
    prevent_destroy = true
  }
}

# The one permission this account still needed from the old shared
# module's wide policy: read/write access to its own folder in the shared
# state bucket. Everything else this role needs (managing the 5 known
# roles, the 3 known customer-managed policies, /organizations/* SSM
# parameters, reading its own boundary) is already granted separately by
# terraform-deploy-permissions.tf — untouched by this migration, still
# attached to this same role by name.
resource "aws_iam_role_policy" "terraform_deploy_state_access" {
  name = "TerraformDeployStateAccess"
  role = aws_iam_role.terraform_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StateFileAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject", # the .tflock file use_lockfile writes/deletes
        ]
        Resource = "arn:aws:s3:::james-terraform-state-2026/platform/*"
      },
      {
        Sid      = "ListOwnPrefixOnly"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::james-terraform-state-2026"
        Condition = {
          StringLike = {
            "s3:prefix" = ["platform/*"]
          }
        }
      }
    ]
  })
}
