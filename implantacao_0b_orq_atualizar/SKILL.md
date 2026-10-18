---
name: implantacao-orquestrar-atualizacao
description: Conduz a ATUALIZAÇÃO do 4clinics já em produção (versão nova de front, back ou banco) — classificar a mudança, publicar a main com tag, atualizar a VPS com backup obrigatório e migrations, conferir e, se preciso, voltar atrás. Use a cada melhoria, correção ou mudança de banco depois da implantação inicial. Reaproveita implantacao_1, 2, 4 e 5; a parte da VPS é deploy/atualizar-api.sh.
---

# Atualizar o 4clinics em produção (trilha B)

Fonte: `D:\git\4clinics\4clinics_backend\docs\plano-implantacao.md` §3. Regras gerais, **modo de trabalho** (rótulo do terminal em todo bloco, um bloco por mensagem, "feito" não é evidência) e **padrão de segredos**: iguais aos de `implantacao_0_orq_implantar`.
A diferença: **produção já tem dado real de paciente**. O risco está nas migrations, na ordem front/back e em qualquer erro que derrube o serviço no meio do expediente.
Primeira execução real: `v2026.10.17-1 → -2` em 17/10/2026, sem intervenção (backup antes, 0 migrations, reinício, `/health` ok).

## Passos

| # | Passo | Quem | Conferência |
|---|---|---|---|
| B1 | Desenvolver na `develop`; suíte completa do back e do front; `npm run banco:ensaio`; **conferências fixas** (abaixo); CI verde | Claude Code | relatório com contagens |
| B2 | **Classificar a mudança** (tabela abaixo) e escolher o caminho | Responsável + Claude Code | classe registrada |
| B3 | **Back:** PR `develop` → `main`, CI, merge (sem squash) e **tag nova nos dois repositórios** (`implantacao_1_publicar-main`). **Não fazer o merge do front ainda.** | Claude Code / Chrome, com o "sim" | CI verde na `main` do back; tag criada |
| B4 | **VPS:** portão abaixo → `sudo bash /opt/4clinics/api/deploy/atualizar-api.sh <tag>` → **reaplicar permissões** | Administrador (SSH) | `OK: <anterior> -> <tag>`; `git describe` = tag |
| B5 | **Front, só depois do B4 ok:** merge do PR do app (o Cloudflare Pages publica a `main` **no momento do merge**); conferir o deploy e os cabeçalhos | Chrome, com o "sim" | `curl -I https://app.<dominio>/`, versão nova na tela |
| B6 | Verificação curta (lista abaixo) e registro | Claude Code / Chrome | relatório |

**Por que a ordem B3 → B4 → B5:** o Pages publica o front assim que a `main` do app recebe o merge. Fazer o merge dos dois repositórios juntos põe o front novo no ar **antes** da API nova. A regra é **back antes do front** (a API nova atende o front antigo). Só front: B3 e B4 ficam de fora, vai direto ao B5.
**Tag igual nos dois repositórios mesmo quando um não mudou** (a `-2` de 17/10/2026 marcou o app sem mudança). No repositório sem mudança, a tag aponta para a `main` atual; no do front com mudança, a tag é criada **depois** do merge do B5.

## B1 — conferências fixas (antes do PR)
- Suítes completas verdes e `npm run banco:ensaio` → `APROVADO` (valida migration nova montando do zero; conferir o tempo dela).
- `git ls-files -s deploy/*.sh` → todos `100755` (o Git no Windows grava `100644` e as unidades systemd executam o arquivo direto: `status=203/EXEC`).
- `tests/contratos/listasVazias.test.js` verde (lista vazia devolve `[]`, nunca `{}`: tela branca com zero registros).
- Migration nova cria trigger ou rotina? O servidor tem binlog ligado; o `4clinics.cnf` já tem `log_bin_trust_function_creators = 1` — conferir na VPS (`SELECT @@log_bin_trust_function_creators`) antes do B4.
- Correção de defeito: teste novo que **falha sem a correção** (provar, revertendo a correção) e passa com ela.

## B2 — classes de mudança

| Classe | Exemplo | Cuidado |
|---|---|---|
| **Só front** | tela, texto, estilo | Só o B5; rollback = *Rollback* do deploy no Pages |
| **Back sem migration** | regra, rota, relatório | B3 + B4 (reinício de segundos; fora do horário de pico é melhor) |
| **Back com migration compatível** | coluna nova opcional, tabela nova, índice | B4; a versão anterior do código continua funcionando com o banco novo; tabela nova precisa de `GRANT` ao `app4clinics` (rodar de novo a geração de `docs/sql/protecao-logs-producao.sql`) |
| **Migration arriscada** | remover/renomear coluna, alterar tipo, mexer em muita linha, trocar chave | **Não numa versão só.** Duas versões: primeiro acrescentar e migrar (compatível), depois remover. Janela combinada com a clínica, aviso, backup conferido **e restauração testada** antes |
| **Mudança incompatível entre front e back** | rota que muda formato | Janela combinada; ordem decidida caso a caso e escrita no registro |

Regras de migration: `docs/banco-producao.md` §7.

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

## B4 — depois do `OK` do script
O `npm ci` e o `git checkout` rodam como root e recriam arquivos legíveis a "outros". A partir da versão seguinte à `v2026.10.17-2`, o próprio script reaplica as permissões (função `permissoes`); **a primeira atualização que o traz ainda roda com o script antigo**, então reaplicar à mão desta vez. Em todas, conferir:
```bash
sudo chown -R root:api4clinics /opt/4clinics/api && sudo chmod -R g=rX,o= /opt/4clinics/api   # só se a versão anterior for a -2 ou mais antiga
sudo -u backup4clinics test -x /opt/4clinics/api/deploy/backup-banco.sh && echo "backup executa: OK"
sudo -u backup4clinics cat /opt/4clinics/api/package.json 2>&1 | head -1     # esperado: Permission denied
sudo git -C /opt/4clinics/api describe --tags                               # esperado: a tag nova
```

## B6 — verificação curta (a mesma lista a cada versão)
De fora (Claude Code):
```bash
curl -sI https://api.<dominio>/health | grep -iE "^(HTTP|strict-transport|x-content-type|cache-control)"   # 200
curl -s -o /dev/null -w "%{http_code}\n" https://api.<dominio>/api/pacientes                             # 401
curl -sI https://app.<dominio>/ | grep -iE "content-security-policy|strict-transport|x-frame-options"
```
Na VPS: `systemctl is-active 4clinics-api`, `sudo journalctl -u 4clinics-api --since "15 min ago" -p warning --no-pager` (sem `[AMBIENTE]` nem `[ERRO_INTERNO]`), `git describe` = tag, `status` do backup `ok`.
No navegador (Chrome, sessão do responsável, só leitura): uma tela de lista e a tela tocada pela mudança, **console sem erro e sem violação de CSP**.
Mais: o item específico da mudança.

## Se der errado
O script volta o **código** sozinho e explica o que fazer com o banco. Banco: nunca desfazer migration às cegas; ver `implantacao_5_rollback-backup`. Front: *Rollback* do deploy no Pages. Registrar o incidente (o que, quando, causa, correção) e **acrescentar um teste** que o pegaria.

## Registro de atualização
Acrescentar ao registro de implantação (`docs/registro-implantacao-*.md`) ou a um registro de versões: tag, data/hora, hash dos dois repositórios, classe da mudança, quem executou, resultado da verificação curta, caminho do backup anterior à atualização (`/var/backups/4clinics/antes-de-<tag>-*.sql.gz`).
