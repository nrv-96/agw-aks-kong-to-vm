# Kong Gateway on AKS — repeatable deployment runbook

This is the exact order used for the live deployment in East US. It records
which script runs where, what each phase produces, and where every TLS material
is stored.

## Current live state

| Item | Value |
|---|---|
| Subscription | `6d064e64-7038-4a50-aa19-899b347bed41` (PAG-PLomesh) |
| Tenant | `3224f33f-f4c3-46a3-b624-7b0b452f9a98` |
| Resource group | `rg-pairs-monitor-dev` |
| Region | `eastus` |
| AKS | `aks-pairs-monitor-dev` — Kubernetes **1.34.12**, Free tier, 1 × `Standard_B4ms` |
| VMs | `vm1` `10.20.2.51`, `vm2` `10.20.2.52` — `Standard_B2s`, Ubuntu 24.04 |
| Bastion | `bas-pairs-monitor-dev` — Basic, copy/paste on, public IP `20.25.20.81` |
| Key Vault | `kv-pm-dev-ig8r` |
| Kong internal LB | `10.20.1.250` (HTTPS 443) |
| Private DNS | `internal.example.com` → `be` → both VM IPs |
| Application Gateway | **enabled** — `agw-pairs-monitor-dev`, public IP `20.119.58.31`, backend `10.20.1.250:443` Healthy |

Traffic path today:

```text
Browser ──HTTPS fe.internal.example.com──► Application Gateway 20.119.58.31
        │  HTTPS, trusts private root CA
        ▼
Kong internal LB 10.20.1.250:443
        │  TLS terminated with fe.internal.example.com certificate
        ▼
Kong Gateway (KIC 3.5.14 / Kong 3.9.4)
        │  HTTPS, TLS verify, SNI + Host = be.internal.example.com
        ▼
vm1 10.20.2.51:8100 / vm2 10.20.2.52:8100
        │  hello-app (Java 21) + PKCS#12 keystore
```

Application Gateway is live and owns the public HTTP→HTTPS redirect. The Kong
internal listener is HTTPS-only.

---

## 0. Prerequisites

### Laptop (Windows PowerShell)

- Azure CLI (`az`)
- Terraform `>= 1.9`
- `kubectl`, `helm`
- JDK 21 + Maven
- WSL with `bash`, `openssl`, `yq`, `python3`, `base64`, `envsubst`, `sed`
- WSL `kubectl` and `helm` (Linux binaries in `~/bin`) plus the AKS kubeconfig

Install the WSL tools once:

```bash
mkdir -p ~/bin
curl -fsSL -o ~/bin/kubectl \
  "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x ~/bin/kubectl

curl -fsSL https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz -o /tmp/helm.tgz
tar -xzf /tmp/helm.tgz -C /tmp
mv /tmp/linux-amd64/helm ~/bin/helm
chmod +x ~/bin/helm

mkdir -p ~/.kube
cp /mnt/c/Users/Administrator/.kube/config ~/.kube/config
chmod 600 ~/.kube/config
```

Every WSL command below assumes:

```bash
export PATH="$HOME/bin:$PATH"
```

### Azure login

```powershell
az login
az account set --subscription 6d064e64-7038-4a50-aa19-899b347bed41
az account show --query "{subscription:id, tenant:tenantId, user:user.name}" -o table
```

The subscription **must** match the Terraform state. Mixing the `prod`
subscription (`0a457f9a…`, different tenant) with a state created in
`6d064e64` causes `InvalidAuthenticationTokenTenant`.

Update the AKS CLI extension if `az aks` commands crash with
`'NoneType' object has no attribute '__dict__'`:

```powershell
az extension update -n aks-preview
```

### Paths

| Item | Path |
|---|---|
| Repo root | `D:\gitclone\appjava` |
| Project | `D:\gitclone\appjava\infra\kong-azure-vm-gateway` |
| Terraform | `…\kong-azure-vm-gateway\terraform` |
| Config | `…\kong-azure-vm-gateway\config\config.yaml` |
| Local PKI | `…\kong-azure-vm-gateway\pki` |
| CSRs | `…\kong-azure-vm-gateway\csr` |
| App JAR | `D:\gitclone\appjava\target\hello-app.jar` |

---

## 1. Configure

Edit `config/config.yaml`:

