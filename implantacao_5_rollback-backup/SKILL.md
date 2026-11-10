---
name: implantacao-rollback-backup
description: Volta o 4clinics de produção para a versão anterior (código do back por tag, deploy do front no Cloudflare Pages, banco por migration desfeita ou por restauração do backup em banco novo), instala o backup automático (dump criptografado com age para o Cloudflare R2, verificação diária e alerta por e-mail) e faz backup manual e o teste mensal de restauração. Use quando uma implantação ou atualização der errado, antes de mudança arriscada no banco, e no teste periódico de restauração. Decisões sobre o banco são sempre do responsável; nunca se restaura por cima do banco em uso.
---

# Volta atrás, backup e restauração

Referências: `D:\git\4clinics\4clinics_backend\docs\plano-implantacao.md` §5, `docs/procedimento-backup.md`, `docs/banco-producao.md` §7, `deploy/atualizar-api.sh`.

## 1. Decidir (antes de mexer)
| Sintoma | Caminho |
|---|---|
| Front quebrado, API boa | §2 (só o front) |
| API não sobe ou dá erro, **sem** migration na versão | §3 (código) |
| API com erro e **com** migration compatível | §3 (código); o banco fica — a versão anterior funciona com ele |
| Migration estragou dado ou é incompatível | §4 (banco) — **decisão do responsável**, com o backup feito antes da atualização |
| Dúvida | parar, coletar `journalctl -u 4clinics-api -n 120` e as saídas, e decidir com o responsável |

Registrar sempre: quando, o quê, por quê, quem decidiu.

**Apagar dado de produção (`DELETE`, `TRUNCATE`, `DROP`, tabela vazia exigida) é decisão do responsável, nunca dedução.** O que consta na `develop` (plano, documento, comentário de migration) não autoriza nada. Só com autorização explícita no chat, depois de medir a produção; o backup que protege o apagamento é o **completo no R2 conferido** (§5) mais a cópia local das tabelas, feitos **com a API parada e antes** do apagamento. Procedimento completo: **"REGRA INEGOCIÁVEL"** em `implantacao_0b_orq_atualizar_4clinics`.

## 2. Front (Cloudflare Pages)
Pages → Deployments → deploy anterior → **Rollback** (com o "sim"; o Claude no Chrome pode fazer o clique depois da autorização). Conferir: `curl -sI https://app.<dominio>/` e a versão na tela.

## 3. Código do back (VPS)
```bash
sudo bash /opt/4clinics/api/deploy/atualizar-api.sh v<TAG-ANTERIOR>
```
O script faz backup, troca o código, roda migrations pendentes (nenhuma, na tag anterior) e reinicia. Se o serviço estiver parado (o script recusa), fazer à mão:
```bash
cd /opt/4clinics/api && sudo git checkout --detach tags/v<TAG-ANTERIOR> && sudo npm ci --omit=dev && sudo systemctl restart 4clinics-api && curl -fsS http://127.0.0.1:8010/health
```

