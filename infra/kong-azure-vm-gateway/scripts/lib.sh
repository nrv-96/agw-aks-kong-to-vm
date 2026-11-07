#!/usr/bin/env bash
# Shared helpers for the Kong/AKS automation scripts.
# Requires: bash 4+, yq v4 (mikefarah).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_DIR}/config/config.yaml}"

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
    TENANT_ID ROOT_CA_OBJECT ROOT_CA_ID_OBJECT VM1_IP VM2_IP WORKLOAD_IDENTITY_CLIENT_ID
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
