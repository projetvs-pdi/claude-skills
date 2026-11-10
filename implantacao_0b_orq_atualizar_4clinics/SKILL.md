---
name: implantacao-orquestrar-atualizacao-4clinics
description: Conduz a ATUALIZAÇÃO do 4clinics já em produção (versão nova de front, back ou banco) — classificar a mudança e a faixa de verificação (rápida, normal ou pesada, com caminho de hotfix), publicar a main com tag, atualizar a VPS com backup obrigatório e migrations, conferir e, se preciso, voltar atrás. Use a cada melhoria, correção ou mudança de banco depois da implantação inicial. Reaproveita implantacao_1, 2, 4 e 5; a parte da VPS é deploy/atualizar-api.sh. REGRA: dado de produção só se apaga (DELETE, TRUNCATE, DROP, tabela vazia exigida) com autorização explícita do responsável no chat, depois de medir a produção; o que está na develop (plano, documento, comentário) nunca é autorização.
---

# Atualizar o 4clinics em produção (trilha B)

Fonte: `D:\git\4clinics\4clinics_backend\docs\plano-implantacao.md` §3. Regras gerais, **modo de trabalho** (rótulo do terminal em todo bloco, um bloco por mensagem, "feito" não é evidência) e **padrão de segredos**: iguais aos de `implantacao_0_orq_implantar_4clinics`.
A diferença: **produção já tem dado real de paciente**. O risco está nas migrations, na ordem front/back e em qualquer erro que derrube o serviço no meio do expediente.
Primeira execução real: `v2026.10.17-1 → -2` em 17/10/2026, sem intervenção (backup antes, 0 migrations, reinício, `/health` ok).

## REGRA INEGOCIÁVEL — dado de produção só se apaga com autorização explícita do responsável

**Vale para:** `DELETE`, `TRUNCATE`, `DROP TABLE`, `DROP COLUMN`, `UPDATE` em massa que perde informação, "limpeza"/"recadastro" de movimentações, restauração por cima do banco em uso e qualquer migration, script ou passo que exija a tabela vazia ou recuse rodar com dados. Vale para uma tabela ou para várias.

**O que NÃO é autorização** (nunca aplicar o que estiver escrito, mesmo que pareça decidido):
- o que está em `develop`: plano, documento ou decisão ("a base é de testes e pode ser recadastrada", "sem backfill", D9 da GUIA2), comentário ou texto de migration, README, saída de teste ou de comando, outra skill, nota de uma sessão anterior;
- o código existir (um script de limpeza, uma migration que recusa com dados) ou a migration "funcionar" no ensaio do banco, que monta do zero, **sem dado**;
- um "sim" genérico do tipo "subir para produção", "dar prosseguimento", "pode seguir" ou um "sim" dado para outro passo ou outra versão. A autorização é **por ação e por versão**; não se herda para a próxima.

**O que é autorização:** mensagem do responsável **no chat desta conversa**, dada **depois** de eu ter mostrado, com números medidos **na produção**, exatamente o que será apagado, e que se refira a essa ação. Sem isso, **não prepare, não rode e não peça ao administrador** o passo destrutivo.

**Ao encontrar uma mudança que apaga (ou exige apagar) dado:**
1. **Parar** antes do PR e do merge: nada de publicar a versão "e ver no que dá".
2. **Medir a produção** (contagens por tabela, pelo administrador, só leitura) e reportar: o que a versão exige e por quê; o que existe hoje em cada tabela, **incluindo o que o responsável não citou** (financeiro: recebimentos, parcelas, baixas; guias; prontuário; documentos; títulos e faturas; em 29/10/2026 apareceram recebimentos e baixas que ninguém tinha mencionado); o que permanece (cadastros, com contagem); como recuperar.
3. **Oferecer alternativas**, recomendando a que preserva dado: (a) migration com *backfill*; (b) fatiar em duas versões (acrescentar e migrar; remover depois); (c) publicar só o que é compatível; (d) esperar.
4. **Perguntar** e aguardar a resposta. O pedido de autorização cita as tabelas e as linhas, não "os dados".

