<#
.SYNOPSIS
    import-db-agenda: sincroniza .xls do Simples Agenda com a tabela MySQL
    sbx990 (banco 4clinics) e gera planilhas .xlsx ordenadas a partir do banco.

.DESCRIPTION
    Skill ESPECIFICA (nao generica): hardcoded para a tabela sbx990 e para o
    layout de colunas exportado pelo Simples Agenda (aba AGENDAMENTOS).

    sbx990 e uma tabela do sistema 4clinics com chave primaria composta
    (empresaId, filialOrigemId, id) e FKs para xempresas/xfiliais. Por isso,
    ao contrario da antiga agenda_realizada_status, o schema NAO e criado por
    esta skill (init-schema apenas valida que a tabela e as referencias
    existem) e o campo id NAO e AUTO_INCREMENT - e gerado por esta skill via
    MAX(id)+1 escopado a (empresaId, filialOrigemId).

    Mapeamento de colunas (Simples Agenda -> sbx990):
      data -> dataAgenda | data_acao -> dataAcao | executado_por -> executadoPor
      cliente, telefone, email, servico, observacao, profissional, status: mesmo nome

    status do Simples Agenda (texto livre) e convertido para o ENUM restrito
    de sbx990 ('Agendado','Confirmado','Atendendo','Atendido','Faltou',
    'Cancelado'): match exato (case-insensitive) ou fallback 'Agendado' com
    aviso.

    Usa:
      - mysqlsh.exe (MySQL Shell) para falar com o MySQL, via --sql --json=raw
      - Microsoft Excel (COM) para ler o .xls de entrada e escrever o .xlsx de saida
      - a skill credential-manager para guardar a senha do MySQL com seguranca

.PARAMETER Action
    init-schema | sync | export | logout

.PARAMETER EmpresaId
    Codigo da empresa em sbx990/xempresas (char(3)). Default '001'.

.PARAMETER FilialId
    Codigo da filial em sbx990 (char(3)). Default '01'.

.PARAMETER FilialOrigemId
    Codigo da filial de origem em sbx990/xfiliais, usado na PK composta
    junto com EmpresaId (char(3)). Default '01'.

.EXAMPLE
    # 1a vez: valida que sbx990 e as referencias (xempresas/xfiliais) existem
    .\db_manager.ps1 -Action init-schema -DbHost 127.0.0.1 -DbPort 3306 -DbUser root -Database 4clinics -DbPassword T3st_r00t

.EXAMPLE
    # sincroniza um .xls baixado do Simples Agenda
    .\db_manager.ps1 -Action sync -DbHost 127.0.0.1 -DbPort 3306 -DbUser root -Database 4clinics -XlsPath C:\Users\voce\Downloads\agenda_20260901_111703.xls

.EXAMPLE
    # gera .xlsx ordenado por cliente+data a partir do banco
    .\db_manager.ps1 -Action export -DbHost 127.0.0.1 -DbPort 3306 -DbUser root -Database 4clinics -OutputPath C:\Users\voce\Downloads\agenda_ordenada.xlsx -SortBy cliente+data

.NOTES
    Codigos de saida: 0 OK | 1 DB_CONNECTION_FAILED | 2 PASSWORD_REQUIRED |
                      3 XLS_NOT_FOUND | 4 XLS_UNEXPECTED_FORMAT |
                      5 EXCEL_COM_UNAVAILABLE | 6 MYSQLSH_NOT_FOUND | 7 INVALID_INPUT
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("init-schema", "sync", "export", "logout")]
    [string]$Action,

    [string]$DbHost = "127.0.0.1",
    [int]$DbPort = 3306,
    [string]$DbUser = "root",
    [string]$Database = "4clinics",
    [string]$DbPassword,

    # Identificadores fixos de sbx990 (fazem parte da PK composta e das FKs
    # para xempresas/xfiliais). Todo registro sincronizado por esta skill usa
    # os mesmos tres valores.
    [string]$EmpresaId = "001",
    [string]$FilialId = "01",
    [string]$FilialOrigemId = "01",

    [string]$XlsPath,
    [string]$OutputPath,
    [ValidateSet("cliente+data", "servico+data", "profissional+data")]
    [string]$SortBy = "cliente+data",

    # Filtro opcional de periodo para -Action export (dd/MM/yyyy). Sem eles,
    # exporta o historico inteiro sincronizado para (EmpresaId, FilialId).
    [string]$DataIni,
    [string]$DataFim,

    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------- credential-manager
