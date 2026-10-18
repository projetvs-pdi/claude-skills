---
name: implantacao-api-nginx-systemd
description: Coloca a API Node do 4clinics no ar na VPS — Node LTS, usuário de serviço, código clonado na TAG com chave de implantação somente leitura, /etc/4clinics/api.env com as variáveis de produção, unidade systemd e journald, nginx com certificado Origin CA do Cloudflare, backup e alerta — e também a ATUALIZAÇÃO da API por deploy/atualizar-api.sh. Use nas fases 3c e B4. O administrador executa por SSH; Claude orienta, confere as saídas e verifica de fora.
---

# API, nginx e systemd (fase 3c) — e atualização (B4)

Referências (repositório da API): `docs/servico-systemd.md`, `docs/checklist-implantacao.md` §4, `deploy/4clinics-api.service`, `deploy/journald-4clinics.conf`, `deploy/nginx-api.conf`, `deploy/atualizar-api.sh`, `docs/procedimento-backup.md`.
**Ordem com a 3b:** blocos 1 e 2 desta skill **antes** do bloco 3 da `implantacao_3b_mysql-banco-producao` (o banco é montado a partir do código clonado); depois, blocos 3 em diante.

## Bloco 1 — Node LTS
```bash
curl -fsSLo /tmp/nodesource_setup.sh https://deb.nodesource.com/setup_24.x
less /tmp/nodesource_setup.sh                 # ler antes de rodar (script baixado da internet)
sudo bash /tmp/nodesource_setup.sh && sudo apt -y install nodejs
node -v && npm -v
```
Esperado: `v24.x`. (Mesma versão do CI e do desenvolvimento; `engines` exige ≥ 22.)

## Bloco 2 — usuário de serviço e código na TAG
```bash
sudo useradd --system --home /opt/4clinics --shell /usr/sbin/nologin api4clinics
sudo install -d -m 750 -o root -g api4clinics /opt/4clinics /etc/4clinics
sudo ssh-keygen -t ed25519 -N "" -C "deploy-4clinics-api" -f /root/.ssh/deploy_4clinics_api
sudo cat /root/.ssh/deploy_4clinics_api.pub
```
O **responsável** cadastra essa chave pública no GitHub do `4clinics_backend` como **Deploy key somente leitura** (configuração de segurança; o Chrome só confere). Depois:
```bash
sudo tee -a /root/.ssh/config >/dev/null <<'CFG'
Host github-4clinics-api
  HostName github.com
  User git
  IdentityFile /root/.ssh/deploy_4clinics_api
  IdentitiesOnly yes
CFG
sudo git clone git@github-4clinics-api:gian-setta-gti/4clinics_backend.git /opt/4clinics/api
sudo git -C /opt/4clinics/api checkout --detach tags/<tag>
cd /opt/4clinics/api && sudo npm ci --omit=dev
sudo chown -R root:api4clinics /opt/4clinics/api && sudo chmod -R g=rX,o= /opt/4clinics/api
git -C /opt/4clinics/api describe --tags
```
Esperado: a tag publicada na fase 1. (Agora é a vez da `implantacao_3b`, blocos 3 a 6.)

## Bloco 3 — variáveis de produção
`sudo install -m 640 -o root -g api4clinics /dev/null /etc/4clinics/api.env` e editar (`sudoedit`). Gerar `JWT_SECRET` **na VPS**: `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`.
Obrigatórias (o servidor **recusa subir** sem elas): `AUTH_TENANT_REQUIRED=true`, `JWT_SECRET`, `COOKIE_SECURE=true`, `CORS_ORIGINS=https://app.<dominio>`. Recomendadas: `TRUST_PROXY=2`, `HOST=127.0.0.1`.
Também: `PORT=8010`, `DB_HOST=127.0.0.1`, `DB_PORT=3306`, `DB_DATABASE=4clinics`, `DB_USER=app4clinics`, `DB_PASSWORD=<senha-app>`, `JWT_EXPIRES_IN=8h`, `AUTH_SESSAO_MAX_HORAS=12`,
`EMPRESAS_OPERACIONAIS=001`, `EMPRESAS_TESTE=990`, `ALLOW_EMPRESA_TESTE=990`, `EMPRESA_TESTE_MODO=restrito` (a 990 fica em produção só para Administrador/Admin Clínico; sem o modo restrito o servidor recusa subir), `AGENDA_TIMEZONE=America/Sao_Paulo`. Tabela completa: `checklist-implantacao.md` §4. **Não** definir `EVENTOS_SEGURANCA`.
Claude confere a lista de **nomes** (`sudo cut -d= -f1 /etc/4clinics/api.env`), nunca os valores.

## Bloco 4 — serviço e logs
```bash
sudo cp /opt/4clinics/api/deploy/4clinics-api.service /etc/systemd/system/
sudo install -d /etc/systemd/journald.conf.d && sudo cp /opt/4clinics/api/deploy/journald-4clinics.conf /etc/systemd/journald.conf.d/4clinics.conf
sudo systemctl restart systemd-journald && sudo systemctl daemon-reload
sudo systemd-analyze verify /etc/systemd/system/4clinics-api.service
sudo systemctl enable --now 4clinics-api
systemctl status 4clinics-api --no-pager | head -5
journalctl -u 4clinics-api -n 20 --no-pager
curl -fsS http://127.0.0.1:8010/health
sudo systemd-analyze security 4clinics-api | tail -1
```
Esperado: `active (running)`, no log `Servidor iniciado na porta 8010 (somente 127.0.0.1)` e **nenhuma** linha `[AMBIENTE] - ...` (se houver, a variável está errada: corrigir e reiniciar), `/health` → `{"ok":true}`.

