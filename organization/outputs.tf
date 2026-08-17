###############################################################################
# Outputs
###############################################################################

output "organization_id" {
  value = aws_organizations_organization.aws_Org.id
}

output "root_id" {
  value = local.root_id
}

# Optional: If you need account IDs in Terraform outputs
# output "account_ids" {
#   value = {
#     for k, v in aws_ssm_parameter.account_ids :
#     k => v.value
#   }
#   sensitive = true
# }
