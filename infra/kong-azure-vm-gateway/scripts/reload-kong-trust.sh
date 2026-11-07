#!/usr/bin/env bash
# Force Kong to reconcile newly rotated CA trust material.
#
# Why this exists: the CSI driver refreshes the mounted file and the synced
# Kubernetes Secret, but that does NOT guarantee Kong Gateway reloads the trust
# store or that KIC re-pushes the CA entity. This script detects the current CA
# checksum, annotates the gateway Deployment and waits for a rolling restart.
#
# Usage:
#   ./scripts/reload-kong-trust.sh [--config FILE] [--force]
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FORCE="false"

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    --force) FORCE="true"; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_config
require_cmd kubectl
require_cmd sha256sum
load_kong_config

kubectl get secret "${CA_SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 \
  || die "secret ${CA_SECRET_NAME} not found in ${NAMESPACE}; CA trust is not synced"

DEPLOYMENT="$(kubectl_ns get deployment \
  -l "app.kubernetes.io/instance=${RELEASE_NAME},app.kubernetes.io/name=gateway" \
  -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${DEPLOYMENT}" ]] || die "Kong gateway deployment not found in namespace ${NAMESPACE}"

ca_b64="$(kubectl_ns get secret "${CA_SECRET_NAME}" -o jsonpath='{.data.ca\.crt}')"
[[ -n "${ca_b64}" ]] || die "secret ${CA_SECRET_NAME} has no 'ca.crt' key; CA trust is not synced correctly"
checksum="$(printf '%s' "${ca_b64}" | sha256sum | awk '{print $1}')"
current="$(kubectl_ns get deployment "${DEPLOYMENT}" \
  -o jsonpath='{.spec.template.metadata.annotations.konghq\.com/ca-checksum}' 2>/dev/null || true)"

if [[ "${checksum}" == "${current}" && "${FORCE}" != "true" ]]; then
  log "CA checksum unchanged (${checksum:0:12}); nothing to do. Use --force to restart anyway."
  exit 0
fi

# No baseline annotation means the CA was already mounted when this Deployment
# was created (fresh install), so there is nothing to reload yet.
if [[ -z "${current}" && "${FORCE}" != "true" ]]; then
  log "no previous CA checksum recorded (fresh install); skipping restart. Use --force to roll anyway."
  exit 0
fi

log "rolling ${DEPLOYMENT} to pick up CA ${checksum:0:12}"
kubectl_ns annotate deployment "${DEPLOYMENT}" "konghq.com/ca-checksum=${checksum}" --overwrite >/dev/null
kubectl_ns rollout status deployment "${DEPLOYMENT}" --timeout=5m

log "Kong trust reload triggered; verify with ./scripts/validate-kong.sh (phase 2)"
