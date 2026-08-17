############################################################################
# AWS Organizations OUs, Accounts, and Delegated Administrators
############################################################################

# This resource is used to move the AWS Organization from the management account to a new account.
moved {
  from = aws_organizations_organization.this
  to   = aws_organizations_organization.aws_Org
}

# This module creates the AWS Organization, Organizational Units, Member Accounts, and Delegated Administrators for the organization. 
# It also enables the necessary service principals for AWS services that require access to the organization.
resource "aws_organizations_organization" "aws_Org" {
  feature_set = "ALL"

  enabled_policy_types = [
    "SERVICE_CONTROL_POLICY",
    "TAG_POLICY",
  ]

  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "sso.amazonaws.com",
    "guardduty.amazonaws.com",
    "securityhub.amazonaws.com",
    "access-analyzer.amazonaws.com",
    "account.amazonaws.com",
    "ram.amazonaws.com",
  ]
  lifecycle {
    prevent_destroy = true
  }
}

locals {
  root_id = aws_organizations_organization.aws_Org.roots[0].id
}

# Organizational Units
resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = local.root_id
  tags      = { ManagedBy = "Terraform" }
}

resource "aws_organizations_organizational_unit" "infrastructure" {
  name      = "Infrastructure"
  parent_id = local.root_id
  tags      = { ManagedBy = "Terraform" }
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = local.root_id
  tags      = { ManagedBy = "Terraform" }
}

resource "aws_organizations_organizational_unit" "workloads_prod" {
  name      = "Prod"
  parent_id = aws_organizations_organizational_unit.workloads.id
  tags      = { ManagedBy = "Terraform" }
}

resource "aws_organizations_organizational_unit" "workloads_dev" {
  name      = "Dev"
  parent_id = aws_organizations_organizational_unit.workloads.id
  tags      = { ManagedBy = "Terraform" }
}

# Member Accounts
resource "aws_organizations_account" "security" {
  name      = "security"
  email     = var.account_emails["security"]
  parent_id = aws_organizations_organizational_unit.security.id
  role_name = "OrganizationAccountAccessRole"
  tags = {
    OU        = "Security"
    Purpose   = "Centralized security operations"
    ManagedBy = "Terraform"
  }
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, email]
  }
}

resource "aws_organizations_account" "security_analytics" {
  name      = "security-analytics"
  email     = var.account_emails["security_analytics"]
  parent_id = aws_organizations_organizational_unit.security.id
  role_name = "OrganizationAccountAccessRole"
  tags = {
    OU        = "Security"
    Purpose   = "AI-generated security findings analysis"
    ManagedBy = "Terraform"
  }
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, email]
  }
}

resource "aws_organizations_account" "network" {
  name      = "network"
  email     = var.account_emails["network"]
  parent_id = aws_organizations_organizational_unit.infrastructure.id
  role_name = "OrganizationAccountAccessRole"
  tags = {
    OU        = "Infrastructure"
    Purpose   = "Shared networking infrastructure"
    ManagedBy = "Terraform"
  }
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, email]
  }
}

resource "aws_organizations_account" "monitoring" {
  name      = "monitoring"
  email     = var.account_emails["monitoring"]
  parent_id = aws_organizations_organizational_unit.infrastructure.id
  role_name = "OrganizationAccountAccessRole"
  tags = {
    OU        = "Infrastructure"
    Purpose   = "Centralized observability"
    ManagedBy = "Terraform"
  }
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, email]
  }
}

resource "aws_organizations_account" "production" {
  name      = "production"
  email     = var.account_emails["production"]
  parent_id = aws_organizations_organizational_unit.workloads_prod.id
  role_name = "OrganizationAccountAccessRole"
  tags = {
    OU          = "Workloads/Prod"
    Purpose     = "Live workload hosting"
    Environment = "production"
    ManagedBy   = "Terraform"
  }
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, email]
  }
}

resource "aws_organizations_account" "development" {
  name      = "development"
  email     = var.account_emails["development"]
  parent_id = aws_organizations_organizational_unit.workloads_dev.id
  role_name = "OrganizationAccountAccessRole"
  tags = {
    OU          = "Workloads/Dev"
    Purpose     = "Development and testing"
    Environment = "development"
    ManagedBy   = "Terraform"
  }
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, email]
  }
}

# Delegated Administrators
resource "aws_organizations_delegated_administrator" "guardduty" {
  account_id        = aws_organizations_account.security.id
  service_principal = "guardduty.amazonaws.com"
}

resource "aws_organizations_delegated_administrator" "securityhub" {
  account_id        = aws_organizations_account.security.id
  service_principal = "securityhub.amazonaws.com"
}

resource "aws_organizations_delegated_administrator" "access_analyzer" {
  account_id        = aws_organizations_account.security.id
  service_principal = "access-analyzer.amazonaws.com"
}

# Delegates IAM Identity Center administration to security, per AWS's own
# guidance: minimize what has access to the management account by delegating
# admin of services that support it. See sso.tf's header comment and
# member-accounts/security/sso.tf (Terraform-Platform repo) for where SSO
# resource management actually lives now.
resource "aws_organizations_delegated_administrator" "identity_center" {
  account_id        = aws_organizations_account.security.id
  service_principal = "sso.amazonaws.com"
}