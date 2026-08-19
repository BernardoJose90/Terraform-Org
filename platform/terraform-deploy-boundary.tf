###############################################################################
# TerraformDeploy's permissions boundary
#
# terraform_deploy_role's shared `permissions` policy (pinned module) is
# written wide — ec2:*, VPN/CloudWatch logging, and unconstrained
# iam:CreateRole/AttachRolePolicy/DeleteRole on Resource "*" — because it's
# reused by accounts (network, security, ...) that actually run that kind of
# infrastructure. This account doesn't: platform/ only ever manages a fixed,
# known set of IAM roles/policies, the state bucket, and SSM parameters under
# /organizations/*. None of it touches EC2, VPC, VPN, or CloudWatch, and it
# never creates or modifies an IAM role/policy outside the fixed list below.
#
# Surfaced by Checkov (CKV_AWS_61/107/109/111/356) — findings were real: the
# shared policy's grant is broader than this account uses, and the
# unconstrained iam:CreateRole/AttachRolePolicy is a genuine
# privilege-escalation shape (create or modify an arbitrary role, attach
# AdministratorAccess to it). AWS's own guidance backs both the diagnosis and
# the fix:
#   - Well-Architected SEC03-BP05 lists "running workloads in your
#     [management/organizational admin] account" as a common anti-pattern —
#     ec2:*/VPN/logging has no business being usable here regardless of
#     whether it's ever actually called.
#   - IAM User Guide, "Permissions boundaries for IAM entities" — the
#     documented mechanism for capping one specific identity's *effective*
#     permissions below what a shared/broader identity policy grants, without
#     narrowing that policy for every other caller.
#
# A permissions boundary caps what's USABLE, not what's GRANTED — the shared
# policy still technically grants ec2:*, but TerraformDeploy can't actually
# use it, because AWS evaluates the intersection of the identity policy and
# this boundary. Every other account calling the same module is completely
# unaffected — permissions_boundary_arn defaults to null and only this
# account passes a value (see main.tf).
#
# Deliberately excluded from what TerraformDeploy itself is allowed to touch:
# this boundary's own policy (content or attachment). If TerraformDeploy
# could edit or detach its own boundary, the boundary wouldn't be a real
# ceiling — a buggy or compromised CI run could just remove it and fall back
# to the shared policy's full width. Changing this file therefore still
# requires the management break-glass path (see README / CLAUDE session
# notes on how the OIDC and this fix were both applied), same as
# organization/ already does for SCPs.
###############################################################################

data "aws_iam_policy_document" "terraform_deploy_boundary" {
  # Read-only on this boundary policy's own resource, so `terraform plan`/
  # `apply` can refresh it on every future run without needing any write
  # access to it — see the file header for why writes are deliberately not
  # granted here. Hardcoded ARN (not a resource attribute reference) because
  # referencing aws_iam_policy.terraform_deploy_boundary.arn from inside its
  # own policy document would be a dependency cycle; IAM policy ARNs are
  # deterministic from account ID + name, so this is safe.
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

  # The fixed set of IAM roles this account's Terraform actually manages —
  # see iam.tf, discovery-role.tf, main.tf (this module's own two roles).
  # CreateRole/AttachRolePolicy scoped to exactly these five is what closes
  # the privilege-escalation gap: TerraformDeploy can manage these known
  # roles but can't create or modify any role outside this list.
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

  # The two customer-managed policies this account creates — same ARNs as
  # terraform-deploy-permissions.tf's ManageStandaloneIAMPolicies statement.
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
    ]
  }

  # Matches the module's own SSMParameterStore statement scope exactly —
  # this account's automation only ever touches /organizations/* parameters.
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

  # Matches state-bucket-policy.tf's existing scope — object access plus the
  # bucket-policy management that resource already grants separately today.
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
      # Literal, matching state-bucket-policy.tf's own convention — this
      # repo has no state_bucket_name variable (that's module-internal to
      # terraform_deploy_role, defaulted there, not exposed here).
      "arn:aws:s3:::james-terraform-state-2026",
      "arn:aws:s3:::james-terraform-state-2026/*",
    ]
  }
}

resource "aws_iam_policy" "terraform_deploy_boundary" {
  name        = "TerraformDeployPermissionsBoundary"
  description = "Caps TerraformDeploy's effective permissions to what platform/ actually manages. Not editable by TerraformDeploy itself — see file header."
  policy      = data.aws_iam_policy_document.terraform_deploy_boundary.json
}
