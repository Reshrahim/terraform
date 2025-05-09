terraform {
  required_providers {
    azure = {
      source  = "hashicorp/azurerm"
      version = ">= 2.0"
    }
  }
}

variable "location" {
  type    = string
  default = data.azurerm_resource_group.location
}

variable "context" {
  description = "This variable contains Radius recipe context."
  type = any
}

locals {
  capacity_lookup = {
    S = 10
    M = 20
    L = 30
  }
   uniqueName = var.context.resource.name
}

resource "azurerm_cognitive_account" "openai" {
  name                = local.uniqueName
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  kind                = "OpenAI"
  sku_name            = "S0"
}

resource "azurerm_cognitive_deployment" "gpt35" {
    name = "gpt-35-turbo"
    cognitive_account_id = azurerm_cognitive_account.openai.id
    model {
        format = "OpenAI"
        name = "gpt-35-turbo"
        version= "0125"
      }
    sku {
        name = "S0"
        capacity = local.capacity_lookup[var.context.resource.capacity]
      }
}

output "result" {
  value = {
    values = {
      apiVersion = "2023-05-15"
      endpoint   = azurerm_cognitive_account.openai.endpoint
      deployment = "gpt-35-turbo"
    }
    # Warning: sensitive output
    secrets = {
      apiKey = azurerm_cognitive_account.openai.primary_access_key
    }
  }
  sensitive = true
}
