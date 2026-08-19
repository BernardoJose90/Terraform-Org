###############################################################################
# SSM Parameter Store to Store account IDs and tiers for discovery by Github Action and Terraform-Platform repos
###############################################################################

resource "aws_ssm_parameter" "account_ids" {
  for_each = {
    security           = aws_organizations_account.security.id
    security_analytics = aws_organizations_account.security_analytics.id
    network            = aws_organizations_account.network.id
    monitoring         = aws_organizations_account.monitoring.id
    production         = aws_organizations_account.production.id
    development        = aws_organizations_account.development.id
  }

  name      = "/organizations/accounts/${each.key}"
  value     = each.value
  type      = "String"
  overwrite = true

  tags = {
    ManagedBy = "Terraform"
    Purpose   = "Share account IDs with other Terraform configurations"
  }
}

####################################################################################################
# SSm parameters to store account tiers for discovery by Github Action and Terraform-Platform repos 
####################################################################################################

locals {
  account_tiers = {
    management         = "management-approval"
    security           = "production-approval"
    security-analytics = "production-approval"
    network            = "production-approval"
    monitoring         = "automated"
    production         = "production-approval"
    development        = "automated"
  }
}

resource "aws_ssm_parameter" "account_tier" {
  for_each = local.account_tiers

  name  = "/organizations/tiers/${each.key}"
  type  = "String"
  value = each.value
}