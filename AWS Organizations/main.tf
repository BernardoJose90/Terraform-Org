###############################################################################
# Main Module Calls
# The root module that orchestrates all resources
###############################################################################

module "terraform_deploy_role" {
  source = "git::https://github.com/BernardoJose90/Terraform-Platform.git//modules/terraform-deploy-role?ref=main"

  management_account_id = var.management_account_id
  account_name          = var.account_name
}