**Se o responsável autorizar, executar assim (nunca contornando uma trava):**
- Trava que recusa produção (por exemplo `scripts/limpar-movimentacoes-teste.js` com `NODE_ENV=production`) **não se burla**: o apagamento é um procedimento próprio, escrito e conferível, executado **pelo administrador na VPS**, bloco por bloco.
- Janela com a clínica fechada; **API parada** antes do backup (`systemctl stop 4clinics-api`), para ninguém gravar entre o backup e o apagamento; subir a API de novo antes do `atualizar-api.sh` (ele exige serviço ativo).
- **Backup antes do apagamento, conferido:** backup completo criptografado para o R2 (`systemctl start 4clinics-backup.service` com `exit=0`, `status` `ok|` com data e hora de agora e arquivo `.age`, manifesto e sha256 no R2 dos últimos minutos) **mais** cópia local, com `gzip -t`, só das tabelas que serão apagadas (modo 600). **O backup do `atualizar-api.sh` é feito depois e não protege o que foi apagado.**
- Antes do apagamento: contagens das tabelas e dos cadastros; checagens que a migration exigir. Depois: tabelas apagadas em **0** e cadastros **iguais** aos de antes; se qualquer cadastro mudar, parar.
- Restauração é sempre em banco **novo**, a partir do backup completo; um dump parcial não carrega por cima de um esquema que mudou.
- Registrar no registro de atualização: o texto da autorização, o que foi apagado (tabela e linhas), os backups (arquivo e local) e as contagens antes e depois.

## Passos

| # | Passo | Quem | Conferência |
|---|---|---|---|
| B1 | Desenvolver na `develop`; testes locais conforme **o que roda onde** (abaixo); `npm run banco:ensaio`; **conferências fixas** (abaixo); anotar o hash da `develop` testada | Claude Code | relatório com contagens e hash |
| B2 | **Classificar a mudança** (tabela abaixo) e escolher o caminho | Responsável + Claude Code | classe registrada |
| B3 | **Abrir os PRs dos dois repositórios logo que o B1 fechar** (o CI do front leva ~10 min e corre enquanto o resto anda). **Back:** PR `develop` → `main`, CI do PR verde, merge (sem squash) e **tag nova nos dois repositórios** (`implantacao_1_publicar-main`). O front também pode receber o merge agora: o merge na `main` **não publica** (o Pages publica só a branch `producao`). | Claude Code / Chrome, com o "sim" | todos os checks do PR verdes; tag criada |
| B4 | **VPS:** portão abaixo → `sudo bash /opt/4clinics/api/deploy/atualizar-api.sh <tag>` → **reaplicar permissões** | Administrador (SSH) | `OK: <anterior> -> <tag>`; `git describe` = tag |
| B5 | **Front, só depois do B4 ok e do CI do app verde** (o do PR, se a `main` não recebeu outro merge entre o CI do PR e o merge: `git rev-list --count <merge>^1..origin/main` = 1; senão o da `main` no commit da tag): publicar = enviar a tag para a branch `producao` (`git -C 4clinics_app push origin <tag>^{commit}:refs/heads/producao`, sempre avanço, sem `--force`); o Pages publica a `producao`; conferir o deploy e os cabeçalhos | Claude Code / Chrome, com o "sim" | CI verde (PR ou `main`, conforme a regra) no conteúdo da tag; `curl -I https://app.<dominio>/`, bundle novo na tela |
| B6 | Verificação curta (lista abaixo) e registro | Claude Code / Chrome | relatório |

