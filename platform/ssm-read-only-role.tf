###############################################################################
# Lets each member account's own Terraform read /organizations/* parameters
# from SSM in the management account, without needing a hardcoded AWS CLI
# profile — a member account assumes this role instead.
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
  # Trusts every member account (by account root) to try assuming this
  # role. Trusting them here isn't enough on its own, though — each member
  # account also has to explicitly grant its own roles permission to
  # assume this specific ARN before anything in that account can actually
  # use it.
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
