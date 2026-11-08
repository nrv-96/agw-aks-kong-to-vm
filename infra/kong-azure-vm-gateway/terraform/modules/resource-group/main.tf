variable "create" {
  type    = bool
  default = true
}

variable "name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_resource_group" "this" {
  count    = var.create ? 1 : 0
  name     = var.name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "this" {
  count = var.create ? 0 : 1
  name  = var.name
}

output "name" {
  value = var.create ? azurerm_resource_group.this[0].name : data.azurerm_resource_group.this[0].name
}

output "location" {
  value = var.create ? azurerm_resource_group.this[0].location : data.azurerm_resource_group.this[0].location
}
