---
name: seguranca-owasp
description: Aplica o OWASP Top 10:2025 ao desenho, à implementação e à revisão de uma funcionalidade ou de um projeto — controle de acesso e isolamento por empresa, configuração e cabeçalhos, dependências, criptografia e sessão, injeção (SQL, XSS, fórmula em planilha), projeto seguro, autenticação, integridade, log e alerta, e tratamento de erro sem vazar detalhe. Use ao criar ou alterar rota, tela, login, exportação, upload, integração ou configuração de ambiente, ao revisar um projeto existente contra o OWASP, ou ao montar a matriz de segurança. Chamada por modelar-dados-api, desenhar-interface e pelo gate de entregar-funcionalidade; complementa integridade-transacional.
---

# Segurança da informação (OWASP Top 10:2025)

## Passo 0 — confirmar a edição vigente (obrigatório, antes de qualquer desenho ou implementação)

Toda vez que esta skill for usada:

1. Consultar a página de origem com o **FireCrawl** (`firecrawl_scrape` em `https://owasp.org/Top10/`, que redireciona para `https://top10.owasp.org/<ano>/`; pedir `maxAge: 0` para não usar cópia antiga) e ler o ano da edição e a lista A01–A10.
2. Comparar com a edição registrada abaixo (**OWASP Top 10:2025**) e com a tabela da §1.
3. **Igual:** seguir, citando no relato "edição conferida em <data>".
4. **Diferente (edição nova, categoria renomeada, reordenada ou nova):** **parar e atualizar esta skill antes de implementar** — a edição de referência, a coluna "OWASP" e as regras S1–S10 da §1 (e a matriz do projeto, se existir). Avisar o usuário do que mudou. Só depois seguir com a funcionalidade.
5. **FireCrawl indisponível ou página fora do ar:** dizer ao usuário que a edição não pôde ser conferida, seguir com a edição registrada marcando "edição não conferida" no relato, e não afirmar que está atualizada.

Fonte da lista: apenas a página oficial da OWASP, nunca memória do modelo nem site de terceiros.

