# Kong Gateway on AKS for the VM-hosted application

Automated Kong Gateway in AKS in front of two Linux VMs, with Azure Private DNS,
a private root CA, Azure Key Vault / CSI trust distribution, HTTPS to the VMs
with full certificate verification, Application Gateway fronting Kong, and
Entra ID SSO (pending).

> **Status: live. Terraform foundation, Bastion, VM TLS/hello-app, Kong/CSI and
> Application Gateway are deployed and validated. Entra ID SSO and CA renewal
> automation are pending.**
> Terraform (9 modules) creates the resource group, network, private DNS, Key Vault,
> AKS, identities, VMs, Bastion and Application Gateway. The Kong Helm layer,
> VM certificate/systemd automation and AGW frontend are implemented. Renewal
> automation, Entra ID SSO, CI and the full validation suite are pending.

## Documentation

| File | Purpose |
|---|---|
| `AGENT_HANDOFF.md` | **Start here** — live state, start-here checklist, commands, do-not-touch rules |
| `KONG.md` | Kong architecture, **HTTPRoute + KIC-generated Kong route**, objects, request flow |
| `CERTIFICATES.md` | Trust chain, every certificate/key, creation, storage, rotation, security |
| `RUNBOOK.md` | Full repeatable deployment order and the errors hit |
| `cost.md` | East US SKU inventory and hourly/monthly cost |

## Target architecture

```
Browser ──HTTPS fe.internal.example.com──► Application Gateway ──HTTPS──► Kong (AKS)
                                                                 │
                                                    Entra ID OIDC (later)
                                                                 │
                                                    Kong upstream (HTTPS)
                                                     SNI be.internal.example.com
                                                     CA   pairs-monitor-root-ca
                                                                 │
                                        ┌────────────────────────┴───────────────┐
                                     VM1 10.20.2.51:8100                    VM2 10.20.2.52:8100
                                     cert SAN be.internal.example.com          cert SAN be.internal.example.com
```

Two distinct identities, deliberately:

| Identity | Used for | Issued by |
| --- | --- | --- |
| `fe.internal.example.com` | browser → Application Gateway → Kong listener | private root CA (`agw-frontend`, `kong-proxy-tls`) |
| `be.internal.example.com` | Kong → VM TLS (SNI + hostname + chain verification) | private root CA (VM leaf certificates) |

Placeholder backends are `10.20.2.51` / `10.20.2.52`. The spec's `100.64.2.51/52`
cannot be used: Azure reserves `100.64.0.0/10` for CGNAT and rejects it in VNets.

## What exists now

