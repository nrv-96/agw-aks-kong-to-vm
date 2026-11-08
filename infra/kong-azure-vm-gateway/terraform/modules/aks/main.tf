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
variable "tags" {
  type    = map(string)
  default = {}
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

  api_server_access_profile {
    authorized_ip_ranges = length(var.authorized_ips) > 0 ? var.authorized_ips : []
  }

  identity {
    type = "SystemAssigned"
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
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "none"
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

resource "azurerm_role_assignment" "network" {
  scope                = var.vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.identity[0].principal_id
}

output "name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "key_vault_secrets_provider_identity_object_id" {
  value = azurerm_kubernetes_cluster.this.key_vault_secrets_provider[0].secret_identity[0].object_id
}
