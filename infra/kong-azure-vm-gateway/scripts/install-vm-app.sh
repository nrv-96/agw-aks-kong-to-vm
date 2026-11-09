#!/usr/bin/env bash
# Install the hello-app JAR + signed certificate/keystore on every backend VM
# through Azure VM Run Command. Runs entirely from the signing host.
#
# Usage:
#   ./scripts/install-vm-app.sh [--config config/config.yaml]
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    -h|--help)
      sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

JAR="${PROJECT_DIR}/../../target/hello-app.jar"
CA="${PROJECT_DIR}/pki/root-ca.crt"
HELLO_SCRIPT="${PROJECT_DIR}/vm/install-hello-service.sh"
CERT_SCRIPT="${PROJECT_DIR}/certificates/install-vm-certificate.sh"
VALIDATE_SCRIPT="${PROJECT_DIR}/certificates/validate-certificate.sh"

for file in "${JAR}" "${CA}" "${HELLO_SCRIPT}" "${CERT_SCRIPT}" "${VALIDATE_SCRIPT}"; do
  [[ -f "${file}" ]] || die "required file not found: ${file}"
done

b64() { base64 -w0 "$1"; }

JAR_B64="$(b64 "${JAR}")"
CA_B64="$(b64 "${CA}")"
HELLO_B64="$(b64 "${HELLO_SCRIPT}")"
CERT_SCRIPT_B64="$(b64 "${CERT_SCRIPT}")"
VALIDATE_B64="$(b64 "${VALIDATE_SCRIPT}")"

for vm in $(cfg '.backends[].name'); do
  CRT="${PROJECT_DIR}/pki/issued/${vm}.crt"
  CHAIN="${PROJECT_DIR}/pki/issued/${vm}-chain.pem"
  [[ -f "${CRT}" ]] || die "signed certificate not found: ${CRT}"
  [[ -f "${CHAIN}" ]] || die "signed chain not found: ${CHAIN}"

  log "installing app + certificate on ${vm} (${RESOURCE_GROUP})"

  VM_SCRIPT="$(cat <<EOF
#!/bin/sh
set -eu
DIR=/tmp/vm-install
mkdir -p "\$DIR"
echo '${JAR_B64}' | base64 -d > "\$DIR/hello-app.jar"
echo '${CA_B64}' | base64 -d > "\$DIR/root-ca.crt"
echo '$(b64 "${CRT}")' | base64 -d > "\$DIR/${vm}.crt"
echo '$(b64 "${CHAIN}")' | base64 -d > "\$DIR/${vm}-chain.pem"
echo '${HELLO_B64}' | base64 -d > "\$DIR/install-hello-service.sh"
echo '${CERT_SCRIPT_B64}' | base64 -d > "\$DIR/install-vm-certificate.sh"
echo '${VALIDATE_B64}' | base64 -d > "\$DIR/validate-certificate.sh"
chmod 0700 "\$DIR"
chmod 0600 "\$DIR/hello-app.jar"
chmod 0644 "\$DIR/root-ca.crt" "\$DIR/${vm}.crt" "\$DIR/${vm}-chain.pem"
chmod 0700 "\$DIR/install-hello-service.sh" "\$DIR/install-vm-certificate.sh" "\$DIR/validate-certificate.sh"

bash "\$DIR/install-hello-service.sh" \
  --jar "\$DIR/hello-app.jar" \
  --user hello --group hello --service hello-app \
  --port 8100

bash "\$DIR/install-vm-certificate.sh" \
  --cert "\$DIR/${vm}.crt" \
  --chain "\$DIR/${vm}-chain.pem" \
  --ca "\$DIR/root-ca.crt" \
  --key "/etc/hello/csr/${vm}.key" \
  --hostname "${BACKEND_HOSTNAME}" \
  --port 8100
EOF
)"

  TMP_SCRIPT="${PROJECT_DIR}/.install-vm-${vm}.sh"
  printf '%s\n' "${VM_SCRIPT}" > "${TMP_SCRIPT}"
  chmod 0600 "${TMP_SCRIPT}"
  if command -v wslpath >/dev/null 2>&1; then
    AZ_SCRIPT="$(wslpath -w "${TMP_SCRIPT}")"
  else
    AZ_SCRIPT="${TMP_SCRIPT}"
  fi

  az vm run-command invoke \
    --subscription "${SUBSCRIPTION_ID}" \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${vm}" \
    --command-id RunShellScript \
    --scripts "@${AZ_SCRIPT}" \
    --only-show-errors \
    --query "value[0].message" -o tsv

  rm -f "${TMP_SCRIPT}"
done

log "done. Next: install Kong in AKS."