- `azure.subscription_id` — must match the state subscription.
- `azure.environment`, `azure.location`.
- Network CIDRs (AKS `10.20.1.0/24`, VM `10.20.2.0/24`, Bastion
  `10.20.3.0/24`, AGW `10.20.4.0/24`).
- `azure.aks.kubernetes_version: "1.34"` (1.33 is LTS-only in East US).
- `azure.vm.image_sku: "server"` (the actual Gen2 image; `server-gen2` does not
  exist).
- `azure.bastion.enabled: true`.
- `azure.agw.enabled: false` until the AGW frontend certificate exists.
- `azure.keyvault.name`, `tenant_id`, `workload_identity_client_id` may stay
  `<INPUT>`; phase 2.1 fills them from Terraform outputs.

Generate the Terraform variables (WSL):

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
bash scripts/terraform-config.sh
```

Produces `terraform/terraform.tfvars.json`.

---

## 2. Terraform foundation

Run from Windows PowerShell in the Terraform directory:

```powershell
cd D:\gitclone\appjava\infra\kong-azure-vm-gateway\terraform
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

### What Terraform creates

| Module | Resources |
|---|---|
| `resource-group` | `rg-pairs-monitor-dev` |
| `network` | VNet `10.20.0.0/16`; `snet-aks`, `snet-vm`, `snet-agw`, `AzureBastionSubnet`; 3 NSGs + 16 rules; Standard public IP + NAT Gateway; subnet associations |
| `private-dns` | `internal.example.com`; A record `be` → `10.20.2.51`, `10.20.2.52`; VNet link |
| `key-vault` | `kv-pm-dev-ig8r`, RBAC, public access, purge protection, 90-day soft delete |
| `identity` | UAMIs: control plane, kubelet, Kong CSI, AGW; outputs client/principal IDs |
| `aks` | Free tier, Kubernetes 1.34, CNI Overlay, OIDC + workload identity, user-assigned control-plane + kubelet identities, Key Vault CSI provider, 1 × `Standard_B4ms` autoscale 1–2 |
| `vm` | 2 NICs, 2 × `Standard_B2s` Ubuntu 24.04, static private IPs, no public IPs, Java 21 cloud-init, Standard HDD S4 OS disks |
| `bastion` | Basic Bastion, Standard static public IP, copy/paste on |
| `application-gateway` | Gated off by default; Standard_v2, public IP, HTTPS listener, `/health` probe |

Terraform also creates:

- `azurerm_federated_identity_credential.csi` — subject
  `system:serviceaccount:kong:kong-gateway`.
- `Network Contributor` for the control-plane UAMI on the VNet.
- `Managed Identity Operator` for the control-plane UAMI on the kubelet UAMI.
- `Key Vault Secrets User` for the Kong CSI UAMI and the AGW UAMI.
- The AKS add-on identity is **not** granted Key Vault access.

### 2.1 Post-apply

```powershell
az aks get-credentials -g rg-pairs-monitor-dev -n aks-pairs-monitor-dev --overwrite-existing
kubectl get nodes -o wide
kubectl get pods -n kube-system
kubectl get csidriver
```

Then fill `config.yaml` from the outputs (WSL):

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
# one-time: install Linux providers so the sync script can call terraform
(cd terraform && terraform init)
bash scripts/sync-terraform-outputs.sh
```

If the sync script cannot run, copy these manually from `terraform output`:

- `tenant_id`
- `key_vault_name`
- `workload_identity_client_id`
- `aks_name`, `aks_oidc_issuer_url`
- VM IPs, Kong LB IP

Verify the federated credential and Key Vault RBAC:

```powershell
az identity federated-credential list --identity-name id-kong-csi-dev -g rg-pairs-monitor-dev -o table
$KV = az keyvault show -n kv-pm-dev-ig8r --query id -o tsv
az role assignment list --scope $KV --query "[].{principal:principalId,role:roleDefinitionName}" -o table
```

Expected: exactly two `Key Vault Secrets User` assignments (CSI + AGW).

---

## 3. Certificates — root CA and Key Vault

All TLS is anchored on one private root CA created on the laptop. The root CA
private key never leaves the laptop and is never uploaded to Azure.

### 3.1 Create the root CA (laptop WSL)

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
bash certificates/create-root-ca.sh --out-dir ./pki
```

Produces:

