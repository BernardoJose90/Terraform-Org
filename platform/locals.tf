###############################################################################
# Shared account-ID lookups
#
# IAM Identity Center resources used to live in this file (sso.tf) but moved
# to member-accounts/security/sso.tf (Terraform-Platform repo) — security is
# now the delegated admin for sso.amazonaws.com, per AWS's own guidance to
# keep automation permissions out of the management account where a
# delegation option exists. See organizations.tf
# (aws_organizations_delegated_administrator.identity_center).
#
# What's left here is still load-bearing: iam.tf's ssm_read_only_trust and
# state-bucket-policy.tf's account-prefix mapping both consume
# local.account_ids_sso.
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