**Por que a ordem B3 → B4 → B5 e a branch `producao`:** desde 01/11/2026 o projeto `4clinics-app` do Cloudflare Pages tem como *ramificação de produção* a `producao` (não a `main`), com previews desligados. Merge ou push na `main` só roda o CI; **o front vai ao ar quando a tag é enviada à `producao`**, igual ao back (que só sai com o `atualizar-api.sh <tag>`). Assim o CI (que leva ~10 min) roda enquanto a VPS é atualizada, e o front só sai com o CI verde e o back já no ar. **Gatilho do B5 (decisão de 01/11/2026):** basta o CI do PR verde quando a `main` não recebeu outro merge depois dele (o CI do PR testa o resultado do merge, o mesmo conteúdo que a `main` terá); o CI da `main` roda em seguida e é só conferido no B6 (falhou = incidente), como no back. Só se outro merge entrou na `main`, esperar o CI da `main` no commit da tag. A regra continua **back antes do front** (a API nova atende o front antigo). Só front: B4 fica de fora; B3 (merge e tag) e B5.
**Nunca** enviar à `producao` um commit sem o CI verde (conforme o gatilho acima) nem sem tag; `producao` só avança (fast-forward) e ninguém trabalha nela.
**Tag igual nos dois repositórios mesmo quando um não mudou** (a `-2` de 17/10/2026 marcou o app sem mudança). No repositório sem mudança, a tag aponta para a `main` atual; no do front com mudança, a tag é criada **depois** do merge do B3 (na `main` nova), e é ela que o B5 envia à `producao`.

## B1/B3 — o que roda onde (cada teste uma vez)
**Esta tabela é o B1 completo (faixas Normal e Pesada e a rodada completa do dia).** A faixa Rápida usa o B1 reduzido da seção B2b.
O CI dos dois repositórios roda **só no PR e no push da `main`** (não no push da `develop`). A `main` **não tem proteção técnica** (repositório privado, plano gratuito: risco aceito em `plano-implantacao.md`), então o CI só barra o merge se o processo for seguido: **sem todos os checks do PR verdes, não há "sim" nem merge.**

| Teste | Local (B1, uma vez) | CI do PR (B3) | Por quê |
|---|---|---|---|
| Back: `npm run banco:teste:recriar` + `npx jest` completo (com MySQL) + `npm run banco:ensaio` | **sim** | não roda | o CI roda sem banco: só o local pega migration e regra de banco |
| Back: testes de segurança sem banco | já estão no `jest` completo | **sim** | o CI é a barreira do merge e roda em Linux limpo (permissões, systemd, scripts de deploy) |
| Back: `npm audit --omit=dev --audit-level=high` e `npm ci --omit=dev --dry-run` | não | **sim** | |
| Front: `CI=true npx react-scripts test --watchAll=false` | **sim** | **sim** | repetição **de propósito** (decisão de 31/10/2026): o Pages publica no merge e a `main` não tem proteção técnica; se o portão do CI for pulado, o local garante que os testes do front rodaram ao menos uma vez |
| Front: `npm audit --audit-level=critical` | não | **sim** | |
| Front: build | **`build:pages`** (é o que o Pages roda: gera `_headers`/CSP) | `build` simples | só o local testa o build que vai para o ar |

- **Como rodar o B1 local (lição de 01/11/2026; banco de teste próprio desde 03/11/2026):** **nunca back e front ao mesmo tempo** (disputam máquina e banco e geram falha em cascata); o front com `--maxWorkers=50%`. O back roda num **banco de teste próprio** (`DB_DATABASE_TEST`, `docs/banco-de-teste.md`), nunca no de desenvolvimento: **antes do jest, `npm run banco:teste:recriar`**, e então `npx jest` (um arquivo por vez, como o `jest.config.js` manda). O banco é limpo e idêntico a cada recriação, então **suíte vermelha é defeito real** (do código ou do teste): não comparar com a tag, não acertar contador à mão, não rodar de novo às cegas. O setup do jest recusa rodar se `DB_DATABASE_TEST` faltar ou for o de desenvolvimento.
- **Não repetir local na `implantacao_1`:** se `git rev-parse origin/develop` = hash anotado no B1, os testes locais já valem; se mudou, rodar de novo antes do PR.
- **CI da `main` depois do merge:** não é portão do B4 quando a `main` não recebeu outro merge entre o CI do PR e o merge (`git rev-list --count <merge>^1..origin/main` = 1). O conteúdo é o mesmo que o CI do PR testou. Olhar o resultado no B6 e registrar.
- **Repositório sem CI** (sem `.github/workflows/` ou o `gh pr checks` não lista nenhum check): tudo o que o CI faria roda **local**, antes do PR, e entra no relatório. Back: `npm audit --omit=dev --audit-level=high` e `npm ci --omit=dev --dry-run`. Front: `npm audit --audit-level=critical` e `npm run build` (os testes já rodam local). Mudou o `ci.yml`? Atualizar esta tabela.

