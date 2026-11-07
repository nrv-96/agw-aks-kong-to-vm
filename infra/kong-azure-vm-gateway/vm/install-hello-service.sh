#!/usr/bin/env bash
# Install the hello-app jar, dedicated system user, directories and systemd unit.
# Runs ON the VM as root. Certificate/keystore installation is separate.
#
# Usage:
#   ./vm/install-hello-service.sh --jar target/hello-app.jar [--root-prefix /]
#       [--user hello] [--group hello] [--service hello-app]
#       [--install-dir /opt/hello-app] [--config-dir /etc/hello]
#       [--tls-dir /etc/hello/tls] [--env-file /etc/hello/hello.env]
#       [--java-bin /usr/bin/java] [--port 8100] [--start] [--no-systemctl]
set -euo pipefail

ROOT_PREFIX="/"
JAR=""
APP_USER="hello"
APP_GROUP="hello"
SERVICE="hello-app"
INSTALL_DIR="/opt/hello-app"
CONFIG_DIR="/etc/hello"
TLS_DIR="/etc/hello/tls"
ENV_FILE="/etc/hello/hello.env"
JAR_NAME="hello-app.jar"
JAVA_BIN="/usr/bin/java"
PORT="8100"
START="false"
NO_SYSTEMCTL="false"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root-prefix) ROOT_PREFIX="${2:?}"; shift 2 ;;
    --jar) JAR="${2:?}"; shift 2 ;;
    --user) APP_USER="${2:?}"; shift 2 ;;
    --group) APP_GROUP="${2:?}"; shift 2 ;;
    --service) SERVICE="${2:?}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:?}"; shift 2 ;;
    --config-dir) CONFIG_DIR="${2:?}"; shift 2 ;;
    --tls-dir) TLS_DIR="${2:?}"; shift 2 ;;
    --env-file) ENV_FILE="${2:?}"; shift 2 ;;
    --jar-name) JAR_NAME="${2:?}"; shift 2 ;;
    --java-bin) JAVA_BIN="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --start) START="true"; shift ;;
    --no-systemctl) NO_SYSTEMCTL="true"; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${JAR}" && -f "${JAR}" ]] || die "--jar is required and must exist"
[[ "${SERVICE}" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "invalid --service name"
[[ "${APP_USER}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid --user name"
[[ "${PORT}" =~ ^[0-9]+$ ]] || die "--port must be numeric"

ROOT_PREFIX="${ROOT_PREFIX%/}"
[[ -n "${ROOT_PREFIX}" ]] || ROOT_PREFIX="/"

LOGICAL_INSTALL="${INSTALL_DIR}"
LOGICAL_CONFIG="${CONFIG_DIR}"
LOGICAL_TLS="${TLS_DIR}"
LOGICAL_ENV="${ENV_FILE}"
LOGICAL_JAVA="${JAVA_BIN}"

if [[ "${ROOT_PREFIX}" != "/" ]]; then
  INSTALL_DIR="${ROOT_PREFIX}${INSTALL_DIR}"
  CONFIG_DIR="${ROOT_PREFIX}${CONFIG_DIR}"
  TLS_DIR="${ROOT_PREFIX}${TLS_DIR}"
  ENV_FILE="${ROOT_PREFIX}${ENV_FILE}"
  NO_SYSTEMCTL="true"
fi

if [[ "${ROOT_PREFIX}" == "/" && "$(id -u)" -ne 0 ]]; then
  die "run as root on the VM (or use sudo)"
fi

# --- user/group --------------------------------------------------------------
if [[ "${ROOT_PREFIX}" == "/" ]]; then
  getent group "${APP_GROUP}" >/dev/null 2>&1 || groupadd --system "${APP_GROUP}"
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    useradd --system \
      --gid "${APP_GROUP}" \
      --home-dir "${LOGICAL_INSTALL}" \
      --shell /usr/sbin/nologin \
      "${APP_USER}"
    log "created system user ${APP_USER}"
  fi
fi

# --- directories -------------------------------------------------------------
install -d -m 0755 "${INSTALL_DIR}"
install -d -m 0750 "${CONFIG_DIR}" "${TLS_DIR}"
install -m 0644 "${JAR}" "${INSTALL_DIR}/${JAR_NAME}"

if [[ "${ROOT_PREFIX}" == "/" ]]; then
  chown root:root "${INSTALL_DIR}" "${INSTALL_DIR}/${JAR_NAME}" "${CONFIG_DIR}"
  chown "${APP_USER}:${APP_GROUP}" "${TLS_DIR}"
  chmod 0750 "${TLS_DIR}"
fi

# --- environment file (do not overwrite an existing password) ----------------
if [[ ! -f "${ENV_FILE}" ]]; then
  cat > "${ENV_FILE}" <<EOF
PORT=${PORT}
TLS_KEYSTORE_PATH=${LOGICAL_TLS}/keystore.p12
TLS_KEYSTORE_TYPE=PKCS12
EOF
  chmod 0600 "${ENV_FILE}"
  [[ "${ROOT_PREFIX}" == "/" ]] && chown root:root "${ENV_FILE}"
  log "created ${ENV_FILE}; certificate installation will add TLS_KEYSTORE_PASSWORD"
fi

# --- systemd unit ------------------------------------------------------------
UNIT_DIR="${ROOT_PREFIX}/etc/systemd/system"
if [[ "${ROOT_PREFIX}" != "/" ]]; then
  UNIT_DIR="${ROOT_PREFIX}/etc/systemd/system"
fi
install -d -m 0755 "${UNIT_DIR}"
UNIT_FILE="${UNIT_DIR}/${SERVICE}.service"

cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=hello-app HTTPS service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
EnvironmentFile=${LOGICAL_ENV}
ExecStart=${LOGICAL_JAVA} -jar ${LOGICAL_INSTALL}/${JAR_NAME}
Restart=on-failure
RestartSec=5s
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "${UNIT_FILE}"
log "wrote ${UNIT_FILE}"

# --- Java check --------------------------------------------------------------
if [[ -x "${JAVA_BIN}" ]]; then
  JAVA_VERSION="$("${JAVA_BIN}" -version 2>&1 | head -n1)"
  JAVA_MAJOR="$(sed -E 's/.*version "([0-9]+).*/\1/' <<< "${JAVA_VERSION}")"
  if [[ "${JAVA_MAJOR}" =~ ^[0-9]+$ ]] && (( JAVA_MAJOR >= 21 )); then
    log "Java OK: ${JAVA_VERSION}"
  else
    log "WARN: ${JAVA_BIN} is not Java 21+: ${JAVA_VERSION}"
  fi
else
  log "WARN: ${JAVA_BIN} not found; install a Java 21 runtime before starting ${SERVICE}"
fi

# --- enable/start ------------------------------------------------------------
if [[ "${NO_SYSTEMCTL}" == "true" ]]; then
  log "systemctl skipped (test mode or --no-systemctl)"
  exit 0
fi

systemctl daemon-reload
systemctl enable "${SERVICE}"

if [[ "${START}" == "true" ]]; then
  if [[ ! -s "${LOGICAL_TLS}/keystore.p12" ]]; then
    log "keystore not installed yet; run ./certificates/install-vm-certificate.sh before starting"
    exit 0
  fi
  systemctl restart "${SERVICE}"
  systemctl --no-pager --full status "${SERVICE}" | head -n 20 >&2 || true
else
  log "service ${SERVICE} enabled but not started; install the certificate/keystore first"
fi
