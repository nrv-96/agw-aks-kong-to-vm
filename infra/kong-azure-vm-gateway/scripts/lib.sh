#!/usr/bin/env bash
# Shared helpers for the Kong/AKS automation scripts.
# Requires: bash 4+, yq v4 (mikefarah).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_DIR}/config/config.yaml}"

# SecretProviderClass that materializes the backend CA Secret.
CA_SPC_NAME="${CA_SPC_NAME:-pairs-monitor-ca}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
warn() { log "WARN: $*"; }
die() { log "ERROR: $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_config() {
  [[ -f "${CONFIG_FILE}" ]] || die "config file not found: ${CONFIG_FILE}"
  require_cmd yq
}

# cfg <yq-expression> - raw value from config.yaml
cfg() {
  yq -r "$1" "${CONFIG_FILE}"
}

# cfg_required <yq-expression> - fails when the value is empty or a placeholder
cfg_required() {
  local value
  value="$(cfg "$1")"
  if [[ -z "${value}" || "${value}" == "null" || "${value}" == "<INPUT>" ]]; then
    die "missing required config value: $1 (${CONFIG_FILE})"
  fi
  printf '%s' "${value}"
}

# cfg_optional <yq-expression> - empty string when unset or still a placeholder
cfg_optional() {
  local value
  value="$(cfg "$1")"
  if [[ "${value}" == "null" || "${value}" == "<INPUT>" ]]; then
    value=""
  fi
  printf '%s' "${value}"
}

# load_kong_config - exports the values used to render helm/*.yaml manifests.
load_kong_config() {
  NAMESPACE="$(cfg_required '.kong.namespace')"
  RELEASE_NAME="$(cfg_required '.kong.release_name')"
  PUBLIC_HOSTNAME="$(cfg_required '.application.public_hostname')"
  BACKEND_HOSTNAME="$(cfg_required '.application.backend_hostname')"
  BACKEND_PORT="$(cfg_required '.application.port')"
  HEALTH_PATH="$(cfg_required '.application.health_endpoint')"
  KONG_CHART_VERSION="$(cfg_required '.kong.chart_version')"
  KONG_GATEWAY_IMAGE="$(cfg_required '.kong.gateway_image')"
  KONG_GATEWAY_TAG="$(cfg_required '.kong.gateway_image_tag')"
  KIC_TAG="$(cfg_required '.kong.ingress_controller_image_tag')"
  GATEWAY_API_CRD_VERSION="$(cfg_required '.kong.gateway_api_crd_version')"
  INTERNAL_LB_IP="$(cfg_required '.kong.internal_lb_ip')"
  PROXY_TLS_SECRET="$(cfg_required '.kong.proxy_tls_secret_name')"
  CA_SECRET_NAME="$(cfg_required '.kong.ca_secret_name')"
  ROOT_CA_OBJECT="$(cfg_required '.certificates.root_ca_name')"
  ROOT_CA_ID_OBJECT="$(cfg_required '.certificates.root_ca_id_name')"

  # Key Vault inputs are only needed when the CSI-backed CA Secret is used.
  KEYVAULT_NAME="$(cfg_optional '.azure.keyvault.name')"
  TENANT_ID="$(cfg_optional '.azure.tenant_id')"
  WORKLOAD_IDENTITY_CLIENT_ID="$(cfg_optional '.azure.keyvault.workload_identity_client_id')"

  VM1_IP="$(yq -r '.backends[0].private_ip' "${CONFIG_FILE}")"
  VM2_IP="$(yq -r '.backends[1].private_ip' "${CONFIG_FILE}")"
  [[ "${VM1_IP}" != "null" && "${VM2_IP}" != "null" ]] || die "config must define two backends"

  # envsubst reads the process environment, not shell-local variables.
  export NAMESPACE RELEASE_NAME PUBLIC_HOSTNAME BACKEND_HOSTNAME BACKEND_PORT \
    HEALTH_PATH KONG_CHART_VERSION KONG_GATEWAY_IMAGE KONG_GATEWAY_TAG KIC_TAG \
    GATEWAY_API_CRD_VERSION PROXY_TLS_SECRET CA_SECRET_NAME KEYVAULT_NAME \
    TENANT_ID ROOT_CA_OBJECT ROOT_CA_ID_OBJECT VM1_IP VM2_IP WORKLOAD_IDENTITY_CLIENT_ID \
    INTERNAL_LB_IP
}

# render <file> - substitute the manifest token set from config.yaml.
render_manifest() {
  require_cmd envsubst
  envsubst \
    '${NAMESPACE} ${RELEASE_NAME} ${PUBLIC_HOSTNAME} ${BACKEND_HOSTNAME} ${BACKEND_PORT} ${HEALTH_PATH} ${VM1_IP} ${VM2_IP} ${PROXY_TLS_SECRET} ${CA_SECRET_NAME} ${KEYVAULT_NAME} ${TENANT_ID} ${WORKLOAD_IDENTITY_CLIENT_ID} ${ROOT_CA_OBJECT} ${ROOT_CA_ID_OBJECT}' \
    < "$1"
}

