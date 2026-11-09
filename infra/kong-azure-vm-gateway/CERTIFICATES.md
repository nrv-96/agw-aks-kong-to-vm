# CERTIFICATES.md — TLS inventory, creation and rotation

> **Audience:** a future AI agent or engineer. Read `AGENT_HANDOFF.md` first for
> live state. Kong architecture is in `KONG.md`.
>
> **Golden rules**
> - The root CA private key (`pki/root-ca.key`) never leaves the laptop.
> - VM private keys (`/etc/hello/csr/vmN.key`) never leave the VMs.
> - Key Vault stores public CA/leaf chains plus the AGW frontend certificate
>   (which necessarily contains its private key).
> - Never rotate a key by overwriting it without a backup and reissuing the
>   certificate.

## 1. Trust chain

One private root CA signs every server certificate:

```text
pki/root-ca.key  (private, laptop only)
        │
        ├── signs  AGW listener leaf      CN/SAN = fe.internal.example.com
        ├── signs  Kong listener leaf     CN/SAN = fe.internal.example.com
        ├── signs  vm1 leaf               CN/SAN = be.internal.example.com
        └── signs  vm2 leaf               CN/SAN = be.internal.example.com
```

| Hop | Server certificate | Verified by | Trust anchor |
|---|---|---|---|
| Client → AGW | `agw-frontend` (`fe`) | browser/curl | root CA on the client |
| AGW → Kong | Kong listener (`fe`) | AGW | AGW trusted root `pairs-monitor-root-ca` |
| Kong → VM | VM leaf (`be`) | Kong | K8s Secret `pairs-monitor-ca` |

This is **server-authentication TLS only**. Kong does not present a client
certificate to the VMs.

---

## 2. Certificate inventory

| Name | CN / SAN | Type | Private key location | Used by |
|---|---|---|---|---|
| Root CA `pairs-monitor-root-ca` | `CN=pairs-monitor-root-ca, O=pairs-monitor` | CA | laptop `pki/root-ca.key` | signs all leaves |
| `agw-frontend` | `fe.internal.example.com` | leaf + PFX | Key Vault certificate `agw-frontend`; laptop `pki/kong/agw-frontend.pfx` | AGW listener |
| Kong listener (`kong-proxy-tls`) | `fe.internal.example.com` | leaf | K8s Secret `kong-proxy-tls`; laptop `pki/kong/kong-proxy.key` | Kong listener |
| vm1 (`pairs-monitor-vm1-tls`) | `be.internal.example.com` | leaf + chain | VM `/etc/hello/csr/vm1.key`, `/etc/hello/tls/tls.key`, `keystore.p12` | Java app on vm1 |
| vm2 (`pairs-monitor-vm2-tls`) | `be.internal.example.com` | leaf + chain | VM `/etc/hello/csr/vm2.key`, `/etc/hello/tls/tls.key`, `keystore.p12` | Java app on vm2 |
| CA for Kong → VM (`pairs-monitor-ca`) | root CA | CA (public) | none | Kong `BackendTLSPolicy` |
| AGW trusted root | root CA | CA (public) | none | AGW backend verification |

Key Vault objects:

| Object | Kind | Content |
|---|---|---|
| `pairs-monitor-root-ca` | secret | public root CA PEM |
| `pairs-monitor-root-ca-id` | secret | UUID `7d29d90f-ba50-4830-99dd-5e4b209ce2dc` |
| `pairs-monitor-vm1-tls` | secret | vm1 public leaf + root chain |
| `pairs-monitor-vm2-tls` | secret | vm2 public leaf + root chain |
| `agw-frontend` | **certificate** | PFX, SAN `fe.internal.example.com`, private key included |

Kubernetes secrets:

| Secret | Keys | Content |
|---|---|---|
| `kong-proxy-tls` | `tls.crt`, `tls.key` | Kong listener leaf + private key |
| `pairs-monitor-ca` | `ca.crt`, `id` | public root CA + Kong CA entity UUID |

---

## 3. Storage map