$CredManagerScript = Join-Path $PSScriptRoot '..\..\credential-manager\scripts\credential_manager.ps1'
$CredService = 'mysql-agenda-db'

function Invoke-CredManager {
    param([hashtable]$CredArgs)
    & $CredManagerScript @CredArgs
}

$credManagerDisponivel = Test-Path $CredManagerScript

if ($Action -eq 'logout') {
    if (-not $credManagerDisponivel) {
        Write-Output "[ERRO] Skill credential-manager nao encontrada em: $CredManagerScript"
        exit 6
    }
    Invoke-CredManager -CredArgs @{ Action = 'delete'; Username = $DbUser; Service = $CredService } | Out-Null
    Write-Output "[OK] Senha removida para usuario '$DbUser' (service $CredService)."
    exit 0
}

# ------------------------------------------------------------------ mysqlsh
$MysqlshCmd = Get-Command mysqlsh.exe -ErrorAction SilentlyContinue
if (-not $MysqlshCmd) {
    Write-Output "[ERRO] mysqlsh.exe nao encontrado no PATH. Instale o MySQL Shell."
    exit 6
}

if ([string]::IsNullOrEmpty($DbPassword) -and $credManagerDisponivel) {
    $jsonOut = Invoke-CredManager -CredArgs @{ Action = 'load'; Username = $DbUser; Service = $CredService; Json = $true }
    try {
        $parsed = $jsonOut | ConvertFrom-Json
        if ($parsed.found) {
            $DbPassword = $parsed.password
            Write-Output "[*] Senha do MySQL carregada automaticamente (usuario $DbUser)."
        }
    }
    catch {
        # sem senha salva ainda
    }
}

if ([string]::IsNullOrEmpty($DbPassword)) {
    Write-Output "[ERRO] Senha do MySQL nao informada (-DbPassword) e nenhuma salva no credential-manager."
    Write-Output "       Informe -DbPassword uma vez; ela sera salva para as proximas execucoes."
    exit 2
}

if ($credManagerDisponivel -and $PSBoundParameters.ContainsKey('DbPassword')) {
    Invoke-CredManager -CredArgs @{ Action = 'save'; Username = $DbUser; Password = $DbPassword; Service = $CredService } | Out-Null
}

# --------------------------------------------------------------- Invoke-MySql
function Invoke-MySql {
    <#
        Executa 1+ statements SQL via mysqlsh --sql --json=raw --file=<tmp>.
        Retorna um array de objetos PSCustomObject (um por statement), cada um
        com .hasData, .rows, .affectedRowCount, etc. (conforme mysqlsh --json).
    #>
    param([string]$Sql)

    $tmpSql = [System.IO.Path]::GetTempFileName() + ".sql"
    try {
        # Set-Content -Encoding UTF8 escreve BOM, que quebra o parser SQL do
        # mysqlsh (erro de sintaxe no primeiro caractere). Escrever sem BOM:
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpSql, $Sql, $utf8NoBom)

        $args = @(
            '--sql', '-h', $DbHost, '-P', $DbPort, '-u', $DbUser,
            "-p$DbPassword", "--schema=$Database", '--json=raw', '--file', $tmpSql
        )
        $output = & mysqlsh.exe @args 2>&1
        $exitCode = $LASTEXITCODE

        $results = @()
        foreach ($line in $output) {
            $line = $line.Trim()
            if ([string]::IsNullOrEmpty($line)) { continue }
            try {
                $obj = $line | ConvertFrom-Json
                if ($obj.PSObject.Properties.Name -contains 'warning') { continue }
                if ($obj.PSObject.Properties.Name -contains 'error') {
                    throw "Erro MySQL: $($obj.error)"
                }
                $results += $obj
            }
            catch [System.Management.Automation.RuntimeException] {
                throw
            }
            catch {
                # linha que nao e JSON valido (raro) - ignora
            }
        }

        if ($exitCode -ne 0 -and $results.Count -eq 0) {
            throw "mysqlsh retornou codigo $exitCode sem resultado JSON. Saida: $($output -join ' | ')"
        }

        return $results
    }
    finally {
        Remove-Item -Path $tmpSql -Force -ErrorAction SilentlyContinue
    }
}

