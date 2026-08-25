###############################################################################
# TerraformDeploy's permissions boundary
#
# This account's TerraformDeploy role already has an intentionally minimal
# identity policy (terraform-deploy-role.tf + terraform-deploy-permissions.tf)
# — scoped to exactly the fixed set of IAM roles/policies, the state bucket,
# and SSM parameters under /organizations/* this account actually manages.
# This boundary is a second, independent layer on top of that: AWS evaluates
# the intersection of a role's identity policy and its boundary, so even if
# some future change here (a new resource, a policy attached directly via
# the console) ever granted this role something broader, this boundary caps
# what's actually usable back down to this same fixed list.
#
# Originally added to close a real privilege-escalation shape — unconstrained
# iam:CreateRole/AttachRolePolicy/PassRole — inherited from a shared,
# multi-account IAM-role module this account used to source
# TerraformDeploy/TerraformPlan from. That module is gone now (replaced by
# the dedicated role definition above), so the specific finding that
# originally motivated this file no longer fires — kept anyway as
# defense-in-depth, per AWS's own guidance:
#   - Well-Architected SEC03-BP05 lists "running workloads in your
#     [management/organizational admin] account" as a common anti-pattern.
#   - IAM User Guide, "Permissions boundaries for IAM entities" — the
#     documented mechanism for capping one specific identity's *effective*
#     permissions independent of whatever its identity policy grants.
#
# Deliberately excluded from what TerraformDeploy itself is allowed to touch:
# this boundary's own policy (content or attachment). If TerraformDeploy
# could edit or detach its own boundary, the boundary wouldn't be a real
# ceiling — a buggy or compromised CI run could just remove it. Changing
# this file therefore requires the management break-glass path (an admin
# AWS profile, applied locally — see README's Usage section), same as
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
  # see terraform-org-role.tf, ssm-read-only-role.tf, discovery-role.tf, and
  # terraform-deploy-role.tf/terraform-plan-role.tf (this account's own two
  # roles). CreateRole/AttachRolePolicy scoped to exactly these five is what
  # closes the privilege-escalation gap: TerraformDeploy can manage these
  # known roles but can't create or modify any role outside this list.
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

  # The customer-managed policies this account creates — two of our own
  # (same ARNs as terraform-deploy-permissions.tf's ManageStandaloneIAM
  # Policies statement), plus TerraformPlanS3Policy (terraform-plan-role.tf)
  # — scopes TerraformPlan's state-bucket S3 access to this account's own
  # state_key_prefix. TerraformDeploy is the role that runs `apply`, so it's
  # the one that has to create/manage this too, even though it belongs to a
  # different role — omitting it here fails CreatePolicy with "no
  # permissions boundary allows the iam:CreatePolicy action."
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
      # repo has no state_bucket_name variable at all.
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
