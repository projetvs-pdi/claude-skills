---
name: implantacao-frontend-cloudflare
description: Publica o front do 4clinics (React) no Cloudflare Pages em app.<dominio> e confere a segurança da zona — projeto ligado ao repositório 4clinics_app, build npm run build:pages, variáveis REACT_APP_HOST_API/INLINE_RUNTIME_CHUNK/NODE_VERSION, domínio personalizado, cabeçalhos (CSP, HSTS) e as configurações de SSL/TLS, WAF e limite de requisições. Use na fase 2 da implantação e para conferir/reverter o front numa atualização (B5). O Claude no Chrome faz a parte de navegação e conferência; configuração de segurança é do responsável.
---

# Front-end no Cloudflare Pages

Referências: `D:\git\4clinics\4clinics_app\src\docs\cabecalhos-seguranca.md` (seção "Produção no Cloudflare Pages"), `D:\git\4clinics\4clinics_backend\docs\checklist-implantacao.md` §1.
O Pages publica os arquivos estáticos da pasta `build`. Os cabeçalhos de segurança vêm do `_headers` **gerado** por `npm run build:pages`; o `_redirects` (`/* /index.html 200`) faz as rotas do app abrirem.

## Pré-condições
- Fase 1 concluída (`main` publicada e com tag); fase 0 (domínio na zona do Cloudflare; nome `api.<dominio>` já decidido).
- Responsável logado no Cloudflare com 2FA. **O Chrome não faz login nem digita código.**

## Parte 1 — projeto e domínio (Claude no Chrome, com confirmação a cada botão irreversível)
1. Workers & Pages → criar projeto **Pages** → "Connect to Git" → repositório `4clinics_app`. A **concessão de acesso do Cloudflare ao GitHub é do responsável** (tela de autorização).
2. Ramo de produção: `main`. Ramos de pré-visualização: desligar (evita publicar a `develop` por engano) ou aceitar só se o responsável pedir.
3. Configuração de build: **comando** `npm run build:pages`; **pasta de saída** `build`; **raiz** `/`.
4. **Variáveis (produção):** `REACT_APP_HOST_API=https://api.<dominio>` · `INLINE_RUNTIME_CHUNK=false` · `NODE_VERSION=24`.
   Se `REACT_APP_HOST_API` faltar ou não for `https://` de verdade, o **build falha de propósito** (`seguranca/gerar-pages.js`): é o comportamento certo.
5. Disparar o primeiro deploy (precisa do "sim" do responsável) e acompanhar o log do build até "Success".
6. **Domínio personalizado** `app.<dominio>` (o Cloudflare cria o CNAME). Aguardar o certificado ativo.

## Parte 2 — segurança da zona (**o responsável ajusta; o Chrome só confere e fotografa**)
Configuração de segurança não é feita pelo plugin. O responsável ajusta e diz "feito"; o Chrome abre cada tela e confirma o valor.
| Onde (nomes aproximados) | Valor |
|---|---|
| SSL/TLS → Visão geral | **Full (strict)** |
| SSL/TLS → Certificados de borda | **Versão mínima do TLS 1.2**; TLS 1.3 ligado; *Always Use HTTPS* ligado; *Automatic HTTPS Rewrites* ligado |
| SSL/TLS → Servidor de origem | **Origin CA** para `api.<dominio>` (a chave privada é baixada e guardada **pelo responsável**; vai para a VPS pelo administrador, nunca por chat) |
| Segurança → WAF | conjunto gerenciado gratuito ligado; *Bot Fight Mode* ligado |
| Segurança → Regras de limite | `/api/auth/login`: 20 requisições/minuto por IP, bloquear por 1 minuto |
| Caching → Regras | *Bypass cache* para `api.<dominio>/*` |
| DNS | `app` (CNAME, via Pages, nuvem laranja); `api` (A → IP da VPS, nuvem laranja) — o registro `api` só depois da fase 3c |

## Conferência de fora (Claude Code, `curl`; independe da tela)
```bash
curl -sI https://app.<dominio>/ | grep -iE "^(HTTP|content-security-policy|strict-transport-security|x-frame-options|x-content-type-options|referrer-policy|permissions-policy)"
curl -s -o /dev/null -w "%{http_code}\n" https://app.<dominio>/pacientes          # 200: rota profunda abre (regra _redirects)
JS=$(curl -s https://app.<dominio>/asset-manifest.json | grep -o 'static/js/main[^"]*\.js' | head -1); curl -sI "https://app.<dominio>/$JS" | grep -i cache-control   # public, max-age=31536000, immutable
openssl s_client -connect app.<dominio>:443 -tls1_1 </dev/null 2>&1 | grep -i "alert\|handshake failure"   # TLS 1.1 recusado
```
Esperado: CSP com `connect-src 'self' https://api.<dominio>`, `script-src 'self'` (sem `unsafe-eval`), HSTS, `DENY`, `nosniff`. No navegador, o console **sem violação de CSP** em: login, agenda, pacientes, atendimento, relatório (ver `implantacao_4_verificar-producao`).

**Prompt para o Claude no Chrome (conferência):**
> Estou logado no painel do Cloudflare. Abra, uma por uma, estas telas da zona `<dominio>`: SSL/TLS (modo de criptografia), versão mínima do TLS, "Always Use HTTPS", regras de limite de requisições, WAF/Bot Fight Mode e as regras de cache. Para cada uma, **só leia e me diga o valor atual** (e tire uma captura). **Não altere nada.** No fim, liste o que está diferente do esperado: Full (strict); TLS mínimo 1.2; Always Use HTTPS ligado; regra de limite em /api/auth/login; cache bypass em api.<dominio>/*.

## Atualização do front (B5) e volta atrás
- Atualização: o Pages publica a `main` sozinho; abrir o deploy mais recente, conferir "Success" e a tag/hash no log; rodar a conferência de fora.
- **Rollback:** Deployments → escolher o deploy anterior → "Rollback" (com o "sim" do responsável). Domínio errado: remover o domínio personalizado. O front antigo continua funcionando com a API nova (regra de compatibilidade).

## Relato
Deploy (hash, horário), variáveis conferidas (sem mostrar valores sensíveis), saída do `curl` dos cabeçalhos, cada configuração de segurança como lida (valor + captura), e o que **não** foi conferido (ex.: regra de limite ainda não criada).
