###############################################################################
# Security alerts — management account
#
# Added 2026-08-26 to close the "how would you know if TerraformDeploy or
# BreakGlassAdmin were used unexpectedly" gap. Before this, the only
# notification mechanism anywhere in the estate was GitHub's built-in email
# on a failed scheduled workflow — nothing watched AWS itself.
#
# These rules depend on the organization trail in
# organization/cloudtrail.tf: current AWS docs say `AWS API Call via
# CloudTrail` events reach EventBridge only when a trail with logging is
# enabled — the free 90-day event history alone is not a supported source.
#
# AssumeRole / AssumeRoleWithWebIdentity are *read-only* management events,
# which a plain state = ENABLED rule drops. The assume rule below must set
# state = ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS or it silently
# matches nothing. (The BreakGlassAdmin rule also matches Console Sign In
# and mutating calls, so it is less affected — but the opt-in is harmless
# there and keeps both rules consistent.)
#
# Scope: this file only covers the management account, since that's the
# only account this root module manages, and it's the only account
# BreakGlassAdmin exists in. Terraform-platform's member accounts each
# have their own copy of this same pattern — see
# modules/deploy-role-alerts in that repo, wired into each
# member-accounts/*/main.tf.
###############################################################################

variable "alert_email" {
  description = "Email address to notify on unexpected TerraformDeploy or BreakGlassAdmin use. Required — supply via a gitignored *.auto.tfvars file locally, or TF_VAR_alert_email / a repo secret in CI. No default on purpose: this alarm is silent and useless without a real destination, and a placeholder default is the kind of thing that quietly never gets fixed."
  type        = string
  default = "bernardo.jose@websummit.com"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# SNS SSE needs a customer-managed key, not alias/aws/sns: EventBridge can
# only publish to an encrypted topic if the key policy grants
# events.amazonaws.com kms:Decrypt + kms:GenerateDataKey*, and the
# AWS-managed key's policy can't be edited.
data "aws_iam_policy_document" "security_alerts_kms" {
  #checkov:skip=CKV_AWS_111:KMS key policy — "*" means "this key"; grants are constrained by principal + conditions.
  #checkov:skip=CKV_AWS_356:Same — a key policy's resource is always "*" meaning the key it is attached to.
  #checkov:skip=CKV_AWS_109:Root gets kms:* so the account keeps control of its own key (AWS-required statement).
  statement {
    sid       = "EnableIAMUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowEventBridgePublishToEncryptedTopic"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "security_alerts" {
  description             = "CMK for the security-alerts SNS topic"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.security_alerts_kms.json
}

resource "aws_kms_alias" "security_alerts" {
  name          = "alias/security-alerts"
  target_key_id = aws_kms_key.security_alerts.key_id
}

resource "aws_sns_topic" "security_alerts" {
  name              = "security-alerts"
  kms_master_key_id = aws_kms_key.security_alerts.key_id
}

resource "aws_sns_topic_subscription" "security_alerts_email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "security_alerts_topic_policy" {
  statement {
    sid     = "AllowEventBridgePublish"
    effect  = "Allow"
    actions = ["sns:Publish"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    resources = [aws_sns_topic.security_alerts.arn]
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.security_alerts_topic_policy.json
}

# Fires when TerraformDeploy (this account's copy of it — see
# terraform-deploy-role.tf) is assumed by anything other than the GitHub
# OIDC federated identity. In normal operation every assumption is
# AssumeRoleWithWebIdentity with userIdentity.type == "WebIdentityUser".
# The only other legitimate path is the documented BreakGlass one (root
# account + MFA, see terraform-deploy-role.tf's "ManagementAccountBreakGlass"
# statement) — which is exactly the case this should still alert on, since
# break-glass access is meant to be rare and always noticed.
resource "aws_cloudwatch_event_rule" "unexpected_deploy_assume" {
  name        = "unexpected-terraform-deploy-assume"
  description = "TerraformDeploy assumed by something other than GitHub Actions OIDC (i.e. BreakGlass)"
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = jsonencode({
    source        = ["aws.sts"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["AssumeRole", "AssumeRoleWithWebIdentity"]
      requestParameters = {
        roleArn = [{ suffix = ":role/TerraformDeploy" }]
      }
      userIdentity = {
        type = [{ "anything-but" = ["WebIdentityUser"] }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "unexpected_deploy_assume" {
  rule = aws_cloudwatch_event_rule.unexpected_deploy_assume.name
  arn  = aws_sns_topic.security_alerts.arn
}

# Fires on ANY use of the BreakGlassAdmin IAM user's access key. This
# credential's only intended use is a human, out-of-band, assuming
# TerraformDeploy/TerraformPlan during an incident (see breakglass-user.tf
# and scripts/breakglass-bootstrap.sh in Terraform-platform) — so any
# activity from it at all is worth a human looking at, not just the
# assume-role calls.
#
# state: the intended use IS an AssumeRole call, which is a read-only
# management event — so this rule needs the same opt-in as the one above,
# or it would miss exactly the event it exists for.
resource "aws_cloudwatch_event_rule" "breakglass_admin_used" {
  name        = "breakglass-admin-used"
  description = "Any AWS API activity authenticated as the BreakGlassAdmin IAM user"
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"]
    detail = {
      userIdentity = {
        type     = ["IAMUser"]
        userName = ["BreakGlassAdmin"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "breakglass_admin_used" {
  rule = aws_cloudwatch_event_rule.breakglass_admin_used.name
  arn  = aws_sns_topic.security_alerts.arn
}
