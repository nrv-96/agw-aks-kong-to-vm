#!/usr/bin/env bash
# Assert that a rendered Kong chart enables AKS workload identity.
#
# Usage:
#   ./scripts/verify-helm-workload-identity.sh <rendered.yaml> <client-id>
set -euo pipefail

FILE="${1:?usage: $0 <rendered.yaml> <client-id>}"
CLIENT_ID="${2:?usage: $0 <rendered.yaml> <client-id>}"

command -v yq >/dev/null 2>&1 || { echo "yq v4 is required" >&2; exit 1; }
[[ -f "${FILE}" ]] || { echo "rendered file not found: ${FILE}" >&2; exit 1; }
[[ -n "${CLIENT_ID}" ]] || { echo "workload identity client ID is empty" >&2; exit 1; }

sa_client_id="$(yq -r 'select(.kind == "ServiceAccount" and .metadata.name == "kong-gateway") | .metadata.annotations["azure.workload.identity/client-id"]' "${FILE}" | head -n1)"
pod_label="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "kong-gateway") | .spec.template.metadata.labels["azure.workload.identity/use"]' "${FILE}" | head -n1)"
pod_sa="$(yq -r 'select(.kind == "Deployment" and .metadata.name == "kong-gateway") | .spec.template.spec.serviceAccountName' "${FILE}" | head -n1)"

if [[ "${sa_client_id}" != "${CLIENT_ID}" ]]; then
  echo "FAIL: ServiceAccount kong-gateway workload identity client-id is '${sa_client_id}', expected '${CLIENT_ID}'" >&2
  exit 1
fi
if [[ "${pod_label}" != "true" ]]; then
  echo "FAIL: Deployment kong-gateway pod label azure.workload.identity/use is '${pod_label}', expected 'true'" >&2
  exit 1
fi
if [[ "${pod_sa}" != "kong-gateway" ]]; then
  echo "FAIL: Deployment kong-gateway serviceAccountName is '${pod_sa}', expected 'kong-gateway'" >&2
  exit 1
fi

echo "workload identity render OK: SA annotation, pod label and serviceAccountName are correct"
