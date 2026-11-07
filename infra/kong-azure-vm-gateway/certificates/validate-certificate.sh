#!/usr/bin/env bash
# Validate a server certificate against the private CA and its purpose.
#
# Usage:
#   ./certificates/validate-certificate.sh --cert FILE --ca FILE --hostname NAME
#       [--key FILE] [--warn-days 30]
#
# Checks: chain, hostname, exact SAN, serverAuth EKU, CA:FALSE, key usage,
# validity and (when --key is supplied) that the key matches the certificate.
set -euo pipefail

CERT=""
CA=""
HOSTNAME=""
KEY=""
WARN_DAYS="30"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
ok() { log "OK: $*"; }

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cert) CERT="${2:?}"; shift 2 ;;
    --ca) CA="${2:?}"; shift 2 ;;
    --hostname) HOSTNAME="${2:?}"; shift 2 ;;
    --key) KEY="${2:?}"; shift 2 ;;
    --warn-days) WARN_DAYS="${2:?}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v openssl >/dev/null 2>&1 || die "openssl is required"
[[ -n "${CERT}" && -f "${CERT}" ]] || die "--cert is required"
[[ -n "${CA}" && -f "${CA}" ]] || die "--ca is required"
[[ -n "${HOSTNAME}" ]] || die "--hostname is required"

openssl verify -CAfile "${CA}" "${CERT}" >/dev/null \
  || die "certificate chain verification failed against ${CA}"
ok "chain verifies against ${CA}"

openssl x509 -in "${CERT}" -noout -checkhost "${HOSTNAME}" >/dev/null \
  || die "certificate does not match hostname ${HOSTNAME}"
ok "hostname matches ${HOSTNAME}"

SAN_LINE="$(openssl x509 -in "${CERT}" -noout -ext subjectAltName 2>/dev/null \
  | sed -n '2p' | tr -d '[:space:]')"
[[ -n "${SAN_LINE}" ]] || die "certificate has no subjectAltName"
IFS=',' read -r -a SAN_ENTRIES <<< "${SAN_LINE}"
dns_count=0
for entry in "${SAN_ENTRIES[@]}"; do
  [[ -z "${entry}" ]] && continue
  [[ "${entry}" == "DNS:${HOSTNAME}" ]] || die "unexpected SAN entry '${entry}'"
  dns_count=$((dns_count + 1))
done
(( dns_count >= 1 )) || die "subjectAltName does not contain DNS:${HOSTNAME}"
ok "subjectAltName is exactly DNS:${HOSTNAME}"

openssl x509 -in "${CERT}" -noout -ext extendedKeyUsage 2>/dev/null \
  | grep -q "TLS Web Server Authentication" \
  || die "extendedKeyUsage does not contain serverAuth"
ok "extendedKeyUsage contains serverAuth"

if openssl x509 -in "${CERT}" -noout -ext basicConstraints 2>/dev/null | grep -q "CA:TRUE"; then
  die "certificate is a CA certificate (CA:TRUE); expected an end-entity certificate"
fi
openssl x509 -in "${CERT}" -noout -ext basicConstraints 2>/dev/null \
  | grep -q "CA:FALSE" \
  || die "basicConstraints CA:FALSE is missing"
ok "basicConstraints CA:FALSE"

KEY_USAGE="$(openssl x509 -in "${CERT}" -noout -ext keyUsage 2>/dev/null || true)"
grep -q "Digital Signature" <<< "${KEY_USAGE}" \
  || die "keyUsage does not contain digitalSignature"
grep -q "Key Encipherment" <<< "${KEY_USAGE}" \
  || die "keyUsage does not contain keyEncipherment"
ok "keyUsage contains digitalSignature and keyEncipherment"

openssl x509 -in "${CERT}" -noout -checkend 0 >/dev/null \
  || die "certificate is expired"
if ! openssl x509 -in "${CERT}" -noout -checkend "$((WARN_DAYS * 86400))" >/dev/null; then
  log "WARN: certificate expires within ${WARN_DAYS} days"
else
  ok "certificate is valid for at least ${WARN_DAYS} more days"
fi

if [[ -n "${KEY}" ]]; then
  [[ -f "${KEY}" ]] || die "key file not found: ${KEY}"
  cert_pub="$(openssl x509 -in "${CERT}" -pubkey -noout \
    | openssl pkey -pubin -outform DER | sha256sum)"
  key_pub="$(openssl pkey -in "${KEY}" -pubout -outform DER | sha256sum)"
  [[ "${cert_pub}" == "${key_pub}" ]] \
    || die "private key ${KEY} does not match certificate ${CERT}"
  ok "private key matches the certificate"
fi

log "certificate validation passed: ${CERT}"
openssl x509 -in "${CERT}" -noout -subject -issuer -serial -dates >&2
