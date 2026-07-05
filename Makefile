SHELL := /usr/bin/env bash

.PHONY: apply sync diff destroy destroy-namespaces lint template repos check seed-vault-secrets status

ENV_FILE ?= .env

define with_env
set -euo pipefail; \
if [[ -f "$(ENV_FILE)" ]]; then set -a; source "$(ENV_FILE)"; set +a; fi; \
if [[ -z "$${KUBECONFIG:-}" && -f "../terraform-homelab/configs/kubeconfig" ]]; then export KUBECONFIG="../terraform-homelab/configs/kubeconfig"; fi; \
$1
endef

apply: check
	@$(call with_env,./scripts/ensure-namespaces.sh)
	@$(call with_env,SEED_VAULT_SKIP_IF_UNAVAILABLE=true ./scripts/seed-vault-secrets.sh)
	@$(call with_env,./scripts/wait-talos-worker-config.sh)
	@$(call with_env,helmfile apply)

sync: check
	@$(call with_env,./scripts/ensure-namespaces.sh)
	@$(call with_env,SEED_VAULT_SKIP_IF_UNAVAILABLE=true ./scripts/seed-vault-secrets.sh)
	@$(call with_env,./scripts/wait-talos-worker-config.sh)
	@$(call with_env,helmfile sync)

diff: check
	@$(call with_env,helmfile diff)

destroy:
	@$(call with_env,SKIP_BOOTSTRAP_SECRET_CHECK=true ./scripts/check-prereqs.sh)
	@$(call with_env,helmfile destroy)
	@$(call with_env,./scripts/destroy-namespaces.sh)

destroy-namespaces:
	@$(call with_env,./scripts/destroy-namespaces.sh)

lint: check
	@$(call with_env,helmfile lint)

template: check
	@$(call with_env,helmfile template)

repos:
	helmfile repos

check:
	@$(call with_env,./scripts/check-prereqs.sh)

seed-vault-secrets:
	@$(call with_env,./scripts/seed-vault-secrets.sh)

status:
	kubectl get nodes
	kubectl get pods -A
