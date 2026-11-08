#!/usr/bin/env bash
# Upgrade the Kong Helm release with pinned versions.
#
# Usage:
#   ./scripts/kong-upgrade.sh [--env dev|prod] [--config FILE]
#                             [--chart VERSION] [--gateway-tag TAG] [--kic-tag TAG]
#                             [--dry-run] [--yes] [--with-csi|--without-csi]
#
# Without --yes the script only prints the server-side dry run, so production
# upgrades always require an explicit approval flag.
#
# The Key Vault CSI volume is preserved automatically when the live gateway
# Deployment already mounts it; override with --with-csi / --without-csi.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ENV_NAME="prod"
DRY_RUN="false"
CONFIRMED="false"
CHART_VERSION=""
GATEWAY_TAG=""
KIC_TAG_ARG=""
CSI_MODE="auto"          # auto | true | false

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="${2:?}"; shift 2 ;;
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    --chart) CHART_VERSION="${2:?}"; shift 2 ;;
    --gateway-tag) GATEWAY_TAG="${2:?}"; shift 2 ;;
    --kic-tag) KIC_TAG_ARG="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --yes) CONFIRMED="true"; shift ;;
    --with-csi) CSI_MODE="true"; shift ;;
    --without-csi) CSI_MODE="false"; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_config
require_cmd helm
require_cmd kubectl
load_kong_config

# Overrides from flags, otherwise the pinned config values.
CHART_VERSION="${CHART_VERSION:-${KONG_CHART_VERSION}}"
GATEWAY_TAG="${GATEWAY_TAG:-${KONG_GATEWAY_TAG}}"
KIC_TAG_ARG="${KIC_TAG_ARG:-${KIC_TAG}}"
REPLICAS="$(cfg_required '.kong.replicas')"

VALUES_FILE="${PROJECT_DIR}/helm/values-${ENV_NAME}.yaml"
[[ -f "${VALUES_FILE}" ]] || die "values file not found: ${VALUES_FILE}"

# Preserve the Key Vault CSI volume across upgrades: dropping values-csi.yaml
# would remove the mount, stop the Secret refresh and break CA rotation.
GW_DEPLOYMENT="$(kubectl_ns get deployment \
  -l "app.kubernetes.io/instance=${RELEASE_NAME},app.kubernetes.io/name=gateway" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

csi_in_release() {
  [[ -n "${GW_DEPLOYMENT}" ]] || return 1
  kubectl_ns get deployment "${GW_DEPLOYMENT}" \
    -o jsonpath='{range .spec.template.spec.volumes[*]}{.csi.driver}{"\n"}{end}' 2>/dev/null \
    | grep -qx 'secrets-store.csi.k8s.io'
}

case "${CSI_MODE}" in
  auto)
    if csi_in_release; then CSI_ENABLED="true"; else CSI_ENABLED="false"; fi
    ;;
  true)
    kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io >/dev/null 2>&1 \
      || die "Key Vault CSI CRD not found; use --without-csi"
    CSI_ENABLED="true"
    ;;
  false)
    CSI_ENABLED="false"
    ;;
esac

helm_args=(
  --namespace "${NAMESPACE}"
  --version "${CHART_VERSION}"
  --values "${PROJECT_DIR}/helm/values.yaml"
  --values "${VALUES_FILE}"
  --set "gateway.image.repository=${KONG_GATEWAY_IMAGE}"
  --set "gateway.image.tag=${GATEWAY_TAG}"
  --set "controller.ingressController.image.tag=${KIC_TAG_ARG}"
  --set-string "gateway.proxy.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-ipv4=${INTERNAL_LB_IP}"
)

# .kong.replicas governs the production profile; dev stays at one replica.
if [[ "${ENV_NAME}" == "prod" ]]; then
  helm_args+=(--set "gateway.replicaCount=${REPLICAS}")
fi

if [[ "${CSI_ENABLED}" == "true" ]]; then
  helm_args+=(--values "${PROJECT_DIR}/helm/values-csi.yaml")
fi

log "target chart=${CHART_VERSION} gateway=${KONG_GATEWAY_IMAGE}:${GATEWAY_TAG} KIC=${KIC_TAG_ARG} csi=${CSI_ENABLED}"

if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  log "Gateway API CRDs present - not modified by this script"
else
  die "Gateway API CRDs missing; run kong-install.sh first"
fi

helm repo add kong https://charts.konghq.com --force-update >/dev/null
helm repo update kong >/dev/null

log "server-side dry run"
helm upgrade "${RELEASE_NAME}" kong/ingress \
  "${helm_args[@]}" \
  --dry-run=server

if [[ "${DRY_RUN}" == "true" ]]; then
  log "dry run requested - stopping before applying"
  exit 0
fi

if [[ "${CONFIRMED}" != "true" ]]; then
  die "refusing to apply an upgrade without --yes (production approval gate)"
fi

log "applying upgrade"
helm upgrade "${RELEASE_NAME}" kong/ingress \
  "${helm_args[@]}" \
  --atomic \
  --wait \
  --timeout 15m

kubectl_ns rollout status deployment \
  -l app.kubernetes.io/instance="${RELEASE_NAME}",app.kubernetes.io/component=app \
  --timeout=5m

if [[ "${CSI_ENABLED}" == "true" ]]; then
  wait_for_csi_secret 180
fi

log "upgrade complete; run ./scripts/validate-kong.sh for runtime assertions"
