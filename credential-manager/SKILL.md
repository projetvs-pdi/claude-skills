# Credential Manager

## Overview

Skill genérica para armazenamento e recuperação segura de credenciais, usando
DPAPI do Windows (`ConvertTo-SecureString` / `ConvertFrom-SecureString`) —
sem dependências externas, PowerShell 5.1 nativo.

**Ponto chave:** Esta é uma skill **reutilizável** — qualquer outra skill que
precise armazenar/carregar credenciais (login/senha) de forma segura pode
chamá-la, sem duplicar lógica de criptografia ou armazenamento.

### O que esta skill faz

1. **Salva** credenciais (usuário + senha) de forma criptografada no cofre local
2. **Carrega** credenciais salvas anteriormente
3. **Deleta** credenciais (logout)
4. **Verifica** se credenciais existem para um usuário/serviço
5. **Fluxo integrado** (`get-or-prompt`): tenta carregar; se não existir, pede
   ao usuário via `Read-Host -AsSecureString` e oferece salvar

### O que esta skill NÃO faz

- ✗ Não armazena senhas em texto plano em nenhum momento
- ✗ Não loga senhas em arquivos de log
- ✗ Não transmite credenciais pela rede (armazenamento é 100% local)
- ✗ Não gerencia sessões/tokens de aplicações — apenas usuário/senha

---

## Como Usar

```bash
powershell -ExecutionPolicy Bypass -File scripts/credential_manager.ps1 `
    -Action save -Username user@email.com -Password minhasenha -Service simples-agenda
```

```bash
powershell -ExecutionPolicy Bypass -File scripts/credential_manager.ps1 `
    -Action load -Username user@email.com -Service simples-agenda
```

Retorna a senha em stdout (para uso imediato pelo script chamador) ou
`exit 1` se não existir.

```bash
powershell -ExecutionPolicy Bypass -File scripts/credential_manager.ps1 `
    -Action delete -Username user@email.com -Service simples-agenda
```

```bash
powershell -ExecutionPolicy Bypass -File scripts/credential_manager.ps1 `
    -Action exists -Username user@email.com -Service simples-agenda
```

### Fluxo integrado (recomendado para skills que consomem)

```bash
powershell -ExecutionPolicy Bypass -File scripts/credential_manager.ps1 `
    -Action get-or-prompt -Username user@email.com -Service simples-agenda
```

Este comando:
1. Tenta carregar credenciais existentes
2. Se não existir, pede a senha interativamente (`Read-Host -AsSecureString`,
   sem eco no terminal)
3. Pergunta se deseja salvar para próximas vezes
4. Retorna `username:password`

### Chamada direta por outra skill (PowerShell)

Uma skill consumidora não precisa reimplementar CLI parsing — pode invocar o
script diretamente via splatting, como faz `baixar_agenda.ps1`:

```powershell
$CredManagerScript = Join-Path $PSScriptRoot '..\..\credential-manager\scripts\credential_manager.ps1'

function Invoke-CredManager {
    param([hashtable]$CredArgs)
    & $CredManagerScript @CredArgs
}

$jsonOut = Invoke-CredManager -CredArgs @{ Action = 'load'; Username = $Email; Service = 'minha-skill'; Json = $true }
$parsed = $jsonOut | ConvertFrom-Json
if ($parsed.found) { $senha = $parsed.password }
```

---

## Parâmetros

| Parâmetro | Tipo | Obrigatório | Descrição |
|-----------|------|-------------|-----------|
| `-Action` | string | ✅ | `save`, `load`, `delete`, `exists`, `get-or-prompt` |
| `-Username` | string | ✅ | Identificador do usuário (geralmente email) |
| `-Password` | string | Apenas para `save` | Senha a ser armazenada |
| `-Service` | string | ❌ (padrão: `simples-agenda`) | Nome do serviço/aplicação — permite múltiplos serviços armazenados separadamente, sem colisão |
| `-Json` | switch | ❌ | Retorna saída em formato JSON (para integração programática) |

---

## Segurança

✅ **Garantias:**
- Senha nunca é armazenada em texto plano em disco — usa DPAPI, vinculado a
  usuário+máquina (ninguém mais consegue descriptografar o blob)
- Comando `load` imprime a senha em stdout apenas quando explicitamente
  solicitado — cuidado ao usar em scripts com logging habilitado
- `get-or-prompt` usa `Read-Host -AsSecureString` para não ecoar a senha
  digitada no terminal

⚠️ **Cuidados do desenvolvedor:**
- Nunca capture o stdout do comando `load` em um log persistente
- Prefira chamada direta via splatting (hashtable) a montar uma string de
  linha de comando — evita passar senha como argumento visível em
  `Win32_Process` ou no histórico do PSReadLine

---

## Localização do Cofre

Por padrão, o cofre fica em `%LOCALAPPDATA%\credential-manager\`. Se a
variável de ambiente `CLAUDE_SKILLS_CRED_DIR` estiver definida, o cofre usa
esse caminho no lugar — necessário em máquinas com perfil roaming corporativo,
onde `%LOCALAPPDATA%` pode reverter arquivos sozinho (sync de perfil). Nesse
caso o script falha alto se o caminho de override não puder ser criado, em
vez de cair de volta silenciosamente no diretório instável.

O blob DPAPI é vinculado a usuário+máquina, nunca ao caminho do arquivo —
mover o cofre não invalida credenciais já salvas.

Nome do arquivo: `<service>__<username>.cred` (nomes sanitizados).

---

## Erros e Tratamento

| Cenário | Exit Code | Mensagem |
|---------|-----------|----------|
| Credenciais não encontradas (`load`) | 1 | "Credenciais não encontradas para {username}" |
| `-Password` ausente em `save` | 1 | "-Password é obrigatório para 'save'" |
| Falha ao salvar/deletar (permissão, disco) | 1 | "Falha ao salvar/deletar credenciais: {erro}" |
| Blob corrompido ou de outro usuário/máquina | — | `load` retorna `$null` (trata como "não encontrado") |

---

## Casos de Uso (Consumidores)

Esta skill é consumida por outras skills, cada uma com seu próprio `-Service`
para evitar colisão de credenciais entre aplicações diferentes:

- **`simples-agenda-download`** (`service = simples-agenda`): login do Simples Agenda
- **`import-db-agenda`**: senha do MySQL
- Futuras skills que precisem autenticar em outros sistemas (ERPs, portais, APIs)

---

## Triggering Phrases

Esta skill deve ativar quando:
- Outra skill precisa salvar ou carregar credenciais de forma segura
- Usuário pede para "salvar credenciais", "lembrar senha", "fazer logout"
