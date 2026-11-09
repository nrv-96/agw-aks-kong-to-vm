#!/usr/bin/env bash
# Install a VM certificate + VM-local private key as a PKCS#12 keystore and
# (re)start the hello-app systemd service. Runs ON the VM.
#
# Usage:
#   ./certificates/install-vm-certificate.sh --cert vm1.crt --chain chain.pem \
#       --ca root-ca.crt --key vm1.key [--root-prefix /] [...]
#
#   ./certificates/install-vm-certificate.sh --from-keyvault \
#       --vault-name NAME --secret-name pairs-monitor-vm1-tls \
#       --key /etc/hello/tls/vm1.key --ca root-ca.crt [...]
#
# The private key must already exist on the VM. It is never downloaded or
# accepted from Key Vault.
set -euo pipefail

ROOT_PREFIX="/"
CERT=""
CHAIN=""
CA=""
KEY=""
FROM_KEYVAULT="false"
VAULT_NAME=""
SECRET_NAME=""
TLS_DIR="/etc/hello/tls"
KEYSTORE="/etc/hello/tls/keystore.p12"
ENV_FILE="/etc/hello/hello.env"
SERVICE="hello-app"
APP_USER="hello"
APP_GROUP="hello"
PORT="8100"
HOSTNAME="be.internal.example.com"
KEYSTORE_ALIAS="hello-app"
NO_SYSTEMCTL="false"
SKIP_RESTART="false"
WORK_DIR=""

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
ok() { log "OK: $*"; }

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cert) CERT="${2:?}"; shift 2 ;;
    --chain) CHAIN="${2:?}"; shift 2 ;;
    --ca) CA="${2:?}"; shift 2 ;;
    --key) KEY="${2:?}"; shift 2 ;;
    --from-keyvault) FROM_KEYVAULT="true"; shift ;;
    --vault-name) VAULT_NAME="${2:?}"; shift 2 ;;
    --secret-name) SECRET_NAME="${2:?}"; shift 2 ;;
    --root-prefix) ROOT_PREFIX="${2:?}"; shift 2 ;;
    --tls-dir) TLS_DIR="${2:?}"; shift 2 ;;
    --keystore) KEYSTORE="${2:?}"; shift 2 ;;
    --env-file) ENV_FILE="${2:?}"; shift 2 ;;
    --service) SERVICE="${2:?}"; shift 2 ;;
    --user) APP_USER="${2:?}"; shift 2 ;;
    --group) APP_GROUP="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --hostname) HOSTNAME="${2:?}"; shift 2 ;;
    --alias) KEYSTORE_ALIAS="${2:?}"; shift 2 ;;
    --no-systemctl) NO_SYSTEMCTL="true"; shift ;;
    --skip-restart) SKIP_RESTART="true"; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v openssl >/dev/null 2>&1 || die "openssl is required"
[[ -n "${KEY}" && -f "${KEY}" ]] || die "--key is required (the VM-local private key)"

ROOT_PREFIX="${ROOT_PREFIX%/}"
[[ -n "${ROOT_PREFIX}" ]] || ROOT_PREFIX="/"
if [[ "${ROOT_PREFIX}" != "/" ]]; then
  # Test/staging mode: rewrite absolute destinations under the prefix.
  TLS_DIR="${ROOT_PREFIX}${TLS_DIR}"
  KEYSTORE="${ROOT_PREFIX}${KEYSTORE}"
  ENV_FILE="${ROOT_PREFIX}${ENV_FILE}"
  NO_SYSTEMCTL="true"
fi

if [[ "${ROOT_PREFIX}" == "/" && "$(id -u)" -ne 0 ]]; then
  die "run as root on the VM (or use sudo)"
fi

WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

