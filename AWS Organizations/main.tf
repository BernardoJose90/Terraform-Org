#####################################################################################################
# This is the AWS Organizations setup that creates our member accounts and writes their IDs 
# to SSM Parameter Store. This is the first step in our multi-account setup.
#####################################################################################################

#####################################################################################################
# Summary Flow
# 1-Enable AWS Organizations
# 2-Create OU hierarchy (Security → Infrastructure → Workloads/Prod & Dev)
# 3-Create 6 member accounts in appropriate OUs
# 4-Delegate Security account to manage GuardDuty, SecurityHub, and Access Analyzer
# 5-Store all account IDs in SSM Parameter Store for other configurations to consume
# 6-SSO Resources: Users, Groups, Permission Sets, and Account Assignments
# This setup creates a landing zone for a well-architected multi-account AWS environment following 
# best practices for separation of duties and centralized security management.
#####################################################################################################

#####################################################################################################
# This main.tf file manages AWS Organizations – Multi-Account Landing Zone(OUs, accounts) 
# Delegates security account as the administrators for securityhub, guardDuty and access_analyzer.
# 
# Management account: james.jose109099@gmail.com (145678291484)
# 
# FIRST-TIME SETUP — run this once before terraform apply:
# terraform import aws_organizations_organization.this r-sywu
#####################################################################################################

terraform {
  required_version = ">= 1.10.0"

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
# 1. Creates an IAM role for Terraform to deploy resources
# Source: Pulls module from a Git repository (Terraform-Platform)
# Creates the role that Terraform uses to manage AWS Organizations
# Module sourced from terraform-platform repository
###############################################################################

module "terraform_deploy_role" {
  source = "git::https://github.com/BernardoJose90/Terraform-Platform.git//modules/terraform-deploy-role?ref=main"
  
  management_account_id = var.management_account_id
  account_name = var.account_name
}

###############################################################################
# 2. AWS Organizations Configuration
# Enables AWS Organizations in the management account
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

# Purpose: Extracts the organization root ID for use in OU creation
locals {
  root_id = aws_organizations_organization.this.roots[0].id
}

# security OU to hold security-related accounts.
resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = local.root_id
  tags      = { ManagedBy = "Terraform" }
}

# infrastructure OU to hold shared infrastructure accounts (network, monitoring).
resource "aws_organizations_organizational_unit" "infrastructure" {
  name      = "Infrastructure"
  parent_id = local.root_id
  tags      = { ManagedBy = "Terraform" }
}

# Parent OU for all workload accounts.
resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = local.root_id
  tags      = { ManagedBy = "Terraform" }
}

# Child of Workloads OU for production workloads
resource "aws_organizations_organizational_unit" "workloads_prod" {
  name      = "Prod"
  parent_id = aws_organizations_organizational_unit.workloads.id
  tags      = { ManagedBy = "Terraform" }
}

# Child of Workloads OU for development workloads
resource "aws_organizations_organizational_unit" "workloads_dev" {
  name      = "Dev"
  parent_id = aws_organizations_organizational_unit.workloads.id
  tags      = { ManagedBy = "Terraform" }
}

# Creates security OU.
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

# Purpose: Designates the Security account as the delegated administrator for:
# GuardDuty: Threat detection service
# SecurityHub: Security posture management
# Access Analyzer: IAM policy analysis
# This means the Security account can:
# Manage GuardDuty across all organization accounts
# Aggregate SecurityHub findings from all accounts
# Run Access Analyzer across the organization

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
# 3. Store all account IDs in SSM Parameter Store 
# These will be read by terraform-platform repo in github to configure SSO permissions
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

###############################################################################
# 4. Region Restriction SCP
# Denies API calls outside var.allowed_regions, except for actions on global
# services that either have no regional endpoint or must remain reachable
# from any region (IAM, STS, Organizations, CloudFront, Route 53, Support,
# Billing, Identity Center / SSO, etc.)
###############################################################################

data "aws_iam_policy_document" "region_restriction" {
  statement {
    sid       = "DenyOutsideAllowedRegions"
    effect    = "Deny"
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = var.allowed_regions
    }

    not_actions = [
      "iam:*",
      "sts:*",
      "organizations:*",
      "account:*",
      "aws-portal:*",
      "budgets:*",
      "ce:*",
      "cur:*",
      "support:*",
      "trustedadvisor:*",
      "cloudfront:*",
      "route53:*",
      "route53domains:*",
      "waf:*",
      "wafv2:*",
      "shield:*",
      "globalaccelerator:*",
      "sso:*",
      "sso-directory:*",
      "identitystore:*",
      "guardduty:*",
      "securityhub:*",
      "access-analyzer:*",
      "tag:*",
      "resource-explorer-2:*",
      "health:*",
    ]
  }
}

