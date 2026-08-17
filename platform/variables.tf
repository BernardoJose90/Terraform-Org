###############################################################################
# Variables
###############################################################################

variable "home_region" {
  description = "Primary AWS region."
  type        = string
}

variable "management_account_id" {
  description = "AWS Account ID of the existing management account."
  type        = string
}

variable "account_name" {
  description = "Name of the management account."
  type        = string
}

variable "github_org" {
  description = "GitHub organization name for GitHub Actions."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name for GitHub Actions. Used by the TerraformDeploy/TerraformPlan trust policies (terraform_deploy_role module) — those roles are assumed by THIS repo's own CI, so this must be this repo's name."
  type        = string
}

variable "discovery_github_repo" {
  description = "GitHub repository name whose Actions runs are trusted to assume the github_discovery role (discovery-role.tf). Deliberately separate from github_repo: github_discovery is assumed by Terraform-Platform's CI (account discovery from SSM), not this repo's — sharing one variable between the two meant fixing one repo's trust silently broke the other's. See member-accounts/*/README or Terraform-Platform's workflows for where DISCOVERY_ROLE_ARN is consumed."
  type        = string
}