```
kong-azure-vm-gateway/
├── config/config.yaml                  # single source of inputs + version pins
├── AGENT_HANDOFF.md                    # start here: live state + agent checklist
├── KONG.md                             # Kong architecture and request flow
├── CERTIFICATES.md                     # TLS inventory, creation, rotation
├── RUNBOOK.md                          # repeatable deployment order
├── cost.md                             # East US SKU/price inventory + monthly estimate
├── terraform/                          # 9 modules: RG, network, DNS, VM, KV, identity, AKS, AGW, Bastion
├── helm/
│   ├── values.yaml                     # base chart values (3 replicas, DB-less, PDB, probes)
│   ├── values-dev.yaml                 # 1 replica, internal Azure LB (static IP)
│   ├── values-prod.yaml                # internal Azure LB, anti-affinity, PDB 2
│   ├── values-csi.yaml                 # Key Vault CSI CA volume + health-check trust bundle
│   ├── gateway.yaml                    # GatewayClass + Gateway (HTTPS/HTTP listeners)
│   ├── httproute.yaml                  # HTTPS route (public HTTP→HTTPS is at AGW)
│   ├── service.yaml                    # pairs-monitor-backend (selector-less, https)
│   ├── endpointslice.yaml              # the two VM IPs (single target source)
│   ├── backend-tls-policy.yaml         # SNI + hostname + CA verification
│   ├── kong-upstream-policy.yaml       # round-robin + active/passive HTTPS health checks
│   ├── secret-provider-class.yaml      # Key Vault CA → CSI → pairs-monitor-ca
│   ├── network-policy.yaml             # Admin API only from KIC
│   └── README.md                       # chart-level detail, fallbacks, troubleshooting
├── certificates/
│   ├── create-root-ca.sh               # one-time private Root CA
│   ├── generate-vm-csr.sh              # VM-local key + CSR (runs on the VM)
│   ├── sign-vm-csr.sh                  # controlled signing host
│   ├── issue-vm-certificates.sh        # signs all backend CSRs from config
│   ├── validate-certificate.sh         # SAN/EKU/chain/key-match checks
│   ├── install-vm-certificate.sh       # keystore + env + restart (runs on the VM)
│   └── upload-ca-to-keyvault.sh        # public CA PEM + stable UUID for CSI
├── vm/
│   ├── install-hello-service.sh        # hello user, dirs, systemd unit
│   └── reload-application.sh           # restart + local HTTPS health check
├── scripts/
│   ├── lib.sh                          # config loading + manifest rendering
│   ├── kong-install.sh                 # CRDs + Helm install (CSI-aware)
│   ├── kong-upgrade.sh                 # dry run, then gated --yes upgrade
│   ├── apply-kong-resources.sh         # render/apply Gateway API resources (fail-closed)
│   ├── reload-kong-trust.sh            # CA checksum → gateway rollout
│   ├── validate-kong.sh                # Admin API runtime assertions
│   ├── verify-helm-workload-identity.sh # rendered SA/pod workload-identity assertions
│   └── deploy.sh                       # phase-1 entry point
└── README.md                           # this file
```

Not present yet: `automation/`, `monitoring/`, `.github/workflows/`,
`config/schema.json` and the remaining validation scripts listed in the
specification.

## Pinned versions

| Component | Version |
| --- | --- |
| `kong/ingress` chart | `0.24.0` (subcharts `kong/kong` `3.2.0`) |
| Kong Gateway OSS image | `kong:3.9.4` |
| Kong Ingress Controller | `kong/kubernetes-ingress-controller:3.5.14` |
| Gateway API CRDs | `v1.3.0` **experimental** |
| Key Vault CSI provider | `1.8.2` (AKS managed add-on) |
| Terraform / azurerm | Terraform `>= 1.9`, `hashicorp/azurerm ~> 4.0` |

`3.5.14` is the latest KIC 3.5 patch and its `go.mod` pins
`sigs.k8s.io/gateway-api v1.3.0`, which is why the CRD channel is 1.3.0
experimental. Bump `config/config.yaml` only after re-checking that matrix.

## Prerequisites

- `kubectl` 1.29+ pointed at the target cluster, `helm` 3.14+
- `terraform` 1.9+, Azure CLI (`az login`)
- `yq` v4 (mikefarah), `envsubst` (gettext), `python3` (runtime validation), `bash` 4+
- `openssl` 1.1.1+ for the certificate scripts; `az` only for Key Vault upload/download
- On the VMs: Java 21, `systemd`, `openssl`, `curl`
- Azure access for later phases (the phase-1 scripts never call Azure)

The scripts run in WSL on this workstation; `yq` is installed at `~/bin/yq`.
On another machine install yq v4 (`winget install --id MikeFarah.yq` or
`choco install yq`) and ensure `python3` is available for `validate-kong.sh`.

## Quick start

