#!/usr/bin/env bash
# Install or reconcile the Kong Helm release (chart kong/ingress).
#
# Usage:
#   ./scripts/kong-install.sh [--env dev|prod] [--config FILE]
#                             [--skip-gateway-api-crds] [--dry-run]
#                             [--with-csi|--without-csi]
#
# The Gateway API CRDs MUST exist before KIC starts, otherwise KIC never
# reconciles Gateway/HTTPRoute resources.
#
# Key Vault CSI is auto-detected: when the Secrets Store CSI CRD is installed,
# the SecretProviderClass is applied first and the CA volume is attached to the
# gateway pods. Use --without-csi when no Key Vault trust material is available
# (for example a throwaway dev cluster).
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ENV_NAME="prod"
SKIP_GATEWAY_API_CRDS="false"
DRY_RUN="false"
CSI_MODE="auto"          # auto | true | false

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="${2:?}"; shift 2 ;;
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    --skip-gateway-api-crds) SKIP_GATEWAY_API_CRDS="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --with-csi) CSI_MODE="true"; shift ;;
    --without-csi) CSI_MODE="false"; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "${ENV_NAME}" == "dev" || "${ENV_NAME}" == "prod" ]] || die "--env must be dev or prod"

require_config
require_cmd helm
require_cmd kubectl
load_kong_config

VALUES_FILE="${PROJECT_DIR}/helm/values-${ENV_NAME}.yaml"
[[ -f "${VALUES_FILE}" ]] || die "values file not found: ${VALUES_FILE}"

REPLICAS="$(cfg_required '.kong.replicas')"

csi_crd_present() {
  kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io >/dev/null 2>&1
}

# --- resolve CSI mode --------------------------------------------------------
case "${CSI_MODE}" in
  auto)
    if csi_crd_present; then
      CSI_ENABLED="true"
    else
      CSI_ENABLED="false"
    fi
    ;;
  true)
    csi_crd_present || die "Key Vault CSI CRD not found; enable the AKS add-on or use --without-csi"
    CSI_ENABLED="true"
    ;;
  false)
    CSI_ENABLED="false"
    ;;
esac

if [[ "${CSI_ENABLED}" != "true" ]]; then
  warn "Key Vault CSI volume will not be mounted (CA Secret ${CA_SECRET_NAME} must be provided another way)"
elif [[ -z "${KEYVAULT_NAME}" || -z "${TENANT_ID}" || -z "${WORKLOAD_IDENTITY_CLIENT_ID}" ]]; then
  die "CSI is enabled but azure.keyvault.name, azure.tenant_id and azure.keyvault.workload_identity_client_id are not all set in ${CONFIG_FILE}.
Fix config.yaml or run with --without-csi for a cluster without Key Vault access."
fi

install_gateway_api_crds() {
  if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 \
     && kubectl get crd backendtlspolicies.gateway.networking.k8s.io >/dev/null 2>&1; then
    log "Gateway API CRDs (including BackendTLSPolicy) already installed - leaving them untouched"
    return
  fi
  local url="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_CRD_VERSION}/experimental-install.yaml"
  log "installing Gateway API CRDs ${GATEWAY_API_CRD_VERSION} (experimental channel)"
  kubectl apply --server-side -f "${url}"
}

helm_args=(
  --namespace "${NAMESPACE}"
  --create-namespace
  --version "${KONG_CHART_VERSION}"
  --values "${PROJECT_DIR}/helm/values.yaml"
  --values "${VALUES_FILE}"
  --set "gateway.image.repository=${KONG_GATEWAY_IMAGE}"
  --set "gateway.image.tag=${KONG_GATEWAY_TAG}"
  --set "controller.ingressController.image.tag=${KIC_TAG}"
)

# .kong.replicas governs the production profile. values-dev.yaml intentionally
# stays at one replica so throwaway clusters remain cheap and schedulable.
if [[ "${ENV_NAME}" == "prod" ]]; then
  helm_args+=(--set "gateway.replicaCount=${REPLICAS}")
fi

if [[ "${CSI_ENABLED}" == "true" ]]; then
  helm_args+=(--values "${PROJECT_DIR}/helm/values-csi.yaml")
fi

log "Kong chart ${KONG_CHART_VERSION} | gateway ${KONG_GATEWAY_IMAGE}:${KONG_GATEWAY_TAG} | KIC ${KIC_TAG}"
log "namespace=${NAMESPACE} release=${RELEASE_NAME} env=${ENV_NAME} replicas=${REPLICAS} csi=${CSI_ENABLED}"

helm repo add kong https://charts.konghq.com --force-update >/dev/null
helm repo update kong >/dev/null

if [[ "${DRY_RUN}" == "true" ]]; then
  helm template "${RELEASE_NAME}" kong/ingress "${helm_args[@]}" >/dev/null
  log "dry run OK (helm template rendered successfully)"
  exit 0
fi

require_cmd envsubst
if [[ "${SKIP_GATEWAY_API_CRDS}" != "true" ]]; then
  install_gateway_api_crds
else
  warn "skipping Gateway API CRD installation by request"
fi

# The gateway pods reference the SecretProviderClass through a CSI volume, so
# the namespace and the class must exist before Helm rolls the pods out.
if [[ "${CSI_ENABLED}" == "true" ]]; then
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  apply_manifest "${PROJECT_DIR}/helm/secret-provider-class.yaml"
fi

log "installing/upgrading release ${RELEASE_NAME}"
helm upgrade --install "${RELEASE_NAME}" kong/ingress \
  "${helm_args[@]}" \
  --atomic \
  --wait \
  --timeout 10m

kubectl_ns get pods -l app.kubernetes.io/instance="${RELEASE_NAME}" -o wide

log "Kong installed. Next: ./scripts/apply-kong-resources.sh --env ${ENV_NAME}"
