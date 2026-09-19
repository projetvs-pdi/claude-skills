---
name: cloudflare-api-manager
description: Use esta skill sempre que o usuário pedir para criar/rotacionar/revogar/listar tokens de API do Cloudflare, adicionar um domínio/zona novo, gerenciar registros DNS, publicar um site no Cloudflare Pages a partir de um repo GitHub/GitLab (criar projeto, configurar build, conectar domínio), ou aplicar as recomendações padrão do Cloudflare (SPF/DMARC) após uma zona propagar — tudo via API REST do Cloudflare, sem clicar no painel. Dispare para "token do Cloudflare", "escopar token pra uma zona", "CNAME/A/TXT", "site novo no Cloudflare", "publicar esse repositório no Pages", "buildar e implantar esse projeto", "credencial pra pipeline de deploy", "a zona já propagou, aplica as recomendações", "conecta esse domínio ao Pages", "SPF/DMARC pra não ter e-mail spoofado", ou automatizar algo antes feito manualmente no painel. Prefira sempre esta skill a orientar cliques no painel quando o usuário está no Claude Code (com shell).
---

# Cloudflare API Manager

Automatiza, via chamadas diretas à API REST da Cloudflare (`api.cloudflare.com/client/v4`), o que normalmente seria feito clicando no painel web: criar um domínio (zona), escopar e gerar tokens de API restritos a uma zona/conta, rotacionar (rolar) e revogar esses tokens, gerenciar registros DNS, publicar um site no Cloudflare Pages a partir de um repositório GitHub/GitLab (criar o projeto, configurar a build, conectar o domínio) e aplicar as recomendações de segurança padrão (SPF/DMARC) assim que a zona propagar.

Esta skill nasceu de um fluxo real feito manualmente pelo painel — criar um token restrito a uma zona (`DNS:Edit`, `Zone:Edit`, `Cloudflare Pages:Edit`), rotacioná-lo, criar uma zona nova, conectar um repositório GitHub a um projeto Cloudflare Pages (escolhendo framework/comando de build), conectar domínio + www a esse projeto, e endurecer SPF/DMARC quando não há e-mail configurado. Tudo isso agora é reproduzível por script, mais rápido e sem risco de clicar na opção errada.

## Por que isso importa (e por que não usamos a Global API Key)

A Global API Key dá acesso total e irrestrito à conta inteira — se vazar, o estrago é máximo. Um token escopado (a um domínio, a uma permissão específica) limita o dano possível caso vaze, e pode ser revogado individualmente sem afetar mais nada. Por isso esta skill **sempre** cria tokens restritos ao menor escopo necessário para a tarefa (princípio do menor privilégio), e nunca usa nem pede a Global API Key.

## Pré-requisitos

Antes de qualquer chamada real à API, duas variáveis de ambiente precisam existir na máquina/sessão onde os scripts rodam:

- `CLOUDFLARE_BOOTSTRAP_TOKEN` — um token "mestre" que só sabe gerenciar outros tokens (e, opcionalmente, criar zonas — ver abaixo). É ele que os scripts usam para *criar/rolar/revogar* os tokens de cada projeto.
- `CLOUDFLARE_ACCOUNT_ID` — o ID da conta Cloudflare (não é secreto; aparece na URL do painel, ex. `dash.cloudflare.com/<ACCOUNT_ID>/...`, ou em Visão geral da conta).

**Se alguma dessas variáveis não estiver definida quando o usuário pedir algo desta skill, pare e siga o passo a passo abaixo com ele — nunca invente um valor, nunca peça para colar o token diretamente na conversa, e nunca tente ler credenciais de outro lugar (histórico de shell, arquivos não indicados).** Todos os scripts já detectam a ausência da variável sozinhos e entram em modo de simulação (dry-run) em vez de falhar — veja "Modo dry-run" abaixo.

### Passo a passo: criar o token de bootstrap (uma única vez)

