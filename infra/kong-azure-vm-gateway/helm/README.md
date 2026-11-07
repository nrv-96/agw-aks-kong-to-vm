# Kong Helm layer (phase 1)

Deploys Kong Gateway (OSS) + Kong Ingress Controller with the official
`kong/ingress` chart, and the Gateway API / backend resources that front the two
Linux VMs over verified HTTPS.

## Pinned versions

| Component | Pin | Why |
| --- | --- | --- |
| `kong/ingress` chart | **0.24.0** | Latest chart; pins `kong/kong` 3.2.0 subcharts |
| Kong Gateway OSS | **`kong:3.9.4`** | Latest 3.9 patch published on Docker Hub; the 3.9 line is supported by KIC 3.5 |
| Kong Ingress Controller | **`kong/kubernetes-ingress-controller:3.5.14`** | Latest 3.5 patch; upstream `go.mod` pins `sigs.k8s.io/gateway-api v1.3.0` |
| Gateway API CRDs | **v1.3.0 (experimental channel)** | Exactly the version KIC 3.5.14 is built against; `BackendTLSPolicy` is served as `v1alpha3` |
| Azure Key Vault CSI provider | **1.8.2** | AKS managed add-on preferred (phase 9); this layer only ships the `SecretProviderClass` |

Upgrades are intentionally not automated to "latest": bump these pins in
`config/config.yaml` after checking the Kong KIC compatibility matrix, then run
`scripts/kong-upgrade.sh --dry-run` followed by `--yes`.

## Files

| File | Purpose |
| --- | --- |
| `values.yaml` | Shared chart values: 3 replicas, DB-less, admin TLS + headless Service, proxy 80/443, PDB, zone spreading, probes, graceful shutdown |
| `values-dev.yaml` | 1 replica, ClusterIP proxy (port-forward), no PDB |
| `values-prod.yaml` | Internal Azure LB annotations, anti-affinity, larger resources, PDB `minAvailable: 2` |
| `values-csi.yaml` | Key Vault CSI volume/mount for the CA trust store plus the health-check Lua trust bundle; added only when the driver exists |
| `gateway.yaml` | `GatewayClass` (unmanaged) + `Gateway` with HTTPS/HTTP listeners |
| `httproute.yaml` | HTTPS route to the backend Service + HTTP→HTTPS 301 redirect |
| `service.yaml` | Selector-less Service `pairs-monitor-backend` with Kong annotations |
| `endpointslice.yaml` | The two VM IPs as EndpointSlice targets (single registration mechanism) |
| `backend-tls-policy.yaml` | SNI + CA + hostname verification for the VM upstreams |
| `kong-upstream-policy.yaml` | Round-robin + active/passive HTTPS health checks |
| `secret-provider-class.yaml` | Key Vault → CSI → `pairs-monitor-ca` Secret (`ca.crt` + `id`) and `/etc/kong/trust` mount |
| `network-policy.yaml` | Admin API reachable only from KIC |

`helm/*.yaml` manifests contain `${TOKEN}` placeholders and are rendered from
`config/config.yaml` by `scripts/apply-kong-resources.sh`. Do not `kubectl apply`
them directly.

## Traffic and TLS flow

```
Browser ──HTTPS(examplefe.com)──► Application Gateway (phase 12)
                                   │ HTTPS, trusts private root CA
                                   ▼
                        Kong Gateway :443 (cert SAN examplefe.com)
                                   │ Gateway API HTTPRoute
                                   ▼
                        Service pairs-monitor-backend:8100
                          protocol=https, tls_verify=true
                          SNI + hostname = pairs-monitor.be.com
                          CA = pairs-monitor-ca (from Key Vault)
                                   │
                    ┌──────────────┴──────────────┐
                 VM1 10.20.2.51:8100          VM2 10.20.2.52:8100
                 cert SAN pairs-monitor.be.com (phase 2)
```

Two distinct identities are used on purpose:

- public: `examplefe.com`
- backend TLS: `pairs-monitor.be.com`

## Why BackendTLSPolicy

KIC 3.4+ supports upstream TLS verification through
`konghq.com/*` Service annotations or Gateway API `BackendTLSPolicy`. This layer
uses `BackendTLSPolicy` because it carries the SNI/hostname explicitly while the
targets are raw VM IPs:

```yaml
validation:
  hostname: pairs-monitor.be.com      # SNI + certificate identity
  caCertificateRefs: [Secret/pairs-monitor-ca]
options:
  tls-verify-depth: "1"               # leaf -> root
```

KIC 3.5.14 translates that policy into Kong Service settings: `protocol=https`,
`tls_verify=true`, `ca_certificates=<CA entity>`, `host_header=<hostname>` and
SNI from `validation.hostname`. `service.yaml` therefore intentionally carries no
`konghq.com/protocol` annotation: if the policy is missing, Kong stays on HTTP and
the TLS-only VM port rejects the request (fail closed) instead of silently
skipping verification. The apply script reports whether the policy reached the
`Accepted` condition.

Requirements:

- Gateway API **experimental** CRDs v1.3.0 (`BackendTLSPolicy` is `v1alpha3`)
- KIC feature gate `GatewayAlpha=true` (already set in `values.yaml`)
- CA Secret labelled `konghq.com/ca-cert=true` (CSI label + script annotation)
- CA Secret must contain **both** keys:
  - `ca.crt` - the PEM root certificate
  - `id` - a stable UUID used as the Kong `ca_certificates` entity ID

KIC 3.5.14 fails translation for labelled CA Secrets without `id`
(`invalid secret CA certificate: missing 'id' field in data`), and
`BackendTLSPolicy` then never becomes `Accepted`. Because the CSI driver can
only build the Secret from Key Vault objects, the UUID is stored as a second
Key Vault secret (`certificates.root_ca_id_name`, default
`pairs-monitor-root-ca-id`) and synced by the `SecretProviderClass`. Keep that
UUID stable for the lifetime of a root CA; use a **new** UUID when rotating the
root CA (that is what allows an overlap period later). Store the value without
a trailing newline.

### Fallback (only if BackendTLSPolicy is unavailable)

Annotate the Service and drop `backend-tls-policy.yaml`:

```yaml
konghq.com/protocol: https
konghq.com/tls-verify: "true"
konghq.com/tls-verify-depth: "1"
konghq.com/ca-certificates-secrets: pairs-monitor-ca
konghq.com/host-header: pairs-monitor.be.com
```

Do **not** enable both mechanisms for the same Service, and never set
`konghq.com/tls-verify: "false"`.

## Load balancing and health checks

`KongUpstreamPolicy` is attached with `konghq.com/upstream-policy`:

- `algorithm: round-robin`
- active HTTPS checks: `GET /health` on port 8100
- `httpsSni: pairs-monitor.be.com`, `httpsVerifyCertificate: true`
- healthy: 2 successes / 10s interval; unhealthy: 3 failures, 3 timeouts / 10s
- passive checks also enabled
- unhealthy targets are removed from rotation and re-added after recovery

Active HTTPS health checks use Kong's **global Lua trust store**, not the Kong
Service `ca_certificates`. `values-csi.yaml` therefore sets:

```yaml
gateway:
  env:
    lua_ssl_trusted_certificate: "system,/etc/kong/trust/ca.crt"
```

Kong resolves the comma-separated list at startup and builds a combined PEM
bundle; `system` keeps the public distro CAs, and the CSI-mounted private root CA
is appended. Without this, proxied requests would succeed but every health check
would fail certificate verification and both VMs would be marked unhealthy.
Dev installations without CSI do not set this variable; if you run without CSI in
an environment with real VM certificates, add the private CA to the data plane's
`lua_ssl_trusted_certificate` by another supported means.

The KongUpstreamPolicy CRD is `configuration.konghq.com/v1beta1`; all field
names above were validated against the CRD shipped in chart `kong/kong` 3.2.0.

## Key Vault objects used by this layer

| Key Vault secret | Content | Mounted file | Kubernetes key |
| --- | --- | --- | --- |
| `pairs-monitor-root-ca` | public root CA, PEM, no private key | `/etc/kong/trust/ca.crt` | `ca.crt` |
| `pairs-monitor-root-ca-id` | stable UUID (no trailing newline) | `/etc/kong/trust/id` | `id` |

The CSI driver mounts both files at `/etc/kong/trust` and syncs them into the
`pairs-monitor-ca` Secret. Only the public CA ever reaches Kong; VM private keys
are never stored here or mounted into the cluster.

## CSI sync ordering

CSI `secretObjects` are only materialized while a pod mounts the volume. The
scripts enforce the full chain instead of waiting blindly:

1. `kong-install.sh` applies the `SecretProviderClass` **before** Helm.
2. After `helm --wait`, `wait_for_csi_secret` checks that the gateway Deployment is
   Available, a running gateway pod mounts `pairs-monitor-ca`, the matching
   `SecretProviderClassPodStatus.status.mounted` is `true`, and the synced Secret
   contains `ca.crt` + `id`.
3. `apply-kong-resources.sh` repeats the check before applying `BackendTLSPolicy`.

On failure the helper prints the SPC, pod statuses, pod events and CSI driver pods
instead of timing out silently.

## CA rotation is not automatic

The CSI driver updates the mounted PEM and the synced Secret, but Kong does not
reliably reload the upstream trust store on file change. After a CA or backend
certificate rotation run:

```bash
./scripts/reload-kong-trust.sh
```

It checksums `pairs-monitor-ca`, annotates the gateway Deployment and waits for
the rolling restart, so KIC re-pushes the CA entity and Kong reloads it.

## Commands

