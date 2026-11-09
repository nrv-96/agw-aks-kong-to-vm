variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "name" { type = string }
variable "public_ip_name" { type = string }
variable "subnet_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_public_ip" "this" {
  name                = var.public_ip_name
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Basic"
  copy_paste_enabled  = true
  tags                = var.tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = var.subnet_id
    public_ip_address_id = azurerm_public_ip.this.id
  }
}

output "id" {
  value = azurerm_bastion_host.this.id
}

output "name" {
  value = azurerm_bastion_host.this.name
}

output "public_ip" {
  value = azurerm_public_ip.this.ip_address
}
