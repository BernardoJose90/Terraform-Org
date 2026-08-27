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
      #
      # Scoped the same way TerraformPlan is (terraform-plan-role.tf),
      # rather than ":*" — this role is only ever assumed from the
      # discover-accounts job in Terraform-platform's terraform-plan.yaml,
      # terraform-apply.yaml, drift-detection.yaml and terraform-teardown.yaml,
      # none of which set a job-level `environment:`. That job only ever
      # runs from a pull_request event or from main (push, schedule, or a
      # workflow_dispatch dispatched against main) — so those are the only
      # two claim shapes that should ever be allowed to assume it. A
      # wildcard here would let a workflow run on any branch or fork read
      # the entire account manifest; audited 2026-08-26.
      values = [
        "repo:${var.github_org}/${var.discovery_github_repo}:pull_request",
        "repo:${var.github_org}/${var.discovery_github_repo}:ref:refs/heads/main",
      ]
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

# Was platform/outputs.tf — merged here 2026-08-25 since this is its only
# consumer (a human copies this into Terraform-Platform's DISCOVERY_ROLE_ARN
# GitHub Actions variable; see that repo's workflows).
output "discovery_role_arn" {
  value = aws_iam_role.github_discovery.arn
}