- `pki/root-ca.key` — **private**, 0600, never upload.
- `pki/root-ca.crt` — public root certificate.
- `pki/root-ca.id` — stable UUID used as the Kong CA entity ID.

### 3.2 Grant your user Key Vault data-plane access (one-time)

Terraform manages the vault but does not grant the deploying user data-plane
rights. Run in PowerShell:

```powershell
$OID = az ad signed-in-user show --query id -o tsv
$KV  = az keyvault show -n kv-pm-dev-ig8r --query id -o tsv
az role assignment create `
  --assignee-object-id $OID `
  --assignee-principal-type User `
  --role "Key Vault Secrets Officer" `
  --scope $KV
```

Wait 1–3 minutes for RBAC propagation before writing secrets.

### 3.3 Upload the public CA + UUID (laptop WSL)

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
bash certificates/upload-ca-to-keyvault.sh --vault-name kv-pm-dev-ig8r
```

Key Vault secrets created:

| Secret | Content |
|---|---|
| `pairs-monitor-root-ca` | public root CA PEM |
| `pairs-monitor-root-ca-id` | stable UUID `7d29…` (no trailing newline) |

No private key is uploaded.

Verify:

```powershell
az keyvault secret show --vault-name kv-pm-dev-ig8r --name pairs-monitor-root-ca --query "{name:name,enabled:attributes.enabled}" -o json
az keyvault secret show --vault-name kv-pm-dev-ig8r --name pairs-monitor-root-ca-id --query "{name:name,value:value}" -o json
```

---

## 4. VM certificate requests

This runs `certificates/generate-vm-csr.sh` **on both VMs** through Azure VM Run
Command. The VM private key is generated on the VM and never leaves it.

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
bash scripts/generate-vm-csrs.sh
```

What happens:

- On vm1: `/etc/hello/csr/vm1.key` + `/etc/hello/csr/vm1.csr`.
- On vm2: `/etc/hello/csr/vm2.key` + `/etc/hello/csr/vm2.csr`.
- Locally: `csr/vm1.csr`, `csr/vm2.csr`.
- Subject/SAN: `CN=be.internal.example.com`, `DNS:be.internal.example.com`.

Verify locally:

```bash
openssl req -in csr/vm1.csr -noout -verify
openssl req -in csr/vm1.csr -noout -subject -nameopt RFC2253
openssl req -in csr/vm1.csr -noout -text | grep -A1 "Subject Alternative Name"
```

The script is idempotent: an existing key is never overwritten; the CSR is
regenerated from it.

---

## 5. Sign the VM certificates

On the laptop (signing host):

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
bash certificates/issue-vm-certificates.sh \
  --csr-dir ./csr \
  --ca-cert ./pki/root-ca.crt \
  --ca-key ./pki/root-ca.key \
  --out-dir ./pki/issued \
  --upload-keyvault --vault-name kv-pm-dev-ig8r
```

Produces:

- `pki/issued/vm1.crt`, `pki/issued/vm1-chain.pem`
- `pki/issued/vm2.crt`, `pki/issued/vm2-chain.pem`

Uploads the **public** leaf+chain to Key Vault:

| Secret | Content |
|---|---|
| `pairs-monitor-vm1-tls` | vm1 leaf + root chain |
| `pairs-monitor-vm2-tls` | vm2 leaf + root chain |

The VM private keys remain at `/etc/hello/csr/vmN.key` on each VM.

---

## 6. App + certificate on the VMs

Build the Java app on the laptop:

```powershell
cd D:\gitclone\appjava
mvn -q -DskipTests package
```

Produces `target/hello-app.jar`.

Deploy the JAR + signed certificate to both VMs (laptop WSL):

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
bash scripts/install-vm-app.sh
```

This runs on each VM, via VM Run Command:

1. `vm/install-hello-service.sh`
   - creates `hello` user/group
   - `/opt/hello-app/hello-app.jar`
   - `/etc/hello/hello.env`
   - `/etc/systemd/system/hello-app.service`
2. `certificates/install-vm-certificate.sh`
   - validates the leaf/key/chain
   - builds `/etc/hello/tls/keystore.p12`
   - installs `tls.crt`, `chain.pem`, `ca.crt`, `tls.key`
   - restarts `hello-app`
   - checks `https://be.internal.example.com:8100/health`

Verify from the laptop:

```powershell
az vm run-command invoke -g rg-pairs-monitor-dev -n vm1 `
  --command-id RunShellScript `
  --scripts "systemctl is-active hello-app; curl -fsS --cacert /etc/hello/tls/ca.crt --resolve be.internal.example.com:8100:127.0.0.1 https://be.internal.example.com:8100/health" `
  --query "value[0].message" -o tsv
```

Expected: `active` and `{"status":"UP","service":"hello-app","host":"vm1"}`.

---

## 7. Kong listener certificate

The Gateway HTTPS listener needs a Kubernetes TLS secret named
`kong-proxy-tls` before `apply-kong-resources.sh` runs.

Generate and sign the listener certificate on the laptop (WSL):

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
bash certificates/generate-vm-csr.sh \
  --out-dir ./pki/kong --name kong-proxy \
  --cn fe.internal.example.com --san fe.internal.example.com

bash certificates/sign-vm-csr.sh \
  --csr ./pki/kong/kong-proxy.csr \
  --name kong-proxy \
  --ca-cert ./pki/root-ca.crt \
  --ca-key ./pki/root-ca.key \
  --out-dir ./pki/kong/issued \
  --hostname fe.internal.example.com \
  --days 365
```

Create the namespace and secret (leaf-only cert, not the chain):

```bash
export PATH="$HOME/bin:$PATH"
kubectl create namespace kong --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret tls kong-proxy-tls -n kong \
  --cert=./pki/kong/issued/kong-proxy.crt \
  --key=./pki/kong/kong-proxy.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

Verify:

```bash
kubectl get secret kong-proxy-tls -n kong
```

---

## 8. Install Kong

The chart and CRDs are normally fetched from GitHub. If GitHub returns 504,
cache them locally first:

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
mkdir -p .cache
curl -fL --retry 5 --retry-delay 3 \
  -o .cache/ingress-0.24.0.tgz \
  "https://github.com/Kong/charts/releases/download/ingress-0.24.0/ingress-0.24.0.tgz"
curl -fL --retry 5 --retry-delay 3 \
  -o .cache/gateway-api-v1.3.0-experimental.yaml \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml"
```

Install/upgrade Kong (laptop WSL):

```bash
export PATH="$HOME/bin:$PATH"
KONG_CHART_TGZ=$PWD/.cache/ingress-0.24.0.tgz \
  bash scripts/kong-install.sh --env dev
```

This:

- installs Gateway API CRDs v1.3.0 (local cache if present)
- applies the `pairs-monitor-ca` SecretProviderClass
- installs `kong/ingress` 0.24.0 with `kong:3.9.4` and KIC `3.5.14`
- pins the `kong-gateway` ServiceAccount and workload-identity annotations
- waits until the CSI secret contains `ca.crt` + `id`

Then apply the Gateway, backend, TLS and policy manifests:

```bash
bash scripts/apply-kong-resources.sh --env dev
```

This creates/updates:

| Object | Purpose |
|---|---|
| `GatewayClass/kong` | unmanaged Kong class |
| `Gateway/pairs-monitor-gateway` | HTTPS listener on `fe.internal.example.com`, address `10.20.1.250` |
| `HTTPRoute/pairs-monitor` | HTTPS route to `pairs-monitor-backend:8100` |
| `Service/pairs-monitor-backend` | selector-less Service, `konghq.com/host-header` + upstream policy |
| `EndpointSlice/pairs-monitor-backend-vms` | the two VM IPs |
| `BackendTLSPolicy/pairs-monitor-backend-tls` | HTTPS + SNI/hostname + CA verification |
| `KongUpstreamPolicy/pairs-monitor-backend-policy` | round-robin + active/passive HTTPS health checks |
| `Secret/pairs-monitor-ca` | CSI-synced CA + UUID |
| `NetworkPolicy/kong-admin-restricted` | admin API restriction (enforced with `network_policy=azure`) |

`apply-kong-resources.sh` waits for `Gateway Programmed` and
`BackendTLSPolicy Accepted`; it fails closed if either is not true.

---

