#!/usr/bin/env bash
set -euo pipefail

: "${VAULT_NAMESPACE:=secrets}"
: "${VAULT_POD:=hashicorp-vault-0}"
: "${VAULT_MOUNT:=k8s-homelab}"
: "${VAULT_CREDENTIALS_FILE:=../scripts-k8s-homelab/vault/vault-credentials.txt}"
: "${TALOS_WORKER_CONFIG_FILE:=../terraform-homelab/configs/karpenter-talos-worker-user-data.yaml}"

require_tool() {
  if ! command -v "${1}" >/dev/null 2>&1; then
    echo "Missing required tool: ${1}" >&2
    exit 1
  fi
}

secret_value() {
  local namespace="${1}"
  local secret_name="${2}"
  local key="${3}"

  kubectl -n "${namespace}" get secret "${secret_name}" \
    -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

load_vault_token() {
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    printf '%s' "${VAULT_TOKEN}"
    return
  fi

  if [[ -f "${VAULT_CREDENTIALS_FILE}" ]]; then
    sed -n 's/^ROOT_TOKEN=//p' "${VAULT_CREDENTIALS_FILE}" | tail -n1
    return
  fi
}

vault_kv_put() {
  local path="${1}"
  local payload="${2}"

  kubectl -n "${VAULT_NAMESPACE}" exec -i "${VAULT_POD}" -- sh -c '
    token="${1}"
    mount="${2}"
    path="${3}"
    tmp="$(mktemp)"
    cat >"${tmp}"
    VAULT_TOKEN="${token}" vault kv put -mount="${mount}" "${path}" @"${tmp}" >/dev/null
    rm -f "${tmp}"
  ' sh "${vault_token}" "${VAULT_MOUNT}" "${path}" <<<"${payload}"

  echo "Seeded Vault path ${VAULT_MOUNT}/${path}."
}

seed_proxmox_credentials() {
  local url="${PROXMOX_API_URL:-}"
  local token_id="${PROXMOX_API_TOKEN_ID:-}"
  local token_secret="${PROXMOX_API_TOKEN_SECRET:-}"
  local insecure="${PROXMOX_INSECURE:-true}"
  local region="${PROXMOX_REGION:-pve}"
  local config_yaml

  if [[ -z "${url}" || -z "${token_id}" || -z "${token_secret}" ]]; then
    config_yaml="$(secret_value kube-system ccm-proxmox-credentials config\\.yaml)"
    if [[ -n "${config_yaml}" ]]; then
      url="$(yq -r '.clusters[0].url // ""' <<<"${config_yaml}")"
      token_id="$(yq -r '.clusters[0].token_id // ""' <<<"${config_yaml}")"
      token_secret="$(yq -r '.clusters[0].token_secret // ""' <<<"${config_yaml}")"
      insecure="$(yq -r '.clusters[0].insecure // true' <<<"${config_yaml}")"
      region="$(yq -r '.clusters[0].region // "pve"' <<<"${config_yaml}")"
    fi
  fi

  if [[ -z "${url}" || -z "${token_id}" || -z "${token_secret}" ]]; then
    echo "Skipping proxmox-credentials: missing values and no existing Kubernetes Secret found." >&2
    return
  fi

  vault_kv_put proxmox-credentials "$(
    jq -n \
      --arg url "${url}" \
      --arg token_id "${token_id}" \
      --arg token_secret "${token_secret}" \
      --argjson insecure "${insecure}" \
      --arg region "${region}" \
      '{url:$url, token_id:$token_id, token_secret:$token_secret, insecure:$insecure, region:$region}'
  )"
}

seed_grafana_credentials() {
  local admin_user="${GRAFANA_ADMIN_USER:-}"
  local admin_password="${GRAFANA_ADMIN_PASSWORD:-}"
  local postgres_url="${GRAFANA_POSTGRES_URL:-}"

  [[ -n "${admin_user}" ]] || admin_user="$(secret_value monitoring grafana-credentials admin-user)"
  [[ -n "${admin_password}" ]] || admin_password="$(secret_value monitoring grafana-credentials admin-password)"
  [[ -n "${postgres_url}" ]] || postgres_url="$(secret_value monitoring grafana-credentials postgres-url)"

  if [[ -z "${admin_user}" || -z "${admin_password}" ]]; then
    echo "Skipping grafana-credentials: missing values and no existing Kubernetes Secret found." >&2
    return
  fi

  vault_kv_put grafana-credentials "$(
    jq -n \
      --arg admin_user "${admin_user}" \
      --arg admin_password "${admin_password}" \
      --arg postgres_url "${postgres_url}" \
      '{"admin-user":$admin_user, "admin-password":$admin_password, "postgres-url":$postgres_url}'
  )"
}

