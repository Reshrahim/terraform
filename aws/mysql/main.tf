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
// MySQL variables
//////////////////////////////////////////

locals {
  port        = 3306
  database    = try(var.context.resource.properties.database, local.application_name)
  secret_name = var.context.resource.properties.secretName
  version     = try(var.context.resource.properties.version, "8.4")

  # RDS identifier must be lowercase alphanumeric and hyphens, max 63 chars
  sanitized_identifier = substr(replace(lower(local.resource_name), "/[^a-z0-9-]/", "-"), 0, 63)

  # Database name must be alphanumeric and underscores
  sanitized_database = replace(local.database, "/[^a-zA-Z0-9_]/", "_")

  tags = {
    "radapp.io/resource"    = local.resource_name
    "radapp.io/application" = local.application_name
    "radapp.io/environment" = local.environment_name
  }
}

//////////////////////////////////////////
// Credentials
//////////////////////////////////////////

# Read credentials from the Kubernetes secret provided by the developer
data "kubernetes_secret" "db_credentials" {
  metadata {
    name      = local.secret_name
    namespace = local.namespace
  }
}

//////////////////////////////////////////
// RDS Deployment
//////////////////////////////////////////

resource "aws_db_subnet_group" "mysql" {
  name       = "${local.sanitized_identifier}-subnet-group"
  subnet_ids = var.subnetIds

  tags = local.tags
}

resource "aws_db_instance" "mysql" {
  identifier     = local.sanitized_identifier
  engine         = "mysql"
  engine_version = local.version
  instance_class = "db.t3.micro"

  db_name  = local.sanitized_database
  username = data.kubernetes_secret.db_credentials.data["USERNAME"]
  password = data.kubernetes_secret.db_credentials.data["PASSWORD"]
  port     = local.port

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.mysql.name
  vpc_security_group_ids = [var.securityGroupId]
  publicly_accessible    = false

  skip_final_snapshot       = true
  final_snapshot_identifier = "${local.sanitized_identifier}-final"

  tags = local.tags
}

//////////////////////////////////////////
// Output
//////////////////////////////////////////

output "result" {
  value = {
    resources = []
    values = {
      host     = aws_db_instance.mysql.address
      port     = aws_db_instance.mysql.port
      database = local.sanitized_database
    }
  }
}
