###############################################################################
# Outputs
###############################################################################

output "organization_id" {
  value = aws_organizations_organization.this.id
}

output "root_id" {
  value = local.root_id
}

output "discovery_role_arn" {
  value = aws_iam_role.github_discovery.arn
}

# Optional: If you need account IDs in Terraform outputs
# output "account_ids" {
#   value = {
#     for k, v in aws_ssm_parameter.account_ids :
#     k => v.value
#   }
#   sensitive = true
# }