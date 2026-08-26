###############################################################################
# Shared account-ID lookups
#
# This file used to also manage IAM Identity Center (SSO) resources, but
# those moved to member-accounts/security/sso.tf in the Terraform-Platform
# repo — the `security` account now handles SSO administration instead of
# the management account, following AWS's advice to keep the management
# account's own permissions as minimal as possible. See organizations.tf's
# aws_organizations_delegated_administrator.identity_center for where that
# handoff is set up.
#
# What's left here is still needed: ssm-read-only-role.tf's
# ssm_read_only_trust and state-bucket-policy.tf's account-prefix mapping
# both use local.account_ids_sso.
###############################################################################

locals {
  sso_account_names = [
    "security",
    "security_analytics",
    "network",
    "monitoring",
    "production",
    "development"
  ]
}

data "aws_ssm_parameter" "account_ids_sso" {
  for_each = toset(local.sso_account_names)
  name     = "/organizations/accounts/${each.value}"
}

locals {
  account_ids_sso = {
    for name in local.sso_account_names :
    name => data.aws_ssm_parameter.account_ids_sso[name].value
  }
}
