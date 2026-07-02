###############################################################################
# This main.tf file manages AWS Organizations – Multi-Account Landing Zone(OUs, accounts) 
# Delegates security account as the administrators for securityhub, guardDuty and access_analyzer.
# 
# Management account: james.jose109099@gmail.com (145678291484)
# 
# FIRST-TIME SETUP — run this once before terraform apply:
# terraform import aws_organizations_organization.this r-sywu
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "james-terraform-state-2026"
    key            = "org/terraform.tfstate"
    region         = "eu-west-2"
    use_lockfile   = true
    encrypt        = true
  }
}

provider "aws" {
  region = var.home_region
}

###############################################################################
# 1. IAM Role for Terraform Deployment
# Creates the role that Terraform uses to manage AWS Organizations
# Module sourced from terraform-platform repository
###############################################################################

module "terraform_deploy_role" {
  source = "git::https://github.com/BernardoJose90/Terraform-Platform.git//modules/terraform-deploy-role?ref=main"
  
  management_account_id = "145678291484"
}

###############################################################################
# 2. AWS Organizations Configuration
###############################################################################

resource "aws_organizations_organization" "this" {
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
  ]
}

locals {
  root_id = aws_organizations_organization.this.roots[0].id
}

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
    ignore_changes  = [role_name]
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
    ignore_changes  = [role_name]
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
    ignore_changes  = [role_name]
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
    ignore_changes  = [role_name]
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
    ignore_changes  = [role_name]
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
    ignore_changes  = [role_name]
  }
}

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

###############################################################################
# 3. Store account IDs in SSM Parameter Store
# These will be read by terraform-platform to configure SSO permissions
###############################################################################

resource "aws_ssm_parameter" "account_ids" {
  for_each = {
    security           = aws_organizations_account.security.id
    security_analytics = aws_organizations_account.security_analytics.id
    network            = aws_organizations_account.network.id
    monitoring         = aws_organizations_account.monitoring.id
    production         = aws_organizations_account.production.id
    development        = aws_organizations_account.development.id
  }

  name      = "/organizations/accounts/${each.key}"
  value     = each.value
  type      = "String"
  overwrite = true

  tags = {
    ManagedBy = "Terraform"
    Purpose   = "Share account IDs with other Terraform configurations"
  }
}