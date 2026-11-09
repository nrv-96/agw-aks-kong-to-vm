# AGENT_HANDOFF.md — start here

> **If you are an AI agent picking this up:** read this file first, then
> `KONG.md`, `CERTIFICATES.md`, `RUNBOOK.md`, and `cost.md`.
>
> The stack is **live and validated** as of 2026-11-09. Do not rotate
> certificates, recreate the root CA, or change Terraform feature flags without
> reading `CERTIFICATES.md` first.

## 1. Live environment

| Item | Value |
|---|---|
| Subscription | `6d064e64-7038-4a50-aa19-899b347bed41` (**PAG-PLomesh**) |
| Tenant | `3224f33f-f4c3-46a3-b624-7b0b452f9a98` |
| Resource group | `rg-pairs-monitor-dev` |
| Region | `eastus` |
| Terraform state | **local** `terraform/terraform.tfstate` |
| AKS | `aks-pairs-monitor-dev` — Kubernetes **1.34.12**, Free tier, 1 × `Standard_B4ms` (autoscale 1–2) |
| AKS networking | CNI Overlay, `network_policy = "azure"`, OIDC + workload identity, Key Vault CSI add-on |
| VMs | `vm1` `10.20.2.51`, `vm2` `10.20.2.52` — `Standard_B2s`, Ubuntu 24.04, Java 21.0.12 |
| VM app | `hello-app` systemd service, HTTPS `:8100`, health `/health` |
| Bastion | `bas-pairs-monitor-dev` — Basic, copy/paste, public IP `20.25.20.81` |
| Key Vault | `kv-pm-dev-ig8r` |
| Private DNS | `internal.example.com`, A record `be` → both VM IPs, TTL 300 |
| Kong | Helm release `kong`, namespace `kong`, chart `0.24.0`, gateway `kong:3.9.4`, KIC `3.5.14` |
| Kong internal LB | `10.20.1.250` (Azure Standard LB, private) |
| Application Gateway | `agw-pairs-monitor-dev`, Standard_v2, public IP **`20.119.58.31`** |
| Public hostname | `fe.internal.example.com` |
| Backend hostname | `be.internal.example.com` |
| Feature flags | `enable_bastion = true`, `enable_application_gateway = true`, `enable_nat_gateway = true` |
| Last Terraform plan | **No changes** (`-detailed-exitcode` = 0) |

### Current cost

| Live fixed charges | Monthly |
|---|---:|
| Bastion + Kong LB + AGW, 1 AKS node, documented free AKS control plane | **$543.36** |
| Same + AKS `FreeTierInfrastructureCost` meter | **$579.86** |

Usage meters (NAT/LB/AGW data, egress, DNS queries, Key Vault operations) are
extra. See `cost.md`.

---

## 2. What is done

- [x] Terraform foundation: RG, VNet, 4 subnets, NSGs, NAT, private DNS, Key Vault, identities, AKS, VMs, Bastion.
- [x] AKS workload identity + Key Vault CSI + federated credential.
- [x] Root CA + Key Vault CA secrets.
- [x] VM private keys/CSRs on the VMs; certificates signed on the laptop.
- [x] Java `hello-app` installed, PKCS#12 keystore, systemd, HTTPS health.
- [x] Kong Helm release + Gateway API CRDs + KIC.
- [x] CA sync via CSI (`pairs-monitor-ca`).
- [x] Gateway/HTTPRoute/Service/EndpointSlice/BackendTLSPolicy/KongUpstreamPolicy.
- [x] Kong → VM TLS verification (`be.internal.example.com`, depth 1).
- [x] Application Gateway + public TLS (`agw-frontend`) + HTTP→HTTPS redirect.
- [x] Runtime validation (`validate-kong.sh`) and end-to-end curl.

## 3. What is pending

- Entra ID SSO (not implemented; Kong OSS has no official OIDC plugin in this stack).
- Automatic CA/certificate renewal.
- CI pipeline.
- Observability, backup and WAF are intentionally excluded by project scope.
- Remote Terraform state (currently local).

---

## 4. Start-here checklist for an AI agent

### 4.1 Check context

```powershell
az account show --query "{subscription:id, tenant:tenantId, user:user.name}" -o table
kubectl config current-context
kubectl get nodes -o wide
```

