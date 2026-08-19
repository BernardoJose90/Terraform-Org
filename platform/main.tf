###############################################################################
# Main Module Calls
# The root module that orchestrates all resources
###############################################################################

module "terraform_deploy_role" {
  source = "git::https://github.com/BernardoJose90/Terraform-Platform.git//modules/terraform-deploy-role?ref=d25d3ef32be0fa683f4ae7b9d6d4e7b9d7c76e20"

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