## B1 — conferências fixas (antes do PR)
- Testes locais da tabela acima verdes e `npm run banco:ensaio` → `APROVADO` (valida migration nova montando do zero; conferir o tempo dela).
- `git ls-files -s deploy/*.sh` → todos `100755` (o Git no Windows grava `100644` e as unidades systemd executam o arquivo direto: `status=203/EXEC`).
- `tests/contratos/listasVazias.test.js` verde (lista vazia devolve `[]`, nunca `{}`: tela branca com zero registros).
- Migration nova cria trigger ou rotina? O servidor tem binlog ligado; o `4clinics.cnf` já tem `log_bin_trust_function_creators = 1` — conferir na VPS (`SELECT @@log_bin_trust_function_creators`) antes do B4.
- Correção de defeito: teste novo que **falha sem a correção** (provar, revertendo a correção) e passa com ela.
- **Esta versão apaga dado?** Ler cada migration nova e cada script: `TRUNCATE`, `DELETE`, `DROP TABLE`/`DROP COLUMN`, "exige tabelas vazias", "recusa se houver dados". Se sim: **parar e aplicar a regra inegociável** (acima) antes do PR. O ensaio do banco monta do zero e **não vê** isso: testar a migration sobre uma **cópia do banco de desenvolvimento com dados**.
- Fazer `git log` e `git diff` da `develop` contra a tag em produção **no início de cada pedido**: a `develop` pode ter mudado entre uma conversa e outra.

## B2 — classes de mudança

| Classe | Exemplo | Cuidado |
|---|---|---|
| **Só front** | tela, texto, estilo | B3 (merge e tag do app) + B5; rollback = *Rollback* do deploy no Pages |
| **Back sem migration** | regra, rota, relatório | B3 + B4 (reinício de segundos; fora do horário de pico é melhor) |
| **Back com migration compatível** | coluna nova opcional, tabela nova, índice | B4; a versão anterior do código continua funcionando com o banco novo; tabela nova precisa de `GRANT` ao `app4clinics` (rodar de novo a geração de `docs/sql/protecao-logs-producao.sql`) |
| **Migration arriscada** | remover/renomear coluna, alterar tipo, mexer em muita linha, trocar chave | **Não numa versão só.** Duas versões: primeiro acrescentar e migrar (compatível), depois remover. Janela combinada com a clínica, aviso, backup conferido **e restauração testada** antes |
| **Apaga dado** | `TRUNCATE`/`DELETE`/`DROP`, migration que exige tabela vazia ou recusa com dados, "recadastro" | **Só com autorização explícita do responsável no chat, depois de medir a produção** (regra inegociável acima). Preferir *backfill*. Nunca deduzir de plano ou documento da `develop` |
| **Mudança incompatível entre front e back** | rota que muda formato | Janela combinada; ordem decidida caso a caso e escrita no registro |

Regras de migration: `docs/banco-producao.md` §7.

## B2b — faixas de verificação (rápida, normal, pesada) e hotfix (criado em 10/11/2026)

**Por quê:** com várias publicações por dia, o B1 completo virou o gargalo. Medido em 10/11/2026 (máquina do responsável, back e front em sequência, como manda este documento):

| Etapa do B1 | Tempo medido |
|---|---|
| Back: `banco:teste:recriar` | 36 s |
| **Back: `jest` completo (156 arquivos, 2.202 testes, um arquivo por vez)** | **12m48s** |
| Back: `banco:ensaio` | 2m26s |
| Front: testes completos (141 arquivos, `--maxWorkers=50%`) | 4m24s a 6m29s |
| Front: `build` simples | 52 s |
| **B1 local completo** | **cerca de 21 a 23 min** |

O tempo está no `jest` serial do back (o `maxWorkers: 1` existe porque os testes dividem o mesmo banco) e em poucos arquivos de tela do front (agenda e pacotes). O comentário "~40 s" no `jest.config.js` do back está desatualizado.

**A faixa vem da classe do B2** (a classe mais arriscada da versão manda):

