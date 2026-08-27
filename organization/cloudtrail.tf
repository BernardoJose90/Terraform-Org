###############################################################################
# Organization CloudTrail trail
#
# Added 2026-08-26 to close the "nothing observes anything" gap: before
# this, there was no CloudTrail trail anywhere in the estate — only the
# default 90-day event history every account gets for free, which isn't
# durable, isn't centralized, and isn't queryable across accounts.
#
# `cloudtrail.amazonaws.com` is already a trusted service principal on the
# organization (see organizations.tf), so no further org-level enablement
# is needed for `is_organization_trail = true` to work — it applies this
# trail to every account in the org automatically, current and future,
# without each member account needing its own trail resource.
#
# This trail is the backbone for both observability concerns:
#   * durable, centralized, queryable STORAGE of management events (the S3
#     bucket below), and
#   * a CloudWatch Logs copy (also below) that CIS-style metric-filter
#     alarms and the EventBridge rules in platform/security-alerts.tf build
#     on. Current AWS docs are explicit that `AWS API Call via CloudTrail`
#     events reach EventBridge only when a trail with logging is enabled —
#     the free 90-day event history on its own is not a supported
#     EventBridge source, so those rules depend on this trail existing.
#
# Hardening status vs CIS AWS Foundations Benchmark section 3:
#   3.1 multi-region .............. yes (is_multi_region_trail)
#   3.2 log file validation ....... yes (enable_log_file_validation)
#   3.3 bucket not public ......... yes (public access block)
#   3.4 CloudWatch Logs .......... yes (aws_cloudwatch_log_group.cloudtrail)
#   3.6 bucket access logging .... yes (aws_s3_bucket_logging.cloudtrail)
#   3.7 KMS CMK encryption ....... yes (aws_kms_key.cloudtrail — trail + log group)
#   SRA: S3 Object Lock (WORM) ... TODO — deliberately deferred: COMPLIANCE
#       mode is irreversible per object, so it needs a considered retention
#       decision rather than a bundled default.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# CIS 3.7 — customer-managed CMK for the trail. One key covers the S3 log
# files and the CloudWatch Logs group. The encryption-context conditions
# scope each grant to this trail / this log group; org principals can
# decrypt log files they're otherwise allowed to read.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "cloudtrail_kms" {
  #checkov:skip=CKV_AWS_111:KMS key policy — "*" resource means "this key" (a key policy only ever scopes its own key). Grants are constrained by service principal + encryption-context conditions.
  #checkov:skip=CKV_AWS_356:Same — a key policy's resource is always "*" meaning the key it's attached to.
  #checkov:skip=CKV_AWS_109:Root gets kms:* so the account keeps control of its own key — this is the AWS-required "Enable IAM User Permissions" statement, not an unconstrained grant to others.
  statement {
    sid       = "EnableIAMUserPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowCloudTrailEncrypt"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"]
    }
  }

  statement {
    sid       = "AllowOrgPrincipalsToDecryptLogFiles"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:ReEncryptFrom"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [aws_organizations_organization.aws_Org.id]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"]
    }
  }

  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/cloudtrail/org-trail"]
    }
  }
}

resource "aws_kms_key" "cloudtrail" {
  description             = "CMK for the organization CloudTrail — S3 log files and CloudWatch Logs group"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.cloudtrail_kms.json
}

resource "aws_kms_alias" "cloudtrail" {
  name          = "alias/org-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail.key_id
}

