variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "name" { type = string }
variable "public_ip_name" { type = string }
variable "subnet_id" { type = string }
variable "capacity" { type = number }
variable "frontend_hostname" { type = string }
variable "kong_internal_lb_ip" { type = string }
variable "identity_id" { type = string }
variable "certificate_secret_id" { type = string }
variable "root_ca_cert_path" { type = string }
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

resource "azurerm_application_gateway" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = var.capacity
  }

  zones = []

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity_id]
  }

  gateway_ip_configuration {
    name      = "gwip"
    subnet_id = var.subnet_id
  }

  frontend_ip_configuration {
    name                 = "feip"
    public_ip_address_id = azurerm_public_ip.this.id
  }

  frontend_port {
    name = "http"
    port = 80
  }

  frontend_port {
    name = "https"
    port = 443
  }

  ssl_certificate {
    name                = "agw-frontend"
    key_vault_secret_id = var.certificate_secret_id
  }

  trusted_root_certificate {
    name = "pairs-monitor-root-ca"
    data = base64encode(file("${path.root}/${var.root_ca_cert_path}"))
  }

  backend_address_pool {
    name         = "kong"
    ip_addresses = [var.kong_internal_lb_ip]
  }

  probe {
    name                                      = "kong-health"
    protocol                                  = "Https"
    path                                      = "/health"
    host                                      = var.frontend_hostname
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = false
    minimum_servers                           = 0
  }

  backend_http_settings {
    name                                = "kong-https"
    protocol                            = "Https"
    port                                = 443
    request_timeout                     = 60
    cookie_based_affinity               = "Disabled"
    host_name                           = var.frontend_hostname
    pick_host_name_from_backend_address = false
    trusted_root_certificate_names      = ["pairs-monitor-root-ca"]
    probe_name                          = "kong-health"
  }

  http_listener {
    name                           = "https"
    frontend_ip_configuration_name = "feip"
    frontend_port_name             = "https"
    protocol                       = "Https"
    ssl_certificate_name           = "agw-frontend"
  }

  http_listener {
    name                           = "http"
    frontend_ip_configuration_name = "feip"
    frontend_port_name             = "http"
    protocol                       = "Http"
  }

  redirect_configuration {
    name                 = "http-to-https"
    redirect_type        = "Permanent"
    target_listener_name = "https"
    include_path         = true
    include_query_string = true
  }

  request_routing_rule {
    name                       = "https-rule"
    rule_type                  = "Basic"
    http_listener_name         = "https"
    backend_address_pool_name  = "kong"
    backend_http_settings_name = "kong-https"
    priority                   = 100
  }

  request_routing_rule {
    name                        = "http-redirect"
    rule_type                   = "Basic"
    http_listener_name          = "http"
    redirect_configuration_name = "http-to-https"
    priority                    = 110
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }
}

output "public_ip" {
  value = azurerm_public_ip.this.ip_address
}

output "id" {
  value = azurerm_application_gateway.this.id
}
