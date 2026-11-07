#!/usr/bin/env bash
# Phase 1 entry point: deploy the Kong Gateway layer only.
#
# Usage:
#   ./scripts/deploy.sh --config config/config.yaml [--env prod|dev] [--dry-run]
#                       [--with-csi|--without-csi] [--skip-crds]
#
# Full end-to-end deployment (Terraform private DNS, CA issuance, VM TLS,
# Application Gateway, Entra ID) is built in later phases; --phase all fails
# explicitly instead of pretending those steps ran.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ENV_NAME="prod"
PHASE="kong"
DRY_RUN="false"
CSI_FLAG=""
SKIP_CRDS="false"

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    --env) ENV_NAME="${2:?}"; shift 2 ;;
    --phase) PHASE="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --with-csi) CSI_FLAG="--with-csi"; shift ;;
    --without-csi) CSI_FLAG="--without-csi"; shift ;;
    --skip-crds) SKIP_CRDS="true"; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "${PHASE}" == "kong" ]] || die "only --phase kong is implemented in this increment (requested: ${PHASE})"

require_config
require_cmd kubectl
load_kong_config

log "phase=kong env=${ENV_NAME} namespace=${NAMESPACE} release=${RELEASE_NAME}"

install_args=(--config "${CONFIG_FILE}" --env "${ENV_NAME}")
if [[ -n "${CSI_FLAG}" ]]; then
  install_args+=("${CSI_FLAG}")
fi
if [[ "${SKIP_CRDS}" == "true" ]]; then
  install_args+=(--skip-gateway-api-crds)
fi
if [[ "${DRY_RUN}" == "true" ]]; then
  install_args+=(--dry-run)
fi

"${SCRIPT_DIR}/kong-install.sh" "${install_args[@]}"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "deploy dry run complete"
  exit 0
fi

resource_args=(--config "${CONFIG_FILE}" --env "${ENV_NAME}")
if [[ "${CSI_FLAG}" == "--without-csi" ]]; then
  resource_args+=(--skip-csi)
fi

"${SCRIPT_DIR}/apply-kong-resources.sh" "${resource_args[@]}"
"${SCRIPT_DIR}/reload-kong-trust.sh" --config "${CONFIG_FILE}"

log "Kong layer deployed. Validate listeners/targets, then continue with Terraform + certificate phases."
