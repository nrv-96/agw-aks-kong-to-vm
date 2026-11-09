variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "name" { type = string }
variable "dns_prefix" { type = string }
variable "kubernetes_version" { type = string }
variable "vnet_id" { type = string }
variable "subnet_id" { type = string }
variable "pod_cidr" { type = string }
variable "service_cidr" { type = string }
variable "dns_service_ip" { type = string }
variable "node_vm_size" { type = string }
variable "node_min_count" { type = number }
variable "node_max_count" { type = number }
variable "authorized_ips" {
  type    = list(string)
  default = []
}
variable "private_cluster" { type = bool }
variable "control_plane_identity_id" { type = string }
variable "control_plane_identity_principal_id" { type = string }
variable "kubelet_identity_id" { type = string }
variable "kubelet_identity_client_id" { type = string }
variable "kubelet_identity_principal_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_role_assignment" "control_plane_network" {
  scope                = var.vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = var.control_plane_identity_principal_id
}

resource "azurerm_role_assignment" "control_plane_kubelet_operator" {
  scope                = var.kubelet_identity_id
  role_definition_name = "Managed Identity Operator"
  principal_id         = var.control_plane_identity_principal_id
}

resource "azurerm_kubernetes_cluster" "this" {
  name                              = var.name
  location                          = var.location
  resource_group_name               = var.resource_group_name
  dns_prefix                        = var.dns_prefix
  kubernetes_version                = var.kubernetes_version
  sku_tier                          = "Free"
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  private_cluster_enabled           = var.private_cluster
  role_based_access_control_enabled = true
  tags                              = var.tags

  depends_on = [
    azurerm_role_assignment.control_plane_network,
    azurerm_role_assignment.control_plane_kubelet_operator,
  ]

  api_server_access_profile {
    authorized_ip_ranges = length(var.authorized_ips) > 0 ? var.authorized_ips : []
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.control_plane_identity_id]
  }

  kubelet_identity {
    client_id                 = var.kubelet_identity_client_id
    object_id                 = var.kubelet_identity_principal_id
    user_assigned_identity_id = var.kubelet_identity_id
  }

  default_node_pool {
    name                 = "system"
    node_count           = var.node_min_count
    vm_size              = var.node_vm_size
    vnet_subnet_id       = var.subnet_id
    auto_scaling_enabled = true
    min_count            = var.node_min_count
    max_count            = var.node_max_count
    os_disk_type         = "Managed"
    os_disk_size_gb      = 30
    type                 = "VirtualMachineScaleSets"

    # Pin the API defaults so the provider does not plan to remove them.
    upgrade_settings {
      drain_timeout_in_minutes      = 0
      max_surge                     = "10%"
      node_soak_duration_in_minutes = 0
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "azure"
    outbound_type       = "userAssignedNATGateway"
    load_balancer_sku   = "standard"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }
}

output "name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.this.oidc_issuer_url
}
