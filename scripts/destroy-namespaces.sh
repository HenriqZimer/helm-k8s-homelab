#!/usr/bin/env bash
set -euo pipefail

namespaces=(
  development
  monitoring
  networking
  scheduling
  secrets
  storage
)

cleanup_vault_secret_finalizers() {
  local namespace="$1"
  local resources

  mapfile -t resources < <(
    kubectl api-resources \
      --api-group=secrets.hashicorp.com \
      --namespaced=true \
      -o name 2>/dev/null || true
  )

  for resource in "${resources[@]}"; do
    local items
    mapfile -t items < <(
      kubectl -n "${namespace}" get "${resource}" \
        -o name \
        --ignore-not-found 2>/dev/null || true
    )

    for item in "${items[@]}"; do
      echo "Removing finalizers from ${namespace}/${item}..."
      kubectl -n "${namespace}" patch "${item}" \
        --type=merge \
        -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      kubectl -n "${namespace}" delete "${item}" \
        --ignore-not-found \
        --wait=false >/dev/null 2>&1 || true
    done
  done
}

for namespace in "${namespaces[@]}"; do
  if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    cleanup_vault_secret_finalizers "${namespace}"
    echo "Deleting namespace ${namespace}..."
    kubectl delete namespace "${namespace}" --ignore-not-found --wait=false
  else
    echo "Namespace ${namespace} already absent."
  fi
done

for namespace in "${namespaces[@]}"; do
  if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    echo "Waiting for namespace ${namespace} to terminate..."
    if ! kubectl wait \
      --for=delete "namespace/${namespace}" \
      --timeout="${NAMESPACE_DELETE_TIMEOUT:-300s}" >/dev/null 2>&1; then
      echo "Namespace ${namespace} is still terminating. Remaining conditions:"
      kubectl get namespace "${namespace}" -o json 2>/dev/null \
        | yq -r '.status.conditions[]? | "- " + .type + ": " + .reason + " - " + .message' || true
    fi
  fi
done
