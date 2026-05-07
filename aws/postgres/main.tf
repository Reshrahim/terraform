terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

variable "context" {
  description = "Radius-provided context for the recipe"
  type        = any
}

variable "region" {
  description = "AWS region for provisioned resources"
  type        = string
  default     = "us-west-2"
}

locals {
  name     = var.context.resource.name
  database = try(var.context.resource.properties.database, "postgres_db")
  size     = try(var.context.resource.properties.size, "S")
  port     = 5432
  username = "pgadmin"

  sku_map = {
    S = "db.t4g.micro"
    M = "db.r6g.large"
    L = "db.r6g.xlarge"
  }

  storage_map = {
    S = 20
    M = 50
    L = 100
  }

  tags = {
    "radius-resource"      = local.name
    "radius-resource-type" = "Radius.Data/postgreSqlDatabases"
  }
}

resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "random_id" "suffix" {
  byte_length = 4
}

# Security group allowing PostgreSQL access from within the VPC
data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "postgres" {
  name_prefix = "${local.name}-pg-"
  description = "Allow PostgreSQL access"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = local.port
    to_port     = local.port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "PostgreSQL"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_db_instance" "postgres" {
  identifier     = "${local.name}-${random_id.suffix.hex}"
  engine         = "postgres"
  engine_version = "16"
  instance_class = local.sku_map[local.size]

  allocated_storage = local.storage_map[local.size]
  storage_type      = "gp3"

  db_name  = replace(local.database, "-", "_")
  username = local.username
  password = random_password.admin.result
  port     = local.port

  vpc_security_group_ids = [aws_security_group.postgres.id]
  publicly_accessible    = true
  skip_final_snapshot    = true

  backup_retention_period = 7

  tags = local.tags
}

output "result" {
  value = {
    values = {
      host     = aws_db_instance.postgres.address
      port     = local.port
      database = aws_db_instance.postgres.db_name
      user     = local.username
      password = random_password.admin.result
    }
    resources = []
  }
  sensitive = true
}
