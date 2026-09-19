# Referência rápida — API Cloudflare v4 (usada por esta skill)

Base: `https://api.cloudflare.com/client/v4`. Toda chamada usa
`Authorization: Bearer <token>` (nunca a Global API Key — ver SKILL.md sobre
por que evitamos isso).

Esta página existe para consulta pontual — os scripts em `scripts/` já
implementam tudo isso. Leia aqui quando precisar entender um erro, estender
um script, ou fazer uma chamada que os scripts não cobrem.

## Tokens de API (escopo "user" — o que o painel chama de "Tokens de API de usuário")

| Ação | Método | Caminho |
|---|---|---|
| Verificar se um token é válido | GET | `/user/tokens/verify` |
| Listar permission groups disponíveis | GET | `/user/tokens/permission_groups` |
| Criar token | POST | `/user/tokens` |
| Listar tokens | GET | `/user/tokens` |
| Ver um token | GET | `/user/tokens/{token_id}` |
| Rolar (revoga o valor atual, gera um novo, mesmas permissões) | PUT | `/user/tokens/{token_id}/value` |
| Revogar (excluir) | DELETE | `/user/tokens/{token_id}` |

Corpo de criação (`POST /user/tokens`):

```json
{
  "name": "meu-token",
  "policies": [
    {
      "effect": "allow",
      "resources": { "com.cloudflare.api.account.zone.<ZONE_ID>": "*" },
      "permission_groups": [{ "id": "<id resolvido via permission_groups>", "name": "DNS Write" }]
    },
    {
      "effect": "allow",
      "resources": { "com.cloudflare.api.account.<ACCOUNT_ID>": "*" },
      "permission_groups": [{ "id": "...", "name": "Cloudflare Pages Write" }]
    }
  ],
  "expires_on": "2027-01-01T00:00:00Z"
}
```

### Formato das chaves de `resources` (importante)

- Uma zona específica: `com.cloudflare.api.account.zone.<ZONE_ID>`
- Uma conta específica: `com.cloudflare.api.account.<ACCOUNT_ID>`

O valor associado é sempre `"*"`. **Não existe** uma forma de escopar a uma
zona pelo nome do domínio — sempre pelo `zone_id` (por isso os scripts
primeiro resolvem o id via `GET /zones?name=`).

### Por que resolver `permission_groups` dinamicamente

Os ids de cada grupo de permissão (ex. "DNS Write") não são fixos/garantidos
pela documentação pública — a própria Cloudflare recomenda descobri-los via
`GET /user/tokens/permission_groups` antes de montar o token. `cf_api.py`
faz isso automaticamente (função `resolver_grupo_permissao`).

## Zonas

| Ação | Método | Caminho |
|---|---|---|
| Listar / buscar por nome | GET | `/zones?name=<dominio>` |
| Criar zona | POST | `/zones` |

Corpo de criação:

```json
{ "account": { "id": "<ACCOUNT_ID>" }, "name": "exemplo.com.br", "type": "full" }
```

A resposta inclui `result.name_servers` — os nameservers que o usuário
precisa configurar manualmente no registrador do domínio. **Isso é sempre um
passo manual fora da Cloudflare**; nenhum script pode automatizá-lo.

## Registros DNS

| Ação | Método | Caminho |
|---|---|---|
| Listar | GET | `/zones/{zone_id}/dns_records` |
| Criar | POST | `/zones/{zone_id}/dns_records` |
| Atualizar (parcial) | PATCH | `/zones/{zone_id}/dns_records/{id}` |
| Remover | DELETE | `/zones/{zone_id}/dns_records/{id}` |

Corpo de criação:

```json
{ "type": "CNAME", "name": "app.exemplo.com.br", "content": "destino.pages.dev", "ttl": 1, "proxied": true }
```

`ttl: 1` significa "automático" (recomendado quando `proxied: true`).

## Cloudflare Pages — projetos e implantações

| Ação | Método | Caminho |
|---|---|---|
| Listar projetos | GET | `/accounts/{account_id}/pages/projects` |
| Ver um projeto | GET | `/accounts/{account_id}/pages/projects/{project_name}` |
| Criar projeto (conectado a um repo Git) | POST | `/accounts/{account_id}/pages/projects` |
| Listar implantações (deployments/builds) | GET | `/accounts/{account_id}/pages/projects/{project_name}/deployments` |
| Adicionar domínio personalizado | POST | `/accounts/{account_id}/pages/projects/{project_name}/domains` |

Corpo de criação de projeto conectado ao GitHub (`POST .../pages/projects`):

```json
{
  "name": "meu-projeto",
  "production_branch": "main",
  "build_config": {
    "build_command": "npm run build",
    "destination_dir": "dist",
    "root_dir": ""
  },
  "source": {
    "type": "github",
    "config": {
      "owner": "minha-org",
      "repo_name": "meu-repo",
      "production_branch": "main",
      "pr_comments_enabled": true,
      "deployments_enabled": true,
      "production_deployment_enabled": true
    }
  }
}
```

**Pré-requisito que a API não cobre**: a conta precisa ter o GitHub/GitLab
conectado como integração (autorização OAuth feita uma única vez pelo
painel — ver `pages_manager.py`, seção "Pré-requisito" na docstring). Sem
isso, a chamada acima falha porque a Cloudflare não tem permissão para ler
o repositório indicado em `source.config`.

### Comando de build / diretório de saída por framework (atalhos comuns)

Variam conforme a configuração real do projeto — confirme sempre com quem
mantém o repositório antes de assumir um destes valores às cegas:

| Framework | Comando de build | Diretório de saída |
|---|---|---|
| Nenhum (HTML estático) | *(vazio)* | *(raiz)* |
| React (Vite) | `npm run build` | `dist` |
| React (Create React App) | `npm run build` | `build` |
| Vue | `npm run build` | `dist` |
| Next.js (export estático) | `npm run build` | `out` |
| Nuxt | `npm run generate` | `dist` |
| SvelteKit | `npm run build` | `build` |
| Angular | `npm run build` | `dist` |
| Hugo | `hugo` | `public` |
| Jekyll | `jekyll build` | `_site` |
| Gatsby | `npm run build` | `public` |
| Astro | `npm run build` | `dist` |

## Erros comuns

- **HTTP 403 / "Authentication error"**: a variável de ambiente aponta para
  um token que não tem a permissão necessária para aquela chamada, ou o
  token expirou/foi revogado. Rode `python cf_api.py <NOME_DA_VARIAVEL>` para
  verificar.
- **"Não encontrei o(s) permission group(s) [...]"**: o nome do grupo não
  existe com esse texto exato na conta (produto não habilitado, ou nome
  mudou). Rode `chamar_api("GET", "/user/tokens/permission_groups", ...)`
  manualmente e procure o nome mais parecido.
- **Zona não encontrada ao criar registro DNS/token**: o domínio ainda não
  foi adicionado como zona no Cloudflare — use `zone_manager.py criar`
  primeiro, ou confirme a grafia exata do domínio.
