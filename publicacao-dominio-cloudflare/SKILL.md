---
name: publicacao-dominio-cloudflare
description: Publica e propaga um domínio de internet para um site institucional estático usando a CloudFlare — cria a zona no CloudFlare, gera as instruções de troca de nameservers no registrador (registro.br ou similar), publica o site em CloudFlare Pages e anexa o domínio customizado. Use esta skill sempre que o usuário pedir para "publicar domínio", "propagar domínio", "configurar domínio na CloudFlare", "colocar meu site no ar", "apontar meu domínio para o site" ou quando ele disser que comprou um domínio e tem uma conta CloudFlare e quer publicar um site estático nele — mesmo que ele não use os termos técnicos exatos (zona, nameserver, DNS, Pages). Pressupõe usuário leigo em DNS/CloudFlare: explique cada etapa em linguagem simples e confirme antes de qualquer ação que mexa na conta CloudFlare, no registrador do domínio, ou publique conteúdo.
---

# Publicação de Domínio via CloudFlare

## Por que esta skill existe

O MCP da CloudFlare conectado nesta sessão só expõe ferramentas de Workers,
D1, KV, R2, Hyperdrive e busca de documentação — **não** tem ferramentas de
Zone/DNS ou de Pages. Por isso esta skill chama a API REST da CloudFlare
diretamente via `scripts/cloudflare_api.ps1`, em vez de depender do MCP para
a parte de domínio/DNS/Pages.

## Quando usar cada referência

- Este arquivo (SKILL.md): fluxo resumido e comandos do dia a dia.
- [references/fluxo-completo.md](references/fluxo-completo.md): leia quando
  precisar explicar o "porquê" de uma etapa ao usuário, dar o texto exato de
  instrução para o registrador, ou lidar com o caminho alternativo (site
  hospedado fora do CloudFlare Pages).

## Pressuposto de partida

Trate o usuário como iniciante nisso, a menos que ele demonstre o contrário:
ele tem um domínio pago e uma conta CloudFlare — só isso. Não presuma que ele
sabe o que é "zona", "nameserver" ou "registro DNS"; explique em uma frase
simples na primeira vez que usar o termo.

## Guardrails (regras de segurança)

- **Nunca** peça para o usuário colar o token da API CloudFlare no chat, nem
  o exiba de volta. O token vive no cofre do `credential-manager`
  (service `cloudflare-domain-publisher`, username `cloudflare-api-token`) —
  `cloudflare_api.ps1` busca ou pede o token sozinho na primeira execução via
  `Read-Host -AsSecureString` (não aparece na tela).
- **Confirme com o usuário antes de**: criar a zona na CloudFlare, criar/anexar
  um projeto Pages, criar qualquer registro DNS, ou publicar conteúdo. Essas
  são mudanças em conta e publicação de site — irreversíveis o suficiente
  para merecer um "pode confirmar?" antes de agir, mesmo que o usuário já
  tenha pedido a tarefa como um todo.
- **Nunca automatize login no registrador do domínio** (registro.br ou
  qualquer outro) via navegador — normalmente exige 2FA e é a conta real do
  usuário. Em vez disso, gere a instrução exata (domínio + os dois
  nameservers) para ele mesmo aplicar.
- Não gere conteúdo do site (HTML/CSS) como parte desta skill — o objetivo é
  publicar um site que já existe ou que o usuário vai fornecer.

## Fluxo resumido

1. **Coletar parâmetros obrigatórios**, se ainda não informados:
   - domínio a publicar (ex.: `www.meusite.com.br` ou `meusite.com.br`)
   - onde o domínio foi comprado (ex.: registro.br) — só para saber onde ele
     vai trocar os nameservers depois
   - se o site estático já existe em algum lugar (pasta local pronta,
     repositório Git, ou já hospedado em outro provedor com IP/CNAME) — se
     "nada disso ainda", explique que a skill publica o site quando ele tiver
     os arquivos prontos, e pode parar aqui até ele providenciar

