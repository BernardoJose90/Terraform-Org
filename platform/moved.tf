###############################################################################
# One-time address moves from the retired terraform_deploy_role module call
# to the resources now defined directly in this repo (terraform-deploy-
# role.tf, terraform-plan-role.tf). Every one of these is a pure rename —
# `terraform plan` should show these as "moved," never "destroy"/"create."
# Confirm that in the plan output before applying. Safe to delete this file
# once it's been applied once — the moves only matter the first time.
###############################################################################

moved {
  from = module.terraform_deploy_role.aws_iam_role.terraform_deploy
  to   = aws_iam_role.terraform_deploy
}

moved {
  from = module.terraform_deploy_role.aws_iam_role.terraform_plan
  to   = aws_iam_role.terraform_plan
}

moved {
  from = module.terraform_deploy_role.aws_iam_role_policy.terraform_plan_assume_ssm_readonly
  to   = aws_iam_role_policy.terraform_plan_assume_ssm_readonly
}

moved {
  from = module.terraform_deploy_role.aws_iam_role_policy_attachment.terraform_plan_readonly
  to   = aws_iam_role_policy_attachment.terraform_plan_readonly
}

moved {
  from = module.terraform_deploy_role.aws_iam_policy.terraform_plan_s3_role
  to   = aws_iam_policy.terraform_plan_s3_role
}

moved {
  from = module.terraform_deploy_role.aws_iam_role_policy_attachment.terraform_plan_s3_policy_attachment
  to   = aws_iam_role_policy_attachment.terraform_plan_s3_policy_attachment
}

# NOT moved, deliberately destroyed:
# module.terraform_deploy_role.aws_iam_role_policy.terraform_deploy_policy
#
# This was the shared module's wide "permissions" document (ec2:*,
# unconstrained iam:CreateRole/AttachRolePolicy/PassRole, VPN/CloudWatch
# logging). terraform-deploy-boundary.tf already capped every one of those
# actions down to nothing usable for this account (see that file's
# header) — removing the nominal grant changes nothing about what
# TerraformDeploy can actually do, so this one destroy in the plan is
# expected and safe, not a resource that needs a home.
