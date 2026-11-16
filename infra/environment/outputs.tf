output "agent_id" {
  value = azapi_resource.agent.id
}

output "agent_endpoint" {
  value = azapi_resource.agent.output.properties.agentEndpoint
}

output "workspace_id" {
  value = azapi_resource.workspace.id
}

output "workspace_customer_id" {
  value = azapi_resource.workspace.output.properties.customerId
}

output "monitoring_identity_id" {
  value = azurerm_user_assigned_identity.monitoring.id
}

output "monitoring_principal_id" {
  value = azurerm_user_assigned_identity.monitoring.principal_id
}

output "checkout_id" {
  value = azapi_resource.checkout.id
}
