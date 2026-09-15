<#
.SYNOPSIS
    Helper de linha de comando para a API REST da CloudFlare (v4), usado pela
    skill "publicacao-dominio-cloudflare". Concentra todas as chamadas HTTP
    num único script para que a skill nunca precise montar JSON/headers na mão.

.DESCRIPTION
    Ações suportadas (-Action):
      whoami            -> valida o token e mostra a conta associada
      find-zone         -> procura zona existente para um domínio
      create-zone       -> cria a zona (site) do domínio na conta CloudFlare
      zone-status       -> consulta status da zona (pending/active) e nameservers
      create-pages      -> cria um projeto CloudFlare Pages vazio
      attach-pages-domain -> anexa domínio customizado a um projeto Pages
      create-dns-record -> cria registro DNS (A/CNAME) manualmente
      list-dns-records  -> lista registros DNS de uma zona
      list-pages-projects -> lista projetos CloudFlare Pages de uma conta
      find-pages-project  -> acha o projeto Pages cujo domínio (customizado
                             ou *.pages.dev) bate com -Domain

    O token nunca é impresso; é lido do cofre do credential-manager (service
    "cloudflare-domain-publisher") ou recebido via -ApiToken (uso pontual,
    ex. testes) e nunca deve ser logado pelo chamador.

.NOTES
    Requer PowerShell 5.1+. Sem dependências externas (usa Invoke-RestMethod).
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('whoami', 'find-zone', 'create-zone', 'zone-status', 'create-pages', 'attach-pages-domain', 'create-dns-record', 'list-dns-records', 'list-pages-projects', 'find-pages-project')]
    [string]$Action,

    [string]$ApiToken,          # opcional: se omitido, carrega do credential-manager
    [string]$Domain,            # ex.: exemplo.com.br (sem www)
    [string]$ZoneId,
    [string]$AccountId,
    [string]$ProjectName,       # nome do projeto CloudFlare Pages
    [string]$RecordType = 'CNAME',
    [string]$RecordName,        # ex.: www
    [string]$RecordContent,     # ex.: meu-projeto.pages.dev ou IP
    [switch]$Proxied,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Get-CFToken {
    if ($ApiToken) { return $ApiToken }
    $credScript = Join-Path $PSScriptRoot '..\..\credential-manager\scripts\credential_manager.ps1'
    if (-not (Test-Path $credScript)) {
        throw "credential-manager não encontrado em $credScript. Rode com -ApiToken ou instale a skill credential-manager."
    }
    $out = & $credScript -Action get-or-prompt -Username 'cloudflare-api-token' -Service 'cloudflare-domain-publisher' -Json
    $parsed = $out | ConvertFrom-Json
    # get-or-prompt retorna "username:password" fora do modo Json; em Json, campo password
    if ($parsed.password) { return $parsed.password }
    throw "Não foi possível obter o CloudFlare API Token do cofre."
}

function Invoke-CF {
    param(
        [string]$Method,
        [string]$Path,
        [hashtable]$Body
    )
    $token = Get-CFToken
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $uri = "https://api.cloudflare.com/client/v4$Path"
    $params = @{ Method = $Method; Uri = $uri; Headers = $headers }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10) }
    try {
        return Invoke-RestMethod @params
    } catch {
        $resp = $_.ErrorDetails.Message
        throw "Chamada CloudFlare API falhou ($Method $Path): $resp"
    }
}

function Write-Out($obj) {
    if ($Json) { $obj | ConvertTo-Json -Depth 10 }
    else { $obj | Format-List | Out-String | Write-Output }
}

switch ($Action) {
    'whoami' {
        $r = Invoke-CF -Method GET -Path '/user/tokens/verify'
        Write-Out $r.result
    }
    'find-zone' {
        if (-not $Domain) { throw '-Domain é obrigatório para find-zone' }
        $r = Invoke-CF -Method GET -Path "/zones?name=$Domain"
        Write-Out $r.result
    }
    'create-zone' {
        if (-not $Domain) { throw '-Domain é obrigatório para create-zone' }
        $body = @{ name = $Domain }
        if ($AccountId) { $body.account = @{ id = $AccountId } }
        $r = Invoke-CF -Method POST -Path '/zones' -Body $body
        Write-Out $r.result
    }
    'zone-status' {
        if (-not $ZoneId) { throw '-ZoneId é obrigatório para zone-status' }
        $r = Invoke-CF -Method GET -Path "/zones/$ZoneId"
        Write-Out $r.result
    }
    'create-pages' {
        if (-not $AccountId -or -not $ProjectName) { throw '-AccountId e -ProjectName são obrigatórios para create-pages' }
        $body = @{ name = $ProjectName; production_branch = 'main' }
        $r = Invoke-CF -Method POST -Path "/accounts/$AccountId/pages/projects" -Body $body
        Write-Out $r.result
    }
    'attach-pages-domain' {
        if (-not $AccountId -or -not $ProjectName -or -not $Domain) { throw '-AccountId, -ProjectName e -Domain são obrigatórios' }
        $body = @{ name = $Domain }
        $r = Invoke-CF -Method POST -Path "/accounts/$AccountId/pages/projects/$ProjectName/domains" -Body $body
        Write-Out $r.result
    }
    'create-dns-record' {
        if (-not $ZoneId -or -not $RecordName -or -not $RecordContent) { throw '-ZoneId, -RecordName e -RecordContent são obrigatórios' }
        $body = @{ type = $RecordType; name = $RecordName; content = $RecordContent; proxied = [bool]$Proxied }
        $r = Invoke-CF -Method POST -Path "/zones/$ZoneId/dns_records" -Body $body
        Write-Out $r.result
    }
    'list-dns-records' {
        if (-not $ZoneId) { throw '-ZoneId é obrigatório para list-dns-records' }
        $r = Invoke-CF -Method GET -Path "/zones/$ZoneId/dns_records"
        Write-Out $r.result
    }
    'list-pages-projects' {
        if (-not $AccountId) { throw '-AccountId é obrigatório para list-pages-projects' }
        $r = Invoke-CF -Method GET -Path "/accounts/$AccountId/pages/projects"
        Write-Out $r.result
    }
    'find-pages-project' {
        if (-not $AccountId -or -not $Domain) { throw '-AccountId e -Domain são obrigatórios para find-pages-project' }
        $needle = $Domain.ToLower() -replace '^www\.', ''
        $r = Invoke-CF -Method GET -Path "/accounts/$AccountId/pages/projects"
        $match = $r.result | Where-Object {
            $candidates = @($_.subdomain, $_.name) + $_.domains
            $candidates | Where-Object { $_ -and ($_.ToLower() -replace '^www\.', '') -eq $needle }
        } | Select-Object -First 1
        Write-Out $match
    }
}
