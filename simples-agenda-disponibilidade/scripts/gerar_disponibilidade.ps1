<#
.SYNOPSIS
    Baixa a agenda FUTURA do Simples Agenda, cruza com a disponibilidade
    semanal dos profissionais (sb5990) e com o historico de atendimentos das
    ultimas N semanas (sbx990) para sugerir pacientes que preencham horarios
    vagos, e gera uma planilha final ordenada por profissional + data + hora
    (Cenario A - sugestoes - primeiro, Cenario B - vagos sem sugestao - depois).

.DESCRIPTION
    Nao chama baixar_agenda.ps1 nem db_manager.ps1 diretamente (ver
    manifest.json -> dependencies.not_called_directly). Reimplementa o mesmo
    protocolo HTTP de login+export+download documentado em
    simples-agenda-download/SKILL.md, com o guardrail de data invertido
    (aqui a data tem que ser hoje ou futura), e reusa credential-manager com
    os MESMOS service_name (simples-agenda, mysql-agenda-db) ja usados pelas
    outras skills - nao pede senha de novo se ja estiver salva.

    Por padrao NAO grava nada em sc0990 (tabela real do 4clinics em producao)
    - o cruzamento roda em memoria a partir do .xls baixado + leituras
    (SELECT) em sb5990/sbx990. Ver manifest.json -> sc0_write_policy e
    SKILL.md para o motivo (sa1990/sa3990/sa5990 vazias no banco de
    referencia). Use -SyncToSc0 para ligar a gravacao (com valores fixos de
    pacienteId/tipoConsultaId/planoSaudeId).

.PARAMETER Email
    Login do Simples Agenda. Senha carregada do credential-manager
    (service=simples-agenda) ou solicitada uma vez.

.PARAMETER DataIni
    Data inicial do periodo futuro (dd/MM/yyyy). Tem que ser >= hoje.

.PARAMETER DataFim
    Data final do periodo futuro (dd/MM/yyyy). Tem que ser >= DataIni.

.EXAMPLE
    .\gerar_disponibilidade.ps1 -Email voce@email.com -DataIni 15/09/2026 -DataFim 30/09/2026

.EXAMPLE
    # gravando tambem em sc0990 (opt-in, ver SKILL.md antes de usar)
    .\gerar_disponibilidade.ps1 -Email voce@email.com -DataIni 15/09/2026 -DataFim 30/09/2026 -SyncToSc0

.NOTES
    Codigos de saida: 0 OK | 1 AUTH_FAILED | 2 NO_AVAILABILITY |
                      3 CORRUPTED_FILE | 4 INVALID_INPUT | 5 CONNECTION_ERROR |
                      6 RATE_LIMITED | 7 DB_ERROR | 8 EXCEL_COM_UNAVAILABLE |
                      9 MYSQLSH_NOT_FOUND
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Email,
    [string]$Senha,
    [string]$DataIni,
    [string]$DataFim,
    [string]$CodUsuarioArray = '',

    [int]$SemanasHistorico = 4,
    [int]$DuracaoPadraoMin = 50,

    [switch]$SyncToSc0,
    [int]$PacienteIdPadrao = 0,
    [int]$EspecIdPadraoFallback = 0,
    [int]$TipoConsultaIdPadrao = 1,
    [int]$PlanoSaudeIdPadrao = 1,

    [string]$DbHost = '127.0.0.1',
    [int]$DbPort = 3306,
    [string]$DbUser = 'root',
    [string]$Database = '4clinics',
    [string]$DbPassword,
    [string]$EmpresaId = '001',
    [string]$FilialId = '01',
    [string]$FilialOrigemId = '01',

    [string]$OutputPath,
    [switch]$Json,

    [string]$EnviarPara = 'amazonasterapiafisio@gmail.com',
    [string]$EmailErroPara = 'projetvs.pdi@gmail.com',
    [string]$EmailService = 'simples-agenda',
    [switch]$SemEnvioEmail
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------ credential-manager
$CredManagerScript = Join-Path $PSScriptRoot '..\..\credential-manager\scripts\credential_manager.ps1'
$credManagerDisponivel = Test-Path $CredManagerScript

function Invoke-CredManager {
    param([hashtable]$CredArgs)
    & $CredManagerScript @CredArgs
}

