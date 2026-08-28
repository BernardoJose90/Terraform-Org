###############################################################################
# Security alerts
#
# Added 2026-08-26 to close the "how would you know if TerraformDeploy or
# BreakGlassAdmin were used unexpectedly" gap. Before this, the only
# notification mechanism anywhere in the estate was GitHub's built-in email
# on a failed scheduled workflow — nothing watched AWS itself.
#
# Two layers, both feeding the one security-alerts SNS topic:
#
#  1. EventBridge rules (this account only). Real-time, but the default
#     event bus only sees THIS account's events. Kept for the management
#     account because BreakGlassAdmin only exists here and these fire
#     fastest. AssumeRole is a read-only management event, so the rules
#     need state = ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS or they
#     silently match nothing.
#
#  2. CloudWatch Logs metric filters + alarms on the org trail's log group
#     (organization/cloudtrail.tf). The org trail aggregates EVERY account's
#     CloudTrail — member accounts included, and global (IAM/STS) events —
#     into that one log group, so these filters cover the whole estate from
#     one place. This is the CIS 4.4 / AWS SRA shape, and it replaces the
#     per-account modules/deploy-role-alerts that used to live in each
#     Terraform-platform member stack (removed 2026-08: pushing an
#     EventBridge rule + encrypted SNS topic + CMK into six tightly
#     permissions-boundaried accounts wasn't worth it).
#
# Ordering: the metric filters reference the org trail's log group by name,
# so organization/ must be applied before platform/ (it already is — the
# org has to exist first regardless).
###############################################################################

locals {
  # organization/cloudtrail.tf :: aws_cloudwatch_log_group.cloudtrail.name
  org_trail_log_group = "/aws/cloudtrail/org-trail"
}

variable "alert_email" {
  description = "Email address to notify on unexpected TerraformDeploy or BreakGlassAdmin use. Required — supply via a gitignored *.auto.tfvars file locally, or TF_VAR_alert_email / a repo secret in CI. No default on purpose: this alarm is silent and useless without a real destination, and a placeholder default is the kind of thing that quietly never gets fixed."
  type        = string
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# SNS SSE needs a customer-managed key, not alias/aws/sns: a publisher can
# only reach an encrypted topic if the key policy grants it kms:Decrypt +
# kms:GenerateDataKey*, and the AWS-managed key's policy can't be edited.
# Both publishers here — EventBridge rules and CloudWatch alarms — need it.
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
    sid       = "AllowPublishersToEncryptedTopic"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "cloudwatch.amazonaws.com"]
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
    sid     = "AllowPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "cloudwatch.amazonaws.com"]
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