# --- fetch/parse the public chain -------------------------------------------
if [[ "${FROM_KEYVAULT}" == "true" ]]; then
  [[ -n "${VAULT_NAME}" && -n "${SECRET_NAME}" ]] \
    || die "--vault-name and --secret-name are required with --from-keyvault"
  command -v az >/dev/null 2>&1 || die "az CLI is required for --from-keyvault"
  BUNDLE="${WORK_DIR}/bundle.pem"
  log "downloading public certificate chain from Key Vault ${VAULT_NAME}/${SECRET_NAME}"
  az keyvault secret download \
    --vault-name "${VAULT_NAME}" \
    --name "${SECRET_NAME}" \
    --file "${BUNDLE}" \
    --encoding utf-8 \
    --only-show-errors

  csplit -s -z -f "${WORK_DIR}/cert-" -b '%02d.pem' "${BUNDLE}" \
    '/-----BEGIN CERTIFICATE-----/' '{*}'
  mapfile -t CERTS < <(find "${WORK_DIR}" -maxdepth 1 -name 'cert-*.pem' | sort)
  [[ ${#CERTS[@]} -ge 1 ]] || die "no certificates found in the Key Vault secret"
  CERT="${CERTS[0]}"
  if [[ ${#CERTS[@]} -ge 2 ]]; then
    CHAIN="${WORK_DIR}/chain.pem"
    : > "${CHAIN}"
    for index in "${!CERTS[@]}"; do
      [[ "${index}" -eq 0 ]] && continue
      cat "${CERTS[$index]}" >> "${CHAIN}"
    done
    if [[ -z "${CA}" ]]; then
      # The last certificate in the uploaded chain is the private root CA.
      CA="${CERTS[$(( ${#CERTS[@]} - 1 ))]}"
      log "WARN: no --ca supplied; using the last certificate in the bundle as the trust anchor"
      log "      verify this fingerprint out of band:"
      openssl x509 -in "${CA}" -noout -fingerprint -sha256 >&2
    fi
  fi
fi

[[ -n "${CERT}" && -f "${CERT}" ]] || die "--cert is required (or use --from-keyvault)"
[[ -n "${CHAIN}" && -f "${CHAIN}" ]] || CHAIN=""
[[ -n "${CA}" && -f "${CA}" ]] || die "--ca is required (or supply a bundle that contains the root)"

# --- validate cert/key/chain before touching the live keystore ---------------
VALIDATE_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/validate-certificate.sh"
bash "${VALIDATE_SCRIPT}" \
  --cert "${CERT}" --ca "${CA}" --hostname "${HOSTNAME}" --key "${KEY}"
# --- prepare directories and password ---------------------------------------
install -d -m 0750 "${TLS_DIR}" 2>/dev/null || mkdir -p "${TLS_DIR}"
install -d -m 0750 "$(dirname "${ENV_FILE}")" 2>/dev/null || mkdir -p "$(dirname "${ENV_FILE}")"

if [[ -n "${TLS_KEYSTORE_PASSWORD:-}" ]]; then
  KEYSTORE_PASSWORD="${TLS_KEYSTORE_PASSWORD}"
elif [[ -f "${ENV_FILE}" ]]; then
  KEYSTORE_PASSWORD="$(sed -n 's/^TLS_KEYSTORE_PASSWORD=//p' "${ENV_FILE}" | tail -n1 | tr -d '\r')"
else
  KEYSTORE_PASSWORD=""
fi
if [[ -z "${KEYSTORE_PASSWORD}" ]]; then
  KEYSTORE_PASSWORD="$(openssl rand -base64 32 | tr -d '\r\n')"
  log "generated a new keystore password"
fi
[[ "${KEYSTORE_PASSWORD}" =~ ^[A-Za-z0-9+/=._-]+$ ]] \
  || die "TLS_KEYSTORE_PASSWORD contains characters that are unsafe in a systemd EnvironmentFile"
export TLS_KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD}"

NEW_KEYSTORE="${WORK_DIR}/keystore.p12"
log "creating PKCS#12 keystore"
openssl pkcs12 -export \
  -inkey "${KEY}" \
  -in "${CERT}" \
  -certfile "${CHAIN:-${CA}}" \
  -name "${KEYSTORE_ALIAS}" \
  -out "${NEW_KEYSTORE}" \
  -passout env:TLS_KEYSTORE_PASSWORD
openssl pkcs12 -in "${NEW_KEYSTORE}" -noout -passin env:TLS_KEYSTORE_PASSWORD \
  || die "generated keystore cannot be opened with the chosen password"

# --- install files (with rollback point) ------------------------------------
umask 077
if [[ -f "${KEYSTORE}" ]]; then
  cp -p "${KEYSTORE}" "${KEYSTORE}.previous"
  log "backed up existing keystore to ${KEYSTORE}.previous"
fi

install_file() {
  local source="$1" destination="$2" mode="$3"
  if [[ -e "${destination}" \
        && "$(readlink -f "${source}")" == "$(readlink -f "${destination}")" ]]; then
    chmod "${mode}" "${destination}"
    return 0
  fi
  install -m "${mode}" "${source}" "${destination}"
}

install_file "${CERT}" "${TLS_DIR}/tls.crt" 0644
install_file "${CHAIN:-${CA}}" "${TLS_DIR}/chain.pem" 0644
install_file "${CA}" "${TLS_DIR}/ca.crt" 0644
install_file "${KEY}" "${TLS_DIR}/tls.key" 0600
install -m 0600 "${NEW_KEYSTORE}" "${KEYSTORE}"

cat > "${ENV_FILE}.new" <<EOF
PORT=${PORT}
TLS_KEYSTORE_PATH=${KEYSTORE}
TLS_KEYSTORE_PASSWORD=${KEYSTORE_PASSWORD}
TLS_KEYSTORE_TYPE=PKCS12
EOF
chmod 0600 "${ENV_FILE}.new"
mv -f "${ENV_FILE}.new" "${ENV_FILE}"

if [[ "${ROOT_PREFIX}" == "/" ]]; then
  chown -R "${APP_USER}:${APP_GROUP}" "${TLS_DIR}"
  chmod 0750 "${TLS_DIR}"
  chmod 0600 "${TLS_DIR}/tls.key" "${KEYSTORE}"
  chmod 0644 "${TLS_DIR}/tls.crt" "${TLS_DIR}/chain.pem" "${TLS_DIR}/ca.crt"
  chown root:root "${ENV_FILE}"
  chmod 0600 "${ENV_FILE}"
fi

ok "installed certificate, chain and keystore"
ls -l "${TLS_DIR}" "${ENV_FILE}" >&2

# --- restart and validate ----------------------------------------------------
if [[ "${SKIP_RESTART}" == "true" || "${NO_SYSTEMCTL}" == "true" ]]; then
  log "restart skipped (test mode or --skip-restart)"
  exit 0
fi

command -v systemctl >/dev/null 2>&1 || die "systemctl not found"

log "restarting ${SERVICE}"
if ! systemctl restart "${SERVICE}"; then
  systemctl status "${SERVICE}" --no-pager >&2 || true
  die "failed to restart ${SERVICE}"
fi
if ! systemctl is-active --quiet "${SERVICE}"; then
  journalctl -u "${SERVICE}" -n 50 --no-pager >&2 || true
  die "${SERVICE} is not active after restart"
fi

if command -v curl >/dev/null 2>&1; then
  log "validating https://${HOSTNAME}:${PORT}/health"
  HEALTH_OK="false"
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 5 \
        --cacert "${TLS_DIR}/ca.crt" \
        --resolve "${HOSTNAME}:${PORT}:127.0.0.1" \
        "https://${HOSTNAME}:${PORT}/health" | grep -q '"status":"UP"'; then
      HEALTH_OK="true"
      break
    fi
    sleep 2
  done
  if [[ "${HEALTH_OK}" != "true" ]]; then
    log "health validation failed after 10 attempts; rolling back the previous keystore"
    if [[ -f "${KEYSTORE}.previous" ]]; then
      install -m 0600 "${KEYSTORE}.previous" "${KEYSTORE}"
      systemctl restart "${SERVICE}" || true
    fi
    die "HTTPS health validation failed after installing the certificate"
  fi
  ok "HTTPS health endpoint returned status UP"
fi

ok "certificate installed and ${SERVICE} is healthy"
