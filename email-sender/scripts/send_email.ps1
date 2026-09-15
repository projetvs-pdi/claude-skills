<#
.SYNOPSIS
    email-sender - envio de email por SMTP+TLS com anexo, reutilizavel por qualquer skill.

.DESCRIPTION
    Skill generica de envio de email, projetada com seguranca da informacao e
    privacidade como criterios primarios. Nao contem regra de negocio de nenhuma
    skill especifica: quem chama informa destinatarios, assunto, corpo e anexos.

    ISOLAMENTO POR SERVICO
      -Service e obrigatorio e define um namespace proprio. Cada skill chamadora
      usa o seu. Um servico nunca le a credencial nem a allowlist de outro:
        credencial : %LOCALAPPDATA%\credential-manager\<service>__<from>.cred
        allowlist  : %LOCALAPPDATA%\email-sender\allowlist\<service>.allowlist
        config     : %LOCALAPPDATA%\email-sender\config\<service>.json
        auditoria  : %LOCALAPPDATA%\email-sender\audit\<service>.log

    CONTROLES DE SEGURANCA (ver SKILL.md para o racional de cada um)
      1. Allowlist obrigatoria por servico. Destinatario fora da lista = bloqueio
         (exit 3), sem conexao SMTP. Fail-closed: allowlist ausente/vazia bloqueia.
      2. TLS obrigatorio (TLS 1.2+), sem opcao de desligar. Validacao de
         certificado nunca e desabilitada.
      3. A senha nunca existe em texto plano neste processo: o blob DPAPI e lido
         direto para SecureString e entregue a SmtpClient via NetworkCredential.
      4. Nenhum parametro -Password. A senha so entra por Read-Host -AsSecureString
         no -Action setup, para nao aparecer em linha de comando (Win32_Process)
         nem no historico do PSReadLine.
      5. Anti header-injection: CR/LF e rejeitado em destinatarios, remetente e
         assunto.
      6. Auditoria local do que foi enviado (nunca do corpo, nunca da senha).

.PARAMETER Action
    send | setup | add-recipient | remove-recipient | list-recipients | status | logout

.PARAMETER Service
    Namespace do servico chamador (obrigatorio). Ex.: 'simples-agenda'.

.EXAMPLE
    # 1a vez: configura remetente, senha de app e allowlist (interativo)
    .\send_email.ps1 -Action setup -Service simples-agenda

