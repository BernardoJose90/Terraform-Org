###############################################################################
# Main Module Calls
# The root module that orchestrates all resources
###############################################################################

module "terraform_deploy_role" {
  source = "git::https://github.com/BernardoJose90/Terraform-Platform.git//modules/terraform-deploy-role?ref=34c6cb69ef06e907faeee56ede694262306d5c88"

  management_account_id = var.management_account_id
  account_name          = var.account_name
  github_org            = var.github_org
  github_repo           = var.github_repo
  # terraform-apply (this repo's workflow) gates its apply job behind the
  # management-approval GitHub Environment. That changes the OIDC token's
  # sub claim to "repo:ORG/REPO:environment:management-approval" instead of
  # the ref-based one — see the module's github_environment description.
  github_environment = "management-approval"
  # Caps TerraformDeploy's effective permissions to what platform/ actually
  # manages — see terraform-deploy-boundary.tf for what this excludes and
  # why (ec2:*, VPN logging, unconstrained IAM role/policy management from
  # the module's shared permissions policy, none of which this account
  # uses).
  permissions_boundary_arn = aws_iam_policy.terraform_deploy_boundary.arn
}