# Email Sender Skill (SMTP + TLS)

## Overview

Skill **genérica e reutilizável** de envio de email por SMTP com anexo. Não contém
regra de negócio de nenhuma skill específica — quem chama informa destinatários,
assunto, corpo e anexos.

Foi construída com **segurança da informação, privacidade de dados e proteção de
credenciais como critérios primários**, não como acréscimo. A seção
[Modelo de Segurança](#modelo-de-segurança) explica cada controle e o porquê.

**Entry point:** [scripts/send_email.ps1](scripts/send_email.ps1) (PowerShell 5.1+, sem dependências)

---

## Isolamento por Serviço (conceito central)

O parâmetro **`-Service` é obrigatório em toda invocação**. Ele define um
namespace próprio, e é o que permite que várias skills usem esta mesma skill sem
se contaminarem.

```
-Service simples-agenda          -Service relatorio-financeiro
        │                                 │
        ├── credencial SMTP própria       ├── credencial SMTP própria
        ├── allowlist própria             ├── allowlist própria
        ├── config própria                ├── config própria
        └── auditoria própria             └── auditoria própria
```

Um serviço **nunca** lê a credencial nem a allowlist de outro. Consequências
práticas:

- Autorizar `paciente@x.com` em `simples-agenda` **não** autoriza no `relatorio-financeiro`.
- Cada serviço pode usar uma conta remetente diferente.
- Revogar a credencial de um serviço (`-Action logout`) não afeta os demais.
- Comprometer um serviço não expande para os outros.

O nome do serviço é validado por `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$` — isso também
impede *path traversal* via nome de serviço.

### Onde cada coisa fica

| Item | Caminho |
|------|---------|
| Credencial (blob DPAPI) | `%LOCALAPPDATA%\credential-manager\email-sender.<service>__<remetente>.cred` |
| Allowlist | `%LOCALAPPDATA%\email-sender\allowlist\<service>.allowlist` |
| Config (remetente, host, porta) | `%LOCALAPPDATA%\email-sender\config\<service>.json` |
| Auditoria | `%LOCALAPPDATA%\email-sender\audit\<service>.log` |

---

## Modelo de Segurança

### 1. Allowlist obrigatória, *fail-closed*

Só recebe email quem foi **previamente autorizado naquele serviço**. Um endereço
fora da lista é bloqueado (exit 3) **antes de qualquer conexão SMTP** e antes de
tocar na credencial.

- **Allowlist ausente ou vazia = bloqueio total.** O padrão é negar, nunca permitir.
- **O bloqueio é total, não parcial.** Se a chamada tem 3 destinatários e 1 está
  fora da lista, *nenhum* email é enviado. Enviar só para os autorizados
  mascararia o erro do chamador e ainda entregaria os dados a um conjunto que ele
  não pediu.

**Por quê:** o anexo típico carrega dado pessoal. Um destinatário digitado errado
não é um incômodo — é um incidente de vazamento, e e-mail não tem "desfazer".
Esta é a única barreira que protege contra erro de digitação e contra uma skill
chamadora passar o destinatário errado por bug.

### 2. TLS obrigatório, sem opção de desligar

- `EnableSsl = $true` fixo no código. **Não existe parâmetro para desativar.**
- Força TLS 1.2 (e 1.3 quando disponível). O PowerShell 5.1 pode herdar
  SSL3/TLS 1.0 do processo — a skill sobrescreve isso a cada envio.
- Reseta `ServerCertificateValidationCallback = $null` antes de conectar. Se um
  script anterior na mesma sessão tiver instalado um callback permissivo
  (`{ $true }`), ele aceitaria certificado inválido; a skill restaura o padrão.
- Falha ao estabelecer TLS **aborta** (exit 7). Não há fallback para texto claro.

### 3. A senha nunca existe em texto plano no processo

Este é o ponto onde a skill se afasta de propósito da `credential-manager`:

| Operação | Como a `credential-manager` faz | Como esta skill faz |
|----------|--------------------------------|---------------------|
| Salvar | `-Password` em linha de comando | `Read-Host -AsSecureString` |
| Carregar | Devolve texto plano no stdout | Lê o blob direto para `SecureString` |

**Por que isso importa:**

- `credential_manager.ps1 -Action save -Password "senha"` coloca a senha na linha
  de comando, **visível para qualquer processo da máquina** via
  `Get-CimInstance Win32_Process`, e gravada no histórico do PSReadLine.
- `-Action load` devolve a senha em texto plano pelo stdout, materializando-a
  como string .NET imutável — que não pode ser zerada e fica no heap até o GC
  (podendo ir para dump de memória ou arquivo de paginação).

Aqui o caminho é: blob DPAPI → `ConvertTo-SecureString` → `NetworkCredential`.
O texto plano nunca é materializado. **Não existe parâmetro `-Password` nesta skill.**

> **Compatibilidade:** o formato e o diretório de armazenamento são os mesmos da
> `credential-manager` (`ConvertFrom-SecureString`, DPAPI vinculado a
> usuário+máquina). Só o caminho de manipulação em memória é mais restrito aqui.

> **Prefixo anti-colisão:** o nome do arquivo leva `email-sender.` antes do nome
> do serviço. Sem isso, uma skill que use `-Service simples-agenda` e cujo
> remetente SMTP seja o mesmo e-mail do login da aplicação geraria exatamente o
> mesmo caminho que a `credential-manager` usa para a senha de login — e uma
> senha sobrescreveria a outra silenciosamente. O prefixo torna essa colisão
> estruturalmente impossível para qualquer chamador.

### 4. Anti *header injection*

CR/LF é rejeitado em destinatários, remetente e assunto. Sem isso, um chamador
poderia injetar `\nBcc: atacante@dominio.com` no assunto e desviar cópia do anexo
silenciosamente — furando a allowlist.

Destinatários passam por validação de formato, limite de 254 caracteres e
rejeição de tabs e bytes nulos.

### 5. Corpo em texto puro

`IsBodyHtml = $false` fixo. Sem HTML significa sem conteúdo remoto, sem pixel de
rastreamento e sem superfície de injeção de markup no corpo.

### 6. Auditoria local

Cada tentativa — enviada, bloqueada ou falha — grava uma linha em
`audit\<service>.log`:

```
2026-09-05T14:48:10|BLOCKED_NOT_ALLOWED|from=|to=intruso@x.com|subject=teste|attachments=
2026-09-05T14:52:33|SENT|from=envio@x.com|to=ok@y.com|subject=Agenda|attachments=planilha.xlsx(11908B)
```

Registra **metadados apenas**: nunca o corpo do email, nunca a senha, nunca o
conteúdo do anexo — só nome e tamanho.

O log em si contém endereços de email, que são dado pessoal. Ele fica em
`%LOCALAPPDATA%` (escopo do usuário) e pode ser desativado por chamada com
`-NoAudit`. Ver [Privacidade](#privacidade-e-lgpd).

### 7. `-DryRun`

Valida tudo — allowlist, credencial, anexos, tamanhos — e reporta exatamente o
que **seria** enviado, sem abrir conexão. Use ao integrar uma skill nova.

---

## O que esta skill NÃO protege

Ser honesto sobre os limites importa mais do que uma lista de controles.

- **Não restringe o caminho do anexo.** Qualquer arquivo legível pelo usuário
  pode ser anexado. Restringir diretórios daria pouca segurança real: a skill
  chamadora roda como o mesmo usuário e poderia ler e enviar o arquivo por conta
  própria. A barreira efetiva contra exfiltração é a allowlist (o *destino*),
  não o *caminho de origem*.
- **Não protege contra a própria conta comprometida.** Quem tem a sessão do
  Windows do usuário consegue decifrar o blob DPAPI — é o modelo do DPAPI, por
  design vinculado a usuário+máquina.
- **Não criptografa o anexo.** O arquivo vai como está. TLS protege o *trânsito*,
  não o *repouso* na caixa do destinatário.
- **Não valida se o destinatário autorizado ainda é o correto.** A allowlist é
  estática; revisar periodicamente é responsabilidade de quem opera.

---

## Privacidade e LGPD

Esta skill transporta arquivos que frequentemente contêm **dado pessoal**. No caso
da `simples-agenda-download`, a planilha traz nome, telefone, email, serviço e
profissional de pacientes — o que sob a LGPD (Lei 13.709/2018, Art. 5º, II) é
**dado pessoal sensível**, por se referir à saúde.

Implicações práticas de quem usar esta skill:

1. **Minimização (Art. 6º, III):** envie a menor planilha que resolve. Período de
   um dia em vez de um mês, quando serve.
2. **Finalidade (Art. 6º, I):** a allowlist é o registro concreto de quem tem
   finalidade legítima para receber. Mantenha-a enxuta.
3. **Segurança (Art. 46):** TLS em trânsito e DPAPI para a credencial são
   atendidos pela skill. O repouso na caixa do destinatário **não** é — considere
   se o destino é adequado para dado de saúde.
4. **Retenção:** o log de auditoria acumula endereços indefinidamente. Estabeleça
   um prazo de expurgo, ou use `-NoAudit` se a trilha não for necessária.
5. **Anexos ficam em `Downloads`** depois do envio. Quem gera é quem deve limpar.

Esta seção é orientação de engenharia, não parecer jurídico.

---

## Setup (uma única vez por serviço)

```bash
powershell -ExecutionPolicy Bypass -File .claude/skills/email-sender/scripts/send_email.ps1 -Action setup -Service simples-agenda
```

O modo interativo pede, em ordem:

1. **Endereço remetente** — a conta Gmail que enviará.
2. **Senha de App do Google** — digitação oculta (`-AsSecureString`).
   - Requer verificação em duas etapas ativa na conta. Sem 2FA a página de
     senhas de app responde *"a configuração que você está procurando não está
     disponível para sua conta"*.
   - Gere em <https://myaccount.google.com/apppasswords>. Não confunda com
     **"Chaves de acesso"** (passkeys), que servem para login e não para SMTP.
   - É uma senha específica para esta finalidade: revogá-la não afeta a conta.
   - Pode colar **com ou sem os espaços** (`abcd efgh ijkl mnop`): o script
     remove os espaços, que são só formatação visual do site. O Gmail recusa a
     senha se eles forem enviados.
   - Nada aparece na tela enquanto você digita ou cola — é o esperado.
3. **Destinatários autorizados** — um por linha, vazio encerra.

Nada disso aparece em linha de comando, log ou histórico do shell.

### Gerenciar a allowlist depois

```bash
powershell -File send_email.ps1 -Action add-recipient -Service simples-agenda -Recipient novo@dominio.com
```

```bash
powershell -File send_email.ps1 -Action remove-recipient -Service simples-agenda -Recipient antigo@dominio.com
```

```bash
powershell -File send_email.ps1 -Action list-recipients -Service simples-agenda
```

```bash
powershell -File send_email.ps1 -Action status -Service simples-agenda
```

### Revogar a credencial

```bash
powershell -File send_email.ps1 -Action logout -Service simples-agenda
```

Remove só a credencial daquele serviço. Allowlist e auditoria são preservadas.

---

## Uso a partir de outra skill

### PowerShell

```powershell
$EmailSender = Join-Path $PSScriptRoot '..\..\email-sender\scripts\send_email.ps1'

& $EmailSender -Service 'simples-agenda' `
    -To $EnviarPara `
    -Subject "Agenda Ordenada: $DataIni a $DataFim" `
    -Body $corpo `
    -Attachment $planilha

switch ($LASTEXITCODE) {
    0 { Write-Output '[OK] Email enviado.' }
    3 { Write-Output '[AVISO] Destinatario nao autorizado. Planilha gerada mesmo assim.' }
    2 { Write-Output '[AVISO] email-sender nao configurado. Rode -Action setup.' }
    default { Write-Output "[AVISO] Falha no envio (exit $LASTEXITCODE). Planilha preservada." }
}
```

**Regra para skills chamadoras:** falha de envio **não deve** derrubar a skill
chamadora nem apagar o artefato já produzido. Avise e siga.

### Saída em JSON

Use `-Json` quando a skill chamadora precisar interpretar o resultado:

```json
{"code":"OK","message":"[OK] Email enviado para: dest@x.com","service":"simples-agenda","recipients":["dest@x.com"],"attachments":1}
```

```json
{"code":"RECIPIENT_BLOCKED","message":"[BLOQUEADO] ...","service":"simples-agenda","blocked":["intruso@y.com"]}
```

---

## Parâmetros

### Obrigatórios

| Parâmetro | Descrição |
|-----------|-----------|
| `-Service` | Namespace do serviço chamador. Define credencial e allowlist. |

### Para `-Action send` (padrão)

| Parâmetro | Descrição |
|-----------|-----------|
| `-To` | Destinatários. Array ou string separada por `,`/`;`. Todos devem estar na allowlist. |
| `-Subject` | Assunto. CR/LF rejeitado. |
| `-Body` | Corpo em texto puro. |
| `-BodyFile` | Alternativa a `-Body`: lê o corpo de um arquivo. |
| `-Attachment` | Caminho(s) de anexo. Aceita múltiplos. |

### Opcionais

| Parâmetro | Padrão | Descrição |
|-----------|--------|-----------|
| `-From` | da config | Sobrescreve o remetente configurado. |
| `-SmtpHost` | `smtp.gmail.com` | Servidor SMTP. |
| `-SmtpPort` | `587` | Porta (STARTTLS). |
| `-MaxTotalMB` | `20` | Teto da soma dos anexos. |
| `-DryRun` | — | Valida tudo, não envia. |
| `-NoAudit` | — | Não grava na trilha de auditoria. |
| `-Json` | — | Saída estruturada. |

**Não existe `-Password`.** Por design — ver [Modelo de Segurança §3](#3-a-senha-nunca-existe-em-texto-plano-no-processo).

---

## Exit Codes

| Código | Nome | Significado |
|--------|------|-------------|
| 0 | OK | Enviado (ou dry-run validado) |
| 1 | INVALID_INPUT | Destinatário/assunto inválido, header injection, campo faltando |
| 2 | CREDENTIAL_MISSING | Serviço sem setup, ou credencial removida |
| 3 | RECIPIENT_BLOCKED | Destinatário fora da allowlist, ou allowlist vazia |
| 4 | ATTACHMENT_ERROR | Anexo inexistente, vazio, ou acima do limite |
| 5 | SEND_FAILED | Falha SMTP genérica (rede, servidor) |
| 6 | AUTH_FAILED | Senha de app recusada/revogada |
| 7 | TLS_ERROR | Não foi possível exigir TLS 1.2+ |

---

## Error Scenarios

| Cenário | Ação da skill | Mensagem |
|---------|---------------|----------|
| Allowlist vazia | Bloqueia antes de conectar | "O servico X nao tem allowlist configurada. Nenhum email sera enviado (fail-closed por design)." |
| Destinatário fora da lista | Bloqueia **todos** os destinatários | "Destinatario(s) fora da allowlist... Nenhum email foi enviado." |
| CR/LF no assunto | Rejeita | "Assunto contem quebra de linha (tentativa de header injection)." |
| Senha de app revogada | Aborta com orientação | "Autenticacao SMTP recusada... Gere uma nova senha de app e rode -Action setup." |
| Anexo acima de 20 MB | Rejeita antes de conectar | "Anexos somam X MB, acima do limite de 20 MB." |
| Anexo com 0 bytes | Rejeita | "Anexo vazio (0 bytes)" — evita enviar arquivo truncado |
| Serviço sem setup | Orienta | "Servico X sem remetente configurado. Rode o setup uma unica vez." |

---

## Testes de Segurança Executados

Validados nesta máquina em 05/09/2026, sem envio real:

| # | Teste | Esperado | Resultado |
|---|-------|----------|-----------|
| 1 | `status` de serviço novo | Reporta não configurado | ✅ exit 0 |
| 2 | Envio sem allowlist | Bloqueio fail-closed | ✅ exit 3 |
| 3 | `\n` no assunto | Rejeita header injection | ✅ exit 1 |
| 4 | Destinatário malformado | Rejeita | ✅ exit 1 |
| 5 | `add-recipient` | Autoriza | ✅ exit 0 |
| 6 | Envio para autorizado | Passa allowlist, para na credencial | ✅ exit 2 |
| 7 | Envio para não autorizado | Bloqueia | ✅ exit 3 |
| 8 | Misto autorizado + não autorizado | Bloqueio **total** | ✅ exit 3 |
| 9 | Allowlist de outro serviço | Vazia (isolamento) | ✅ exit 0 |

O teste 6 é o mais informativo: ele prova que a allowlist é avaliada **antes** de
qualquer acesso à credencial ou à rede.

### Verificado contra servidor real

| Caminho | Resultado |
|---------|-----------|
| **Envio bem-sucedido (exit 0)** | ✅ **Verificado em 05/09/2026.** Planilha `.xlsx` de 11.908 bytes entregue a um destinatário da allowlist, via `smtp.gmail.com:587` com TLS. |
| `AUTH_FAILED` (exit 6) | ✅ Verificado. Gmail recusou o AUTH e a skill classificou corretamente, com orientação de correção. |
| Round-trip da credencial | ✅ Verificado. Blob DPAPI decifra, `SecureString` se forma e `NetworkCredential` preserva o comprimento — sem materializar texto plano. |

**Ainda não exercitado:** `TLS_ERROR` (exit 7).

### Armadilhas de setup encontradas na prática

Três defeitos reais apareceram só na primeira configuração ponta a ponta. Todos
os três produziam o **mesmo sintoma** — exit 6 — por causas diferentes, e os
dois primeiros já estão corrigidos no script.

**1. Senha de app colada com os espaços (a causa final)**

O Google exibe a senha como `abcd efgh ijkl mnop`. Colar assim é o
comportamento natural, mas o AUTH do Gmail **recusa a senha com espaços** — eles
são apenas formatação visual. O setup gravava os 19 caracteres literais e todo
envio falhava com exit 6.

Corrigido: `ConvertTo-CompactSecureString` remove os espaços antes de gravar
(e também na leitura, para credenciais salvas antes da correção). A remoção é
feita sobre o BSTR não gerenciado, zerado no `finally`, para não criar uma
`String` gerenciada — que não pode ser zerada e sobreviveria num dump de memória.

**2. Senha da conta em vez da senha de app**

O Google bloqueia senha de conta em SMTP desde 2022. Diagnóstico pelo
comprimento, sem expor o valor:

```powershell
$p = "$env:LOCALAPPDATA\credential-manager\email-sender.<service>__<remetente>.cred"
(ConvertTo-SecureString -String (Get-Content $p -Raw).Trim()).Length
```

Senha de app tem **exatamente 16 caracteres** depois de remover os espaços.
Qualquer outro valor não é senha de app. O setup agora rejeita na hora, em vez
de deixar o erro aparecer só no primeiro envio.

**3. Setup que dizia "concluído" sem gravar a credencial**

O teste era `if ($secure.Length -eq 0)`. Quando o terminal não entrega o teclado
ao script, `Read-Host -AsSecureString` devolve **`$null`**, e `$null.Length`
também é `$null` — que não é igual a `0`. A guarda não disparava, o
`ConvertFrom-SecureString` falhava, o `Set-Content` inteiro era pulado, e a
execução seguia para gravar a config e imprimir `[OK] Setup concluido`.

O serviço ficava **aparentemente configurado, mas com a credencial antiga** — o
pior modo de falha possível, porque não há sinal nenhum até o envio falhar.

Corrigido com `if ($null -eq $secure -or $secure.Length -eq 0)`, mais um
`try/catch` em volta da gravação que aborta com exit 2 em vez de seguir para a
config.

> **Lição de método:** o sintoma (`exit 6`) foi idêntico nos três casos, e os
> timestamps dos arquivos sugeriam causas que não eram a verdadeira. O que
> resolveu foi capturar a execução real com `Start-Transcript` e ler o log, em
> vez de inferir o que tinha acontecido pelo estado deixado em disco.

---

## Limitações

- ✗ Somente texto puro — sem HTML por design
- ✗ Sem criptografia do anexo (S/MIME, PGP, ZIP com senha)
- ✗ Sem retry automático — a skill chamadora decide se repete
- ✗ Sem agendamento ou fila — envio é síncrono
- ✗ Windows apenas (DPAPI). Em Linux/macOS seria preciso outro cofre
- ✗ Não gerencia a conta Google (2FA, senha de app) — isso é manual, por design

---

## Permissões Necessárias

- ✓ Rede: saída TCP para o servidor SMTP (padrão `smtp.gmail.com:587`, TLS)
- ✓ Leitura: caminhos de anexo informados pelo chamador
- ✓ Escrita: `%LOCALAPPDATA%\email-sender\` (allowlist, config, auditoria)
- ✓ Leitura/escrita: `%LOCALAPPDATA%\credential-manager\` (blob DPAPI)
- ✗ Nenhum acesso fora disso

---

## Triggering Phrases

- "enviar email"
- "mandar por email"
- "send email with attachment"
- "configurar envio de email"
- "autorizar destinatário"
- Quando outra skill precisa entregar um arquivo por email
