terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
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
// S3 variables
//////////////////////////////////////////

variable "context" {
  description = "Radius-provided context for the recipe"
  type        = any
}

locals {
  container_name = try(var.context.resource.properties.container, "documents")
  unique_suffix  = substr(md5(local.resource_name), 0, 13)

  # S3 bucket name: lowercase alphanumeric, hyphens, 3-63 chars
  bucket_name = "s3-${local.unique_suffix}"

  tags = {
    "radapp.io/resource"    = local.resource_name
    "radapp.io/application" = local.application_name
    "radapp.io/environment" = local.environment_name
  }
}

//////////////////////////////////////////
// S3 bucket
//////////////////////////////////////////

module "s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = local.bucket_name

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  tags = local.tags
}

//////////////////////////////////////////
// Output
//////////////////////////////////////////

output "result" {
  value = {
    resources = []
    values = {
      endpoint    = "https://${module.s3_bucket.s3_bucket_bucket_regional_domain_name}"
      accountName = module.s3_bucket.s3_bucket_id
      accountKey  = ""
      container   = local.container_name
    }
  }
}
