#!/usr/bin/env bash
# Create the private Root CA exactly once (idempotent).
#
# Usage:
#   ./certificates/create-root-ca.sh [--out-dir DIR] [--cn NAME]
#                                    [--days N] [--key-size BITS]
#
# The CA private key is written with 0600 permissions and must stay on the
# controlled signing host. It is never copied to a VM or to Kong.
set -euo pipefail

OUT_DIR="./pki"
CA_CN="pairs-monitor-root-ca"
DAYS="3650"
KEY_SIZE="3072"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) OUT_DIR="${2:?}"; shift 2 ;;
    --cn) CA_CN="${2:?}"; shift 2 ;;
    --days) DAYS="${2:?}"; shift 2 ;;
    --key-size) KEY_SIZE="${2:?}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v openssl >/dev/null 2>&1 || die "openssl is required"

CA_KEY="${OUT_DIR}/root-ca.key"
CA_CRT="${OUT_DIR}/root-ca.crt"
CA_CONF=""

cleanup() { [[ -n "${CA_CONF}" ]] && rm -f "${CA_CONF}"; }
trap cleanup EXIT

mkdir -p "${OUT_DIR}"
chmod 0700 "${OUT_DIR}"

validate_existing() {
  openssl x509 -in "${CA_CRT}" -noout -checkend 0 >/dev/null \
    || die "existing Root CA ${CA_CRT} is expired; plan a trust migration instead of regenerating"
  openssl pkey -in "${CA_KEY}" -noout >/dev/null 2>&1 \
    || die "existing CA key ${CA_KEY} is not readable"
  local cert_pub key_pub
  cert_pub="$(openssl x509 -in "${CA_CRT}" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)"
  key_pub="$(openssl pkey -in "${CA_KEY}" -pubout -outform DER | sha256sum)"
  [[ "${cert_pub}" == "${key_pub}" ]] || die "existing Root CA key does not match ${CA_CRT}"
  openssl x509 -in "${CA_CRT}" -noout -text | grep -q "CA:TRUE" \
    || die "existing ${CA_CRT} is not a CA certificate"
}

if [[ -f "${CA_CRT}" && -f "${CA_KEY}" ]]; then
  validate_existing
  log "reusing existing Root CA ${CA_CRT}"
  openssl x509 -in "${CA_CRT}" -noout -subject -issuer -dates -fingerprint -sha256 >&2
  exit 0
fi

if [[ -f "${CA_CRT}" || -f "${CA_KEY}" ]]; then
  die "incomplete Root CA state in ${OUT_DIR}: found only one of root-ca.key/root-ca.crt. Refusing to overwrite."
fi

umask 077
log "generating ${KEY_SIZE}-bit RSA Root CA ${CA_CN}"
openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${KEY_SIZE}" -out "${CA_KEY}"
chmod 0600 "${CA_KEY}"

CA_CONF="$(mktemp)"
cat > "${CA_CONF}" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_ca

[dn]
CN = ${CA_CN}
O = pairs-monitor

[v3_ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

openssl req -x509 -new -key "${CA_KEY}" -sha256 -days "${DAYS}" \
  -out "${CA_CRT}" -config "${CA_CONF}"
chmod 0644 "${CA_CRT}"

validate_existing
log "Root CA created: ${CA_CRT}"
openssl x509 -in "${CA_CRT}" -noout -subject -issuer -dates -fingerprint -sha256 >&2
