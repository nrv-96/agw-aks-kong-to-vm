#!/usr/bin/env bash
# Upload the public Root CA PEM and its stable UUID to Azure Key Vault.
#
# Usage:
#   ./certificates/upload-ca-to-keyvault.sh --vault-name <kv> \
#       [--ca-cert pki/root-ca.crt] [--id-file pki/root-ca.id]
#
# The Root CA private key is never read or uploaded. The UUID is generated once
# and kept in the local id file; it becomes the Kong CA certificate entity ID.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

VAULT_NAME=""
CA_CERT="${PROJECT_DIR}/pki/root-ca.crt"
ID_FILE="${PROJECT_DIR}/pki/root-ca.id"
CA_SECRET="pairs-monitor-root-ca"
ID_SECRET="pairs-monitor-root-ca-id"
CA_ID=""

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-name) VAULT_NAME="${2:?}"; shift 2 ;;
    --ca-cert) CA_CERT="${2:?}"; shift 2 ;;
    --id-file) ID_FILE="${2:?}"; shift 2 ;;
    --ca-secret-name) CA_SECRET="${2:?}"; shift 2 ;;
    --id-secret-name) ID_SECRET="${2:?}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v az >/dev/null 2>&1 || die "az CLI is required"
command -v openssl >/dev/null 2>&1 || die "openssl is required"
[[ -n "${VAULT_NAME}" ]] || die "--vault-name is required"
[[ -f "${CA_CERT}" ]] || die "CA certificate not found: ${CA_CERT}"

openssl x509 -in "${CA_CERT}" -noout -text | grep -q "CA:TRUE" \
  || die "${CA_CERT} is not a CA certificate"

if [[ ! -s "${ID_FILE}" ]]; then
  mkdir -p "$(dirname "${ID_FILE}")"
  if command -v uuidgen >/dev/null 2>&1; then
    CA_ID="$(uuidgen | tr 'A-Z' 'a-z')"
  else
    command -v python3 >/dev/null 2>&1 || die "uuidgen or python3 is required to create the CA UUID"
    CA_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  fi
  printf '%s' "${CA_ID}" > "${ID_FILE}"
  chmod 0600 "${ID_FILE}"
  log "generated stable CA UUID ${CA_ID} in ${ID_FILE}"
else
  CA_ID="$(tr -d '\r\n' < "${ID_FILE}")"
fi
[[ "${CA_ID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
  || die "CA UUID in ${ID_FILE} is not a valid UUID"

log "uploading public CA to ${VAULT_NAME}/${CA_SECRET}"
az keyvault secret set \
  --vault-name "${VAULT_NAME}" \
  --name "${CA_SECRET}" \
  --file "${CA_CERT}" \
  --encoding utf-8 \
  --only-show-errors >/dev/null

log "uploading CA UUID to ${VAULT_NAME}/${ID_SECRET}"
az keyvault secret set \
  --vault-name "${VAULT_NAME}" \
  --name "${ID_SECRET}" \
  --value "${CA_ID}" \
  --only-show-errors >/dev/null

log "done: CA PEM and UUID are available for the CSI SecretProviderClass"