2. **Zona CloudFlare** — confirmar com o usuário, depois:
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/cloudflare_api.ps1 -Action find-zone -Domain meusite.com.br -Json
   ```
   Se não existir, criar (peça `AccountId` via `whoami` se precisar escolher
   entre múltiplas contas):
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/cloudflare_api.ps1 -Action create-zone -Domain meusite.com.br -Json
   ```
   Guarde o `id` da zona (ZoneId) e os `name_servers` retornados.

3. **Instrução de nameserver para o registrador** — monte o texto usando o
   modelo em [references/fluxo-completo.md](references/fluxo-completo.md#etapa-2--trocar-nameservers-no-registrador-registrobr-ou-outro)
   com os NS reais retornados. Peça para o usuário confirmar quando tiver
   feito a troca — não prossiga sem essa confirmação.

4. **Checar ativação da zona** (pode levar minutos a horas — não fique em
   loop apertado, sugira tentar de novo em alguns minutos):
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/cloudflare_api.ps1 -Action zone-status -ZoneId <id> -Json
   ```
   Só avance quando `status` vier `active`.

5. **Publicar o site**:
   - Pergunte a origem dos arquivos, se ainda não souber: pasta **local**,
     repositório **GitHub** ou **GitLab** (URL). Resolva a origem para uma
     pasta local pronta com:
     ```powershell
     # local
     powershell -ExecutionPolicy Bypass -File scripts/prepare_source.ps1 -SourceType local -Path "C:\caminho\do\site"

     # GitHub ou GitLab (repo público; privado usa as credenciais Git já
     # configuradas na máquina do usuário — não pede token aqui)
     powershell -ExecutionPolicy Bypass -File scripts/prepare_source.ps1 -SourceType github -RepoUrl "https://github.com/usuario/repo.git" -SubPath "" 
     powershell -ExecutionPolicy Bypass -File scripts/prepare_source.ps1 -SourceType gitlab -RepoUrl "https://gitlab.com/usuario/repo.git"
     ```
     Use `-SubPath` quando os arquivos do site não estão na raiz do repo
     (ex.: `-SubPath dist` ou `-SubPath public`). Use `-Branch` para fixar uma
     branch específica.
   - Confirme com o usuário, crie o projeto Pages se ainda não existir
     (`-Action create-pages`) e publique a pasta resolvida:
     ```powershell
     powershell -ExecutionPolicy Bypass -File scripts/deploy_pages.ps1 -FolderPath "<path retornado>" -ProjectName "<nome-projeto>" -AccountId "<id-da-conta>"
     ```
     Isso roda `npx wrangler pages deploy` usando o token já salvo no cofre
     (requer Node.js instalado). Se o usuário não tiver Node.js, ofereça a
     alternativa manual: dashboard CloudFlare, arrastando a pasta em
     "Workers & Pages → Create → Pages → Upload assets".
     Detalhes em [references/fluxo-completo.md](references/fluxo-completo.md#etapa-4--publicar-o-site-em-cloudflare-pages).
   - Se o site já está hospedado fora da CloudFlare (IP ou CNAME externo),
     pule Pages e use `create-dns-record` apontando para esse destino — ver
     [caminho alternativo](references/fluxo-completo.md#caminho-alternativo--site-hospedado-fora-da-cloudflare-pages).

6. **Anexar o domínio final** (só no caminho Pages):
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/cloudflare_api.ps1 -Action attach-pages-domain -AccountId <id> -ProjectName <nome> -Domain meusite.com.br -Json
   ```
   A CloudFlare cria o registro DNS necessário automaticamente.

7. **Verificação final** — confira `list-dns-records` e peça ao usuário para
   abrir `https://<domínio>` no navegador e confirmar que o site carrega.

## Saída esperada

Ao concluir, resuma para o usuário em uma frase clara, por exemplo:

```
✓ Domínio meusite.com.br publicado e propagado — site acessível via CloudFlare Pages em https://meusite.com.br
```

Se parar no meio (ex.: aguardando troca de nameserver ou aguardando os
arquivos do site), diga exatamente o que falta e o que o usuário precisa
fazer ou fornecer para continuar.
