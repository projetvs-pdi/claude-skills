---
name: atualizar-deploy-cloudflare-pages
description: Atualiza um site estático já publicado em CloudFlare Pages, puxando a versão mais recente de um repositório Git (GitHub ou GitLab) ou de uma pasta local e republicando. Use esta skill sempre que o usuário pedir para "atualizar o site", "publicar a nova versão", "fazer deploy", "subir as mudanças do GitHub/GitLab para o CloudFlare", "colocar a versão nova no ar" ou similar — mesmo sem citar CloudFlare Pages explicitamente, desde que o site já esteja publicado nele. Não use esta skill para a configuração inicial de domínio/DNS/zona (isso é a skill publicacao-dominio-cloudflare) — esta aqui é só para republicar conteúdo em um site que já existe.
---

# Atualizar Deploy no CloudFlare Pages

## Por que esta skill existe

Depois que um domínio já foi publicado (via [publicacao-dominio-cloudflare](../publicacao-dominio-cloudflare/SKILL.md)), o trabalho do dia a dia passa a ser bem mais simples: só puxar a versão nova do código e republicar. Esta skill isola esse fluxo curto e frequente, sem repetir as perguntas de zona/DNS/registrador — que só fazem sentido na primeira vez.

Ela reaproveita os mesmos scripts da skill de publicação inicial (`prepare_source.ps1` e `deploy_pages.ps1`), sem duplicar lógica — veja `scripts/` lá.

## Guardrails (regras de segurança)

- **Confirme com o usuário antes de publicar** — sobrescrever o site no ar é uma ação de publicação de conteúdo, mesmo que pareça rotineira.
- **Nunca** peça o CloudFlare API Token no chat — os scripts o buscam sozinhos no cofre (`credential-manager`, service `cloudflare-domain-publisher`), já configurado quando o domínio foi publicado.
- Repositórios privados usam as credenciais Git já configuradas na máquina do usuário — não peça nem armazene token de GitHub/GitLab.
- Não gere ou edite conteúdo do site — só republica o que já está no repositório/pasta informado.

## Fluxo

1. **Perguntar (se ainda não informado):**
   - Qual endereço/projeto no CloudFlare deve ser atualizado (o domínio customizado, ex. `projetvs.com.br`, ou a URL `*.pages.dev`)?
   - Qual repositório Git tem a versão nova (URL do GitHub/GitLab), ou é uma pasta local? Se for repositório, perguntar também a branch, se não for a padrão.

2. **Resolver o projeto/conta CloudFlare** a partir do endereço informado, sem precisar que o usuário saiba o "nome do projeto" ou "account ID":
   - Extrair o domínio puro (sem `https://`, sem `www.`).
   - Se for um domínio customizado (não termina em `.pages.dev`), achar a zona para pegar a conta:
     ```powershell
     powershell -ExecutionPolicy Bypass -File ../publicacao-dominio-cloudflare/scripts/cloudflare_api.ps1 -Action find-zone -Domain <dominio> -Json
     ```
     Pegue `result[0].account.id` como `AccountId`. Se não achar zona nenhuma, avise o usuário — provavelmente o domínio ainda não passou pela skill de publicação inicial.
   - Com o `AccountId`, achar o projeto Pages correspondente:
     ```powershell
     powershell -ExecutionPolicy Bypass -File ../publicacao-dominio-cloudflare/scripts/cloudflare_api.ps1 -Action find-pages-project -AccountId <id> -Domain <dominio> -Json
     ```
     O campo `name` do resultado é o `ProjectName`.
   - Se for direto uma URL `*.pages.dev`, o nome do projeto é o subdomínio (ex.: `projetvs.pages.dev` → `projetvs`), mas ainda assim é preciso o `AccountId` — se não estiver óbvio (ex.: usuário só tem uma conta, ou já foi usada antes na conversa), pergunte qual conta CloudFlare usar, ou rode `find-pages-project` contra as contas conhecidas.
   - Se a busca não encontrar nada, não adivinhe — pergunte ao usuário o nome exato do projeto Pages.

3. **Confirmar com o usuário** o que vai acontecer antes de agir: "vou puxar a branch X do repositório Y e publicar no projeto Z (conta W) — confirma?".

4. **Resolver a origem dos arquivos:**
   ```powershell
   # git (GitHub ou GitLab)
   powershell -ExecutionPolicy Bypass -File ../publicacao-dominio-cloudflare/scripts/prepare_source.ps1 -SourceType github -RepoUrl "<url>" -Branch "<branch, se informado>" -SubPath "<se aplicável>"
   # ou -SourceType gitlab, ou -SourceType local -Path "<pasta>"
   ```
   Isso clona na primeira vez e só atualiza (`git pull`) nas próximas — não deixa lixo acumulando.

5. **Publicar:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File ../publicacao-dominio-cloudflare/scripts/deploy_pages.ps1 -FolderPath "<path retornado>" -ProjectName "<nome>" -AccountId "<id>"
   ```

6. **Reportar o resultado** com a URL de deploy retornada, e lembrar que pode levar um minuto para o cache da CDN atualizar globalmente.

## Saída esperada

```
✓ projetvs.com.br atualizado com a versão mais recente de github.com/usuario/repo (branch main) — deploy em https://<hash>.projetvs.pages.dev
```

Se a resolução do projeto/conta falhar em algum ponto, pare e pergunte ao usuário o dado que faltou, em vez de tentar adivinhar — publicar no projeto errado é o tipo de erro caro de reverter.