1. Acesse `https://dash.cloudflare.com/profile/api-tokens` (logado na conta Cloudflare).
2. Clique em **Create Token** → **Create Custom Token**.
3. Em **Permissions**, monte:
   - `Usuário` → `Tokens de API` → `Editar` — permissão mínima obrigatória (permite criar/rolar/revogar outros tokens).
   - **Opcional, só se o usuário também quiser criar zonas/domínios novos por aqui:** adicione uma segunda linha `Conta` → `Zona` → `Editar`, e em **Account Resources** escolha a conta. Sem essa permissão extra, `zone_manager.py criar` não vai funcionar (mas `token_manager.py` e `dns_manager.py` funcionam normalmente).
4. Em **Client IP Address Filtering**, se a máquina que vai rodar os scripts tiver IP fixo, restrinja a ele — reduz ainda mais o risco caso o token vaze. Se não tiver, deixe em branco.
5. Defina um **TTL** se fizer sentido para o caso de uso (recomendado para ambientes de CI/CD; token permanente é aceitável para uso pessoal recorrente).
6. **Continue to summary** → **Create Token**.
7. A Cloudflare mostra o valor **uma única vez**. Não cole esse valor de volta nesta conversa — exporte-o direto como variável de ambiente (próxima seção).

### Passo a passo: descobrir o Account ID

Não é secreto, mas também não precisa ser adivinhado: está visível na URL do painel assim que você abre qualquer zona (`dash.cloudflare.com/<ACCOUNT_ID>/dominio.com/...`), ou em **Manage Account → Account Home**, no card "Account ID".

### Passo a passo: conectar GitHub/GitLab ao Cloudflare Pages (uma única vez, só se for publicar sites via repositório)

Só é necessário se for usar o fluxo 6 (publicar um site a partir de um repositório). É o **único passo desta skill que continua manual e não pode virar API** — é uma tela de autorização OAuth do GitHub/GitLab, não uma credencial que se gera no painel:

1. Acesse `https://dash.cloudflare.com/<ACCOUNT_ID>/workers-and-pages/create/pages`.
2. **Importar um repositório Git existente** → aba **GitHub** (ou **GitLab**) → botão **Conectar o GitHub**.
3. Autorize o app "Cloudflare Pages" a acessar a organização/conta dona do(s) repositório(s) — dá para restringir a repositórios específicos.

Depois desse passo único por conta, `pages_manager.py criar` funciona para qualquer repositório autorizado, sem precisar repetir a autorização.

### Configurando as variáveis com segurança

Nunca digite o token em um comando que fica salvo no histórico do shell sem proteção nem cole no chat. Prefira:

```bash
# bash/zsh — sessão atual apenas (não persiste em novos terminais)
read -s -p "Cole o CLOUDFLARE_BOOTSTRAP_TOKEN: " CLOUDFLARE_BOOTSTRAP_TOKEN && export CLOUDFLARE_BOOTSTRAP_TOKEN
export CLOUDFLARE_ACCOUNT_ID="<account id, não é secreto>"
```

Para persistir entre sessões, um arquivo `.env` (adicionado ao `.gitignore` do projeto, **nunca commitado**) carregado por `direnv`, `dotenv`, ou equivalente é uma alternativa aceitável — mas o script nunca deve escrever nem imprimir o conteúdo desse arquivo.

Depois de configurar, valide com:

```bash
python scripts/cf_api.py CLOUDFLARE_BOOTSTRAP_TOKEN
```

## Modo dry-run (padrão de segurança dos scripts)

Todo script desta skill checa a variável de ambiente correspondente antes de fazer qualquer chamada de rede. Se ela não existir, ele **não falha silenciosamente nem inventa nada** — imprime exatamente qual chamada faria (método, URL, corpo da requisição) prefixado com `[DRY-RUN]`, e explica qual variável falta. Isso serve para:

- Revisar o que uma ação vai fazer antes de rodá-la de verdade.
- Testar/demonstrar a skill sem precisar de uma credencial real.

Ao apresentar um plano de dry-run ao usuário, pergunte se ele quer prosseguir de verdade antes de configurar a credencial e reexecutar — trate como qualquer outra ação que muda configuração de conta.

## Fluxos de trabalho

Todos os comandos abaixo rodam a partir da pasta `scripts/` desta skill (ou referencie o caminho completo).

### 1. Gerar um token escopado para um domínio já existente no Cloudflare

Equivalente ao fluxo manual (painel → Create Custom Token → DNS Edit + Zone Edit + Cloudflare Pages Edit → zona específica):

