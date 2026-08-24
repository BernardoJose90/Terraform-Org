###############################################################################
# Cross-account SSM read access for member accounts (Option A pattern)
# Lets each member account's Terraform read /organizations/* parameters
# without hardcoding AWS CLI profiles.
###############################################################################

data "aws_iam_policy_document" "ssm_read_only" {
  statement {
    sid       = "ReadOrgParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParametersByPath", "ssm:DescribeParameters"]
    resources = ["arn:aws:ssm:eu-west-2:${var.management_account_id}:parameter/organizations/*"]
  }
}

resource "aws_iam_policy" "ssm_read_only" {
  name   = "SSMReadOnlyForMemberAccounts"
  policy = data.aws_iam_policy_document.ssm_read_only.json
}

data "aws_iam_policy_document" "ssm_read_only_trust" {
  # Trust every member account (by account root). Whether a specific
  # role/user inside that account can actually assume this role still
  # depends on THAT account granting sts:AssumeRole on this ARN — see Step 2.
  dynamic "statement" {
    for_each = local.account_ids_sso
    content {
      sid     = "Trust${title(replace(statement.key, "_", ""))}Account"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]
      principals {
        type        = "AWS"
        identifiers = ["arn:aws:iam::${statement.value}:root"]
      }
    }
  }
}

resource "aws_iam_role" "ssm_read_only" {
  name               = "SSMReadOnly"
  assume_role_policy = data.aws_iam_policy_document.ssm_read_only_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm_read_only" {
  role       = aws_iam_role.ssm_read_only.name
  policy_arn = aws_iam_policy.ssm_read_only.arn
}
