#!/usr/bin/env bash
# Restart hello-app and validate its local HTTPS health endpoint.
#
# Usage:
#   ./vm/reload-application.sh [--service hello-app] [--hostname be.internal.example.com]
#       [--port 8100] [--ca /etc/hello/tls/ca.crt] [--timeout 30]
#       [--root-prefix /] [--no-systemctl]
set -euo pipefail

SERVICE="hello-app"
HOSTNAME="be.internal.example.com"
PORT="8100"
CA="/etc/hello/tls/ca.crt"
TIMEOUT="30"
ROOT_PREFIX="/"
NO_SYSTEMCTL="false"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE="${2:?}"; shift 2 ;;
    --hostname) HOSTNAME="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --ca) CA="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --root-prefix) ROOT_PREFIX="${2:?}"; shift 2 ;;
    --no-systemctl) NO_SYSTEMCTL="true"; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

ROOT_PREFIX="${ROOT_PREFIX%/}"
[[ -n "${ROOT_PREFIX}" ]] || ROOT_PREFIX="/"
if [[ "${ROOT_PREFIX}" != "/" ]]; then
  CA="${ROOT_PREFIX}${CA}"
  NO_SYSTEMCTL="true"
fi

if [[ "${NO_SYSTEMCTL}" == "true" ]]; then
  log "systemctl/validation skipped (test mode or --no-systemctl)"
  exit 0
fi

command -v systemctl >/dev/null 2>&1 || die "systemctl not found"
[[ -f "${CA}" ]] || die "CA file not found: ${CA}"

log "restarting ${SERVICE}"
systemctl restart "${SERVICE}" || {
  systemctl --no-pager --full status "${SERVICE}" >&2 || true
  die "failed to restart ${SERVICE}"
}
systemctl is-active --quiet "${SERVICE}" \
  || { journalctl -u "${SERVICE}" -n 50 --no-pager >&2 || true; die "${SERVICE} is not active"; }

command -v curl >/dev/null 2>&1 || { log "WARN: curl not found; skipping HTTPS validation"; exit 0; }

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  if BODY="$(curl -fsS --max-time 5 \
      --cacert "${CA}" \
      --resolve "${HOSTNAME}:${PORT}:127.0.0.1" \
      "https://${HOSTNAME}:${PORT}/health" 2>/dev/null)"; then
    if grep -q '"status":"UP"' <<< "${BODY}" && grep -q '"service":"hello-app"' <<< "${BODY}"; then
      log "HTTPS health OK: ${BODY}"
      exit 0
    fi
  fi
  if (( $(date +%s) >= deadline )); then
    journalctl -u "${SERVICE}" -n 50 --no-pager >&2 || true
    die "HTTPS health validation failed for ${HOSTNAME}:${PORT} within ${TIMEOUT}s"
  fi
  sleep 2
done
