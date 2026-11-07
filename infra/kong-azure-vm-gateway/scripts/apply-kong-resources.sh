#!/usr/bin/env bash
# Apply the Kong Gateway API, backend, TLS-trust and network-policy manifests.
#
# Usage:
#   ./scripts/apply-kong-resources.sh [--env dev|prod] [--config FILE]
#                                     [--skip-csi] [--ca-timeout SECONDS]
#
# The manifests are rendered from config/config.yaml; do not apply the raw
# helm/*.yaml files directly.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ENV_NAME="prod"
SKIP_CSI="false"
CA_TIMEOUT="180"

usage() {
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="${2:?}"; shift 2 ;;
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    --skip-csi) SKIP_CSI="true"; shift ;;
    --ca-timeout) CA_TIMEOUT="${2:?}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_config
require_cmd kubectl
require_cmd envsubst
load_kong_config

log "namespace=${NAMESPACE} public=${PUBLIC_HOSTNAME} backend=${BACKEND_HOSTNAME}:${BACKEND_PORT}"
log "targets: ${VM1_IP}, ${VM2_IP}"

# --- prerequisite checks -----------------------------------------------------
kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 \
  || die "Gateway API CRDs are not installed; run ./scripts/kong-install.sh first"

if ! kubectl get crd backendtlspolicies.gateway.networking.k8s.io >/dev/null 2>&1; then
  die "BackendTLSPolicy CRD missing. Install Gateway API ${GATEWAY_API_CRD_VERSION} experimental CRDs (kong-install.sh does this)."
fi

BTLS_VERSIONS="$(kubectl get crd backendtlspolicies.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}')"
[[ "${BTLS_VERSIONS}" == *v1alpha3* ]] \
  || die "BackendTLSPolicy CRD does not serve v1alpha3 (served: ${BTLS_VERSIONS}); KIC 3.5 requires Gateway API 1.3 experimental CRDs"

if ! kubectl get secret "${PROXY_TLS_SECRET}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  die "proxy TLS secret '${PROXY_TLS_SECRET}' not found in namespace '${NAMESPACE}'.
Create it first (certificate SAN must contain ${PUBLIC_HOSTNAME}), e.g.:
  kubectl create secret tls ${PROXY_TLS_SECRET} -n ${NAMESPACE} --cert=kong-proxy.crt --key=kong-proxy.key"
fi

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# --- CSI / CA trust ----------------------------------------------------------
if [[ "${SKIP_CSI}" == "true" ]]; then
  warn "skipping SecretProviderClass by request; ${CA_SECRET_NAME} must exist already"
elif kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io >/dev/null 2>&1; then
  if [[ -z "${KEYVAULT_NAME}" || -z "${TENANT_ID}" || -z "${WORKLOAD_IDENTITY_CLIENT_ID}" ]]; then
    die "Key Vault CA sync needs azure.keyvault.name, azure.tenant_id and azure.keyvault.workload_identity_client_id in ${CONFIG_FILE} (or run with --skip-csi)"
  fi
  apply_manifest "${PROJECT_DIR}/helm/secret-provider-class.yaml"
else
  warn "Key Vault CSI driver CRD not found - enable the AKS add-on (phase 9). Skipping SecretProviderClass."
  SKIP_CSI="true"
fi

# --- CA secret: wait for CSI sync, then make it consumable by KIC ------------
if [[ "${SKIP_CSI}" != "true" ]]; then
  log "waiting up to ${CA_TIMEOUT}s for CSI to sync secret ${CA_SECRET_NAME}"
  elapsed=0
  until kubectl get secret "${CA_SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; do
    if (( elapsed >= CA_TIMEOUT )); then
      warn "secret ${CA_SECRET_NAME} not synced yet. The CSI driver only syncs while a pod mounting the volume is running."
      warn "Check: kubectl -n ${NAMESPACE} describe pod -l app.kubernetes.io/component=app"
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
fi

