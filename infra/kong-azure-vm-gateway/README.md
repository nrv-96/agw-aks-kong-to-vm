# Kong Gateway on AKS for the VM-hosted application

Automated Kong Gateway in AKS in front of two Linux VMs, with Azure Private DNS,
a private root CA, Azure Key Vault / CSI trust distribution, HTTPS to the VMs
with full certificate verification, and (later) Application Gateway + Entra ID.

> **Status: phase 1 only.** This increment delivers the Kong Helm layer, the
> Gateway API/Service/TLS manifests, the install/upgrade/apply scripts and the
> configuration file. Terraform (Private DNS / Key Vault / identity),
> certificate issuance and VM installation, renewal automation, Application
> Gateway, Entra ID SSO, CI and the validation suites are **not implemented yet**.
> `./scripts/deploy.sh --phase all` fails on purpose instead of pretending they ran.

## Target architecture

```
Browser ──HTTPS examplefe.com──► Application Gateway ──HTTPS──► Kong (AKS)
                                                                 │
                                                    Entra ID OIDC (later)
                                                                 │
                                                    Kong upstream (HTTPS)
                                                     SNI pairs-monitor.be.com
                                                     CA   pairs-monitor-root-ca
                                                                 │
                                        ┌────────────────────────┴───────────────┐
                                     VM1 10.20.2.51:8100                    VM2 10.20.2.52:8100
                                     cert SAN pairs-monitor.be.com          cert SAN pairs-monitor.be.com
```

Two distinct identities, deliberately:

| Identity | Used for | Issued by |
| --- | --- | --- |
| `examplefe.com` | browser → Application Gateway → Kong listener | application certificate (phase 2/12) |
| `pairs-monitor.be.com` | Kong → VM TLS (SNI + hostname + chain verification) | private root CA (phase 2) |

Placeholder backends are `10.20.2.51` / `10.20.2.52`. The spec's `100.64.2.51/52`
cannot be used: Azure reserves `100.64.0.0/10` for CGNAT and rejects it in VNets.

## What exists now

```
kong-azure-vm-gateway/
├── config/config.yaml                  # single source of inputs + version pins
├── helm/
│   ├── values.yaml                     # base chart values (3 replicas, DB-less, PDB, probes)
│   ├── values-dev.yaml                 # 1 replica, ClusterIP (port-forward)
│   ├── values-prod.yaml                # internal Azure LB, anti-affinity, PDB 2
│   ├── values-csi.yaml                 # Key Vault CSI CA volume + health-check trust bundle
│   ├── gateway.yaml                    # GatewayClass + Gateway (HTTPS/HTTP listeners)
│   ├── httproute.yaml                  # HTTPS route + HTTP→HTTPS 301
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
│   └── install-vm-certificate.sh       # keystore + env + restart (runs on the VM)
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
│   └── deploy.sh                       # phase-1 entry point
└── README.md                           # this file
```

Not present yet: `terraform/`, `automation/`, `monitoring/`,
`.github/workflows/`, `config/schema.json` and the remaining validation
scripts listed in the specification.

## Pinned versions

| Component | Version |
| --- | --- |
| `kong/ingress` chart | `0.24.0` (subcharts `kong/kong` `3.2.0`) |
| Kong Gateway OSS image | `kong:3.9.4` |
| Kong Ingress Controller | `kong/kubernetes-ingress-controller:3.5.14` |
| Gateway API CRDs | `v1.3.0` **experimental** |
| Key Vault CSI provider | `1.8.2` (AKS managed add-on) |

`3.5.14` is the latest KIC 3.5 patch and its `go.mod` pins
`sigs.k8s.io/gateway-api v1.3.0`, which is why the CRD channel is 1.3.0
experimental. Bump `config/config.yaml` only after re-checking that matrix.

## Prerequisites

- `kubectl` 1.29+ pointed at the target cluster, `helm` 3.14+
- `yq` v4 (mikefarah), `envsubst` (gettext), `python3` (runtime validation), `bash` 4+
- `openssl` 1.1.1+ for the certificate scripts; `az` only for Key Vault upload/download
- On the VMs: Java 21, `systemd`, `openssl`, `curl`
- Azure access for later phases (the phase-1 scripts never call Azure)

The scripts run in WSL on this workstation; `yq` is installed at `~/bin/yq`.
On another machine install yq v4 (`winget install --id MikeFarah.yq` or
`choco install yq`) and ensure `python3` is available for `validate-kong.sh`.

## Quick start

```bash
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

Production uses `--env prod` (internal Azure LoadBalancer) and `kong-upgrade.sh`
requires `--yes` before applying anything.

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

# 2. On each VM: generate the private key + CSR. The key never leaves the VM.
./certificates/generate-vm-csr.sh --out-dir /etc/hello/csr --name vm1 \
  --cn pairs-monitor.be.com --san pairs-monitor.be.com
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
`https://pairs-monitor.be.com:8100/health` locally with the private CA.

### Phase-1 prerequisites you must supply

`apply-kong-resources.sh` fails fast unless Secret `kong-proxy-tls` exists in the
Kong namespace (certificate SAN must cover `application.public_hostname`) and the
`pairs-monitor-ca` CA Secret is present with both required keys. Until phase 2
issues real certificates, create a throwaway listener cert for lab testing:

```bash
openssl req -x509 -newkey rsa:3072 -nodes -days 7 \
  -subj "/CN=examplefe.com" -addext "subjectAltName=DNS:examplefe.com" \
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

## Security properties enforced by this layer

- Backend TLS verification cannot be disabled: `BackendTLSPolicy` sets
  `validation.hostname` and `caCertificateRefs`; there is no `tls-verify: false`
  anywhere. If the policy is missing or not `Accepted`, the deployment fails.
- The deployment asserts the **actual Kong runtime** configuration through the Admin
  API (`protocol=https`, `tls_verify=true`, exact targets, HTTPS health checks) and
  fails on mismatch; Kubernetes object creation alone is not treated as success.
- Kong never sees VM private keys: only the public CA certificate is mounted from
  Key Vault.
- VM private keys are generated on each VM and never leave it; only the public
  leaf+chain certificate is stored in Key Vault. The systemd service runs as a
  dedicated `hello` user with a 0600 keystore/env file.
- CSI sync is proven, not assumed: install waits for a gateway pod to mount the
  SecretProviderClass, `SecretProviderClassPodStatus.mounted=true`, and a synced
  Secret containing `ca.crt` + `id`; failure prints pod/CSI diagnostics.
- Active HTTPS health checks verify the same private CA: `values-csi.yaml` adds
  `/etc/kong/trust/ca.crt` to `lua_ssl_trusted_certificate` (Kong Service
  `ca_certificates` do not apply to health checks).
- Admin API (8444) is headless/ClusterIP and restricted to KIC pods by
  NetworkPolicy.
- Version pins are explicit; no `latest` tags and no unpinned CRDs.
- Scripts are idempotent (`helm upgrade --install`, server-side apply, checksum-gated
  rollout).

## Honest limitations

- Kong OSS has **no official OIDC plugin**; Entra ID SSO is deferred by decision.
- KIC still skips verification of Kong's self-signed **Admin API** certificate
  (`kong_admin_tls_skip_verify: true`). That hop is headless and
  NetworkPolicy-restricted; phase 9 replaces it with a private-CA admin
  certificate. Backend TLS verification is never disabled.
- Key Vault CSI rotation does not reload Kong's upstream trust; use
  `reload-kong-trust.sh` after any CA rotation (checksum → rollout).
- `GatewayAlpha=true` is required in KIC for `BackendTLSPolicy`; it is set in
  `helm/values.yaml`.
- No cluster was available here: Helm rendering, CRD schema checks, shell syntax and
  the Java tests were validated locally, but `wait_for_csi_secret`, the fail-closed
  policy checks and `validate-kong.sh` have not been executed against a live AKS
  cluster in this increment.
- The `certificates/` and `vm/` scripts were exercised end to end against a temporary
  prefix (Root CA, CSRs, signed certificates, PKCS#12 keystore, systemd unit) and the
  keystore was used to start the Java app. `systemctl`, real VM users/ownership and
  the `az keyvault` upload/download paths were not executed on live VMs.

## Next phases

1. Terraform: Private DNS zone/records/VNet links, Key Vault, workload identity.
2. Private CA + VM certificate issuance/installation, Key Vault storage.
3. Renewal automation, monitoring, full validation suite, CI.
4. Application Gateway integration and Entra ID SSO (needs an enterprise-grade
   OIDC path; Kong OSS alone cannot do it).

See `helm/README.md` for the rendered topology, TLS verification details and
troubleshooting table.
