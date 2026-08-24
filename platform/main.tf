###############################################################################
# Main Module Calls
# The root module that orchestrates all resources
###############################################################################

module "terraform_deploy_role" {
  # NOT YET PUSHED: this SHA is on a local, unpushed branch
  # (fix/apply-retry-and-oidc-boundary-compat) in Terraform-Platform as of
  # 2026-08-24. This ref will not resolve — `terraform init` will fail to
  # fetch it — until that branch (or its commits) is pushed to GitHub.
  # Also note the path change: the module was renamed from
  # terraform-deploy-role to github-oidc-roles partway through this repo's
  # history, well before this ref.
  source = "git::https://github.com/BernardoJose90/Terraform-Platform.git//modules/github-oidc-roles?ref=30758a1031fb05b0138cbac6293e5756665685b8"

  management_account_id = var.management_account_id
  account_name          = var.account_name
  github_org            = var.github_org
  github_repo           = var.github_repo
  # terraform-apply (this repo's workflow) gates its apply job behind the
  # management-approval GitHub Environment, which changes the OIDC token's
  # sub claim to "repo:ORG/REPO:environment:management-approval". The
  # module doesn't trust that environment name by default (only
  # production-approval/automated/teardown-approval), so it has to be
  # added explicitly here — see extra_trusted_environments' description.
  extra_trusted_environments = ["management-approval"]
  # platform/ already owns the account's GitHub OIDC provider itself (see
  # discovery-role.tf) — AWS allows only one per URL per account, so the
  # module must not also try to create one.
  create_oidc_provider = false
  # Caps TerraformDeploy's effective permissions to what platform/ actually
  # manages — see terraform-deploy-boundary.tf for what this excludes and
  # why (ec2:*, VPN logging, unconstrained IAM role/policy management from
  # the module's shared permissions policy, none of which this account
  # uses).
  permissions_boundary_arn = aws_iam_policy.terraform_deploy_boundary.arn
}