seed_portainer_credentials() {
  local password="${PORTAINER_ADMIN_PASSWORD:-}"

  [[ -n "${password}" ]] || password="$(secret_value monitoring portainer-admin-password password)"

  if [[ -z "${password}" ]]; then
    echo "Skipping portainer-admin-password: missing value and no existing Kubernetes Secret found." >&2
    return
  fi

  vault_kv_put portainer-admin-password "$(jq -n --arg password "${password}" '{password:$password}')"
}

seed_cert_manager_token() {
  local api_token="${CLOUDFLARE_API_TOKEN:-${CLOUDFLARE_DNS_API_TOKEN:-${CF_API_TOKEN:-${CF_DNS_API_TOKEN:-}}}}"

  [[ -n "${api_token}" ]] || api_token="$(secret_value networking cert-manager-token api-token)"

  if [[ -z "${api_token}" ]]; then
    echo "Skipping cert-manager-token: missing Cloudflare API token and no existing Kubernetes Secret found." >&2
    return
  fi

  if [[ "${api_token}" =~ ^Bearer[[:space:]] ]] || [[ "${api_token}" =~ [[:space:]] ]] || [[ "${#api_token}" -lt 40 ]]; then
    cat >&2 <<'EOF'
Skipping cert-manager-token: Cloudflare token format looks invalid.

Use a Cloudflare API Token value only, without "Bearer", quotes, spaces, or the Tunnel token.
Required permissions: Zone:Read and DNS:Edit for the target zone.
EOF
    return
  fi

  vault_kv_put cert-manager-token "$(jq -n --arg api_token "${api_token}" '{"api-token":$api_token}')"
}

seed_romm_credentials() {
  local db_passwd="${ROMM_DB_PASSWORD:-}"
  local mysql_root_password="${ROMM_MYSQL_ROOT_PASSWORD:-}"
  local auth_secret_key="${ROMM_AUTH_SECRET_KEY:-}"
  local igdb_client_id="${ROMM_IGDB_CLIENT_ID:-}"
  local igdb_client_secret="${ROMM_IGDB_CLIENT_SECRET:-}"
  local steamgriddb_api_key="${ROMM_STEAMGRIDDB_API_KEY:-}"
  local mobygames_api_key="${ROMM_MOBYGAMES_API_KEY:-}"
  local retroachievements_api_key="${ROMM_RETROACHIEVEMENTS_API_KEY:-}"

  if [[ -z "${db_passwd}" ]]; then
    db_passwd="$(secret_value gaming romm-credentials DB_PASSWD)"
    mysql_root_password="$(secret_value gaming romm-credentials MYSQL_ROOT_PASSWORD)"
    auth_secret_key="$(secret_value gaming romm-credentials ROMM_AUTH_SECRET_KEY)"
    igdb_client_id="$(secret_value gaming romm-credentials IGDB_CLIENT_ID)"
    igdb_client_secret="$(secret_value gaming romm-credentials IGDB_CLIENT_SECRET)"
    steamgriddb_api_key="$(secret_value gaming romm-credentials STEAMGRIDDB_API_KEY)"
    mobygames_api_key="$(secret_value gaming romm-credentials MOBYGAMES_API_KEY)"
    retroachievements_api_key="$(secret_value gaming romm-credentials RETROACHIEVEMENTS_API_KEY)"
  fi

  # Senhas/chave de auth sao internas ao cluster (nao precisam de input manual):
  # gera automaticamente na primeira vez, se ainda nao existirem.
  [[ -n "${db_passwd}" ]] || db_passwd="$(openssl rand -hex 24)"
  [[ -n "${mysql_root_password}" ]] || mysql_root_password="$(openssl rand -hex 24)"
  [[ -n "${auth_secret_key}" ]] || auth_secret_key="$(openssl rand -hex 32)"

  vault_kv_put romm-credentials "$(
    jq -n \
      --arg db_passwd "${db_passwd}" \
      --arg mysql_root_password "${mysql_root_password}" \
      --arg auth_secret_key "${auth_secret_key}" \
      --arg igdb_client_id "${igdb_client_id}" \
      --arg igdb_client_secret "${igdb_client_secret}" \
      --arg steamgriddb_api_key "${steamgriddb_api_key}" \
      --arg mobygames_api_key "${mobygames_api_key}" \
      --arg retroachievements_api_key "${retroachievements_api_key}" \
      '{
        "DB_PASSWD": $db_passwd,
        "MYSQL_PASSWORD": $db_passwd,
        "MYSQL_ROOT_PASSWORD": $mysql_root_password,
        "ROMM_AUTH_SECRET_KEY": $auth_secret_key,
        "IGDB_CLIENT_ID": $igdb_client_id,
        "IGDB_CLIENT_SECRET": $igdb_client_secret,
        "STEAMGRIDDB_API_KEY": $steamgriddb_api_key,
        "MOBYGAMES_API_KEY": $mobygames_api_key,
        "RETROACHIEVEMENTS_API_KEY": $retroachievements_api_key
      }'
  )"

  if [[ -z "${igdb_client_id}" ]]; then
    cat >&2 <<'EOF'
