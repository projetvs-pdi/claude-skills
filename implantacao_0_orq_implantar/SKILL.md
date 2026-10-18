---
name: implantacao-orquestrar-implantacao
description: Conduz a implantação INICIAL do 4clinics em produção, de ponta a ponta e em fases com portão — publicar a main no GitHub, front no Cloudflare Pages, API e MySQL na VPS (Ubuntu, sem Docker), backup com restauração testada, verificação e entrada em produção. Use ao colocar o sistema no ar pela primeira vez ou ao repetir a implantação numa clínica nova. Coordena as skills implantacao_1 a implantacao_5. Para versões novas depois do primeiro dia use implantacao_0b_orq_atualizar.
---

# Implantar o 4clinics (orquestração da trilha A)

Fonte de verdade: `D:\git\4clinics\4clinics_backend\docs\plano-implantacao.md` (fases, portões, quem faz o quê). Documentos de apoio na mesma pasta `docs/`:
`checklist-implantacao.md`, `banco-producao.md`, `decisao-infraestrutura.md`, `servico-systemd.md`, `procedimento-backup.md`.
Repositórios: `D:\git\4clinics\4clinics_backend` (API) e `D:\git\4clinics\4clinics_app` (front).
Primeira execução real: 17/10/2026 (registro em `docs/registro-implantacao-2026-10-17.md`, modelo para as próximas).

## Regras do processo

1. **Discussão não é autorização.** Publicar (merge, tag, deploy, DNS, comando na VPS) só com o "sim" explícito do responsável, naquele momento. Aprovação de uma etapa não vale para a seguinte.
2. **Portão de fase.** A fase seguinte só começa com a anterior conferida (`docs/plano-implantacao.md` §5). Falhou? Para, registra, corrige, repete.
3. **Quem faz o quê** (`plano-implantacao.md` §1): o responsável contrata, aceita termos, faz login com 2FA, ajusta **configuração de segurança** e cria contas/tokens/senhas; o administrador da VPS roda os comandos por SSH e cola as saídas; Claude Code prepara, testa, confere e verifica **de fora**; o Claude no Chrome navega GitHub e Cloudflare já logados e **confere** o que o responsável ajustou. Ninguém digita senha, token ou pagamento por outra pessoa. Tela que mostra segredo uma vez (token do R2, Origin CA, senha de app) é **sempre do responsável**: se o Chrome a abrisse, o segredo passaria pelas capturas.
4. **Segredos nunca por chat.** Nascem e ficam na VPS ou no cofre do responsável (ver "Padrão de segredos").
5. **Cada passo termina com uma conferência que não depende da tela** (um `curl`, um `SELECT`, um código de saída). "Feito" **não é evidência**: pedir a saída colada; se não veio, repedir só o comando de conferência.
6. **Relato honesto:** o que foi conferido (de fora ou por saída colada), o que **não** foi verificado e o que ficou pendente. Nunca "pronto" sem a conferência.
7. **Registro de implantação** ao final (ver Fase 5).

## Modo de trabalho com o administrador (lições de 17/10/2026)

- **Todo bloco começa com o rótulo do terminal**, sempre um destes: **[VPS · admin4clinics]**, **[CMD do Windows]**, **[Git Bash]**, **[PowerShell]**, **[Painel: você]**. O maior atrito da 1ª implantação foi comando do Windows colado na VPS (`%USERPROFILE%`, `scp` rodado de dentro da VPS) e vice-versa. Se a saída colada mostrar o prompt errado (`admin4clinics@vps...` num passo do Windows), parar e reorientar antes de qualquer outra coisa.
- **Um bloco por mensagem**, curto, com o **esperado** logo abaixo. Comandos que esperam entrada (`tee` para colar certificado, `read -rs`, `scp` com *passphrase*) vão **sozinhos**, uma linha por vez: colagens de várias linhas emendaram e travaram.
- **Antes de comando destrutivo ou que corta acesso** (`rm`, `ufw enable`, `sshd reload`, `DROP`), conferir o estado primeiro e manter uma segunda sessão aberta.
- Na VPS, preferir `sudo bash -c '...'` a `cd` em pasta fechada (`/opt/4clinics` é 750) e `--prefix` no `npm`.
- O comando do Windows depende do terminal: CMD (`%USERPROFILE%\.ssh\...`, `type`, `certutil -hashfile`), PowerShell (`$env:USERPROFILE`; **não** usar `>` para arquivo binário) e Git Bash (`~/.ssh/...`). `scp` usa `-P` maiúsculo para a porta.

## Padrão de segredos

