# helm-k8s-homelab

Instala a stack do homelab Kubernetes com Helmfile.

## Bootstrap rapido

```bash
cp .env.example .env
# edite .env apenas com valores de ambiente nao sensiveis
make apply
```

Se `KUBECONFIG` nao estiver definido, os scripts tentam usar `../terraform-homelab/configs/kubeconfig`.

Depois de recriar o cluster com `terraform-homelab`, o Terraform gera
`../terraform-homelab/configs/karpenter-talos-worker-user-data.yaml`. Esse arquivo contem o `user-data` Talos worker do cluster novo e o `make apply` usa ele para atualizar o path `k8s-homelab/talos-worker-config` no Vault antes de instalar o Karpenter.

Quando o Vault ja existe, `make apply` e `make sync` tambem rodam o seed antes do Helmfile e aguardam o Secret `kube-system/talos-worker-config` bater com esse arquivo. Isso evita o Karpenter usar `user-data` antigo depois de um rebuild do cluster.

## Variaveis de ambiente

`make apply` carrega `.env` automaticamente e exporta as variaveis para o Helmfile e hooks.

Obrigatoria somente no primeiro bootstrap do Vault, caso o Secret Kubernetes ainda nao exista no cluster:

```bash
VAULT_POSTGRES_CONNECTION_URL='postgresql://vault:<password>@postgresql.example.com:5432/vault'
```

Variaveis usadas pelos manifests (`*/manifests/*.yaml`, via `envsubst` em `scripts/apply-manifests.sh`) e por scripts de bootstrap:

```bash
CLUSTER_DOMAIN=henriqzimer.com.br
ACME_EMAIL=henrique.zimermann@outlook.com.br
CLOUDFLARE_EMAIL=henrique.zimermann@outlook.com.br
TALOS_WORKER_CONFIG_FILE=../terraform-homelab/configs/karpenter-talos-worker-user-data.yaml
METALLB_ADDRESS_RANGE=192.168.1.150-192.168.1.155
PROXMOX_REGION=pve
```

`PROXMOX_REGION` deve bater com o `region` do secret `proxmox-credentials` (usado como fallback em `scripts/seed-vault-secrets.sh`).

Dominio, storage class e regiao/zona do Proxmox usados pelos **charts Helm** (NFS, Vault, Traefik, Karpenter, kube-prometheus-stack, Portainer, Argo CD, n8n) ficam fixos direto nos `values.yaml` de cada app — sao a unica fonte de verdade para esses valores, sem override via `.env` no `helmfile.yaml`. Trocar de cluster/dominio no futuro significa editar esses `values.yaml` diretamente.

Secrets de aplicacao ficam no Vault, nao no `.env`. O comando `make seed-vault-secrets` popula estes paths no mount `k8s-homelab`:

- `proxmox-credentials`: credenciais usadas por CCM e Karpenter.
- `grafana-credentials`: usuario/senha do Grafana e URL opcional do Postgres.
- `portainer-admin-password`: senha inicial do Portainer.
- `cert-manager-token`: token Cloudflare DNS-01 na chave `api-token`.
- `talos-worker-config`: `user-data` completo usado pelo Karpenter para criar workers Talos.

Para `talos-worker-config`, o script prefere o arquivo `TALOS_WORKER_CONFIG_FILE` gerado pelo Terraform. Se o arquivo nao existir, ele tenta reaproveitar o Secret `kube-system/talos-worker-config` do cluster atual como fallback. Para os outros secrets, o script le primeiro os Secrets ja existentes no cluster. Se algum deles ainda nao existir, ele pode usar variaveis temporarias do `.env`; depois do seed, remova essas variaveis sensiveis.

Para popular o token do cert-manager pela primeira vez, use temporariamente `CLOUDFLARE_API_TOKEN` ou `CLOUDFLARE_DNS_API_TOKEN` no `.env` e rode `make seed-vault-secrets`. Use um Cloudflare API Token com `Zone:Read` e `DNS:Edit` para a zona; nao use token de Tunnel, prefixo `Bearer`, aspas ou espacos.

O Grafana usa Postgres por padrao (`monitoring/kube-prometheus-stack/values.yaml`), entao `grafana-credentials/postgres-url` precisa existir no Vault **antes** do primeiro `make apply` (rode `make seed-vault-secrets` com `GRAFANA_POSTGRES_URL` definido, ou grave o path direto no Vault). Se preferir sqlite3 para o primeiro bootstrap, edite `envFromSecret` e `grafana.ini.database.type` em `monitoring/kube-prometheus-stack/values.yaml` diretamente.

O Karpenter Proxmox e instalado sempre (`releases[].installed` nao existe mais em `helmfile.yaml`). Para pular no primeiro bootstrap, comente o release `karpenter-provider-proxmox` em `helmfile.yaml` ou rode `helmfile apply --selector name!=karpenter-provider-proxmox`.

## n8n MCP

O n8n fica com MCP instance-level habilitado por ambiente. A URL segue o `CLUSTER_DOMAIN`:

```bash
https://n8n.${CLUSTER_DOMAIN}/mcp-server/http
```

No n8n, habilite os workflows que devem aparecer no MCP e gere o token em **Settings > MCP**. O cliente MCP deve usar esse token no header `Authorization: Bearer <token>`.

O token do MCP nao fica no `.env` nem no Vault por padrao, porque ele eh um token de cliente gerenciado pelo proprio n8n. Se voce quiser padronizar isso depois, o caminho seguro eh criar uma secret dedicada no Vault e injetar no cliente que vai consumir o MCP, nao no chart do n8n.

## O que o Makefile faz

- `make check`: valida ferramentas, acesso ao cluster e secret inicial do Vault.
- `make seed-vault-secrets`: grava no Vault os secrets que antes ficavam no `.env` ou ja existem no cluster.
- `make apply`: roda `helmfile apply`.
- `make sync`: força sincronizacao com `helmfile sync`.
- `make diff`: mostra diferencas com `helmfile diff`.
- `make lint`: roda lint dos charts.
- `make template`: renderiza os manifests.
- `make status`: lista nodes e pods.

## Ordem de instalacao

O `helmfile.yaml` define `needs` e hooks para tornar o bootstrap previsivel:

1. NFS provisioner.
2. Vault, usando o Secret `vault-postgres-storage`.
3. Vault Secrets Operator.
4. `VaultAuthGlobal` e `VaultAuth` dos namespaces.
5. Manifests `VaultStaticSecret` que sincronizam secrets dos apps.
6. Charts que dependem desses secrets.

Os hooks usam `scripts/apply-manifests.sh`, que renderiza variaveis de ambiente com `envsubst`, aplica manifests com `kubectl apply --validate=false` e, quando pedido, aguarda os Secrets gerados pelo Vault Secrets Operator.

## Pontos de atencao

- O Vault precisa estar inicializado, unsealed e com o auth Kubernetes/configuracao KV esperados antes dos `VaultStaticSecret` sincronizarem.
- O arquivo `.env` fica fora do Git.
- `VAULT_POSTGRES_CONNECTION_URL` e a credencial root/unseal do Vault sao bootstrap externo: nao devem depender do proprio Vault.