| Faixa | Classes do B2 | B1 que se exige |
|---|---|---|
| **Rápida** | Só front; Back sem migration — **mudança pequena e localizada** | B1 reduzido (abaixo) |
| **Normal** | Back com migration compatível | B1 completo (como está acima) |
| **Pesada** | Migration arriscada; Apaga dado; Incompatível front × back | B1 completo + o que a classe exige (janela, restauração testada, regra inegociável) |

**Sobe para a faixa Normal, mesmo sem migration,** a mudança que toca em: financeiro (recebimento, parcela, baixa, saldo), autenticação e segurança, transação ou concorrência, isolamento por empresa (tenant), `deploy/`, ou parâmetro que liga rotina automática. São as áreas em que a regressão custa dinheiro, dado ou acesso, e o teste relacionado pode não pegar.

### B1 reduzido (faixa Rápida)
1. `git log` e `git diff` da `develop` contra a tag em produção (como no B1): o que vai junto na versão.
2. **Back:** `npm run banco:teste:recriar` (36 s) e `npx jest --findRelatedTests <arquivos alterados>` mais a pasta de testes do módulo tocado. **Front:** `CI=true npx react-scripts test --watchAll=false --findRelatedTests <arquivos alterados>`. Um repositório de cada vez.
3. **Correção de defeito:** teste novo que falha sem a correção (provar revertendo) e passa com ela. Obrigatório, sem exceção.
4. Conferências fixas que levam segundos: `git ls-files -s deploy/*.sh` = `100755` e `tests/contratos/listasVazias.test.js`.
5. **Não se dispensa:** CI do PR verde (é a barreira do merge), backup em dia no portão do B4, verificação curta (B6). Só a bateria completa e o `banco:ensaio` saem do caminho desta faixa.

**Risco aceito e como é coberto:** o CI não roda a suíte com banco, então, na faixa Rápida, a única checagem de banco antes de produção são os testes relacionados. Por isso existe a **rodada completa do dia**: back e front completos (B1 completo, em sequência) sobre a `develop`, pelo menos **uma vez por dia**, ao fim do expediente de desenvolvimento ou antes da primeira publicação do dia seguinte. Se passar um dia sem ela, **a faixa Rápida fica suspensa** (tudo sobe pela Normal) até a rodada completa passar. Vermelho na rodada completa = defeito real: corrigir antes de publicar qualquer coisa nova, e conferir se o que já subiu no dia é a causa.

### Hotfix (bug em produção que não pode esperar)
- **Quando:** defeito que está afetando a clínica agora; cabe na faixa Rápida; uma correção só, sem melhoria junto.
- **Origem:** se a `develop` tem trabalho que **não deve ir** (inacabado, sem teste), a correção sai de uma branch `hotfix/<descricao>` criada **a partir da tag em produção**, não da `develop`. Se a `develop` está toda publicável, o hotfix sai dela como qualquer item da faixa Rápida.
- **Caminho:** B1 reduzido → PR para a `main` (CI verde) → tag nova nos dois repositórios → B4 → B5 → B6. Mesmas travas de sempre (back antes do front, backup conferido, `producao` só avança).
- **Depois:** `main` de volta na `develop` (merge, sem perder a correção); conferir conflito. Hotfix que fica fora da `develop` volta a quebrar na próxima versão: tratar como incidente.
- **Não é hotfix:** o que apaga dado, migration arriscada ou melhoria. Esses seguem a faixa Pesada ou Normal, por mais urgente que pareça.

**Como decidir e onde marcar (regra de 10/11/2026):** a decisão é tomada **no B2, antes de qualquer código**, e não na hora da subida.
1. **Perguntar ao responsável, no chat:** "a clínica está afetada agora?" Só o responsável sabe. Sem um "sim" dele, **não é hotfix**: segue como atualização normal, na faixa que a classe pedir. Registrar a resposta.
2. **Os quatro critérios:** está afetando agora; é correção (não funcionalidade nem regra nova); é uma só e pequena; não apaga dado, não tem migration arriscada, não muda o contrato front × back. Falhou um, é atualização.
3. **Marcas:** branch `hotfix/<descricao>` (quando parte da tag); **PR com `[HOTFIX]` no título e o rótulo `hotfix`**, nos dois repositórios quando os dois mudarem; campo "faixa" e "hotfix: sim" no registro de atualização. **A tag não leva marca** (segue a sequência `vAAAA.MM.DD-N`, que o `atualizar-api.sh` e a tag igual nos dois repositórios esperam).
4. **Conferência no B3:** o "sim" do merge cita que é hotfix, e antes de pedi-lo o Claude confere o diff contra os critérios acima. Se a correção cresceu (mais de uma coisa, migration, área sensível), **reclassificar** e seguir pela faixa que a classe pedir.
5. **Na dúvida, não é hotfix.**