Expected subscription: `6d064e64-7038-4a50-aa19-899b347bed41`.

If `kubectl` is not configured:

```powershell
az aks get-credentials -g rg-pairs-monitor-dev -n aks-pairs-monitor-dev --overwrite-existing
```

WSL kubectl/helm live in `~/bin`:

```bash
export PATH="$HOME/bin:$PATH"
```

### 4.2 Check no drift

```powershell
cd D:\gitclone\appjava\infra\kong-azure-vm-gateway\terraform
terraform plan -detailed-exitcode
```

Expect exit **0** and `No changes`.

### 4.3 Check the app and Kong

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
export PATH="$HOME/bin:$PATH"
bash scripts/validate-kong.sh --config config/config.yaml
```

Expect `All Kong runtime checks passed`.

### 4.4 Check the public path

```bash
curl -sS --cacert pki/root-ca.crt \
  --resolve fe.internal.example.com:443:20.119.58.31 \
  https://fe.internal.example.com/health
```

Expect `{"status":"UP","service":"hello-app","host":"vm1"}` or `"vm2"`.

```bash
curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" \
  -H "Host: fe.internal.example.com" http://20.119.58.31/
```

Expect `301 https://fe.internal.example.com/`.

### 4.5 Check the VMs

```powershell
az vm run-command invoke -g rg-pairs-monitor-dev -n vm1 `
  --command-id RunShellScript `
  --scripts "systemctl is-active hello-app; curl -fsS --cacert /etc/hello/tls/ca.crt --resolve be.internal.example.com:8100:127.0.0.1 https://be.internal.example.com:8100/health" `
  --query "value[0].message" -o tsv
```

Repeat for `vm2`.

---

## 5. Read these before changing anything

| File | Contents |
|---|---|
| `KONG.md` | Kong components, install, object map, **HTTPRoute + KIC-generated Kong route**, request flow, ports, troubleshooting |
| `CERTIFICATES.md` | Trust chain, every cert/key, creation, storage, rotation, security |
| `RUNBOOK.md` | Full repeatable deployment order and the errors hit |
| `cost.md` | East US inventory, hourly/monthly costs |
| `README.md` | Project overview |
| `terraform/README.md` | Terraform modules |
| `helm/README.md` | Chart values and manifests |

---

## 6. Current configuration values

`config/config.yaml` key values:

```yaml
azure:
  tenant_id: "3224f33f-f4c3-46a3-b624-7b0b452f9a98"
  subscription_id: "6d064e64-7038-4a50-aa19-899b347bed41"
  location: "eastus"
  aks:
    name: "aks-pairs-monitor-dev"
    kubernetes_version: "1.34"
    node_vm_size: "Standard_B4ms"
    node_min_count: 1
    node_max_count: 2
    private_cluster: false
  bastion:
    enabled: true
    name: "bas-pairs-monitor-dev"
    public_ip_name: "pip-bas-pairs-monitor-dev"
    public_ip: "20.25.20.81"
    subnet_cidr: "10.20.3.0/24"
  vm:
    size: "Standard_B2s"
    image_sku: "server"
    os_disk_type: "Standard_LRS"
    os_disk_size_gb: 30
  keyvault:
    name: "kv-pm-dev-ig8r"
    workload_identity_client_id: "af2ebf11-f30e-4ac7-8e77-cb286019cfcb"
  agw:
    enabled: true
    name: "agw-pairs-monitor-dev"
    public_ip: "20.119.58.31"
    certificate_secret_id: "https://kv-pm-dev-ig8r.vault.azure.net/secrets/agw-frontend/e6bdbdd1bb154e52b84d7e1ea5333c39"
    trusted_root_ca_path: "../pki/root-ca.crt"
```

Generated values:

| Output | Value |
|---|---|
| `aks_oidc_issuer_url` | `https://eastus.oic.prod-aks.azure.com/3224f33f-f4c3-46a3-b624-7b0b452f9a98/470acd2f-1319-4641-8148-53f4fc88c241/` |
| `key_vault_name` | `kv-pm-dev-ig8r` |
| `workload_identity_client_id` | `af2ebf11-f30e-4ac7-8e77-cb286019cfcb` |
| CA UUID | `7d29d90f-ba50-4830-99dd-5e4b209ce2dc` |
| AGW cert secret ID | `…/secrets/agw-frontend/e6bdbdd1bb154e52b84d7e1ea5333c39` |
| AGW public IP | `20.119.58.31` |
| Bastion public IP | `20.25.20.81` |

