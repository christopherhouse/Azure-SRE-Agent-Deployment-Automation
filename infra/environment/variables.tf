variable "target_subscription_id" {
  type        = string
  description = "Selected target subscription, independent of the externally owned state account."
  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.target_subscription_id))
    error_message = "Supply the selected target subscription UUID."
  }
}

variable "tenant_id" {
  type        = string
  description = "Microsoft Entra tenant containing both subscriptions."
}

variable "use_oidc" {
  type        = bool
  default     = false
  description = "Use GitHub OIDC instead of interactive Azure CLI authentication."
}

variable "operator_object_id" {
  type        = string
  description = "Interactive operator object ID; grants agent administration only on this agent."
}

variable "fault_enabled" {
  type        = bool
  default     = false
  description = "Deliberately fail every fifth synthetic checkout; no real customer traffic."
}