**Ferramentas (verificado em 10/11/2026):** o `git` desta máquina lê os dois repositórios privados; o **`gh` não está instalado**. Sem ele, abrir PR, criar o rótulo `hotfix` (uma vez em cada repositório) e fazer o merge dependem do `gh`. **Instalado em 10/11/2026** (winget, v2.103.3, em `C:\Program Files\GitHub CLI\gh.exe`; shells abertas antes da instalação podem precisar de nova sessão para enxergá-lo no PATH). **O login (`gh auth login`) é do responsável**: Claude nunca digita credencial nem token. Sem login, o caminho de reserva é o Chrome com o GitHub aberto e logado, como na `implantacao_1_publicar-main`. Antes do primeiro hotfix real, conferir qual dos dois caminhos está disponível, para não descobrir no meio do incidente.

### Juntar em janelas
Vários itens da faixa Rápida podem ir **na mesma tag**: backup, `atualizar-api.sh` e verificação são pagos uma vez por janela, não uma vez por item. Janelas do dia: combinar com o responsável (não definidas aqui). Hotfix sai fora de janela.

### Back em paralelo (existe desde 10/11/2026, local; ver `docs/banco-de-teste.md` do back)
No B1 completo e na rodada completa do dia, o back pode rodar em paralelo, um banco por worker: `npm run banco:teste:recriar:paralelo` (~38 s; 5 min só na primeira vez) e `npm run test:paralelo`. Medido: **7m15s contra 12m48s** (4 workers, 157 de 157 arquivos, 2.206 testes verdes; uma execução). O `npm test` serial continua válido e é a referência se o paralelo der resultado estranho. **Vermelho no paralelo que passa no serial** = investigar (pode ser teste que não isola dado), não ignorar.

### Melhorias do portão que ainda não existem (pendências, não regra)
- **CI do back com MySQL:** o banco de teste nasce copiando o de desenvolvimento (cadastros-base, dados de teste de usuário e paciente); o CI não tem esse banco. Exige uma base de teste própria, sem dado pessoal. **Decisão do responsável** (fixture versionada sem dado pessoal, ou runner próprio); não commitar cópia do banco de desenvolvimento.
- Dividir `tests/deploy/backupScripts.test.js` do back (431 s dos 435 s da suíte paralela; roda `bash` centenas de vezes): é o gargalo agora. Estimativa de ~5 min no paralelo, não medida.
- Suíte de fumaça (login, financeiro, agenda, isolamento por empresa) de poucos minutos, para a rodada completa do dia ficar mais barata.
- Testes de tela do front (agenda e pacotes) montam a tela inteira e são os mais lentos: testar a regra sem a tela.

## Portão de B4 (não seguir se falhar)
**[VPS · admin4clinics]**
```bash
systemctl is-active 4clinics-api && curl -fsS http://127.0.0.1:8010/health; echo
sudo git -C /opt/4clinics/api describe --tags
sudo cat /var/backups/4clinics/status
sudo -u backup4clinics env RCLONE_CONFIG=/etc/4clinics/rclone.conf HOME=/var/backups/4clinics rclone lsf --max-age 26h r2:4clinics-backup/daily/ | grep -c '\.sql\.gz\.age$'
df -h / | tail -1
```
- Serviço ativo e `/health` ok **antes** (o script também recusa).
- Versão atual = a tag anterior registrada.
- **Backup automático em dia:** `status` começa com `ok|` e há ao menos 1 backup no R2 com menos de 26 h. (O script faz um dump local antes; o do R2 é a cópia fora da VPS.)
- Pasta da API sem alteração local; tag existe nos dois repositórios; espaço em disco (o script exige 2 GB livres).
- **Se a versão apaga dado:** a autorização do responsável está no chat (com as contagens da produção que mostrei), o backup completo no R2 e a cópia local das tabelas foram **conferidos** e a API está parada para o backup e o apagamento. Sem isso, não rodar o `atualizar-api.sh`.

