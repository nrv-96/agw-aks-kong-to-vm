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
├── scripts/
│   ├── lib.sh                          # config loading + manifest rendering
│   ├── kong-install.sh                 # CRDs + Helm install (CSI-aware)
│   ├── kong-upgrade.sh                 # dry run, then gated --yes upgrade
│   ├── apply-kong-resources.sh         # render/apply Gateway API resources
│   ├── reload-kong-trust.sh            # CA checksum → gateway rollout
│   └── deploy.sh                       # phase-1 entry point
└── README.md                           # this file
```

Not present yet: `terraform/`, `certificates/`, `vm/`, `automation/`,
`monitoring/`, `.github/workflows/`, `config/schema.json` and the validation
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
- `yq` v4 (mikefarah), `envsubst` (gettext), `bash` 4+
- Azure access for later phases (the phase-1 scripts never call Azure)

`yq` is not installed on this workstation yet:

```powershell
winget install --id MikeFarah.yq
# or: choco install yq
```

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

# 5. One-shot phase-1 deploy (install + apply + trust reload)
./scripts/deploy.sh --config config/config.yaml --env dev
```

Production uses `--env prod` (internal Azure LoadBalancer) and `kong-upgrade.sh`
requires `--yes` before applying anything.

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
  anywhere. If `BackendTLSPolicy` is unavailable, the documented fallback uses
  the equivalent Service annotations.
- Kong never sees VM private keys: only the public CA certificate is mounted from
  Key Vault.
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
- No cluster was available here: Helm rendering and CRD schema checks were
  validated locally, but nothing was installed or validated against a live AKS
  cluster in this increment.

## Next phases

1. Terraform: Private DNS zone/records/VNet links, Key Vault, workload identity.
2. Private CA + VM certificate issuance/installation, Key Vault storage.
3. Renewal automation, monitoring, full validation suite, CI.
4. Application Gateway integration and Entra ID SSO (needs an enterprise-grade
   OIDC path; Kong OSS alone cannot do it).

See `helm/README.md` for the rendered topology, TLS verification details and
troubleshooting table.
