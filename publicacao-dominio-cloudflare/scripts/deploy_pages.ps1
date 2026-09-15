<#
.SYNOPSIS
    Publica uma pasta local no CloudFlare Pages via Wrangler CLI. Usado como
    última etapa depois que scripts/prepare_source.ps1 resolveu a origem
    (local, GitHub ou GitLab) para uma pasta pronta.

.DESCRIPTION
    Requer Node.js instalado (roda `npx wrangler pages deploy`). O Wrangler
    usa o mesmo CloudFlare API Token do cofre (via variável de ambiente
    CLOUDFLARE_API_TOKEN) — não pede login interativo separado.

.PARAMETER FolderPath
    Pasta com os arquivos estáticos prontos (retornada por prepare_source.ps1).

.PARAMETER ProjectName
    Nome do projeto CloudFlare Pages (criado antes via cloudflare_api.ps1 -Action create-pages,
    ou já existente).

.OUTPUTS
    JSON com { deployed, url, raw_output }.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$FolderPath,

    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [Parameter(Mandatory = $true)]
    [string]$AccountId,

    [string]$ApiToken
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $FolderPath)) { throw "Pasta não encontrada: $FolderPath" }
if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    throw "Node.js/npx não encontrado no PATH. Instale o Node.js para publicar via Wrangler, ou publique manualmente pelo dashboard CloudFlare (Workers & Pages -> Upload assets)."
}

if (-not $ApiToken) {
    $credScript = Join-Path $PSScriptRoot '..\..\credential-manager\scripts\credential_manager.ps1'
    $out = & $credScript -Action load -Username 'cloudflare-api-token' -Service 'cloudflare-domain-publisher' -Json
    $parsed = $out | ConvertFrom-Json
    if (-not $parsed.found) { throw "CloudFlare API Token não encontrado no cofre. Salve-o antes (veja SKILL.md)." }
    $ApiToken = $parsed.password
}

$env:CLOUDFLARE_API_TOKEN = $ApiToken
$env:CLOUDFLARE_ACCOUNT_ID = $AccountId
# npm/npx/wrangler escrevem progresso e avisos no stderr; com
# $ErrorActionPreference='Stop' isso vira exceção falsa mesmo em sucesso.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $rawOutput = & npx wrangler pages deploy $FolderPath --project-name $ProjectName *>&1 | Out-String
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
    Remove-Item Env:\CLOUDFLARE_API_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\CLOUDFLARE_ACCOUNT_ID -ErrorAction SilentlyContinue
}

$deployed = $exitCode -eq 0
$urlMatch = $rawOutput | Select-String -Pattern 'https://[a-zA-Z0-9.-]+\.pages\.dev' | Select-Object -First 1
$url = if ($urlMatch) { $urlMatch.Matches[0].Value } else { $null }

[PSCustomObject]@{
    deployed   = $deployed
    url        = $url
    raw_output = ($rawOutput -join "`n")
} | ConvertTo-Json