```bash
# 0. Infrastructure (T1): generate tfvars, validate, plan, apply
./scripts/terraform-config.sh
terraform -chdir=terraform init
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
terraform -chdir=terraform plan
terraform -chdir=terraform apply
./scripts/sync-terraform-outputs.sh

# 1. Fill in config/config.yaml (every <INPUT> and both VM IPs)
#    Replace the placeholder Key Vault / tenant / identity values too.

# 2. Local render check - no cluster calls
helm template kong kong/ingress --version 0.24.0 -n kong \
  -f helm/values.yaml -f helm/values-prod.yaml

# 3. Install gateway + controller (CSI auto-detected)
./scripts/kong-install.sh --env dev --dry-run
./scripts/kong-install.sh --env dev

# 4. Apply Gateway API / backend / TLS resources
./scripts/apply-kong-resources.sh --env dev

# 5. One-shot phase-1 deploy (install + apply + trust reload + runtime validation)
./scripts/deploy.sh --config config/config.yaml --env dev
```

The dev profile uses one Kong replica and the internal Azure LoadBalancer with the
static IP from `config.kong.internal_lb_ip`; production uses three replicas and PDB
`minAvailable: 2`. `kong-upgrade.sh` requires `--yes` before applying anything.

### Bastion access

The VMs have no public IPs. Connect through the Basic Bastion host.

| VM | Resource ID |
|---|---|
| `vm1` | `/subscriptions/6d064e64-7038-4a50-aa19-899b347bed41/resourceGroups/rg-pairs-monitor-dev/providers/Microsoft.Compute/virtualMachines/vm1` |
| `vm2` | `/subscriptions/6d064e64-7038-4a50-aa19-899b347bed41/resourceGroups/rg-pairs-monitor-dev/providers/Microsoft.Compute/virtualMachines/vm2` |

```powershell
# Load the generated password (or use the value you supplied via vm_admin_password)
$VM_PASSWORD = (Get-Content .\terraform\vm-admin-password.txt -Raw).Trim()

az network bastion ssh `
  --resource-group rg-pairs-monitor-dev `
  --name bas-pairs-monitor-dev `
  --target-resource-id "/subscriptions/6d064e64-7038-4a50-aa19-899b347bed41/resourceGroups/rg-pairs-monitor-dev/providers/Microsoft.Compute/virtualMachines/vm1" `
  --auth-type password `
  --username azureuser
```

Repeat with the `vm2` resource ID. The CLI prompts for the password; paste
`$VM_PASSWORD`. Bastion copy/paste is enabled. In the portal: VM → **Connect** →
**Bastion**.

The optional Terraform variable `vm_admin_password` (sensitive, default empty)
lets you supply your own password. When set, Terraform updates both VMs in place
and rewrites `terraform/vm-admin-password.txt`.

### Generate VM certificate requests

```bash
./scripts/generate-vm-csrs.sh
```

This runs `certificates/generate-vm-csr.sh` on vm1 and vm2 through Azure VM Run
Command, so nothing needs to be copied to the VMs. Only the CSRs come back, into
`csr/vm1.csr` and `csr/vm2.csr`; the private keys stay at
`/etc/hello/csr/<vm>.key` on each VM. The script is idempotent: an existing key
is never overwritten, and the CSR is regenerated from it.

### Install the app and certificate on the VMs

```bash
./scripts/install-vm-app.sh
```

This pushes the signed certificate, chain, root CA and `target/hello-app.jar` to
both VMs through VM Run Command, installs the `hello-app` systemd service,
builds the PKCS#12 keystore, restarts the service, and validates
`https://be.internal.example.com:8100/health` locally on each VM.

## VM certificate and application deployment

The `certificates/` and `vm/` scripts implement the VM side of the chain. No
live VMs were available here, so they were validated end to end against a
temporary prefix (Root CA -> CSRs -> signed certificates -> keystore -> systemd
unit), and the resulting keystore was used to start the Java app; `curl --cacert`
verified the chain and SAN.

### Certificate workflow

