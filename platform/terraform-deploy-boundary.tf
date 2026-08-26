###############################################################################
# TerraformDeploy's permissions boundary — a second, independent limit on
# top of its normal permissions.
#
# TerraformDeploy already only has the specific permissions it needs
# (terraform-deploy-role.tf). This file
# adds a backup limit on top of that: AWS only allows an action if BOTH a
# role's normal permissions AND its boundary agree to it. So even if
# something in the future accidentally gave this role extra permissions (a
# new resource added here, someone attaching a policy by hand in the AWS
# console), this boundary would still block anything outside the fixed
# list below.
#
# Why this exists: it was originally added to fix a real problem — this
# role used to get its permissions from a module shared across several AWS
# accounts, and that module allowed creating or modifying almost any IAM
# role (a classic way to accidentally grant yourself admin access). That
# shared module isn't used anymore (this role's permissions are now
# defined directly in this repo, already narrow), so the original problem
# can't happen anymore either — this file is kept anyway as extra
# insurance, following AWS's own advice:
#   - AWS Well-Architected (SEC03-BP05) calls out granting your management
#     account permissions it doesn't need as a common mistake to avoid.
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
}

resource "aws_iam_policy" "terraform_deploy_boundary" {
  name        = "TerraformDeployPermissionsBoundary"
  description = "Caps TerraformDeploy's effective permissions to what platform/ actually manages. Not editable by TerraformDeploy itself — see file header."
  policy      = data.aws_iam_policy_document.terraform_deploy_boundary.json
}
