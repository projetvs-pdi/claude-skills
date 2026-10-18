---
name: implantacao-verificar-producao
description: Verifica o 4clinics em produção de fora para dentro — cabeçalhos de segurança do front e da API, TLS 1.1 recusado, portas fechadas, 401 sem sessão, cookie seguro, login do administrador com troca de senha, bloqueio de login e alerta, eventos de segurança, queda e reinício do serviço, console do navegador sem violação de CSP e restauração do backup. Use na fase 4, após cada atualização (versão curta) e no pós-implantação (24 h e 7 dias). Só leitura, exceto os testes de bloqueio e de queda, que pedem o "sim" do responsável.
---

# Verificar a produção (fases 4 e 6; B6)

Referência: `D:\git\4clinics\4clinics_backend\docs\checklist-implantacao.md` §5.
Saída: um **relatório** com cada item `OK` / `FALHOU` / `NÃO VERIFICADO` + evidência (comando e saída, ou captura). Nada marcado como OK sem evidência.

## Versões
- **Completa** (fase 4 e primeira semana): todos os blocos.
- **Curta** (depois de cada atualização): blocos A, B (só `/health`, 401 e cabeçalhos), D (login real) e o item da mudança.

## A — de fora, sem login (Claude Code)
```bash
curl -sI https://api.<dominio>/health                   # 200; strict-transport-security; x-content-type-options: nosniff; cache-control: no-store; SEM x-powered-by
curl -s -o /dev/null -w "%{http_code}\n" https://api.<dominio>/api/pacientes      # 401
curl -sI https://app.<dominio>/ | grep -iE "content-security-policy|strict-transport|x-frame-options"
openssl s_client -connect api.<dominio>:443 -tls1_1 </dev/null 2>&1 | grep -iE "alert|handshake"   # recusado
openssl s_client -connect api.<dominio>:443 -tls1_2 </dev/null 2>&1 | grep -i "Protocol"            # TLSv1.2 ou 1.3
nc -zv -w 5 <IP-da-VPS> 3306 ; nc -zv -w 5 <IP-da-VPS> 8010 ; nc -zv -w 5 <IP-da-VPS> 80      # todos devem FALHAR
curl -m 5 -sk https://<IP-da-VPS>/ ; echo "exit=$?"     # não responde (443 só para o Cloudflare)
```

## B — na VPS (administrador cola as saídas)
```bash
systemctl is-active 4clinics-api && curl -fsS http://127.0.0.1:8010/health
sudo ss -tlnp | grep -E ":(3306|8010|443|22)\b"          # 3306 e 8010 só em 127.0.0.1
journalctl -u 4clinics-api --since "1 hour ago" -p warning --no-pager | tail -20
sudo -u api4clinics bash -c 'set -a; . /etc/4clinics/migrador.env; set +a; cd /opt/4clinics/api; NODE_ENV=production node scripts/verificar-banco-producao.js'
```
`verificar-banco-producao.js` (com o usuário **migrador**: o da aplicação não lê a `SequelizeMeta`, de propósito): 16 itens OK.

## C — navegador (Claude no Chrome; o responsável já está logado como administrador)
Em celular (~375 px) e desktop: login, agenda, pacientes, atendimento, relatórios (gerar **PDF** e **Excel**). Em cada tela: **console sem violação de CSP** e sem erro vermelho; arquivo baixado abre.
**Prompt para o Claude no Chrome:**
> Estou logado no 4clinics em https://app.<dominio>. Abra o console do navegador (DevTools). Navegue, sem gravar nada, por: Agenda, Pacientes (abra um cadastro existente), Atendimento (só abrir), Relatórios (gere um relatório em tela, depois PDF e Excel). Em cada tela, me diga se apareceu no console alguma mensagem de "Content Security Policy", erro de rede (4xx/5xx) ou erro vermelho, e tire uma captura. **Não clique em salvar, excluir, confirmar ou enviar.** No fim, liste o que falhou.

## D — sessão e login (com o "sim" do responsável)
- Login real do administrador: DevTools → Application → Cookies: `sessao4c` com **HttpOnly, Secure, SameSite=Strict**; nada de token no Local Storage.
- Primeiro acesso: troca de senha obrigatória funcionou.
- **Bloqueio de login** (login de teste inexistente, ex.: `teste.bloqueio`): 11 tentativas erradas → a 11ª mostra "aguarde N minuto(s)". Depois, o DBA apaga as linhas: `DELETE FROM xLOGIN_TENTATIVAS WHERE login = 'teste.bloqueio';`.
- **Alerta:** 15 falhas do mesmo IP em 10 min geram `[ALERTA_SEGURANCA] rajada_login_ip` em `journalctl -u 4clinics-api -g ALERTA_SEGURANCA` (rodar só se o responsável quiser testar; usa o IP de quem testa).
- **Eventos:** como Administrador, `GET /api/prontuario/log-acesso?modulo=seguranca` (pela tela de log, se houver) mostra `login_sucesso`, `login_falha`, `acesso_negado`.

## E — resiliência (com o "sim"; fora do horário de uso)
```bash
sudo kill -9 $(systemctl show -p MainPID --value 4clinics-api); sleep 7; systemctl is-active 4clinics-api   # active (reiniciou)
sudo systemctl restart 4clinics-api; journalctl -u 4clinics-api -n 5 --no-pager | grep ENCERRAMENTO       # encerramento suave
```

## F — backup (quando os scripts existirem)
Último backup no R2 com menos de 26 h; **restauração** do mais recente em banco de teste conferida (contagens por tabela, triggers). Até os scripts existirem: `NÃO VERIFICADO` e bloqueio de dado real.

## Pós-implantação (24 h e 7 dias)
`journalctl -u 4clinics-api --since "24 hours ago" -g "ERRO_INTERNO|ALERTA_SEGURANCA|AMBIENTE"`, uso de memória (`systemctl status` → `Memory:`) contra `MemoryMax=1500M`, disco (`df -h`), `npm audit --omit=dev` no repositório da API, tentativas de login (`SELECT tipo, COUNT(*) FROM xLOGIN_TENTATIVAS GROUP BY tipo`).

## Relato
Tabela com cada item, resultado e evidência; lista do que falhou com a ação sugerida; o que ficou `NÃO VERIFICADO` e por quê.
