terraform {
  required_version = ">= 1.15.2, < 2.0.0"

  backend "azurerm" {
    use_azuread_auth     = true
    lookup_blob_endpoint = false
  }
}