.EXAMPLE
    # uso normal por outra skill
    .\send_email.ps1 -Service simples-agenda -To dest@exemplo.com `
        -Subject "Agenda Ordenada" -Body "segue anexo" -Attachment "C:\...\planilha.xlsx"

.EXAMPLE
    # valida tudo sem enviar
    .\send_email.ps1 -Service simples-agenda -To dest@exemplo.com -Subject x -Body y -DryRun

.NOTES
    Exit codes: 0 OK | 1 INVALID_INPUT | 2 CREDENTIAL_MISSING |
                3 RECIPIENT_BLOCKED | 4 ATTACHMENT_ERROR | 5 SEND_FAILED |
                6 AUTH_FAILED | 7 TLS_ERROR
#>
[CmdletBinding()]
param(
    [ValidateSet('send', 'setup', 'add-recipient', 'remove-recipient', 'list-recipients', 'status', 'logout')]
    [string]$Action = 'send',

    # Namespace do servico. O padrao de nome tambem impede path traversal.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$')]
    [string]$Service,

    [string[]]$To,
    [string]$Subject,
    [string]$Body,
    [string]$BodyFile,
    [string[]]$Attachment,
    [string]$Recipient,
    [string]$From,
    [string]$SmtpHost,
    [int]$SmtpPort = 0,
    [int]$MaxTotalMB = 20,
    [switch]$DryRun,
    [switch]$NoAudit,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# =====================================================================
# Camada de armazenamento (por servico)
# =====================================================================

# Allowlist, config e auditoria seguem a credencial para fora do perfil quando
# CLAUDE_SKILLS_CRED_DIR esta definida. Deixar so a credencial protegida nao
# bastaria: em maquina com perfil roaming, uma allowlist revertida bloqueia
# envios legitimos (exit 3) e um config revertido faz o servico parecer nao
# configurado (exit 2) - mesma classe de bug, arquivo diferente.
$AppDir = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_SKILLS_CRED_DIR)) {
    Join-Path $env:CLAUDE_SKILLS_CRED_DIR 'email-sender'
} else {
    Join-Path $env:LOCALAPPDATA 'email-sender'
}

function New-DirIfMissing {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return $Path
}

function Get-AllowlistPath {
    $dir = New-DirIfMissing (Join-Path $AppDir 'allowlist')
    return Join-Path $dir "$Service.allowlist"
}

function Get-ConfigPath {
    $dir = New-DirIfMissing (Join-Path $AppDir 'config')
    return Join-Path $dir "$Service.json"
}

function Get-AuditPath {
    $dir = New-DirIfMissing (Join-Path $AppDir 'audit')
    return Join-Path $dir "$Service.log"
}

# Mesmo contrato de armazenamento da skill credential-manager: blob DPAPI
# produzido por ConvertFrom-SecureString, vinculado a usuario+maquina.
# Lemos o arquivo direto (em vez de invocar credential_manager.ps1) porque
# aquele script devolve a senha em texto plano no stdout, e o 'save' dele exige
# -Password em linha de comando. Aqui a senha nunca sai de um SecureString.
function Get-CredentialStoreDir {
    # Por padrao o cofre fica em %LOCALAPPDATA%, mas em maquina com perfil
    # roaming corporativo (ou pasta sincronizada) esse diretorio nao e estavel:
    # observamos nesta maquina o arquivo de credencial voltar sozinho a uma
    # versao anterior COM o timestamp antigo preservado - assinatura de
    # restauracao por agente de perfil/sync, nao de escrita normal. O efeito e
    # um setup que aparenta ter funcionado e minutos depois volta a falhar.
    #
    # CLAUDE_SKILLS_CRED_DIR permite apontar o cofre para um caminho fora do
    # perfil (outro volume, por exemplo). O blob DPAPI continua valido: ele e
    # vinculado a usuario+maquina, nunca ao caminho do arquivo.
    $override = $env:CLAUDE_SKILLS_CRED_DIR
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        # Falhar alto: cair silenciosamente de volta no diretorio instavel
        # reintroduziria exatamente o bug que este override existe para evitar.
        if (-not (Test-Path $override)) {
            try { New-Item -ItemType Directory -Path $override -Force -ErrorAction Stop | Out-Null }
            catch {
                throw "CLAUDE_SKILLS_CRED_DIR aponta para '$override', que nao pode ser criado: $($_.Exception.Message)"
            }
        }
        return $override
    }
    return (New-DirIfMissing (Join-Path $env:LOCALAPPDATA 'credential-manager'))
}

function Get-CredentialPath {
    param([string]$User)
    $dir = Get-CredentialStoreDir
    # O prefixo 'email-sender.' evita colisao com credenciais que a propria
    # credential-manager guarda para o MESMO nome de servico. Sem ele, uma skill
    # que use -Service 'simples-agenda' e cujo remetente SMTP seja o mesmo email
    # do login da aplicacao geraria exatamente o mesmo caminho de arquivo, e a
    # senha de app sobrescreveria a senha de login (ou vice-versa).
    $safeService = ("email-sender.$Service" -replace '[^a-zA-Z0-9_.-]', '_')
    $safeUser = ($User -replace '[^a-zA-Z0-9_.@-]', '_')
    return Join-Path $dir "$safeService`__$safeUser.cred"
}

function ConvertTo-CompactSecureString {
    # O Google exibe a senha de app como "abcd efgh ijkl mnop", e colar com os
    # espacos e o comportamento natural - mas o AUTH do Gmail recusa a senha
    # assim. Os espacos sao so formatacao visual do site.
    #
    # A remocao acontece sem criar uma String gerenciada (que nao pode ser zerada
    # e sobreviveria num dump de memoria ou na paginacao): o texto plano existe
    # apenas no BSTR nao gerenciado, lido caractere a caractere e zerado no
    # finally.
    param([System.Security.SecureString]$Secure)

    $out = New-Object System.Security.SecureString
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        for ($i = 0; $i -lt $Secure.Length; $i++) {
            $c = [char][System.Runtime.InteropServices.Marshal]::ReadInt16($bstr, $i * 2)
            if (-not [char]::IsWhiteSpace($c)) { $out.AppendChar($c) }
        }
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
    $out.MakeReadOnly()
    return $out
}

# =====================================================================
# Validacao de entrada
# =====================================================================

function Test-NoHeaderInjection {
    # CR/LF em qualquer campo que vira cabecalho SMTP permite ao chamador
    # forjar cabecalhos (Bcc, Content-Type). Rejeitamos antes de montar a msg.
    param([string]$Value)
    if ($null -eq $Value) { return $true }
    return ($Value -notmatch '[\r\n]')
}

