# KONG.md — Kong Gateway architecture, setup and request flow

> **Audience:** a future AI agent or engineer who needs to understand or operate
> the Kong layer without re-reading the whole conversation.
>
> Read `AGENT_HANDOFF.md` first for the live state and start-here checklist.
> Certificates are documented separately in `CERTIFICATES.md`.

## Current live state

| Item | Value |
|---|---|
| Namespace / release | `kong` / `kong` |
| Chart | `kong/ingress` **0.24.0** |
| Kong Gateway image | `kong:3.9.4` |
| KIC image | `kong/kubernetes-ingress-controller:3.5.14` |
| Gateway API CRDs | **v1.3.0 experimental** |
| Gateway address | `10.20.1.250` (internal Azure LB) |
| Public entry point | AGW `20.119.58.31` |
| Public hostname | `fe.internal.example.com` |
| Backend hostname | `be.internal.example.com` |
| Backend targets | `10.20.2.51:8100`, `10.20.2.52:8100` |
| DB mode | DB-less (`database=off`) |
| Replicas (dev) | 1 |
| Admin API | `kong-gateway-admin:8444` (headless, internal only) |
| Status listener | `:8100` inside the gateway pod |

---

## 1. What Kong is made of

| Layer | Component | Responsibility |
|---|---|---|
| Data plane | `Deployment/kong-gateway` | Terminates TLS, routes, load-balances, runs health checks |
| Control plane | `Deployment/kong-controller` (KIC) | Watches Gateway API/K8s, translates to Kong config, pushes to Admin API |
| Config API | `Service/kong-gateway-admin` (headless, 8444) | KIC and `validate-kong.sh` use it |
| Status | `:8100` | Readiness/liveness probes |
| Public/internal LB | `Service/kong-gateway-proxy` | Azure Standard LB, static `10.20.1.250`, 80→8000, 443→8443 |
| Gateway API | `GatewayClass`, `Gateway`, `HTTPRoute`, `BackendTLSPolicy` | Routing and TLS policy |
| Kong CRDs | `KongUpstreamPolicy`, `KongPlugin`, ... | Kong-specific behaviour |
| Secrets | CSI + Key Vault | CA material for backend verification |
| Front door | Application Gateway | Public TLS + HTTP→HTTPS redirect |

Terraform creates the platform (AKS, VNet, Key Vault, identities, CSI add-on).
Terraform does **not** create Kong. Helm installs Kong; Gateway API manifests
configure it.

---

## 2. How it is installed

1. Terraform:
   - AKS with OIDC + workload identity
   - Key Vault CSI provider add-on
   - control-plane + kubelet UAMIs
   - Kong CSI UAMI `id-kong-csi-dev`
   - federated credential subject `system:serviceaccount:kong:kong-gateway`
2. Key Vault CA secrets:
   - `pairs-monitor-root-ca`
   - `pairs-monitor-root-ca-id`
3. Kubernetes listener secret:
   - `kong-proxy-tls` in namespace `kong`
4. Helm:
   ```bash
   KONG_CHART_TGZ=$PWD/.cache/ingress-0.24.0.tgz \
     bash scripts/kong-install.sh --env dev
   ```
5. Apply Gateway API resources:
   ```bash
   bash scripts/apply-kong-resources.sh --env dev
   ```
6. Validate:
   ```bash
   bash scripts/validate-kong.sh --config config/config.yaml
   ```

`deploy.sh --phase kong` wraps steps 4–6.

### Offline fallback

If GitHub returns 504:

```bash
mkdir -p .cache
curl -fL --retry 5 -o .cache/ingress-0.24.0.tgz \
  "https://github.com/Kong/charts/releases/download/ingress-0.24.0/ingress-0.24.0.tgz"
curl -fL --retry 5 -o .cache/gateway-api-v1.3.0-experimental.yaml \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml"
```

`kong-install.sh` uses `.cache/gateway-api-${version}-experimental.yaml` when
present and `KONG_CHART_TGZ` for the chart.