# ------------------------------------------------------------------- helpers
function Remove-Diacritics {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString().Normalize([Text.NormalizationForm]::FormC).Trim().ToUpperInvariant()
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

function Get-SqlLiteral {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return 'NULL' }
    $escaped = $Value.ToString().Replace("\", "\\").Replace("'", "''")
    return "'$escaped'"
}

# --------------------------------------------------------------- validacao e defaults
$hoje = [datetime]::Now.Date

# Se datas nao foram informadas, usar defaults: hoje ate hoje+7 dias
if ([string]::IsNullOrWhiteSpace($DataIni) -and [string]::IsNullOrWhiteSpace($DataFim)) {
    $dIni = $hoje
    $dFim = $hoje.AddDays(7)
    $DataIni = $dIni.ToString('dd/MM/yyyy')
    $DataFim = $dFim.ToString('dd/MM/yyyy')
    Write-Output "[*] Datas nao informadas - usando defaults: $DataIni a $DataFim (hoje ate hoje+7 dias)."
} else {
    # Se uma foi informada mas nao a outra, erro
    if ([string]::IsNullOrWhiteSpace($DataIni) -or [string]::IsNullOrWhiteSpace($DataFim)) {
        Write-Output "[ERRO] Ambas as datas (DataIni e DataFim) sao obrigatorias se uma delas for informada."
        Write-Output "       Use ambas ou nenhuma (sera usado default: hoje ate hoje+7 dias)."
        exit 4
    }

    # Ambas foram informadas - validar formato e valores
    $dIni = Test-DataValida $DataIni
    if ($null -eq $dIni) {
        Write-Output "[ERRO] Data Inicio invalida: '$DataIni'. Use dd/mm/yyyy (exemplo: 15/09/2026)."
        exit 4
    }
    $dFim = Test-DataValida $DataFim
    if ($null -eq $dFim) {
        Write-Output "[ERRO] Data Fim invalida: '$DataFim'. Use dd/mm/yyyy (exemplo: 30/09/2026)."
        exit 4
    }
    if ($dIni -lt $hoje) {
        Write-Output "[ERRO] Data Inicio precisa ser hoje ou no futuro."
        Write-Output "       Hoje: $($hoje.ToString('dd/MM/yyyy')) | Informada: $DataIni"
        exit 4
    }
    if ($dFim -lt $dIni) {
        Write-Output "[ERRO] Data Fim deve ser maior ou igual a Data Inicio."
        Write-Output "       Data Inicio: $DataIni | Data Fim: $DataFim"
        exit 4
    }
}

# ---------------------------------------------------------- mysqlsh disponivel
$MysqlshCmd = Get-Command mysqlsh.exe -ErrorAction SilentlyContinue
if (-not $MysqlshCmd) {
    Write-Output "[ERRO] mysqlsh.exe nao encontrado no PATH. Instale o MySQL Shell."
    exit 9
}

# ------------------------------------------------------------------- senhas
if ([string]::IsNullOrEmpty($Senha) -and $credManagerDisponivel) {
    $jsonOut = Invoke-CredManager -CredArgs @{ Action = 'load'; Username = $Email; Service = 'simples-agenda'; Json = $true }
    try {
        $parsed = $jsonOut | ConvertFrom-Json
        if ($parsed.found) {
            $Senha = $parsed.password
            Write-Output "[*] Credenciais do Simples Agenda carregadas automaticamente para $Email."
        }
    } catch { }
}
$senhaVeioDoPrompt = $false
if ([string]::IsNullOrEmpty($Senha)) {
    $sec = Read-Host -Prompt 'Senha Simples Agenda' -AsSecureString
    $Senha = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    $senhaVeioDoPrompt = $true
}
if ([string]::IsNullOrEmpty($Senha)) {
    Write-Output "[ERRO] Senha do Simples Agenda e obrigatoria."
    exit 4
}
if ($credManagerDisponivel -and ($senhaVeioDoPrompt -or $PSBoundParameters.ContainsKey('Senha'))) {
    Invoke-CredManager -CredArgs @{ Action = 'save'; Username = $Email; Password = $Senha; Service = 'simples-agenda' } | Out-Null
}

if ([string]::IsNullOrEmpty($DbPassword) -and $credManagerDisponivel) {
    $jsonOut = Invoke-CredManager -CredArgs @{ Action = 'load'; Username = $DbUser; Service = 'mysql-agenda-db'; Json = $true }
    try {
        $parsed = $jsonOut | ConvertFrom-Json
        if ($parsed.found) {
            $DbPassword = $parsed.password
            Write-Output "[*] Senha do MySQL carregada automaticamente (usuario $DbUser)."
        }
    } catch { }
}
if ([string]::IsNullOrEmpty($DbPassword)) {
    Write-Output "[ERRO] Senha do MySQL nao informada (-DbPassword) e nenhuma salva no credential-manager (service=mysql-agenda-db)."
    exit 7
}

# ============================================================ 1) LOGIN + EXPORT
$base = 'https://www.simplesagenda.com.br'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

function Get-Text($resp) {
    $c = $resp.Content
    if ($c -is [byte[]]) { return [System.Text.Encoding]::GetEncoding('iso-8859-1').GetString($c) }
    return [string]$c
}
function Get-Tag($xml, $tag) {
    $m = [regex]::Match($xml, ('<{0}>(.*?)</{0}>' -f $tag), 'Singleline')
    if (-not $m.Success) { return $null }
    return ($m.Groups[1].Value -replace '<!\[CDATA\[', '' -replace '\]\]>', '').Trim()
}
function Get-HttpStatus($err) {
    if ($err.Exception.Response) { return [int]$err.Exception.Response.StatusCode }
    return 0
}
function Exit-OnHttpError($err, $contexto) {
    $status = Get-HttpStatus $err
    if ($status -eq 429) {
        Write-Output "[ERRO] Muitas requisicoes em sequencia (HTTP 429). Aguarde alguns minutos."
        exit 6
    }
    Write-Output "[ERRO] Falha de conexao $contexto. Verifique sua internet e tente novamente."
    Write-Output ("       " + $err.Exception.Message)
    exit 5
}

try {
    Write-Output "[*] Autenticando como $Email..."
    $null = Invoke-WebRequest -Uri "$base/autenticacao_usuario.php" `
        -SessionVariable sess -UserAgent $ua -UseBasicParsing -TimeoutSec 30

    $login = Invoke-WebRequest -Uri "$base/crud_autenticacao.php" -Method POST `
        -WebSession $sess -UserAgent $ua -UseBasicParsing -TimeoutSec 30 `
        -Headers @{ 'X-Requested-With' = 'XMLHttpRequest'; 'Referer' = "$base/autenticacao_usuario.php" } `
        -Body @{ acao = 'autentica_usuario'; login = $Email; senha = $Senha; conectado = '1'; captcha_resposta = '' }
} catch { Exit-OnHttpError $_ "no login" }

$lb = Get-Text $login
$houveErro = Get-Tag $lb 'houve_erro'
if ($null -eq $houveErro) {
    Write-Output "[ERRO] Resposta de login em formato inesperado (sem <houve_erro>). O Simples Agenda pode ter mudado o endpoint."
    exit 1
}
if ($houveErro -ne 'N') {
    if ((Get-Tag $lb 'requer_captcha') -eq 'S') {
        Write-Output "[ERRO] O site esta pedindo CAPTCHA no login."
        Write-Output ("       Pergunta: " + (Get-Tag $lb 'captcha_pergunta'))
        Write-Output "       Faca o login manualmente no navegador e tente de novo mais tarde."
        exit 1
    }
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

try {
    Write-Output "[*] Exportando agenda FUTURA de $DataIni ate $DataFim..."
    $exportResp = Invoke-WebRequest -Uri "$base/crud.php" -Method POST -WebSession $sess `
        -UserAgent $ua -UseBasicParsing -TimeoutSec 120 `
        -Headers @{ 'X-Requested-With' = 'XMLHttpRequest'; 'Referer' = "$base/agendamento.php" } `
        -Body @{
            acao              = 'exporta_agendamentos'
            dataIni           = $DataIni
            dataFim           = $DataFim
            cod_usuario_array = $CodUsuarioArray
            cod_cliente       = ''
            cod_produto       = ''
        }
    $body = Get-Text $exportResp
} catch { Exit-OnHttpError $_ "durante a exportacao" }

if ($body -match 'ExpirouConexao') {
    Write-Output "[ERRO] Sessao expirada no servidor. Execute o script novamente."
    exit 1
}
$nome = Get-Tag $body 'nome_excel'
if ([string]::IsNullOrWhiteSpace($nome)) {
    Write-Output "[AVISO] Nenhum agendamento futuro encontrado no Simples Agenda para $DataIni ate $DataFim."
    Write-Output "        Seguindo mesmo assim: todos os horarios disponiveis (sb5990) virao como Cenario B."
    $futureRows = @()
} else {
    Write-Output "[OK] Excel gerado: $nome"

    $tmpXls = Join-Path $env:TEMP ("agenda_futura_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".xls")
    try {
        Invoke-WebRequest -Uri ("$base/" + $nome) -WebSession $sess -UserAgent $ua `
            -UseBasicParsing -TimeoutSec 180 -OutFile $tmpXls
    } catch {
        if (Test-Path $tmpXls) { Remove-Item $tmpXls -Force }
        Write-Output "[ERRO] Download interrompido. Tente novamente."
        Exit-OnHttpError $_ "no download do arquivo"
    }
    $size = (Get-Item $tmpXls).Length
    $magic = [BitConverter]::ToString((Get-Content -Path $tmpXls -Encoding Byte -TotalCount 8)) -replace '-', ''
    if ($size -eq 0 -or $magic -ne 'D0CF11E0A1B11AE1') {
        Write-Output "[ERRO] Download interrompido ou arquivo corrompido ($size bytes, magic $magic)."
        Remove-Item $tmpXls -Force -ErrorAction SilentlyContinue
        exit 3
    }
    Write-Output ("[OK] Agenda futura baixada: " + $size.ToString('N0') + " bytes")
}

# ============================================================ 2) EXCEL COM
function New-ExcelCom {
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        return $excel
    } catch {
        Write-Output "[ERRO] Microsoft Excel (COM) nao disponivel: $_"
        exit 8
    }
}

$ExpectedHeaders = @('Data', 'Cliente', 'Telefone', 'Email', 'Servico', 'Observacao', 'Profissional', 'Status', 'Data Acao', 'Executado por')