| Material | Laptop | Azure / Kubernetes | VM |
|---|---|---|---|
| Root CA key | `pki/root-ca.key` | — | — |
| Root CA cert | `pki/root-ca.crt` | KV `pairs-monitor-root-ca`; K8s `pairs-monitor-ca`; AGW trusted root | `/etc/hello/tls/ca.crt` |
| Root CA UUID | `pki/root-ca.id` | KV `pairs-monitor-root-ca-id`; K8s `pairs-monitor-ca` | — |
| vm1 leaf | `pki/issued/vm1.crt` | KV `pairs-monitor-vm1-tls` | `/etc/hello/tls/tls.crt` |
| vm1 chain | `pki/issued/vm1-chain.pem` | KV `pairs-monitor-vm1-tls` | `/etc/hello/tls/chain.pem` |
| vm1 key | — | — | `/etc/hello/csr/vm1.key`, `/etc/hello/tls/tls.key`, `keystore.p12` |
| vm2 leaf/chain/key | same pattern | same pattern | same pattern |
| Keystore password | — | — | `/etc/hello/hello.env` (0600 root) |
| Kong listener leaf | `pki/kong/issued/kong-proxy.crt` | K8s `kong-proxy-tls` | — |
| Kong listener key | `pki/kong/kong-proxy.key` | K8s `kong-proxy-tls` | — |
| AGW frontend PFX | `pki/kong/agw-frontend.pfx` + `.pfx.password` | KV certificate `agw-frontend` | — |

The live `agw-frontend` was built by **reusing** the Kong listener leaf/key (same
`fe` SAN, same root). For a cleaner setup, create a separate `agw-frontend`
key/cert. The backend trust root is unaffected either way.

---

## 4. Root CA

### Create (laptop WSL)

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
bash certificates/create-root-ca.sh --out-dir ./pki
```

Produces:

| File | Description |
|---|---|
| `pki/root-ca.key` | 3072-bit RSA private key, 0600 |
| `pki/root-ca.crt` | self-signed CA certificate |
| `pki/root-ca.id` | stable UUID for the Kong CA entity |

Current values:

```text
Subject/Issuer: CN=pairs-monitor-root-ca, O=pairs-monitor
Validity:       2026-11-09 → 2036-11-06
SHA-256:        78:D9:72:53:94:9F:70:CF:82:FB:18:08:31:2E:E8:22:
                82:D1:65:4E:DE:EE:AC:57:50:3E:81:C0:2D:5C:2E:A4
UUID:           7d29d90f-ba50-4830-99dd-5e4b209ce2dc
```

### Upload the public CA + UUID

```bash
bash certificates/upload-ca-to-keyvault.sh --vault-name kv-pm-dev-ig8r
```

Requires the deploying user to have `Key Vault Secrets Officer` on the vault.
The script converts WSL paths with `wslpath -w` for the Windows `az` CLI.

---

## 5. VM certificates — step by step

### 5.1 Key + CSR on the VM

```bash
bash scripts/generate-vm-csrs.sh
```

Runs `certificates/generate-vm-csr.sh` on vm1/vm2 through Azure VM Run Command.

On each VM:

```text
/etc/hello/csr/vmN.key   private key, 0600, never leaves the VM
/etc/hello/csr/vmN.csr
```

CSR details:

```ini
CN = be.internal.example.com
O  = pairs-monitor
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:be.internal.example.com
```

Only the CSR is copied back:

```text
csr/vm1.csr
csr/vm2.csr
```

### 5.2 Sign on the laptop

```bash
bash certificates/issue-vm-certificates.sh \
  --csr-dir ./csr \
  --ca-cert ./pki/root-ca.crt \
  --ca-key ./pki/root-ca.key \
  --out-dir ./pki/issued \
  --upload-keyvault --vault-name kv-pm-dev-ig8r
