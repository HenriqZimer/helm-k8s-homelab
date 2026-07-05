#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while IFS= read -r -d '' manifest; do
  mapfile -t namespaces < <(
    yq ea -N -r '.metadata.namespace | select(. != null and . != "")' "${manifest}" | sort -u
  )

  for namespace in "${namespaces[@]}"; do
    kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
  done

  kubectl apply -f "${manifest}"
done < <(find "${root_dir}" -maxdepth 2 -name 'vault-auth.yaml' -print0 | sort -z)
