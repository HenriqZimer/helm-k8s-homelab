#!/usr/bin/env bash
set -euo pipefail

namespace="secrets"
secret_name="vault-postgres-storage"

kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n "${namespace}" get secret "${secret_name}" >/dev/null 2>&1; then
  echo "Secret ${namespace}/${secret_name} already exists; keeping current value."
  exit 0
fi

if [[ -z "${VAULT_POSTGRES_CONNECTION_URL:-}" ]]; then
  echo "VAULT_POSTGRES_CONNECTION_URL is required to create ${namespace}/${secret_name}." >&2
  exit 1
fi

kubectl -n "${namespace}" create secret generic "${secret_name}" \
  --from-literal=connection_url="${VAULT_POSTGRES_CONNECTION_URL}"