```bash
# Render only
helm template kong kong/ingress --version 0.24.0 -n kong \
  -f helm/values.yaml -f helm/values-dev.yaml

# Render with the Key Vault CSI volume attached
helm template kong kong/ingress --version 0.24.0 -n kong \
  -f helm/values.yaml -f helm/values-prod.yaml -f helm/values-csi.yaml

# Install/reconcile Kong (installs Gateway API CRDs first if missing).
# CSI is auto-detected; --without-csi forces a release with no CA volume.
./scripts/kong-install.sh --env dev --dry-run
./scripts/kong-install.sh --env dev --without-csi

# Apply Gateway/Service/EndpointSlice/TLS policy manifests
./scripts/apply-kong-resources.sh --env dev --skip-csi

# After CA rotation
./scripts/reload-kong-trust.sh --force

# Runtime assertions against the Kong Admin API (fatal on mismatch)
./scripts/validate-kong.sh
```

`validate-kong.sh` port-forwards to the gateway pod and verifies the actual Kong
Service/Upstream: `protocol=https`, `tls_verify=true`, `tls_verify_depth=1`, the CA
entity matching the Secret, exactly the two VM targets, and the active HTTPS
health-check settings. It fails the deployment instead of trusting Kubernetes object
creation. Requires `python3`.

## Validation (phase-1 level)

```bash
# Preferred: runtime assertions (fatal on mismatch)
./scripts/validate-kong.sh

# Kubernetes-level inspection
kubectl -n kong get deploy,pods,svc
kubectl -n kong get gateway pairs-monitor-gateway -o yaml
kubectl -n kong get httproute
kubectl -n kong get endpointslice pairs-monitor-backend-vms -o yaml
kubectl -n kong get backendtlspolicy
kubectl -n kong get kongupstreampolicy

# CA Secret must expose both keys (ca.crt PEM + id UUID)
kubectl -n kong get secret pairs-monitor-ca -o jsonpath='{.data.id}' | base64 -d; echo
kubectl -n kong get secret pairs-monitor-ca -o jsonpath='{.data.ca\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -dates

# Health-check trust + header policy actually applied to the data plane
kubectl -n kong exec deploy/kong-gateway -- env \
  | grep -E 'KONG_LUA_SSL_TRUSTED_CERTIFICATE|KONG_HEADERS'

# Kong targets/upstreams (admin API via port-forward)
kubectl -n kong port-forward deploy/kong-gateway 8444:8444
curl -sk https://localhost:8444/upstreams | jq
curl -sk https://localhost:8444/upstreams/<id>/health | jq
```

Expected Kong upstream: protocol `https`, both VM IPs as targets, TLS
verification enabled, SNI `pairs-monitor.be.com`, health path `/health`.

## Dev bootstrap without phase 2 certificates

For a local smoke test only, create throwaway certs:

```bash
openssl req -x509 -newkey rsa:3072 -nodes -days 7 \
  -subj "/CN=examplefe.com" -addext "subjectAltName=DNS:examplefe.com" \
  -keyout kong-proxy.key -out kong-proxy.crt

kubectl create secret tls kong-proxy-tls -n kong \
  --cert=kong-proxy.crt --key=kong-proxy.key

# Stand-in CA secret so KIC has something to reference (no CSI in dev).
# KIC requires the 'id' key next to the PEM; use any UUID here.
kubectl create secret generic pairs-monitor-ca -n kong \
  --from-file=ca.crt=kong-proxy.crt \
  --from-literal=id="$(uuidgen | tr 'A-Z' 'a-z')"
kubectl label secret pairs-monitor-ca -n kong konghq.com/ca-cert=true --overwrite
./scripts/apply-kong-resources.sh --env dev --skip-csi
```

Backend HTTPS will keep failing verification until phase 2 issues certificates
with SAN `pairs-monitor.be.com` from the private root CA. That failure is the
correct, secure behaviour.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `BackendTLSPolicy` ignored | KIC env `CONTROLLER_FEATURE_GATES=GatewayAlpha=true`; CRD serves `v1alpha3` |
| Backend returns 502 with `upstream SSL certificate verify error` | VM cert SAN/chain wrong, CA Secret stale, or SNI mismatch |
| Both targets unhealthy while proxied requests still work | `KONG_LUA_SSL_TRUSTED_CERTIFICATE` missing `/etc/kong/trust/ca.crt`; the pod must have the CSI mount and `values-csi.yaml` |
| Kong has no targets | EndpointSlice labels `kubernetes.io/service-name=pairs-monitor-backend`; Service port name matches slice port name |
| CA Secret never appears | CSI add-on enabled; a gateway pod mounting `/etc/kong/trust` is running; workload identity has `get` on both Key Vault secrets |
| `wait_for_csi_secret` reports `mounted=true` missing | Workload identity, federated credential or Key Vault RBAC is wrong; inspect the pod and CSI driver logs printed by the helper |
| `validate-kong.sh` reports protocol/tls_verify mismatch | BackendTLSPolicy accepted but KIC has not reconciled/pushed config yet; inspect KIC logs |
| `BackendTLSPolicy` not Accepted, KIC logs `missing 'id' field` | CA Secret must contain `id` (UUID) in addition to `ca.crt`; fix the Key Vault `pairs-monitor-root-ca-id` object and restart the gateway pods |
| Gateway not Programmed | `kubectl -n kong describe gateway pairs-monitor-gateway`; listener cert Secret must exist |
| Admin API exposed | `network-policy.yaml` applied; admin Service type is ClusterIP/headless |
