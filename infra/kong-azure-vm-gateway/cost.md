# Cost estimate — Kong Gateway on AKS (East US)

Inventory of **every resource the current Terraform creates** in
`infra/kong-azure-vm-gateway/terraform`, priced at **East US (`eastus`)** retail
rates in **USD**.

| | |
|---|---|
| Region | `eastus` (US East) for all regional resources |
| Currency | USD |
| Price basis | Pay-as-you-go retail (no EA/MCA discount, no reservations, no savings plan, no spot) |
| Prices retrieved | **2026-11-08** from the Azure Retail Prices API |
| Monthly multiplier | **730 hours** (Azure Pricing Calculator convention) |
| Terraform defaults | `enable_application_gateway = false`, `enable_nat_gateway = true`, 3 subnets, `node_min_count = 1`, `node_max_count = 2` |
| Live plan/apply | **Not run.** Counts come from the configuration, not deployed state |

> Managed disks are billed monthly; their hourly value below is `monthly ÷ 730`
> and is shown only so every row has an hourly figure.

---

## 1. Headline totals

| Scenario | Hourly | Monthly |
|---|---:|---:|
| **Terraform default** (AGW off), AKS Free tier as documented | $0.506325 | **$369.62** |
| Terraform default + AKS `FreeTierInfrastructureCost` meter (see §2.1) | $0.556325 | **$406.12** |
| Terraform default + Kong internal LB (created by Helm after apply) | $0.531325 | **$387.87** |
| Terraform default + AKS meter + Kong internal LB | $0.581325 | **$424.37** |
| Terraform default + Kong LB + Application Gateway (optional) | $0.744325 | **$543.36** |
| Terraform default + AKS meter + Kong LB + Application Gateway | $0.794325 | **$579.86** |

> **Current live deployment:** Bastion + Kong internal LB + Application Gateway,
> AKS at 1 node, documented free AKS control plane → **$543.36/month**
> ($0.744325/hour). With the AKS `FreeTierInfrastructureCost` meter →
> **$579.86/month** ($0.794325/hour). Fixed charges only; §5 usage is extra.

Traffic-dependent data charges are **not** in these totals; see §5.

---

## 2. Billable Terraform resources

All values are per unit. `Qty` is the number of identical units created by the
current `terraform.tfvars.json`.

| # | Terraform resource | SKU / meter | Region | Qty | Hourly (USD) | Monthly (USD) |
|---|---|---|---:|---:|---:|---:|
| 1 | `module.vm.azurerm_linux_virtual_machine.this["vm1"]` | `Standard_B2s`, Linux, BS series | East US | 1 | 0.041600 | 30.37 |
| 2 | `module.vm.azurerm_linux_virtual_machine.this["vm2"]` | `Standard_B2s`, Linux, BS series | East US | 1 | 0.041600 | 30.37 |
| 3 | `module.vm` OS disk for `vm1` | Standard HDD LRS, **S4 / 32 GiB** (30 GB request) | East US | 1 | 0.002104 | 1.54 |
| 4 | `module.vm` OS disk for `vm2` | Standard HDD LRS, **S4 / 32 GiB** (30 GB request) | East US | 1 | 0.002104 | 1.54 |
| 5 | `module.aks.azurerm_kubernetes_cluster.this` default node pool | `Standard_B4ms`, Linux, BS series | East US | 1 | 0.166000 | 121.18 |
| 6 | `module.aks` node OS disk | Premium SSD LRS, **P4 / 32 GiB** (`os_disk_size_gb = 30`) | East US | 1 | 0.007232 | 5.28 |
| 7 | `module.network.azurerm_nat_gateway.this[0]` | NAT Gateway, Standard | Global | 1 | 0.045000 | 32.85 |
| 8 | `module.network.azurerm_public_ip.nat[0]` | Standard IPv4 static public IP | East US | 1 | 0.005000 | 3.65 |
| 9 | `module.private_dns.azurerm_private_dns_zone.this` | Azure DNS private zone (first 25 zones) | Global | 1 | 0.000685 | 0.50 |
| 10 | `module.key_vault.azurerm_key_vault.this` | Key Vault **Standard** | East US | 1 | 0.000000 | 0.00 |
| 11 | `module.aks.azurerm_kubernetes_cluster.this` control plane | AKS **Free tier** (Base SKU) | East US | 1 | 0.000000 | 0.00 |
| 12 | `module.bastion.azurerm_public_ip.this[0]` | Standard IPv4 static public IP | East US | 1 | 0.005000 | 3.65 |
| 13 | `module.bastion.azurerm_bastion_host.this[0]` | Azure Bastion **Basic** (copy/paste on) | East US | 1 | 0.190000 | 138.70 |
| | **Subtotal — Terraform default** | | | | **0.506325** | **369.62** |

Notes on the billable rows:

- **VMs (#1–2)** — Ubuntu 24.04 LTS, Linux price. No Windows licence, no Azure
  Hybrid Benefit. `Standard_B2s` = 2 vCPU / 4 GiB burstable.
- **VM disks (#3–4)** — `os_disk_type = "Standard_LRS"` is **Standard HDD LRS**.
  Azure rounds the 30 GB request up to the 32 GiB **S4** tier ($1.536/month each).
  Standard SSD (E4) would be $2.40/month each; Premium SSD (P4) $5.2795/month each.
- **AKS node (#5)** — `Standard_B4ms` = 4 vCPU / 16 GiB burstable, 1 node
  (`node_min_count = 1`). Autoscale to 2 nodes adds **$126.46/month** (§4).
- **AKS node disk (#6)** — AKS managed OS disk defaults to **Premium SSD**
  (`P10/128G` tier for 1–7 vCPU per Microsoft docs). Because the Terraform pins
  `os_disk_size_gb = 30`, the billed tier is **P4 / 32 GiB**. If your subscription
  provisions Standard SSD instead, the row falls to $2.40/month.
- **NAT gateway (#7)** — `$0.045/hour` gateway + `$0.045/GB` data (§5). Attached
  to both `snet-aks` and `snet-vm`.
- **NAT public IP (#8)** — Standard static IPv4, `$0.005/hour`.
- **Private DNS (#9)** — `$0.50/zone/month` (first 25 zones). The A record is free
  and, per current Azure DNS pricing, there is **no separate VNet-link charge**.
  Queries are $0.40/million (§5).
- **Key Vault (#10)** — no base fee; only operations are billed
  ($0.03 per 10,000). See §5.
- **Bastion (#12–13)** — Basic SKU, `$0.19/hour`, copy/paste enabled, Standard
  static public IP. Used to reach the VMs, which have no public IPs. Data
  transfer out: first 5 GB/month free, then `$0.087/GB` (tiers down to
  `$0.05/GB` above 150 TB).
- **AKS control plane (#11)** — see §2.1.

### 2.1 AKS Free tier pricing discrepancy

Two official Microsoft sources currently disagree, so both are shown:

| Source | Meter | Hourly | Monthly |
|---|---|---:|---:|
| Azure pricing page + AKS pricing-tier docs | Free tier = "Free (only pay for underlying resources)" | $0.000000 | $0.00 |
| Azure Retail Prices API, `eastus`, effective **2026-10-01** | `FreeTierInfrastructureCost Uptime SLA` (SKU `FreeTierInfrastructureCost`) | $0.050000 | $36.50 |

What this means:

- The public pricing page (`azure.microsoft.com/pricing/details/kubernetes-service`)
  and `learn.microsoft.com/azure/aks/free-standard-pricing-tiers` still describe
  the Free tier as free cluster management.
- The Retail Prices API — the feed behind actual billing — publishes a
  `FreeTierInfrastructureCost` meter at **$0.05/hour** in every public region
  (and $0.0625/hour in US Gov), starting **2026-10-01**.
- The headline table therefore gives totals **with** and **without** this meter.
  For the full Terraform-default stack (including Bastion), treat
  **$406.12/month** as the conservative budget and **$369.62/month** as the
  documented-price result. Confirm on the first invoice or with the Azure
  calculator before committing a budget.

For reference, the alternatives are Standard tier (`$0.10/hour` = $73.00/month,
includes uptime SLA) and Automatic (`$0.16/hour` hosted component). Neither is
used by this Terraform (`sku_tier = "Free"`).

---

## 3. Free Terraform resources (verified $0.00)

Every remaining resource in the configuration is non-billable. Listed so the
inventory is complete.

| Module / scope | Resources | Qty | Hourly | Monthly |
|---|---|---:|---:|---:|
| `resource-group` | `azurerm_resource_group.this` | 1 | 0.000000 | 0.00 |
| `network` | `azurerm_virtual_network.this` | 1 | 0.000000 | 0.00 |
| `network` | `azurerm_subnet` (`snet-aks`, `snet-vm`, `snet-agw`, `AzureBastionSubnet`) | 4 | 0.000000 | 0.00 |
| `network` | `azurerm_network_security_group` (`nsg-aks`, `nsg-vm`, `nsg-agw`) | 3 | 0.000000 | 0.00 |
| `network` | `azurerm_network_security_rule` (all 16 rules) | 16 | 0.000000 | 0.00 |
| `network` | `azurerm_subnet_network_security_group_association` | 2 | 0.000000 | 0.00 |
| `network` | `azurerm_nat_gateway_public_ip_association` | 1 | 0.000000 | 0.00 |
| `network` | `azurerm_subnet_nat_gateway_association` (`snet-aks`, `snet-vm`) | 2 | 0.000000 | 0.00 |
| `vm` | `azurerm_network_interface` (`nic-vm1`, `nic-vm2`) | 2 | 0.000000 | 0.00 |
| `vm` | `azurerm_network_interface_security_group_association` | 2 | 0.000000 | 0.00 |
| `private-dns` | `azurerm_private_dns_a_record.backend` (`be` → both VM IPs) | 1 | 0.000000 | 0.00 |
| `private-dns` | `azurerm_private_dns_zone_virtual_network_link` | 1 | 0.000000 | 0.00 |
| `identity` | `azurerm_user_assigned_identity` (control plane, kubelet, Kong CSI, AGW) | 4 | 0.000000 | 0.00 |
| `aks` | `azurerm_role_assignment` (`Network Contributor` on VNet, `Managed Identity Operator` on kubelet UAMI) | 2 | 0.000000 | 0.00 |
| root | `azurerm_federated_identity_credential.csi` | 1 | 0.000000 | 0.00 |
| root | `azurerm_role_assignment` (`Key Vault Secrets User` × 2: CSI and AGW identities) | 2 | 0.000000 | 0.00 |
| root | `random_string.suffix`, `random_password.admin`, `local_sensitive_file.admin_password` | 3 | 0.000000 | 0.00 |
| root | `data.azurerm_client_config.current` | 1 | 0.000000 | 0.00 |

The AKS cluster also enables OIDC issuer and the Key Vault Secrets Provider
add-on; both are free. Virtual network, subnets, NSGs, UAMIs, role assignments
and federated credentials have no Azure charge.

---

## 4. Runtime and optional resources

These are **not created by Terraform** but are part of running the stack.

| Resource | SKU / meter | Region | Qty | Hourly | Monthly |
|---|---|---|---:|---:|---:|
| Kong internal LB (Kubernetes `Service` type `LoadBalancer`, internal annotation) | Standard LB, first 5 rules | Global | 1 | 0.025000 | 18.25 |
| **Application Gateway (only when `enable_application_gateway = true`)** | | | | | |
| `module.application_gateway.azurerm_application_gateway.this` — fixed | Standard_v2 fixed cost | East US | 1 | 0.200000 | 146.00 |
| same — capacity units | Standard_v2 capacity unit (1 CU assumed) | East US | 1 | 0.008000 | 5.84 |
| `module.application_gateway.azurerm_public_ip.this` | Standard IPv4 static public IP | East US | 1 | 0.005000 | 3.65 |
| **AGW subtotal** | | | | **0.213000** | **155.49** |
| **AKS scale-out (optional)** | | | | | |
| 2nd node in the autoscale range | `Standard_B4ms` + P4 OS disk | East US | +1 | 0.173232 | 126.46 |

Notes:

- The Kong proxy `Service` exposes 80 and 443 → 2 rules, which is inside the
  **first 5 rules** band. Standard LB bills a flat `$0.025/hour` for the first
  five load-balancing/outbound rules, so 1–5 rules cost the same $18.25/month.
  A 6th rule would add $0.01/hour ($7.30/month).
- Application Gateway `capacity = 1` is a manual-scale instance count. The
  estimate assumes the **minimum 1 capacity unit** ($0.008/hour). Real CU
  consumption scales with compute, persistent connections and throughput, so
  $155.49/month is a floor, not a ceiling.
- AGW is gated off in `terraform.tfvars.json`, so it contributes $0 to the
  Terraform-default totals. The AGW public IP is created only with the gateway.
- AGW outbound data is charged at standard bandwidth rates in addition to CU.

---

## 5. Usage-based charges (outside the fixed totals)

| Meter | Rate | Example |
|---|---:|---|
| NAT Gateway data processed | $0.045/GB | 100 GB → $4.50; 1 TB → $46.08 |
| Standard Load Balancer data processed | $0.005/GB | 1 TB → $5.12 |
| Internet egress, Microsoft global network | first 100 GB/month free, then $0.087/GB | 1 TB total → 924 GB × $0.087 = $80.39 |
| Internet egress, Internet routing preference | first 100 GB/month free, then $0.080/GB | 1 TB total → $73.92 |
| Private DNS queries | $0.40/million | 10 million → $4.00 |
| Key Vault Standard operations | $0.03 per 10,000 | 100,000 → $0.30 |
| Key Vault certificate renewal request | $3.00 each | $0 — this project uploads its own PKI certificate as a secret |
| Application Gateway capacity units above 1 | $0.008/CU-hour | 2 CU → +$5.84/month |
| Azure Bastion Basic data transfer out | first 5 GB/month free, then $0.087/GB (tiers down to $0.05/GB above 150 TB) | 10 GB → $0.44 |

Traffic in this design flows `Internet → AGW (optional) → Kong internal LB → VMs`.
Inbound data is free; the egress and data-processed meters above are the ones to
watch. For a small internal deployment (well under 100 GB/month egress) the
usage add-on is typically a few dollars per month.

---

## 6. Assumptions

1. **Region** is `eastus`, taken from `terraform.tfvars.json`. NAT Gateway,
   Standard LB and Azure DNS meters are non-regional (same price in East US).
2. **Linux** prices for both VM SKUs (Ubuntu 24.04 LTS). No Windows licence, no
   Azure Hybrid Benefit, no reserved instances, no savings plan, no spot.
3. **1 node** for AKS (`node_min_count = 1`). Autoscale is capped at 2; the
   second node is priced separately in §4.
4. **AKS OS disk** is Premium SSD **P4 / 32 GiB**. Microsoft documents Premium
   SSD as the default managed OS disk tier; `os_disk_size_gb = 30` maps to the
   32 GiB tier.
5. **VM OS disks** are Standard HDD LRS **S4 / 32 GiB**, matching
   `os_disk_type = "Standard_LRS"` and `os_disk_size_gb = 30`.
6. **730 hours/month**, the same convention as the Azure Pricing Calculator.
7. **Key Vault** is Standard SKU with public access, RBAC, purge protection and
   90-day soft delete. No base fee; only operation counts are billed.
8. **Private DNS** has one zone, one A record and one VNet link. Zone charge
   $0.50/month; record sets and VNet links are free at current pricing.
9. **No discounts or credits** are applied. Prices exclude tax.
10. **No live `terraform plan/apply`** was run. Resource counts are read from the
    configuration, so a plan could still reveal provider-default resources.
11. **Bastion** is Basic SKU with a Standard static public IP,
    `copy_paste_enabled = true`, and a dedicated `AzureBastionSubnet`
    (`10.20.3.0/24`, /24 ≥ the /26 minimum).

---

## 7. Not included in this estimate

By project scope, the following are intentionally absent and therefore $0 here:

- Observability: Log Analytics workspace, Managed Prometheus, Managed Grafana,
  Container Insights.
- Backup: Azure Backup / Recovery Services vault.
- WAF: Application Gateway WAF_v2 (would be $0.36/hour fixed + $0.0144/CU-hour)
  and any WAF policy.
- Private endpoints / Private Link, and the deferred private-endpoint subnet.
- Microsoft Defender for Cloud, DDoS Protection Standard.
- Azure Container Registry (images come from public registries).
- Azure Bastion, VPN Gateway, ExpressRoute.
- Public DNS zone or domain registration for `internal.example.com`.
- TLS certificate purchase (the project uses a self-signed root CA and
  script-issued certificates).
- Support plan.
- Terraform state storage (state is local; no Storage Account is created).
- Data egress beyond the fixed meters in §5.

---

## 8. Sources

Prices were read from the **Azure Retail Prices API** on 2026-11-08 and
cross-checked against the official pricing pages.

| Item | Source |
|---|---|
| Retail prices (all meters) | `https://prices.azure.com/api/retail/prices` — `armRegionName eq 'eastus'`, `priceType eq 'Consumption'`, USD |
| AKS tiers and Free-tier definition | https://azure.microsoft.com/en-us/pricing/details/kubernetes-service/ · https://learn.microsoft.com/en-us/azure/aks/free-standard-pricing-tiers |
| AKS managed OS disk default tier | https://learn.microsoft.com/en-us/azure/aks/concepts-storage |
| VM SKUs | https://azure.microsoft.com/en-us/pricing/details/virtual-machines/linux/ |
| Managed disks (S4, P4) | https://azure.microsoft.com/en-us/pricing/details/managed-disks/ |
| NAT Gateway | https://azure.microsoft.com/en-us/pricing/details/azure-nat-gateway/ |
| Public IP addresses | https://azure.microsoft.com/en-us/pricing/details/ip-addresses/ |
| Azure DNS private zones | https://azure.microsoft.com/en-us/pricing/details/dns/ |
| Key Vault | https://azure.microsoft.com/en-us/pricing/details/key-vault/ |
| Standard Load Balancer | https://azure.microsoft.com/en-us/pricing/details/load-balancer/ |
| Application Gateway v2 | https://azure.microsoft.com/en-us/pricing/details/application-gateway/ |
| Bandwidth / egress | https://azure.microsoft.com/en-us/pricing/details/bandwidth/ |
| Calculator | https://azure.microsoft.com/en-us/pricing/calculator/ |

### Reproducing a single price

```bash
# Standard_B4ms, Linux, East US
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=serviceName eq 'Virtual Machines' and armRegionName eq 'eastus' and armSkuName eq 'Standard_B4ms' and priceType eq 'Consumption'"

# Premium SSD P4
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=serviceName eq 'Storage' and armRegionName eq 'eastus' and priceType eq 'Consumption' and meterName eq 'P4 LRS Disk'"

# AKS Free-tier infrastructure meter
curl -sG 'https://prices.azure.com/api/retail/prices' \
  --data-urlencode "\$filter=serviceName eq 'Azure Kubernetes Service' and armRegionName eq 'eastus' and skuName eq 'FreeTierInfrastructureCost'"
```

---

## 9. Validation notes

- `terraform fmt -check -recursive` — pass.
- `terraform validate` — pass.
- Resource inventory taken from a static read of all eight modules plus the
  generated `terraform.tfvars.json`; `terraform graph` confirms the identity,
  role-assignment and federated-credential dependencies.
- Arithmetic: every monthly value is `hourly × 730`; disk rows are
  `monthly price` with `hourly = monthly ÷ 730`. Totals were recomputed from the
  unrounded unit prices.
- Cross-check against the Azure Pricing Calculator: select **East US**, add
  `B2s` ×2, `B4ms` ×1, `S4` ×2, `P4` ×1, NAT Gateway ×1, Standard static IP ×1,
  Private DNS zone ×1, Standard LB with 2 rules, and optionally
  Application Gateway Standard_v2 with 1 CU and 1 public IP.
- No Azure plan/apply was executed, so no deployed resource IDs or actual billed
  amounts were available to compare.

---

## 10. Grand total — every resource

### 10.1 Complete resource ledger

Every resource in the project appears exactly once: the 13 Terraform line items
(11 with a fixed charge, Key Vault and the AKS control plane at $0 base), the
runtime Kong load balancer, the optional AGW and second AKS node, the AKS
infrastructure meter, and the zero-cost resources.

| # | Resource | SKU / meter | Qty | Hourly (USD) | Monthly (USD) | Type |
|---|---|---|---:|---:|---:|---|
| 1 | VM `vm1` | `Standard_B2s`, Linux | 1 | 0.041600 | 30.37 | Terraform |
| 2 | VM `vm2` | `Standard_B2s`, Linux | 1 | 0.041600 | 30.37 | Terraform |
| 3 | VM `vm1` OS disk | Standard HDD LRS **S4 / 32 GiB** | 1 | 0.002104 | 1.54 | Terraform |
| 4 | VM `vm2` OS disk | Standard HDD LRS **S4 / 32 GiB** | 1 | 0.002104 | 1.54 | Terraform |
| 5 | AKS node 1 | `Standard_B4ms`, Linux | 1 | 0.166000 | 121.18 | Terraform |
| 6 | AKS node 1 OS disk | Premium SSD LRS **P4 / 32 GiB** | 1 | 0.007232 | 5.28 | Terraform |
| 7 | NAT gateway | NAT Gateway Standard | 1 | 0.045000 | 32.85 | Terraform |
| 8 | NAT public IP | Standard static IPv4 | 1 | 0.005000 | 3.65 | Terraform |
| 9 | Private DNS zone | Azure DNS private zone | 1 | 0.000685 | 0.50 | Terraform |
| 10 | Key Vault | Standard (operations only) | 1 | 0.000000 | 0.00 | Terraform |
| 11 | AKS control plane | Free tier (documented) | 1 | 0.000000 | 0.00 | Terraform |
| 12 | Bastion public IP | Standard static IPv4 | 1 | 0.005000 | 3.65 | Terraform |
| 13 | Azure Bastion | Basic, copy/paste on | 1 | 0.190000 | 138.70 | Terraform |
| | **Terraform default subtotal** | | | **0.506325** | **369.62** | |
| 14 | Kong internal LB | Standard LB, 2 rules (first 5) | 1 | 0.025000 | 18.25 | Runtime |
| 15 | AKS node 2 (autoscale) | `Standard_B4ms`, Linux | 1 | 0.166000 | 121.18 | Optional |
| 16 | AKS node 2 OS disk | Premium SSD LRS **P4 / 32 GiB** | 1 | 0.007232 | 5.28 | Optional |
| 17 | Application Gateway fixed | Standard_v2 | 1 | 0.200000 | 146.00 | Optional |
| 18 | Application Gateway CU | Standard_v2, 1 CU | 1 | 0.008000 | 5.84 | Optional |
| 19 | AGW public IP | Standard static IPv4 | 1 | 0.005000 | 3.65 | Optional |
| 20 | AKS `FreeTierInfrastructureCost` | Retail API meter | 1 | 0.050000 | 36.50 | Meter variant |
| | **Default + runtime Kong LB** | | | **0.531325** | **387.87** | |
| | **Default + Kong LB + AGW** | | | **0.744325** | **543.36** | |
| | **Default + Kong LB + AGW + 2 nodes** | | | **0.917558** | **669.82** | |
| | **ALL RESOURCES + AKS meter (2 nodes, AGW on)** | | | **0.967558** | **706.32** | |

Zero-cost resources (VNet, 4 subnets, 3 NSGs, 16 NSG rules, 2 NSG associations,
2 NICs, 2 NIC-associations, DNS A record, DNS VNet link, 4 UAMIs, 5 role
assignments, federated credential, OIDC issuer, Key Vault CSI provider, random
password/string, local state file) add **$0.000000/hour** and **$0.00/month**.

### 10.2 Final total by scenario

| Configuration | Hourly | Monthly |
|---|---:|---:|
| Terraform default only (1 node, AGW off, AKS documented free) | $0.506325 | **$369.62** |
| Default + runtime Kong LB | $0.531325 | **$387.87** |
| Default + runtime Kong LB + AKS meter | $0.581325 | **$424.37** |
| Default + runtime Kong LB + AGW | $0.744325 | **$543.36** |
| Default + runtime Kong LB + AGW + 2nd node | $0.917558 | **$669.82** |
| **GRAND TOTAL — all resources, 2 nodes, AGW on, AKS meter** | **$0.967558** | **$706.32** |

> **Grand total: $706.32/month ($0.967558/hour) with every resource included.**
> This assumes the optional Application Gateway is enabled
> (`enable_application_gateway = true`), AKS has scaled to its maximum of 2 nodes,
> and the `FreeTierInfrastructureCost` meter is billed. With the documented free
> AKS control plane, the same all-resource configuration is **$669.82/month**.
>
> These are fixed charges. Traffic-dependent meters in §5 (NAT data, LB data,
> internet egress, private DNS queries, Key Vault operations, AGW CUs above 1)
> are additional and vary with usage.

### 10.3 Does the grand total include every VM and every resource?

**Yes.** The $706.32/month row includes **all 4 VMs** (2 application VMs + 2 AKS
nodes), all 4 OS disks, and every other resource with a charge.

| Group | Included resources | Qty | Hourly (USD) | Monthly (USD) |
|---|---|---:|---:|---:|
| Application VMs | `vm1` + `vm2` — `Standard_B2s`, Linux | 2 | 0.083200 | 60.74 |
| AKS nodes | node 1 + node 2 — `Standard_B4ms`, Linux | 2 | 0.332000 | 242.36 |
| AKS control plane | `FreeTierInfrastructureCost` meter | 1 | 0.050000 | 36.50 |
| VM OS disks | 2 × Standard HDD LRS **S4 / 32 GiB** | 2 | 0.004208 | 3.07 |
| AKS OS disks | 2 × Premium SSD LRS **P4 / 32 GiB** | 2 | 0.014464 | 10.56 |
| NAT gateway | gateway + Standard static public IP | 2 | 0.050000 | 36.50 |
| Private DNS | zone (`internal.example.com`); record + VNet link free | 1 | 0.000685 | 0.50 |
| Kong internal LB | Standard LB, 2 rules (first 5) | 1 | 0.025000 | 18.25 |
| Application Gateway | Standard_v2 fixed + 1 CU + public IP | 3 | 0.213000 | 155.49 |
| Azure Bastion | Basic gateway + Standard static public IP | 2 | 0.195000 | 142.35 |
| Key Vault | Standard, operations only | 1 | 0.000000 | 0.00 |
| All zero-cost resources | VNet, 4 subnets, 3 NSGs, 16 rules, NICs, 4 UAMIs, 5 role assignments, federated credential, OIDC/CSI add-ons | — | 0.000000 | 0.00 |
| **GRAND TOTAL** | | | **0.967558** | **706.32** |

Inclusion checklist:

- [x] `vm1` — `Standard_B2s` — $30.37/mo
- [x] `vm2` — `Standard_B2s` — $30.37/mo
- [x] AKS node 1 — `Standard_B4ms` — $121.18/mo
- [x] AKS node 2 (autoscale maximum) — `Standard_B4ms` — $121.18/mo
- [x] 2 × S4 VM OS disks — $3.07/mo total
- [x] 2 × P4 AKS OS disks — $10.56/mo total
- [x] NAT gateway + public IP — $36.50/mo
- [x] Private DNS zone — $0.50/mo
- [x] Kong internal LB — $18.25/mo
- [x] Application Gateway + 1 CU + public IP — $155.49/mo
- [x] Azure Bastion Basic + Standard public IP — $142.35/mo
- [x] AKS control plane meter — $36.50/mo
- [x] Every zero-cost resource — $0.00/mo

If Application Gateway is left disabled and AKS stays at its default 1 node, the
same "all resources" total is **$369.62/month** ($0.506325/hour) without the AKS
meter, or **$406.12/month** ($0.556325/hour) with it — see §10.2.

