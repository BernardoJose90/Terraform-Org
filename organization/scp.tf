###############################################################################
# A Service Control Policy (SCP) — an org-wide guardrail that blocks certain
# actions no matter what permissions an individual account or user has.
# This one blocks doing anything outside the allowed AWS regions.
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

    # Everything below is exempt from the region block — these are global
    # services that either don't run in any specific region at all (IAM,
    # Organizations, Route 53, CloudFront...) or need to work everywhere
    # regardless (billing, support). Blocking them "outside the allowed
    # region" would just break them entirely, since they were never tied
    # to a region to begin with.
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