- **Gerar na VPS** e mostrar **uma vez** para o cofre: `openssl rand -base64 48 | tr -d '+/=\n' | cut -c1-40` (só letras e números: não quebra `.env` nem shell).
- **Receber do cofre sem eco**: script com `read -rsp "Cole ... " VAR </dev/tty` dentro de `bash <<'EOS' ... EOS`, gravando com `sudo install -m 600 -o <dono> /dev/null <arquivo>` + `printf ... | sudo tee`. Conferir só os **nomes** (`cut -d= -f1`) e um login de teste, nunca o valor.
- **Arquivo que precisa sair da VPS** (cópia do keyring): cópia temporária legível → `scp` do Windows → `sha256sum`/`certutil` iguais nos dois lados → `shred -u` do temporário. Nunca `ssh ... > arquivo` no CMD (trava no prompt da *passphrase*).
- Texto aberto de dump (teste de restauração) é apagado no mesmo dia, na VPS (`shred -u`) e no computador.

## Sequência

| Fase | Skill | O que sai |
|---|---|---|
| 0 | (esta skill) | reconhecimento, pré-requisitos e aceites fechados |
| 1 | `implantacao_1_publicar-main` | `main` = `develop` nos dois repositórios, CI verde, tag |
| 2 | `implantacao_2_frontend-cloudflare` | front em `app.<dominio>` com cabeçalhos de segurança e zona endurecida |
| 3a | `implantacao_3_vps-base-seguranca` | VPS endurecida, firewall, portas fechadas |
| 3b | `implantacao_3b_mysql-banco-producao` | MySQL nativo com TDE, banco montado e preparado, administrador criado |
| 3c | `implantacao_3c_api-nginx-systemd` (blocos 1–5) | API sob systemd atrás do nginx, DNS `api` |
| **3d** | `implantacao_5_rollback-backup` §7 + 3c bloco 6 | **backup automático no R2, restauração testada com a chave do cofre, alertas por e-mail** |
| 4 | `implantacao_4_verificar-producao` | relatório de verificação completo |
| 5 | (esta skill) | monitor externo, cadastros, entrada em produção, registro |
| 6 | `implantacao_4_verificar-producao` (24 h / 7 dias) | pós-implantação |
| — | `implantacao_5_rollback-backup` | volta atrás, backup e restauração |

**Ordem dentro da fase 3:** 3a → 3c blocos 1 e 2 (Node e código na tag) → 3b inteira (o banco é montado com o código clonado) → 3c blocos 3 a 5 → **3d (backup)**. O portão da fase 3 só fecha com a restauração testada (é a fase que mais revela defeito: na 1ª implantação, quatro ajustes saíram daqui).

## Fase 0 — pré-requisitos (conferir um a um com o responsável)

### 0.A Reconhecimento da VPS (antes de qualquer configuração)
1. **Console de emergência** do painel do provedor: abrir **e entrar com login** (não basta ver a tela). Sem isso, não se mexe em SSH nem firewall.
2. Bloco de leitura **[VPS]** e colar a saída:
   ```bash
   whoami; hostname; lsb_release -ds; uname -r; echo "SSH_CLIENT=$SSH_CLIENT"
   nproc; free -h | head -2; df -h / | tail -1
   sudo -n true 2>/dev/null && echo "sudo sem senha: sim" || echo "sudo sem senha: não"
   sudo ss -tlnp | head -20
   ```
   Daí saem: usuário de entrada (root? → criar administrador), **porta real do SSH** (a da HostGator era **22022**: firewall e fail2ban precisam dela), versão do Ubuntu, CPU/RAM (ajustam `MemoryMax` e `innodb_buffer_pool_size`).
3. Perguntar: o **IP do administrador é fixo ou dinâmico**? (dinâmico → `ufw limit <porta>/tcp` em vez de restringir por IP) e **qual sistema/terminal** ele usa no computador (define a forma dos comandos locais).

### 0.B Itens que exigem o aceite ou a conta do responsável (descobrir agora, não no meio)
| Item | Por quê | Pronto quando |
|---|---|---|
| Domínio na zona do Cloudflare | DNS, Pages, Origin CA | zona ativa |
| Plano do Cloudflare | Free limita WAF (só o conjunto gerenciado) e rate limit (período de 10 s, 1 regra) | decidido e anotado |
| **Assinatura do R2** (US$ 0 no uso previsto, mas aceita termos e usa a forma de pagamento) | destino do backup | assinatura ativa |
| Plano do GitHub | **privado gratuito não aplica proteção de branch** | decidido: GitHub Pro ou risco aceito com 2FA |
| 2FA no GitHub, Cloudflare e Gmail | contas que publicam em produção | conferido |
| **Senha de app do Gmail** (exige 2FA) | e-mail dos alertas | criada e no cofre |
| Conta do monitor externo (ex.: UptimeRobot) | queda total da VPS não alerta de dentro | conta criada |
| `gh` instalado na máquina do Claude Code? | sem ele, PRs e checks pelo Chrome | anotado |
| Cofre de senhas com anexos | keyring, chave `age`, Origin CA | disponível |
| DPA/SLA do provedor e termos do Cloudflare | LGPD | decidido (seguir sem = risco aceito e registrado) |