## 9. Validate

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
export PATH="$HOME/bin:$PATH"
bash scripts/validate-kong.sh --config config/config.yaml
```

It checks:

- Kong Service `protocol=https`, `tls_verify=true`, `tls_verify_depth=1`,
  CA UUID, port 8100
- upstream targets exactly `10.20.2.51:8100`, `10.20.2.52:8100`
- upstream `host_header=be.internal.example.com`
- active health checks: HTTPS, `/health`, SNI `be.internal.example.com`,
  certificate verification on
- Kong CA entity matches the Kubernetes `ca.crt` (SHA-256)
- both targets `HEALTHY`

End-to-end from a VM:

```bash
curl -sS --cacert /etc/hello/tls/ca.crt \
  --resolve fe.internal.example.com:443:10.20.1.250 \
  https://fe.internal.example.com/health
```

Expected:

```json
{"status":"UP","service":"hello-app","host":"vm1"}
```

Repeat on vm2; the host should alternate.

---

## 10. Where every certificate/key lives

| Material | Laptop | Azure / Kubernetes | VM | Private? |
|---|---|---|---|---|
| Root CA key | `pki/root-ca.key` | — | — | **yes** — never upload |
| Root CA cert | `pki/root-ca.crt` | KV `pairs-monitor-root-ca`; K8s `pairs-monitor-ca` (`ca.crt`) | `/etc/hello/tls/ca.crt` | public |
| Root CA UUID | `pki/root-ca.id` | KV `pairs-monitor-root-ca-id`; K8s `pairs-monitor-ca` (`id`) | — | public |
| VM1 leaf | `pki/issued/vm1.crt` | KV `pairs-monitor-vm1-tls` | `/etc/hello/tls/tls.crt` | public |
| VM1 chain | `pki/issued/vm1-chain.pem` | KV `pairs-monitor-vm1-tls` | `/etc/hello/tls/chain.pem` | public |
| VM1 private key | — | — | `/etc/hello/csr/vm1.key`, `/etc/hello/tls/tls.key`, inside `keystore.p12` | **yes** — never leaves VM |
| VM2 leaf/chain/key | same pattern | same pattern | same pattern | same |
| Keystore password | — | — | `/etc/hello/hello.env` (0600 root) | **yes** |
| Kong listener cert | `pki/kong/issued/kong-proxy.crt` | K8s `kong-proxy-tls` (`tls.crt`) | — | public |
| Kong listener key | `pki/kong/kong-proxy.key` | K8s `kong-proxy-tls` (`tls.key`) | — | **yes** — needed by Kong |
| Kong CA entity | — | Kong Admin API, ID `7d29…` | — | public |
| AGW frontend cert + key | `pki/kong/agw-frontend.pfx` (built from `kong-proxy.crt` + `kong-proxy.key`) | Key Vault certificate `agw-frontend`, secret ID `…/secrets/agw-frontend/e6bdbdd1…` | — | **yes** — the PFX / KV certificate contains the private key |

Key Vault contains public CA/leaf chains **and** the AGW frontend certificate
(a PFX with its private key, required by Application Gateway). The root CA
private key and the VM private keys never enter Key Vault.

Kubernetes contains:

- `kong-proxy-tls` — listener leaf + private key (required for TLS termination).
- `pairs-monitor-ca` — public CA + UUID only.

---

## 11. What runs where

| Task | Where |
|---|---|
| `scripts/terraform-config.sh` | Laptop WSL |
| `terraform init/plan/apply` | Laptop PowerShell |
| `az aks get-credentials` | Laptop PowerShell |
| `scripts/sync-terraform-outputs.sh` | Laptop WSL (run `terraform init` in WSL once) |
| `certificates/create-root-ca.sh` | Laptop WSL |
| `certificates/upload-ca-to-keyvault.sh` | Laptop WSL |
| `scripts/generate-vm-csrs.sh` | Laptop WSL → Run Command on each VM |
| `certificates/issue-vm-certificates.sh` | Laptop WSL |
| `mvn package` | Laptop PowerShell |
| `scripts/install-vm-app.sh` | Laptop WSL → Run Command on each VM |
| `vm/install-hello-service.sh` | VM (invoked remotely) |
| `certificates/install-vm-certificate.sh` | VM (invoked remotely) |
| `certificates/generate-vm-csr.sh` | VM (invoked remotely) |
| `scripts/kong-install.sh` | Laptop WSL |
| `scripts/apply-kong-resources.sh` | Laptop WSL |
| `scripts/deploy.sh` | Laptop WSL (wraps install + apply + reload + validate) |
| `scripts/validate-kong.sh` | Laptop WSL |
| `curl` end-to-end test | VM SSH or `az vm run-command` |

---

## 12. Repeat order (copy/paste checklist)

1. Edit `config/config.yaml` (subscription, CIDRs, `image_sku: server`,
   `kubernetes_version: 1.34`, Bastion on; AGW off until step 18).
2. WSL: `bash scripts/terraform-config.sh`.
3. PowerShell: `terraform init && terraform apply`.
4. PowerShell: `az aks get-credentials …`.
5. WSL: `bash scripts/sync-terraform-outputs.sh`.
6. WSL: `bash certificates/create-root-ca.sh --out-dir ./pki`.
7. PowerShell: assign `Key Vault Secrets Officer` to your user (one-time).
8. WSL: `bash certificates/upload-ca-to-keyvault.sh --vault-name kv-pm-dev-ig8r`.
9. WSL: `bash scripts/generate-vm-csrs.sh`.
10. WSL: `bash certificates/issue-vm-certificates.sh … --upload-keyvault …`.
11. PowerShell: `mvn -q -DskipTests package`.
12. WSL: `bash scripts/install-vm-app.sh`.
13. WSL: generate/sign the Kong listener cert and create `kong-proxy-tls`.
14. WSL: `KONG_CHART_TGZ=… bash scripts/kong-install.sh --env dev`.
15. WSL: `bash scripts/apply-kong-resources.sh --env dev`.
16. WSL: `bash scripts/validate-kong.sh --config config/config.yaml`.
17. VM: `curl --cacert /etc/hello/tls/ca.crt --resolve fe.internal.example.com:443:10.20.1.250 https://fe.internal.example.com/health`.
18. AGW (optional, §14): build `pki/kong/agw-frontend.pfx`, import it as Key
    Vault certificate `agw-frontend`, set `azure.agw.enabled: true` +
    `certificate_secret_id`, regenerate tfvars, `terraform apply`.

