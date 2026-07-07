###############################################################################
# SSM Parameter Store
# Store account IDs and tiers for discovery by other repos
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