---
name: implantacao-mysql-banco-producao
description: Instala o MySQL 8 nativo na VPS (sem Docker) com lower_case_table_names=1 e utf8mb4_unicode_ci iguais ao desenvolvimento e criptografia em repouso (TDE com keyring), cria os usuários app4clinics, migrador e backup_user, e monta o banco de produção do 4clinics do zero (montar → preparar → administrador → verificar), com os dados reais da clínica, a empresa de teste 990 restrita e sem o admin do seed. Use na fase 3b da implantação. O administrador executa na VPS; Claude orienta e confere as saídas. Antes, o ensaio (npm run banco:ensaio) precisa estar APROVADO.
---

# MySQL e banco de produção (fase 3b)

Referências: `D:\git\4clinics\4clinics_backend\docs\banco-producao.md` (procedimento), `docs/criptografia-repouso.md` (TDE: decisão, prova e armadilhas), `docs/empresa-teste-producao.md`, `docs/checklist-implantacao.md` §3, `docs/sql/protecao-logs-producao.sql`. Arquivos de configuração do MySQL em `deploy/mysql/` (vêm com o código).
Na máquina de desenvolvimento, **antes**: `npm run banco:ensaio` → `ENSAIO: APROVADO (6/6 passos)` e `npm run banco:exportar` → `deploy/dados-clinica.json` sem erro (revisado pelo responsável).

## Bloco 1 — MySQL 8: `lower_case_table_names=1` e criptografia em repouso (só antes da 1ª inicialização)
No Ubuntu o padrão é `lower_case_table_names=0` e o MySQL 8 **não deixa mudar depois** (o código mistura caixa nos nomes de tabela). A criptografia em repouso (TDE) também entra aqui, antes de existir dado. O código da API precisa estar em `/opt/4clinics/api` (fase 3c, passo de código; pode-se clonar antes).
```bash
sudo apt -y install mysql-server
sudo systemctl stop mysql
sudo bash -c 'rm -rf /var/lib/mysql/*'                    # só agora, com o MySQL recém-instalado e sem dado nenhum
D=/opt/4clinics/api/deploy/mysql
sudo install -m 644 -o root -g root $D/4clinics.cnf                 /etc/mysql/mysql.conf.d/4clinics.cnf
sudo install -m 644 -o root -g root $D/mysqld.my                    /usr/sbin/mysqld.my
sudo install -m 644 -o root -g root $D/component_keyring_file.cnf   /usr/lib/mysql/plugin/component_keyring_file.cnf
sudo install -m 644 -o root -g root $D/apparmor-mysqld-local        /etc/apparmor.d/local/usr.sbin.mysqld
sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld
sudo install -d -m 750 -o mysql -g mysql /var/lib/mysql-keyring
sudo -u mysql mysqld --initialize-insecure                  # COMO usuário mysql: como root, a chave nasce com dono root e o MySQL não sobe
sudo ls -l /var/lib/mysql-keyring                          # esperado: component_keyring_file com dono mysql
sudo systemctl start mysql
sudo mysql -e "SELECT VERSION(), @@lower_case_table_names, @@character_set_server, @@collation_server, @@bind_address, @@default_table_encryption"
sudo mysql -e "SELECT STATUS_KEY, STATUS_VALUE FROM performance_schema.keyring_component_status WHERE STATUS_KEY='Component_status'"
```
Esperado: `8.0.x | 1 | utf8mb4 | utf8mb4_unicode_ci | 127.0.0.1 | 1` e `Component_status | Active`. Depois: `sudo mysql_secure_installation` (sem usuário anônimo, sem banco `test`, root só local).
**Cópia da chave do keyring para o cofre** (uma vez; de novo só se trocar a chave mestra), na máquina do responsável: `ssh <vps> 'sudo cat /var/lib/mysql-keyring/component_keyring_file' | age -r <chave-publica-do-cofre> > keyring-4clinics.age`. Nunca em texto puro fora da VPS.
**Se o MySQL não subir** (`journalctl -u mysql -n 50`): `Check keyring fail` → `sudo chown -R mysql:mysql /var/lib/mysql-keyring`; `apparmor="DENIED"` em `sudo dmesg | tail` → conferir o arquivo do AppArmor. Colar a saída e parar.
**Não verificado em VPS real** (verificado no MySQL 8.0.45 oficial em 16/10/2026: keyring ativo, 50/50 tabelas criptografadas; `docs/criptografia-repouso.md` §4).

## Bloco 2 — banco e usuários
Gerar as senhas **na VPS** (nunca no chat): `openssl rand -base64 30`. Guardar no cofre do responsável.
```sql
-- sudo mysql
CREATE DATABASE `4clinics` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'migrador'@'127.0.0.1' IDENTIFIED BY '<senha-migrador>';
GRANT ALL PRIVILEGES ON `4clinics`.* TO 'migrador'@'127.0.0.1';
CREATE USER 'app4clinics'@'127.0.0.1' IDENTIFIED BY '<senha-app>';
-- as permissões do app4clinics vêm no bloco 5 (depois que as tabelas existem)
-- backup: só leitura, usado por deploy/backup-banco.sh (skill implantacao_5_rollback-backup)
CREATE USER 'backup_user'@'localhost' IDENTIFIED BY '<senha-backup>';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, PROCESS ON *.* TO 'backup_user'@'localhost';
```
Arquivo `/etc/4clinics/migrador.env` (`sudo install -m 600 -o root -g root /dev/null ...` e editar): `DB_HOST=127.0.0.1`, `DB_PORT=3306`, `DB_DATABASE=4clinics`, `DB_USER=migrador`, `DB_PASSWORD=<senha-migrador>`.