```

Produces:

```text
pki/issued/vm1.crt
pki/issued/vm1-chain.pem   (leaf + root)
pki/issued/vm2.crt
pki/issued/vm2-chain.pem
```

Uploads public chains to Key Vault:

```text
pairs-monitor-vm1-tls
pairs-monitor-vm2-tls
```

### 5.3 Install on the VM and build the keystore

```bash
bash scripts/install-vm-app.sh
```

Runs `certificates/install-vm-certificate.sh` on each VM. It:

1. Validates chain/hostname/SAN/EKU/keyUsage/validity/key match.
2. Builds the PKCS#12 keystore:

   ```bash
   openssl pkcs12 -export \
     -inkey /etc/hello/csr/vmN.key \
     -in vmN.crt \
     -certfile vmN-chain.pem \
     -name hello-app \
     -out /etc/hello/tls/keystore.p12 \
     -passout env:TLS_KEYSTORE_PASSWORD
   ```

3. Installs:

   ```text
   /etc/hello/tls/tls.crt       0644 hello:hello
   /etc/hello/tls/chain.pem     0644 hello:hello
   /etc/hello/tls/ca.crt        0644 hello:hello
   /etc/hello/tls/tls.key       0600 hello:hello
   /etc/hello/tls/keystore.p12  0600 hello:hello
   ```

4. Writes `/etc/hello/hello.env`:

   ```ini
   PORT=8100
   TLS_KEYSTORE_PATH=/etc/hello/tls/keystore.p12
   TLS_KEYSTORE_PASSWORD=<generated>
   TLS_KEYSTORE_TYPE=PKCS12
   ```

5. Restarts `hello-app` and checks
   `https://be.internal.example.com:8100/health`.

The Java app loads the keystore and serves HTTPS on `0.0.0.0:8100`.

---

## 6. Kong listener certificate

The Gateway HTTPS listener needs `kong-proxy-tls` before
`apply-kong-resources.sh` runs.

### Create

```bash
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

Outputs:

```text
pki/kong/kong-proxy.key
pki/kong/issued/kong-proxy.crt
pki/kong/issued/kong-proxy-chain.pem
```

### Create the Kubernetes secret (leaf-only cert)

```bash
export PATH="$HOME/bin:$PATH"
kubectl create namespace kong --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret tls kong-proxy-tls -n kong \
  --cert=./pki/kong/issued/kong-proxy.crt \
  --key=./pki/kong/kong-proxy.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

The Gateway references it:

```yaml
tls:
  mode: Terminate
  certificateRefs:
    - kind: Secret
      name: kong-proxy-tls
```

### Why leaf-only

The K8s secret uses the leaf, not the chain. The client/AGW has the root as a
trust anchor. Using the chain in the secret caused Kong certificate entity
validation problems in this deployment.

---

## 7. AGW frontend certificate (`agw-frontend`)

AGW needs a Key Vault **certificate** (PFX), not a PEM secret.

### 7.1 Build the PFX

The live deployment reused the Kong listener leaf/key:

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

For a **separate** AGW certificate, generate a new key/CSR with CN/SAN
`fe.internal.example.com`, sign it with the root CA, and use
`pki/agw/agw-frontend.key` + `pki/agw/issued/agw-frontend.crt` in the PFX
instead.

### 7.2 Import into Key Vault

The user needs `Key Vault Certificates Officer` on the vault:

```powershell
$OID = az ad signed-in-user show --query id -o tsv
$KV  = az keyvault show -n kv-pm-dev-ig8r --query id -o tsv
az role assignment create `
  --assignee-object-id $OID `
  --assignee-principal-type User `
  --role "Key Vault Certificates Officer" `
  --scope $KV
```

```powershell
$pfx  = 'D:\gitclone\appjava\infra\kong-azure-vm-gateway\pki\kong\agw-frontend.pfx'
$pass = (Get-Content 'D:\gitclone\appjava\infra\kong-azure-vm-gateway\pki\kong\agw-frontend.pfx.password' -Raw).Trim()
az keyvault certificate import `
  --vault-name kv-pm-dev-ig8r `
  --name agw-frontend `
  --file $pfx `
  --password $pass
az keyvault certificate show --vault-name kv-pm-dev-ig8r --name agw-frontend --query sid -o tsv
```

Current `sid`:

```text
https://kv-pm-dev-ig8r.vault.azure.net/secrets/agw-frontend/e6bdbdd1bb154e52b84d7e1ea5333c39
```

### 7.3 Configure Terraform

`config/config.yaml`:

```yaml
agw:
  enabled: true
  certificate_secret_id: "https://kv-pm-dev-ig8r.vault.azure.net/secrets/agw-frontend/e6bdbdd1bb154e52b84d7e1ea5333c39"
```

Then:

```bash
bash scripts/terraform-config.sh
cd terraform && terraform plan && terraform apply
```

The AGW UAMI `id-agw-dev` has `Key Vault Secrets User` from Terraform, so it can
read the certificate.

---

## 8. AGW backend trusted root

This is **not** a new certificate. It is the public root CA:

```text
pki/root-ca.crt
```

Terraform uploads it to AGW:

```hcl
trusted_root_certificate {
  name = "pairs-monitor-root-ca"
  data = base64encode(file("${path.root}/${var.root_ca_cert_path}"))
}
```

with:

```hcl
root_ca_cert_path = "../pki/root-ca.crt"
```

AGW backend settings:

```text
Backend pool:        10.20.1.250 (Kong internal LB)
Protocol:            HTTPS
Port:                443
Host name:           fe.internal.example.com
Certificate issuer:  Private CA
Trusted root:        pairs-monitor-root-ca
```

The host name is `fe.internal.example.com` because **Kong** presents the `fe`
listener certificate on this hop. It is not `be.internal.example.com`; that is
the next hop (Kong → VM).

The AGW probe uses the same host and trusted root:

```text
HTTPS GET https://fe.internal.example.com/health
```

---

## 9. How each hop verifies

### Client → AGW

- Server cert: `agw-frontend` (`fe`).
- Client trusts: root CA installed in the OS/browser trust store.
- Hostname: `fe.internal.example.com`.

### AGW → Kong

- Server cert: `kong-proxy-tls` (`fe`).
- AGW trusts: `pairs-monitor-root-ca`.
- Hostname: `fe.internal.example.com`.
- Probe: `HTTPS /health`.

### Kong → VM

- Server cert: VM leaf (`be`).
- Kong trusts: `pairs-monitor-ca` (root CA + UUID).
- Hostname/SNI: `be.internal.example.com`.
- Depth: 1.
- Health check: `HTTPS /health`, verify cert.

---

## 10. Rotation

### VM leaf only (same root)

1. On the VM, generate a new key + CSR:

   ```bash
   bash certificates/generate-vm-csr.sh \
     --out-dir /etc/hello/csr --name vm1 \
     --cn be.internal.example.com --san be.internal.example.com --force
   ```

2. Copy `vm1.csr` to the laptop.
3. Sign:

   ```bash
   bash certificates/sign-vm-csr.sh \
     --csr ./csr/vm1.csr --name vm1 \
     --ca-cert ./pki/root-ca.crt --ca-key ./pki/root-ca.key \
     --out-dir ./pki/issued --hostname be.internal.example.com
   ```

4. Install on the VM:

   ```bash
   bash install-vm-certificate.sh \
     --cert vm1.crt --chain vm1-chain.pem --ca root-ca.crt \
     --key /etc/hello/csr/vm1.key --hostname be.internal.example.com
   ```

Kong needs no change: it trusts the root.

### Kong listener cert

1. Regenerate `pki/kong/kong-proxy.*` with the same CN/SAN.
2. Recreate `kong-proxy-tls` (leaf-only cert + key).
3. KIC picks up the secret change; no Helm upgrade required.

### AGW listener cert

1. Build a new PFX.
2. Import it as a **new version** of the `agw-frontend` Key Vault certificate.
3. Update `agw.certificate_secret_id` to the new versioned `sid`.
4. `terraform-config.sh` + `terraform apply`.

### Root CA rotation

This is a planned migration, not an in-place overwrite:

1. Create a new root CA with a new UUID.
2. Add the new CA alongside the old one in Key Vault and Kong.
3. Reissue all leaves (AGW, Kong listener, VMs) under the new root.
4. Roll AGW/Kong/app and keep both roots trusted during overlap.
5. Remove the old root and old leaves only after the overlap.

Never overwrite `pki/root-ca.key` or `pki/root-ca.id` without a full rollover
plan.

---

## 11. Verify

### Root CA / Key Vault

```powershell
az keyvault secret show --vault-name kv-pm-dev-ig8r --name pairs-monitor-root-ca --query "{name:name,enabled:attributes.enabled}" -o json
az keyvault secret show --vault-name kv-pm-dev-ig8r --name pairs-monitor-root-ca-id --query value -o tsv
az keyvault certificate show --vault-name kv-pm-dev-ig8r --name agw-frontend --query "{subject:policy.x509CertificateProperties.subject,san:policy.x509CertificateProperties.subjectAlternativeNames.dnsNames,sid:sid}" -o json
```

### VM cert

