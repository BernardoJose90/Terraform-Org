###############################################################################
# Publishes account IDs and tiers to SSM Parameter Store, so GitHub Actions
# and the Terraform-Platform repo can look them up instead of hardcoding.
#
# Both parameter sets below for_each over the same local.accounts map, so an
# account's ID and its tier always come from the same object. Previously
# these were two separately-maintained maps and their keys drifted apart
# (security-analytics vs security_analytics) without either failing --
# whichever account you add here, its tier now travels with it as a tag
# instead of a second list to keep in sync by hand.
###############################################################################

locals {
  accounts = {
    security           = aws_organizations_account.security
    security_analytics = aws_organizations_account.security_analytics
    network            = aws_organizations_account.network
    monitoring         = aws_organizations_account.monitoring
    production         = aws_organizations_account.production
    development        = aws_organizations_account.development
  }
}

resource "aws_ssm_parameter" "account_ids" {
  # checkov:skip=CKV2_AWS_34:Account IDs, not secrets — they appear in ARNs
  # and cross-account trust policies throughout this repo already.
  # checkov:skip=CKV_AWS_337:Same reasoning — SecureString/KMS CMK would add
  # a key and kms:Decrypt to every consumer (this repo's own roles plus every
  # member account's read role) for content that was never confidential.
  for_each = local.accounts

  name      = "/organizations/accounts/${each.key}"
  value     = each.value.id
  type      = "String"
  overwrite = true

  tags = {
    ManagedBy = "Terraform"
    Purpose   = "Share account IDs with other Terraform configurations"
  }
}

###############################################################################
# Same idea, for each account's approval tier (whether its applies need a
# human to approve, or can run automatically). The management account has no
# aws_organizations_account resource here, so it's published separately.
###############################################################################

resource "aws_ssm_parameter" "account_tier" {
  # checkov:skip=CKV2_AWS_34:Tier labels like "production-approval" — config
  # strings, not secrets. Same reasoning as account_ids above.
  # checkov:skip=CKV_AWS_337:Same reasoning, KMS CMK variant of the same check.
  for_each = local.accounts

  name  = "/organizations/tiers/${each.key}"
  type  = "String"
  value = each.value.tags["Tier"]
}

resource "aws_ssm_parameter" "management_tier" {
  # checkov:skip=CKV2_AWS_34:Same reasoning as account_tier above.
  # checkov:skip=CKV_AWS_337:Same reasoning as account_tier above.
  name  = "/organizations/tiers/management"
  type  = "String"
  value = "management-approval"
}