## Bloco 5 — nginx com o Origin CA
```bash
sudo apt -y install nginx
sudo install -d -m 700 /etc/ssl/cloudflare
sudo nano /etc/ssl/cloudflare/api.pem && sudo nano /etc/ssl/cloudflare/api.key   # colar certificado e chave Origin CA (o responsável os tem)
sudo chmod 600 /etc/ssl/cloudflare/api.key
sudo cp /opt/4clinics/api/deploy/nginx-api.conf /etc/nginx/conf.d/4clinics-api.conf
sudo sed -i 's/api.suaclinica.com.br/api.<dominio>/' /etc/nginx/conf.d/4clinics-api.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
curl -sk --resolve api.<dominio>:443:127.0.0.1 https://api.<dominio>/health
```
Esperado: `syntax is ok`, `{"ok":true}`. Agora o responsável cria o DNS `api` (nuvem laranja) — `implantacao_2`.

## Bloco 6 — backup, alerta e monitor
Backup automático (dump criptografado com `age` → R2, verificação diária, alerta por e-mail) e o encaminhamento do `[ALERTA_SEGURANCA]` para **projetvs.pdi@gmail.com**: instalar pela skill `implantacao_5_rollback-backup` §7 (scripts e unidades em `deploy/`, testados em 16/10/2026). O encaminhador de alertas roda com o usuário `backup4clinics` e usa o `msmtprc`: ligar **depois** dos passos 1 e 7 daquela seção.
```bash
sudo install -m 644 /opt/4clinics/api/deploy/4clinics-alerta-seguranca.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now 4clinics-alerta-seguranca
systemctl is-active 4clinics-alerta-seguranca    # esperado: active
```
Até o primeiro backup na VPS e o teste de restauração passarem, **não há dado real de paciente**. Monitor externo do `/health`: fase 4.

## Atualização (B4) — depois da implantação
```bash
sudo bash /opt/4clinics/api/deploy/atualizar-api.sh v<AAAA.MM.DD-N>
```
O script confere o estado, faz o **backup** (antes de qualquer migration), troca o código para a tag, `npm ci --omit=dev`, roda as migrations pendentes com o `migrador`, reinicia e confere o `/health`; se falhar, **volta o código** e explica o que fazer com o banco.
Precisa de `/etc/4clinics/migrador.env` (bloco 2 da 3b). Esperado no fim: `OK: <anterior> -> <tag>` e o caminho do backup. Depois: `implantacao_4_verificar-producao` (versão curta).

## Volta atrás
Código: `implantacao_5_rollback-backup` (ou o próprio `atualizar-api.sh` com a tag anterior). Serviço que não sobe: `journalctl -u 4clinics-api -n 80` — linha `[AMBIENTE]` = variável; `[ERRO_INTERNO] <código>` = erro com ocorrência.

## Ajustes do primeiro uso (17/10/2026)
- Sem login de root: usar `sudo`; `cd /opt/4clinics/api` falha para o administrador (pasta `750 root:api4clinics`) → `npm ci --omit=dev --prefix /opt/4clinics/api`. O npm 11 avisa de `install-scripts` (bcrypt, es5-ext): provar com `require('bcrypt')` a partir de `cd /opt/4clinics/api` como `api4clinics` (o `node -e` falha se o cwd não for legível pelo usuário).
- Confirmar o fingerprint do GitHub (`ssh-keygen -lf` do `ssh-keyscan -t ed25519 github.com`: `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`) antes de gravar o `known_hosts` do root.
- `api.env` gerado por script com `read -rs` (senha do `app4clinics` do cofre, sem eco) e `JWT_SECRET` gerado na VPS; `640 root:api4clinics`.
- Para ler o journal sem sudo: `usermod -aG systemd-journal admin4clinics`.
- Colar certificado/chave do Origin CA: `sudo tee /etc/ssl/cloudflare/api.pem >/dev/null` (colar, Enter, Ctrl+D), **um comando por vez** (colagens de várias linhas emendaram). Conferir que as chaves públicas (`x509 -pubkey` × `pkey -pubout`) têm o mesmo `sha256sum`.
- Depois do `rm sites-enabled/default` + `reload`, a porta 80 some em alguns segundos (worker antigo). O cabeçalho HSTS sai duplicado (nginx + API): pendência.
- DNS `api` (A, nuvem laranja → IP da VPS) só depois do nginx; verificado de fora: `/health` 200 pelo Cloudflare, `/api/pacientes` 401, IP direto na 443 recusado, 80/3306/8010 fechadas.

## Relato
Versões (Node, tag), saídas de `systemctl status`, `nginx -t`, `/health` local e pelo nginx, `systemd-analyze security` (nota), nomes das variáveis definidas, pendências (backup, alerta, monitor).
