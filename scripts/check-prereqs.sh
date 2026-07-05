#!/usr/bin/env bash
set -euo pipefail

required_tools=(envsubst helm helmfile kubectl yq)

if [[ -z "${KUBECONFIG:-}" && -f "../terraform-homelab/configs/kubeconfig" ]]; then
  export KUBECONFIG="../terraform-homelab/configs/kubeconfig"
fi

for tool in "${required_tools[@]}"; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Missing required tool: ${tool}" >&2
    exit 1
  fi
done

kubectl cluster-info >/dev/null

if [[ "${SKIP_BOOTSTRAP_SECRET_CHECK:-false}" == "true" ]]; then
  exit 0
fi

if ! kubectl -n secrets get secret vault-postgres-storage >/dev/null 2>&1; then
  if [[ -n "${VAULT_POSTGRES_CONNECTION_URL:-}" ]]; then
    ./scripts/ensure-vault-postgres-secret.sh
  else
    cat >&2 <<'EOF'
VAULT_POSTGRES_CONNECTION_URL is not set and secret/secrets/vault-postgres-storage does not exist.

Set it in .env before the first bootstrap, for example:
VAULT_POSTGRES_CONNECTION_URL='postgresql://vault:<password>@postgresql.example.com:5432/vault'
EOF
    exit 1
  fi
fi

if ! kubectl -n secrets get secret vault-postgres-storage >/dev/null 2>&1; then
  cat >&2 <<'EOF'
secret/secrets/vault-postgres-storage was not created successfully.
EOF
  exit 1
fi

if ! kubectl -n kube-system get secret talos-worker-config >/dev/null 2>&1; then
  cat >&2 <<'EOF'
secret/kube-system/talos-worker-config does not exist yet.

This is expected on a fresh cluster only if Vault already contains k8s-homelab/talos-worker-config.
If Vault is empty, run:
  make seed-vault-secrets
EOF
fi

if kubectl -n networking get secret cert-manager-token >/dev/null 2>&1; then
  cloudflare_token="$(
    kubectl -n networking get secret cert-manager-token \
      -o jsonpath='{.data.api-token}' 2>/dev/null | base64 -d 2>/dev/null || true
  )"

  if [[ -z "${cloudflare_token}" ]] || [[ "${cloudflare_token}" =~ ^Bearer[[:space:]] ]] || [[ "${cloudflare_token}" =~ [[:space:]] ]] || [[ "${#cloudflare_token}" -lt 40 ]]; then
    cat >&2 <<'EOF'
Warning:
secret/networking/cert-manager-token exists, but api-token does not look like a valid Cloudflare API Token.

Fix the Vault path k8s-homelab/cert-manager-token with key api-token, or temporarily set
CLOUDFLARE_API_TOKEN and run:
  make seed-vault-secrets

Use the raw Cloudflare API Token value only, without "Bearer", quotes, spaces, or the Tunnel token.
Required permissions: Zone:Read and DNS:Edit for the target zone.
EOF
    if [[ "${REQUIRE_VALID_CLOUDFLARE_TOKEN:-false}" == "true" ]]; then
      exit 1
    fi
  fi
fi