try {
    $null = Invoke-MySql -Sql "SELECT 1;"
}
catch {
    Write-Output "[ERRO] Falha ao conectar no MySQL ($DbHost`:$DbPort, usuario $DbUser, banco $Database)."
    Write-Output "       $_"
    exit 1
}

# ------------------------------------------------------------------- schema
# sbx990 e uma tabela do sistema 4clinics com FKs para xempresas/xfiliais e
# chave primaria composta - nao e criada nem alterada por esta skill. init-
# schema apenas valida que ela e as referencias (EmpresaId, FilialOrigemId)
# existem, para falhar cedo e com mensagem clara em vez de um erro de FK
# constraint no meio do sync.
function Invoke-InitSchema {
    $tableCheck = Invoke-MySql -Sql "SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = '$Database' AND table_name = 'sbx990';"
    if ([int]$tableCheck[0].rows[0].n -eq 0) {
        Write-Output "[ERRO] Tabela sbx990 nao existe no banco $Database."
        Write-Output "       sbx990 e gerenciada pelo sistema 4clinics (tem FKs para xempresas/xfiliais)"
        Write-Output "       e nao e criada por esta skill. Verifique o banco/schema informado."
        exit 4
    }

    $empresaCheck = Invoke-MySql -Sql "SELECT COUNT(*) AS n FROM xempresas WHERE id = '$EmpresaId';"
    if ([int]$empresaCheck[0].rows[0].n -eq 0) {
        Write-Output "[ERRO] EmpresaId '$EmpresaId' nao existe em xempresas."
        Write-Output "       sbx990 tem FK (empresaId -> xempresas.id); o sync falharia com erro de FK."
        exit 4
    }

    $filialCheck = Invoke-MySql -Sql "SELECT COUNT(*) AS n FROM xfiliais WHERE empresaId = '$EmpresaId' AND filialId = '$FilialOrigemId';"
    if ([int]$filialCheck[0].rows[0].n -eq 0) {
        Write-Output "[ERRO] Par (EmpresaId '$EmpresaId', FilialOrigemId '$FilialOrigemId') nao existe em xfiliais."
        Write-Output "       sbx990 tem FK ((empresaId,filialOrigemId) -> xfiliais(empresaId,filialId)); o sync falharia com erro de FK."
        exit 4
    }

    # sbx990 nao tem, por padrao, nenhuma UNIQUE KEY nas colunas de negocio
    # (empresaId, filialId, dataAgenda, cliente). Sem ela, o INSERT ... ON
    # DUPLICATE KEY UPDATE do sync nao tem em que colidir e cada sincronizacao
    # repetida duplicaria os agendamentos. Cria a UNIQUE KEY uma unica vez
    # (idempotente) se ainda nao existir.
    $uniqueKeyName = 'uq_sync_empresa_filial_data_cliente'
    $ukCheck = Invoke-MySql -Sql "SELECT COUNT(*) AS n FROM information_schema.statistics WHERE table_schema = '$Database' AND table_name = 'sbx990' AND index_name = '$uniqueKeyName';"
    if ([int]$ukCheck[0].rows[0].n -eq 0) {
        Write-Output "[*] UNIQUE KEY de dedup ausente em sbx990. Criando '$uniqueKeyName'..."
        try {
            Invoke-MySql -Sql "ALTER TABLE sbx990 ADD UNIQUE KEY $uniqueKeyName (empresaId, filialId, dataAgenda, cliente);" | Out-Null
            Write-Output "[OK] UNIQUE KEY '$uniqueKeyName' (empresaId, filialId, dataAgenda, cliente) criada em sbx990."
        }
        catch {
            Write-Output "[ERRO] Falha ao criar UNIQUE KEY em sbx990: $_"
            Write-Output "       Possivel causa: ja existem linhas duplicadas em (empresaId, filialId, dataAgenda, cliente)."
            Write-Output "       Resolva a duplicidade manualmente antes de rodar init-schema novamente."
            exit 4
        }
    }

    Write-Output "[OK] Tabela sbx990 e referencias (EmpresaId '$EmpresaId', FilialOrigemId '$FilialOrigemId') validadas em $Database."
}