## Bloco 3 — montar e preparar (na pasta da API já clonada na tag — fase 3c, passo de código; pode-se clonar antes)
```bash
cd /opt/4clinics/api
sudo -u api4clinics bash -c 'set -a; . /etc/4clinics/migrador.env; set +a; export NODE_ENV=production npm_config_cache=/tmp/npm-4clinics;
  npm run banco:montar && npm run banco:preparar -- --dados /root/dados-clinica.json'
```
(`dados-clinica.json` levado por `scp` do responsável para `/root/`, permissão 600.) Esperado: `[1/2] migrations (inclui os dados-base) ... ok`, `[2/2] ... ok`, `Banco montado.` e o resumo do preparo: empresas 001 e 990 (a 990 com os nomes padrão), admin do seed ausente, SX2 ≥ 30, `relacoesSxaAtivas` ≈ 76.
**Depois:** `sudo shred -u /root/dados-clinica.json`.

## Bloco 4 — primeiro administrador
```bash
sudo -u api4clinics bash -c 'set -a; . /etc/4clinics/migrador.env; set +a; export NODE_ENV=production npm_config_cache=/tmp/npm-4clinics; npm run banco:admin'
```
Responder login, nome completo e e-mail. A **senha provisória aparece uma vez**: entregar por canal seguro; **não colar no chat** (para a conferência basta o login).

## Bloco 5 — permissões do usuário da aplicação (logs só de inclusão)
Rodar `docs/sql/protecao-logs-producao.sql` com `sudo mysql`, trocando `<nome_do_banco>`=`4clinics`, `<usuario_app>`=`app4clinics`, `<host_app>`=`127.0.0.1`; executar os comandos que ele **gera** (revisar antes).
```sql
SHOW GRANTS FOR 'app4clinics'@'127.0.0.1';
```
Esperado: `SELECT, INSERT, UPDATE, DELETE` por tabela; nas de log (`xLOG_ACESSOS_MOVIMENTACOES`, `SC1990`) só `SELECT, INSERT`; `xLOGIN_TENTATIVAS` com `DELETE` (a poda precisa).

## Bloco 6 — conferência
```bash
sudo -u api4clinics bash -c 'set -a; . /etc/4clinics/migrador.env; set +a; export NODE_ENV=production npm_config_cache=/tmp/npm-4clinics; npm run banco:verificar -- --tde'
```
Esperado: todos os itens OK (inclui os 3 de criptografia em repouso) e `RESULTADO: tudo certo.` (a conferência com `--api` fica para a fase 4, com a API no ar).

## Volta atrás
Antes de dado real, o banco é descartável: `DROP DATABASE \`4clinics\`;` e recomeçar do bloco 2. **Nunca** rodar `banco:montar`/`banco:preparar` num banco em uso (os scripts recusam).

## Ajustes do primeiro uso (17/10/2026, MySQL 8.0.46 do Ubuntu 22.04)
- **`mysqld --initialize-insecure` deixa o `root@localhost` SEM senha** e o `auth_socket` não vem carregado: antes de tudo, `INSTALL PLUGIN auth_socket SONAME 'auth_socket.so'` e `ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket` (senão o usuário de serviço entra como root do MySQL pelo socket). Conferir com `sudo -u api4clinics mysql -u root -e "SELECT 1"` → `Access denied`.
- **Migration FIN1 falha** com o binlog ligado (`You do not have the SUPER privilege and binary logging is enabled`): `log_bin_trust_function_creators = 1` entra no `4clinics.cnf` (já no repositório, `deploy/mysql/4clinics.cnf`); em banco já criado, `SET GLOBAL` + apagar o banco incompleto e refazer o bloco 2/3.
- **Bloco 3/4/6 rodam como root** (`sudo bash -c 'cd /opt/4clinics/api && set -a && . /etc/4clinics/migrador.env ...'`), não como `api4clinics`: o `migrador.env` é `root:root 600` (o usuário de serviço não pode ler a senha do migrador), como o `atualizar-api.sh`.
- **O `migrador` precisa de duas permissões a mais** para o `banco:verificar --tde`: `GRANT PROCESS ON *.* ...` e `GRANT SELECT ON performance_schema.keyring_component_status ...` (sem elas, falso "sem keyring").
- Senhas geradas só com letras e números (`openssl rand -base64 48 | tr -d '+/=\n' | cut -c1-40`) para não quebrar `.env`/shell; aparecem uma vez no terminal para o cofre.
- Tabelas ficam em minúsculas (`lower_case_table_names=1`): `grep` de nomes de tabela com `-i`.
- Cópia da chave do keyring para o cofre feita por `scp` de uma cópia temporária (o `ssh ... > arquivo` no CMD do Windows travou no prompt da passphrase); conferir SHA256 nos dois lados e apagar o temporário com `shred`.

## Relato
Saídas de cada bloco (sem senhas), versão e configuração do MySQL, resumo do preparo, login do administrador criado (sem a senha), resultado do `banco:verificar`, confirmação de que o `dados-clinica.json` foi apagado.