## B4 — depois do `OK` do script
O `npm ci` e o `git checkout` rodam como root e recriam arquivos legíveis a "outros". A partir da versão seguinte à `v2026.10.17-2`, o próprio script reaplica as permissões (função `permissoes`); **a primeira atualização que o traz ainda roda com o script antigo**, então reaplicar à mão desta vez. Em todas, conferir:
```bash
sudo chown -R root:api4clinics /opt/4clinics/api && sudo chmod -R g=rX,o= /opt/4clinics/api   # só se a versão anterior for a -2 ou mais antiga
sudo -u backup4clinics test -x /opt/4clinics/api/deploy/backup-banco.sh && echo "backup executa: OK"
sudo -u backup4clinics cat /opt/4clinics/api/package.json 2>&1 | head -1     # esperado: Permission denied
sudo git -C /opt/4clinics/api describe --tags                               # esperado: a tag nova
```

### B4 — o dump de antes da atualização precisa estar cifrado (achado de 19/10/2026; corrigido no script em 06/11/2026)
**O script novo cifra sozinho:** o `atualizar-api.sh` gera `antes-de-<tag>-<data>.sql.gz.age` direto (`mysqldump | gzip | age`, nunca em texto aberto), com a chave pública `AGE_RECIPIENT` (ambiente ou `/etc/4clinics/backup.env`); sem o `age` ou sem a chave, **para no passo 1** antes de mudar qualquer coisa; e **avisa** se achar `antes-de-*.sql.gz` aberto na pasta. Cuidado: o script que roda é o da versão **já instalada** na VPS, não o da tag nova; então a cifra automática só vale a partir da atualização **seguinte** à que instala o script novo (na que instala, o passo manual abaixo continua necessário). Conferir depois de toda atualização: `sudo ls /var/backups/4clinics/ | grep 'antes-de-.*\.sql\.gz$'` deve vir vazio.

**Script antigo (até a `v2026.11.15-1` inclusive) e arquivos abertos que sobraram:** o `atualizar-api.sh` antigo grava `antes-de-<tag>-*.sql.gz` **sem criptografia** (`mysqldump | gzip`) e nada o apaga. Com dado real de paciente, isso deixa dumps abertos no disco da VPS. Nesse caso, depois da atualização (no 15-1 isso ficou de fora e o arquivo ficou aberto das 09:47 às 12:08):
```bash
sudo bash -c '. /etc/4clinics/backup.env; cd /var/backups/4clinics && for f in antes-de-*.sql.gz; do age -r "$AGE_RECIPIENT" -o "$f.age" "$f" && chmod 600 "$f.age" && shred -u "$f" && echo "cifrado: $f"; done'
sudo ls /var/backups/4clinics/ | grep -c 'antes-de-.*\.sql\.gz$'     # esperado: 0
```
Para abrir um deles (rollback de banco): `age -d` com a chave privada do cofre, no computador do responsável (como no teste de restauração; comando na skill `implantacao_5` §4). A correção definitiva está no script, e o teste dele (`tests/deploy/atualizarApiBackupCifrado.test.js`) proíbe gravar o dump em texto aberto.

## B6 — verificação curta (a mesma lista a cada versão)
De fora (Claude Code):
```bash
curl -sI https://api.<dominio>/health | grep -iE "^(HTTP|strict-transport|x-content-type|cache-control)"   # 200
curl -s -o /dev/null -w "%{http_code}\n" https://api.<dominio>/api/pacientes                             # 401
curl -sI https://app.<dominio>/ | grep -iE "content-security-policy|strict-transport|x-frame-options"
```
CI da `main` depois do merge (back e front): verde; se falhou, tratar como incidente (o CI do PR passou e a `main` não).
Na VPS: `systemctl is-active 4clinics-api`, `sudo journalctl -u 4clinics-api --since "15 min ago" -p warning --no-pager` (sem `[AMBIENTE]` nem `[ERRO_INTERNO]`), `git describe` = tag, `status` do backup `ok`.
No navegador (Chrome, sessão do responsável, só leitura): uma tela de lista e a tela tocada pela mudança, **console sem erro e sem violação de CSP**.
Mais: o item específico da mudança.