## 4. Banco
**Nunca** `db:migrate:undo:all`, nunca restaurar por cima do banco em uso, nunca apagar o backup pré-atualização.
- **Desfazer UMA migration** (reversível e sem perda): com o ambiente do migrador, `npx sequelize-cli db:migrate:undo --name <arquivo>.js`. Antes: ler o `down` da migration e confirmar que não apaga dado.
- **Restaurar o backup** (último recurso; perde o que foi gravado depois do backup):
  ```bash
  sudo mysql -e 'CREATE DATABASE `4clinics_restaurado` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci'
  gunzip -c /var/backups/4clinics/antes-de-<tag>-<data>.sql.gz | sudo mysql 4clinics_restaurado      # só para arquivo ANTIGO aberto (script até a v2026.11.15-1)
  sudo mysql 4clinics_restaurado -e "SELECT COUNT(*) FROM SA1990; SELECT COUNT(*) FROM SC0990; SELECT COUNT(*) FROM SequelizeMeta"
  ```
  **O backup novo é CIFRADO** (`antes-de-<tag>-<data>.sql.gz.age`): a chave privada NÃO está na VPS. Na máquina do responsável, **no Git Bash** (o PowerShell estraga dados binários em pipe), a restauração passa pelo túnel SSH sem gravar texto aberto em disco:
  ```bash
  ssh -p 22022 <admin>@<vps> 'sudo cat /var/backups/4clinics/antes-de-<tag>-<data>.sql.gz.age' | age -d -i chave-privada.txt | gunzip | ssh -p 22022 <admin>@<vps> 'sudo mysql 4clinics_restaurado'
  ```
  (o banco `4clinics_restaurado` já criado como acima; depois, as mesmas contagens.)
  Conferir as contagens com o responsável; dar ao `app4clinics` as permissões no banco novo (`docs/sql/protecao-logs-producao.sql` com `<nome_do_banco>` novo); trocar `DB_DATABASE` em `/etc/4clinics/api.env` e reiniciar.
  O banco antigo fica guardado (renomeado) até o responsável decidir.

## 5. Backup manual (antes de mudança arriscada)
```bash
sudo bash -c 'set -a; . /etc/4clinics/migrador.env; set +a; umask 077; MYSQL_PWD="$DB_PASSWORD" mysqldump --single-transaction --routines --triggers --events --set-gtid-purged=OFF --default-character-set=utf8mb4 -h 127.0.0.1 -u "$DB_USER" "$DB_DATABASE" | gzip -9 > /var/backups/4clinics/manual-$(date +%Y%m%d_%H%M).sql.gz'
gzip -t /var/backups/4clinics/manual-*.sql.gz && ls -lh /var/backups/4clinics/
```

**Restaurar a partir do R2** (VPS perdida ou backup local apagado): a chave privada **não** vai para a VPS. Na máquina do responsável, descriptografar e mandar pelo SSH direto para o MySQL (o texto puro só passa pelo túnel):
```bash
rclone copyto r2:4clinics-backup/daily/db_<data>.sql.gz.age ./db.age
age -d -i chave-privada.txt db.age | gunzip | ssh <vps> 'sudo mysql 4clinics_restaurado'
```
No servidor com criptografia em repouso, o `ENCRYPTION='Y'` do dump funciona (há keyring); num MySQL sem keyring, ver `restaurar-teste.sh`.

## 6. Testes de restauração (dois, que se completam; obrigatório antes de dado real)
**6.1 Mensal, manual** (usa a chave privada, por isso não roda na VPS). **Comando recomendado**, na pasta do repositório da API, com Docker rodando, `age` instalado e `~/.4clinics-rclone.conf` (remoto do R2, credenciais do cofre):
```bash
bash deploy/restaurar-teste-docker.sh --identidade chave-privada.txt
```
Sobe um MySQL descartável em Docker, baixa o backup mais recente, restaura, confere e registra no R2; apaga o contêiner no fim. Opções: `--arquivo`, `--sem-registrar`, `--remoto`, `--rclone-conf`, `--log`. **Manual, sem Docker:** na máquina do responsável (onde está a chave privada), com um MySQL 8 descartável **fora da VPS** (ex.: Docker) e o `rclone` configurado com leitura do bucket (e gravação em `restore-teste/`, para o `--registrar`):
```bash
MYSQL_CNF=~/.4clinics-restore.cnf bash deploy/restaurar-teste.sh --identidade chave-privada.txt --r2 r2:4clinics-backup --registrar r2:4clinics-backup --log restore-teste.log
```
Esperado: `APROVADO ... conferido por: manifesto` (tabelas, triggers e migrations **iguais** às do momento do backup). O script se recusa a usar banco sem "restore" no nome e apaga o banco de teste no fim. Guardar a linha do `restore-teste.log` no registro de implantação. `REPROVADO` = backup **não** confiável: tratar no mesmo dia. O `--registrar` grava o resultado no R2 (`restore-teste/ultimo-aprovado.txt`): **é o que a VPS lê** para parar de cobrar. Se avisar `AVISO: não consegui gravar o registro`, gravar a linha pela VPS (comando no próprio aviso). **Lembrete:** a VPS envia e-mail no dia 1 de cada mês (`4clinics-lembrete-restauracao.timer`) e, se o teste atrasar (> 35 dias) ou nunca tiver sido registrado, **todo dia às 08:00** (`verificar-backup.sh`), com o motivo e o comando pronto.

