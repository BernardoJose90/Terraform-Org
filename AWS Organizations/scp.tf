###############################################################################
# Region Restriction SCP
###############################################################################

data "aws_iam_policy_document" "region_restriction" {
  statement {
    sid       = "DenyOutsideAllowedRegions"
    effect    = "Deny"
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = var.allowed_regions
    }

    not_actions = [
      "iam:*",
      "sts:*",
      "organizations:*",
      "account:*",
      "aws-portal:*",
      "budgets:*",
      "ce:*",
      "cur:*",
      "support:*",
      "trustedadvisor:*",
      "cloudfront:*",
      "route53:*",
      "route53domains:*",
      "waf:*",
      "wafv2:*",
      "shield:*",
      "globalaccelerator:*",
      "sso:*",
      "sso-directory:*",
      "identitystore:*",
      "guardduty:*",
      "securityhub:*",
      "access-analyzer:*",
      "tag:*",
      "resource-explorer-2:*",
      "health:*",
    ]
  }
}

resource "aws_organizations_policy" "region_restriction" {
  name        = "region-restriction"
  description = "Denies actions outside the allowed regions: ${join(", ", var.allowed_regions)}"
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.region_restriction.json

  tags = {
    ManagedBy = "Terraform"
  }
}

resource "aws_organizations_policy_attachment" "region_restriction_dev_test" {
  policy_id = aws_organizations_policy.region_restriction.id
  target_id = aws_organizations_organizational_unit.workloads_dev.id
}