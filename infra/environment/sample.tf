resource "azapi_resource" "container_environment" {
  type      = "Microsoft.App/managedEnvironments@2025-07-01"
  name      = "cae-sre-checkout"
  parent_id = data.azurerm_resource_group.target.id
  location  = local.location
  tags      = local.tags
  body = {
    properties = {
      appLogsConfiguration = {
        destination = "azure-monitor"
      }
      workloadProfiles = [{
        name                = "Consumption"
        workloadProfileType = "Consumption"
      }]
    }
  }
  response_export_values = ["properties.provisioningState"]
}

resource "azurerm_monitor_diagnostic_setting" "checkout" {
  name                       = "checkout-workspace"
  target_resource_id         = azapi_resource.container_environment.id
  log_analytics_workspace_id = azapi_resource.workspace.id
  enabled_log {
    category = "ContainerAppConsoleLogs"
  }
  enabled_log {
    category = "ContainerAppSystemLogs"
  }
}

resource "azapi_resource" "checkout" {
  type      = "Microsoft.App/containerApps@2025-07-01"
  name      = "ca-sre-checkout"
  parent_id = data.azurerm_resource_group.target.id
  location  = local.location
  tags      = local.tags
  body = {
    properties = {
      environmentId       = azapi_resource.container_environment.id
      workloadProfileName = "Consumption"
      configuration = {
        activeRevisionsMode = "Single"
      }
      template = {
        containers = [{
          name    = "checkout"
          image   = "docker.io/library/python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e"
          command = ["python", "-u", "-c", file("${path.module}/../../sample/checkout.py")]
          env = [{
            name  = "CHECKOUT_FAULT_ENABLED"
            value = tostring(var.fault_enabled)
          }]
          resources = {
            cpu    = 0.25
            memory = "0.5Gi"
          }
        }]
        scale = {
          minReplicas = 1
          maxReplicas = 1
        }
      }
    }
  }
  response_export_values = ["properties.provisioningState", "properties.latestReadyRevisionName", "properties.runningStatus"]
  depends_on             = [azurerm_monitor_diagnostic_setting.checkout]
}
