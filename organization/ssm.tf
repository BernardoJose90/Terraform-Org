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

###############################################################################
# Account Tiers (SSM Parameters)
#
# Relocated from platform/discovery-role.tf (2026-08-17 split) — file move
# only, not a state move. This resource isn't in the 14-resource migration
# list, so it stays in organization/'s state; it just needed to live
# somewhere other than a file that was leaving the directory.
###############################################################################

locals {
  account_tiers = {
    management         = "production-approval"
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