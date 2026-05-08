terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
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

variable "username" {
  description = "Admin username for PostgreSQL"
  type        = string
  default     = "pgadmin"
}

variable "password" {
  description = "Admin password for PostgreSQL. If empty, a random password is generated."
  type        = string
  default     = ""
  sensitive   = true
}

locals {
  port          = 5432
  database      = try(var.context.resource.properties.database, "postgres_db")
  version       = try(var.context.resource.properties.version, "16")
  unique_suffix = substr(md5(local.resource_name), 0, 13)

  # RDS identifier: lowercase alphanumeric and hyphens, max 63 chars
  sanitized_identifier = "rds-pg-${local.unique_suffix}"

  # Database name: alphanumeric and underscores only
  sanitized_database = replace(local.database, "/[^0-9A-Za-z_]/", "_")

  admin_password = var.password != "" ? var.password : random_password.admin[0].result

  tags = {
    "radapp.io/resource"    = local.resource_name
    "radapp.io/application" = local.application_name
    "radapp.io/environment" = local.environment_name
  }
}

//////////////////////////////////////////
// Random password (used when password not provided)
//////////////////////////////////////////

resource "random_password" "admin" {
  count   = var.password == "" ? 1 : 0
  length  = 24
  special = false
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
  username = var.username
  password = local.admin_password
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
      user     = var.username
      password = local.admin_password
    }
  }
  sensitive = true
}