# ------------------------------------------------------------------- Excel COM
function New-ExcelCom {
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        return $excel
    }
    catch {
        Write-Output "[ERRO] Microsoft Excel (COM) nao disponivel: $_"
        exit 5
    }
}

function ConvertTo-MySqlDateTime {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $d = [datetime]::MinValue
    $formats = @('dd/MM/yyyy HH:mm', 'dd/MM/yyyy H:mm', 'dd/MM/yyyy')
    foreach ($fmt in $formats) {
        if ([datetime]::TryParseExact($Text.Trim(), $fmt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) {
            return $d.ToString('yyyy-MM-dd HH:mm:ss')
        }
    }
    return $null
}

function Get-SqlLiteral {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return 'NULL' }
    $escaped = $Value.ToString().Replace("\", "\\").Replace("'", "''")
    return "'$escaped'"
}

# Status do Simples Agenda e texto livre; sbx990.status e ENUM restrito.
# Match exato case-insensitive ou fallback 'Agendado' com aviso.
$StatusEnum = @('Agendado', 'Confirmado', 'Atendendo', 'Atendido', 'Faltou', 'Cancelado')

function Convert-StatusToEnum {
    param([string]$StatusText, [int]$LinhaOrigem)
    if ([string]::IsNullOrWhiteSpace($StatusText)) { return 'Agendado' }
    foreach ($enumVal in $StatusEnum) {
        if ($StatusText.Trim() -ieq $enumVal) { return $enumVal }
    }
    Write-Output "[AVISO] Linha $LinhaOrigem`: status '$StatusText' nao reconhecido pelo ENUM de sbx990. Usando 'Agendado'."
    return 'Agendado'
}

# ------------------------------------------------------------------- sync
# Comparados sem acento: PowerShell 5.1 le .ps1 em UTF-8 sem BOM como ANSI,
# o que corrompe literais acentuados (ex.: letras com cedilha/til). Normalizar
# removendo diacriticos evita depender da codificacao do arquivo do script.
function Remove-Diacritics {
    param([string]$Text)
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString().Normalize([Text.NormalizationForm]::FormC)
}

$ExpectedHeaders = @('Data', 'Cliente', 'Telefone', 'Email', 'Servico', 'Observacao', 'Profissional', 'Status', 'Data Acao', 'Executado por')

function Invoke-Sync {
    if ([string]::IsNullOrWhiteSpace($XlsPath)) {
        Write-Output "[ERRO] -XlsPath e obrigatorio para -Action sync."
        exit 7
    }
    if (-not (Test-Path $XlsPath)) {
        Write-Output "[ERRO] Arquivo nao encontrado: $XlsPath"
        exit 3
    }

    $excel = New-ExcelCom
    $wb = $null
    try {
        $wb = $excel.Workbooks.Open((Resolve-Path $XlsPath).Path)
        $ws = $wb.Sheets.Item(1)
        $used = $ws.UsedRange
        $rowCount = $used.Rows.Count
        $colCount = $used.Columns.Count

        # valida cabecalho (pelo menos as 10 primeiras colunas esperadas)
        for ($c = 1; $c -le 10; $c++) {
            $header = Remove-Diacritics ($ws.Cells.Item(1, $c).Text.Trim())
            if ($header -ne $ExpectedHeaders[$c - 1]) {
                Write-Output "[ERRO] Layout inesperado: coluna $c e '$header', esperava '$($ExpectedHeaders[$c - 1])'."
                Write-Output "       O Simples Agenda pode ter mudado o formato de exportacao."
                exit 4
            }
        }

        $rows = @()
        for ($r = 2; $r -le $rowCount; $r++) {
            $dataTxt = $ws.Cells.Item($r, 1).Text.Trim()
            $clienteTxt = $ws.Cells.Item($r, 2).Text.Trim()
            if ([string]::IsNullOrWhiteSpace($dataTxt) -or [string]::IsNullOrWhiteSpace($clienteTxt)) {
                continue  # linha em branco no final da planilha
            }

            $dataSql = ConvertTo-MySqlDateTime $dataTxt
            if ($null -eq $dataSql) {
                Write-Output "[AVISO] Linha $r ignorada: data invalida '$dataTxt'."
                continue
            }

            $statusTxt = $ws.Cells.Item($r, 8).Text.Trim()

            $rows += [PSCustomObject]@{
                dataAgenda    = $dataSql
                cliente       = $clienteTxt
                telefone      = $ws.Cells.Item($r, 3).Text.Trim()
                email         = $ws.Cells.Item($r, 4).Text.Trim()
                servico       = $ws.Cells.Item($r, 5).Text.Trim()
                observacao    = $ws.Cells.Item($r, 6).Text.Trim()
                profissional  = $ws.Cells.Item($r, 7).Text.Trim()
                status        = Convert-StatusToEnum -StatusText $statusTxt -LinhaOrigem $r
                dataAcao      = ConvertTo-MySqlDateTime $ws.Cells.Item($r, 9).Text.Trim()
                executadoPor  = $ws.Cells.Item($r, 10).Text.Trim()
            }
        }
    }
    finally {
        if ($wb) { $wb.Close($false) }
        $excel.Quit()
        if ($wb) { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wb) | Out-Null }
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
    }

    if ($rows.Count -eq 0) {
        Write-Output "[AVISO] Nenhuma linha valida encontrada em $XlsPath."
        exit 0
    }

    # id e AUTO_INCREMENT em sbx990 - nao entra no INSERT, o MySQL gera sozinho
    # para linhas novas. O dedup usa a UNIQUE KEY (empresaId, filialId,
    # dataAgenda, cliente) criada por -Action init-schema: quando ela colide,
    # o ON DUPLICATE KEY UPDATE atualiza a linha existente e o id original
    # (nao listado no UPDATE) e preservado.
    $batchSize = 200
    $totalProcessed = 0
    for ($i = 0; $i -lt $rows.Count; $i += $batchSize) {
        $batch = $rows[$i..([Math]::Min($i + $batchSize - 1, $rows.Count - 1))]
        $valueLines = foreach ($row in $batch) {
            "(" + (Get-SqlLiteral $EmpresaId) + "," +
                  (Get-SqlLiteral $FilialId) + "," +
                  (Get-SqlLiteral $row.dataAgenda) + "," +
                  (Get-SqlLiteral $row.cliente) + "," +
                  (Get-SqlLiteral $row.telefone) + "," +
                  (Get-SqlLiteral $row.email) + "," +
                  (Get-SqlLiteral $row.servico) + "," +
                  (Get-SqlLiteral $row.observacao) + "," +
                  (Get-SqlLiteral $row.dataAcao) + "," +
                  (Get-SqlLiteral $row.executadoPor) + "," +
                  (Get-SqlLiteral $row.profissional) + "," +
                  (Get-SqlLiteral $row.status) + "," +
                  "'1'," +
                  (Get-SqlLiteral $FilialOrigemId) + "," +
                  "'1'," +
                  "NULL," +
                  "NOW()," +
                  "'simples-agenda-sync'," +
                  "NOW()," +
                  "'simples-agenda-sync')"
        }
        $sql = @"
INSERT INTO sbx990
    (empresaId, filialId, dataAgenda, cliente, telefone, email, servico, observacao, dataAcao, executadoPor, profissional, status, ativo, filialOrigemId, controleId, userControle, createdAt, userCreatedAt, updatedAt, userUpdatedAt)
VALUES
    $($valueLines -join ",`n    ")
ON DUPLICATE KEY UPDATE
    telefone = VALUES(telefone),
    email = VALUES(email),
    servico = VALUES(servico),
    profissional = VALUES(profissional),
    status = VALUES(status),
    observacao = VALUES(observacao),
    dataAcao = VALUES(dataAcao),
    executadoPor = VALUES(executadoPor),
    updatedAt = VALUES(updatedAt),
    userUpdatedAt = VALUES(userUpdatedAt);
"@
        Invoke-MySql -Sql $sql | Out-Null
        $totalProcessed += $batch.Count
    }

    if ($Json) {
        @{ success = $true; rows_processed = $totalProcessed } | ConvertTo-Json -Compress
    }
    else {
        Write-Output "[OK] $totalProcessed agendamento(s) sincronizado(s) em sbx990 (empresaId=$EmpresaId, filialId=$FilialId)."
    }
}