Referência fixa: **OWASP Top 10:2025** (https://top10.owasp.org/2025/). A numeração muda entre edições (em 2025 entraram *Software Supply Chain Failures* e *Mishandling of Exceptional Conditions*, e SSRF passou para A01): citar sempre a edição e rever esta skill quando sair outra. O Top 10 é conscientização; para checar item a item, usar o OWASP ASVS.

Dois modos de uso:
- **Desenho** (funcionalidade nova ou mudança): preencher a seção "Segurança" da ficha (§2) e escrever os testes da §4.
- **Adequação** (projeto existente): matriz → ações priorizadas → ondas (§6).

Segurança é requisito da entrega, não etapa final. Falha de segurança descoberta no gate volta para a etapa em que nasceu. Antes de propor, ler o que o projeto já tem (middlewares de acesso, cabeçalhos, tratador de erro, log de auditoria, testes de segurança) e **reaproveitar**.

## 1. Regras (S1–S10) — uma por categoria

| # | OWASP 2025 | Regra | Como |
|---|---|---|---|
| S1 | **A01 Controle de acesso** (inclui SSRF) | **Negar por padrão.** Toda rota passa por autenticação, escopo de empresa/filial e permissão da rotina; rota fora do catálogo de permissões é só do administrador. Empresa e filial vêm da **sessão**, nunca do corpo, da query ou da URL. Todo acesso a registro por id confere o dono (IDOR). | Uma peça comum de acesso em todas as rotas, e não uma checagem por controller. Sem permissão de leitura → 404 quando "existe, mas você não pode ver" já vaza. Chamada de servidor a URL: só destinos de uma lista fixa; nunca URL vinda da requisição. |
| S2 | **A02 Configuração incorreta** | Cabeçalhos de segurança em toda resposta (CSP restritiva, `X-Frame-Options`/`frame-ancestors`, `nosniff`, `Referrer-Policy`, `Permissions-Policy`, `Cache-Control: no-store` em dados pessoais, HSTS sob HTTPS), sem banner de tecnologia (`X-Powered-By`), CORS por lista de origens (nunca `*` com credenciais), sem rota de depuração, usuário padrão ou segredo no repositório. | `.env` fora do controle de versão; `.env.example` sem valor real. Variáveis que mudam o comportamento de segurança em produção (cookie seguro, proxy confiável, origens) entram num **checklist de implantação** (§5). **Referência:** em produção o servidor **recusa subir** com autenticação desligada, segredo de exemplo/curto, cookie sem HTTPS ou CORS sem https (guarda de ambiente testada); a API escuta só no loopback (`HOST=127.0.0.1`) atrás do proxy; o front no Cloudflare Pages recebe os cabeçalhos por `_headers` gerado da mesma fonte da CSP, e o build falha se a API não for https. |
| S3 | **A03 Cadeia de suprimentos** | Dependência é código de terceiros executando com os nossos dados. Lockfile versionado, auditoria automática (`npm audit` ou equivalente) e atualização periódica; ferramenta de desenvolvimento fora das dependências de produção. | CI roda auditoria e testes; versão nova de dependência é lida no changelog antes de subir. Pacote novo: conferir mantenedor, uso e necessidade. **Na primeira auditoria de um projeto:** procurar pacote que ninguém importa (já achamos `latest`, que arrastava o `npm` inteiro e todas as críticas), pacote de demonstração/comercial (ex.: `@mui/x-data-grid-generator` trazia o MUI X pro/premium, pagos), ferramenta de desenvolvimento em `dependencies`; **não mover para `devDependencies` o que roda na implantação** (ex.: `sequelize-cli` se a migração roda na VPS); medir desempenho antes e depois de atualizar versões; só aceitar vulnerabilidade com justificativa escrita. |
| S4 | **A04 Falhas criptográficas** | Dado em trânsito e em repouso protegido: **TLS 1.2 no mínimo** (aceitar 1.3), conexão aplicação ↔ banco com TLS, banco e backup criptografados. Senha com hash lento e salgado (bcrypt/argon2), nunca criptografia reversível. Segredo em cofre ou arquivo com permissão restrita, com rotação. | Sessão em cookie `httpOnly` + `SameSite` + `Secure`; nada de token em `localStorage`. Aleatório de segurança por gerador criptográfico, nunca `Math.random`. |
| S5 | **A05 Injeção** | **Nenhum valor da requisição entra no texto de um comando.** SQL só com parâmetros; busca textual escapa curingas. Saída para HTML só por escape do framework; sem `dangerouslySetInnerHTML`/`innerHTML`. Exportação para planilha/CSV **neutraliza célula que começa com `=`, `+`, `-`, `@`**. Nunca montar comando de sistema com entrada do usuário. | Teste estático que falha ao encontrar `literal(` com dado da requisição e `dangerouslySetInnerHTML`. Nome de arquivo e de aba vindos de dado são higienizados. |
| S6 | **A06 Projeto inseguro** | Pensar em abuso **no desenho**: quem pode fazer, quantas vezes, com que volume, e o que acontece se alguém tentar o fluxo fora da ordem. Regra de negócio vive no back. Limite de tamanho de corpo e de página em listagem; ação em massa tem teto. | A seção "Segurança" da ficha pergunta: *o que um usuário mal-intencionado, ou um usuário legítimo de outra empresa, faria aqui?* Dinheiro, saldo e recurso disputado seguem `integridade-transacional`. |
| S7 | **A07 Falhas de autenticação** | Limite de tentativas de login e de desbloqueio **persistente** (contador em memória zera no reinício e não vale com várias instâncias), mensagem igual para usuário inexistente e senha errada, política de senha mínima, expiração e encerramento de sessão, proteção CSRF (token + conferência de `Origin`) em toda gravação feita por navegador. | Falha de login e de desbloqueio entram no log de auditoria. Troca de senha encerra as outras sessões. Senha provisória exige troca no primeiro acesso. **Referência:** falhas pré-login em tabela própria sem chave estrangeira (a tentativa pode ser de usuário/empresa que não existe), limites por login **e** por IP, tentativa bloqueada não grava, `429` com `Retry-After`, login inexistente com a mesma resposta e o mesmo custo de senha (hash falso). **`TRUST_PROXY` correto é pré-requisito:** sem ele todos têm o IP do proxy e um atacante bloqueia a clínica inteira. |
| S8 | **A08 Integridade de software e dados** | Não confiar em dado sem verificar origem: upload valida tipo real, tamanho e nome, e não é executável nem servido no mesmo domínio da API; deserialização só de formato de dado (JSON); build e deploy reprodutíveis, a partir do lockfile. | Log de auditoria só de inclusão (teste que proíbe alterar/excluir). Dado imutável protegido também no banco (ver `integridade-transacional` T8). |
| S9 | **A09 Log e alerta** | Registrar quem, quando, o quê e sobre quem nas ações sensíveis (ler dado clínico, transferir, revogar, baixar dinheiro, mudar permissão) e **também as recusas** (login falho, 403, 429). **Não registrar conteúdo sensível** (texto clínico, senha, token, corpo da requisição). | Log global único em vez de uma tabela por funcionalidade. Alerta automático para rajada de falhas de login e de 403/429. O front registra erro com contexto e código, nunca com o corpo da requisição. **Referência:** eventos em `modulo=seguranca` do log global, visíveis só ao Administrador (Admin Clínico não vê); alerta por rajada com prefixo fixo `[ALERTA_SEGURANCA]`, sem repetir por 30 min; texto digitado limpo (sem quebra de linha nem colchetes) para ninguém forjar linha de log; falha ao gravar evento nunca derruba a requisição. |
| S10 | **A10 Tratamento de condições excepcionais** | **Falhar fechado e sem vazar.** Um tratador global de erro responde mensagem genérica + identificador da ocorrência e grava o detalhe só no log do servidor; **nunca devolver `e.message`** de erro interno (pode trazer SQL, caminho, nome de tabela). Erro de negócio tem código estável e mensagem com motivo e o que fazer. Rejeição de promessa e exceção não tratada não derrubam em silêncio. | Contexto de permissão ausente recusa em vez de liberar. Transação desfaz tudo no erro. Teste estático que proíbe `res.status(500).json({ message: e.message })` nos controllers. |

## 2. Seção "Segurança" da ficha

Acrescentar à ficha da funcionalidade:

```markdown
## 2b. Segurança  (seguranca-owasp, OWASP Top 10:2025)
- Dados sensíveis tocados (pessoais, clínicos, financeiros) e quem os vê (por perfil)
- Acesso (A01): rotina/permissão exigida; escopo empresa/filial; perfil recusado e resposta (403/404)
- Entrada (A05): campos livres, busca, arquivo, exportação — onde é validada/escapada
- Abuso (A06/A07): limite de tentativas/volume/lote; fluxo fora de ordem; CSRF
- Log (A09): ações auditadas, recusas auditadas, o que NÃO vai para o log
- Erros (A10): códigos de recusa; nada interno na resposta
- Dependência/integração nova (A03/A01-SSRF): qual e por quê
- Testes de segurança que esta funcionalidade ganha (§4)
```

Funcionalidade que não toca dado sensível, entrada livre nem permissão registra "sem impacto" com a justificativa de uma linha.

## 3. Dados pessoais e de saúde (LGPD)

Dado de saúde é dado pessoal sensível. Para toda funcionalidade que o toca:
- **Minimizar:** a resposta devolve só o campo de que a tela precisa, e por perfil (função `paraTela(registro, contexto)`).
- **Finalidade e base legal:** quem acessa e para quê fica na regra de negócio (etapa 1), não só no código.
- **Rastro de acesso:** ler prontuário e dado clínico gera registro de acesso consultável pelo titular da responsabilidade.
- **Sem sensível em URL, log, mensagem de erro ou e-mail.** Identificador na URL é id opaco, nunca CPF, nome ou diagnóstico.
- **Retenção e exclusão:** dizer o que é guardado, por quanto tempo e como é apagado ou anonimizado. Backup herda a mesma proteção.

## 4. Testes

**Por funcionalidade:**
- [ ] Cada perfil, inclusive o recusado: 403/404 com o código previsto e nenhum dado no corpo da recusa.
- [ ] **Isolamento entre empresas:** usuário da empresa A pedindo id da empresa B recebe 404 (leitura, alteração e exclusão).
- [ ] Sem sessão → 401; sessão expirada → 401; gravação sem token CSRF ou com `Origin` fora da lista → 403.
- [ ] Entrada hostil nos campos livres e na busca (`' OR 1=1 --`, `<script>`, `%`, `_`, `=cmd|…`): nada executa, nada vaza, a exportação sai neutralizada.
- [ ] Recusa e erro interno não trazem texto do banco, caminho nem pilha.
- [ ] Ação sensível gera registro de auditoria sem o conteúdo sensível.

**De contrato (estáticos, rodam sempre):**
- SQL sem concatenação de dado da requisição (varre os controllers).
- Nenhum `dangerouslySetInnerHTML`/`innerHTML`/`eval` no front.
- Nenhum controller devolve mensagem de erro interno.
- Toda rota registrada passa pela peça de autenticação, escopo e permissão (teste que percorre a tabela de rotas e falha para rota sem guarda).
- Cabeçalhos de segurança presentes e com o valor esperado.
- Nenhum token ou segredo lido do `localStorage`; nenhum segredo no repositório.
- Lista de **pendências que só diminui**, como no contrato de transação.

**Dados de teste:** credenciais e tokens de teste só em arquivo de semente/exemplo; marca identificável e limpeza no fim e no início.

## 5. Implantação e ambiente (checklist independente de provedor)

O que muda de um provedor para outro é *como* cumprir cada linha, não a linha:

| Item | Requisito |
|---|---|
| HTTPS | TLS 1.2 no mínimo, HSTS, certificado com renovação automática; HTTP redireciona |
| Proxy | `TRUST_PROXY` correto (senão o cookie seguro e o HSTS não funcionam atrás do proxy) |
| Banco | Sem IP público; porta liberada só para a aplicação; criptografia em repouso; TLS na conexão da aplicação; usuário da aplicação sem privilégio de administração |
| Segredos | Fora do repositório e da imagem; permissão restrita; rotação definida |
| Backup | Criptografado, em local separado, com **restauração testada** |
| Acesso administrativo | SSH por chave, restrito por origem ou bastião; sem senha |
| Limites | Limite de requisições na borda além do limite da aplicação; WAF quando houver exposição pública |
| Monitoramento | Alerta de falha de login, rajada de 403/429, erro 5xx, disco e backup |
| Ambientes | Produção separada de teste; dados reais nunca em ambiente de desenvolvimento |

Servidor de desenvolvimento não publica a porta do banco em todas as interfaces (`127.0.0.1:3306:3306`).

## 6. Adequação de projeto existente

1. **Matriz** (documento no projeto, ex.: `docs/matriz-owasp-top10-2025.md`): uma linha por categoria com o que existe, a lacuna e o status — ✅ coberto e testado · 🟡 parcial · ❌ lacuna · ❔ não verificado. Citar o arquivo ou teste que comprova cada ✅. **Não marcar ✅ sem evidência.**
2. **Levantamento somente de leitura:** rotas sem guarda, `e.message` em respostas, concatenação em SQL, `localStorage` com token, contadores de tentativa em memória, exportações sem neutralização, dependências sem auditoria, portas expostas.
3. **Ações priorizadas** por risco × esforço: vazamento de erro e injeção primeiro; depois dependências, autenticação persistente e log de recusa; por fim monitoramento.
4. **Ondas** com documento atualizado, testes novos + suítes completas, e relato honesto. Implementar só com autorização explícita por onda.
5. Revisar a matriz a cada fase de entrega e quando sair nova edição do Top 10.

## Relato

Separar sempre: o que o teste **provou**, o que é **preventivo**, e o que **não foi verificado** (ex.: `npm audit` não rodado, ambiente de produção não inspecionado, sem teste de invasão).
