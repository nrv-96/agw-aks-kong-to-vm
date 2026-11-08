data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false
}

module "resource_group" {
  source = "./modules/resource-group"

  create   = var.create_resource_group
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

module "network" {
  source = "./modules/network"

  resource_group_name = local.rg_name
  location            = local.location
  vnet_name           = var.vnet_name
  vnet_cidr           = var.vnet_cidr
  aks_subnet_cidr     = var.aks_subnet_cidr
  vm_subnet_cidr      = var.vm_subnet_cidr
  pe_subnet_cidr      = var.pe_subnet_cidr
  agw_subnet_cidr     = var.agw_subnet_cidr
  enable_nat_gateway  = var.enable_nat_gateway
  tags                = local.tags
}

module "private_dns" {
  source = "./modules/private-dns"

  resource_group_name = local.rg_name
  zone_name           = var.internal_dns_zone
  record_name         = var.backend_dns_record
  records             = [var.vm1_ip, var.vm2_ip]
  ttl                 = var.dns_ttl
  vnet_id             = module.network.vnet_id
  tags                = local.tags
}

module "key_vault" {
  source = "./modules/key-vault"

  resource_group_name = local.rg_name
  location            = local.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  name                = local.key_vault_name
  allowed_ip_ranges   = var.key_vault_allowed_ip_ranges
  purge_protection    = var.key_vault_purge_protection
  tags                = local.tags
}

module "aks" {
  source = "./modules/aks"

  resource_group_name = local.rg_name
  location            = local.location
  name                = var.aks_name
  dns_prefix          = "pmp-${var.environment}-${random_string.suffix.result}"
  kubernetes_version  = var.kubernetes_version
  vnet_id             = module.network.vnet_id
  subnet_id           = module.network.aks_subnet_id

  pod_cidr        = var.pod_cidr
  service_cidr    = var.service_cidr
  dns_service_ip  = var.dns_service_ip
  node_vm_size    = var.node_vm_size
  node_min_count  = var.node_min_count
  node_max_count  = var.node_max_count
  authorized_ips  = var.aks_authorized_ip_ranges
  private_cluster = var.aks_private_cluster
  tags            = local.tags
}

module "identity" {
  source = "./modules/identity"

  resource_group_name = local.rg_name
  location            = local.location
  environment         = var.environment
  aks_oidc_issuer_url = module.aks.oidc_issuer_url
  tags                = local.tags
}

resource "random_password" "admin" {
  length           = 24
  special          = true
  min_special      = 2
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "local_sensitive_file" "admin_password" {
  content         = random_password.admin.result
  filename        = "${path.root}/vm-admin-password.txt"
  file_permission = "0600"
}

module "vm" {
  source = "./modules/vm"

  resource_group_name = local.rg_name
  location            = local.location
  subnet_id           = module.network.vm_subnet_id
  nsg_id              = module.network.vm_nsg_id
  vm1_ip              = var.vm1_ip
  vm2_ip              = var.vm2_ip
  admin_username      = var.admin_username
  admin_password      = random_password.admin.result
  vm_size             = var.vm_size
  image_publisher     = var.vm_image_publisher
  image_offer         = var.vm_image_offer
  image_sku           = var.vm_image_sku
  image_version       = var.vm_image_version
  os_disk_type        = var.os_disk_type
  os_disk_size_gb     = var.os_disk_size_gb
  tags                = local.tags
}

module "application_gateway" {
  source = "./modules/application-gateway"
  count  = var.enable_application_gateway ? 1 : 0

  resource_group_name   = local.rg_name
  location              = local.location
  name                  = var.agw_name
  public_ip_name        = var.agw_public_ip_name
  subnet_id             = module.network.agw_subnet_id
  capacity              = var.agw_capacity
  frontend_hostname     = local.frontend_fqdn
  kong_internal_lb_ip   = var.kong_internal_lb_ip
  identity_id           = module.identity.agw_identity_id
  certificate_secret_id = var.agw_certificate_secret_id
  root_ca_cert_path     = var.root_ca_cert_path
  tags                  = local.tags

  depends_on = [azurerm_role_assignment.agw_kv]
}

# --- data-plane RBAC ---------------------------------------------------------
resource "azurerm_role_assignment" "csi_kv" {
  scope                = module.key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.identity.workload_identity_principal_id
}

resource "azurerm_role_assignment" "agw_kv" {
  scope                = module.key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.identity.agw_identity_principal_id
}

resource "azurerm_role_assignment" "aks_addon_kv" {
  scope                = module.key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.aks.key_vault_secrets_provider_identity_object_id
}
