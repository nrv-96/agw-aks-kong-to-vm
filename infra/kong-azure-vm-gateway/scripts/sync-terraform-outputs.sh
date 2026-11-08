#!/usr/bin/env bash
# Write Terraform outputs (non-secret values) back into config/config.yaml.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_config
require_cmd terraform
require_cmd yq

TERRAFORM_DIR="${PROJECT_DIR}/terraform"
[[ -d "${TERRAFORM_DIR}" ]] || die "terraform directory not found: ${TERRAFORM_DIR}"

JSON="$(terraform -chdir="${TERRAFORM_DIR}" output -json)"

get() {
  local key="$1"
  yq -p=json -r ".[\"${key}\"].value // \"\"" <<< "${JSON}"
}

TENANT="$(get tenant_id)"
RG="$(get resource_group_name)"
AKS="$(get aks_name)"
OIDC="$(get aks_oidc_issuer_url)"
UAMI="$(get workload_identity_client_id)"
KV="$(get key_vault_name)"
VM1="$(get vm1_ip)"
VM2="$(get vm2_ip)"
LB="$(get kong_internal_lb_ip)"
AGW="$(get agw_public_ip)"

BACKUP="${CONFIG_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "${CONFIG_FILE}" "${BACKUP}"

if [[ -n "${TENANT}" ]]; then yq -i ".azure.tenant_id = \"${TENANT}\"" "${CONFIG_FILE}"; fi
if [[ -n "${RG}" ]]; then
  yq -i ".azure.resource_group.name = \"${RG}\"" "${CONFIG_FILE}"
  yq -i ".azure.aks.resource_group = \"${RG}\"" "${CONFIG_FILE}"
  yq -i ".azure.keyvault.resource_group = \"${RG}\"" "${CONFIG_FILE}"
  yq -i ".azure.private_dns.resource_group = \"${RG}\"" "${CONFIG_FILE}"
fi
if [[ -n "${AKS}" ]]; then yq -i ".azure.aks.name = \"${AKS}\"" "${CONFIG_FILE}"; fi
if [[ -n "${OIDC}" ]]; then yq -i ".azure.aks.oidc_issuer_url = \"${OIDC}\"" "${CONFIG_FILE}"; fi
if [[ -n "${UAMI}" ]]; then yq -i ".azure.keyvault.workload_identity_client_id = \"${UAMI}\"" "${CONFIG_FILE}"; fi
if [[ -n "${KV}" ]]; then yq -i ".azure.keyvault.name = \"${KV}\"" "${CONFIG_FILE}"; fi
if [[ -n "${VM1}" ]]; then yq -i ".backends[0].private_ip = \"${VM1}\"" "${CONFIG_FILE}"; fi
if [[ -n "${VM2}" ]]; then yq -i ".backends[1].private_ip = \"${VM2}\"" "${CONFIG_FILE}"; fi
if [[ -n "${LB}" ]]; then yq -i ".kong.internal_lb_ip = \"${LB}\"" "${CONFIG_FILE}"; fi
if [[ -n "${AGW}" ]]; then yq -i ".azure.agw.public_ip = \"${AGW}\"" "${CONFIG_FILE}"; fi

log "config updated from Terraform outputs (backup: ${BACKUP})"
log "tenant=${TENANT} rg=${RG} aks=${AKS} keyvault=${KV} lb=${LB} agw_public_ip=${AGW:-<not enabled>}"