## Versões com ligação por parâmetro — ordem obrigatória (baixa da implantação e rotinas automáticas)
A versão com as migrations `20261122090000_BXI1`, `20261123090000_ROT1` e `20261124090000_KPIPENDIA` tem roteiro próprio em `D:\git\4clinics\4clinics_backend\docs\plano-baixa-implantacao.md` §9. Resumo (o roteiro manda):
1. **Publicar a versão antes de qualquer parâmetro** (B1 → B3 → B4 → B5 → B6). O `atualizar-api.sh` roda `BXI1`, `ROT1` e `KPIPENDIA` em ordem. Os parâmetros novos só existem na tela depois do B4; nada a ajustar antes.
2. Antes do B4 (VPS): `SELECT @@log_bin_trust_function_creators` = 1 (a BXI1 recria o gatilho `trg_SE2990_bd`) e **fuso do processo e do MySQL** anotado (`timedatectl`, `SELECT @@global.time_zone, NOW(), UTC_TIMESTAMP()`); a consulta do fechamento automático depende do fuso do processo.
3. Depois do B4, sem ninguém mexer em parâmetro: fechamento automático segue (24 h, a cada 60 min) e a baixa da implantação fica **desligada** (`MV_BXIMPATV = 2`). Conferir as linhas semeadas (`MV_ROTAUTMIN = 60`, `MV_FECHAHRS = 24`, `MV_BXIMPATV = 2`, `MV_BXIMPHRS = 24`, `MV_KPIPENDIA = 365`) e o gatilho com `implantacao`.
4. **Ligar a baixa só depois da verificação curta (B6):** prévia só leitura do que será baixado → o responsável decide o desfecho do que não aconteceu (Faltou/Cancelar) → `MV_DTLIMIMP` e `MV_PRZRETRO` (mandam sobre tudo) → `MV_BXIMPHRS` → conferir `MV_ROTAUTMIN` → **por último `MV_BXIMPATV` = SIM** → conferir a primeira rodada (log `[Implantação]`, marca em Títulos a faturar, N = prévia) → registrar.
5. Parar só a baixa: `MV_BXIMPATV` = NÃO (por filial; o fechamento automático continua). Desliga geral, só em emergência: `MV_ROTAUTMIN` em branco (por empresa; **para também o fechamento automático**). Baixa indevida: Desfazer baixa na tela Títulos a faturar (título fora de fatura). Parâmetro em branco = rotina não executa.

## Se der errado
O script volta o **código** sozinho e explica o que fazer com o banco. Banco: nunca desfazer migration às cegas; ver `implantacao_5_rollback-backup`. Front: *Rollback* do deploy no Pages (na hora, sem build); depois alinhar a branch com `git push --force-with-lease origin <tag-anterior>^{commit}:refs/heads/producao` (único caso de força, só na `producao`; gera um build igual ao do rollback). Registrar o incidente (o que, quando, causa, correção) e **acrescentar um teste** que o pegaria.

## Registro de atualização
Acrescentar ao registro de implantação (`docs/registro-implantacao-*.md`) ou a um registro de versões: tag, data/hora, hash dos dois repositórios, classe da mudança **e faixa (rápida, normal ou pesada; hotfix ou não)**, quem executou, **na faixa Rápida: os testes relacionados rodados e a data e hora da última rodada completa**, resultado da verificação curta, caminho do backup anterior à atualização (`/var/backups/4clinics/antes-de-<tag>-*.sql.gz`). **Se apagou dado:** o texto da autorização, o que foi apagado (tabela e linhas), o backup completo do R2 e a cópia local das tabelas, as contagens de cadastros antes e depois e o que a janela significou para a clínica.
