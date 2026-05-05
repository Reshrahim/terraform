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
  name           = var.context.resource.name
  container_name = try(var.context.resource.properties.container, "documents")

  tags = {
    "radius-resource"      = local.name
    "radius-resource-type" = "Radius.Storage/blobStorages"
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "storage" {
  bucket = "${local.name}-${random_id.suffix.hex}"
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "storage" {
  bucket = aws_s3_bucket.storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "storage" {
  bucket                  = aws_s3_bucket.storage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "result" {
  value = {
    values = {
      endpoint    = "https://${aws_s3_bucket.storage.bucket_regional_domain_name}"
      accountName = aws_s3_bucket.storage.bucket
      accountKey  = ""
      container   = local.container_name
    }
    resources = [
      aws_s3_bucket.storage.arn
    ]
  }
}
