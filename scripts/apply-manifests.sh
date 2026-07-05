#!/usr/bin/env bash
set -euo pipefail

manifest_dir="${1:?usage: apply-manifests.sh <manifest-dir> [--wait-secrets] [--dry-run]}"
shift

dry_run=false
wait_secrets=false

for arg in "$@"; do
  case "${arg}" in
    --dry-run)
      dry_run=true
      ;;
    --wait-secrets)
      wait_secrets=true
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      exit 1
      ;;
  esac
done

: "${ACME_EMAIL:=henrique.zimermann@outlook.com.br}"
: "${CERTIFICATE_NAMESPACE:=networking}"
: "${CLOUDFLARE_EMAIL:=${ACME_EMAIL}}"
: "${CLUSTER_DOMAIN:=henriqzimer.com.br}"
: "${METALLB_ADDRESS_RANGE:=192.168.1.150-192.168.1.155}"

export ACME_EMAIL CERTIFICATE_NAMESPACE CLOUDFLARE_EMAIL CLUSTER_DOMAIN
export METALLB_ADDRESS_RANGE

rendered_dir="$(mktemp -d)"
trap 'rm -rf "${rendered_dir}"' EXIT

ensure_namespaces() {
  local namespaces

  mapfile -t namespaces < <(
    yq ea -r '
      [
        .metadata.namespace,
        .spec.destination.namespace
      ]
      | .[]
      | select(. != null and . != "")
    ' "${rendered_dir}"/*.yaml 2>/dev/null | sort -u
  )

  for namespace in "${namespaces[@]}"; do
    kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
    case "${namespace}" in
      monitoring | networking)
        kubectl label namespace "${namespace}" \
          pod-security.kubernetes.io/enforce=privileged \
          pod-security.kubernetes.io/audit=privileged \
          pod-security.kubernetes.io/warn=privileged \
          --overwrite >/dev/null
        ;;
    esac
  done
}

for manifest in "${manifest_dir}"/*.yaml; do
  [[ -e "${manifest}" ]] || continue
  envsubst <"${manifest}" >"${rendered_dir}/$(basename "${manifest}")"
done

if [[ "${dry_run}" == "true" ]]; then
  yq ea '.' "${rendered_dir}"/*.yaml >/dev/null
  echo "Rendered manifests from ${manifest_dir} successfully."
  exit 0
fi

ensure_namespaces
kubectl apply --validate=false -f "${rendered_dir}"

if [[ "${wait_secrets}" != "true" ]]; then
  exit 0
fi

mapfile -t secrets < <(
  yq ea -r '
    select(.kind == "VaultStaticSecret")
    | [.metadata.namespace, .spec.destination.name]
    | @tsv
  ' "${rendered_dir}"/*.yaml 2>/dev/null || true
)

for item in "${secrets[@]}"; do
  [[ -z "${item}" ]] && continue
  namespace="$(awk '{print $1}' <<<"${item}")"
  secret_name="$(awk '{print $2}' <<<"${item}")"

  echo "Waiting for synced secret ${namespace}/${secret_name}..."
  for _ in {1..60}; do
    if kubectl -n "${namespace}" get secret "${secret_name}" >/dev/null 2>&1; then
      echo "Secret ${namespace}/${secret_name} is ready."
      break
    fi
    sleep 2
  done

  kubectl -n "${namespace}" get secret "${secret_name}" >/dev/null
done
