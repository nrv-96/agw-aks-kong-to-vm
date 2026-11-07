#!/usr/bin/env bash
# Sign the CSRs for every backend VM defined in config/config.yaml.
#
# Usage:
#   ./certificates/issue-vm-certificates.sh [--config FILE] [--csr-dir DIR]
#       [--ca-cert FILE] [--ca-key FILE] [--out-dir DIR] [--hostname NAME]
#       [--days N] [--upload-keyvault] [--vault-name NAME]
#
# Expected CSR layout: <csr-dir>/<backend name>.csr (e.g. vm1.csr, vm2.csr).
# Public leaf+chain certificates are written to <out-dir> and optionally stored
# in Key Vault under backends[].certificate_name. Private keys never leave the VMs.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

CONFIG_FILE="${PROJECT_DIR}/config/config.yaml"
CSR_DIR="./csr"
CA_CERT="${PROJECT_DIR}/pki/root-ca.crt"
CA_KEY="${PROJECT_DIR}/pki/root-ca.key"
OUT_DIR="${PROJECT_DIR}/pki/issued"
HOSTNAME=""
DAYS=""
UPLOAD_KEYVAULT="false"
VAULT_NAME=""

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    --csr-dir) CSR_DIR="${2:?}"; shift 2 ;;
    --ca-cert) CA_CERT="${2:?}"; shift 2 ;;
    --ca-key) CA_KEY="${2:?}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:?}"; shift 2 ;;
    --hostname) HOSTNAME="${2:?}"; shift 2 ;;
    --days) DAYS="${2:?}"; shift 2 ;;
    --upload-keyvault) UPLOAD_KEYVAULT="true"; shift ;;
    --vault-name) VAULT_NAME="${2:?}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v yq >/dev/null 2>&1 || die "yq v4 is required"
require() {
  local value="$1" label="$2"
  [[ -n "${value}" && "${value}" != "null" && "${value}" != "<INPUT>" ]] \
    || die "missing required config value: ${label} (${CONFIG_FILE})"
}

[[ -f "${CONFIG_FILE}" ]] || die "config not found: ${CONFIG_FILE}"
[[ -f "${CA_CERT}" ]] || die "CA certificate not found: ${CA_CERT}"
[[ -f "${CA_KEY}" ]] || die "CA key not found: ${CA_KEY}"

[[ -n "${HOSTNAME}" ]] || HOSTNAME="$(yq -r '.application.backend_hostname' "${CONFIG_FILE}")"
[[ -n "${DAYS}" ]] || DAYS="$(yq -r '.certificates.server_certificate_validity_days' "${CONFIG_FILE}")"
require "${HOSTNAME}" ".application.backend_hostname"
require "${DAYS}" ".certificates.server_certificate_validity_days"

mapfile -t VM_NAMES < <(yq -r '.backends[].name' "${CONFIG_FILE}")
mapfile -t CERT_NAMES < <(yq -r '.backends[].certificate_name' "${CONFIG_FILE}")
[[ ${#VM_NAMES[@]} -ge 2 ]] || die "config must define at least two backends"
[[ ${#VM_NAMES[@]} -eq ${#CERT_NAMES[@]} ]] \
  || die "backends[].name and backends[].certificate_name counts do not match"

if [[ "${UPLOAD_KEYVAULT}" == "true" ]]; then
  [[ -n "${VAULT_NAME}" ]] || VAULT_NAME="$(yq -r '.azure.keyvault.name' "${CONFIG_FILE}")"
  require "${VAULT_NAME}" ".azure.keyvault.name"
  command -v az >/dev/null 2>&1 || die "az CLI is required for --upload-keyvault"
fi

mkdir -p "${OUT_DIR}"
chmod 0700 "${OUT_DIR}" 2>/dev/null || true

for index in "${!VM_NAMES[@]}"; do
  vm="${VM_NAMES[$index]}"
  secret="${CERT_NAMES[$index]}"
  require "${vm}" ".backends[${index}].name"
  require "${secret}" ".backends[${index}].certificate_name"
  csr="${CSR_DIR}/${vm}.csr"
  [[ -f "${csr}" ]] || die "CSR not found for ${vm}: ${csr}"

  args=(
    --csr "${csr}"
    --name "${vm}"
    --ca-cert "${CA_CERT}"
    --ca-key "${CA_KEY}"
    --out-dir "${OUT_DIR}"
    --hostname "${HOSTNAME}"
    --days "${DAYS}"
  )
  if [[ "${UPLOAD_KEYVAULT}" == "true" ]]; then
    args+=(--upload-keyvault --vault-name "${VAULT_NAME}" --secret-name "${secret}")
  fi

  log "issuing certificate for ${vm} (secret ${secret})"
  bash "${SCRIPT_DIR}/sign-vm-csr.sh" "${args[@]}"
done

log "issued ${#VM_NAMES[@]} VM certificate(s) into ${OUT_DIR}"