```bash
python token_manager.py criar --dominio projetvs.com.br --nome projetvs.com.br
```

Usa o preset `dns-pages` por padrão (DNS Write + Zone Write na zona, Cloudflare Pages Write na conta — o mesmo conjunto que usamos manualmente). Outros presets: `dns-somente`, `dns-leitura`. Para permissões totalmente customizadas, use `--permissoes` e `--permissoes-conta` (veja `python token_manager.py criar --help`).

O valor do token só é impresso uma vez, com aviso para copiar imediatamente — nunca é regravado em nenhum arquivo por este script.

### 2. Rotacionar (rolar) ou revogar um token existente

```bash
python token_manager.py rolar --nome projetvs.com.br     # revoga o valor atual, gera um novo, mesmas permissões
python token_manager.py revogar --nome projetvs.com.br   # revoga definitivamente
python token_manager.py listar                            # lista todos os tokens de API do usuário
```

**Sempre confirme com o usuário antes de rodar `rolar` ou `revogar` de verdade** (fora do modo dry-run) — são ações que invalidam credenciais possivelmente em uso em produção. Pergunte: "isso vai revogar o token atual imediatamente, algo depende dele em produção agora?"

### 3. Adicionar um domínio novo do zero

```bash
python zone_manager.py criar --dominio novosite.com.br
```

Isso só cria o registro da zona na Cloudflare e devolve os nameservers — **o domínio só fica ativo depois que o usuário configurar esses nameservers no registrador** (Registro.br, GoDaddy, etc.), uma etapa manual fora da Cloudflare que nenhum script cobre. Sempre mostre os nameservers retornados e avise sobre esse passo. Depois que a zona estiver ativa, siga para o fluxo 1 para gerar o token daquela zona.

### 4. Gerenciar registros DNS de uma zona

Requer o token *daquela zona específica* (não o de bootstrap) na variável `CLOUDFLARE_ZONE_TOKEN` (ou outro nome, passando `--var-ambiente`):

```bash
python dns_manager.py listar --dominio projetvs.com.br
python dns_manager.py criar --dominio projetvs.com.br --tipo CNAME --nome app.projetvs.com.br --conteudo meuapp.pages.dev --proxied
python dns_manager.py atualizar --dominio projetvs.com.br --id <record_id> --conteudo novo-destino.pages.dev
python dns_manager.py remover --dominio projetvs.com.br --id <record_id>
```

Por que um token separado do de bootstrap: se o token de DNS de um projeto vazar, ele não pode ser usado para criar ou revogar outros tokens — o dano fica contido àquela zona.

### 5. Provisionar domínio novo até a ativação completa (pós-propagação)

Depois que `zone_manager.py criar` retorna os nameservers e o usuário os configura no registrador, a zona leva de alguns minutos a até 24h para o Cloudflare marcar como `active` — isso é assíncrono e fora do controle desta skill. Em vez de o usuário aplicar manualmente, pelo painel, as recomendações que o próprio Cloudflare mostra para uma zona recém-ativada (conectar o domínio ao projeto certo, endurecer e-mail), rode:

```bash
python provisionar_dominio.py verificar-e-aplicar --dominio novosite.com.br --projeto-pages meu-projeto
```

O que esse comando faz, na ordem:

1. Consulta o status da zona (`GET /zones?name=...`) usando `CLOUDFLARE_BOOTSTRAP_TOKEN`. Se ainda não estiver `active`, **não altera nada** — só avisa que a propagação ainda não terminou e sugere rodar de novo mais tarde.
2. Se já estiver `active`, conecta a raiz do domínio e (por padrão) o `www` como **Custom Domains** do projeto indicado no Cloudflare Pages (`POST /accounts/{account_id}/pages/projects/{projeto}/domains` — é isso que ativa roteamento + SSL, não só um CNAME solto), usando `CLOUDFLARE_ZONE_TOKEN`. Cria também um CNAME de rede de segurança caso o Custom Domain não provisione o DNS sozinho.
3. Verifica se a zona já tem algum registro MX. Se **não tiver nenhum** (ou seja, o domínio ainda não tem e-mail configurado), aplica um SPF restritivo (`v=spf1 -all`) e um DMARC restritivo (`v=DMARC1; p=reject;`) — só para impedir spoofing de e-mail "de" um domínio que ainda não envia e-mail de verdade. Se **já existir MX**, o script não mexe em nada relacionado a e-mail, para não sobrescrever uma configuração real.

