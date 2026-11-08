variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "environment" { type = string }
variable "aks_oidc_issuer_url" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_user_assigned_identity" "csi" {
  name                = "id-kong-csi-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "csi" {
  name                = "fic-kong-csi-${var.environment}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.csi.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.aks_oidc_issuer_url
  subject             = "system:serviceaccount:kong:kong-gateway"
}

resource "azurerm_user_assigned_identity" "agw" {
  name                = "id-agw-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

output "workload_identity_client_id" {
  value = azurerm_user_assigned_identity.csi.client_id
}

output "workload_identity_principal_id" {
  value = azurerm_user_assigned_identity.csi.principal_id
}

output "agw_identity_id" {
  value = azurerm_user_assigned_identity.agw.id
}

output "agw_identity_principal_id" {
  value = azurerm_user_assigned_identity.agw.principal_id
}
