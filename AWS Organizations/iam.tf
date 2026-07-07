# IAM Policy for terraform-org to write to SSM
resource "aws_iam_policy" "terraform_org_ssm" {
  name        = "TerraformOrgSSMPolicy"
  description = "Allow terraform-org to write account IDs to SSM Parameter Store"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:DeleteParameter",
          "ssm:DescribeParameters"
        ]
        Resource = "arn:aws:ssm:eu-west-2:145678291484:parameter/organizations/*"
      }
    ]
  })
}


# If we don't have an existing role, create one (optional)
resource "aws_iam_role" "terraform_org" {
  name = "TerraformOrgRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::145678291484:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_org_main" {
  role       = aws_iam_role.terraform_org.name
  policy_arn = aws_iam_policy.terraform_org_ssm.arn
}