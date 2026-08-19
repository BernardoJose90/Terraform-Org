###############################################################################
# TerraformDeploy's IAM management gap.
#
# Surfaced 2026-08-17 by the FIRST real run of terraform-apply against this
# account — the old workflow's `needs: terraform-plan` on the apply job made
# apply unreachable (push and pull_request triggers never coincide), so it
# had literally never executed. This gap predates the organization/platform
# split and was never caught. terraform_deploy_role's built-in `permissions`
# policy (pinned module, ref 2ed2b8e0dd9c4ebd3fc54055878209b80e91d5b4) was
# written for EC2/instance-profile roles (ManageInstanceRoles:
# CreateRole/GetRole/DeleteRole/TagRole, AttachRolePolicy/DetachRolePolicy
# for MANAGED policy attachments) — it never covered standalone
# customer-managed policies (aws_iam_policy), inline role policies
# (aws_iam_role_policy), trust-policy updates (UpdateAssumeRolePolicy), or
# reading the GitHub OIDC provider (GetOpenIDConnectProvider). Exactly what
# iam.tf, discovery-role.tf, and the inline policies below need.
#
# Scoped to the specific resources TerraformDeploy actually manages here —
# not iam:*, not Resource = "*" — same narrow-grant pattern as
# terraform_deploy_state_bucket_policy_access and terraform_plan_lock_access
# (state-bucket-policy.tf).
###############################################################################

resource "aws_iam_role_policy" "terraform_deploy_iam_management_access" {
  name = "IAMManagementAccess"
  role = module.terraform_deploy_role.role_name

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
        # A permissions boundary doesn't grant anything by itself — it only
        # narrows what an actual identity policy grants (AWS IAM User Guide:
        # "does not provide permissions on its own"). terraform-deploy-
        # boundary.tf's own ReadOwnBoundaryPolicy statement is the boundary
        # half of that AND; this is the identity-policy half. Without both,
        # TerraformDeploy can't even read its own boundary to refresh it in
        # state — confirmed by testing as the assumed role, not just
        # reviewing the HCL (GetPolicy came back AccessDenied without this).
        # Deliberately read-only: no CreatePolicyVersion/DeletePolicy here,
        # so TerraformDeploy still can't edit or widen its own ceiling — see
        # terraform-deploy-boundary.tf's file header for why.
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