```bash
# 1. Signing host only: create the Root CA once. The CA key never leaves this host.
./certificates/create-root-ca.sh --out-dir ./pki

# 1b. Upload the public CA PEM + stable UUID to Key Vault for the CSI driver.
./certificates/upload-ca-to-keyvault.sh --vault-name <key-vault-name>

# 2. On each VM: generate the private key + CSR. The key never leaves the VM.
./certificates/generate-vm-csr.sh --out-dir /etc/hello/csr --name vm1 \
  --cn be.internal.example.com --san be.internal.example.com
# Copy only /etc/hello/csr/vm1.csr to the signing host (never vm1.key), e.g.:
#   scp vm1:/etc/hello/csr/vm1.csr ./csr/vm1.csr
# Repeat with --name vm2.

# 3. Signing host: sign every backend CSR from config/config.yaml.
./certificates/issue-vm-certificates.sh \
  --csr-dir ./csr \
  --ca-cert ./pki/root-ca.crt --ca-key ./pki/root-ca.key \
  --out-dir ./pki/issued \
  --upload-keyvault --vault-name <key-vault-name>
# Optional: --upload-keyvault stores the public leaf+chain as the KV secret named
# backends[].certificate_name (pairs-monitor-vm1-tls / -vm2-tls).

# 4. On each VM: install the certificate/keystore and restart + validate.
./certificates/install-vm-certificate.sh \
  --cert ./pki/issued/vm1.crt --chain ./pki/root-ca.crt --ca ./pki/root-ca.crt \
  --key /etc/hello/csr/vm1.key
```

`install-vm-certificate.sh` also supports:

```bash
--from-keyvault --vault-name <kv> --secret-name pairs-monitor-vm1-tls
```

The private key must already be on the VM; it is never downloaded or accepted
from Key Vault. The public leaf+chain is stored in Key Vault; the VM needs
`Key Vault Secrets User` only if it pulls the certificate directly. The signing
host needs `Key Vault Secrets Officer` to upload the public chain.

### Systemd service

```bash
# On the VM, after copying hello-app.jar and installing Java 21:
./vm/install-hello-service.sh --jar /tmp/hello-app.jar --start
./vm/reload-application.sh --ca /etc/hello/tls/ca.crt
```

`install-hello-service.sh` creates:

- system user/group `hello` (no login shell)
- `/opt/hello-app/hello-app.jar`
- `/etc/hello/hello.env` (0600; `PORT`, `TLS_KEYSTORE_PATH`, `TLS_KEYSTORE_TYPE`;
  `install-vm-certificate.sh` adds `TLS_KEYSTORE_PASSWORD`)
- `/etc/hello/tls/` (0750; certs 0644, key/keystore 0600)
- `/etc/systemd/system/hello-app.service` with `NoNewPrivileges`,
  `ProtectSystem=strict`, `PrivateTmp`, `UMask=0077`, `Restart=on-failure`
- `systemctl enable`; `--start` starts only when the keystore exists

New-VM order: install Java 21 -> `install-hello-service.sh` -> generate key/CSR ->
sign -> `install-vm-certificate.sh` (or `--skip-restart` + `reload-application.sh`).
`reload-application.sh` restarts the unit and verifies
`https://be.internal.example.com:8100/health` locally with the private CA.

### Phase-1 prerequisites you must supply

`apply-kong-resources.sh` fails fast unless Secret `kong-proxy-tls` exists in the
Kong namespace (certificate SAN must cover `application.public_hostname`) and the
`pairs-monitor-ca` CA Secret is present with both required keys. Until phase 2
issues real certificates, create a throwaway listener cert for lab testing:

```bash
openssl req -x509 -newkey rsa:3072 -nodes -days 7 \
  -subj "/CN=fe.internal.example.com" -addext "subjectAltName=DNS:fe.internal.example.com" \
  -keyout kong-proxy.key -out kong-proxy.crt
kubectl create secret tls kong-proxy-tls -n kong \
  --cert=kong-proxy.crt --key=kong-proxy.key
```

The CA Secret (`pairs-monitor-ca`) must contain **two** keys or KIC ignores it:

| Key | Content |
| --- | --- |
| `ca.crt` | public root CA certificate (PEM) |
| `id` | stable UUID used as the Kong `ca_certificates` entity ID |

