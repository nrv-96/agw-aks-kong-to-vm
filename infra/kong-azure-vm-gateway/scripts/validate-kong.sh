#!/usr/bin/env bash
# Verify the *runtime* Kong configuration, not just Kubernetes objects.
#
# Usage:
#   ./scripts/validate-kong.sh [--config FILE] [--local-port 18444] [--timeout 180]
#
# Checks:
#   - Kong Service for pairs-monitor-backend: protocol=https, tls_verify=true,
#     tls_verify_depth=1, referenced CA entity, upstream host.
#   - Kong CA entity matches ca.crt in the Kubernetes Secret (DER fingerprint).
#   - Upstream has exactly the configured VM targets.
#   - Active health checks are HTTPS with SNI/host/path verification enabled.
#   - Both targets report HEALTHY (polled up to --timeout).
#
# The Admin API is internal and self-signed, so the local loopback port-forward
# uses an unverified TLS context. This is admin-only and is not the backend path.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LOCAL_PORT="18444"
TIMEOUT="180"
PF_PID=""
PF_LOG=""
CA_PEM_FILE=""

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_config
require_cmd kubectl
require_cmd python3
load_kong_config

cleanup() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
  if [[ -n "${CA_PEM_FILE}" ]]; then
    rm -f "${CA_PEM_FILE}"
  fi
  if [[ -n "${PF_LOG}" ]]; then
    rm -f "${PF_LOG}"
  fi
}
trap cleanup EXIT INT TERM

DEPLOYMENT="$(kubectl_ns get deployment \
  -l "app.kubernetes.io/instance=${RELEASE_NAME},app.kubernetes.io/name=gateway" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${DEPLOYMENT}" ]] || die "Kong gateway Deployment not found in namespace ${NAMESPACE}"

kubectl_ns get secret "${CA_SECRET_NAME}" >/dev/null 2>&1 \
  || die "CA secret ${CA_SECRET_NAME} not found; cannot validate the CA entity"

CA_ID="$(kubectl_ns get secret "${CA_SECRET_NAME}" \
  -o jsonpath='{.data.id}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[[ -n "${CA_ID}" ]] || die "CA secret ${CA_SECRET_NAME} has no 'id' key"

CA_PEM_FILE="$(mktemp)"
kubectl_ns get secret "${CA_SECRET_NAME}" \
  -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "${CA_PEM_FILE}" 2>/dev/null || true
[[ -s "${CA_PEM_FILE}" ]] || die "CA secret ${CA_SECRET_NAME} has an empty 'ca.crt'"

PF_LOG="$(mktemp)"
log "starting port-forward deployment/${DEPLOYMENT} ${LOCAL_PORT}:8444"
kubectl_ns port-forward "deploy/${DEPLOYMENT}" "${LOCAL_PORT}:8444" \
  >"${PF_LOG}" 2>&1 &
PF_PID=$!

ADMIN_READY="false"
for _ in $(seq 1 30); do
  if python3 - "${LOCAL_PORT}" <<'PY'
import socket
import sys

try:
    with socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1):
        pass
except OSError:
    sys.exit(1)
PY
  then
    ADMIN_READY="true"
    break
  fi
  sleep 1
done
if [[ "${ADMIN_READY}" != "true" ]]; then
  cat "${PF_LOG}" >&2 || true
  die "Kong Admin API port-forward did not become ready on 127.0.0.1:${LOCAL_PORT}"
fi

export ADMIN_BASE="https://127.0.0.1:${LOCAL_PORT}"
export KONG_SERVICE_SUFFIX="pairs-monitor-backend"
export KONG_NAMESPACE="${NAMESPACE}"
export KONG_BACKEND_HOST="${BACKEND_HOSTNAME}"
export KONG_HEALTH_PATH="${HEALTH_PATH}"
export KONG_CA_ID="${CA_ID}"
export KONG_CA_PEM_FILE="${CA_PEM_FILE}"
export KONG_VM1="${VM1_IP}"
export KONG_VM2="${VM2_IP}"
export KONG_BACKEND_PORT="${BACKEND_PORT}"
export KONG_TIMEOUT="${TIMEOUT}"

log "validating Kong runtime configuration via ${ADMIN_BASE}"
python3 - <<'PY'
import hashlib
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ["ADMIN_BASE"]
SERVICE_SUFFIX = os.environ["KONG_SERVICE_SUFFIX"]
NAMESPACE = os.environ["KONG_NAMESPACE"]
BACKEND_HOST = os.environ["KONG_BACKEND_HOST"]
HEALTH_PATH = os.environ["KONG_HEALTH_PATH"]
CA_ID = os.environ["KONG_CA_ID"]
CA_PEM_FILE = os.environ["KONG_CA_PEM_FILE"]
VM1 = os.environ["KONG_VM1"]
VM2 = os.environ["KONG_VM2"]
BACKEND_PORT = os.environ["KONG_BACKEND_PORT"]
TIMEOUT = int(os.environ["KONG_TIMEOUT"])

SSL_CTX = ssl._create_unverified_context()  # admin-only loopback exception
FAILURES = []


def items(payload):
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        return payload.get("data") or []
    return []


