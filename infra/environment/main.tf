data "azurerm_resource_group" "target" {
  name = "rg-sre-checkout-westus3"
}

data "azurerm_user_assigned_identity" "deployment" {
  name                = "id-sre-checkout-github"
  resource_group_name = data.azurerm_resource_group.target.name
}

locals {
  location = "westus3"
  suffix   = substr(sha256(data.azurerm_resource_group.target.id), 0, 8)
  tags = {
    project    = "sre-checkout"
    managed_by = "terraform-environment"
  }
}

resource "azurerm_user_assigned_identity" "monitoring" {
  name                = "id-sre-checkout-monitoring"
  resource_group_name = data.azurerm_resource_group.target.name
  location            = local.location
  tags                = local.tags

  lifecycle {
    precondition {
      condition     = data.azurerm_resource_group.target.location == local.location
      error_message = "The bootstrap resource group must be in West US 3."
    }
  }
}

# ARM-only management does not retrieve the workspace shared keys into state.
resource "azapi_resource" "workspace" {
  type      = "Microsoft.OperationalInsights/workspaces@2025-07-01"
  name      = "law-sre-checkout"
  parent_id = data.azurerm_resource_group.target.id
  location  = local.location
  tags      = local.tags
  body = {
    properties = {
      sku             = { name = "PerGB2018" }
      retentionInDays = 30
      workspaceCapping = {
        dailyQuotaGb = 1
      }
      features = {
        disableLocalAuth = true
      }
    }
  }
  response_export_values = ["properties.customerId"]
}

resource "azurerm_role_assignment" "discovery" {
  name                 = uuidv5("url", "${data.azurerm_resource_group.target.id}/${azurerm_user_assigned_identity.monitoring.principal_id}/reader")
  scope                = data.azurerm_resource_group.target.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.monitoring.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "logs" {
  name                 = uuidv5("url", "${azapi_resource.workspace.id}/${azurerm_user_assigned_identity.monitoring.principal_id}/log-reader")
  scope                = azapi_resource.workspace.id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_user_assigned_identity.monitoring.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azapi_resource" "agent" {
  type      = "Microsoft.App/agents@2026-01-01"
  name      = "sre-checkout-${local.suffix}"
  parent_id = data.azurerm_resource_group.target.id
  location  = local.location
  tags      = local.tags
  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.monitoring.id]
  }
  body = {
    properties = {
      actionConfiguration = {
        accessLevel = "Low"
        mode        = "Review"
        identity    = azurerm_user_assigned_identity.monitoring.id
      }
      knowledgeGraphConfiguration = {
        identity         = azurerm_user_assigned_identity.monitoring.id
        managedResources = [data.azurerm_resource_group.target.id]
      }
    }
  }
  response_export_values = ["properties.agentEndpoint", "properties.provisioningState"]
  depends_on             = [azurerm_role_assignment.discovery, azurerm_role_assignment.logs]
}

resource "azurerm_role_assignment" "agent_administrators" {
  for_each = {
    operator   = { principal_id = var.operator_object_id, principal_type = "User" }
    deployment = { principal_id = data.azurerm_user_assigned_identity.deployment.principal_id, principal_type = "ServicePrincipal" }
  }
  name                 = uuidv5("url", "${azapi_resource.agent.id}/${each.value.principal_id}/sre-admin")
  scope                = azapi_resource.agent.id
  role_definition_name = "SRE Agent Administrator"
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type
}