**6.2 Semanal, automático** (na VPS, sem a chave privada): `deploy/restaurar-teste-semanal.sh`, domingo 04:00 (`4clinics-restaurar-teste.timer`). Confere o sha256 do arquivo do R2 e restaura um dump novo num banco `4clinics_restore_teste`, comparando tabelas/triggers/migrations com o banco em uso; apaga o banco no fim. Resultado em `/var/backups/4clinics/status-restauracao`; falha = e-mail. Ver `docs/procedimento-backup.md` §7.2. Não prova a chave privada nem a recuperação sem a VPS: por isso o 6.1 é obrigatório.

## 7. Instalar o backup automático (uma vez, na implantação)
Referência completa: `docs/procedimento-backup.md` §9. O administrador executa; Claude confere as saídas. **Teste semanal e lembrete mensal** (06/11/2026): passos 10 a 12 abaixo, depois do backup instalado. **Verificado** com dump real + `age` real + restauração (16/10/2026, R2 simulado); **não verificado** em VPS real nem no R2 real.
1. **Pacotes e usuário:** `sudo apt -y install age rclone msmtp` e `sudo useradd -r -s /usr/sbin/nologin backup4clinics && sudo install -d -m 700 -o backup4clinics -g backup4clinics /var/backups/4clinics`.
2. **Chaves age** (na máquina do responsável, **não** na VPS): `age-keygen -o chave-privada.txt` → guardar no cofre; a linha `# public key: age1...` vai para a VPS.
3. **MySQL:** `backup_user` já criado na skill 3b. `/etc/4clinics/backup.cnf` (`sudo install -m 600 -o backup4clinics /dev/null ...`): `[client]`, `user=backup_user`, `password=<senha-backup>`, `host=localhost`.
4. **R2** (Cloudflare, o Claude no Chrome pode fazer com o "sim"): bucket `4clinics-backup`; token de API **só deste bucket** (Object Read & Write); regras de ciclo de vida: `daily/` 14 dias, `weekly/` 56 dias, `monthly/` 366 dias, `config/` 90 dias; **bloqueio de exclusão** (Bucket Lock) de 14 dias em `daily/`, se disponível na conta, para um invasor da VPS não apagar os backups; alerta de cobrança.
5. **rclone** como `backup4clinics`: `sudo -u backup4clinics rclone config` → remoto `r2`, tipo S3, provedor Cloudflare, chaves do token, endpoint `https://<conta>.r2.cloudflarestorage.com`. Testar: `sudo -u backup4clinics rclone lsf r2:4clinics-backup`.
6. **`/etc/4clinics/backup.env`** (0600, dono `backup4clinics`): `DB_DATABASE=4clinics`, `AGE_RECIPIENT=age1...`, `R2_REMOTE=r2:4clinics-backup`, `ALERTA_EMAIL=projetvs.pdi@gmail.com`.
7. **E-mail do alerta:** conta Gmail `projetvs.pdi@gmail.com` com verificação em duas etapas e **senha de app**; `/etc/4clinics/msmtprc` (0600, dono `backup4clinics`) com `host smtp.gmail.com`, `port 587`, `tls on`, `auth on`, `user`, `password <senha-de-app>`, `from`. Testar: `sudo -u backup4clinics /opt/4clinics/api/deploy/alerta-email.sh "teste" "alerta de teste"` → o e-mail chega.
8. **Unidades:** copiar `deploy/4clinics-backup.{service,timer}`, `deploy/4clinics-backup-verifica.{service,timer}` e `deploy/4clinics-alerta@.service` para `/etc/systemd/system/`; `sudo systemctl daemon-reload && sudo systemctl enable --now 4clinics-backup.timer 4clinics-backup-verifica.timer`.
9. **Primeira execução:** `sudo systemctl start 4clinics-backup && journalctl -u 4clinics-backup -n 30` → `backup db_... concluído`; `cat /var/backups/4clinics/status` → `ok|...`; `sudo systemctl start 4clinics-backup-verifica` → `ok: backup recente`. Depois, o teste de restauração (§6) **antes** de dado real.

