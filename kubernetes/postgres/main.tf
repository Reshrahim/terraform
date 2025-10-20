terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
  }
}

variable "context" {
  description = "This variable contains Radius recipe context."
  type = any
}

variable "memory" {
  description = "Memory limits for the PostgreSQL container"
  type = map(object({
    memoryRequest = string
    memoryLimit  = string
  }))
  default = {
    S = {
      memoryRequest = "512Mi"
      memoryLimit   = "1024Mi"
    },
    M = {
      memoryRequest = "1Gi"
      memoryLimit   = "2Gi"
    }
  }
}

locals {
  uniqueName      = var.context.resource.name
  namespace       = var.context.runtime.kubernetes.namespace
  username        = "postgres"
  memory_settings = try(var.memory[var.context.resource.properties.size], var.memory["S"])
}

module "postgresql" {
  source  = "ballj/postgresql/kubernetes"
  version = "~> 1.2"
  namespace     = local.namespace
  object_prefix = local.uniqueName
  name          = local.uniqueName
  username      = local.username
  resources_requests_memory = local.memory_settings.memoryRequest
  resources_limits_memory   = local.memory_settings.memoryLimit
  password_key   = "password"
  image_name = "postgres"
  image_tag  = "16"
}

output "result" {
  value = {
    values = {
      host            = "${module.postgresql.hostname}.${local.namespace}.svc.cluster.local"
      port            = module.postgresql.port
      database        = module.postgresql.name
      username        = module.postgresql.username
      password_key    = module.postgresql.password_key
      password_secret = module.postgresql.password_secret
    }
  }
}