# Without an input_transformer, EventBridge hands SNS the raw CloudTrail
# record as-is — a wall of nested JSON with the actually-useful fields
# buried several levels deep, which is what the email used to look like
# before this. This reshapes it into a few labeled lines instead.
#
# Every field below is guaranteed present on any event this rule can ever
# match: requestParameters.roleArn exists because the rule's own event
# pattern already requires it to match a specific suffix, and the rest
# (time/eventName/userIdentity.*/sourceIPAddress) are on every CloudTrail
# record, full stop. Deliberately not reaching for anything less certain
# than that — EventBridge silently drops the whole notification if any one
# input_paths entry doesn't resolve on a given event, so an alert firing at
# all matters more here than including one more field.
resource "aws_cloudwatch_event_target" "unexpected_deploy_assume" {
  rule = aws_cloudwatch_event_rule.unexpected_deploy_assume.name
  arn  = aws_sns_topic.security_alerts.arn

  input_transformer {
    input_paths = {
      time      = "$.time"
      eventName = "$.detail.eventName"
      idType    = "$.detail.userIdentity.type"
      principal = "$.detail.userIdentity.arn"
      sourceIp  = "$.detail.sourceIPAddress"
      roleArn   = "$.detail.requestParameters.roleArn"
    }
    # This is AWS's own documented pattern for multi-line plain-text output
    # (EventBridge docs, "Common Issues with transforming input" ->
    # "For (non-JSON) text output as multi-line strings"), not something
    # worked out by trial and error: one independently-quoted JSON string
    # per line, stacked with real newlines between them in the heredoc.
    # EventBridge decodes each line on its own and joins them with real
    # line breaks. Different from a single JSON string with escaped
    # newlines inside it, which is what two earlier, failed versions of
    # this line tried instead — one didn't pass AWS's own validation at
    # all, the other passed validation but delivered the escape sequences
    # and quote marks literally in the email (confirmed by an actual test).
    input_template = <<-EOT
      "⚠️ TerraformDeploy assumed outside GitHub Actions OIDC"
      ""
      "When:       <time>"
      "Event:      <eventName>"
      "Role:       <roleArn>"
      "Assumed by: <principal> (<idType>)"
      "Source IP:  <sourceIp>"
      ""
      "This should only ever happen via the documented BreakGlass path (management-account root + MFA). If this wasn't you, investigate immediately."
    EOT
  }
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

# Same reasoning as unexpected_deploy_assume's target above. This rule
# matches two different CloudTrail record shapes (API call vs. console
# sign-in), but both share the same base envelope — time/eventName/
# eventSource/awsRegion/sourceIPAddress/userIdentity.arn are present on
# every CloudTrail record regardless of shape, so these are safe to rely
# on for either event type this rule can match.
resource "aws_cloudwatch_event_target" "breakglass_admin_used" {
  rule = aws_cloudwatch_event_rule.breakglass_admin_used.name
  arn  = aws_sns_topic.security_alerts.arn

  input_transformer {
    input_paths = {
      time        = "$.time"
      eventName   = "$.detail.eventName"
      eventSource = "$.detail.eventSource"
      region      = "$.detail.awsRegion"
      principal   = "$.detail.userIdentity.arn"
      sourceIp    = "$.detail.sourceIPAddress"
    }
    # See unexpected_deploy_assume's target above for the full reasoning —
    # same AWS-documented multi-line pattern here.
    input_template = <<-EOT
      "🚨 BreakGlassAdmin was used"
      ""
      "When:      <time>"
      "Action:    <eventName> (<eventSource>)"
      "Region:    <region>"
      "Used by:   <principal>"
      "Source IP: <sourceIp>"
      ""
      "BreakGlassAdmin is meant for rare, out-of-band emergency use only. If this wasn't you, investigate immediately."
    EOT
  }
}

###############################################################################
# Layer 2 — estate-wide metric filters on the org trail's CloudWatch Logs
# group. These see every account (member accounts + this one) and global
# IAM/STS events, which a per-account EventBridge rule cannot. CIS 4.4 shape:
# metric filter -> metric -> alarm (threshold 1, Sum, 300s, >=), alarm ->
# the same security-alerts SNS topic.
#
# For the management account these overlap the EventBridge rules above (two
# emails on a real event) — deliberate: a rare, sensitive event should be
# over-noticed, not de-duplicated.
###############################################################################

# Plain AssumeRole (not AssumeRoleWithWebIdentity) on any *:role/TerraformDeploy,
# in any account. Per each role's trust policy the only principal that can do
# this is the management account root with MFA — i.e. BreakGlass.
resource "aws_cloudwatch_log_metric_filter" "unexpected_deploy_assume" {
  name           = "unexpected-terraform-deploy-assume"
  log_group_name = local.org_trail_log_group

  pattern = "{ ($.eventSource = \"sts.amazonaws.com\") && ($.eventName = \"AssumeRole\") && ($.requestParameters.roleArn = \"*:role/TerraformDeploy\") }"

  metric_transformation {
    name          = "UnexpectedTerraformDeployAssume"
    namespace     = "Security/CloudTrail"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "unexpected_deploy_assume" {
  alarm_name          = "unexpected-terraform-deploy-assume"
  alarm_description   = "A TerraformDeploy role was assumed via plain AssumeRole (BreakGlass, not GitHub OIDC) somewhere in the org."
  namespace           = "Security/CloudTrail"
  metric_name         = "UnexpectedTerraformDeployAssume"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.security_alerts.arn]
}

# Out-of-band changes to the TerraformDeploy / TerraformPlan roles — trust
# policy, inline/attached policy, permissions boundary, or the role itself.
# The last clause drops changes the pipeline makes to its own roles (routine);
# a change made after a BreakGlass assume is excluded here too, but that path
# already trips the alarm above. IAM is global — only the org trail (multi-
# region + global service events) surfaces these; a regional EventBridge rule
# would not.
resource "aws_cloudwatch_log_metric_filter" "deploy_role_tampering" {
  name           = "terraform-deploy-role-tampering"
  log_group_name = local.org_trail_log_group

  pattern = "{ ($.eventSource = \"iam.amazonaws.com\") && ($.eventName = \"UpdateAssumeRolePolicy\" || $.eventName = \"PutRolePolicy\" || $.eventName = \"DeleteRolePolicy\" || $.eventName = \"AttachRolePolicy\" || $.eventName = \"DetachRolePolicy\" || $.eventName = \"PutRolePermissionsBoundary\" || $.eventName = \"DeleteRolePermissionsBoundary\" || $.eventName = \"UpdateRole\" || $.eventName = \"DeleteRole\") && ($.requestParameters.roleName = \"TerraformDeploy\" || $.requestParameters.roleName = \"TerraformPlan\") && ($.userIdentity.sessionContext.sessionIssuer.userName != \"TerraformDeploy\") }"

  metric_transformation {
    name          = "TerraformDeployRoleTampering"
    namespace     = "Security/CloudTrail"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "deploy_role_tampering" {
  alarm_name          = "terraform-deploy-role-tampering"
  alarm_description   = "An out-of-band IAM change touched a TerraformDeploy/TerraformPlan role (trust policy, attached policy, or permissions boundary) somewhere in the org."
  namespace           = "Security/CloudTrail"
  metric_name         = "TerraformDeployRoleTampering"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.security_alerts.arn]
}
