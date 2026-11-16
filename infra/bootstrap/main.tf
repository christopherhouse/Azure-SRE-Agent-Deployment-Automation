terraform {
  required_version = ">= 1.15.2, < 2.0.0"

  backend "local" {}

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
  use_cli                         = true
  use_oidc                        = false
  use_msi                         = false
}

provider "azurerm" {
  alias = "state"
  features {}
  subscription_id                 = split("/", var.state_storage_account_id)[2]
  tenant_id                       = var.tenant_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true
  use_cli                         = true
  use_oidc                        = false
  use_msi                         = false
}

provider "azapi" {
  subscription_id            = split("/", var.state_storage_account_id)[2]
  tenant_id                  = var.tenant_id
  skip_provider_registration = true
  use_cli                    = true
  use_oidc                   = false
  use_msi                    = false
}

locals {
  tags = {
    project    = "sre-checkout"
    managed_by = "terraform-bootstrap"
  }
  container_scope = "${var.state_storage_account_id}/blobServices/default/containers/sre-checkout"
  blob_role_id    = "/subscriptions/${split("/", var.state_storage_account_id)[2]}/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe"
}

resource "azurerm_resource_group" "target" {
  name     = "rg-sre-checkout-westus3"
  location = "westus3"
  tags     = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_user_assigned_identity" "deployment" {
  name                = "id-sre-checkout-github"
  resource_group_name = azurerm_resource_group.target.name
  location            = azurerm_resource_group.target.location
  tags                = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_federated_identity_credential" "main" {
  name                      = "github-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.deployment.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "${var.github_subject_prefix}:ref:refs/heads/main"
}

# ARM-only container management avoids the AzureRM container ACL Shared Key path.
resource "azapi_resource" "state_container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2025-08-01"
  name      = "sre-checkout"
  parent_id = "${var.state_storage_account_id}/blobServices/default"
  body = {
    properties = {
      publicAccess = "None"
      metadata = {
        managed_by = "terraform-bootstrap"
        project    = "sre-checkout"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "deployment_state" {
  provider                         = azurerm.state
  name                             = uuidv5("url", "${local.container_scope}/${azurerm_user_assigned_identity.deployment.principal_id}/blob-contributor")
  scope                            = azapi_resource.state_container.id
  role_definition_id               = local.blob_role_id
  principal_id                     = azurerm_user_assigned_identity.deployment.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "operator_state" {
  provider           = azurerm.state
  name               = uuidv5("url", "${local.container_scope}/${var.operator_object_id}/blob-contributor")
  scope              = azapi_resource.state_container.id
  role_definition_id = local.blob_role_id
  principal_id       = var.operator_object_id
  principal_type     = "User"
}

resource "azurerm_role_assignment" "deployment_resources" {
  name                 = uuidv5("url", "${azurerm_resource_group.target.id}/${azurerm_user_assigned_identity.deployment.principal_id}/contributor")
  scope                = azurerm_resource_group.target.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.deployment.principal_id
  principal_type       = "ServicePrincipal"
}

# The operator establishes this only after the environment identity exists.
resource "azurerm_role_assignment" "environment_rbac" {
  count                = var.monitoring_principal_id == null ? 0 : 1
  name                 = uuidv5("url", "${azurerm_resource_group.target.id}/${azurerm_user_assigned_identity.deployment.principal_id}/environment-rbac")
  scope                = azurerm_resource_group.target.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.deployment.principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = <<-CONDITION
    (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
      OR
      (
        (
          @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {acdd72a7-3385-48ef-bd42-f606fba81ae7, 73c42c96-874c-492b-b04d-ab87d138a893}
          AND
          @Request[Microsoft.Authorization/roleAssignments:PrincipalId] GuidEquals ${var.monitoring_principal_id}
        )
        OR
        (
          @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] GuidEquals e79298df-d852-4c6d-84f9-5d13249d1e55
          AND
          @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {${azurerm_user_assigned_identity.deployment.principal_id}, ${var.operator_object_id}}
        )
      )
    )
    AND
    (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
      OR
      (
        (
          @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {acdd72a7-3385-48ef-bd42-f606fba81ae7, 73c42c96-874c-492b-b04d-ab87d138a893}
          AND
          @Resource[Microsoft.Authorization/roleAssignments:PrincipalId] GuidEquals ${var.monitoring_principal_id}
        )
        OR
        (
          @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] GuidEquals e79298df-d852-4c6d-84f9-5d13249d1e55
          AND
          @Resource[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAnyValues:GuidEquals {${azurerm_user_assigned_identity.deployment.principal_id}, ${var.operator_object_id}}
        )
      )
    )
  CONDITION
}