# apply_manifest <file> - render and server-side apply one manifest.
apply_manifest() {
  local file="$1"
  log "applying $(basename "$file")"
  render_manifest "$file" | kubectl apply --server-side --field-manager=pairs-monitor-automation -f -
}

kubectl_ns() {
  kubectl --namespace "${NAMESPACE}" "$@"
}

# csi_diagnostics - print the artifacts needed to debug a stuck CSI sync.
csi_diagnostics() {
  {
    echo "--- SecretProviderClass ${CA_SPC_NAME} ---"
    kubectl_ns get secretproviderclass "${CA_SPC_NAME}" -o yaml || true
    echo "--- SecretProviderClassPodStatuses ---"
    kubectl_ns get secretproviderclasspodstatuses -o wide || true
    echo "--- gateway pods ---"
    kubectl_ns describe pods \
      -l "app.kubernetes.io/instance=${RELEASE_NAME},app.kubernetes.io/name=gateway" || true
    echo "--- recent events ---"
    kubectl_ns get events --sort-by=.lastTimestamp | tail -n 30 || true
    echo "--- CSI driver pods ---"
    kubectl get pods -A -l app=secrets-store-csi-driver -o wide || true
    kubectl get pods -A -l app=secrets-store-csi-driver-provider-azure -o wide || true
  } >&2
}

# wait_for_csi_secret [timeout-seconds]
#
# Proves the full CSI sync chain before the CA Secret is consumed:
#   1. the SecretProviderClass exists;
#   2. the gateway Deployment is Available;
#   3. a running gateway pod actually mounts the CSI volume;
#   4. the CSI driver reports mounted=true for that pod/SPC;
#   5. the synced Secret contains both `ca.crt` and `id`.
# Fails with pod events and CSI diagnostics instead of silently timing out.
wait_for_csi_secret() {
  local timeout="${1:-180}"
  local elapsed=0
  local pod=""
  local mounted=""
  local ca_b64=""
  local id_b64=""
  local deployment=""
  local candidate=""
  local volumes=""

  kubectl_ns get secretproviderclass "${CA_SPC_NAME}" >/dev/null 2>&1 \
    || die "SecretProviderClass ${CA_SPC_NAME} not found in namespace ${NAMESPACE}"

  deployment="$(kubectl_ns get deployment \
    -l "app.kubernetes.io/instance=${RELEASE_NAME},app.kubernetes.io/name=gateway" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${deployment}" ]] || die "Kong gateway Deployment not found in namespace ${NAMESPACE}"

  log "CSI: waiting for deployment/${deployment} to be Available"
  kubectl_ns rollout status "deployment/${deployment}" --timeout="${timeout}s" >/dev/null \
    || { csi_diagnostics; die "gateway Deployment ${deployment} did not become Available"; }

  log "CSI: waiting for a gateway pod mounting ${CA_SPC_NAME} with mounted=true"
  while (( elapsed < timeout )); do
    pod=""
    while IFS= read -r candidate; do
      [[ -n "${candidate}" ]] || continue
      volumes="$(kubectl_ns get pod "${candidate}" \
        -o jsonpath='{range .spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null || true)"
      if grep -qx "${CA_SPC_NAME}" <<< "${volumes}"; then
        pod="${candidate}"
        break
      fi
    done < <(kubectl_ns get pods \
      -l "app.kubernetes.io/instance=${RELEASE_NAME},app.kubernetes.io/name=gateway,app.kubernetes.io/component=app" \
      -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    if [[ -n "${pod}" ]]; then
      mounted="$(kubectl_ns get secretproviderclasspodstatuses \
        -o jsonpath='{range .items[*]}{.status.podName}{"|"}{.status.secretProviderClassName}{"|"}{.status.mounted}{"\n"}{end}' \
        2>/dev/null | grep -F "${pod}|${CA_SPC_NAME}|true" || true)"
      if [[ -n "${mounted}" ]]; then
        break
      fi
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [[ -z "${pod}" || -z "${mounted}" ]]; then
    csi_diagnostics
    die "CSI did not report ${CA_SPC_NAME} mounted=true on a gateway pod within ${timeout}s"
  fi
  log "CSI: ${CA_SPC_NAME} mounted on pod ${pod}"

  elapsed=0
  while (( elapsed < timeout )); do
    ca_b64="$(kubectl_ns get secret "${CA_SECRET_NAME}" \
      -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
    id_b64="$(kubectl_ns get secret "${CA_SECRET_NAME}" \
      -o jsonpath='{.data.id}' 2>/dev/null || true)"
    if [[ -n "${ca_b64}" && -n "${id_b64}" ]]; then
      log "CSI: secret ${CA_SECRET_NAME} synced (ca.crt + id)"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  csi_diagnostics
  die "CSI secret ${CA_SECRET_NAME} did not contain ca.crt + id within ${timeout}s"
}
