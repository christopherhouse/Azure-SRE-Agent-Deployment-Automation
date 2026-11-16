variable "target_subscription_id" {
  type        = string
  description = "Subscription selected in the operator's Azure CLI session."
  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.target_subscription_id))
    error_message = "Supply a subscription UUID."
  }
}

variable "tenant_id" {
  type        = string
  description = "Shared tenant of the target and externally owned state account."
}

variable "operator_object_id" {
  type        = string
  description = "Signed-in Entra user receiving container-scoped local state access."
}

variable "state_storage_account_id" {
  type        = string
  description = "Existing externally owned account, which may be in another subscription."
  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft.Storage/storageAccounts/[a-z0-9]{3,24}$", var.state_storage_account_id))
    error_message = "Supply the full Storage account ARM resource ID."
  }
}

variable "github_subject_prefix" {
  type        = string
  description = "GitHub-reported OIDC prefix, including immutable IDs when enabled."
  validation {
    condition     = can(regex("^repo:[^/:]+/[^/:]+$", var.github_subject_prefix))
    error_message = "Supply a repo:owner/repository prefix, optionally containing immutable @IDs."
  }
}

variable "monitoring_principal_id" {
  type        = string
  default     = null
  description = "Environment monitoring UAMI principal, supplied after the first operator-owned environment apply."
  validation {
    condition     = var.monitoring_principal_id == null ? true : can(regex("^[0-9a-fA-F-]{36}$", var.monitoring_principal_id))
    error_message = "Supply the environment monitoring principal UUID, not its client or resource ID."
  }
}
