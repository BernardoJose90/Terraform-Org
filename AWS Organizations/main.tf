###############################################################################
# Main Module Calls
# The root module that orchestrates all resources
###############################################################################

module "terraform_deploy_role" {
  source = "git::https://github.com/BernardoJose90/Terraform-Platform.git//modules/terraform-deploy-role?ref=2ed2b8e0dd9c4ebd3fc54055878209b80e91d5b4"

  management_account_id = var.management_account_id
  account_name          = var.account_name
}