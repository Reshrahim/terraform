terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1"
    }
  }
}

//////////////////////////////////////////
// Common Radius variables
//////////////////////////////////////////

locals {
  resource_name    = var.context.resource.name
  application_name = var.context.application != null ? var.context.application.name : ""
  environment_name = var.context.environment != null ? var.context.environment.name : ""
  namespace        = var.context.runtime.kubernetes.namespace
}

//////////////////////////////////////////
// PostgreSQL variables
//////////////////////////////////////////

variable "context" {
  description = "Radius-provided context for the recipe"
  type        = any
}

variable "vpcId" {
  description = "VPC ID where the RDS instance will be created"
  type        = string
}

variable "subnetIds" {
  description = "JSON-encoded list of subnet IDs for the DB subnet group"
  type        = string
}

variable "instanceClass" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "allocatedStorage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

locals {
  port          = 5432
  database      = try(var.context.resource.properties.database, "postgres_db")
  secret_name   = var.context.resource.properties.secretName
  version       = try(var.context.resource.properties.version, "16")
  unique_suffix = substr(md5(local.resource_name), 0, 13)

  # RDS identifier: lowercase alphanumeric and hyphens, max 63 chars
  sanitized_identifier = "rds-pg-${local.unique_suffix}"

  # Database name: alphanumeric and underscores only
  sanitized_database = replace(local.database, "/[^0-9A-Za-z_]/", "_")

  tags = {
    "radapp.io/resource"    = local.resource_name
    "radapp.io/application" = local.application_name
    "radapp.io/environment" = local.environment_name
  }
}

//////////////////////////////////////////
// Credentials
//////////////////////////////////////////

data "kubernetes_secret" "db_credentials" {
  metadata {
    name      = local.secret_name
    namespace = local.namespace
  }
}

//////////////////////////////////////////
// RDS security group
//////////////////////////////////////////

data "aws_vpc" "selected" {
  id = var.vpcId
}

module "rds_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "rds-pg-sg-${local.unique_suffix}"
  description = "Security group for RDS PostgreSQL - ${local.resource_name}"
  vpc_id      = var.vpcId

  ingress_with_cidr_blocks = [
    {
      from_port   = local.port
      to_port     = local.port
      protocol    = "tcp"
      description = "PostgreSQL access"
      cidr_blocks = data.aws_vpc.selected.cidr_block
    }
  ]

  egress_rules = ["all-all"]

  tags = local.tags
}

//////////////////////////////////////////
// RDS instance
//////////////////////////////////////////

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = local.sanitized_identifier

  engine               = "postgres"
  engine_version       = local.version
  family               = "postgres${local.version}"
  major_engine_version = local.version
  instance_class       = var.instanceClass

  db_name  = local.sanitized_database
  username = try(data.kubernetes_secret.db_credentials.data["USERNAME"], "")
  password = try(data.kubernetes_secret.db_credentials.data["PASSWORD"], "")
  port     = local.port

  allocated_storage = var.allocatedStorage
  storage_type      = "gp3"

  create_db_subnet_group = true
  db_subnet_group_name   = "rds-pg-subnetgroup-${local.unique_suffix}"
  subnet_ids             = jsondecode(var.subnetIds)

  vpc_security_group_ids = [module.rds_security_group.security_group_id]

  skip_final_snapshot = true
  apply_immediately   = true

  tags = local.tags
}

//////////////////////////////////////////
// Output
//////////////////////////////////////////

output "result" {
  value = {
    resources = []
    values = {
      host     = module.db.db_instance_address
      port     = module.db.db_instance_port
      database = local.sanitized_database
    }
  }
}