Or use the one-shot wrapper for steps 14–16:

```bash
KONG_CHART_TGZ=$PWD/.cache/ingress-0.24.0.tgz \
  bash scripts/deploy.sh --phase kong --env dev
```

---

## 13. Errors hit during the first deployment (and fixes)

| Symptom | Cause | Fix |
|---|---|---|
| `PlatformImageNotFound` for `server-gen2` | That SKU does not exist | Use `server` (already Gen2) |
| `SubnetNotAssociatedWithNATGateway` | AKS raced the NAT association | `depends_on = [module.network]` on `module.aks` and `module.vm` |
| `K8sVersionNotSupported` 1.33 is LTS-only | 1.33 left standard support in East US | Use Kubernetes **1.34** |
| `az aks` crashes with `NoneType` | `aks-preview` extension bug | `az extension update -n aks-preview` |
| Key Vault `ForbiddenByRbac` | Deploying user had no data-plane role | Assign `Key Vault Secrets Officer` on the vault |
| `upload-ca-to-keyvault.sh` “file not found” | Windows `az` received a WSL path | Scripts now convert with `wslpath -w` |
| Helm chart download 504 | GitHub release asset timeout | Cache chart + CRDs under `.cache`, use `KONG_CHART_TGZ` |
| Kong 502 “certificate does not match fe...” | Kong used the client Host as upstream SNI | `konghq.com/preserve-host: "false"` on the HTTPRoute + `konghq.com/host-header` |
| HTTPS request returned 301 to itself | KIC/Kong matched the HTTP-only redirect route on 8443 | Removed the Kong redirect route; AGW owns HTTP→HTTPS |
| 8443 IPv6 listener was plaintext | Chart default `[::]:8443 http2` lacked `ssl` | Pin `proxy_listen` with `ssl` on both 8443 listeners |
| `hello-app` “keystore is not readable” | `/etc/hello` was `root:root 0750` | `chown root:hello /etc/hello`, mode 0750 |
| `validate-kong.sh` could not find the Service | KIC names it `httproute.kong.pairs-monitor.0` | Match the `k8s-name:pairs-monitor-backend` tag |
| `az aks` subscription/tenant mismatch | `config.yaml` pointed at `prod` while state was in `6d064e64` | Align `azure.subscription_id` with the state |
| AGW certificate import | `key_vault_secret_id` needs a Key Vault **certificate** (PFX), not a PEM secret | Import `agw-frontend.pfx`; grant `Key Vault Certificates Officer` |

---

