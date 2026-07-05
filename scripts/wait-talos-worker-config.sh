#!/usr/bin/env bash
set -euo pipefail

: "${TALOS_WORKER_CONFIG_FILE:=../terraform-homelab/configs/karpenter-talos-worker-user-data.yaml}"
: "${TALOS_WORKER_CONFIG_NAMESPACE:=kube-system}"
: "${TALOS_WORKER_CONFIG_SECRET:=talos-worker-config}"
: "${TALOS_WORKER_CONFIG_VSS:=talos-worker-config-sync}"
: "${TALOS_WORKER_CONFIG_TIMEOUT:=120}"

if [[ ! -f "${TALOS_WORKER_CONFIG_FILE}" ]]; then
  echo "Talos worker config file ${TALOS_WORKER_CONFIG_FILE} does not exist; skipping sync wait."
  exit 0
fi

if ! kubectl -n "${TALOS_WORKER_CONFIG_NAMESPACE}" get vaultstaticsecret "${TALOS_WORKER_CONFIG_VSS}" >/dev/null 2>&1; then
  echo "VaultStaticSecret ${TALOS_WORKER_CONFIG_NAMESPACE}/${TALOS_WORKER_CONFIG_VSS} does not exist yet; skipping sync wait."
  exit 0
fi

expected_hash="$(
  perl -0pe 's/\n\z//' "${TALOS_WORKER_CONFIG_FILE}" | sha256sum | awk '{print $1}'
)"

kubectl -n "${TALOS_WORKER_CONFIG_NAMESPACE}" annotate \
  "vaultstaticsecret/${TALOS_WORKER_CONFIG_VSS}" \
  "homelab.henriqzimer.com.br/reconcile-ts=$(date +%s)" \
  --overwrite >/dev/null

deadline=$((SECONDS + TALOS_WORKER_CONFIG_TIMEOUT))

while (( SECONDS < deadline )); do
  secret_keys="$(
    kubectl -n "${TALOS_WORKER_CONFIG_NAMESPACE}" get secret "${TALOS_WORKER_CONFIG_SECRET}" \
      -o jsonpath='{.data}' 2>/dev/null || true
  )"

  current_hash="$(
    kubectl -n "${TALOS_WORKER_CONFIG_NAMESPACE}" get secret "${TALOS_WORKER_CONFIG_SECRET}" \
      -o jsonpath='{.data.user-data}' 2>/dev/null \
      | base64 -d 2>/dev/null \
      | sha256sum \
      | awk '{print $1}'
  )"

  if [[ "${current_hash}" == "${expected_hash}" ]] \
    && [[ "${secret_keys}" == *"meta-data"* ]] \
    && [[ "${secret_keys}" == *"network-config"* ]]; then
    echo "Secret ${TALOS_WORKER_CONFIG_NAMESPACE}/${TALOS_WORKER_CONFIG_SECRET} matches ${TALOS_WORKER_CONFIG_FILE}."
    exit 0
  fi

  sleep 5
done

echo "Timed out waiting for ${TALOS_WORKER_CONFIG_NAMESPACE}/${TALOS_WORKER_CONFIG_SECRET} to match ${TALOS_WORKER_CONFIG_FILE}." >&2
exit 1
