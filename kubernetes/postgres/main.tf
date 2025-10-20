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
  uniqueName = var.context.resource.name
  namespace = var.context.runtime.kubernetes.namespace
  username = "postgres"
}

module "postgresql" {
  source        = "ballj/postgresql/kubernetes"
  version       = "~> 1.2"
  namespace     = namespace
  object_prefix = "myapp-db"
  name          = uniqueName
  password_key = "password"
}

output "result" {
  value = {
    values = {
      host = "${kubernetes_service.postgresql.metadata[0].name}.${kubernetes_service.postgresql.metadata[0].namespace}.svc.cluster.local"
      port = "${kubernetes_service.postgresql.spec[0].port[0].port}"
      database = local.uniqueName
      username = local.username
      password_key = "password"
      password_secret = "${kubernetes_secret.postgresql[0].metadata[0].name}"
    }
  }
}
