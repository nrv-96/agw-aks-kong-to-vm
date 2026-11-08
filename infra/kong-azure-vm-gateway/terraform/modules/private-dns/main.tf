variable "resource_group_name" { type = string }
variable "zone_name" { type = string }
variable "record_name" { type = string }
variable "records" { type = list(string) }
variable "ttl" { type = number }
variable "vnet_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_private_dns_zone" "this" {
  name                = var.zone_name
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_a_record" "backend" {
  name                = var.record_name
  zone_name           = azurerm_private_dns_zone.this.name
  resource_group_name = var.resource_group_name
  ttl                 = var.ttl
  records             = var.records
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  name                  = "link-${replace(var.zone_name, ".", "-")}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

output "zone_id" {
  value = azurerm_private_dns_zone.this.id
}

output "zone_name" {
  value = azurerm_private_dns_zone.this.name
}