resource "aws_s3_bucket" "cloudtrail" {
  # Bucket names are global — account ID suffix keeps this collision-free
  # without needing a random_id resource.
  bucket = "org-cloudtrail-logs-${data.aws_caller_identity.current.account_id}"

  #checkov:skip=CKV_AWS_144:Single-region audit store is an accepted risk for now; cross-region / backup-account replication is tracked with the Object Lock follow-up.
  #checkov:skip=CKV2_AWS_62:Log-sink bucket — nothing consumes object-created events; integrity is covered by versioning + CloudTrail log-file validation.
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      # Bucket-default SSE. CloudTrail objects are actually encrypted with
      # the CMK via the trail's own kms_key_id (which carries the
      # aws:cloudtrail:arn encryption context); this default just governs
      # anything else and keeps the bucket KMS-encrypted at rest.
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Trail logs are only useful for as long as they're worth the storage —
# push to cheaper storage quickly, and cap total retention rather than
# keeping everything forever by default.
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    id     = "expire-and-transition"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    expiration {
      days = 400
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*", "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/*/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  # CIS 3.x / SRA: reject any request to this bucket that isn't over TLS.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cloudtrail.arn, "${aws_s3_bucket.cloudtrail.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json
}

# ---------------------------------------------------------------------------
# CIS 3.6 — S3 server access logging on the trail bucket. Separate bucket so
# access-log deliveries don't themselves generate access-log deliveries.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "cloudtrail_access_logs" {
  bucket = "org-cloudtrail-access-logs-${data.aws_caller_identity.current.account_id}"

  #checkov:skip=CKV_AWS_144:Second-order log data; single-region is fine, replicating it is not worth the cost.
  #checkov:skip=CKV2_AWS_62:Log-sink bucket — nothing consumes object-created events.
  #checkov:skip=CKV_AWS_145:SSE-S3 (AES256) is the standard for S3 server-access-log targets; SSE-KMS needs the log-delivery service added to a key policy for no real benefit on second-order log data.
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_access_logs" {
  bucket                  = aws_s3_bucket.cloudtrail_access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudtrail_access_logs" {
  bucket = aws_s3_bucket.cloudtrail_access_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_access_logs" {
  bucket = aws_s3_bucket.cloudtrail_access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3, not KMS: the S3 log-delivery service can't use a CMK without
      # extra grants, and these access logs don't warrant it.
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail_access_logs" {
  bucket = aws_s3_bucket.cloudtrail_access_logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 400
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "cloudtrail_access_logs" {
  statement {
    sid       = "S3ServerAccessLogsPolicy"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail_access_logs.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.cloudtrail.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cloudtrail_access_logs.arn, "${aws_s3_bucket.cloudtrail_access_logs.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail_access_logs" {
  bucket = aws_s3_bucket.cloudtrail_access_logs.id
  policy = data.aws_iam_policy_document.cloudtrail_access_logs.json
}

resource "aws_s3_bucket_logging" "cloudtrail" {
  bucket        = aws_s3_bucket.cloudtrail.id
  target_bucket = aws_s3_bucket.cloudtrail_access_logs.id
  target_prefix = "cloudtrail-bucket-access/"
}

# ---------------------------------------------------------------------------
# CIS 3.4 — CloudWatch Logs delivery. This is what makes the trail usable as
# an alerting source (metric filters + alarms, and the EventBridge rules in
# platform/security-alerts.tf). For an organization trail, every member
# account's events land as log streams named <account-id>_CloudTrail_<region>
# inside THIS log group in the management account.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/org-trail"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.cloudtrail.arn
}

data "aws_iam_policy_document" "cloudtrail_cwl_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudtrail_cwl" {
  name               = "cloudtrail-to-cloudwatch-logs"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_cwl_assume.json
}

data "aws_iam_policy_document" "cloudtrail_cwl" {
  statement {
    sid     = "AWSCloudTrailCreateLogStreamAndPutEvents"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    # log-stream:* (not scoped to this account) because member-account
    # streams are created here too, under their own account IDs.
    resources = ["${aws_cloudwatch_log_group.cloudtrail.arn}:log-stream:*"]
  }
}

resource "aws_iam_role_policy" "cloudtrail_cwl" {
  name   = "cloudtrail-to-cloudwatch-logs"
  role   = aws_iam_role.cloudtrail_cwl.id
  policy = data.aws_iam_policy_document.cloudtrail_cwl.json
}

resource "aws_cloudtrail" "organization" {
  #checkov:skip=CKV_AWS_252:Log-file-delivery SNS notifications are legacy; downstream consumption is the CloudWatch Logs group and EventBridge, not SNS-on-new-object.
  name                          = "org-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.cloudtrail.arn

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cwl.arn

  depends_on = [
    aws_s3_bucket_policy.cloudtrail,
    aws_iam_role_policy.cloudtrail_cwl,
  ]
}
