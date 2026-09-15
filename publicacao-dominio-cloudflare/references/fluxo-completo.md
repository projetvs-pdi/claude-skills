# Fluxo completo de publicação de domínio via CloudFlare

Este arquivo detalha cada etapa do fluxo para quando o usuário precisa de
explicações passo a passo (ex.: é a primeira vez que ele faz isso). O corpo do
SKILL.md tem a versão resumida — use este arquivo quando precisar explicar o
"porquê" de uma etapa ou dar o texto exato de uma instrução manual.

## Visão geral do caminho escolhido

Dado que o usuário só tem um domínio comprado e uma conta CloudFlare (nada
mais configurado), o caminho mais seguro, recomendado e econômico é:

```
Domínio (registrador) --[trocar nameservers]--> Zona CloudFlare --[DNS]--> CloudFlare Pages (grátis) --[serve o site estático]
```

CloudFlare Pages foi escolhido como destino padrão porque: é gratuito para
sites estáticos, já vem com HTTPS automático, CDN global, e a própria
CloudFlare cuida do registro DNS necessário quando você anexa um domínio
customizado ao projeto — elimina uma classe inteira de erros manuais de DNS.

## Etapa 1 — Zona no CloudFlare

Uma "zona" é o registro do domínio dentro da conta CloudFlare — é o que
permite à CloudFlare responder pelas consultas DNS desse domínio.

- Verificar primeiro se a zona já existe (`find-zone`) antes de criar, para
  não duplicar.
- Se não existir, criar via `create-zone`.
- A resposta traz `name_servers`: dois endereços tipo `xxx.ns.cloudflare.com`
  que a CloudFlare atribuiu a essa zona.

## Etapa 2 — Trocar nameservers no registrador (registro.br ou outro)

Esta etapa **não é automatizável com segurança** pela skill: painéis de
registradores (registro.br, GoDaddy, etc.) normalmente exigem login com 2FA e
não têm API pública simples — tentar automatizar isso por navegador é frágil
e arriscado com uma conta real do usuário. Em vez disso, a skill gera as
instruções exatas e pede para o usuário confirmar quando tiver feito.

Texto padrão a apresentar ao usuário (preencher com os NS reais retornados):

```
1. Acesse o painel do seu registrador (ex.: registro.br → "Meus Domínios").
2. Encontre a opção "Alterar servidores DNS" / "Nameservers" do domínio <domínio>.
3. Substitua os nameservers atuais pelos dois abaixo (fornecidos pela CloudFlare):
   - <ns1>
   - <ns2>
4. Salve. A propagação pode levar de alguns minutos a 24h (geralmente é bem mais rápido).
```

Não prosseguir para a Etapa 3 sem essa troca — a zona só fica `active` na
CloudFlare depois que os nameservers propagam.

## Etapa 3 — Aguardar ativação da zona

- Consultar `zone-status` periodicamente (não ficar em loop apertado — sugerir
  ao usuário rodar de novo em alguns minutos, ou a cada nova mensagem dele).
- Status `pending` = ainda propagando; `active` = pronta para uso.

## Etapa 4 — Publicar o site em CloudFlare Pages

Perguntar ao usuário onde estão os arquivos do site — esta skill não gera o
conteúdo, só publica o que já existe. Três origens suportadas por
`scripts/prepare_source.ps1`:

- **Pasta local** (`-SourceType local -Path <pasta>`): só valida que a pasta
  existe e tem arquivos.
- **GitHub** (`-SourceType github -RepoUrl <url>`): clona (ou atualiza, se já
  clonado antes) para uma pasta temporária. Repositórios privados usam as
  credenciais Git já configuradas na máquina do usuário (`gh auth login`,
  chave SSH, etc.) — o script não pede nem guarda token de GitHub.
- **GitLab** (`-SourceType gitlab -RepoUrl <url>`): mesma lógica do GitHub.

Use `-SubPath` quando o site estático não está na raiz do repositório (ex.:
projetos que buildam para `dist/` ou `public/` — mas atenção: esta skill
**não roda build** nenhum, só publica arquivos estáticos já prontos; se o
repositório precisar de `npm run build` antes, isso é responsabilidade do
usuário rodar antes de acionar a skill, ou você pode rodá-lo por fora se o
usuário pedir explicitamente).

Depois de resolvida a origem para uma pasta local, duas formas de publicar:

1. **`scripts/deploy_pages.ps1`** (recomendado, mais direto): roda
   `npx wrangler pages deploy <pasta> --project-name <nome>` usando o token
   já salvo no cofre. Requer Node.js instalado na máquina do usuário. Devolve
   a URL `*.pages.dev` do deploy.
2. **Dashboard CloudFlare (alternativa sem Node.js)**: o usuário mesmo
   arrasta a pasta do site em Workers & Pages → Create → Pages → Upload
   assets, no navegador. Claude não deve tentar arrastar arquivos por
   automação de navegador — é uma ação manual do usuário.

Depois do primeiro deploy, o projeto fica acessível em
`https://<nome-projeto>.pages.dev` — bom para validar antes de anexar o
domínio final.

## Etapa 5 — Anexar o domínio customizado ao projeto Pages

- Usar `attach-pages-domain` (API `/pages/projects/:name/domains`). A
  CloudFlare cria automaticamente o registro DNS (CNAME) necessário na zona —
  não é preciso criar manualmente com `create-dns-record` neste caminho.
- `create-dns-record` só é necessário no caminho alternativo (site hospedado
  fora da CloudFlare Pages, com IP ou CNAME externo).

## Etapa 6 — Verificação final

- Checar `list-dns-records` para confirmar que o registro apontando para o
  domínio existe.
- Confirmar com o usuário que `https://<domínio>` está acessível (pedir para
  ele abrir no navegador, ou usar o Browser tool se disponível).
- Lembrar que o certificado SSL da CloudFlare pode levar alguns minutos para
  ficar ativo mesmo com o DNS já resolvendo.

## Caminho alternativo — site hospedado fora da CloudFlare Pages

Se o usuário já tem hospedagem própria (outro servidor, outro CDN) e só quer
usar a CloudFlare para DNS/proxy:

1. Etapas 1–3 iguais (zona + nameservers).
2. Perguntar o destino: um IP (registro `A`) ou um endereço CNAME.
3. Usar `create-dns-record` com esse destino.
4. Pular a Etapa 4/5 (não há projeto Pages).