With CSI, both come from Key Vault: `pairs-monitor-root-ca` (PEM) and
`pairs-monitor-root-ca-id` (UUID, no trailing newline). Without CSI, create the
Secret manually with `--from-file=ca.crt=... --from-literal=id=<uuid>` and label
it `konghq.com/ca-cert=true`. The apply script verifies both keys and refuses to
continue if one is missing.

Details and the no-Key-Vault CA stand-in are in `helm/README.md`.

## Terraform infrastructure (9 modules)

| # | Module | Creates |
|---|---|---|
| 01 | `resource-group` | resource group (create or reuse) |
| 02 | `network` | VNet, `snet-aks`, `snet-vm`, `snet-agw`, `AzureBastionSubnet`, NSGs/rules, NAT gateway |
| 03 | `private-dns` | private zone `internal.example.com`, A record `be`, VNet link |
| 04 | `vm` | 2 NICs, 2 Ubuntu 24.04 VMs, static private IPs, no public IPs, Java 21 cloud-init, password auth, patch mode |
| 05 | `key-vault` | Key Vault with RBAC authorization, public access, purge protection; secret contents are script-managed |
| 06 | `identity` | AKS control-plane, kubelet, Kong CSI and AGW UAMIs; federated credential created after AKS |
| 07 | `aks` | AKS Free tier, CNI Overlay, OIDC + workload identity, user-assigned control-plane + kubelet identities, CSI provider, single `Standard_B4ms` node with autoscale |
| 08 | `application-gateway` | Standard_v2, static public IP, HTTPS listener, Kong backend pool, private-root trust, `/health` probe (enabled in the live config) |
| 09 | `bastion` | Basic Azure Bastion, Standard static public IP, copy/paste enabled, dedicated `AzureBastionSubnet` |

No observability, backup, WAF or private endpoints by request. The Private
Endpoint subnet/NSG are deferred until Key Vault private connectivity is
implemented.

AKS uses separate user-assigned control-plane, kubelet, Kong CSI and AGW
identities. The control-plane identity gets `Network Contributor` on the VNet and
`Managed Identity Operator` on the kubelet identity before AKS is created. The
federated credential subject is `system:serviceaccount:kong:kong-gateway`; Helm
pins that ServiceAccount, adds the `azure.workload.identity/use` pod label, injects
the client-id annotation and verifies the rendered chart.

### DNS and local trust

- Backend: private zone `internal.example.com`, A record `be` → `10.20.2.51`, `10.20.2.52`.
- Frontend: `fe.internal.example.com` resolves through the Windows hosts file to the
  AGW public IP. There is no public DNS zone.
- The browser must trust the private root CA:

```powershell
# Run as Administrator
Add-Content C:\Windows\System32\drivers\etc\hosts "<AGW_PUBLIC_IP> fe.internal.example.com"
Import-Certificate -FilePath .\pki\root-ca.crt -CertStoreLocation Cert:\LocalMachine\Root
```

### Commands and state

```bash
# Generate terraform/terraform.tfvars.json from config/config.yaml
./scripts/terraform-config.sh

terraform -chdir=terraform init
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
terraform -chdir=terraform plan
terraform -chdir=terraform apply

# Write tenant / Key Vault / UAMI / IPs back into config/config.yaml
./scripts/sync-terraform-outputs.sh
```

- State is **local** by request. Do not commit `terraform.tfstate`,
  `terraform/terraform.tfvars.json` or `terraform/vm-admin-password.txt`.
- The VM admin password is generated by Terraform and stored in
  `terraform/vm-admin-password.txt` (0600); it is also in local state.
- `enable_application_gateway = false` until the AGW frontend certificate exists in
  Key Vault; set it to `true` in a later apply (T3).
- A single B4ms node is low cost but not HA: use the `values-dev.yaml` Kong profile
  (1 replica). The prod 3-replica/PDB/anti-affinity profile needs more nodes.