# ------------------------------------------------------------------- export
function Invoke-Export {
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        Write-Output "[ERRO] -OutputPath e obrigatorio para -Action export."
        exit 7
    }

    $orderMap = @{
        'cliente+data'      = 'cliente, data'
        'servico+data'      = 'servico, data'
        'profissional+data' = 'profissional, data'
    }
    $orderBy = $orderMap[$SortBy]

    # Ajuste a: reordenar colunas conforme modo de ordenacao
    # Determina qual campo vem primeiro (para agrupar e inserir linhas em branco)
    $groupByField = $SortBy.Split('+')[0]  # 'cliente', 'servico', ou 'profissional'

    # Define a ordem das colunas na planilha conforme o agrupamento
    # O primeiro campo do agrupamento vem sempre em primeiro lugar
    $columnOrder = switch ($groupByField) {
        'cliente' {
            @('cliente', 'data', 'telefone', 'email', 'servico', 'profissional', 'status', 'observacao', 'data_acao', 'executado_por')
        }
        'servico' {
            @('servico', 'data', 'cliente', 'telefone', 'email', 'profissional', 'status', 'observacao', 'data_acao', 'executado_por')
        }
        'profissional' {
            @('profissional', 'data', 'cliente', 'telefone', 'email', 'servico', 'status', 'observacao', 'data_acao', 'executado_por')
        }
    }

    # sbx990 usa nomes proprios (dataAgenda, dataAcao, executadoPor); os alias
    # abaixo devolvem as mesmas colunas com os nomes "amigaveis" ja usados no
    # resto do script (data, data_acao, executado_por), preservando o layout
    # da planilha final sem mudanca.
    $selectCols = @(
        'dataAgenda AS data', 'cliente', 'telefone', 'email', 'servico',
        'profissional', 'status', 'observacao',
        'dataAcao AS data_acao', 'executadoPor AS executado_por'
    )

    # Filtro de periodo (dd/MM/yyyy) + escopo fixo por EmpresaId/FilialId.
    $whereParts = @("empresaId = '$EmpresaId'", "filialId = '$FilialId'")
    if (-not [string]::IsNullOrWhiteSpace($DataIni)) {
        $dIni = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($DataIni.Trim(), 'dd/MM/yyyy', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dIni)) {
            Write-Output "[ERRO] -DataIni invalida: '$DataIni'. Use dd/mm/yyyy."
            exit 7
        }
        $iniSql = $dIni.ToString('yyyy-MM-dd 00:00:00')
        $whereParts += "dataAgenda >= '$iniSql'"
    }
    if (-not [string]::IsNullOrWhiteSpace($DataFim)) {
        $dFim = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($DataFim.Trim(), 'dd/MM/yyyy', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dFim)) {
            Write-Output "[ERRO] -DataFim invalida: '$DataFim'. Use dd/mm/yyyy."
            exit 7
        }
        # limite exclusivo no dia seguinte para incluir o -DataFim inteiro (00:00 a 23:59:59)
        $fimSql = $dFim.AddDays(1).ToString('yyyy-MM-dd 00:00:00')
        $whereParts += "dataAgenda < '$fimSql'"
    }
    $whereClause = " WHERE " + ($whereParts -join " AND ")

    $sql = "SELECT $($selectCols -join ', ') FROM sbx990$whereClause ORDER BY $orderBy;"
    $res = Invoke-MySql -Sql $sql
    $rows = if ($res[0].hasData) { $res[0].rows } else { @() }

    $excel = New-ExcelCom
    $wb = $null
    try {
        $wb = $excel.Workbooks.Add()
        $ws = $wb.Sheets.Item(1)
        $ws.Name = "AGENDAMENTOS"

        # Headers na ordem do agrupamento
        $headerMap = @{
            'cliente'      = 'Cliente'
            'data'         = 'Data'
            'telefone'     = 'Telefone'
            'email'        = 'Email'
            'servico'      = 'Servico'
            'profissional' = 'Profissional'
            'status'       = 'Status'
            'observacao'   = 'Observacao'
            'data_acao'    = 'Data Acao'
            'executado_por' = 'Executado por'
        }

        for ($c = 0; $c -lt $columnOrder.Count; $c++) {
            $colName = $columnOrder[$c]
            $ws.Cells.Item(1, $c + 1) = $headerMap[$colName]
        }

        # Formato da coluna Data.
        #
        # O valor chega do MySQL como '2026-08-31 15:00:00'. Sem formato explicito
        # o Excel exibe no formato regional de QUEM ABRE - '8/31/2026' num leitor
        # en-US, onde 31/08 e 08/31 se confundem numa planilha brasileira.
        #
        # O prefixo [$-416] (LCID de pt-BR) e o que torna isso deterministico, por
        # dois motivos:
        #
        # 1. Sem ele, o Excel casa 'dd/mm/yyyy' com o formato EMBUTIDO de data
        #    curta (numFmtId=14), que por definicao e renderizado conforme a
        #    configuracao regional do leitor - o formato explicito e descartado.
        #    Com o prefixo vira um formato CUSTOMIZADO (numFmtId>=164), que guarda
        #    a string literal e exibe igual em qualquer maquina.
        #
        # 2. O prefixo nao resolve sozinho: o SETTER de NumberFormat interpreta os
        #    codigos no idioma da instalacao do Excel (pt-BR usa 'aaaa' para ano,
        #    en-US usa 'yyyy'). Passar o codigo errado nao da erro - o Excel
        #    escapa como texto literal e o arquivo guarda 'dd/mm/\y\y\y\y'.
        #
        # Nao da para conferir pelo retorno do getter: ele SEMPRE devolve a forma
        # canonica em ingles, independentemente do que foi aceito. A unica
        # evidencia confiavel e o que a celula EXIBE. Por isso testamos os
        # candidatos contra uma data e hora conhecidas.
        #
        # O horario faz parte do agendamento e continua visivel: so a ORDEM dos
        # campos muda, nao o conteudo.
        #
        # Verificado no styles.xml do .xlsx gerado: o formato correto vira
        # numFmtId>=164 com formatCode '[$-416]dd/mm/yyyy hh:mm'.
        # A coluna da celula de teste precisa ser larga: .Text devolve o que esta
        # VISIVEL, e numa coluna estreita o Excel responde '########' - o que faria
        # todos os candidatos falharem por um motivo que nao e o formato.
        $ws.Columns.Item(26).ColumnWidth = 40
        $probe = $ws.Cells.Item(1, 26)
        $dateFormat = $null
        foreach ($cand in @('[$-416]dd/mm/aaaa hh:mm', '[$-416]dd/mm/yyyy hh:mm')) {
            try {
                $probe.NumberFormat = $cand
                $probe.Value2 = 46265.625      # 31/08/2026 15:00
                if ($probe.Text -eq '31/08/2026 15:00') { $dateFormat = $cand; break }
            }
            catch { continue }
        }
        $probe.Clear() | Out-Null
        $ws.Columns.Item(26).ColumnWidth = 8.43   # padrao, para nao deixar rastro
        if (-not $dateFormat) {
            Write-Output "[AVISO] Nao foi possivel fixar o formato dd/mm/yyyy hh:mm na coluna Data."
            Write-Output "        A planilha sai com o formato regional do Excel desta maquina."
        }

        $dataColIndex = [array]::IndexOf($columnOrder, 'data')
        if ($dateFormat -and $dataColIndex -ge 0) {
            # Aplicado na coluna inteira de uma vez, e nao celula a celula: uma
            # chamada COM em vez de uma por linha.
            $colLetter = [char]([int][char]'A' + $dataColIndex)
            $ws.Columns.Item("$colLetter`:$colLetter").NumberFormat = $dateFormat
        }

        # Ajustes b e c: inserir linha em branco entre agrupamentos, manter observacao como texto
        $r = 2
        $lastGroupValue = $null
        foreach ($row in $rows) {
            # $row e um PSCustomObject do mysqlsh; acessar com notacao de ponto
            $currentGroupValue = $row.$groupByField

            # Ajuste b: se o valor do campo de agrupamento mudou, inserir linha em branco
            if ($null -ne $lastGroupValue -and $currentGroupValue -ne $lastGroupValue) {
                $r++  # pula uma linha (deixa em branco)
            }

            # Escreve as colunas na ordem definida
            for ($c = 0; $c -lt $columnOrder.Count; $c++) {
                $colName = $columnOrder[$c]
                $val = $row.$colName

                # Ajuste c: observacao mantem como texto (nao converte para date)
                if ($colName -eq 'observacao') {
                    $ws.Cells.Item($r, $c + 1).NumberFormat = '@'  # format como texto
                }

                $ws.Cells.Item($r, $c + 1) = [string]$val
            }

            $lastGroupValue = $currentGroupValue
            $r++
        }

        $ws.Columns.Item("A:J").AutoFit() | Out-Null

        $fullPath = $OutputPath
        if (-not [System.IO.Path]::IsPathRooted($fullPath)) {
            $fullPath = Join-Path (Get-Location) $fullPath
        }
        $dir = Split-Path $fullPath -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        # 51 = xlOpenXMLWorkbook (.xlsx)
        $wb.SaveAs($fullPath, 51)
    }
    finally {
        if ($wb) { $wb.Close($false) }
        $excel.Quit()
        if ($wb) { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wb) | Out-Null }
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
    }

    if ($Json) {
        @{ success = $true; rows = $rows.Count; output_path = $fullPath } | ConvertTo-Json -Compress
    }
    else {
        Write-Output "[OK] $($rows.Count) linha(s) exportada(s) para $fullPath (ordenado por $SortBy)."
    }
}

# ------------------------------------------------------------------- main
switch ($Action) {
    'init-schema' { Invoke-InitSchema }
    'sync'        { Invoke-Sync }
    'export'      { Invoke-Export }
}