## 14. Application Gateway (executed 2026-11-09)

Result: `agw-pairs-monitor-dev`, public IP `20.119.58.31`, backend
`10.20.1.250:443` **Healthy** (probe 200), HTTPS 200, HTTP 301 to
`https://fe.internal.example.com/`.

The AGW frontend certificate must be a Key Vault **certificate** (PFX), not a
PEM secret. The existing Kong listener certificate/key can be reused.

1. Build the PFX (laptop WSL):

   ```bash
   cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
   PFX_PASS="$(openssl rand -base64 24 | tr -d '\r\n')"
   printf '%s' "$PFX_PASS" > pki/kong/agw-frontend.pfx.password
   chmod 600 pki/kong/agw-frontend.pfx.password
   openssl pkcs12 -export \
     -inkey pki/kong/kong-proxy.key \
     -in pki/kong/issued/kong-proxy.crt \
     -certfile pki/root-ca.crt \
     -name agw-frontend \
     -out pki/kong/agw-frontend.pfx \
     -passout "pass:${PFX_PASS}"
   ```

2. Grant your user `Key Vault Certificates Officer` (PowerShell, one-time):

   ```powershell
   $OID = az ad signed-in-user show --query id -o tsv
   $KV  = az keyvault show -n kv-pm-dev-ig8r --query id -o tsv
   az role assignment create --assignee-object-id $OID --assignee-principal-type User `
     --role "Key Vault Certificates Officer" --scope $KV
   ```

3. Import the PFX as a Key Vault certificate:

   ```powershell
   $pfx  = 'D:\gitclone\appjava\infra\kong-azure-vm-gateway\pki\kong\agw-frontend.pfx'
   $pass = (Get-Content 'D:\gitclone\appjava\infra\kong-azure-vm-gateway\pki\kong\agw-frontend.pfx.password' -Raw).Trim()
   az keyvault certificate import --vault-name kv-pm-dev-ig8r --name agw-frontend --file $pfx --password $pass
   az keyvault certificate show --vault-name kv-pm-dev-ig8r --name agw-frontend --query sid -o tsv
   ```

   The `sid` is the versioned secret ID used by Terraform.

4. In `config/config.yaml`:

   ```yaml
   agw:
     enabled: true
     certificate_secret_id: "https://kv-pm-dev-ig8r.vault.azure.net/secrets/agw-frontend/<version>"
   ```

5. Regenerate tfvars and apply:

   ```bash
   bash scripts/terraform-config.sh
   cd terraform && terraform plan && terraform apply
   ```

6. Test:

   ```bash
   # HTTPS through AGW (validate the private root CA)
   curl -sS --cacert pki/root-ca.crt \
     --resolve fe.internal.example.com:443:20.119.58.31 \
     https://fe.internal.example.com/health

   # HTTP redirect
   curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" \
     -H "Host: fe.internal.example.com" http://20.119.58.31/
   ```

The AGW UAMI `id-agw-dev` has `Key Vault Secrets User` from Terraform, so it can
read the certificate secret. The AGW probe trusts `pki/root-ca.crt` and verifies
the Kong listener certificate.

---

## 15. Quick health commands

```powershell
# AKS
kubectl get nodes -o wide
kubectl get pods -n kong
kubectl get gateway,httproute,backendtlspolicy -n kong
kubectl get svc kong-gateway-proxy -n kong

# Application Gateway
az network application-gateway show-backend-health -g rg-pairs-monitor-dev -n agw-pairs-monitor-dev --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health}" -o table
wsl -e bash -lc 'cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway && curl -sS --cacert pki/root-ca.crt --resolve fe.internal.example.com:443:20.119.58.31 https://fe.internal.example.com/health'

# Kong runtime
wsl -e bash -lc 'cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway && export PATH="$HOME/bin:$PATH" && bash scripts/validate-kong.sh --config config/config.yaml'

# VMs
az vm run-command invoke -g rg-pairs-monitor-dev -n vm1 --command-id RunShellScript --scripts "systemctl is-active hello-app; curl -fsS --cacert /etc/hello/tls/ca.crt --resolve be.internal.example.com:8100:127.0.0.1 https://be.internal.example.com:8100/health" --query "value[0].message" -o tsv

# Key Vault
az keyvault secret list --vault-name kv-pm-dev-ig8r --query "[].name" -o table
```