romm-credentials: IGDB_CLIENT_ID/IGDB_CLIENT_SECRET/STEAMGRIDDB_API_KEY/MOBYGAMES_API_KEY/
RETROACHIEVEMENTS_API_KEY nao foram definidos - RomM funciona sem eles, so nao
enriquece metadados desses provedores. Para adicionar depois, exporte
ROMM_IGDB_CLIENT_ID etc. e rode "make seed-vault-secrets" de novo.
EOF
  fi
}

seed_talos_worker_config() {
  local user_data
  local meta_data
  local network_config

  if [[ -f "${TALOS_WORKER_CONFIG_FILE}" ]]; then
    user_data="$(<"${TALOS_WORKER_CONFIG_FILE}")"
  else
    user_data="$(secret_value kube-system talos-worker-config user-data)"
  fi

  if [[ -z "${user_data}" ]]; then
    cat >&2 <<EOF
Skipping talos-worker-config: no worker user-data source found.

Expected Terraform output:
  ${TALOS_WORKER_CONFIG_FILE}

Run terraform-homelab first, or set TALOS_WORKER_CONFIG_FILE to the generated Talos worker user-data file.
EOF
    return
  fi

  meta_data="$(cat <<'EOF'
hostname: {{ .Hostname }}
local-hostname: {{ .Hostname }}
instance-id: {{ .InstanceID }}
{{- if .InstanceType }}
instance-type: {{ .InstanceType }}
{{- end }}
{{- if .ProviderID }}
provider-id: {{ .ProviderID }}
{{- end }}
region: {{ .Region }}
zone: {{ .Zone }}
availability-zone: {{ .Zone }}
EOF
)"

  network_config="$(cat <<'EOF'
version: 1
config:
  - type: physical
    name: eth0
    subnets:
      - type: dhcp
EOF
)"

  vault_kv_put talos-worker-config "$(
    jq -n \
      --arg user_data "${user_data}" \
      --arg meta_data "${meta_data}" \
      --arg network_config "${network_config}" \
      '{"user-data":$user_data, "meta-data":$meta_data, "network-config":$network_config}'
  )"
}

require_tool jq
require_tool kubectl
require_tool yq

if [[ "${SEED_VAULT_SKIP_IF_UNAVAILABLE:-false}" == "true" ]] \
  && ! kubectl -n "${VAULT_NAMESPACE}" get pod "${VAULT_POD}" >/dev/null 2>&1; then
  echo "Vault pod ${VAULT_NAMESPACE}/${VAULT_POD} is not available yet; skipping Vault seed."
  exit 0
fi

vault_token="$(load_vault_token)"
if [[ -z "${vault_token}" ]]; then
  cat >&2 <<EOF
VAULT_TOKEN is not set and ${VAULT_CREDENTIALS_FILE} was not found.

Set VAULT_TOKEN or point VAULT_CREDENTIALS_FILE to the file created by scripts-k8s-homelab/vault/vault-init.sh.
EOF
  exit 1
fi

if ! kubectl -n "${VAULT_NAMESPACE}" exec "${VAULT_POD}" -- vault status >/dev/null 2>&1; then
  if [[ "${SEED_VAULT_SKIP_IF_UNAVAILABLE:-false}" == "true" ]]; then
    echo "Vault is not ready yet; skipping Vault seed."
    exit 0
  fi

  kubectl -n "${VAULT_NAMESPACE}" exec "${VAULT_POD}" -- vault status >/dev/null
fi

seed_proxmox_credentials
seed_grafana_credentials
seed_portainer_credentials
seed_cert_manager_token
seed_romm_credentials
seed_talos_worker_config