10. **Usuário do teste semanal** (restrito ao banco de teste; gerar a senha na VPS com `openssl rand -base64 30`, guardar no cofre): `sudo mysql -e "CREATE USER 'restore_teste'@'localhost' IDENTIFIED BY '<senha>'; GRANT ALL PRIVILEGES ON \`4clinics_restore_teste\`.* TO 'restore_teste'@'localhost'"`. Arquivo `/etc/4clinics/restore.cnf` (`sudo install -m 600 -o backup4clinics -g backup4clinics /dev/null /etc/4clinics/restore.cnf`, editar): `[client]`, `user=restore_teste`, `password=<senha>`. Conferir: `sudo -u backup4clinics mysql --defaults-extra-file=/etc/4clinics/restore.cnf -e 'SHOW DATABASES'` → só `information_schema` e `performance_schema`.
11. **Unidades novas:** `setfacl -m u:backup4clinics:rx /opt/4clinics/api/deploy/{restaurar-teste-semanal,lembrete-restauracao}.sh`; copiar `deploy/4clinics-restaurar-teste.{service,timer}` e `deploy/4clinics-lembrete-restauracao.{service,timer}` para `/etc/systemd/system/`; `sudo systemctl daemon-reload && sudo systemctl enable --now 4clinics-restaurar-teste.timer 4clinics-lembrete-restauracao.timer`.
12. **Primeira execução e e-mail:** `sudo systemctl start 4clinics-restaurar-teste && journalctl -u 4clinics-restaurar-teste -n 20` → `APROVADO ...`; `cat /var/backups/4clinics/status-restauracao` → `ok|...`. Depois `sudo systemctl start 4clinics-lembrete-restauracao` → o e-mail **chega** (é o teste real do envio). Se o teste semanal falhar na primeira vez, colar a saída e parar. Até o primeiro teste manual com `--registrar` (§6.1), a verificação diária das 08:00 avisa por e-mail que ele está pendente (esperado).
13. **Alerta do serviço da API:** descomentar `OnFailure=4clinics-alerta@%n.service` em `4clinics-api.service` e recarregar.
14. **Relatório semanal por e-mail, mesmo com sucesso** (`docs/procedimento-backup.md` §6.1): `sudo setfacl -m u:backup4clinics:rx /opt/4clinics/api/deploy/relatorio-semanal.sh`; copiar `deploy/4clinics-relatorio-semanal.{service,timer}` para `/etc/systemd/system/`; `sudo systemctl daemon-reload && sudo systemctl enable --now 4clinics-relatorio-semanal.timer`; **rodar uma vez à mão**: `sudo -u backup4clinics bash /opt/4clinics/api/deploy/relatorio-semanal.sh` → o e-mail chega (segunda 08:10 em diante, automático) e cria o `relatorio-semanal.status` que a verificação diária cobra (sem ele, ela avisa "o relatório semanal nunca rodou"). Conferir quais itens vieram `n/d` (`apt-get -s`, zram, R2) e ajustar. Instalar o relatório junto da versão do `verificar-backup.sh` que o cobra.

