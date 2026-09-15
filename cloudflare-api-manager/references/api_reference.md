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