`terraform/terraform.tfvars.json` is generated by
`scripts/terraform-config.sh`. Do not hand-edit it; edit `config/config.yaml`.

---

## 7. Commands by task

### Validate the whole stack

```powershell
cd D:\gitclone\appjava\infra\kong-azure-vm-gateway\terraform
terraform plan -detailed-exitcode
```

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
export PATH="$HOME/bin:$PATH"
bash scripts/validate-kong.sh --config config/config.yaml
```

```bash
curl -sS --cacert pki/root-ca.crt \
  --resolve fe.internal.example.com:443:20.119.58.31 \
  https://fe.internal.example.com/health
```

### Change Kong routing / TLS

1. Edit `helm/*.yaml` or `config/config.yaml`.
2. Render/apply:

   ```bash
   bash scripts/apply-kong-resources.sh --env dev
   ```

3. Validate:

   ```bash
   bash scripts/validate-kong.sh --config config/config.yaml
   ```

Do **not** `kubectl apply -f helm/*.yaml` directly (tokens are unrendered).

### Change Terraform

```bash
bash scripts/terraform-config.sh
cd terraform
terraform plan && terraform apply
```

Then, if outputs changed:

```bash
cd ..
bash scripts/sync-terraform-outputs.sh
```

`sync-terraform-outputs.sh` needs Linux Terraform providers in WSL. If it fails,
run `(cd terraform && terraform init)` once in WSL.

### Rotate a VM certificate

See `CERTIFICATES.md` §10. Summary:

```bash
bash scripts/generate-vm-csrs.sh
bash certificates/issue-vm-certificates.sh \
  --csr-dir ./csr --ca-cert ./pki/root-ca.crt --ca-key ./pki/root-ca.key \
  --out-dir ./pki/issued --upload-keyvault --vault-name kv-pm-dev-ig8r
bash scripts/install-vm-app.sh
```

### Rotate the AGW listener certificate

See `CERTIFICATES.md` §7. Build a new PFX, import as a new `agw-frontend`
version, update `agw.certificate_secret_id`, and run Terraform.

### Inspect the private DNS zone

```powershell
az network private-dns zone show -g rg-pairs-monitor-dev -n internal.example.com -o json
az network private-dns record-set a show -g rg-pairs-monitor-dev -z internal.example.com -n be --query "{name:name,ttl:ttl,ips:aRecords[].ipv4Address}" -o json
```

On a VM:

```bash
getent hosts be.internal.example.com
```

---

## 8. Secrets and do-not-touch

| Path | Why |
|---|---|
| `pki/root-ca.key` | root CA private key — never upload, never print |
| `pki/root-ca.id` | stable Kong CA entity UUID — keep |
| `pki/kong/kong-proxy.key` | Kong listener private key |
| `pki/kong/agw-frontend.pfx` | AGW listener PFX (private key) |
| `pki/kong/agw-frontend.pfx.password` | PFX import password, 0600 |
| `terraform/terraform.tfstate` | local state, contains secrets |
| `terraform/vm-admin-password.txt` | VM admin password, 0600 |
| VM `/etc/hello/csr/vmN.key` | VM private key — never copy off the VM |
| VM `/etc/hello/hello.env` | keystore password, 0600 root |
| `.cache/` | local chart/CRD cache; safe to delete/recreate |

Do not commit `pki/`, `csr/`, `.cache/`, `terraform.tfstate*`,
`terraform/vm-admin-password.txt`, or `*.pfx.password`.

---

## 9. Known gotchas (already fixed — do not regress)

| Area | Rule |
|---|---|
| VM image | `Canonical:ubuntu-24_04-lts:server` (there is no `server-gen2`) |
| AKS version | `1.34` (1.33 is LTS-only in East US) |
| NAT ordering | `depends_on = [module.network]` on `module.aks` and `module.vm` |
| Subscription | `config.yaml` must match the Terraform state subscription |
| Key Vault roles | user needs `Key Vault Secrets Officer`; certificate import needs `Key Vault Certificates Officer` |
| WSL `az` paths | scripts use `wslpath -w` for `--file` |
| Helm GitHub 504 | use `.cache/ingress-0.24.0.tgz` + `KONG_CHART_TGZ` |
| Gateway API CRDs | local `.cache/gateway-api-v1.3.0-experimental.yaml` |
| Kong upstream SNI | `konghq.com/preserve-host: "false"` + `konghq.com/host-header` |
| Kong redirect | do not re-add the Kong HTTPRoute redirect; AGW owns HTTP→HTTPS |
| 8443 listener | `proxy_listen` must include `ssl` on IPv4 **and** IPv6 |
| `/etc/hello` perms | `root:hello 0750`, so the `hello` user can traverse |
| Validator naming | KIC names the Kong Service `httproute.kong.pairs-monitor.0`; validator matches the `k8s-name:pairs-monitor-backend` tag |
| AKS admin API | `network_policy=azure` is enforced; keep the admin Service headless |
| AGW cert | must be a Key Vault **certificate** (PFX), not a PEM secret |

---

## 10. File map

| Path | Purpose |
|---|---|
| `AGENT_HANDOFF.md` | this file — start here |
| `KONG.md` | Kong architecture, HTTPRoute/Kong route, objects, request flow |
| `CERTIFICATES.md` | trust chain, every certificate/key, rotation |
| `RUNBOOK.md` | full repeatable deployment order |
| `cost.md` | East US cost inventory |
| `README.md` | project overview |
| `config/config.yaml` | single source of inputs |
| `terraform/` | 9 modules + local state |
| `terraform/terraform.tfvars.json` | generated variables |
| `helm/` | Kong values + Gateway API manifests |
| `scripts/` | deployment, validation, VM wrappers |
| `certificates/` | CA/CSR/sign/install/validate scripts |
| `vm/` | hello-app systemd/service scripts |
| `pki/` | root CA + issued certs + AGW PFX (sensitive) |
| `csr/` | public CSRs |
| `.cache/` | local chart/CRD cache |
| `target/hello-app.jar` | built Java app (repo root) |

---

## 11. What was done (short change log)

1. Terraform foundation and fixes:
   - VM image `server-gen2` → `server`.
   - NAT association ordering.
   - Kubernetes 1.33 → 1.34.
   - Subscription aligned to `6d064e64`.
2. Bastion Basic with copy/paste and `AzureBastionSubnet`.
3. Root CA, Key Vault CA secrets, VM CSRs, signed VM certs, keystore, `hello-app`.
4. Kong Helm release, Gateway API CRDs, KIC, CSI CA sync.
5. Kong fixes:
   - upstream SNI (`preserve-host: false`, host header),
   - IPv6 8443 SSL listener,
   - redirect route removed (AGW owns HTTP→HTTPS),
   - validator matches KIC service name by tag,
   - local Helm/CRD cache for GitHub 504.
6. Application Gateway:
   - PFX `agw-frontend` imported as a Key Vault certificate,
   - `enable_application_gateway = true`,
   - public IP `20.119.58.31`,
   - backend `10.20.1.250:443` Healthy,
   - HTTP 301, HTTPS 200.
7. Documentation: `RUNBOOK.md`, `KONG.md`, `CERTIFICATES.md`, `AGENT_HANDOFF.md`,
   `cost.md`, README updates.

---

## 12. One-paragraph summary

Terraform builds an East US resource group with a VNet, AKS (1.34, CNI Overlay,
workload identity, Key Vault CSI), two Ubuntu VMs, a Basic Bastion, a private DNS
zone, Key Vault, and an Application Gateway. Helm installs Kong Gateway + KIC in
namespace `kong`; Gateway API manifests define a `fe.internal.example.com`
HTTPS listener and a `be.internal.example.com` backend TLS policy. Kong serves
the internal LB `10.20.1.250`; AGW `20.119.58.31` is the public front door. One
private root CA signs the AGW listener, Kong listener and both VM certificates.
Key Vault stores the public CA/leaf chains plus the AGW certificate; the root CA
private key stays on the laptop and VM private keys stay on the VMs. Kong
verifies the VM certificates against the root CA from Key Vault and load-balances
across `10.20.2.51:8100` and `10.20.2.52:8100`. The stack is live and validated.
