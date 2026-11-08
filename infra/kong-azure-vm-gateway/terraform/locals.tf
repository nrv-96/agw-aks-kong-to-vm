locals {
  name_prefix = "pairs-monitor-${var.environment}"

  rg_name  = module.resource_group.name
  location = module.resource_group.location

  key_vault_name = var.key_vault_name != "" ? var.key_vault_name : substr(
    "kv-pm-${var.environment}-${random_string.suffix.result}", 0, 24
  )

  backend_fqdn  = "${var.backend_dns_record}.${var.internal_dns_zone}"
  frontend_fqdn = var.frontend_hostname

  tags = var.tags
}
