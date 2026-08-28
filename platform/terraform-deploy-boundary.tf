###############################################################################
# TerraformDeploy's permissions boundary — a second, independent limit on
# top of its normal permissions.
#
# TerraformDeploy already only has the specific permissions it needs
# (terraform-deploy-role.tf). This file (terraform-deploy-boundary.tf)
# adds a backup limit on top of that: AWS only allows an action if BOTH a
# role's normal permissions AND its boundary agree to it. So even if
# something in the future accidentally gave this role extra permissions (a
# new resource added here, someone attaching a policy by hand in the AWS
# console), this boundary would still block anything outside the fixed
# list below.

#   - AWS's IAM documentation recommends permissions boundaries
#     specifically as a way to cap what one identity can do, independent
#     of whatever its normal permissions say.
#
# One thing TerraformDeploy is NOT allowed to do: change this file's own
# policy, or remove it from itself. If it could, this whole boundary would
# be pointless — a bug or a bad PR could just have it remove its own
# limit. So any change to this file has to be applied by a human directly
# (an admin logged in locally, not through CI) — see the README's Usage
# section. organization/'s SCPs work the same way, for the same reason.
###############################################################################

data "aws_iam_policy_document" "terraform_deploy_boundary" {
  #checkov:skip=CKV_AWS_111:Only the ManageSecurityAlertsKmsKey statement uses Resource "*" — kms:CreateKey/ListAliases can't be scoped to a key ARN at all (confirmed against AWS's IAM Service Authorization Reference). Every other statement in this document is scoped to specific, named resource ARNs.
  #checkov:skip=CKV_AWS_356:Same — see ManageSecurityAlertsKmsKey's own comment further down for the full reasoning.
  #checkov:skip=CKV_AWS_109:Same. This mirrors terraform-deploy-role.tf's terraform_deploy_kms_access policy exactly, as it must — anything granted there does nothing unless this file allows it too.
  # Lets TerraformDeploy read (but not change) this boundary policy itself,
  # so `terraform plan`/`apply` can check it's still correct on every run —
  # see the file header for why it can't write to it. The ARN is spelled
  # out directly instead of referencing the policy resource below, because
  # referencing itself from inside its own policy would create a circular
  # dependency; a policy's ARN is always predictable from the account ID
  # and name, so writing it out directly here is safe.
  statement {
    sid    = "ReadOwnBoundaryPolicy"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
    ]
    resources = ["arn:aws:iam::${var.management_account_id}:policy/TerraformDeployPermissionsBoundary"]
  }

  # The five specific IAM roles this repo manages (defined in
  # terraform-org-role.tf, ssm-read-only-role.tf, discovery-role.tf, and
  # terraform-deploy-role.tf/terraform-plan-role.tf). Limiting
  # CreateRole/AttachRolePolicy to just these five is what actually
  # prevents the "create yourself an admin role" problem — TerraformDeploy
  # can manage these known roles, but literally cannot touch any role
  # outside this list, even if its normal permissions said otherwise.
  statement {
    sid    = "ManageKnownRoles"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = [
      "arn:aws:iam::${var.management_account_id}:role/TerraformOrgRole",
      "arn:aws:iam::${var.management_account_id}:role/SSMReadOnly",
      "arn:aws:iam::${var.management_account_id}:role/GitHubActionsAccountDiscovery",
      "arn:aws:iam::${var.management_account_id}:role/TerraformDeploy",
      "arn:aws:iam::${var.management_account_id}:role/TerraformPlan",
    ]
  }

  statement {
    sid       = "ReadGitHubOIDCProvider"
    effect    = "Allow"
    actions   = ["iam:GetOpenIDConnectProvider"]
    resources = ["arn:aws:iam::${var.management_account_id}:oidc-provider/token.actions.githubusercontent.com"]
  }

  # The one IAM group this account manages — see breakglass-user.tf.
  # Matches terraform-deploy-role.tf's ManageBreakGlassGroup statement.
  statement {
    sid    = "ManageBreakGlassGroup"
    effect = "Allow"
    actions = [
      "iam:CreateGroup",
      "iam:GetGroup",
      "iam:DeleteGroup",
      "iam:AddUserToGroup",
      "iam:RemoveUserFromGroup",
      "iam:PutGroupPolicy",
      "iam:GetGroupPolicy",
      "iam:DeleteGroupPolicy",
    ]
    resources = ["arn:aws:iam::${var.management_account_id}:group/BreakGlassAdmins"]
  }

  # One-time cleanup permission — see terraform-deploy-role.tf's matching
  # CleanUpOldBreakGlassUserPolicy statement for why this exists.
  statement {
    sid       = "CleanUpOldBreakGlassUserPolicy"
    effect    = "Allow"
    actions   = ["iam:DeleteUserPolicy"]
    resources = ["arn:aws:iam::${var.management_account_id}:user/BreakGlassAdmin"]
  }

  # The three IAM policies this account creates: two of our own (same as
  # terraform-deploy-role.tf's ManageStandaloneIAMPolicies list), plus
  # TerraformPlanS3Policy —
  # which actually belongs to the OTHER role (TerraformPlan), but
  # TerraformDeploy still has to be allowed to create/manage it, because
  # TerraformDeploy is the role that runs `apply` and does the actual
  # creating. Leave this ARN out and `apply` fails with an AccessDenied
  # error on iam:CreatePolicy.
  statement {
    sid    = "ManageKnownPolicies"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:DeletePolicy",
    ]
    resources = [
      "arn:aws:iam::${var.management_account_id}:policy/TerraformOrgSSMPolicy",
      "arn:aws:iam::${var.management_account_id}:policy/SSMReadOnlyForMemberAccounts",
      "arn:aws:iam::${var.management_account_id}:policy/TerraformPlanS3Policy",
    ]
  }

  # This account's automation only ever touches /organizations/* parameters
  # in the management account.
  statement {
    sid    = "SSMOrganizationsParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:DescribeParameters",
      "ssm:PutParameter",
      "ssm:DeleteParameter",
    ]
    resources = ["arn:aws:ssm:eu-west-2:${var.management_account_id}:parameter/organizations/*"]
  }

  # Matches what state-bucket-policy.tf already grants: reading/writing
  # objects in the bucket, plus managing the bucket's own policy.
  statement {
    sid    = "StateBucketAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketLocation",
    ]
    resources = [
      # Written out directly rather than as a variable, matching
      # state-bucket-policy.tf — this repo doesn't have a
      # state_bucket_name variable.
      "arn:aws:s3:::james-terraform-state-2026",
      "arn:aws:s3:::james-terraform-state-2026/*",
    ]
  }

  # Added 2026-08-27 — must exactly mirror terraform-deploy-role.tf's three
  # new statements (SecurityAlertsKmsAccess, SecurityAlertsEventBridgeAccess,
  # SecurityAlertsSnsAccess). This is the one half of that fix TerraformDeploy
  # can never apply itself — see this file's header for why. Apply by hand:
  #   aws sso login --profile management
  #   cd platform && terraform apply \
  #     -target=aws_iam_policy.terraform_deploy_boundary
  statement {
    sid    = "ManageSecurityAlertsKmsKey"
    effect = "Allow"
    actions = [
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
      "kms:CancelKeyDeletion",
    ]
    # CreateKey/ListAliases can't be scoped to a specific key ARN at all
    # (confirmed against AWS's own IAM Service Authorization Reference) —
    # see the matching comment in terraform-deploy-role.tf for the full
    # reasoning. The one deliberate exception to this file's own
    # never-wildcard pattern, forced by the KMS API itself.
    resources = ["*"]
  }

  statement {
    sid    = "ManageSecurityAlertsEventRules"
    effect = "Allow"
    actions = [
      "events:PutRule",
      "events:DescribeRule",
      "events:DeleteRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:ListTargetsByRule",
      "events:TagResource",
      "events:UntagResource",
      "events:ListTagsForResource",
    ]
    resources = [
      "arn:aws:events:eu-west-2:${var.management_account_id}:rule/unexpected-terraform-deploy-assume",
      "arn:aws:events:eu-west-2:${var.management_account_id}:rule/breakglass-admin-used",
    ]
  }

  statement {
    sid    = "ManageSecurityAlertsTopic"
    effect = "Allow"
    actions = [
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
      "sns:TagResource",
      "sns:UntagResource",
      "sns:ListTagsForResource",
    ]
    resources = ["arn:aws:sns:eu-west-2:${var.management_account_id}:security-alerts"]
  }

  statement {
    sid    = "ManageSecurityAlertsSubscriptions"
    effect = "Allow"
    actions = [
      "sns:Unsubscribe",
      "sns:GetSubscriptionAttributes",
      "sns:SetSubscriptionAttributes",
    ]
    # ":*" scopes this to "any subscription on this one topic", not every
    # topic in the account — see the matching comment in
    # terraform-deploy-role.tf.
    resources = ["arn:aws:sns:eu-west-2:${var.management_account_id}:security-alerts:*"]
  }

  # Added 2026-08-28 — must exactly mirror terraform-deploy-role.tf's
  # terraform_deploy_logs_access and terraform_deploy_cloudwatch_access
  # policies. Apply by hand, same as the KMS/EventBridge/SNS statements
  # above:
  #   aws sso login --profile management
  #   cd platform && terraform apply \
  #     -target=aws_iam_policy.terraform_deploy_boundary
  statement {
    sid    = "ManageSecurityAlertsMetricFilters"
    effect = "Allow"
    actions = [
      "logs:PutMetricFilter",
      "logs:DeleteMetricFilter",
      "logs:DescribeMetricFilters",
    ]
    resources = ["arn:aws:logs:eu-west-2:${var.management_account_id}:log-group:/aws/cloudtrail/org-trail"]
  }

  statement {
    sid    = "ManageSecurityAlertsAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:DeleteAlarms",
    ]
    resources = [
      "arn:aws:cloudwatch:eu-west-2:${var.management_account_id}:alarm:unexpected-terraform-deploy-assume",
      "arn:aws:cloudwatch:eu-west-2:${var.management_account_id}:alarm:terraform-deploy-role-tampering",
    ]
  }
}

resource "aws_iam_policy" "terraform_deploy_boundary" {
  name        = "TerraformDeployPermissionsBoundary"
  description = "Caps TerraformDeploy's effective permissions to what platform/ actually manages. Not editable by TerraformDeploy itself — see file header."
  policy      = data.aws_iam_policy_document.terraform_deploy_boundary.json
}