---

## 3. Helm values

| File | Purpose |
|---|---|
| `helm/values.yaml` | 3 replicas, DB-less, admin TLS, proxy, PDB, zone spreading, probes, graceful shutdown |
| `helm/values-dev.yaml` | 1 replica, internal Azure LB, static IP |
| `helm/values-prod.yaml` | 3 replicas, anti-affinity, PDB, larger resources |
| `helm/values-csi.yaml` | CSI volume `/etc/kong/trust`, `lua_ssl_trusted_certificate`, workload-identity pod label |

Important values already fixed:

```yaml
gateway:
  env:
    database: "off"
    router_flavor: "traditional"
    proxy_listen: "0.0.0.0:8000, [::]:8000, 0.0.0.0:8443 http2 ssl, [::]:8443 http2 ssl"
    ssl_protocols: "TLSv1.2 TLSv1.3"
    ssl_ciphers: "..."
    headers: "latency_tokens,X-Kong-Request-Id"
  deployment:
    serviceAccount:
      create: true
      name: kong-gateway
```

`values-csi.yaml` adds:

```yaml
gateway:
  podLabels:
    azure.workload.identity/use: "true"
  env:
    lua_ssl_trusted_certificate: "system,/etc/kong/trust/ca.crt"
  deployment:
    userDefinedVolumes:
      - name: pairs-monitor-ca
        csi:
          driver: secrets-store.csi.k8s.io
          volumeAttributes:
            secretProviderClass: pairs-monitor-ca
    userDefinedVolumeMounts:
      - name: pairs-monitor-ca
        mountPath: /etc/kong/trust
```

**Do not remove the `proxy_listen` override.** The chart default leaves the IPv6
8443 listener without `ssl`, which makes Kong’s router treat 8443 as plaintext
and lets HTTP-only routes match HTTPS requests.

---

## 4. Kubernetes object map

```text
GatewayClass/kong  (unmanaged)
  └── Gateway/pairs-monitor-gateway
        ├── listener https :443
        │     hostname: fe.internal.example.com
        │     protocol: HTTPS
        │     certificateRefs: Secret/kong-proxy-tls
        ├── listener http :80
        │     (no HTTPRoute; AGW owns public HTTP→HTTPS)
        │
        └── HTTPRoute/pairs-monitor
              hostname: fe.internal.example.com
              path: /
              annotation: konghq.com/preserve-host: "false"
              backendRef: Service/pairs-monitor-backend:8100
                    │
                    ├── Service/pairs-monitor-backend
                    │     selector-less
                    │     konghq.com/host-header: be.internal.example.com
                    │     konghq.com/upstream-policy: pairs-monitor-backend-policy
                    │
                    ├── EndpointSlice/pairs-monitor-backend-vms
                    │     10.20.2.51:8100
                    │     10.20.2.52:8100
                    │
                    ├── BackendTLSPolicy/pairs-monitor-backend-tls
                    │     targetRef: Service/pairs-monitor-backend
                    │     validation.hostname: be.internal.example.com
                    │     caCertificateRefs: Secret/pairs-monitor-ca
                    │     tls-verify-depth: "1"
                    │
                    └── KongUpstreamPolicy/pairs-monitor-backend-policy
                          algorithm: round-robin
                          active: HTTPS /health
                          SNI: be.internal.example.com
                          verify certificate: true
```

---

## 5. How KIC translates Kubernetes to Kong

| Kubernetes | Kong entity/field |
|---|---|
| `Gateway` listener | listener |
| `Secret/kong-proxy-tls` | `certificate` (SNI `fe.internal.example.com`) |
| `HTTPRoute` | `route` |
| `Service/pairs-monitor-backend` | `service` (`httproute.kong.pairs-monitor.0`) |
| `EndpointSlice` | `upstream` targets |
| `BackendTLSPolicy` | service `protocol=https`, `tls_verify=true`, `ca_certificates`, `host_header` |
| `KongUpstreamPolicy` | upstream algorithm + health checks |
| `Secret/pairs-monitor-ca` | `ca_certificates` entity + stable UUID |

