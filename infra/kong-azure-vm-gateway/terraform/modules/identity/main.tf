variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "environment" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_user_assigned_identity" "aks_control_plane" {
  name                = "id-aks-control-plane-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "aks_kubelet" {
  name                = "id-aks-kubelet-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "csi" {
  name                = "id-kong-csi-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "agw" {
  name                = "id-agw-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

output "control_plane_identity_id" {
  value = azurerm_user_assigned_identity.aks_control_plane.id
}

output "control_plane_identity_client_id" {
  value = azurerm_user_assigned_identity.aks_control_plane.client_id
}

output "control_plane_identity_principal_id" {
  value = azurerm_user_assigned_identity.aks_control_plane.principal_id
}

output "kubelet_identity_id" {
  value = azurerm_user_assigned_identity.aks_kubelet.id
}

output "kubelet_identity_client_id" {
  value = azurerm_user_assigned_identity.aks_kubelet.client_id
}

output "kubelet_identity_principal_id" {
  value = azurerm_user_assigned_identity.aks_kubelet.principal_id
}

output "workload_identity_id" {
  value = azurerm_user_assigned_identity.csi.id
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