- `aks_authorized_ip_ranges = []` leaves the public AKS API unrestricted; add your
  public IP/32 to restrict it.

## Security properties enforced by this layer

- Backend TLS verification cannot be disabled: `BackendTLSPolicy` sets
  `validation.hostname` and `caCertificateRefs`; there is no `tls-verify: false`
  anywhere. If the policy is missing or not `Accepted`, the deployment fails.
- The deployment asserts the **actual Kong runtime** configuration through the Admin
  API (`protocol=https`, `tls_verify=true`, exact targets, HTTPS health checks) and
  fails on mismatch; Kubernetes object creation alone is not treated as success.
- Kong never sees VM private keys: only the public CA certificate is mounted from
  Key Vault.
- Key Vault RBAC is least-privilege: only the Kong CSI workload identity and the
  optional AGW identity receive `Key Vault Secrets User`. The AKS Key Vault
  provider add-on identity is intentionally not granted any Key Vault role because
  the `SecretProviderClass` uses workload identity.
- VM private keys are generated on each VM and never leave it; only the public
  leaf+chain certificate is stored in Key Vault. The systemd service runs as a
  dedicated `hello` user with a 0600 keystore/env file.
- CSI sync is proven, not assumed: install waits for a gateway pod to mount the
  SecretProviderClass, `SecretProviderClassPodStatus.mounted=true`, and a synced
  Secret containing `ca.crt` + `id`; failure prints pod/CSI diagnostics.
- Active HTTPS health checks verify the same private CA: `values-csi.yaml` adds
  `/etc/kong/trust/ca.crt` to `lua_ssl_trusted_certificate` (Kong Service
  `ca_certificates` do not apply to health checks).
- Admin API (8444) is headless/ClusterIP and not exposed outside the cluster. The
  `network-policy.yaml` manifest is applied and AKS is configured with
  `network_policy = "azure"`, so the policy is enforced. Do not
  create a public Service for the admin listener.
- Version pins are explicit; no `latest` tags and no unpinned CRDs.
- Scripts are idempotent (`helm upgrade --install`, server-side apply, checksum-gated
  rollout).

## Honest limitations

- Kong OSS has **no official OIDC plugin**; Entra ID SSO is deferred by decision.
- KIC still skips verification of Kong's self-signed **Admin API** certificate
  (`kong_admin_tls_skip_verify: true`). That hop is headless/ClusterIP and not
  publicly exposed; AKS network policy enforcement is disabled by request. Phase 9
  replaces the admin certificate with a private-CA one. Backend TLS verification is
  never disabled.
- Key Vault CSI rotation does not reload Kong's upstream trust; use
  `reload-kong-trust.sh` after any CA rotation (checksum → rollout).
- `GatewayAlpha=true` is required in KIC for `BackendTLSPolicy`; it is set in
  `helm/values.yaml`.
- No cluster was available here: Helm rendering, CRD schema checks, shell syntax and
  the Java tests were validated locally, but `wait_for_csi_secret`, the fail-closed
  policy checks and `validate-kong.sh` have not been executed against a live AKS
  cluster in this increment.
- The Terraform configuration passes `terraform fmt -check` and `terraform validate`;
  no `plan`/`apply` was run because no Azure credentials/cluster are available here.
  AKS version availability in the target region must still be confirmed on the first plan.
- The `certificates/` and `vm/` scripts were exercised end to end against a temporary
  prefix (Root CA, CSRs, signed certificates, PKCS#12 keystore, systemd unit) and the
  keystore was used to start the Java app. `systemctl`, real VM users/ownership and
  the `az keyvault` upload/download paths were not executed on live VMs.

## Next phases

- First live `terraform plan/apply` — done.
- CA/VM/AGW/Kong certificates and Kong installation — done.
- Application Gateway and HTTP→HTTPS redirect — done.
- Remaining: CA renewal automation, Entra ID SSO, CI and the full validation suite.

See `helm/README.md` for the rendered topology, TLS verification details and
troubleshooting table.