if ($nome) {
    $excel = New-ExcelCom
    $wb = $null
    $futureRows = @()
    try {
        $wb = $excel.Workbooks.Open((Resolve-Path $tmpXls).Path)
        $ws = $wb.Sheets.Item(1)
        $used = $ws.UsedRange
        $rowCount = $used.Rows.Count

        for ($c = 1; $c -le 10; $c++) {
            $header = Remove-Diacritics ($ws.Cells.Item(1, $c).Text.Trim())
            if ($header -ne (Remove-Diacritics $ExpectedHeaders[$c - 1])) {
                Write-Output "[ERRO] Layout inesperado: coluna $c e '$header', esperava '$($ExpectedHeaders[$c - 1])'."
                Write-Output "       O Simples Agenda pode ter mudado o formato de exportacao."
                exit 3
            }
        }

        for ($r = 2; $r -le $rowCount; $r++) {
            $dataTxt = $ws.Cells.Item($r, 1).Text.Trim()
            $clienteTxt = $ws.Cells.Item($r, 2).Text.Trim()
            if ([string]::IsNullOrWhiteSpace($dataTxt) -or [string]::IsNullOrWhiteSpace($clienteTxt)) { continue }

            $dt = [datetime]::MinValue
            $parsedOk = $false
            foreach ($fmt in @('dd/MM/yyyy HH:mm', 'dd/MM/yyyy H:mm', 'dd/MM/yyyy')) {
                if ([datetime]::TryParseExact($dataTxt, $fmt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) {
                    $parsedOk = $true; break
                }
            }
            if (-not $parsedOk) {
                Write-Output "[AVISO] Linha $r ignorada: data invalida '$dataTxt'."
                continue
            }

            $futureRows += [PSCustomObject]@{
                DataHora     = $dt
                Cliente      = $clienteTxt
                Telefone     = $ws.Cells.Item($r, 3).Text.Trim()
                Email        = $ws.Cells.Item($r, 4).Text.Trim()
                Servico      = $ws.Cells.Item($r, 5).Text.Trim()
                Observacao   = $ws.Cells.Item($r, 6).Text.Trim()
                Profissional = $ws.Cells.Item($r, 7).Text.Trim()
                Status       = $ws.Cells.Item($r, 8).Text.Trim()
            }
        }
    } finally {
        if ($wb) { $wb.Close($false) }
        $excel.Quit()
        if ($wb) { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wb) | Out-Null }
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
    }
    Remove-Item -Path $tmpXls -Force -ErrorAction SilentlyContinue
    Write-Output "[OK] $($futureRows.Count) agendamento(s) futuro(s) lido(s)."
}

# ============================================================ 3) MySQL
function Invoke-MySql {
    param([string]$Sql)
    $tmpSql = [System.IO.Path]::GetTempFileName() + ".sql"
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpSql, $Sql, $utf8NoBom)
        $mysqlArgs = @('--sql', '-h', $DbHost, '-P', $DbPort, '-u', $DbUser, "-p$DbPassword", "--schema=$Database", '--json=raw', '--file', $tmpSql)

        # NOTA (bug real, 08/09/2026 - causa raiz de nomes acentuados errados em
        # TODA a skill): capturar a saida do mysqlsh com "& mysqlsh.exe ... 2>&1"
        # faz o PowerShell decodificar os bytes do processo filho usando
        # [Console]::OutputEncoding, que neste ambiente e CP850 (ibm850) - o
        # mysqlsh emite UTF-8, entao "Galvão" chegava como "Galv├úo" em memoria,
        # ANTES de qualquer escrita em planilha. Isso nao era so cosmetico: a
        # chave de comparacao do paciente ficava corrompida e nao batia com a
        # chave vinda da agenda futura (lida via Excel COM, essa sim correta),
        # fazendo a exclusao de "ja tem agendamento futuro" falhar EXATAMENTE
        # para os pacientes com acento no nome - e so para eles (caso real: a
        # paciente Juliana Quintelo Galvão, ja agendada 09/09 08:00, foi sugerida
        # de novo para 09/09 13:00, enquanto os outros 14 candidatos sem acento
        # eram excluidos corretamente).
        # Fix: ler o stdout do processo com UTF-8 EXPLICITO, via
        # System.Diagnostics.Process, em vez de depender do encoding do console
        # (verificado: funciona igual em "powershell -File" e "powershell
        # -Command", ao contrario de mexer em [Console]::OutputEncoding, que
        # depende do contexto de invocacao).
        $argStr = ($mysqlArgs | ForEach-Object { '"' + ("$_" -replace '"', '\"') + '"' }) -join ' '
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $MysqlshCmd.Source
        $psi.Arguments = $argStr
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = $utf8NoBom
        $psi.StandardErrorEncoding = $utf8NoBom
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdOut = $proc.StandardOutput.ReadToEnd()
        $stdErr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $output = @(($stdOut + "`n" + $stdErr) -split "`r?`n")

        $results = @()
        foreach ($line in $output) {
            $line = $line.Trim()
            if ([string]::IsNullOrEmpty($line)) { continue }
            try {
                $obj = $line | ConvertFrom-Json
                if ($obj.PSObject.Properties.Name -contains 'warning') { continue }
                if ($obj.PSObject.Properties.Name -contains 'error') { throw "Erro MySQL: $($obj.error)" }
                $results += $obj
            } catch [System.Management.Automation.RuntimeException] { throw }
            catch { }
        }
        if ($exitCode -ne 0 -and $results.Count -eq 0) {
            throw "mysqlsh retornou codigo $exitCode sem resultado JSON. Saida: $($output -join ' | ')"
        }
        return $results
    } finally {
        Remove-Item -Path $tmpSql -Force -ErrorAction SilentlyContinue
    }
}

try {
    $null = Invoke-MySql -Sql "SELECT 1;"
} catch {
    Write-Output "[ERRO] Falha ao conectar no MySQL ($DbHost`:$DbPort, usuario $DbUser, banco $Database)."
    Write-Output "       $_"
    exit 7
}

# ------------------------------------------------- de/para profissionais/especialidades
Write-Output "[*] Carregando de/para de profissionais (sa2990) e especialidades (sa4990)..."
$profRes = Invoke-MySql -Sql "SELECT id, nome, profSimplesAgId FROM sa2990 WHERE empresaId = '$EmpresaId' AND ativo = '1';"
$profRows = if ($profRes[0].hasData) { $profRes[0].rows } else { @() }
$profByKey = @{}
foreach ($p in $profRows) {
    $keyNome = Remove-Diacritics $p.nome
    $keySimplesAg = Remove-Diacritics $p.profSimplesAgId
    if ($keyNome) { $profByKey[$keyNome] = $p }
    if ($keySimplesAg -and -not $profByKey.ContainsKey($keySimplesAg)) { $profByKey[$keySimplesAg] = $p }
}

$especRes = Invoke-MySql -Sql "SELECT id, descricao FROM sa4990 WHERE empresaId = '$EmpresaId' AND ativo = '1';"
$especRows = if ($especRes[0].hasData) { $especRes[0].rows } else { @() }
$especByKey = @{}
foreach ($e in $especRows) {
    $k = Remove-Diacritics $e.descricao
    if ($k) { $especByKey[$k] = $e }
}

function Resolve-Prof {
    param([string]$Nome)
    $k = Remove-Diacritics $Nome
    if ($profByKey.ContainsKey($k)) { return $profByKey[$k] }
    return $null
}
function Resolve-Espec {
    param([string]$Servico)
    $k = Remove-Diacritics $Servico
    if ($especByKey.ContainsKey($k)) { return $especByKey[$k] }
    return $null
}

# Mapeia cada linha da agenda futura para o profId resolvido; avisa 1x por nome nao mapeado
$profNaoMapeados = New-Object System.Collections.Generic.HashSet[string]
$futureRowsMapped = @()
foreach ($row in $futureRows) {
    $p = Resolve-Prof $row.Profissional
    if ($null -eq $p) {
        if ($profNaoMapeados.Add($row.Profissional)) {
            Write-Output "[AVISO] Profissional '$($row.Profissional)' nao encontrado em sa2990 - excluido do cruzamento."
        }
        continue
    }
    $futureRowsMapped += [PSCustomObject]@{
        ProfId       = [int]$p.id
        ProfNome     = $p.nome
        DataHora     = $row.DataHora
        Cliente      = $row.Cliente
        Telefone     = $row.Telefone
        Email        = $row.Email
        Servico      = $row.Servico
        Observacao   = $row.Observacao
        Status       = $row.Status
    }
}

# Profissionais relevantes: todos os mapeados na agenda futura, MAIS qualquer
# filtro explicito (-CodUsuarioArray) que o usuario tenha pedido mesmo sem
# agendamento futuro ainda (ele quer ver os buracos justamente pq nao tem nada agendado).
$profIdsRelevantes = @($futureRowsMapped | Select-Object -ExpandProperty ProfId -Unique)
if ($profIdsRelevantes.Count -eq 0) {
    # sem nenhum agendamento futuro mapeado: usa todos os profissionais ativos
    $profIdsRelevantes = @($profRows | ForEach-Object { [int]$_.id })
}

if ($profIdsRelevantes.Count -eq 0) {
    Write-Output "[ERRO] Nenhum profissional resolvido (sa2990 vazia ou sem correspondencia). Nada a cruzar."
    exit 2
}

# ============================================================ 4) sb5990 (disponibilidade)
Write-Output "[*] Carregando disponibilidade semanal (sb5990)..."
$profIdList = ($profIdsRelevantes -join ',')
# NOTA (confirmado contra o banco real em 08/09/2026): sb5990.filialId vem
# vazio ('') nos dados existentes, ao contrario de sc0990/sbx990 que usam
# '01'. filialId nao faz parte de nenhuma FK de sb5990 (so filialOrigemId
# faz), entao filtrar por -FilialId aqui descartaria toda a disponibilidade
# silenciosamente. Filtra so por empresaId; se algum dia existir mais de uma
# filial com disponibilidade cadastrada, sera preciso revisar isso.
#
# NOTA 2 (bug real encontrado em teste, 08/09/2026): PowerShell 5.1 le este
# .ps1 em UTF-8 sem BOM como se fosse ANSI/cp1252, corrompendo o "i" com
# acento do literal do ENUM ('Disponível' vira 'Dispon??vel') - a comparacao
# nunca bateria com nenhuma linha, retornando 0 disponibilidade SEMPRE, sem
# erro nenhum. Monta o literal via [char] (codepoint Unicode), imune a
# codificacao do arquivo - mesmo padrao ja usado em outras skills deste
# projeto para texto acentuado (ver memoria "Encoding UTF-8 em PowerShell ->
# MySQL").
$acentoI = [char]0x00ED  # 'i' com acento agudo (U+00ED)
$statusDisponivel = "Dispon" + $acentoI + "vel"
$sb5Res = Invoke-MySql -Sql "SELECT profId, diaSemana, hora FROM sb5990 WHERE empresaId = '$EmpresaId' AND profId IN ($profIdList) AND status = $(Get-SqlLiteral $statusDisponivel);"
$sb5Rows = if ($sb5Res[0].hasData) { $sb5Res[0].rows } else { @() }

if ($sb5Rows.Count -eq 0) {
    Write-Output "[ERRO] Nenhuma disponibilidade cadastrada em sb5990 para os profissionais informados."
    exit 2
}

# indice diaSemana(1..7) -> profId -> lista de horas 'HH:mm'
$sb5ByDiaProf = @{}
foreach ($s in $sb5Rows) {
    $dia = [int]$s.diaSemana
    $profIdCur = [int]$s.profId
    $horaStr = ([string]$s.hora).Substring(0, 5)  # 'HH:mm:ss' -> 'HH:mm'
    $key = "$dia|$profIdCur"
    if (-not $sb5ByDiaProf.ContainsKey($key)) { $sb5ByDiaProf[$key] = @() }
    $sb5ByDiaProf[$key] += $horaStr
}

# ============================================================ 5) Ocupacao (agenda futura em memoria)
# .NET DayOfWeek: Sunday=0..Saturday=6. sb5990: 1=Seg..7=Dom.
function Get-DiaSemanaSB5 {
    param([datetime]$Data)
    $dow = [int]$Data.DayOfWeek
    if ($dow -eq 0) { return 7 }
    return $dow
}

$ocupado = New-Object System.Collections.Generic.HashSet[string]
foreach ($row in $futureRowsMapped) {
    if ((Remove-Diacritics $row.Status) -eq 'CANCELADO') { continue }
    $key = "$($row.ProfId)|$($row.DataHora.ToString('yyyy-MM-dd'))|$($row.DataHora.ToString('HH:mm'))"
    [void]$ocupado.Add($key)
}

# ============================================================ 6) Calcula buracos
Write-Output "[*] Calculando horarios vagos entre $DataIni e $DataFim..."
$buracos = @()
$diaCursor = $dIni
while ($diaCursor -le $dFim) {
    $diaSemana = Get-DiaSemanaSB5 $diaCursor
    foreach ($profIdCur in $profIdsRelevantes) {
        $key = "$diaSemana|$profIdCur"
        if (-not $sb5ByDiaProf.ContainsKey($key)) { continue }
        foreach ($hora in $sb5ByDiaProf[$key]) {
            $ocKey = "$profIdCur|$($diaCursor.ToString('yyyy-MM-dd'))|$hora"
            if ($ocupado.Contains($ocKey)) { continue }
            $buracos += [PSCustomObject]@{
                ProfId = $profIdCur
                Data   = $diaCursor
                Hora   = $hora
            }
        }
    }
    $diaCursor = $diaCursor.AddDays(1)
}
Write-Output "[OK] $($buracos.Count) horario(s) vago(s) encontrado(s) em sb5990 no periodo."

# ============================================================ 7) Cenario A: sugestoes (sbx990)
# Nao basta achar "um paciente que ja foi atendido por esse profissional" - o
# paciente tem um TURNO HABITUAL (a maioria das pessoas so pode ir de manha OU
# de tarde, por causa de trabalho/escola/outros compromissos). Sugerir alguem
# que sempre agenda de tarde para um buraco de manha e uma sugestao inutil na
# pratica, mesmo que "o nome bata". Por isso o historico e lido linha a linha
# (nao so o MAX) para calcular o turno predominante de cada paciente, e o
# casamento buraco<->paciente prioriza compatibilidade de turno.
Write-Output "[*] Buscando pacientes recorrentes nas ultimas $SemanasHistorico semanas (sbx990)..."
$dataLimiteHistorico = $hoje.AddDays(-7 * $SemanasHistorico).ToString('yyyy-MM-dd 00:00:00')

function Get-Turno {
    param([string]$HoraHHmm)
    # HoraHHmm no formato 'HH:mm'. Manha: 08:00-11:59 | Tarde: 12:00-18:59.
    # Fora dessa faixa (bem raro) cai em 'Tarde' por seguranca (nao ha turno
    # 'Noite' modelado ainda - ver Limitacoes no SKILL.md se isso incomodar).
    $h = [int]($HoraHHmm.Split(':')[0])
    if ($h -lt 12) { return 'Manha' }
    return 'Tarde'
}

# Pacientes que JA TEM agendamento futuro no periodo, com QUALQUER profissional.
# Regra pedida pelo usuario (08/09/2026) depois de ver a paciente Juliana, ja
# agendada com a Jasmara em 09/09 08:00, ser sugerida de novo para 09/09 13:00:
# se o paciente ja esta alocado no periodo, ele nao precisa ser chamado - o
# objetivo da skill e achar quem NAO tem agenda futura. Antes essa exclusao era
# por profissional (um paciente agendado com a ENA ainda podia ser sugerido para
# a LUCIANA); agora e global no periodo.
#
# Agendamento CANCELADO nao conta como alocacao - pelo contrario, quem teve a
# sessao cancelada e justamente quem vale a pena reencaixar (mesmo criterio ja
# usado no calculo de $ocupado, que tambem ignora cancelados).
$jaAgendadosNoPeriodo = New-Object System.Collections.Generic.HashSet[string]
foreach ($fr in $futureRowsMapped) {
    if ((Remove-Diacritics $fr.Status) -eq 'CANCELADO') { continue }
    [void]$jaAgendadosNoPeriodo.Add((Remove-Diacritics $fr.Cliente))
}
Write-Output "[*] $($jaAgendadosNoPeriodo.Count) paciente(s) ja tem agendamento futuro no periodo - nao serao sugeridos."

$candidatosPorProf = @{}   # profId -> lista de candidatos (nao consumida ainda), ordenada por mais recente
foreach ($profIdCur in $profIdsRelevantes) {
    $profNome = ($profRows | Where-Object { [int]$_.id -eq $profIdCur } | Select-Object -First 1).nome
    if (-not $profNome) { continue }

    # Traz TODAS as linhas (nao so o MAX) para poder calcular o turno predominante.
    $sql = @"
SELECT cliente, telefone, email, dataAgenda
FROM sbx990
WHERE empresaId = '$EmpresaId' AND filialId = '$FilialId'
  AND profissional = $(Get-SqlLiteral $profNome)
  AND status = 'Atendido'
  AND dataAgenda >= '$dataLimiteHistorico'
ORDER BY dataAgenda DESC;
"@
    $res = Invoke-MySql -Sql $sql
    $rows = if ($res[0].hasData) { $res[0].rows } else { @() }

    # Agrupa por cliente (case-insensitive/sem-acento) para calcular o turno
    # predominante, o HORARIO especifico mais frequente (nao so o turno amplo -
    # ver Get-HoraHabitual abaixo) e guardar o atendimento mais recente de cada um.
    $porCliente = @{}
    foreach ($r in $rows) {
        $keyCliente = Remove-Diacritics $r.cliente
        if ($jaAgendadosNoPeriodo.Contains($keyCliente)) { continue }
        if (-not $porCliente.ContainsKey($keyCliente)) {
            $porCliente[$keyCliente] = [PSCustomObject]@{
                Cliente           = $r.cliente
                Telefone          = $r.telefone
                Email             = $r.email
                UltimoAtendimento = $r.dataAgenda
                ContManha         = 0
                ContTarde         = 0
                HistHoras         = @{}   # 'HH:mm' -> quantas vezes o cliente veio nesse horario
            }
        }
        $c = $porCliente[$keyCliente]
        $horaVisita = ([string]$r.dataAgenda).Substring(11, 5)   # 'yyyy-MM-dd HH:mm:ss' -> 'HH:mm'
        if ((Get-Turno $horaVisita) -eq 'Manha') { $c.ContManha++ } else { $c.ContTarde++ }
        if (-not $c.HistHoras.ContainsKey($horaVisita)) { $c.HistHoras[$horaVisita] = 0 }
        $c.HistHoras[$horaVisita]++
    }

    $candidatos = @()
    foreach ($c in $porCliente.Values) {
        $turnoPredominante = if ($c.ContManha -gt $c.ContTarde) { 'Manha' }
                             elseif ($c.ContTarde -gt $c.ContManha) { 'Tarde' }
                             else { 'Indefinido' }  # empate (ex: so 1 visita de cada, ou so 1 visita total sem clareza)

        # Horario mais frequente do historico (moda); empate desempata pelo
        # mais recente. E' esse horario, nao so o turno amplo, que decide QUAL
        # buraco (14:00 ou 15:00, por exemplo) fica melhor para esse paciente -
        # sem isso, dois pacientes do mesmo turno podiam ser trocados entre si
        # (ver caso real: paciente de habito 15:00 foi encaixado as 14:00 e
        # vice-versa, so porque os dois eram "Tarde").
        $horaMaisRecente = ([string]$c.UltimoAtendimento).Substring(11, 5)
        $maxCount = ($c.HistHoras.Values | Measure-Object -Maximum).Maximum
        $horasComMax = @($c.HistHoras.Keys | Where-Object { $c.HistHoras[$_] -eq $maxCount })
        $horaHabitual = if ($horasComMax -contains $horaMaisRecente) { $horaMaisRecente } else { $horasComMax[0] }

        $candidatos += [PSCustomObject]@{
            Cliente           = $c.Cliente
            Telefone          = $c.Telefone
            Email             = $c.Email
            UltimoAtendimento = $c.UltimoAtendimento
            TurnoHabitual     = $turnoPredominante
            HoraHabitual      = $horaHabitual
            Usado             = $false
        }
    }
    # mais recente primeiro (mesmo criterio de prioridade de antes; a
    # proximidade de horario e' aplicada depois, no momento de casar com cada
    # buraco especifico - ver Get-DiferencaMinutos)
    $candidatosPorProf[$profIdCur] = @($candidatos | Sort-Object UltimoAtendimento -Descending)
}

function Get-DiferencaMinutos {
    # Distancia absoluta em minutos entre dois horarios 'HH:mm', usada para
    # achar o candidato cujo horario habitual mais se aproxima do buraco.
    param([string]$HoraA, [string]$HoraB)
    $ta = [int]($HoraA.Split(':')[0]) * 60 + [int]($HoraA.Split(':')[1])
    $tb = [int]($HoraB.Split(':')[0]) * 60 + [int]($HoraB.Split(':')[1])
    return [Math]::Abs($ta - $tb)
}

# ============================================================ 8) Monta Cenario A / B
# Para cada buraco, tenta casar com o candidato (ainda nao usado) cujo
# HORARIO HABITUAL fica mais PROXIMO do horario vago - nao so o turno amplo
# (Manha/Tarde). Dois pacientes do mesmo turno (ex: um de habito 14:00, outro
# de habito 15:00) tem que ser desempatados pelo horario especifico, senao a
# skill pode trocar os dois entre si (caso real encontrado pelo usuario:
# paciente de 15:00 encaixada as 14:00 e vice-versa, so porque os dois eram
# "Tarde"). So se NENHUM candidato do turno certo sobrar e' que usa um
# candidato de turno diferente - e nesse caso a planilha AVISA na Observacao,
# em vez de sugerir silenciosamente alguem no turno errado.
#
# Processa os buracos em ordem cronologica (por profissional) para o
# casamento guloso (greedy) ficar previsivel; com poucos candidatos por
# profissional (caso tipico aqui) isso da o mesmo resultado que uma
# otimizacao global completa, sem precisar de um algoritmo de emparelhamento
# bipartido so para isso.
$buracos = $buracos | Sort-Object ProfId, Data, Hora

$cenarioA = @()
$cenarioB = @()
foreach ($b in $buracos) {
    $profNome = ($profRows | Where-Object { [int]$_.id -eq $b.ProfId } | Select-Object -First 1).nome
    $turnoBuraco = Get-Turno $b.Hora
    $lista = $candidatosPorProf[$b.ProfId]

    $escolhido = $null
    $divergenciaTurno = $false

    if ($lista) {
        # 1a tentativa: candidatos do MESMO turno (ou 'Indefinido' - historico
        # insuficiente para saber, entao nao conta como divergencia real),
        # escolhendo o de HoraHabitual mais proxima do horario do buraco;
        # empate de distancia desempata pelo atendimento mais recente.
        $compativeis = @($lista | Where-Object { -not $_.Usado -and ($_.TurnoHabitual -eq $turnoBuraco -or $_.TurnoHabitual -eq 'Indefinido') })
        if ($compativeis.Count -gt 0) {
            $escolhido = $compativeis |
                Sort-Object @{Expression = { Get-DiferencaMinutos $_.HoraHabitual $b.Hora }}, @{Expression = 'UltimoAtendimento'; Descending = $true} |
                Select-Object -First 1
        }
        if (-not $escolhido) {
            # 2a tentativa: qualquer candidato restante (turno diferente), mesmo
            # criterio de proximidade de horario - mas sinaliza a divergencia
            $restantes = @($lista | Where-Object { -not $_.Usado })
            if ($restantes.Count -gt 0) {
                $escolhido = $restantes |
                    Sort-Object @{Expression = { Get-DiferencaMinutos $_.HoraHabitual $b.Hora }}, @{Expression = 'UltimoAtendimento'; Descending = $true} |
                    Select-Object -First 1
                if ($escolhido) { $divergenciaTurno = $true }
            }
        }
    }

    if ($escolhido) {
        $escolhido.Usado = $true
        $distanciaMin = Get-DiferencaMinutos $escolhido.HoraHabitual $b.Hora
        $obs = if ($divergenciaTurno) {
            "ATENCAO: paciente costuma agendar no turno da $($escolhido.TurnoHabitual) (por volta de $($escolhido.HoraHabitual)) - este horario e de $turnoBuraco. Confirmar disponibilidade antes de agendar."
        } elseif ($distanciaMin -eq 0) {
            "Paciente recorrente sugerido (ultimas $SemanasHistorico semanas) - horario igual ao habitual dele ($($escolhido.HoraHabitual))."
        } else {
            "Paciente recorrente sugerido (ultimas $SemanasHistorico semanas) - horario habitual dele: $($escolhido.HoraHabitual) ($distanciaMin min de diferenca)."
        }
        $cenarioA += [PSCustomObject]@{
            Cenario           = 'A'
            Profissional      = $profNome
            Data              = $b.Data
            Hora              = $b.Hora
            ClienteSugerido   = $escolhido.Cliente
            Telefone          = $escolhido.Telefone
            Email             = $escolhido.Email
            UltimoAtendimento = $escolhido.UltimoAtendimento
            TurnoHabitual     = "$($escolhido.HoraHabitual) ($($escolhido.TurnoHabitual))"
            Observacao        = $obs
        }
    } else {
        $cenarioB += [PSCustomObject]@{
            Cenario           = 'B'
            Profissional      = $profNome
            Data              = $b.Data
            Hora              = $b.Hora
            ClienteSugerido   = ''
            Telefone          = ''
            Email             = ''
            UltimoAtendimento = ''
            TurnoHabitual     = ''
            Observacao        = 'Horario vago - sem sugestao'
        }
    }
}
$divergentes = @($cenarioA | Where-Object { $_.Observacao -like 'ATENCAO:*' }).Count
Write-Output "[OK] Cenario A (sugestoes): $($cenarioA.Count) [$divergentes com divergencia de turno sinalizada] | Cenario B (sem sugestao): $($cenarioB.Count)"

# Uma unica lista, ordenada por profissional + data + hora + cenario (nao mais
# "todo A primeiro, depois todo B"): dentro de cada profissional, as linhas
# ficam na ordem cronologica real do dia/semana dele, com A e B intercalados
# conforme aparecem na agenda - e' assim que faz sentido revisar o dia de um
# profissional especifico de uma vez so. 'Cenario' entra como ultimo criterio
# de desempate (so importa no caso raro de duas linhas com data+hora iguais).
$todasLinhas = @($cenarioA) + @($cenarioB) | Sort-Object Profissional, Data, Hora, Cenario

# ---------------------------------------------- pacientes recorrentes NAO sugeridos
# Sobra da fila de candidatos de cada profissional: pacientes atendidos nas
# ultimas $SemanasHistorico semanas, SEM agendamento futuro no periodo (essa
# exclusao ja aconteceu ao montar $candidatosPorProf), e que mesmo assim nao
# entraram em nenhuma sugestao de Cenario A (ou porque acabaram os buracos
# daquele profissional, ou porque o -SemanasHistorico e curto e o profissional
# tem poucos horarios vagos). Vale a pena ligar para eles e entender o motivo.
$naoSugeridos = @()
foreach ($profIdCur in $profIdsRelevantes) {
    $profNome = ($profRows | Where-Object { [int]$_.id -eq $profIdCur } | Select-Object -First 1).nome
    $lista = $candidatosPorProf[$profIdCur]
    if (-not $lista) { continue }
    foreach ($cand in ($lista | Where-Object { -not $_.Usado })) {
        $naoSugeridos += [PSCustomObject]@{
            Profissional      = $profNome
            Cliente           = $cand.Cliente
            Telefone          = $cand.Telefone
            UltimoAtendimento = $cand.UltimoAtendimento
            TurnoHabitual     = "$($cand.HoraHabitual) ($($cand.TurnoHabitual))"
        }
    }
}
$naoSugeridos = $naoSugeridos | Sort-Object Profissional, Cliente
Write-Output "[OK] $($naoSugeridos.Count) paciente(s) recorrente(s) sem agendamento futuro e sem sugestao (ver aba de resumo na planilha)."

# ============================================================ 9) SyncToSc0 (opt-in)
if ($SyncToSc0 -and $futureRowsMapped.Count -gt 0) {
    Write-Output "[*] -SyncToSc0 ligado: gravando agenda futura em sc0990 (valores fixos p/ pacienteId/tipoConsultaId/planoSaudeId)..."

    $minDt = ($futureRowsMapped | Sort-Object DataHora | Select-Object -First 1).DataHora
    $maxDt = ($futureRowsMapped | Sort-Object DataHora -Descending | Select-Object -First 1).DataHora
    $existRes = Invoke-MySql -Sql @"
SELECT profId, inicioAt, observacao FROM sc0990
WHERE empresaId = '$EmpresaId' AND filialId = '$FilialId'
  AND profId IN ($profIdList)
  AND inicioAt BETWEEN '$($minDt.ToString('yyyy-MM-dd HH:mm:ss'))' AND '$($maxDt.ToString('yyyy-MM-dd HH:mm:ss'))';
"@
    $existRows = if ($existRes[0].hasData) { $existRes[0].rows } else { @() }
    $existentes = New-Object System.Collections.Generic.HashSet[string]
    foreach ($e in $existRows) {
        [void]$existentes.Add("$($e.profId)|$($e.inicioAt)")
    }

    $maxIdRes = Invoke-MySql -Sql "SELECT COALESCE(MAX(id), 0) AS max_id FROM sc0990 WHERE empresaId = '$EmpresaId' AND filialOrigemId = '$FilialOrigemId';"
    $nextId = [int]$maxIdRes[0].rows[0].max_id + 1

    $ScoStatusEnum = @('Agendado', 'Confirmado', 'EmAtendimento', 'Atendido', 'Faltou', 'Cancelado')
    function Convert-ScoStatus {
        param([string]$Texto)
        if ([string]::IsNullOrWhiteSpace($Texto)) { return 'Agendado' }
        foreach ($v in $ScoStatusEnum) { if ($Texto.Trim() -ieq $v) { return $v } }
        if ((Remove-Diacritics $Texto) -eq 'ATENDENDO') { return 'EmAtendimento' }
        return 'Agendado'
    }

    $inserted = 0
    foreach ($row in $futureRowsMapped) {
        $inicioSql = $row.DataHora.ToString('yyyy-MM-dd HH:mm:ss')
        $key = "$($row.ProfId)|$inicioSql"
        if ($existentes.Contains($key)) { continue }  # ja gravado antes, nao duplica

        $espec = Resolve-Espec $row.Servico
        $especId = if ($espec) { [int]$espec.id } else { $EspecIdPadraoFallback }
        $fimSql = $row.DataHora.AddMinutes($DuracaoPadraoMin).ToString('yyyy-MM-dd HH:mm:ss')
        $obs = "[Simples Agenda] Cliente: $($row.Cliente) | Tel: $($row.Telefone) | Email: $($row.Email)"
        if ($row.Observacao) { $obs += " | Obs original: $($row.Observacao)" }
        $statusSco = Convert-ScoStatus $row.Status

        $sql = @"
INSERT INTO sc0990
    (empresaId, filialId, id, pacienteId, profId, especId, tipoConsultaId, planoSaudeId, inicioAt, fimAt, status, observacao, ativo, filialOrigemId, controleId, userControle, createdAt, userCreatedAt, updatedAt, userUpdatedAt)
VALUES
    ($(Get-SqlLiteral $EmpresaId), $(Get-SqlLiteral $FilialId), $nextId, $PacienteIdPadrao, $($row.ProfId), $especId, $TipoConsultaIdPadrao, $PlanoSaudeIdPadrao,
     '$inicioSql', '$fimSql', $(Get-SqlLiteral $statusSco), $(Get-SqlLiteral $obs), '1', $(Get-SqlLiteral $FilialOrigemId), '1', NULL, NOW(), 'simples-agenda-disponibilidade', NOW(), 'simples-agenda-disponibilidade');
"@
        try {
            Invoke-MySql -Sql $sql | Out-Null
            $nextId++
            $inserted++
        } catch {
            Write-Output "[AVISO] Falha ao inserir em sc0990 (profId=$($row.ProfId), inicio=$inicioSql): $_"
        }
    }
    Write-Output "[OK] $inserted linha(s) nova(s) gravada(s) em sc0990."
}

# ============================================================ 10) Planilha final
if (-not $OutputPath) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $destDir = Join-Path $env:USERPROFILE 'Downloads'
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $OutputPath = Join-Path $destDir ("agenda_futura_x_disponibilidade_profissional_" + $stamp + ".xlsx")
    $i = 1
    while (Test-Path $OutputPath) {
        $OutputPath = Join-Path $destDir ("agenda_futura_x_disponibilidade_profissional_" + $stamp + "_" + $i + ".xlsx")
        $i++
    }
}

# O historico vem do MySQL como 'yyyy-MM-dd HH:mm:ss' - formato bom para
# ORDENAR como string (Sort-Object UltimoAtendimento) e para extrair a hora
# habitual por indice, e por isso o dado interno NAO e alterado. Aqui, so na
# hora de escrever na planilha, converte para o formato que o usuario le
# (dd/MM/yyyy HH:mm). Sem isso o Excel ainda reinterpretava a string como data
# e exibia no padrao americano ("8/24/26 13:00").
function Format-DataHoraBr {
    param($Valor)
    $txt = [string]$Valor
    if ([string]::IsNullOrWhiteSpace($txt)) { return '' }
    $dt = [datetime]::MinValue
    foreach ($fmt in @('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm', 'yyyy-MM-ddTHH:mm:ss')) {
        if ([datetime]::TryParseExact($txt, $fmt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) {
            return $dt.ToString('dd/MM/yyyy HH:mm')
        }
    }
    # formato inesperado: devolve como veio, em vez de esconder o dado
    return $txt
}

$excel = New-ExcelCom
$wb = $null
try {
    $wb = $excel.Workbooks.Add()
    $ws = $wb.Sheets.Item(1)
    $ws.Name = "DISPONIBILIDADE"

    $headers = @('Cenario', 'Profissional', 'Data', 'Dia da Semana', 'Hora', 'Cliente Sugerido', 'Telefone', 'Email', 'Ultimo Atendimento', 'Turno Habitual', 'Observacao')
    for ($c = 0; $c -lt $headers.Count; $c++) { $ws.Cells.Item(1, $c + 1) = $headers[$c] }

    # Nome do dia da semana em portugues vindo da CULTURA pt-BR do .NET, nao de
    # literais no .ps1: "terca-feira" e "sabado" tem acento, e literal acentuado
    # dentro deste arquivo seria lido como ANSI/cp1252 pelo PowerShell 5.1 e
    # chegaria corrompido na planilha (mesmo problema ja documentado no
    # SKILL.md). Pedindo a cultura, o .NET devolve a string ja correta.
    $culturaPtBr = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')

    # Divergencia de turno (paciente sugerido fora do turno que ele costuma
    # frequentar) fica destacada em amarelo - e a diferenca entre uma
    # sugestao boa e uma sugestao que o usuario vai ter que descartar na mao.
    $corDivergencia = 65535  # amarelo (RGB 255,255,0) em formato OLE/BGR usado pelo Excel COM

    # Uma linha so, ordenada por profissional+data+hora+cenario (ja calculado
    # em $todasLinhas). Linha em branco a cada troca de profissional, para
    # quem abre a planilha conseguir ver de relance onde comeca a agenda de
    # cada um (mesmo recurso ja usado no db_manager.ps1 desta suite de skills).
    $r = 2
    $profissionalAnterior = $null
    foreach ($row in $todasLinhas) {
        if ($null -ne $profissionalAnterior -and $row.Profissional -ne $profissionalAnterior) {
            $r++  # linha em branco entre profissionais
        }
        $profissionalAnterior = $row.Profissional

        $temDivergencia = $row.Observacao -like 'ATENCAO:*'
        $ws.Cells.Item($r, 1) = $row.Cenario
        $ws.Cells.Item($r, 2) = $row.Profissional
        $ws.Cells.Item($r, 3).NumberFormat = '@'; $ws.Cells.Item($r, 3) = $row.Data.ToString('dd/MM/yyyy')
        $ws.Cells.Item($r, 4) = $row.Data.ToString('dddd', $culturaPtBr)
        $ws.Cells.Item($r, 5) = $row.Hora
        $ws.Cells.Item($r, 6) = $row.ClienteSugerido
        $ws.Cells.Item($r, 7).NumberFormat = '@'; $ws.Cells.Item($r, 7) = [string]$row.Telefone
        $ws.Cells.Item($r, 8) = $row.Email
        $ws.Cells.Item($r, 9).NumberFormat = '@'; $ws.Cells.Item($r, 9) = Format-DataHoraBr $row.UltimoAtendimento
        $ws.Cells.Item($r, 10) = $row.TurnoHabitual
        $ws.Cells.Item($r, 11) = $row.Observacao
        if ($temDivergencia) {
            $ws.Range($ws.Cells.Item($r, 1), $ws.Cells.Item($r, 11)).Interior.Color = $corDivergencia
        }
        $r++
    }
    $ws.Columns.Item("A:K").AutoFit() | Out-Null

    # ---- 2a aba: pacientes recorrentes sem agendamento futuro e sem sugestao
    $wsResumo = $wb.Sheets.Add([System.Reflection.Missing]::Value, $ws)
    $wsResumo.Name = "SEM AGENDAMENTO"
    $headersResumo = @('Profissional', 'Cliente', 'Telefone', 'Ultimo Atendimento', 'Turno Habitual')
    for ($c = 0; $c -lt $headersResumo.Count; $c++) { $wsResumo.Cells.Item(1, $c + 1) = $headersResumo[$c] }

    $rr = 2
    $profissionalAnteriorResumo = $null
    foreach ($row in $naoSugeridos) {
        if ($null -ne $profissionalAnteriorResumo -and $row.Profissional -ne $profissionalAnteriorResumo) {
            $rr++
        }
        $profissionalAnteriorResumo = $row.Profissional

        $wsResumo.Cells.Item($rr, 1) = $row.Profissional
        $wsResumo.Cells.Item($rr, 2) = $row.Cliente
        $wsResumo.Cells.Item($rr, 3).NumberFormat = '@'; $wsResumo.Cells.Item($rr, 3) = [string]$row.Telefone
        $wsResumo.Cells.Item($rr, 4).NumberFormat = '@'; $wsResumo.Cells.Item($rr, 4) = Format-DataHoraBr $row.UltimoAtendimento
        $wsResumo.Cells.Item($rr, 5) = $row.TurnoHabitual
        $rr++
    }
    $wsResumo.Columns.Item("A:E").AutoFit() | Out-Null
    $ws.Activate() | Out-Null   # deixa a aba principal em foco ao abrir o arquivo

    $fullPath = $OutputPath
    if (-not [System.IO.Path]::IsPathRooted($fullPath)) { $fullPath = Join-Path (Get-Location) $fullPath }
    $dir = Split-Path $fullPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $wb.SaveAs($fullPath, 51)  # 51 = xlOpenXMLWorkbook (.xlsx)
} finally {
    if ($wb) { $wb.Close($false) }
    $excel.Quit()
    if ($wb) { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wb) | Out-Null }
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
}

Write-Output "[OK] Planilha '$(Split-Path $fullPath -Leaf)' gerada com sucesso em $(Split-Path $fullPath -Parent)"
Write-Output "     ($($cenarioA.Count) sugestoes de Cenario A, $($cenarioB.Count) horarios vagos sem sugestao - Cenario B)"
Write-Output "     Aba 'SEM AGENDAMENTO': $($naoSugeridos.Count) paciente(s) recorrente(s) para contatar."
if ($divergentes -gt 0) {
    Write-Output "     [AVISO] $divergentes sugestao(oes) de Cenario A destacada(s) em amarelo na planilha:"
    Write-Output "             o paciente foi encaixado fora do turno que ele costuma frequentar (confirmar antes de agendar)."
}

# ============================================================ 11) Envio por email
# Regra do chamador: em sucesso, apaga a planilha do disco (o destinatario ja
# a recebeu em anexo, nao faz sentido deixar dado de paciente acumulando em
# Downloads); em falha, NAO apaga (preserva o trabalho) e avisa
# $EmailErroPara com o motivo, para alguem poder reenviar manualmente depois.
$emailEnviado = $false
$emailErro = $null
if (-not $SemEnvioEmail) {
    $EmailSenderScript = Join-Path $PSScriptRoot '..\..\email-sender\scripts\send_email.ps1'
    if (-not (Test-Path $EmailSenderScript)) {
        $emailErro = "email-sender nao encontrado em $EmailSenderScript."
        Write-Output "[AVISO] $emailErro Planilha preservada em $fullPath."
    } else {
        Write-Output "[*] Enviando planilha por email para $EnviarPara (service=$EmailService)..."
        $corpo = @"
Planilha de disponibilidade gerada para o periodo $DataIni a $DataFim.

Resumo:
- Cenario A (sugestoes de pacientes): $($cenarioA.Count)
- Cenario B (horarios vagos sem sugestao): $($cenarioB.Count)
- Divergencias de turno sinalizadas (linhas em amarelo): $divergentes
- Pacientes recorrentes sem agendamento futuro (aba SEM AGENDAMENTO): $($naoSugeridos.Count)

Planilha em anexo.

(Email automatico - skill simples-agenda-disponibilidade)
"@
        $sendOut = & $EmailSenderScript -Service $EmailService -To $EnviarPara `
            -Subject "Agenda Futura x Disponibilidade Profissionais: $DataIni a $DataFim" -Body $corpo -Attachment $fullPath -Json
        $sendExit = $LASTEXITCODE
        if ($sendExit -eq 0) {
            $emailEnviado = $true
            Write-Output "[OK] Email enviado para $EnviarPara."
        } else {
            $motivo = switch ($sendExit) {
                1 { 'INVALID_INPUT - destinatario/assunto invalido.' }
                2 { 'CREDENTIAL_MISSING - servico sem setup no email-sender.' }
                3 { "RECIPIENT_BLOCKED - '$EnviarPara' nao esta na allowlist do servico '$EmailService'." }
                4 { 'ATTACHMENT_ERROR - planilha inexistente, vazia ou acima do limite de tamanho.' }
                5 { 'SEND_FAILED - falha SMTP generica (rede ou servidor).' }
                6 { 'AUTH_FAILED - senha de app do Gmail recusada/revogada.' }
                7 { 'TLS_ERROR - nao foi possivel estabelecer TLS 1.2+.' }
                default { "codigo de saida $sendExit nao mapeado." }
            }
            $emailErro = "Falha ao enviar a planilha (exit $sendExit): $motivo"
            Write-Output "[ERRO] $emailErro"
            Write-Output "       Saida do email-sender: $($sendOut -join ' | ')"
            Write-Output "       Planilha preservada em $fullPath (nao apagada)."

            # Avisa quem cuida do processo, com o motivo do erro. Reusa o mesmo
            # servico (o destinatario de erro ja esta na allowlist de
            # 'simples-agenda'); se ESSE envio tambem falhar, so loga - nao ha
            # mais ninguem para avisar, e a planilha ja fica preservada em disco
            # de qualquer forma.
            if ($EmailErroPara) {
                $corpoErro = @"
Falha ao enviar a planilha de disponibilidade (periodo $DataIni a $DataFim) para $EnviarPara.

Motivo: $emailErro

A planilha foi preservada em: $fullPath
Maquina: $env:COMPUTERNAME | Usuario: $env:USERNAME

(Email automatico - skill simples-agenda-disponibilidade)
"@
                & $EmailSenderScript -Service $EmailService -To $EmailErroPara `
                    -Subject "[ERRO] Falha no envio da Agenda Futura x Disponibilidade Profissionais ($DataIni a $DataFim)" -Body $corpoErro -Json | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Output "[OK] Email de erro enviado para $EmailErroPara."
                } else {
                    Write-Output "[AVISO] Tambem falhou o envio do email de erro para $EmailErroPara (exit $LASTEXITCODE). Verifique manualmente."
                }
            }
        }
    }
} else {
    Write-Output "[*] -SemEnvioEmail ligado: pulando envio por email. Planilha preservada em $fullPath."
}

if ($emailEnviado) {
    Remove-Item -Path $fullPath -Force -ErrorAction SilentlyContinue
    Write-Output "[OK] Planilha local removida apos envio confirmado."
}

if ($Json) {
    @{
        success                      = $true
        output_path                  = if ($emailEnviado) { $null } else { $fullPath }
        cenario_a                    = $cenarioA.Count
        cenario_a_divergencia_turno  = $divergentes
        cenario_b                    = $cenarioB.Count
        nao_sugeridos                = $naoSugeridos.Count
        email_enviado                = $emailEnviado
        email_para                   = $EnviarPara
        email_erro                   = $emailErro
    } | ConvertTo-Json -Compress
}
exit 0
