#!/usr/bin/env bash
# Generate a VM-local private key and CSR. Runs ON the VM.
#
# Usage:
#   ./certificates/generate-vm-csr.sh [--out-dir DIR] [--name vm1]
#                                     [--cn HOSTNAME] [--san HOSTNAME[,HOSTNAME...]]
#                                     [--key-size BITS] [--force]
#
# The private key never leaves the VM. Submit only the generated CSR to the
# controlled signing workflow (sign-vm-csr.sh).
set -euo pipefail

OUT_DIR="."
NAME="vm1"
CN="be.internal.example.com"
SAN=""
KEY_SIZE="3072"
FORCE="false"
REQ_CONF=""

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) OUT_DIR="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --cn) CN="${2:?}"; shift 2 ;;
    --san) SAN="${2:?}"; shift 2 ;;
    --key-size) KEY_SIZE="${2:?}"; shift 2 ;;
    --force) FORCE="true"; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v openssl >/dev/null 2>&1 || die "openssl is required"
[[ "${NAME}" =~ ^[A-Za-z0-9._-]+$ ]] || die "--name must be a simple identifier (got '${NAME}')"

[[ -n "${SAN}" ]] || SAN="${CN}"

IFS=',' read -r -a SAN_NAMES <<< "${SAN}"
[[ ${#SAN_NAMES[@]} -ge 1 ]] || die "--san must contain at least one DNS name"

declare -a CLEAN_SANS=()
for raw in "${SAN_NAMES[@]}"; do
  name="${raw// /}"
  [[ "${name}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || die "invalid DNS name in --san: '${name}'"
  CLEAN_SANS+=("${name}")
done

found_cn="false"
for name in "${CLEAN_SANS[@]}"; do
  [[ "${name}" == "${CN}" ]] && found_cn="true"
done
[[ "${found_cn}" == "true" ]] || die "--cn '${CN}' must be present in --san"

mkdir -p "${OUT_DIR}"

KEY="${OUT_DIR}/${NAME}.key"
CSR="${OUT_DIR}/${NAME}.csr"

if [[ -f "${KEY}" && "${FORCE}" != "true" ]]; then
  die "private key ${KEY} already exists; refusing to overwrite. Use --force to rotate it."
fi
if [[ -f "${KEY}" ]]; then
  backup="${KEY}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  log "backing up existing key to ${backup}"
  cp -p "${KEY}" "${backup}"
  chmod 0600 "${backup}"
fi

REQ_CONF="$(mktemp)"
trap 'rm -f "${REQ_CONF}"' EXIT

{
  echo "[req]"
  echo "prompt = no"
  echo "distinguished_name = dn"
  echo "req_extensions = v3_req"
  echo
  echo "[dn]"
  echo "CN = ${CN}"
  echo "O = pairs-monitor"
  echo
  echo "[v3_req]"
  echo "basicConstraints = critical,CA:FALSE"
  echo "keyUsage = critical,digitalSignature,keyEncipherment"
  echo "extendedKeyUsage = serverAuth"
  echo "subjectAltName = @alt_names"
  echo
  echo "[alt_names]"
  index=1
  for name in "${CLEAN_SANS[@]}"; do
    echo "DNS.${index} = ${name}"
    index=$((index + 1))
  done
} > "${REQ_CONF}"

umask 077
log "generating ${KEY_SIZE}-bit RSA key ${KEY}"
openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${KEY_SIZE}" -out "${KEY}"
chmod 0600 "${KEY}"

log "creating CSR ${CSR} with SAN ${CLEAN_SANS[*]}"
openssl req -new -key "${KEY}" -sha256 -out "${CSR}" -config "${REQ_CONF}"
chmod 0644 "${CSR}"

openssl req -in "${CSR}" -noout -verify >/dev/null \
  || die "generated CSR failed verification"

log "CSR ready: ${CSR}"
openssl req -in "${CSR}" -noout -subject -nameopt RFC2253 >&2
openssl req -in "${CSR}" -noout -text | sed -n '/Subject Alternative Name/,+1p' >&2
log "Submit only ${CSR} to the signing host; never copy ${KEY}."