## Ajustes do primeiro uso do backup (17/10/2026)
- `/etc/4clinics` é `750 root:api4clinics`: o usuário `backup4clinics` precisa de **ACL só de travessia** (`apt -y install acl`; `setfacl -m u:backup4clinics:x /etc/4clinics /opt/4clinics /opt/4clinics/api`; `setfacl -R -m u:backup4clinics:rX /opt/4clinics/api/deploy`), sem entrar no grupo da API (o `api.env` continua fechado para ele).
- Os `.sh` vinham `100644` na tag: `setfacl -m u:backup4clinics:rx deploy/{backup-banco,verificar-backup,alerta-email,encaminhar-alertas-seguranca}.sh` (corrigido no repositório para `755` na versão seguinte).
- **Defeito do `backup-banco.sh`** (corrigido no repositório, teste novo): sem nenhum `config_*.tar.gz.age` o `ls` do passo de limpeza devolvia 2 e o `pipefail` abortava o backup **depois** do envio ao R2. Contorno na VPS até a versão nova: `touch /var/backups/4clinics/config_00000000_0000.tar.gz.age`.
- `rclone` do Ubuntu 22.04 é o 1.53: usar `provider = Other` (S3), `region = auto`, `no_check_bucket = true`; configuração em `/etc/4clinics/rclone.conf` (600, `backup4clinics`) e `export RCLONE_CONFIG=... HOME=/var/backups/4clinics` no `backup.env` (o usuário não tem `/home`).
- Token R2: `Object Read & Write`, só o bucket, com **filtro de IP da VPS**; Access Key ID e Secret só no cofre; script com `read -rs`.
- `msmtp` (Ubuntu): responder "No" ao AppArmor **não descarrega** o perfil já carregado: `apparmor_parser -R /etc/apparmor.d/usr.bin.msmtp`. Senha de app do Gmail (2FA) via `read -rs`; testar o e-mail de ponta a ponta.
- Teste de restauração feito em 17/10/2026 com a chave `age` **do cofre**: R2 → `age -d` no Windows → banco `4clinics_restore_teste` na VPS; manifesto (50/20/87), 50 tabelas `ENCRYPTION=Y` e contagens das 50 tabelas iguais. Apagar o `.sql.gz` (texto aberto) depois.

## Rotação da chave `age` (se a privada vazar, ou por rotina)
Feita em 19/10/2026 depois de a chave privada aparecer na conversa (`@arquivo` abre e lê o conteúdo). **Ordem:**
1. No computador do responsável: `age-keygen -o <novo-arquivo>` → guardar a **privada** no cofre com **segunda cópia**; só a linha `Public key:` pode aparecer no chat. Esperar o "guardada" explícito **antes** do passo 2 (cifrar com uma chave que ninguém abre inutiliza os backups novos).
2. Na VPS: `cp -p backup.env` de segurança → `sed -i 's|^AGE_RECIPIENT=.*|AGE_RECIPIENT=<pública-nova>|' /etc/4clinics/backup.env` → conferir `grep -c` e que o arquivo continua `600 backup4clinics` → `systemctl start 4clinics-backup` (código 0, `status ok|`).
3. **Prova:** baixar o backup novo (R2 → VPS → `scp`), abrir com a chave **nova** (abre) e com a **antiga** (`no identity matched any of the recipients`). Apagar tudo o que ficou em texto aberto, no computador e na VPS.
4. **Não destruir a chave antiga na hora:** os backups antigos ainda dependem dela. Marcá-la no cofre ("destruir depois de <data>") para depois do ciclo de vida: o bloqueio de `daily/` (14 dias) impede apagar antes, e `weekly/` (56 dias) e `monthly/` (366 dias) podem guardar cópias; re-cifrar (abrir com a antiga, cifrar com a nova e subir com outro nome) só se houver dado real que não possa esperar.
Regra do chat: **nunca** `@arquivo` de chave, token ou `.env`; mostrar caminho, tamanho e `Public key:` apenas.

## Relato
Decisão tomada e por quem, comandos executados, saídas, versão final (tag e hash), estado do banco (qual, contagens), backups envolvidos, e o que ficou para depois.