### 0.C Dados e código
Dados da clínica revisados (`npm run banco:exportar` no repositório da API, sem erro; atenção a filial com `\` e IE/IM "ISENTO"); nome, login e e-mail do primeiro administrador (`admin` é recusado); e-mail de alerta.
Do lado do Claude Code, **antes da fase 1**:
- **Ensaio do banco aprovado** (`npm run banco:ensaio` → `ENSAIO: APROVADO (6/6 passos)`). Desde 17/10/2026 o ensaio roda os passos do `migrador` com um **usuário temporário com as mesmas permissões da produção** (não o root) e aplica os valores do `deploy/mysql/4clinics.cnf` (`log_bin_trust_function_creators`): pega o erro de trigger com binlog e o `PROCESS` do verificador, que antes só apareceram na VPS. O que o ensaio **ainda não cobre** é instalação do servidor (TDE/keyring, `auth_socket` do root): isso fica na skill 3b.
- **Teste de "clínica vazia":** o banco recém-montado não tem paciente, profissional nem plano. Com zero registros, listas que devolviam `rows: {}` derrubavam a tela inteira (`/pacientes` em branco) — só apareceu em produção. Conferir: `tests/contratos/listasVazias.test.js` verde e, com o banco do ensaio vazio, abrir as telas de lista (pacientes, profissionais, especializações, planos) sem erro no console.
- **Scripts de `deploy/` executáveis** no Git: `git ls-files -s deploy/*.sh` → todos `100755` (o Git no Windows grava `100644`; as unidades systemd os executam direto). Corrigir com `git update-index --chmod=+x`.
- Suítes completas verdes (back `npx jest`, front `CI=true npx react-scripts test --watchAll=false`) e build do front (`REACT_APP_HOST_API=https://api.exemplo.com.br npm run build:pages`).

Se algum item faltar, **parar e listar o que falta** — não "adiantar" fases. Itens que só bloqueiam dado real (backup, monitor) podem seguir em paralelo às fases 1–3, mas fecham antes da fase 5.

## Fase 4 encontrou defeito no código?
Antes de existir dado real, o caminho é a **trilha B no meio da trilha A**: corrigir na `develop` com teste que pega o defeito (provar que falha sem a correção), PR, CI, merge, **tag nova nos dois repositórios** (`...-2`), `atualizar-api.sh` na VPS e repetir a verificação do item. Isso também testa o script de atualização antes do primeiro dia real. Registrar no relato e no registro.

## Fase 5 — entrada em produção
1. **Monitor externo** do `https://api.<dominio>/health` (ex.: UptimeRobot, 5 min, alerta no e-mail do projeto). Conferir: monitor **Up** (o *Bot Fight Mode* não bloqueou na 1ª implantação; se der 403, regra de exceção só para `/health`) e **"Test Notification" chegando ao e-mail**.
2. O administrador troca a senha provisória no primeiro acesso (conferido na fase 4) e cria os demais usuários **pela tela**.
3. **Cadastros iniciais, nesta ordem** (cada um depende do anterior): especializações → planos de saúde → tipos de consulta → tabelas de preço → profissionais (especialização, valores, planos) → usuários (recepção, profissionais) → disponibilidade semanal.
4. Com 1 ou 2 agendamentos reais: **relatórios em PDF e Excel** e a tela de atendimento (itens da fase 4 que só se testam com dado).
5. Comunicado e janela combinados com a clínica; primeiro uso acompanhado.
6. **Registro de implantação**: `docs/registro-implantacao-AAAA-MM-DD.md`, no formato do de 17/10/2026 — versão (tag e hash dos dois repositórios, tag anterior para rollback), ambiente, verificação (OK / não verificado), monitor, **desvios e riscos aceitos**, ajustes do primeiro uso, pendências. Commit na `develop`.

## Pendências conhecidas (atualizado em 17/10/2026)
- Resolvidos na `develop` (entram na próxima tag): `atualizar-api.sh` reaplica as permissões sozinho; ensaio com usuário e configuração de produção.
- Cabeçalho HSTS duplicado na API (nginx e API).
- Arquivos soltos versionados no back (`~$teiro...docx`, `Roteiro...docx`, `pendencias.txt`, `docker-compose.yml`).
