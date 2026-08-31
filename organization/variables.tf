###############################################################################
# Variables
###############################################################################

variable "home_region" {
  description = "Primary AWS region."
  type        = string
}

variable "account_emails" {
  description = "Unique root email address for each member account."
  # These are AWS root-account emails — the primary recovery vector for
  # every member account. Marked sensitive so `terraform plan` renders them
  # as (sensitive value) in stdout and the PR comment; the repo is public
  # and the plan output is posted there. Sourced from the ACCOUNT_EMAILS_JSON
  # secret via TF_VAR_account_emails in terraform.yaml.
  sensitive = true
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
