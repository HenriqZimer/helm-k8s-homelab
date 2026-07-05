#!/usr/bin/env bash
set -euo pipefail

ensure_namespace() {
  local namespace="$1"
  shift

  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -

  if [[ "$#" -gt 0 ]]; then
    kubectl label namespace "${namespace}" "$@" --overwrite >/dev/null
  fi
}

ensure_namespace storage
ensure_namespace secrets
ensure_namespace scheduling
ensure_namespace development
ensure_namespace monitoring \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged
ensure_namespace networking \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged
