<#
.SYNOPSIS
    Baixa a agenda do Simples Agenda em .xls. Alternativa ao download_agenda.py
    para maquinas sem Python instalado.

.DESCRIPTION
    Mesmo fluxo do download_agenda.py, usando apenas Invoke-WebRequest:
      1. GET  autenticacao_usuario.php  -> cookie PHPSESSID
      2. POST crud_autenticacao.php     -> acao=autentica_usuario
      3. POST crud.php                  -> acao=exporta_agendamentos
      4. GET  <nome_excel>              -> arquivo .xls (OLE2)

    Requer Windows PowerShell 5.1 ou superior. Sem dependencias externas.

    Credenciais (Melhoria #1): a senha e gerenciada pela skill credential-manager.
      - 1a execucao: informe -Senha (ou digite quando solicitado) -> e salva automaticamente.
      - Proximas execucoes: basta -Email + datas, a senha e carregada sozinha.
      - -Logout remove a senha salva para o -Email informado.

.EXAMPLE
    .\baixar_agenda.ps1 -Email voce@email.com -Senha minhasenha `
        -DataIni 01/09/2026 -DataFim 05/09/2026

.EXAMPLE
    # proximas vezes: senha carregada automaticamente do credential-manager
    .\baixar_agenda.ps1 -Email voce@email.com -DataIni 06/09/2026 -DataFim 10/09/2026

.EXAMPLE
    .\baixar_agenda.ps1 -Email voce@email.com -Logout

.NOTES
    Codigos de saida: 0 OK | 1 AUTH_FAILED | 2 NO_RESULTS |
                      3 CORRUPTED_FILE | 4 INVALID_INPUT | 5 CONNECTION_ERROR |
                      6 RATE_LIMITED (HTTP 429 - aguarde alguns minutos)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Email,
    [string]$Senha,
    [string]$DataIni,
    [string]$DataFim,
    [string]$CodUsuarioArray = '',
    [string]$CodCliente = '',
    [string]$CodProduto = '',
    [string]$DestDir,
    [switch]$Logout,

    # ---- Melhoria #2: sincronizacao com BD (skill import-db-agenda) ----
    # Destino: banco 4clinics, tabela sbx990 (empresaId/filialId/filialOrigemId
    # fixos - ver import-db-agenda/SKILL.md para o mapeamento de colunas).
    [string]$DbHost = '127.0.0.1',
    [int]$DbPort = 3306,
    [string]$DbUser = 'root',
    [string]$Database = '4clinics',
    [string]$DbPassword,
    [string]$EmpresaId = '001',
    [string]$FilialId = '01',
    [string]$FilialOrigemId = '01',
    [ValidateSet('cliente+data', 'servico+data', 'profissional+data')]
    [string]$SortBy = 'cliente+data',
    [switch]$NoSyncToDb,

    # ---- Melhoria #3: envio de email (delegado a skill email-sender) ----
    # -EnviarPara define o(s) DESTINATARIO(s). O remetente e a conta configurada
    # na email-sender para o servico 'simples-agenda'. Todo destinatario precisa
    # estar na allowlist daquele servico, senao o envio e bloqueado.
    [string]$EnviarPara = 'amazonasterapiafisio@gmail.com',
    [switch]$NaoEnviarEmail
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------- credential-manager
$CredManagerScript = Join-Path $PSScriptRoot '..\..\credential-manager\scripts\credential_manager.ps1'
$CredService = 'simples-agenda'

function Invoke-CredManager {
    param([hashtable]$CredArgs)
    & $CredManagerScript @CredArgs
}

if ($Logout) {
    if (-not (Test-Path $CredManagerScript)) {
        Write-Output "[ERRO] Skill credential-manager nao encontrada em: $CredManagerScript"
        exit 5
    }
    Invoke-CredManager -CredArgs @{ Action = 'delete'; Username = $Email; Service = $CredService } | Out-Null
    exit 0
}

# ------------------------------------------------- defaults para DataIni/DataFim
# Se nao informadas, usa: DataIni = hoje - 7 dias, DataFim = hoje - 1 dia
$hoje = [datetime]::Now.Date
if ([string]::IsNullOrEmpty($DataIni) -or [string]::IsNullOrEmpty($DataFim)) {
    if ([string]::IsNullOrEmpty($DataIni)) {
        $DataIni = $hoje.AddDays(-7).ToString('dd/MM/yyyy')
        Write-Output "[*] DataIni nao informada, usando default: $DataIni (hoje - 7 dias)"
    }
    if ([string]::IsNullOrEmpty($DataFim)) {
        $DataFim = $hoje.AddDays(-1).ToString('dd/MM/yyyy')
        Write-Output "[*] DataFim nao informada, usando default: $DataFim (hoje - 1 dia)"
    }
}

$base = 'https://www.simplesagenda.com.br'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

# ------------------------------------------------------------------ helpers
function Get-Text($resp) {
    $c = $resp.Content
    if ($c -is [byte[]]) {
        return [System.Text.Encoding]::GetEncoding('iso-8859-1').GetString($c)
    }
    return [string]$c
}

function Get-Tag($xml, $tag) {
    $m = [regex]::Match($xml, ('<{0}>(.*?)</{0}>' -f $tag), 'Singleline')
    if (-not $m.Success) { return $null }
    return ($m.Groups[1].Value -replace '<!\[CDATA\[', '' -replace '\]\]>', '').Trim()
}

function Get-HttpStatus($err) {
    # Extrai o codigo HTTP de uma excecao de Invoke-WebRequest (0 se nao houver)
    if ($err.Exception.Response) { return [int]$err.Exception.Response.StatusCode }
    return 0
}

function Exit-OnHttpError($err, $contexto) {
    $status = Get-HttpStatus $err
    if ($status -eq 429) {
        Write-Output "[ERRO] Muitas requisicoes em sequencia (HTTP 429)."
        Write-Output "       O Simples Agenda aplica rate limiting. Aguarde alguns"
        Write-Output "       minutos antes de tentar de novo."
        exit 6
    }
    Write-Output "[ERRO] Falha de conexao $contexto. Verifique sua internet e tente novamente."
    Write-Output ("       " + $err.Exception.Message)
    exit 5
}

function Test-DataValida($s) {
    if ($s -notmatch '^\d{2}/\d{2}/\d{4}$') { return $null }
    $d = [datetime]::MinValue
    $ok = [datetime]::TryParseExact(
        $s, 'dd/MM/yyyy', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$d)
    if ($ok) { return $d }
    return $null
}

# -------------------------------------------------------------- validacao
$dIni = Test-DataValida $DataIni
if ($null -eq $dIni) {
    Write-Output "[ERRO] Data inicial invalida: '$DataIni'. Use dd/mm/yyyy (exemplo: 01/01/2024)."
    exit 4
}
$dFim = Test-DataValida $DataFim
if ($null -eq $dFim) {
    Write-Output "[ERRO] Data final invalida: '$DataFim'. Use dd/mm/yyyy (exemplo: 31/01/2024)."
    exit 4
}

# Validacoes de range de data
# $hoje ja calculado nos defaults acima
if ($dIni -gt $hoje) {
    Write-Output "[ERRO] Data Inicio nao pode ser no futuro."
    Write-Output "       Hoje: $($hoje.ToString('dd/MM/yyyy')) | Informada: $DataIni"
    exit 4
}
if ($dFim -gt $hoje) {
    Write-Output "[ERRO] Data Fim nao pode ser no futuro."
    Write-Output "       Hoje: $($hoje.ToString('dd/MM/yyyy')) | Informada: $DataFim"
    exit 4
}
if ($dFim -lt $dIni) {
    Write-Output "[ERRO] Data Fim deve ser maior ou igual a Data Inicio."
    Write-Output "       Data Inicio: $DataIni | Data Fim: $DataFim"
    exit 4
}

$credManagerDisponivel = Test-Path $CredManagerScript

if ([string]::IsNullOrEmpty($Senha) -and $credManagerDisponivel) {
    # Tenta carregar senha ja salva para este email (nao pede nada ao usuario)
    $jsonOut = Invoke-CredManager -CredArgs @{ Action = 'load'; Username = $Email; Service = $CredService; Json = $true }
    try {
        $parsed = $jsonOut | ConvertFrom-Json
        if ($parsed.found) {
            $Senha = $parsed.password
            Write-Output "[*] Credenciais carregadas automaticamente para $Email."
        }
    }
    catch {
        # sem credencial salva ainda - segue para o prompt abaixo
    }
}

$senhaVeioDoPrompt = $false
if ([string]::IsNullOrEmpty($Senha)) {
    $sec = Read-Host -Prompt 'Senha Simples Agenda' -AsSecureString
    $Senha = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    $senhaVeioDoPrompt = $true
}
if ([string]::IsNullOrEmpty($Senha)) {
    Write-Output "[ERRO] Senha e obrigatoria."
    exit 4
}

# Salva automaticamente quando a senha foi informada explicitamente (-Senha ou
# prompt interativo) para que a proxima execucao nao precise informa-la de novo.
if ($credManagerDisponivel -and ($senhaVeioDoPrompt -or $PSBoundParameters.ContainsKey('Senha'))) {
    Invoke-CredManager -CredArgs @{ Action = 'save'; Username = $Email; Password = $Senha; Service = $CredService } | Out-Null
}

# ------------------------------------------------------------------ login
try {
    Write-Output "[*] Autenticando como $Email..."

    $null = Invoke-WebRequest -Uri "$base/autenticacao_usuario.php" `
        -SessionVariable sess -UserAgent $ua -UseBasicParsing -TimeoutSec 30

    $login = Invoke-WebRequest -Uri "$base/crud_autenticacao.php" -Method POST `
        -WebSession $sess -UserAgent $ua -UseBasicParsing -TimeoutSec 30 `
        -Headers @{ 'X-Requested-With' = 'XMLHttpRequest'; 'Referer' = "$base/autenticacao_usuario.php" } `
        -Body @{
            acao             = 'autentica_usuario'
            login            = $Email
            senha            = $Senha
            conectado        = '1'
            captcha_resposta = ''
        }
}
catch {
    Exit-OnHttpError $_ "no login"
}

$lb = Get-Text $login
$houveErro = Get-Tag $lb 'houve_erro'

if ($null -eq $houveErro) {
    Write-Output "[ERRO] Resposta de login em formato inesperado (sem <houve_erro>)."
    Write-Output "       O Simples Agenda pode ter mudado o endpoint de autenticacao."
    exit 1
}
if ($houveErro -ne 'N') {
    if ((Get-Tag $lb 'requer_captcha') -eq 'S') {
        Write-Output "[ERRO] O site esta pedindo CAPTCHA no login."
        Write-Output ("       Pergunta: " + (Get-Tag $lb 'captcha_pergunta'))
        Write-Output "       Faca o login manualmente no navegador e tente de novo mais tarde."
        exit 1
    }
    # a mensagem do servidor vem com HTML embutido; limpa para o terminal
    $msg = (Get-Tag $lb 'mensagem') -replace '<[^>]+>', ' ' -replace '\s+', ' '
    $msg = $msg.Trim()
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'Credenciais invalidas.' }
    Write-Output "[ERRO] $msg"
    exit 1
}

$cookies = ($sess.Cookies.GetCookies($base) | ForEach-Object { $_.Name }) -join ', '
if ($cookies -notmatch 'UsuarioSA') {
    Write-Output "[ERRO] Login aceito mas a sessao nao foi estabelecida (cookie UsuarioSA ausente)."
    exit 1
}
Write-Output ("[OK] Autenticado. Destino: " + (Get-Tag $lb 'endereco'))

# ------------------------------------------------------------------ export
function Invoke-Export {
    Invoke-WebRequest -Uri "$base/crud.php" -Method POST -WebSession $sess `
        -UserAgent $ua -UseBasicParsing -TimeoutSec 120 `
        -Headers @{ 'X-Requested-With' = 'XMLHttpRequest'; 'Referer' = "$base/agendamento.php" } `
        -Body @{
            acao              = 'exporta_agendamentos'
            dataIni           = $DataIni
            dataFim           = $DataFim
            cod_usuario_array = $CodUsuarioArray
            cod_cliente       = $CodCliente
            cod_produto       = $CodProduto
        }
}

try {
    Write-Output "[*] Exportando agenda de $DataIni ate $DataFim..."
    $body = Get-Text (Invoke-Export)
}
catch {
    Exit-OnHttpError $_ "durante a exportacao"
}

if ($body -match 'ExpirouConexao') {
    Write-Output "[ERRO] Sessao expirada no servidor. Execute o script novamente."
    exit 1
}

$nome = Get-Tag $body 'nome_excel'
if ([string]::IsNullOrWhiteSpace($nome)) {
    Write-Output "[ERRO] Nenhum agendamento encontrado para: $DataIni ate $DataFim."
    Write-Output "       Tente outro periodo ou revise os filtros."
    exit 2
}
Write-Output "[OK] Excel gerado: $nome"

# ---------------------------------------------------------------- download
if ([string]::IsNullOrWhiteSpace($DestDir)) {
    $DestDir = Join-Path $env:USERPROFILE 'Downloads'
}
if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$out = Join-Path $DestDir ("agenda_" + $stamp + ".xls")
$i = 1
while (Test-Path $out) {
    $out = Join-Path $DestDir ("agenda_" + $stamp + "_" + $i + ".xls")
    $i++
}

try {
    Invoke-WebRequest -Uri ("$base/" + $nome) -WebSession $sess -UserAgent $ua `
        -UseBasicParsing -TimeoutSec 180 -OutFile $out
}
catch {
    if (Test-Path $out) { Remove-Item $out -Force }
    Write-Output "[ERRO] Download interrompido. Tente novamente."
    Exit-OnHttpError $_ "no download do arquivo"
}

$size = (Get-Item $out).Length
$magic = [BitConverter]::ToString((Get-Content -Path $out -Encoding Byte -TotalCount 8)) -replace '-', ''
if ($size -eq 0 -or $magic -ne 'D0CF11E0A1B11AE1') {
    Write-Output "[ERRO] Download interrompido ou arquivo corrompido ($size bytes, magic $magic)."
    Remove-Item $out -Force
    exit 3
}

Write-Output ("[OK] Download concluido: " + (Split-Path $out -Leaf) + " (" + $size.ToString('N0') + " bytes)")
Write-Output ("[OK] Local: " + $out)

# --------------------------------------------- Melhoria #2: sincroniza BD
# Passos 4-8 do fluxo: sync -> export ordenado -> deleta o .xls original.
# A skill import-db-agenda e obrigatoria para gerar a planilha ordenada.
# O parametro -NoSyncToDb pula so a SINCRONIZACAO, nao a ORDENACAO.
$DbManagerScript = Join-Path $PSScriptRoot '..\..\import-db-agenda\scripts\db_manager.ps1'
if (-not (Test-Path $DbManagerScript)) {
    Write-Output "[AVISO] Skill import-db-agenda nao encontrada em: $DbManagerScript"
    Write-Output "        Impossivel gerar planilha ordenada (requer import-db-agenda)."
    Write-Output "        O .xls original foi mantido em: $out"
    exit 0
}

function Invoke-DbManager {
    param([hashtable]$DbArgs)
    & $DbManagerScript @DbArgs
}

$dbCommonArgs = @{
    DbHost         = $DbHost
    DbPort         = $DbPort
    DbUser         = $DbUser
    Database       = $Database
    EmpresaId      = $EmpresaId
    FilialId       = $FilialId
    FilialOrigemId = $FilialOrigemId
}
if ($PSBoundParameters.ContainsKey('DbPassword')) {
    $dbCommonArgs['DbPassword'] = $DbPassword
}

# A sincronizacao (init-schema + sync) so acontece sem o -NoSyncToDb.
# Mas a exportacao ordenada sempre acontece.
if (-not $NoSyncToDb) {
    Write-Output "[*] Sincronizando com o banco de dados (sbx990)..."
    Invoke-DbManager -DbArgs ($dbCommonArgs + @{ Action = 'init-schema' })
    if ($LASTEXITCODE -ne 0) {
        Write-Output "[ERRO] Falha ao preparar o schema do banco. O .xls original foi mantido em: $out"
        exit 7
    }

    Invoke-DbManager -DbArgs ($dbCommonArgs + @{ Action = 'sync'; XlsPath = $out })
    if ($LASTEXITCODE -ne 0) {
        Write-Output "[ERRO] Falha ao sincronizar com o banco. O .xls original foi mantido em: $out"
        exit 7
    }
} else {
    Write-Output "[*] Sincronizacao desabilitada. Gerando planilha ordenada sem sincronizar o banco..."
}

$orderedOut = Join-Path $DestDir ("agenda_ordenada_" + $stamp + ".xlsx")
Write-Output "[*] Gerando planilha ordenada por $SortBy (periodo $DataIni a $DataFim)..."
Invoke-DbManager -DbArgs ($dbCommonArgs + @{ Action = 'export'; OutputPath = $orderedOut; SortBy = $SortBy; DataIni = $DataIni; DataFim = $DataFim })
if ($LASTEXITCODE -ne 0) {
    Write-Output "[ERRO] Falha ao gerar a planilha ordenada. O .xls original foi mantido em: $out"
    exit 7
}

# Passo 8: deleta o .xls original agora que os dados estao no BD e a planilha
# ordenada foi gerada com sucesso.
Remove-Item -Path $out -Force -ErrorAction SilentlyContinue
Write-Output "[OK] Fluxo completo. Planilha ordenada final: $orderedOut"

# Passo 9 (Melhoria #3): envia a planilha ordenada por email, delegando para a
# skill email-sender. Todo o mecanismo de seguranca (SMTP+TLS obrigatorio,
# allowlist de destinatarios, credencial em DPAPI sem texto plano) vive la;
# aqui so montamos assunto/corpo e tratamos o resultado.
#
# CONTRATO: falha de envio NAO derruba esta skill e NAO apaga a planilha. O
# artefato principal ja foi produzido com sucesso; o envio e um passo adicional.
if (-not $NaoEnviarEmail) {
    $EmailSenderScript = Join-Path $PSScriptRoot '..\..\email-sender\scripts\send_email.ps1'

    if (-not (Test-Path $EmailSenderScript)) {
        Write-Output "[AVISO] Skill email-sender nao encontrada em: $EmailSenderScript"
        Write-Output "        A planilha foi gerada normalmente. Envie manualmente:"
        Write-Output "        $orderedOut"
    }
    else {
        $assunto = "Agenda Ordenada: $DataIni a $DataFim"
        $corpo = @"
Planilha de agendamentos gerada automaticamente.

Periodo ...: $DataIni a $DataFim
Ordenacao .: $SortBy
Arquivo ...: $(Split-Path $orderedOut -Leaf)
Gerada em .: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')

Enviado pela skill simples-agenda-download.
"@

        Write-Output "[*] Enviando planilha por email para: $EnviarPara..."
        & $EmailSenderScript -Service 'simples-agenda' `
            -To $EnviarPara `
            -Subject $assunto `
            -Body $corpo `
            -Attachment $orderedOut
        $emailExit = $LASTEXITCODE

        # 0 = enviado (a propria email-sender ja imprimiu o [OK]).
        # Os demais viram AVISO: informam o que fazer e preservam a planilha.
        switch ($emailExit) {
            0 { }
            2 {
                Write-Output "[AVISO] email-sender ainda nao configurado para o servico 'simples-agenda'."
                Write-Output "        Configure uma unica vez (interativo):"
                Write-Output "        powershell -ExecutionPolicy Bypass -File `"$EmailSenderScript`" -Action setup -Service simples-agenda"
                Write-Output "        Planilha preservada em: $orderedOut"
            }
            3 {
                Write-Output "[AVISO] Destinatario fora da allowlist do servico 'simples-agenda'. Nada foi enviado."
                Write-Output "        Para autorizar:"
                Write-Output "        powershell -ExecutionPolicy Bypass -File `"$EmailSenderScript`" -Action add-recipient -Service simples-agenda -Recipient <email>"
                Write-Output "        Planilha preservada em: $orderedOut"
            }
            6 {
                # Nao repetir aqui um palpite de causa: o email-sender ja imprimiu
                # acima os dados concretos da credencial que usou (arquivo, data de
                # gravacao, comprimento). Afirmar "senha revogada" sem verificar foi
                # o que levou o usuario a regerar a senha de app varias vezes sem
                # necessidade, quando a causa real era outra copia do arquivo.
                Write-Output "[AVISO] O servidor SMTP recusou a autenticacao. Veja o diagnostico acima."
                Write-Output "        Planilha preservada em: $orderedOut"
            }
            default {
                Write-Output "[AVISO] Falha ao enviar o email (exit $emailExit)."
                Write-Output "        Planilha preservada em: $orderedOut"
            }
        }
    }
}

exit 0
