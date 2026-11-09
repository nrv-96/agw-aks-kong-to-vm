output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "resource_group_name" {
  value = local.rg_name
}

output "location" {
  value = local.location
}

output "vnet_id" {
  value = module.network.vnet_id
}

output "aks_name" {
  value = module.aks.name
}

output "aks_oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

output "workload_identity_client_id" {
  value = module.identity.workload_identity_client_id
}

output "key_vault_name" {
  value = module.key_vault.name
}

output "key_vault_uri" {
  value = module.key_vault.uri
}

output "vm1_ip" {
  value = var.vm1_ip
}

output "vm2_ip" {
  value = var.vm2_ip
}

output "kong_internal_lb_ip" {
  value = var.kong_internal_lb_ip
}

output "frontend_hostname" {
  value = local.frontend_fqdn
}

output "backend_hostname" {
  value = local.backend_fqdn
}

output "agw_public_ip" {
  value = try(module.application_gateway[0].public_ip, "")
}

output "admin_password_file" {
  value = local_sensitive_file.admin_password.filename
}

output "bastion_name" {
  value = try(module.bastion[0].name, "")
}

output "bastion_public_ip" {
  value = try(module.bastion[0].public_ip, "")
}
