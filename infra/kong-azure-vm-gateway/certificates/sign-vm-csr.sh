#!/usr/bin/env bash
# Sign a VM CSR with the private Root CA. Runs on the controlled signing host.
#
# Usage:
#   ./certificates/sign-vm-csr.sh --csr FILE --name vm1 \
#       [--ca-cert pki/root-ca.crt] [--ca-key pki/root-ca.key] \
#       [--out-dir pki/issued] [--hostname pairs-monitor.be.com] [--days 365] \
#       [--upload-keyvault --vault-name NAME --secret-name NAME]
#
# Only the public certificate/chain is uploaded to Key Vault. The VM private key
# stays on the VM and is never part of this workflow.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CSR=""
NAME=""
CA_CERT="${SCRIPT_DIR}/../pki/root-ca.crt"
CA_KEY="${SCRIPT_DIR}/../pki/root-ca.key"
OUT_DIR="${SCRIPT_DIR}/../pki/issued"
HOSTNAME="pairs-monitor.be.com"
DAYS="365"
UPLOAD_KEYVAULT="false"
VAULT_NAME=""
SECRET_NAME=""
EXT_FILE=""

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csr) CSR="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --ca-cert) CA_CERT="${2:?}"; shift 2 ;;
    --ca-key) CA_KEY="${2:?}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:?}"; shift 2 ;;
    --hostname) HOSTNAME="${2:?}"; shift 2 ;;
    --days) DAYS="${2:?}"; shift 2 ;;
    --upload-keyvault) UPLOAD_KEYVAULT="true"; shift ;;
    --vault-name) VAULT_NAME="${2:?}"; shift 2 ;;
    --secret-name) SECRET_NAME="${2:?}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v openssl >/dev/null 2>&1 || die "openssl is required"
[[ -n "${CSR}" && -f "${CSR}" ]] || die "--csr is required and must exist"
[[ -n "${NAME}" ]] || die "--name is required"
[[ "${NAME}" =~ ^[A-Za-z0-9._-]+$ ]] || die "--name must be a simple identifier"
[[ -f "${CA_CERT}" ]] || die "CA certificate not found: ${CA_CERT}"
[[ -f "${CA_KEY}" ]] || die "CA private key not found: ${CA_KEY}"

cleanup() { [[ -n "${EXT_FILE}" ]] && rm -f "${EXT_FILE}"; }
trap cleanup EXIT

# --- validate the CA ---------------------------------------------------------
openssl x509 -in "${CA_CERT}" -noout -checkend 0 >/dev/null \
  || die "CA certificate ${CA_CERT} is expired"
openssl x509 -in "${CA_CERT}" -noout -text | grep -q "CA:TRUE" \
  || die "${CA_CERT} is not a CA certificate"
ca_cert_pub="$(openssl x509 -in "${CA_CERT}" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)"
ca_key_pub="$(openssl pkey -in "${CA_KEY}" -pubout -outform DER | sha256sum)"
[[ "${ca_cert_pub}" == "${ca_key_pub}" ]] || die "CA key does not match ${CA_CERT}"

# --- validate the CSR --------------------------------------------------------
openssl req -in "${CSR}" -noout -verify >/dev/null \
  || die "CSR signature verification failed: ${CSR}"

SUBJECT="$(openssl req -in "${CSR}" -noout -subject -nameopt RFC2253)"
CSR_CN="$(sed -n 's/.*CN=\([^,]*\).*/\1/p' <<< "${SUBJECT}")"
[[ "${CSR_CN}" == "${HOSTNAME}" ]] \
  || die "CSR CN '${CSR_CN}' does not match expected hostname '${HOSTNAME}'"

CSR_TEXT="$(openssl req -in "${CSR}" -noout -text)"
if grep -q "CA:TRUE" <<< "${CSR_TEXT}"; then
  die "CSR requests CA:TRUE; refusing to sign a CA certificate"
fi
if grep -q "Public Key Algorithm: id-ecPublicKey" <<< "${CSR_TEXT}"; then
  die "CSR uses an EC key; this project pins RSA"
fi
KEY_BITS="$(sed -n 's/.*Public-Key: (\([0-9][0-9]*\) bit).*/\1/p' <<< "${CSR_TEXT}" | head -n1)"
[[ -n "${KEY_BITS}" ]] || die "unable to determine the CSR public-key size"
(( KEY_BITS >= 3072 )) || die "CSR key is ${KEY_BITS} bits; at least 3072 is required"

SAN_LINE="$(openssl req -in "${CSR}" -noout -text \
  | sed -n '/X509v3 Subject Alternative Name/{n;p;}' \
  | tr -d '[:space:]')"
[[ -n "${SAN_LINE}" ]] || die "CSR has no subjectAltName extension"

IFS=',' read -r -a SAN_ENTRIES <<< "${SAN_LINE}"
dns_count=0
for entry in "${SAN_ENTRIES[@]}"; do
  [[ -z "${entry}" ]] && continue
  if [[ "${entry}" == "DNS:${HOSTNAME}" ]]; then
    dns_count=$((dns_count + 1))
  else
    die "unexpected SAN entry '${entry}'; only DNS:${HOSTNAME} is allowed"
  fi
done
(( dns_count >= 1 )) || die "CSR SAN does not contain DNS:${HOSTNAME}"

log "CSR ${CSR} validated: CN=${CSR_CN}, SAN=DNS:${HOSTNAME}, ${KEY_BITS}-bit RSA"

# --- sign --------------------------------------------------------------------
mkdir -p "${OUT_DIR}"
chmod 0700 "${OUT_DIR}" 2>/dev/null || true
CERT="${OUT_DIR}/${NAME}.crt"
CHAIN="${OUT_DIR}/${NAME}-chain.pem"

EXT_FILE="$(mktemp)"
cat > "${EXT_FILE}" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${HOSTNAME}
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

log "signing ${CSR} with ${CA_CERT}"
openssl x509 -req -in "${CSR}" \
  -CA "${CA_CERT}" -CAkey "${CA_KEY}" -CAcreateserial \
  -days "${DAYS}" -sha256 -extfile "${EXT_FILE}" \
  -out "${CERT}"
chmod 0644 "${CERT}"

cat "${CERT}" "${CA_CERT}" > "${CHAIN}"
chmod 0644 "${CHAIN}"

if [[ -f "${SCRIPT_DIR}/validate-certificate.sh" ]]; then
  bash "${SCRIPT_DIR}/validate-certificate.sh" \
    --cert "${CERT}" --ca "${CA_CERT}" --hostname "${HOSTNAME}"
else
  openssl verify -CAfile "${CA_CERT}" "${CERT}" >/dev/null
  openssl x509 -in "${CERT}" -noout -checkhost "${HOSTNAME}" >/dev/null
fi

if [[ "${UPLOAD_KEYVAULT}" == "true" ]]; then
  [[ -n "${VAULT_NAME}" ]] || die "--vault-name is required with --upload-keyvault"
  [[ -n "${SECRET_NAME}" ]] || die "--secret-name is required with --upload-keyvault"
  command -v az >/dev/null 2>&1 || die "az CLI is required for --upload-keyvault"
  log "uploading public chain to Key Vault ${VAULT_NAME}/${SECRET_NAME}"
  az keyvault secret set \
    --vault-name "${VAULT_NAME}" \
    --name "${SECRET_NAME}" \
    --file "${CHAIN}" \
    --encoding utf-8 \
    --only-show-errors >/dev/null
fi

log "issued ${CERT}"
openssl x509 -in "${CERT}" -noout -subject -issuer -serial -dates -fingerprint -sha256 >&2
log "chain: ${CHAIN}"
