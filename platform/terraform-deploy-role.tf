###############################################################################
# TerraformDeploy — this account's own, dedicated role, and everything it's
# allowed to do.
#
# This used to come from a module shared with several other AWS accounts
# (network, security, and others that manage real infrastructure like VPCs
# and VPNs). That module granted a lot of permissions this account never
# used, because it had to cover everyone. Every time that shared module
# changed, this account inherited the risk of that change too, even for
# features it would never touch (three separate CI breakages from one such
# update). So this role is now defined directly here instead — it only
# ever grants exactly what this account actually uses, meaning nothing an
# unrelated account's changes could accidentally widen.
#
# terraform-deploy-boundary.tf is still kept as a backup limit, even though
# this role's own permissions are already narrow — see that file for why.
#
# Permissions are split into two grants below: state-bucket access
# (this role's one truly "core" permission), and everything else it needs
# for IAM management — creating/updating standalone IAM policies, editing
# other roles' inline policies, updating trust policies, and reading the
# GitHub OIDC provider. The latter is what discovery-role.tf,
# terraform-org-role.tf, ssm-read-only-role.tf, and this role's own trust
# policy all depend on. Every grant is scoped to specific, named
# resources — never `iam:*` or a wildcard `Resource = "*"`. Same pattern
# used in state-bucket-policy.tf's terraform_deploy_state_bucket_policy_access
# and terraform_plan_lock_access.
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
# state bucket.
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

# Everything else this role needs: managing the 5 known roles, the 3 known
# customer-managed policies, /organizations/* SSM parameters, and reading
# its own boundary. See the file header for the full explanation.
resource "aws_iam_role_policy" "terraform_deploy_iam_management_access" {
  name = "IAMManagementAccess"
  role = aws_iam_role.terraform_deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadGitHubOIDCProvider"
        Effect   = "Allow"
        Action   = ["iam:GetOpenIDConnectProvider"]
        Resource = "arn:aws:iam::145678291484:oidc-provider/token.actions.githubusercontent.com"
      },
      {
        Sid    = "ManageStandaloneIAMPolicies"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:DeletePolicy"
        ]
        Resource = [
          "arn:aws:iam::145678291484:policy/TerraformOrgSSMPolicy",
          "arn:aws:iam::145678291484:policy/SSMReadOnlyForMemberAccounts"
        ]
      },
      {
        Sid    = "ManageInlineRolePolicies"
        Effect = "Allow"
        Action = [
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy"
        ]
        Resource = [
          "arn:aws:iam::145678291484:role/GitHubActionsAccountDiscovery",
          "arn:aws:iam::145678291484:role/TerraformDeploy",
          "arn:aws:iam::145678291484:role/TerraformPlan"
        ]
      },
      {
        Sid    = "UpdateTrustPolicies"
        Effect = "Allow"
        Action = ["iam:UpdateAssumeRolePolicy"]
        Resource = [
          "arn:aws:iam::145678291484:role/TerraformOrgRole",
          "arn:aws:iam::145678291484:role/SSMReadOnly",
          "arn:aws:iam::145678291484:role/GitHubActionsAccountDiscovery",
          "arn:aws:iam::145678291484:role/TerraformDeploy",
          "arn:aws:iam::145678291484:role/TerraformPlan"
        ]
      },
      {
        # Remember, a permissions boundary by itself doesn't grant
        # anything — AWS only allows an action if BOTH a role's normal
        # permissions AND its boundary agree to it. So TerraformDeploy
        # needs its own explicit permission to read the boundary, separate
        # from the boundary allowing itself to be read (that's
        # terraform-deploy-boundary.tf's matching ReadOwnBoundaryPolicy
        # statement) — without both sides granting it, TerraformDeploy
        # can't even check its own boundary is correct (confirmed by
        # actually testing this as the role — it failed with AccessDenied
        # without this permission). Deliberately read-only: no permission
        # to create a new version or delete this policy, so TerraformDeploy
        # still can't widen or remove its own limit — see
        # terraform-deploy-boundary.tf's header for why that matters.
        Sid    = "ReadOwnPermissionsBoundary"
        Effect = "Allow"
        Action = [
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions"
        ]
        Resource = "arn:aws:iam::145678291484:policy/TerraformDeployPermissionsBoundary"
      }
    ]
  })
}
