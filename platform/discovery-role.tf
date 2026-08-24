###############################################################################
# GitHub Discovery Role
# Read-only role for GitHub Actions to discover accounts from SSM
###############################################################################

data "aws_iam_openid_connect_provider" "github" {
  arn = "arn:aws:iam::145678291484:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_discovery_trust" {
  statement {
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
      # Deliberately var.discovery_github_repo, NOT var.github_repo — this
      # role is assumed by Terraform-Platform's CI (account discovery), a
      # different repo than the one this Terraform config itself runs in.
      # See variables.tf for why these are two separate variables.
      values = ["repo:${var.github_org}/${var.discovery_github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_discovery" {
  name               = "GitHubActionsAccountDiscovery"
  assume_role_policy = data.aws_iam_policy_document.github_discovery_trust.json
  tags = {
    ManagedBy = "github-actions"
    Purpose   = "read-only account manifest discovery"
  }
}

resource "aws_iam_role_policy" "github_discovery_ssm_read" {
  name = "ReadAccountManifestOnly"
  role = aws_iam_role.github_discovery.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParametersByPath", "ssm:GetParameter"]
      Resource = "arn:aws:ssm:*:${var.management_account_id}:parameter/organizations/*"
    }]
  })
}


    # TEST: deliberately mis-indented comment to break terraform fmt -check (see test/diagnose-trigger)
