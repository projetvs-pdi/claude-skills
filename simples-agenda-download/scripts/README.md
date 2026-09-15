# Simples Agenda Download — Scripts

Script único, PowerShell 5.1, sem dependências externas.

## 📁 Estrutura

```
scripts/
├── baixar_agenda.ps1   ← Fluxo completo (download → sync BD → planilha ordenada → email)
└── README.md           ← Este arquivo
```

> **Selenium não é necessário.** A versão antiga usava Chrome porque fazia
> POST de login no endpoint errado. Ver [Fluxo](#-fluxo-de-funcionamento).

---

## Uso básico

**Opção 1: Com datas explícitas**
```powershell
powershell -ExecutionPolicy Bypass -File .\baixar_agenda.ps1 `
  -Email voce@email.com -DataIni 01/09/2026 -DataFim 05/09/2026
```

**Opção 2: Sem datas (usa últimos 7 dias)**
```powershell
powershell -ExecutionPolicy Bypass -File .\baixar_agenda.ps1 `
  -Email voce@email.com
# Equivalente a: -DataIni (hoje-7) -DataFim (hoje-1)
```

Se você omitir `-Senha`, o script pede a senha na tela sem exibi-la — e a
salva automaticamente (via skill `credential-manager`) para as próximas
execuções não pedirem de novo.

## Fluxo completo (o que o script faz, em ordem)

1. **Login** no Simples Agenda (`-Email` + senha do cofre ou prompt)
2. **Exporta e baixa** o `.xls` original do período (`-DataIni`/`-DataFim` +
   filtros opcionais)
3. **Sincroniza** os agendamentos na tabela `sbx990` (banco `4clinics`, MySQL), via
   skill `import-db-agenda` — pula com `-NoSyncToDb`
4. **Gera a planilha ordenada** (`.xlsx`) a partir do banco, na ordenação
   pedida em `-SortBy` — este é o entregável final, não o `.xls` original
   (que é apagado depois de sincronizado)
5. **Envia por email** a planilha ordenada, via skill `email-sender` — pula
   com `-NaoEnviarEmail`

Falha em qualquer passo depois do download preserva o arquivo já gerado até
ali e não derruba a skill (ver códigos de saída).

## Parâmetros

| Parâmetro | Obrigatório | Descrição |
|-----------|--------------|-----------|
| `-Email` | ✅ | Login do Simples Agenda |
| `-DataIni` | ❌ | dd/mm/yyyy (padrão: hoje - 7 dias) |
| `-DataFim` | ❌ | dd/mm/yyyy (padrão: hoje - 1 dia) |
| `-Senha` | ❌ | Só na 1ª vez; depois vem do cofre |
| `-CodUsuarioArray`, `-CodCliente`, `-CodProduto` | ❌ | Filtros do Simples Agenda (IDs) |
| `-DestDir` | ❌ | Pasta de destino (padrão: Downloads) |
| `-SortBy` | ❌ | `cliente+data` (padrão) / `servico+data` / `profissional+data` |
| `-NoSyncToDb` | ❌ | Pula a sincronização com o banco (ainda gera a planilha ordenada) |
| `-DbHost`, `-DbPort`, `-DbUser`, `-Database`, `-DbPassword` | ❌ | Conexão MySQL (padrões: `127.0.0.1`, `3306`, `root`, `4clinics`) |
| `-EmpresaId`, `-FilialId`, `-FilialOrigemId` | ❌ | Identificadores fixos de `sbx990` (padrões: `001`, `01`, `01`) |
| `-EnviarPara` | ❌ | Destinatário(s) do email, separados por vírgula (padrão: `amazonasterapiafisio@gmail.com`) |
| `-NaoEnviarEmail` | ❌ | Pula o envio de email |
| `-Logout` | ❌ | Remove a senha salva para `-Email` |

**Códigos de saída:**

| Código | Significado |
|--------|-------------|
| 0 | Sucesso |
| 1 | AUTH_FAILED (inclui CAPTCHA exigido) |
| 2 | NO_RESULTS — nenhum agendamento no período |
| 3 | CORRUPTED_FILE — magic bytes não conferem |
| 4 | INVALID_INPUT — data fora do formato / range invertido |
| 5 | CONNECTION_ERROR |
| 6 | RATE_LIMITED — HTTP 429, aguarde alguns minutos |
| 7 | Falha na sincronização/exportação do banco (skill `import-db-agenda`) |

Falha no envio de email (Passo 5) **não** usa um exit code próprio — vira
`[AVISO]` no output e a skill encerra com `exit 0`, porque a planilha (o
entregável) já foi gerada com sucesso.

---

## 🔄 Fluxo de autenticação (HTTP)

1. **`GET autenticacao_usuario.php`** — obtém o cookie `PHPSESSID` inicial.

2. **`POST crud_autenticacao.php`** — o login de verdade:
   ```
   acao=autentica_usuario
   login=<email>
   senha=<senha>
   conectado=1
   captcha_resposta=
   ```
   Resposta XML: `<houve_erro>N</houve_erro><endereco>agendamento.php</endereco>`.
   Os cookies `UsuarioSA` e `SenhaSA` só aparecem aqui.

   > ⚠️ **Não faça POST de login em `autenticacao_usuario.php`.** Aquele
   > endpoint responde HTTP 200, define apenas `PHPSESSID` e **não autentica** —
   > era esse o motivo do Selenium na versão antiga. O endpoint correto está
   > em `assets/pages/scripts/login.js` (`crudPadrao: "crud_autenticacao.php"`).

3. **`POST crud.php`** — gera o Excel:
   ```
   acao=exporta_agendamentos
   dataIni=01/09/2026
   dataFim=05/09/2026
   cod_usuario_array=   (opcional, IDs separados por vírgula)
   cod_cliente=         (opcional)
   cod_produto=         (opcional)
   ```
   Resposta: `<nome_excel>excel/excel71400/Agendamentos_DDMMYYYYHHMMSS.xls</nome_excel>`

   > `acao=filtraResumido` só renderiza a tabela na tela e **não** gera Excel.
   > Nunca adivinhe o nome do arquivo — leia sempre `<nome_excel>`.

4. **`GET <nome_excel>`** — baixa o binário e valida os magic bytes
   `D0CF11E0A1B11AE1` (OLE2). Arquivo fora do padrão é apagado.

---

## 🔒 Segurança

- O script **não** grava senha em disco nem em log — delega ao
  `credential-manager` (DPAPI) e ao `email-sender` (DPAPI, allowlist própria).
- Prefira deixar o PowerShell perguntar a senha (`Read-Host -AsSecureString`)
  a passá-la na linha de comando — o histórico do shell guarda argumentos.
- CAPTCHA **nunca** é resolvido automaticamente: o script aborta e pede
  login manual.

---

## 🐛 Troubleshooting

### "Usuário ou senha inválido"
Credenciais recusadas pelo servidor (`houve_erro != N`). Confirme no site.

### "Muitas requisições em sequência (HTTP 429)"
O Simples Agenda aplica rate limiting após várias chamadas seguidas —
observado ao repetir logins em poucos segundos. Aguarde alguns minutos.

### "O site está pedindo CAPTCHA"
O campo `captcha_resposta` normalmente fica oculto (`display:none`), mas o
servidor pode exigi-lo após erros de senha. Entre manualmente uma vez.

### "Nenhum agendamento encontrado"
`<nome_excel>` veio vazio: não há registros no período.

### Falha no passo de sincronização/exportação (exit 7)
Confirme que o serviço `MySQL80` está rodando (`Get-Service MySQL80`) e que
`import-db-agenda` está presente em `../import-db-agenda`.

### Email não chegou mas o exit foi 0
Veja o `[AVISO]` impresso — ele traz o comando exato para corrigir (setup do
`email-sender`, autorizar destinatário na allowlist, etc). A planilha sempre
fica preservada em Downloads independente do resultado do email.

---

## 📞 Referências

- [`../SKILL.md`](../SKILL.md) — documentação principal da skill
- [`../../import-db-agenda/manifest.json`](../../import-db-agenda/manifest.json) — sincronização e planilha ordenada
- [`../../email-sender/SKILL.md`](../../email-sender/SKILL.md) — envio de email
- [`../../credential-manager/SKILL.md`](../../credential-manager/SKILL.md) — armazenamento de senha
