variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "subnet_id" { type = string }
variable "nsg_id" { type = string }
variable "vm1_ip" { type = string }
variable "vm2_ip" { type = string }
variable "admin_username" { type = string }
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "vm_size" { type = string }
variable "image_publisher" { type = string }
variable "image_offer" { type = string }
variable "image_sku" { type = string }
variable "image_version" { type = string }
variable "os_disk_type" { type = string }
variable "os_disk_size_gb" { type = number }
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  vms = {
    vm1 = var.vm1_ip
    vm2 = var.vm2_ip
  }
}

resource "azurerm_network_interface" "this" {
  for_each            = local.vms
  name                = "nic-${each.key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value
  }
}

resource "azurerm_network_interface_security_group_association" "this" {
  for_each                  = local.vms
  network_interface_id      = azurerm_network_interface.this[each.key].id
  network_security_group_id = var.nsg_id
}

resource "azurerm_linux_virtual_machine" "this" {
  for_each                        = local.vms
  name                            = each.key
  computer_name                   = each.key
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.this[each.key].id]
  provision_vm_agent              = true
  patch_mode                      = "AutomaticByPlatform"
  custom_data                     = base64encode(file("${path.module}/cloud-init.yaml"))
  tags                            = var.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }
}

output "vm_ids" {
  value = { for name, vm in azurerm_linux_virtual_machine.this : name => vm.id }
}

output "vm_ips" {
  value = local.vms
}