resource "aws_organizations_policy" "region_restriction" {
  name        = "region-restriction"
  description = "Denies actions outside the allowed regions: ${join(", ", var.allowed_regions)}"
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.region_restriction.json

  tags = {
    ManagedBy = "Terraform"
  }
}

resource "aws_organizations_policy_attachment" "region_restriction_dev_test" {
  policy_id = aws_organizations_policy.region_restriction.id
  target_id = aws_organizations_organizational_unit.workloads_dev.id
}

###############################################################################
# 5. SSO Resources — IAM Identity Center
# Users, Groups, Permission Sets, and Account Assignments
# These are managed as code and read account IDs from SSM Parameter Store
###############################################################################

# Data source for IAM Identity Center instance
data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
  
  # Account names for SSO assignments
  sso_account_names = [
    "security",
    "security_analytics",
    "network",
    "monitoring",
    "production",
    "development"
  ]
}

# Data sources for account IDs (read from SSM)
data "aws_ssm_parameter" "account_ids_sso" {
  for_each = toset(local.sso_account_names)
  name     = "/organizations/accounts/${each.value}"
}

locals {
  account_ids_sso = {
    for name in local.sso_account_names :
    name => data.aws_ssm_parameter.account_ids_sso[name].value
  }
}

# Permission Sets
resource "aws_ssoadmin_permission_set" "administrator" {
  name             = "AdministratorAccess"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT2H"
  description      = "Full administrator access. For platform engineers only."
  tags = { ManagedBy = "Terraform" }
}

resource "aws_ssoadmin_managed_policy_attachment" "administrator" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_ssoadmin_permission_set" "network_administrator" {
  name             = "NetworkAdministrator"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT2H"
  description      = "Network administration access. For network team."
  tags = { ManagedBy = "Terraform" }
}

resource "aws_ssoadmin_managed_policy_attachment" "network_administrator" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.network_administrator.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/job-function/NetworkAdministrator"
}

resource "aws_ssoadmin_permission_set" "read_only" {
  name             = "ReadOnly"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT1H"
  description      = "Read-only access. For developers viewing production."
  tags = { ManagedBy = "Terraform" }
}

resource "aws_ssoadmin_managed_policy_attachment" "read_only" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.read_only.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Groups
resource "aws_identitystore_group" "administrators" {
  display_name      = "administrators"
  description       = "Platform engineers with full access to all accounts."
  identity_store_id = local.identity_store_id
}

resource "aws_identitystore_group" "security_team" {
  display_name      = "Security Team"
  description       = "Security engineers with access to security accounts."
  identity_store_id = local.identity_store_id
}

resource "aws_identitystore_group" "network_team" {
  display_name      = "Network Team"
  description       = "Network engineers with access to network account."
  identity_store_id = local.identity_store_id
}

# Users
resource "aws_identitystore_user" "james_admin" {
  identity_store_id = local.identity_store_id
  display_name      = "james jose"
  user_name         = "james.admin"
  name {
    given_name  = "james"
    family_name = "jose"
  }
  emails {
    value   = "james.jose109099+aws-mgemt@gmail.com"
    type    = "work"
    primary = true
  }
}

# Group Memberships
resource "aws_identitystore_group_membership" "james_administrators" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.administrators.group_id
  member_id         = aws_identitystore_user.james_admin.user_id
}

resource "aws_identitystore_group_membership" "james_security_team" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.security_team.group_id
  member_id         = aws_identitystore_user.james_admin.user_id
}

resource "aws_identitystore_group_membership" "james_network_team" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.network_team.group_id
  member_id         = aws_identitystore_user.james_admin.user_id
}

# Account Assignments
# Administrators → Full Admin → ALL accounts
resource "aws_ssoadmin_account_assignment" "administrators_admin" {
  for_each = local.account_ids_sso

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.administrators.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = each.value
}

# Administrators → Read-Only → Production (Safety net)
resource "aws_ssoadmin_account_assignment" "administrators_readonly_prod" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.read_only.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.administrators.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.account_ids_sso["production"]
}

# Security Team → AdministratorAccess → Security + Security Analytics
resource "aws_ssoadmin_account_assignment" "security_team_admin" {
  for_each = {
    security           = local.account_ids_sso["security"]
    security_analytics = local.account_ids_sso["security_analytics"]
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.security_team.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = each.value
}

# Network Team → NetworkAdministrator → Network account only
resource "aws_ssoadmin_account_assignment" "network_team_network_admin" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.network_administrator.arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.network_team.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.account_ids_sso["network"]
}