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

variable "account_emails" {
  description = "Unique root email address for each member account."
  type = object({
    security           = string
    security_analytics = string
    network            = string
    monitoring         = string
    production         = string
    development        = string
  })
}

variable "allowed_regions" {
  description = "AWS regions permitted org-wide by the region-restriction SCP."
  type        = list(string)
  default     = ["eu-west-1", "eu-west-2"]
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
  description = "GitHub repository name for GitHub Actions."
  type        = string

}