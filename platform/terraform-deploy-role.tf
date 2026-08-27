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

# this is a permission policie attached to the terraform_deploy role
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
        # Added 2026-08-27: Terraform reads a role's current state (a plain
        # GetRole) before deciding whether to update it — every one of the
        # 5 roles this account manages needs this, not just whichever one
        # happens to be changing on a given apply, since Terraform refreshes
        # all of them on every run. Missing this is exactly what broke the
        # discovery-role.tf trust-policy fix: the boundary already allowed
        # iam:GetRole (see terraform-deploy-boundary.tf's ManageKnownRoles),
        # but the role's own policy never did — AWS denies unless both
        # agree, so it failed despite the boundary being fine with it.
        Sid    = "ReadKnownRoles"
        Effect = "Allow"
        Action = ["iam:GetRole"]
        Resource = [
          "arn:aws:iam::145678291484:role/TerraformOrgRole",
          "arn:aws:iam::145678291484:role/SSMReadOnly",
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
        Sid    = "ManageBreakGlassGroup"
        Effect = "Allow"
        Action = [
          "iam:CreateGroup",
          "iam:GetGroup",
          "iam:DeleteGroup",
          "iam:AddUserToGroup",
          "iam:RemoveUserFromGroup",
          "iam:PutGroupPolicy",
          "iam:GetGroupPolicy",
          "iam:DeleteGroupPolicy"
        ]
        Resource = "arn:aws:iam::145678291484:group/BreakGlassAdmins"
      },
      {
        # One-time: breakglass-user.tf originally attached this policy
        # directly to the user; it's now attached to the group above
        # instead (see that file's header — CKV_AWS_40), so Terraform has
        # to delete the old user-attached copy. Nothing else in this
        # account ever needs to touch a user-level inline policy.
        Sid      = "CleanUpOldBreakGlassUserPolicy"
        Effect   = "Allow"
        Action   = ["iam:DeleteUserPolicy"]
        Resource = "arn:aws:iam::145678291484:user/BreakGlassAdmin"
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

# Added 2026-08-27 for security-alerts.tf's KMS key (SNS needs a
# customer-managed key, not the AWS-managed alias/aws/sns, so EventBridge
# can be granted decrypt/generate-data-key on it — see that file).
#
# CreateKey and ListAliases can't be scoped to a specific key ARN at all —
# confirmed against AWS's own IAM Service Authorization Reference, not
# assumed: that column is empty for both actions, meaning Resource must be
# "*". A brand-new key also has no ARN yet at the moment this permission is
# checked, so there's nothing to scope it to regardless. Everything else in
# this list COULD technically be scoped to a specific key once it exists,
# but is bundled into the same wildcard statement anyway, matching the
# precedent modules/github-oidc-roles' FlowLogKmsKey statement already set
# for the identical problem (a from-scratch KMS key with no fixed ID) —
# splitting one wildcard-forced action from several scopable ones across
# two statements for one small key isn't worth the inconsistency.
#
# This is the one real exception to this file's own "never Resource = *"
# rule (see file header) — forced by the KMS API itself, not a shortcut.
# TerraformDeploy's blast radius here is still capped independently by
# terraform-deploy-boundary.tf, which needs the identical statement added
# by hand — this grant alone does nothing until that happens too.
resource "aws_iam_role_policy" "terraform_deploy_kms_access" {
  name = "SecurityAlertsKmsAccess"
  role = aws_iam_role.terraform_deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageSecurityAlertsKmsKey"
        Effect = "Allow"
        Action = [
          "kms:CreateKey",
          "kms:ListAliases",
          "kms:DescribeKey",
          "kms:PutKeyPolicy",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:EnableKeyRotation",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:ListResourceTags",
          "kms:CreateAlias",
          "kms:DeleteAlias",
          "kms:UpdateAlias",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion"
        ]
        Resource = "*"
      }
    ]
  })
}

# Added 2026-08-27 for security-alerts.tf's two EventBridge rules
# (unexpected_deploy_assume, breakglass_admin_used). Both rules go on the
# account's default event bus, so the ARN format is
# arn:aws:events:region:account:rule/RuleName — confirmed against AWS's IAM
# Service Authorization Reference. Unlike KMS, EventBridge fully supports
# scoping every one of these actions to a specific, known rule name, so
# this stays inside the file's "never Resource = *" rule with no exception
# needed. Needs the identical statement in terraform-deploy-boundary.tf too.
resource "aws_iam_role_policy" "terraform_deploy_eventbridge_access" {
  name = "SecurityAlertsEventBridgeAccess"
  role = aws_iam_role.terraform_deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageSecurityAlertsEventRules"
        Effect = "Allow"
        Action = [
          "events:PutRule",
          "events:DescribeRule",
          "events:DeleteRule",
          "events:PutTargets",
          "events:RemoveTargets",
          "events:ListTargetsByRule",
          "events:TagResource",
          "events:UntagResource",
          "events:ListTagsForResource"
        ]
        Resource = [
          "arn:aws:events:eu-west-2:145678291484:rule/unexpected-terraform-deploy-assume",
          "arn:aws:events:eu-west-2:145678291484:rule/breakglass-admin-used"
        ]
      }
    ]
  })
}

# Added 2026-08-27 for security-alerts.tf's SNS topic. Topic-level actions
# (CreateTopic, Subscribe, etc.) scope to the topic ARN, which is
# predictable ahead of time since the topic name is fixed
# ("security-alerts") — confirmed against AWS's IAM Service Authorization
# Reference. Subscription-level actions (Unsubscribe,
# {Get,Set}SubscriptionAttributes) need a subscription ARN instead, which
# has a generated ID with no fixed value to write in advance — the
# ":*" suffix scopes that to "any subscription on this specific topic
# only", not to every topic in the account, so this still isn't a bare
# wildcard the way the KMS statement above genuinely has to be.
resource "aws_iam_role_policy" "terraform_deploy_sns_access" {
  name = "SecurityAlertsSnsAccess"
  role = aws_iam_role.terraform_deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageSecurityAlertsTopic"
        Effect = "Allow"
        Action = [
          "sns:CreateTopic",
          "sns:DeleteTopic",
          "sns:GetTopicAttributes",
          "sns:SetTopicAttributes",
          "sns:Subscribe",
          "sns:TagResource",
          "sns:UntagResource",
          "sns:ListTagsForResource"
        ]
        Resource = "arn:aws:sns:eu-west-2:145678291484:security-alerts"
      },
      {
        Sid    = "ManageSecurityAlertsSubscriptions"
        Effect = "Allow"
        Action = [
          "sns:Unsubscribe",
          "sns:GetSubscriptionAttributes",
          "sns:SetSubscriptionAttributes"
        ]
        Resource = "arn:aws:sns:eu-west-2:145678291484:security-alerts:*"
      }
    ]
  })
}