Resulting Kong Service:

```json
{
  "name": "httproute.kong.pairs-monitor.0",
  "protocol": "https",
  "port": 8100,
  "tls_verify": true,
  "tls_verify_depth": 1,
  "ca_certificates": ["7d29d90f-ba50-4830-99dd-5e4b209ce2dc"],
  "host": "httproute.kong.pairs-monitor.0"
}
```

Resulting Kong Upstream:

```json
{
  "name": "httproute.kong.pairs-monitor.0",
  "host_header": "be.internal.example.com",
  "algorithm": "round-robin",
  "healthchecks": {
    "active": {
      "type": "https",
      "http_path": "/health",
      "https_sni": "be.internal.example.com",
      "https_verify_certificate": true
    }
  }
}
```

Targets:

```text
10.20.2.51:8100
10.20.2.52:8100
```

---

## 6. Request flow

### Client → AGW

1. Client resolves `fe.internal.example.com` (hosts file) to `20.119.58.31`.
2. TLS to AGW; AGW presents `agw-frontend` (`fe`).
3. Client verifies with the private root CA.

### AGW → Kong

4. AGW forwards to `10.20.1.250:443`.
5. Protocol HTTPS, host name `fe.internal.example.com`, trusted root
   `pairs-monitor-root-ca`.
6. AGW verifies the Kong listener cert (`kong-proxy-tls`, `fe`).

### Kong routing

7. Kong terminates TLS on `8443` with `kong-proxy-tls`.
8. Router matches Gateway HTTPS listener + `HTTPRoute/pairs-monitor`
   (host `fe`, path `/`).
9. Route forwards to Kong Service `httproute.kong.pairs-monitor.0`.

### Kong → VM

10. Kong picks `10.20.2.51:8100` or `10.20.2.52:8100` (round-robin).
11. New TLS connection to the VM.
12. SNI `be.internal.example.com`.
13. VM presents leaf `be.internal.example.com` + chain.
14. Kong verifies chain → `pairs-monitor-ca`, SAN `be`, depth 1, validity.
15. Kong sends `GET /health` with `Host: be.internal.example.com`.
16. Java app returns JSON.
17. Kong → AGW → client.

If a target is unhealthy, Kong removes it from rotation.

---

## 7. CA / CSI / workload identity

```text
Key Vault
  pairs-monitor-root-ca      (public PEM)
  pairs-monitor-root-ca-id   (UUID 7d29…)
        │
        │ AKS Secrets Store CSI driver
        │ SA kong/kong-gateway → UAMI id-kong-csi-dev
        │ UAMI has Key Vault Secrets User
        ▼
SecretProviderClass/pairs-monitor-ca
        │
        ▼
Secret/pairs-monitor-ca
  ca.crt
  id
        │
        ▼
BackendTLSPolicy → Kong Service
```

The CSI volume is also mounted at `/etc/kong/trust` so active HTTPS health
checks can verify the VM cert.

KIC labels the synced Secret `konghq.com/ca-cert=true` and annotates
`kubernetes.io/ingress.class=kong`.

---

## 8. Ports

| Port | Purpose | Exposure |
|---|---|---|
| 8000 | HTTP proxy | Internal LB `10.20.1.250:80` |
| 8443 | HTTPS proxy | Internal LB `10.20.1.250:443` |
| 8444 | Admin API | Headless `kong-gateway-admin`, internal |
| 8100 | Status/readiness | Pod only |
| 10254/10255 | KIC health/metrics | ClusterIP |
| 8080 | KIC validation webhook | ClusterIP |

The VM app also uses 8100, but that is a different host/network.

---

## 9. Validation