```bash
sudo openssl x509 -in /etc/hello/tls/tls.crt -noout -subject -issuer -dates -ext subjectAltName
sudo openssl pkcs12 -in /etc/hello/tls/keystore.p12 -noout -passin "pass:$(sed -n 's/^TLS_KEYSTORE_PASSWORD=//p' /etc/hello/hello.env)"
```

### Kong → VM TLS

```bash
openssl s_client -connect 10.20.2.51:8100 \
  -servername be.internal.example.com \
  -CAfile pki/root-ca.crt </dev/null
```

### AGW → Kong

```bash
curl -sS --cacert pki/root-ca.crt \
  --resolve fe.internal.example.com:443:20.119.58.31 \
  https://fe.internal.example.com/health
```

### Full runtime

```bash
bash scripts/validate-kong.sh --config config/config.yaml
```

---

## 12. Security rules

- Root CA private key: laptop only, 0600, never in Key Vault/chat/logs.
- VM private keys: VMs only; never copy them to the laptop or Key Vault.
- Key Vault stores public CA/leaf chains plus the AGW certificate (private key
  required by AGW).
- The Kong listener private key is in the `kong-proxy-tls` Secret; it is required
  for TLS termination.
- The AGW PFX password is only for import; store `*.pfx.password` with 0600 and
  never commit it.
- Use `Key Vault Secrets Officer` for secret uploads and
  `Key Vault Certificates Officer` for certificate imports; do not grant wider
  roles.
- Keep the AGW UAMI and Kong CSI UAMI at `Key Vault Secrets User`.
- The AKS add-on identity is intentionally **not** granted Key Vault access.

---

## 13. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ForbiddenByRbac` uploading CA | Assign `Key Vault Secrets Officer`; wait 1–3 min |
| `ForbiddenByRbac` importing certificate | Assign `Key Vault Certificates Officer` |
| `file not found` when uploading | Windows `az` needs a Windows path; scripts use `wslpath -w` |
| AGW cannot read cert | AGW UAMI needs `Key Vault Secrets User`; check `agw_kv` |
| Kong 502 `certificate does not match "be"` | VM cert SAN wrong, or Kong uses `fe` as SNI (`preserve-host`) |
| Kong 502 `unable to get local issuer` | VM cert not signed by `pairs-monitor-root-ca`, or CA Secret wrong |
| KIC rejects CA Secret | Missing `id` UUID key in `pairs-monitor-ca` |
| `hello-app` cannot read keystore | `/etc/hello` must be traversable by the `hello` group (0750) |
| Keystore password error | `TLS_KEYSTORE_PASSWORD` in `hello.env` must match the keystore |
| Chain validation fails | Use leaf → root; `tls-verify-depth: "1"` |
| AGW HTTPS 301 loop | Do not re-add the Kong redirect route; AGW owns HTTP→HTTPS |
| AGW cert import error | Must be a PFX/Key Vault **certificate**, not a PEM secret |

## 14. File map

| Path | Purpose |
|---|---|
| `pki/root-ca.key` | root CA private key — never upload |
| `pki/root-ca.crt` | root CA public cert |
| `pki/root-ca.id` | root CA UUID |
| `pki/issued/vm1.crt` | vm1 leaf |
| `pki/issued/vm1-chain.pem` | vm1 leaf + root |
| `pki/issued/vm2.crt` | vm2 leaf |
| `pki/issued/vm2-chain.pem` | vm2 leaf + root |
| `pki/kong/kong-proxy.key` | Kong listener private key |
| `pki/kong/issued/kong-proxy.crt` | Kong listener leaf |
| `pki/kong/agw-frontend.pfx` | AGW listener PFX |
| `pki/kong/agw-frontend.pfx.password` | PFX import password, 0600 |
| `csr/vm1.csr`, `csr/vm2.csr` | public CSRs |
| `certificates/create-root-ca.sh` | create root CA |
| `certificates/upload-ca-to-keyvault.sh` | upload CA + UUID |
| `certificates/generate-vm-csr.sh` | VM key + CSR |
| `certificates/issue-vm-certificates.sh` | sign all VM CSRs |
| `certificates/install-vm-certificate.sh` | install cert + keystore on VM |
| `certificates/validate-certificate.sh` | cert checks |
| `scripts/generate-vm-csrs.sh` | run CSR generation on both VMs |
| `scripts/install-vm-app.sh` | run app + cert install on both VMs |