Opções úteis: `--sem-www` (conecta só a raiz), `--pular-seguranca-email` (não mexe em SPF/DMARC de jeito nenhum, para quando o usuário já sabe que vai configurar e-mail em breve), `--account-id` (senão lê de `CLOUDFLARE_ACCOUNT_ID`).

É **seguro rodar esse comando várias vezes** (idempotente): ele sempre checa se o domínio personalizado / registro já existe antes de criar, então repetir a execução enquanto se espera a propagação nunca duplica nada nem falha por "já existe".

Como a propagação pode demorar horas, **não bloqueie a conversa esperando**: explique ao usuário que a zona ainda está propagando, ofereça para checar de novo mais tarde (ex. lembrete ou nova mensagem do usuário), e não fique repetindo a chamada em loop apertado.

### 6. Publicar um site novo a partir de um repositório Git (GitHub/GitLab)

Equivalente ao fluxo manual: Workers e Pages → Criar aplicativo → "Importar um repositório Git existente" → selecionar repo → configurar build → "Salvar e implantar". Requer que o GitHub/GitLab já esteja conectado à conta (ver "Pré-requisitos" acima).

```bash
python pages_manager.py criar --projeto amazonasterapia-com-br \
    --owner projetvs-pdi --repo amazonasterapia.com.br --branch main \
    --framework react-vite
```

`--framework` é um atalho para o comando de build + diretório de saída dos frameworks mais comuns (`react-vite`, `react-cra`, `vue`, `next-static`, `nuxt`, `sveltekit`, `angular`, `hugo`, `jekyll`, `gatsby`, `astro`, `nenhum`) — **sempre confirme com quem mantém o repositório** antes de assumir um preset, já que configurações customizadas (ex. `outDir` diferente no Vite) quebram esse valor padrão. Quando não tiver certeza, pergunte em vez de adivinhar. Para casos fora da lista, use `--comando-build` e `--diretorio-saida` diretamente (veja a tabela completa em `references/api_reference.md`).

```bash
python pages_manager.py listar                                    # lista projetos existentes
python pages_manager.py status --projeto amazonasterapia-com-br   # status da implantação mais recente (build/deploy)
```

É **seguro rodar `criar` mais de uma vez** (idempotente): se o projeto já existir, o script avisa e não faz nada, em vez de duplicar ou falhar.

Depois que o projeto existir (`<projeto>.pages.dev` já está no ar), conecte o domínio próprio com o fluxo 5 (`provisionar_dominio.py verificar-e-aplicar --dominio ... --projeto-pages <projeto>`), que também cuida do SPF/DMARC. Ordem completa para publicar um site novo do zero, com domínio próprio: `zone_manager.py criar` → nameservers no registrador (manual) → `pages_manager.py criar` → `provisionar_dominio.py verificar-e-aplicar`.

## Regras de segurança (sempre, sem exceção)

- Nunca peça, aceite ou repita o valor de um token/segredo dentro da conversa — nem para "confirmar", nem para "guardar". Trabalhe sempre via variável de ambiente.
- Nunca escreva um token em um arquivo de log, histórico de comandos salvo, ou em qualquer arquivo dentro do repositório do usuário.
- Ao criar/rolar um token, avise explicitamente que o valor só aparece uma vez e precisa ser copiado imediatamente para um cofre de segredos.
- Confirme com o usuário antes de qualquer ação que revoga, exclui ou substitui uma credencial ou registro DNS existente (ver "Fluxos de trabalho" acima) — essas ações têm efeito imediato em produção.
- Prefira sempre o menor escopo de permissão que resolve o pedido (zona específica > "todas as zonas"; permissão de leitura > edição, quando a tarefa só precisa ler).
- Se faltar uma variável de ambiente, siga a seção "Pré-requisitos" com o usuário passo a passo — nunca prossiga adivinhando ou usando outra credencial "por perto".

## Referência

Para o mapeamento completo de endpoints, formato exato dos campos `resources` (como escopar por zona/conta), e erros comuns, veja `references/api_reference.md`.
