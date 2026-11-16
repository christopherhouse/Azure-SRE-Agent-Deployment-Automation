output "github_variables" {
  description = "Non-secret repository variables; no credentials or state are exported."
  value = {
    AZURE_CLIENT_ID          = azurerm_user_assigned_identity.deployment.client_id
    AZURE_TENANT_ID          = var.tenant_id
    AZURE_SUBSCRIPTION_ID    = var.target_subscription_id
    AZURE_RESOURCE_GROUP     = azurerm_resource_group.target.name
    AZURE_OPERATOR_OBJECT_ID = var.operator_object_id
    TF_STATE_ACCOUNT         = split("/", var.state_storage_account_id)[8]
    TF_STATE_CONTAINER       = azapi_resource.state_container.name
    TF_STATE_KEY             = "checkout.tfstate"
    TF_STATE_ACCOUNT_ID      = var.state_storage_account_id
  }
}
