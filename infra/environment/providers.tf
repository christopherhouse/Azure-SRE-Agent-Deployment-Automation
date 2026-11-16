terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.14.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "= 2.13.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                 = var.target_subscription_id
  tenant_id                       = var.tenant_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true
  use_cli                         = !var.use_oidc
  use_oidc                        = var.use_oidc
  use_msi                         = false
}

provider "azapi" {
  subscription_id            = var.target_subscription_id
  tenant_id                  = var.tenant_id
  skip_provider_registration = true
  use_cli                    = !var.use_oidc
  use_oidc                   = var.use_oidc
  use_msi                    = false
}