```bash
cd /mnt/d/gitclone/appjava/infra/kong-azure-vm-gateway
export PATH="$HOME/bin:$PATH"
bash scripts/validate-kong.sh --config config/config.yaml
```

Checks:

- Kong Service `protocol=https`
- `tls_verify=true`, `tls_verify_depth=1`
- CA UUID present
- upstream targets exactly the two VM IPs
- `host_header=be.internal.example.com`
- active HTTPS health checks with SNI + verification
- Kong CA entity SHA-256 matches the Kubernetes `ca.crt`
- both targets `HEALTHY`

`validate-kong.sh` finds the KIC-named service (`httproute.kong.pairs-monitor.0`)
by its `k8s-name:pairs-monitor-backend` tag.

---

## 10. Inspect / troubleshoot

```bash
kubectl get all -n kong
kubectl get gateway,httproute,backendtlspolicy,kongupstreampolicy,secretproviderclass -n kong
kubectl get svc -n kong
kubectl logs -n kong deploy/kong-controller --tail=100
kubectl logs -n kong deploy/kong-gateway -c proxy --tail=100
```

Admin API:

```bash
kubectl -n kong port-forward deploy/kong-gateway 18444:8444
curl -sk https://127.0.0.1:18444/services | python3 -m json.tool
curl -sk https://127.0.0.1:18444/upstreams | python3 -m json.tool
curl -sk https://127.0.0.1:18444/upstreams/<id>/health | python3 -m json.tool
```

Common errors:

| Symptom | Cause / fix |
|---|---|
| KIC cannot push config | Inspect controller logs; a bad entity returns HTTP 400 |
| 502 `certificate does not match be...` | `preserve-host` not false, or VM cert SAN wrong |
| 502 `unable to get local issuer certificate` | CA Secret missing/wrong, or VM cert not signed by the root |
| KIC rejects CA Secret | `id` key missing; use `pairs-monitor-root-ca-id` |
| HTTPS returns 301 to itself | Do not re-add the Kong HTTPRoute redirect; AGW owns HTTP→HTTPS |
| 8443 treated as HTTP | `proxy_listen` must include `ssl` on both IPv4 and IPv6 |
| Admin API exposed | `network_policy=azure` is enforced; keep the admin Service headless |

---

## 11. File map

| File | Purpose |
|---|---|
| `helm/values.yaml` | Base chart values |
| `helm/values-dev.yaml` | Dev profile (1 replica, internal LB) |
| `helm/values-prod.yaml` | Prod profile |
| `helm/values-csi.yaml` | CSI CA volume + workload identity |
| `helm/gateway.yaml` | GatewayClass + Gateway |
| `helm/httproute.yaml` | HTTPS route only |
| `helm/service.yaml` | Selector-less backend Service |
| `helm/endpointslice.yaml` | VM IPs |
| `helm/backend-tls-policy.yaml` | Kong → VM TLS policy |
| `helm/kong-upstream-policy.yaml` | Round-robin + health checks |
| `helm/secret-provider-class.yaml` | Key Vault CA sync |
| `helm/network-policy.yaml` | Admin API restriction |
| `scripts/kong-install.sh` | CRDs + Helm install/upgrade |
| `scripts/apply-kong-resources.sh` | Render/apply Gateway API resources |
| `scripts/reload-kong-trust.sh` | CA checksum → gateway rollout |
| `scripts/validate-kong.sh` | Runtime assertions |
| `scripts/deploy.sh` | One-shot Kong phase |

## 12. Do not change without reading the docs

- `konghq.com/preserve-host: "false"` on the HTTPRoute.
- `konghq.com/host-header: be.internal.example.com` on the Service.
- `proxy_listen` with `ssl` on both 8443 listeners.
- Do not re-add the Kong HTTP→HTTPS redirect route.
- Do not apply raw `helm/*.yaml` with `kubectl`; use `apply-kong-resources.sh`.
- Do not point the AGW backend at the VM IPs; it points at the Kong LB `10.20.1.250`.
