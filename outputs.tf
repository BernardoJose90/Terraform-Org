output "organization_id" {
  description = "The AWS Organization ID."
  value       = aws_organizations_organization.this.id
}

output "root_id" {
  description = "Root OU ID."
  value       = local.root_id
}

output "account_ids" {
  description = "Map of account name to AWS Account ID."
  value = {
    security           = aws_organizations_account.security.id
    security_analytics = aws_organizations_account.security_analytics.id
    network            = aws_organizations_account.network.id
    monitoring         = aws_organizations_account.monitoring.id
    production         = aws_organizations_account.production.id
    development        = aws_organizations_account.development.id
  }
}

output "cross_account_role_arns" {
  description = "Role ARNs to assume when running Terraform in each member account."
  value = {
    for name, id in {
      security           = aws_organizations_account.security.id
      security_analytics = aws_organizations_account.security_analytics.id
      network            = aws_organizations_account.network.id
      monitoring         = aws_organizations_account.monitoring.id
      production         = aws_organizations_account.production.id
      development        = aws_organizations_account.development.id
    } : name => "arn:aws:iam::${id}:role/OrganizationAccountAccessRole"
  }
}
