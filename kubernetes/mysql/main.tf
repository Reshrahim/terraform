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

locals {
  uniqueName = var.context.resource.name
  port     = 3306
  namespace = var.context.runtime.kubernetes.namespace
}

resource "random_password" "password" {
  length           = 16
}

resource "kubernetes_deployment" "mysql" {
  metadata {
    name      = local.uniqueName
    namespace = local.namespace
  }

  spec {
    selector {
      match_labels = {
        app = "mysql"
      }
    }

    template {
      metadata {
        labels = {
          app = "mysql"
        }
      }

      spec {
        container {
          image = "mysql:8.0"
          name  = "mysql"
          env {
            name  = "MYSQL_PASSWORD"
            value = random_password.password.result
          }
          env {
            name = "MYSQL_USER"
            value = "mysqluser"
          }
          env {
            name  = "MYSQL_DB"
            value = "mysqldb"
          }
          port {
            container_port = local.port
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mysql" {
  metadata {
    name      = local.uniqueName
    namespace = local.namespace
  }

  spec {
    selector = {
      app = "mysql"
    }

    port {
      port        = local.port
      target_port = local.port
    } 
  }
}

output "result" {
  value = {
    values = {
      host = "${kubernetes_service.postgres.metadata[0].name}.${kubernetes_service.postgres.metadata[0].namespace}.svc.cluster.local"
      port = local.port
      database = "mysqldb"
      username = "mysqluser"
      password = random_password.password.result
    }
  }
}