###############################################################################
# TerraformPlan — dedicated to this account, same reasoning as
# terraform-deploy-role.tf. Unlike TerraformDeploy, this role never had a
# permissions boundary (AWS-managed ReadOnlyAccess plus two narrow inline
# grants was already the full extent of its permissions) — kept identical
# here, no boundary added, no behavior change.
###############################################################################

data "aws_iam_policy_document" "terraform_plan_trust_policy" {
  statement {
    sid     = "ManagementAccountBreakGlass"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.management_account_id}:root"]
    }
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }

  statement {
    sid     = "GitHubActionsPlan"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.github_repo}:pull_request",
        "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "terraform_plan" {
  name                 = "TerraformPlan"
  assume_role_policy   = data.aws_iam_policy_document.terraform_plan_trust_policy.json
  max_session_duration = 3600

  tags = {
    ManagedBy   = "github-actions" # kept as-is from the original module for parity, not fixing here
    Repo        = "${var.github_org}/${var.github_repo}"
    AccountName = var.account_name
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Lets terraform_plan borrow the SSMReadOnly role in the management
# account, just for reading SSM parameters from there while planning.
resource "aws_iam_role_policy" "terraform_plan_assume_ssm_readonly" {
  name = "AssumeManagementSSMReadOnly"
  role = aws_iam_role.terraform_plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "arn:aws:iam::${var.management_account_id}:role/SSMReadOnly"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_plan_readonly" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Read/write access to this account's own folder in the state bucket, for
# S3 state locking — ReadOnlyAccess above doesn't cover Put/DeleteObject.
resource "aws_iam_policy" "terraform_plan_s3_role" {
  name = "TerraformPlanS3Policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StateFileAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",    # required for S3 state locking (.tflock file)
          "s3:DeleteObject", # required to clean up lock files
        ]
        Resource = "arn:aws:s3:::james-terraform-state-2026/platform/*"
      },
      {
        Sid      = "ListOwnPrefixOnly"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::james-terraform-state-2026"
        Condition = {
          StringLike = {
            "s3:prefix" = ["platform/*"]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_plan_s3_policy_attachment" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = aws_iam_policy.terraform_plan_s3_role.arn
}