# KIC only consumes a CA Secret that is labelled for the kong ingress class AND
# contains both `ca.crt` (PEM) and `id` (the Kong ca_certificates entity UUID).
# Apply this to the CSI-synced Secret and to manually created ones (--skip-csi).
if kubectl get secret "${CA_SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  kubectl label secret "${CA_SECRET_NAME}" -n "${NAMESPACE}" konghq.com/ca-cert=true --overwrite >/dev/null
  kubectl annotate secret "${CA_SECRET_NAME}" -n "${NAMESPACE}" kubernetes.io/ingress.class=kong --overwrite >/dev/null

  ca_data="$(kubectl get secret "${CA_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
  id_data="$(kubectl get secret "${CA_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.id}' 2>/dev/null || true)"
  if [[ -z "${ca_data}" || -z "${id_data}" ]]; then
    die "CA secret ${CA_SECRET_NAME} must contain both 'ca.crt' (PEM) and 'id' (UUID) keys.
KIC reports a translation failure for CA secrets without 'id', so backend TLS never verifies.
With CSI, store the UUID in Key Vault secret '$(cfg .certificates.root_ca_id_name)' and re-apply the SecretProviderClass.
Without CSI, create the secret with: kubectl create secret generic ${CA_SECRET_NAME} -n ${NAMESPACE} \\
  --from-file=ca.crt=root-ca.crt --from-literal=id=<uuid>"
  fi

  # Kong entity IDs are UUIDs. A trailing newline in the Key Vault value would
  # produce an invalid ID, so reject it here with an actionable message.
  id_value="$(printf '%s' "${id_data}" | base64 -d 2>/dev/null || true)"
  if [[ ! "${id_value}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    die "CA secret ${CA_SECRET_NAME} key 'id' must be a UUID with no whitespace/trailing newline (got '${id_value}')"
  fi
  log "CA secret labelled for KIC (ca.crt + id ${id_value} present)"
else
  die "CA secret ${CA_SECRET_NAME} not found in ${NAMESPACE}; KIC cannot verify the VM certificates.
With CSI: enable the Secrets Store CSI driver and check the SecretProviderClass + Key Vault access.
Without CSI: kubectl create secret generic ${CA_SECRET_NAME} -n ${NAMESPACE} \\
  --from-file=ca.crt=root-ca.crt --from-literal=id=<uuid>"
fi

# --- Kong routing / backend --------------------------------------------------
apply_manifest "${PROJECT_DIR}/helm/service.yaml"
apply_manifest "${PROJECT_DIR}/helm/endpointslice.yaml"
apply_manifest "${PROJECT_DIR}/helm/kong-upstream-policy.yaml"
apply_manifest "${PROJECT_DIR}/helm/backend-tls-policy.yaml"
apply_manifest "${PROJECT_DIR}/helm/gateway.yaml"
apply_manifest "${PROJECT_DIR}/helm/httproute.yaml"
apply_manifest "${PROJECT_DIR}/helm/network-policy.yaml"

# --- status ------------------------------------------------------------------
kubectl_ns get service pairs-monitor-backend -o wide || true
kubectl_ns get endpointslice -l kubernetes.io/service-name=pairs-monitor-backend -o wide || true
kubectl_ns get gateway,httproute || true
kubectl_ns get backendtlspolicy || true

log "waiting for Gateway to be programmed"
kubectl wait --for=condition=Programmed "gateway/pairs-monitor-gateway" -n "${NAMESPACE}" --timeout=180s \
  || warn "Gateway not Programmed yet; inspect: kubectl -n ${NAMESPACE} describe gateway pairs-monitor-gateway"

# BackendTLSPolicy status has no top-level conditions in v1alpha3, only ancestors.
log "checking BackendTLSPolicy acceptance"
btls_status=""
for _ in $(seq 1 24); do
  btls_status="$(kubectl_ns get backendtlspolicy pairs-monitor-backend-tls \
    -o jsonpath='{.status.ancestors[*].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  if [[ "${btls_status}" == *True* ]]; then
    break
  fi
  sleep 5
done
if [[ "${btls_status}" == *True* ]]; then
  log "BackendTLSPolicy accepted - backend TLS verification is active"
else
  warn "BackendTLSPolicy not accepted yet (status='${btls_status}')."
  warn "Check: kubectl -n ${NAMESPACE} describe backendtlspolicy pairs-monitor-backend-tls"
  warn "Until accepted, Kong talks plaintext to the VM TLS port and requests fail (fail-closed)."
fi

log "resources applied. Next: ./scripts/reload-kong-trust.sh (after CA changes) and phase-2 validation scripts."
