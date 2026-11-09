#!/usr/bin/env bash
# Generate a VM-local private key + CSR on every backend VM via Azure VM Run
# Command, then copy only the CSR back into ./csr/<vm>.csr.
#
# The private key is generated on the VM and never leaves it.
#
# Usage:
#   ./scripts/generate-vm-csrs.sh [--config config/config.yaml]
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    -h|--help)
      sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_config
require_cmd az
require_cmd base64

SUBSCRIPTION_ID="$(cfg_required '.azure.subscription_id')"
RESOURCE_GROUP="$(cfg_required '.azure.resource_group.name')"
BACKEND_HOSTNAME="$(cfg_required '.application.backend_hostname')"
OUT_DIR="${PROJECT_DIR}/csr"
mkdir -p "${OUT_DIR}"

# Runs as root through the Azure VM agent. Idempotent: an existing private key
# is never overwritten; only the CSR is regenerated from it.
read -r -d '' VM_SCRIPT <<'VMSCRIPT' || true
set -eu
VM="$(hostname)"
DIR=/etc/hello/csr
CN="__CN__"
mkdir -p "$DIR"
chmod 700 "$DIR"
cat > "$DIR/$VM.cnf" <<EOF
[req]
prompt = no
distinguished_name = dn
req_extensions = v3_req
[dn]
CN = $CN
O = pairs-monitor
[v3_req]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = $CN
EOF
if [ ! -f "$DIR/$VM.key" ]; then
  umask 077
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$DIR/$VM.key"
  chmod 600 "$DIR/$VM.key"
  echo "KEY_CREATED"
else
  echo "KEY_EXISTS (not overwritten)"
fi
openssl req -new -key "$DIR/$VM.key" -sha256 -out "$DIR/$VM.csr" -config "$DIR/$VM.cnf"
chmod 644 "$DIR/$VM.csr"
openssl req -in "$DIR/$VM.csr" -noout -verify
echo "CSR_READY $DIR/$VM.csr"
VMSCRIPT

VM_SCRIPT="${VM_SCRIPT//__CN__/${BACKEND_HOSTNAME}}"

for vm in $(cfg '.backends[].name'); do
  log "generating key + CSR on ${vm} (${RESOURCE_GROUP})"
  az vm run-command invoke \
    --subscription "${SUBSCRIPTION_ID}" \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${vm}" \
    --command-id RunShellScript \
    --scripts "${VM_SCRIPT}" \
    --only-show-errors \
    --query "value[0].message" -o tsv

  log "retrieving ${vm} CSR"
  MESSAGE="$(az vm run-command invoke \
    --subscription "${SUBSCRIPTION_ID}" \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${vm}" \
    --command-id RunShellScript \
    --scripts 'set -eu; VM="$(hostname)"; base64 -w0 "/etc/hello/csr/${VM}.csr"' \
    --only-show-errors \
    --query "value[0].message" -o tsv)"

  B64="$(printf '%s\n' "${MESSAGE}" | sed -n '/\[stdout\]/,/\[stderr\]/p' | sed '1d;$d' | tr -d '\r\n ')"
  [[ -n "${B64}" ]] || die "could not extract the CSR for ${vm}; raw output:
${MESSAGE}"

  printf '%s' "${B64}" | base64 -d > "${OUT_DIR}/${vm}.csr"
  log "saved ${OUT_DIR}/${vm}.csr"
done

log "done. Next: sign the CSRs on this host with certificates/issue-vm-certificates.sh."