def get(path):
    try:
        with urllib.request.urlopen(BASE + path, context=SSL_CTX, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise SystemExit(f"FAIL: GET {path} returned HTTP {error.code}: {error.reason}")
    except urllib.error.URLError as error:
        raise SystemExit(f"FAIL: GET {path} failed: {error.reason}")


def check(condition, message):
    if condition:
        print(f"OK   {message}")
    else:
        print(f"FAIL {message}", file=sys.stderr)
        FAILURES.append(message)


def poll_until(description, fetch, predicate, timeout=60):
    deadline = time.time() + timeout
    last = None
    while True:
        last = fetch()
        if predicate(last):
            return last
        if time.time() >= deadline:
            raise SystemExit(f"FAIL: {description}; last response: {last!r}")
        time.sleep(5)


def find_service(services):
    exact = f"service.{NAMESPACE}.{SERVICE_SUFFIX}"
    for service in services:
        if service.get("name") == exact:
            return service
    # KIC 3.5 names Gateway API services after the HTTPRoute (for example
    # httproute.kong.pairs-monitor.0), so match the Kubernetes Service tag.
    for service in services:
        tags = service.get("tags") or []
        if f"k8s-name:{SERVICE_SUFFIX}" in tags and "k8s-kind:Service" in tags:
            return service
    for service in services:
        if str(service.get("name", "")).endswith(SERVICE_SUFFIX):
            return service
    return None


# KIC may still be pushing configuration right after the policy is Accepted.
services = poll_until(
    f"Kong Service for {SERVICE_SUFFIX} not found",
    lambda: items(get("/services")),
    lambda candidates: find_service(candidates) is not None,
)
service = find_service(services)
print(f"OK   found Kong Service {service.get('name')!r}")
check(service.get("protocol") == "https",
      f"service.protocol is {service.get('protocol')!r}, expected 'https'")
check(service.get("tls_verify") is True,
      f"service.tls_verify is {service.get('tls_verify')!r}, expected true")
check(str(service.get("tls_verify_depth")) == "1",
      f"service.tls_verify_depth is {service.get('tls_verify_depth')!r}, expected 1")
ca_ids = service.get("ca_certificates") or []
check(CA_ID in ca_ids,
      f"service.ca_certificates contains {CA_ID!r} (actual: {ca_ids!r})")
check(str(service.get("port")) == BACKEND_PORT,
      f"service.port is {service.get('port')!r}, expected {BACKEND_PORT!r}")

upstream_name = service.get("host")
check(bool(upstream_name),
      f"service.host points at an upstream (actual: {upstream_name!r})")

upstreams = poll_until(
    f"Kong Upstream {upstream_name!r} not found",
    lambda: items(get("/upstreams")),
    lambda candidates: any(u.get("name") == upstream_name for u in candidates),
)
upstream = next(u for u in upstreams if u.get("name") == upstream_name)
print(f"OK   found Kong Upstream {upstream.get('name')!r}")

expected = sorted({f"{VM1}:{BACKEND_PORT}", f"{VM2}:{BACKEND_PORT}"})
target_items = poll_until(
    f"upstream targets for {upstream_name!r} do not match {expected!r}",
    lambda: items(get(f"/upstreams/{upstream['id']}/targets")),
    lambda entries: sorted({str(entry.get("target")) for entry in entries}) == expected,
)
targets = sorted({str(entry.get("target")) for entry in target_items})
check(targets == expected,
      f"upstream targets are exactly {expected!r} (actual: {targets!r})")

healthchecks = upstream.get("healthchecks") or {}
active = healthchecks.get("active") or {}
check(upstream.get("host_header") == BACKEND_HOST,
      f"upstream.host_header is {upstream.get('host_header')!r}, expected {BACKEND_HOST!r} "
      "(this drives the upstream Host header and TLS SNI)")
check(active.get("type") == "https",
      f"healthchecks.active.type is {active.get('type')!r}, expected 'https'")
check(active.get("http_path") == HEALTH_PATH,
      f"healthchecks.active.http_path is {active.get('http_path')!r}, expected {HEALTH_PATH!r}")
check(active.get("https_sni") == BACKEND_HOST,
      f"healthchecks.active.https_sni is {active.get('https_sni')!r}, expected {BACKEND_HOST!r}")
check(active.get("https_verify_certificate") is True,
      f"healthchecks.active.https_verify_certificate is "
      f"{active.get('https_verify_certificate')!r}, expected true")

ca_entity = get(f"/ca_certificates/{CA_ID}")
kong_cert = ca_entity.get("cert") or ""
with open(CA_PEM_FILE, "r", encoding="utf-8") as handle:
    secret_cert = handle.read()
try:
    kong_der = ssl.PEM_cert_to_DER_cert(kong_cert)
    secret_der = ssl.PEM_cert_to_DER_cert(secret_cert)
except ValueError as error:
    raise SystemExit(f"FAIL: CA certificate PEM parse error: {error}")
check(
    hashlib.sha256(kong_der).hexdigest() == hashlib.sha256(secret_der).hexdigest(),
    f"Kong CA entity {CA_ID!r} matches the Kubernetes Secret ca.crt",
)

# Active checks need time to run after a config push or rollout.
deadline = time.time() + TIMEOUT
last_health = {}
while True:
    health_items = items(get(f"/upstreams/{upstream['id']}/health"))
    last_health = {
        str(item.get("target")): str(item.get("health")) for item in health_items
    }
    if all(last_health.get(target) == "HEALTHY" for target in expected):
        break
    if time.time() >= deadline:
        break
    time.sleep(5)

check(
    all(last_health.get(target) == "HEALTHY" for target in expected),
    f"upstream targets are HEALTHY (actual: {last_health!r})",
)

if FAILURES:
    print(f"\n{len(FAILURES)} runtime check(s) failed", file=sys.stderr)
    sys.exit(1)

print("\nAll Kong runtime checks passed")
PY

log "Kong runtime validation passed"