function Test-EmailAddress {
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    if (-not (Test-NoHeaderInjection $Address)) { return $false }
    if ($Address -match '[\t\0]') { return $false }
    if ($Address.Length -gt 254) { return $false }
    return ($Address -match '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$')
}

function ConvertTo-RecipientList {
    # Aceita tanto -To a@x.com,b@y.com quanto -To "a@x.com,b@y.com"
    param([string[]]$Raw)
    $out = @()
    foreach ($item in $Raw) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        foreach ($piece in ($item -split '[;,]')) {
            $t = $piece.Trim()
            if (-not [string]::IsNullOrWhiteSpace($t)) { $out += $t }
        }
    }
    return $out
}

# =====================================================================
# Allowlist (fail-closed)
# =====================================================================

function Get-Allowlist {
    $path = Get-AllowlistPath
    if (-not (Test-Path $path)) { return @() }
    $entries = @()
    foreach ($line in (Get-Content -Path $path -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($t.StartsWith('#')) { continue }
        $entries += $t.ToLowerInvariant()
    }
    return $entries
}

function Add-AllowlistEntry {
    param([string]$Address)
    $path = Get-AllowlistPath
    $current = Get-Allowlist
    $normalized = $Address.Trim().ToLowerInvariant()
    if ($current -contains $normalized) { return $false }
    if (-not (Test-Path $path)) {
        Set-Content -Path $path -Encoding UTF8 -Value @(
            "# allowlist de destinatarios do servico '$Service'",
            "# gerada pela skill email-sender - um endereco por linha",
            "# remover uma linha aqui revoga o envio para aquele destinatario"
        )
    }
    Add-Content -Path $path -Value $normalized -Encoding UTF8
    return $true
}

function Remove-AllowlistEntry {
    param([string]$Address)
    $path = Get-AllowlistPath
    if (-not (Test-Path $path)) { return $false }
    $normalized = $Address.Trim().ToLowerInvariant()
    $kept = @()
    $removed = $false
    foreach ($line in (Get-Content -Path $path)) {
        if ($line.Trim().ToLowerInvariant() -eq $normalized) {
            $removed = $true
            continue
        }
        $kept += $line
    }
    if ($removed) { Set-Content -Path $path -Value $kept -Encoding UTF8 }
    return $removed
}

# =====================================================================
# Config por servico
# =====================================================================

function Get-ServiceConfig {
    $path = Get-ConfigPath
    if (-not (Test-Path $path)) { return $null }
    try {
        return (Get-Content -Path $path -Raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Save-ServiceConfig {
    # NAO usar $Host como nome de parametro: e variavel automatica read-only.
    param([string]$FromAddress, [string]$ServerName, [int]$Port)
    $cfg = @{
        from      = $FromAddress
        smtpHost  = $ServerName
        smtpPort  = $Port
        updatedAt = (Get-Date).ToString('o')
    }
    Set-Content -Path (Get-ConfigPath) -Value ($cfg | ConvertTo-Json) -Encoding UTF8
}

# =====================================================================
# Auditoria (metadados apenas - nunca corpo, nunca senha)
# =====================================================================

function Write-Audit {
    param([string]$Result, [string]$FromAddress, [string[]]$Recipients, [string]$Subj, [string]$Anexos)
    if ($NoAudit) { return }
    try {
        $line = '{0}|{1}|from={2}|to={3}|subject={4}|attachments={5}' -f `
            (Get-Date).ToString('o'), $Result, $FromAddress, ($Recipients -join ';'), $Subj, $Anexos
        Add-Content -Path (Get-AuditPath) -Value $line -Encoding UTF8
    }
    catch {
        # auditoria nunca derruba o envio
    }
}

# =====================================================================
# Saida
# =====================================================================

function Write-Result {
    param([string]$Code, [string]$Message, [hashtable]$Extra)
    if ($Json) {
        $payload = @{ code = $Code; message = $Message; service = $Service }
        if ($Extra) { foreach ($k in $Extra.Keys) { $payload[$k] = $Extra[$k] } }
        $payload | ConvertTo-Json -Compress
    }
    else {
        Write-Output $Message
    }
}

# =====================================================================
# Acoes administrativas
# =====================================================================

if ($Action -eq 'setup') {
    Write-Output "=== email-sender :: setup do servico '$Service' ==="
    Write-Output ''

    $addr = $From
    if ([string]::IsNullOrWhiteSpace($addr)) {
        $addr = (Read-Host -Prompt 'Endereco REMETENTE (a conta Gmail que enviara)').Trim()
    }
    if (-not (Test-EmailAddress $addr)) {
        Write-Output "[ERRO] Endereco de remetente invalido."
        exit 1
    }

    Write-Output ''
    Write-Output 'Senha de App do Google (nao e a senha da conta):'
    Write-Output '  1. Ative a verificacao em duas etapas na conta.'
    Write-Output '  2. Gere em: https://myaccount.google.com/apppasswords'
    Write-Output '  3. Cole abaixo. A digitacao fica oculta e a senha nunca'
    Write-Output '     aparece em linha de comando, log ou historico.'
    Write-Output ''
    $secure = Read-Host -Prompt 'Senha de App' -AsSecureString
    # Read-Host devolve $null (nao um SecureString vazio) quando stdin nao e um
    # console de verdade - por exemplo rodando via `powershell -File` a partir de
    # um host nao interativo. Testar so `$secure.Length -eq 0` nao pega esse caso,
    # porque $null.Length tambem e $null, e $null -eq 0 e falso: o script seguia
    # adiante, o ConvertFrom-SecureString falhava, o Set-Content inteiro era
    # pulado e mesmo assim a config era gravada - deixando o servico
    # aparentemente configurado, mas com a credencial ANTIGA.
    if ($null -eq $secure -or $secure.Length -eq 0) {
        Write-Output '[CANCELADO] Nenhuma senha foi capturada.'
        Write-Output '  Se voce digitou a senha e ainda assim viu esta mensagem, este'
        Write-Output '  terminal nao esta entregando o teclado ao script. Abra o'
        Write-Output '  PowerShell pelo menu Iniciar e rode o setup de la.'
        exit 1
    }

    # Colar com os espacos do formato "abcd efgh ijkl mnop" e o caminho natural,
    # mas o Gmail recusa a senha com espacos. Normalizamos aqui para que a
    # credencial gravada ja esteja no formato que o servidor aceita.
    $secure = ConvertTo-CompactSecureString -Secure $secure

    # Senha de app do Google tem exatamente 16 caracteres depois de remover os
    # espacos. Qualquer outro comprimento e quase certamente a senha da conta,
    # que o Google recusa em SMTP desde 2022 - e o sintoma so apareceria muito
    # depois, como AUTH_FAILED no primeiro envio.
    if ($secure.Length -ne 16) {
        Write-Output "[ERRO] A senha informada tem $($secure.Length) caracteres (sem espacos)."
        Write-Output '  Uma Senha de App do Google tem exatamente 16.'
        Write-Output '  Gere uma em https://myaccount.google.com/apppasswords'
        Write-Output '  (exige verificacao em duas etapas ativa na conta).'
        Write-Output '  Nada foi gravado.'
        exit 1
    }

    # ConvertFrom-SecureString cifra direto do SecureString (DPAPI, usuario+maquina).
    # O texto plano nunca e materializado neste processo.
    $credPath = Get-CredentialPath -User $addr
    try {
        $blob = ConvertFrom-SecureString -SecureString $secure -ErrorAction Stop
        Set-Content -Path $credPath -Value $blob -Encoding UTF8 -Force -ErrorAction Stop
    }
    catch {
        # Sem isto a falha era silenciosa: a config seguia sendo gravada logo
        # abaixo e o setup terminava dizendo "concluido".
        Write-Output "[ERRO] Falha ao gravar a credencial: $($_.Exception.Message)"
        Write-Output '  A configuracao NAO foi alterada.'
        exit 2
    }
    Write-Output "[OK] Credencial cifrada (DPAPI) em: $credPath"

    $h = $SmtpHost
    if ([string]::IsNullOrWhiteSpace($h)) { $h = 'smtp.gmail.com' }
    $p = $SmtpPort
    if ($p -le 0) { $p = 587 }
    Save-ServiceConfig -FromAddress $addr -ServerName $h -Port $p
    Write-Output "[OK] Config salva: $h`:$p, remetente $addr"

    Write-Output ''
    Write-Output "Allowlist do servico '$Service' (obrigatoria - so estes recebem)."
    Write-Output 'Informe um endereco por vez. Linha vazia encerra.'
    $count = 0
    while ($true) {
        $r = (Read-Host -Prompt 'Destinatario autorizado').Trim()
        if ([string]::IsNullOrWhiteSpace($r)) { break }
        if (-not (Test-EmailAddress $r)) {
            Write-Output "  [IGNORADO] Endereco invalido: $r"
            continue
        }
        if (Add-AllowlistEntry -Address $r) {
            Write-Output "  [OK] Autorizado: $r"
            $count++
        }
        else {
            Write-Output "  [JA EXISTIA] $r"
        }
    }

    Write-Output ''
    if ((Get-Allowlist).Count -eq 0) {
        Write-Output '[AVISO] Allowlist vazia. Nenhum envio sera permitido ate'
        Write-Output "        autorizar ao menos um destinatario:"
        Write-Output "        .\send_email.ps1 -Action add-recipient -Service $Service -Recipient alguem@dominio.com"
        exit 0
    }
    Write-Output "[OK] Setup concluido. $count destinatario(s) adicionado(s) nesta sessao."
    exit 0
}

if ($Action -eq 'add-recipient') {
    if (-not (Test-EmailAddress $Recipient)) {
        Write-Result -Code 'INVALID_INPUT' -Message "[ERRO] -Recipient invalido ou ausente."
        exit 1
    }
    $added = Add-AllowlistEntry -Address $Recipient
    if ($added) {
        Write-Result -Code 'OK' -Message "[OK] '$Recipient' autorizado no servico '$Service'."
    }
    else {
        Write-Result -Code 'OK' -Message "[OK] '$Recipient' ja estava autorizado."
    }
    exit 0
}

if ($Action -eq 'remove-recipient') {
    if ([string]::IsNullOrWhiteSpace($Recipient)) {
        Write-Result -Code 'INVALID_INPUT' -Message '[ERRO] -Recipient e obrigatorio.'
        exit 1
    }
    $removed = Remove-AllowlistEntry -Address $Recipient
    if ($removed) {
        Write-Result -Code 'OK' -Message "[OK] '$Recipient' revogado do servico '$Service'."
    }
    else {
        Write-Result -Code 'OK' -Message "[OK] '$Recipient' nao estava na allowlist."
    }
    exit 0
}

if ($Action -eq 'list-recipients') {
    $list = Get-Allowlist
    if ($Json) {
        @{ service = $Service; recipients = $list } | ConvertTo-Json -Compress
    }
    else {
        Write-Output "Allowlist do servico '$Service' ($($list.Count) endereco(s)):"
        if ($list.Count -eq 0) {
            Write-Output '  (vazia - nenhum envio sera permitido)'
        }
        foreach ($r in $list) { Write-Output "  - $r" }
    }
    exit 0
}

if ($Action -eq 'status') {
    $cfg = Get-ServiceConfig
    $list = Get-Allowlist
    $credOk = $false
    $fromAddr = ''
    if ($null -ne $cfg) {
        $fromAddr = [string]$cfg.from
        $credOk = Test-Path (Get-CredentialPath -User $fromAddr)
    }
    if ($Json) {
        @{
            service         = $Service
            configured      = ($null -ne $cfg)
            from            = $fromAddr
            credentialSaved = $credOk
            recipientCount  = $list.Count
            recipients      = $list
        } | ConvertTo-Json -Compress
    }
    else {
        Write-Output "=== email-sender :: status do servico '$Service' ==="
        if ($null -eq $cfg) {
            Write-Output '  Config .......: NAO configurado (rode -Action setup)'
        }
        else {
            Write-Output "  Remetente ....: $fromAddr"
            Write-Output "  Servidor .....: $($cfg.smtpHost):$($cfg.smtpPort)"
        }
        if ($credOk) {
            Write-Output '  Credencial ...: salva (DPAPI, usuario+maquina)'
        }
        else {
            Write-Output '  Credencial ...: AUSENTE'
        }
        Write-Output "  Allowlist ....: $($list.Count) destinatario(s) autorizado(s)"
        foreach ($r in $list) { Write-Output "                  - $r" }
        Write-Output "  Auditoria ....: $(Get-AuditPath)"
    }
    exit 0
}

if ($Action -eq 'logout') {
    $cfg = Get-ServiceConfig
    if ($null -ne $cfg -and -not [string]::IsNullOrWhiteSpace([string]$cfg.from)) {
        $credPath = Get-CredentialPath -User ([string]$cfg.from)
        if (Test-Path $credPath) { Remove-Item -Path $credPath -Force -Confirm:$false }
    }
    Write-Result -Code 'OK' -Message "[OK] Credencial do servico '$Service' removida. Allowlist e auditoria preservadas."
    exit 0
}

# =====================================================================
# Acao: send
# =====================================================================

# ---- 1. Validacao dos campos ----
$recipients = ConvertTo-RecipientList -Raw $To
if ($recipients.Count -eq 0) {
    Write-Result -Code 'INVALID_INPUT' -Message '[ERRO] -To e obrigatorio (um ou mais destinatarios).'
    exit 1
}
foreach ($r in $recipients) {
    if (-not (Test-EmailAddress $r)) {
        Write-Result -Code 'INVALID_INPUT' -Message "[ERRO] Destinatario invalido: '$r'"
        exit 1
    }
}

if ([string]::IsNullOrWhiteSpace($Subject)) {
    Write-Result -Code 'INVALID_INPUT' -Message '[ERRO] -Subject e obrigatorio.'
    exit 1
}
if (-not (Test-NoHeaderInjection $Subject)) {
    Write-Result -Code 'INVALID_INPUT' -Message '[ERRO] -Subject contem quebra de linha (tentativa de header injection).'
    exit 1
}

$bodyText = $Body
if (-not [string]::IsNullOrWhiteSpace($BodyFile)) {
    if (-not (Test-Path -Path $BodyFile -PathType Leaf)) {
        Write-Result -Code 'INVALID_INPUT' -Message "[ERRO] -BodyFile nao encontrado: $BodyFile"
        exit 1
    }
    $bodyText = Get-Content -Path $BodyFile -Raw
}
if ($null -eq $bodyText) { $bodyText = '' }

# ---- 2. Allowlist: fail-closed, antes de qualquer conexao ----
$allowed = Get-Allowlist
if ($allowed.Count -eq 0) {
    $msg = @"
[BLOQUEADO] O servico '$Service' nao tem allowlist configurada.
            Nenhum email sera enviado (fail-closed por design).
            Autorize os destinatarios primeiro:
              .\send_email.ps1 -Action add-recipient -Service $Service -Recipient alguem@dominio.com
"@
    Write-Result -Code 'RECIPIENT_BLOCKED' -Message $msg
    Write-Audit -Result 'BLOCKED_NO_ALLOWLIST' -FromAddress '' -Recipients $recipients -Subj $Subject -Anexos ''
    exit 3
}

$blocked = @()
foreach ($r in $recipients) {
    if ($allowed -notcontains $r.ToLowerInvariant()) { $blocked += $r }
}
if ($blocked.Count -gt 0) {
    # Bloqueio e total, nao parcial: enviar so para os autorizados mascararia o
    # erro do chamador e ainda entregaria os dados a um conjunto que ele nao pediu.
    $msg = @"
[BLOQUEADO] Destinatario(s) fora da allowlist do servico '$Service':
            $($blocked -join ', ')
            Nenhum email foi enviado. Para autorizar:
              .\send_email.ps1 -Action add-recipient -Service $Service -Recipient $($blocked[0])
"@
    Write-Result -Code 'RECIPIENT_BLOCKED' -Message $msg -Extra @{ blocked = $blocked }
    Write-Audit -Result 'BLOCKED_NOT_ALLOWED' -FromAddress '' -Recipients $recipients -Subj $Subject -Anexos ''
    exit 3
}

# ---- 3. Anexos ----
$resolvedAttachments = @()
$totalBytes = 0
if ($Attachment) {
    foreach ($a in $Attachment) {
        if ([string]::IsNullOrWhiteSpace($a)) { continue }
        if (-not (Test-Path -Path $a -PathType Leaf)) {
            Write-Result -Code 'ATTACHMENT_ERROR' -Message "[ERRO] Anexo nao encontrado (ou nao e arquivo): $a"
            exit 4
        }
        $item = Get-Item -Path $a
        if ($item.Length -eq 0) {
            Write-Result -Code 'ATTACHMENT_ERROR' -Message "[ERRO] Anexo vazio (0 bytes): $($item.FullName)"
            exit 4
        }
        $resolvedAttachments += $item
        $totalBytes += $item.Length
    }
}
$maxBytes = $MaxTotalMB * 1MB
if ($totalBytes -gt $maxBytes) {
    $msg = "[ERRO] Anexos somam $([math]::Round($totalBytes/1MB,2)) MB, acima do limite de $MaxTotalMB MB."
    Write-Result -Code 'ATTACHMENT_ERROR' -Message $msg
    exit 4
}
$attachDesc = ($resolvedAttachments | ForEach-Object { "$($_.Name)($($_.Length)B)" }) -join ';'

# ---- 4. Config e credencial ----
$cfg = Get-ServiceConfig
$fromAddress = $From
if ([string]::IsNullOrWhiteSpace($fromAddress) -and $null -ne $cfg) {
    $fromAddress = [string]$cfg.from
}
if (-not (Test-EmailAddress $fromAddress)) {
    $msg = @"
[ERRO] Servico '$Service' sem remetente configurado.
       Rode o setup uma unica vez:
         .\send_email.ps1 -Action setup -Service $Service
"@
    Write-Result -Code 'CREDENTIAL_MISSING' -Message $msg
    exit 2
}

$smtpServer = $SmtpHost
if ([string]::IsNullOrWhiteSpace($smtpServer)) {
    if ($null -ne $cfg -and -not [string]::IsNullOrWhiteSpace([string]$cfg.smtpHost)) {
        $smtpServer = [string]$cfg.smtpHost
    }
    else {
        $smtpServer = 'smtp.gmail.com'
    }
}
$smtpPortNum = $SmtpPort
if ($smtpPortNum -le 0) {
    if ($null -ne $cfg -and [int]$cfg.smtpPort -gt 0) { $smtpPortNum = [int]$cfg.smtpPort }
    else { $smtpPortNum = 587 }
}

$credPath = Get-CredentialPath -User $fromAddress
if (-not (Test-Path $credPath)) {
    $msg = @"
[ERRO] Credencial nao encontrada para '$fromAddress' no servico '$Service'.
       Rode: .\send_email.ps1 -Action setup -Service $Service
"@
    Write-Result -Code 'CREDENTIAL_MISSING' -Message $msg
    exit 2
}

# ---- 5. DryRun: valida tudo, nao conecta ----
if ($DryRun) {
    $lines = @(
        '[DRY-RUN] Nada foi enviado. Validacao completa:',
        "  Servico ......: $Service",
        "  Remetente ....: $fromAddress",
        "  Servidor .....: $smtpServer`:$smtpPortNum (TLS obrigatorio)",
        "  Destinatarios : $($recipients -join ', ')  [todos na allowlist]",
        "  Assunto ......: $Subject",
        "  Corpo ........: $($bodyText.Length) caracteres",
        "  Anexos .......: $($resolvedAttachments.Count) arquivo(s), $([math]::Round($totalBytes/1KB,1)) KB",
        "  Credencial ...: presente (DPAPI)"
    )
    foreach ($att in $resolvedAttachments) {
        $lines += "                  - $($att.Name) ($($att.Length.ToString('N0')) bytes)"
    }
    Write-Result -Code 'DRY_RUN' -Message ($lines -join [Environment]::NewLine)
    Write-Audit -Result 'DRY_RUN' -FromAddress $fromAddress -Recipients $recipients -Subj $Subject -Anexos $attachDesc
    exit 0
}

# ---- 6. TLS obrigatorio ----
try {
    # PowerShell 5.1 pode herdar SSL3/TLS1.0 do processo. Forcamos 1.2+ .
    $proto = [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        $proto = $proto -bor [Net.SecurityProtocolType]::Tls13
    }
    [Net.ServicePointManager]::SecurityProtocol = $proto
    # Se algum script anterior da sessao instalou um callback permissivo
    # ({ $true }), ele aceitaria certificado invalido. Restauramos o padrao.
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
}
catch {
    Write-Result -Code 'TLS_ERROR' -Message "[ERRO] Nao foi possivel exigir TLS 1.2+: $($_.Exception.Message)"
    exit 7
}

# ---- 7. Envio ----
$smtp = $null
$msgObj = $null
$attachObjs = @()
try {
    # Blob DPAPI -> SecureString -> NetworkCredential.
    # O texto plano da senha nunca existe como string neste processo.
    $encrypted = (Get-Content -Path $credPath -Raw).Trim()
    # A normalizacao tambem acontece aqui, e nao so no setup, para que credenciais
    # gravadas antes desta correcao (com os espacos da senha de app) funcionem sem
    # exigir um novo setup do usuario.
    $securePwd = ConvertTo-CompactSecureString -Secure (ConvertTo-SecureString -String $encrypted)

    $smtp = New-Object System.Net.Mail.SmtpClient($smtpServer, $smtpPortNum)
    $smtp.EnableSsl = $true
    $smtp.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
    $smtp.UseDefaultCredentials = $false
    $smtp.Credentials = New-Object System.Net.NetworkCredential($fromAddress, $securePwd)
    $smtp.Timeout = 60000

    $msgObj = New-Object System.Net.Mail.MailMessage
    $msgObj.From = New-Object System.Net.Mail.MailAddress($fromAddress)
    foreach ($r in $recipients) { $msgObj.To.Add($r) }
    $msgObj.Subject = $Subject
    $msgObj.SubjectEncoding = [System.Text.Encoding]::UTF8
    $msgObj.Body = $bodyText
    $msgObj.BodyEncoding = [System.Text.Encoding]::UTF8
    # Texto puro por design: sem HTML, sem conteudo remoto, sem rastreador.
    $msgObj.IsBodyHtml = $false

    foreach ($att in $resolvedAttachments) {
        $obj = New-Object System.Net.Mail.Attachment($att.FullName)
        $attachObjs += $obj
        $msgObj.Attachments.Add($obj)
    }

    Write-Verbose "Enviando via $smtpServer`:$smtpPortNum como $fromAddress"
    $smtp.Send($msgObj)

    $okMsg = "[OK] Email enviado para: $($recipients -join ', ')"
    if ($resolvedAttachments.Count -gt 0) {
        $okMsg += " ($($resolvedAttachments.Count) anexo(s), $([math]::Round($totalBytes/1KB,1)) KB)"
    }
    Write-Result -Code 'OK' -Message $okMsg -Extra @{ recipients = $recipients; attachments = $resolvedAttachments.Count }
    Write-Audit -Result 'SENT' -FromAddress $fromAddress -Recipients $recipients -Subj $Subject -Anexos $attachDesc
    $exitCode = 0
}
catch [System.Net.Mail.SmtpException] {
    $detail = $_.Exception.Message
    $status = ''
    if ($_.Exception.StatusCode) { $status = [string]$_.Exception.StatusCode }

    if ($status -eq 'MailboxBusy' -or $detail -match '5\.7\.\d|Username and Password not accepted|BadCredentials|Authentication') {
        # A mensagem NAO afirma que a senha foi revogada: isso seria um palpite.
        # O servidor so diz que recusou o AUTH, e a mesma recusa acontece quando a
        # credencial lida nao e a que o usuario acha que gravou - por exemplo se
        # este processo enxerga outro sistema de arquivos (sandbox, container,
        # sessao de outro usuario) e portanto le uma versao antiga do arquivo.
        # Diagnosticar isso exige os fatos abaixo, nao uma causa presumida.
        # Regenerar a senha de app nao resolve o caso do arquivo divergente, e
        # foi exatamente esse palpite que fez o usuario regerar a senha varias
        # vezes a toa antes desta correcao.
        $credInfo = 'nao foi possivel inspecionar o arquivo'
        try {
            $cf = Get-Item $credPath -ErrorAction Stop
            $plen = (ConvertTo-SecureString -String ((Get-Content $credPath -Raw).Trim())).Length
            $credInfo = "gravado em $($cf.LastWriteTime.ToString('dd/MM/yyyy HH:mm:ss')), $plen caractere(s)"
        }
        catch { }

        $msg = @"
[ERRO] O servidor SMTP recusou a autenticacao de '$fromAddress'.
       Resposta do servidor: $detail

       Credencial usada nesta tentativa:
         arquivo ..: $credPath
         $credInfo
         processo .: PID $PID, usuario $env:USERDOMAIN\$env:USERNAME

       Confira PRIMEIRO se esses dados batem com o setup que voce fez:
       - Comprimento diferente de 16 => o que esta salvo nao e uma senha de app.
       - Data de gravacao anterior ao seu ultimo setup => este processo esta
         lendo outra copia do arquivo (sandbox/container/outro usuario). Rode o
         envio no mesmo terminal em que rodou o setup; gerar outra senha de app
         NAO resolve esse caso.
       - Dados batendo e ainda assim recusado => ai sim a senha de app foi
         revogada ou o 2FA foi desativado. Gere outra em
         https://myaccount.google.com/apppasswords e rode:
           .\send_email.ps1 -Action setup -Service $Service
"@
        Write-Result -Code 'AUTH_FAILED' -Message $msg
        Write-Audit -Result 'AUTH_FAILED' -FromAddress $fromAddress -Recipients $recipients -Subj $Subject -Anexos $attachDesc
        $exitCode = 6
    }
    else {
        Write-Result -Code 'SEND_FAILED' -Message "[ERRO] Falha no envio SMTP: $detail"
        Write-Audit -Result 'SEND_FAILED' -FromAddress $fromAddress -Recipients $recipients -Subj $Subject -Anexos $attachDesc
        $exitCode = 5
    }
}
catch {
    Write-Result -Code 'SEND_FAILED' -Message "[ERRO] Falha inesperada no envio: $($_.Exception.Message)"
    Write-Audit -Result 'SEND_FAILED' -FromAddress $fromAddress -Recipients $recipients -Subj $Subject -Anexos $attachDesc
    $exitCode = 5
}
finally {
    foreach ($o in $attachObjs) { if ($o) { $o.Dispose() } }
    if ($msgObj) { $msgObj.Dispose() }
    if ($smtp) { $smtp.Dispose() }
}

exit $exitCode
