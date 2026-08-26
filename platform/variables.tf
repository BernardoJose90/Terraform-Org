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
  description = "GitHub repository name for GitHub Actions. Used by TerraformDeploy/TerraformPlan's trust policies (terraform-deploy-role.tf, terraform-plan-role.tf) — those roles are assumed by THIS repo's own CI, so this must be this repo's name."
  type        = string
}

variable "discovery_github_repo" {
  description = "GitHub repository name whose Actions runs are allowed to assume the github_discovery role (discovery-role.tf). Kept as its own variable, separate from github_repo, on purpose: github_discovery is used by Terraform-Platform's CI (to look up account IDs) — a different repo than the one this config runs in. Sharing one variable between both used to mean fixing one repo's access could silently break the other's."
  type        = string
}
