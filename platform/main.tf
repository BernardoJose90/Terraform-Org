###############################################################################
# Main Module Calls
# The root module that orchestrates all resources
###############################################################################

module "terraform_deploy_role" {
  source = "git::https://github.com/BernardoJose90/Terraform-Platform.git//modules/terraform-deploy-role?ref=bd438c672b63ef4a7d1b1a2a88f5dc77615fd08c"

  management_account_id = var.management_account_id
  account_name          = var.account_name
  github_org            = var.github_org
  github_repo           = var.github_repo
  # terraform-apply (this repo's workflow) gates its apply job behind the
  # management-approval GitHub Environment. That changes the OIDC token's
  # sub claim to "repo:ORG/REPO:environment:management-approval" instead of
  # the ref-based one — see the module's github_environment description.
  github_environment = "management-approval"
}