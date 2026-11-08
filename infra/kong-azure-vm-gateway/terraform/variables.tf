variable "subscription_id" {
  description = "Azure subscription used for AKS, VMs, Key Vault, DNS and AGW."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that Terraform creates or reuses for all project resources."
  type        = string
  default     = "rg-pairs-monitor-dev"
}

variable "create_resource_group" {
  description = "Create the resource group (true) or use an existing one (false)."
  type        = bool
  default     = true
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Environment name used for naming."
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Resource tags. Empty by request."
  type        = map(string)
  default     = {}
}

# --- network -----------------------------------------------------------------
variable "vnet_name" {
  type    = string
  default = "vnet-pairs-monitor-dev"
}

variable "vnet_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "aks_subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "vm_subnet_cidr" {
  type    = string
  default = "10.20.2.0/24"
}

variable "agw_subnet_cidr" {
  type    = string
  default = "10.20.4.0/24"
}

variable "pod_cidr" {
  description = "AKS CNI Overlay pod CIDR; must not overlap the VNet."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  type    = string
  default = "10.96.0.0/16"
}

variable "dns_service_ip" {
  type    = string
  default = "10.96.0.10"
}

variable "enable_nat_gateway" {
  description = "Create a NAT Gateway and associate it with the AKS and VM subnets."
  type        = bool
  default     = true
}

# --- DNS / hostnames ---------------------------------------------------------
variable "frontend_hostname" {
  type    = string
  default = "fe.internal.example.com"
}

variable "backend_hostname" {
  type    = string
  default = "be.internal.example.com"
}

variable "internal_dns_zone" {
  type    = string
  default = "internal.example.com"
}

variable "backend_dns_record" {
  type    = string
  default = "be"
}

variable "dns_ttl" {
  type    = number
  default = 300
}

variable "kong_internal_lb_ip" {
  description = "Static internal LoadBalancer IP for Kong inside the AKS subnet."
  type        = string
  default     = "10.20.1.250"
}

# --- VMs ---------------------------------------------------------------------
variable "vm1_ip" {
  type    = string
  default = "10.20.2.51"
}

variable "vm2_ip" {
  type    = string
  default = "10.20.2.52"
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "vm_size" {
  type    = string
  default = "Standard_B2s"
}

variable "vm_image_publisher" {
  type    = string
  default = "Canonical"
}

variable "vm_image_offer" {
  type    = string
  default = "ubuntu-24_04-lts"
}

variable "vm_image_sku" {
  type    = string
  default = "server-gen2"
}

variable "vm_image_version" {
  type    = string
  default = "latest"
}

variable "os_disk_type" {
  type    = string
  default = "Standard_LRS"
}

variable "os_disk_size_gb" {
  type    = number
  default = 30
}

# --- AKS ---------------------------------------------------------------------
variable "aks_name" {
  type    = string
  default = "aks-pairs-monitor-dev"
}

variable "kubernetes_version" {
  description = "Must be supported by KIC 3.5.14."
  type        = string
  default     = "1.33"
}

variable "node_vm_size" {
  type    = string
  default = "Standard_B4ms"
}

variable "node_min_count" {
  type    = number
  default = 1
}

variable "node_max_count" {
  type    = number
  default = 2
}

variable "aks_authorized_ip_ranges" {
  description = "Public IP ranges allowed to reach the AKS API. Empty = unrestricted."
  type        = list(string)
  default     = []
}

variable "aks_private_cluster" {
  type    = bool
  default = false
}

# --- Key Vault ---------------------------------------------------------------
variable "key_vault_name" {
  description = "Globally unique Key Vault name. Empty = generated."
  type        = string
  default     = ""
}

variable "key_vault_allowed_ip_ranges" {
  description = "Optional public IP allowlist for Key Vault. Empty = allow all public."
  type        = list(string)
  default     = []
}

variable "key_vault_purge_protection" {
  type    = bool
  default = true
}

# --- Application Gateway -----------------------------------------------------
variable "enable_application_gateway" {
  description = "Enable after the AGW frontend certificate exists in Key Vault."
  type        = bool
  default     = false
}

variable "agw_name" {
  type    = string
  default = "agw-pairs-monitor-dev"
}

variable "agw_public_ip_name" {
  type    = string
  default = "pip-agw-pairs-monitor-dev"
}

variable "agw_capacity" {
  type    = number
  default = 1
}

variable "agw_certificate_secret_id" {
  description = "Versioned Key Vault certificate secret ID for the AGW frontend."
  type        = string
  default     = ""
}

variable "root_ca_cert_path" {
  description = "Path to the public root CA PEM used as AGW trusted root."
  type        = string
  default     = "../pki/root-ca.crt"
}
