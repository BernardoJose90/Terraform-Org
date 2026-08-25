###############################################################################
# TerraformDeploy's supplemental IAM-management permissions.
#
# Grants what terraform-deploy-role.tf's own policy (state-bucket access
# only) doesn't: managing standalone customer-managed policies
# (aws_iam_policy), inline role policies (aws_iam_role_policy), trust-policy
# updates (UpdateAssumeRolePolicy), and reading the GitHub OIDC provider
# (GetOpenIDConnectProvider) — exactly what discovery-role.tf,
# terraform-org-role.tf, ssm-read-only-role.tf, and this role's own trust
# policy need. Kept as its own resource rather than merged into
# terraform-deploy-role.tf so future changes here never risk state churn on
# the role resource itself — that one's `prevent_destroy`-protected and is
# the identity CI's own apply run assumes to do the applying.
#
# Scoped to the specific resources TerraformDeploy actually manages here —
# not iam:*, not Resource = "*" — same narrow-grant pattern as
# terraform_deploy_state_bucket_policy_access and terraform_plan_lock_access
# (state-bucket-policy.tf).
###############################################################################

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
