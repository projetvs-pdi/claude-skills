<#
.SYNOPSIS
    Resolve a origem dos arquivos do site (pasta local, GitHub ou GitLab) para
    uma pasta local pronta para deploy no CloudFlare Pages, usada pela skill
    "publicacao-dominio-cloudflare".

.DESCRIPTION
    -SourceType local   -> apenas valida que -Path existe e devolve o caminho
    -SourceType github  -> clona (ou atualiza, se já clonado antes) o repositório
    -SourceType gitlab  -> idem, para GitLab

    Repos privados usam as credenciais Git já configuradas na máquina do
    usuário (Git Credential Manager / SSH) — este script não pede nem
    armazena token de GitHub/GitLab; se o clone falhar por permissão, avisa o
    usuário para configurar o acesso Git normalmente (gh auth login, SSH key,
    etc.) e tentar de novo.

.PARAMETER SourceType
    local | github | gitlab

.PARAMETER Path
    Obrigatório para -SourceType local: caminho da pasta com os arquivos do site.

.PARAMETER RepoUrl
    Obrigatório para -SourceType github/gitlab: URL do repositório
    (https://github.com/usuario/repo.git ou https://gitlab.com/usuario/repo.git).

.PARAMETER Branch
    Branch a usar (padrão: a branch default do repositório).

.PARAMETER SubPath
    Subpasta dentro do repositório onde está o site estático, se não for a
    raiz (ex.: "public", "dist", "site").

.PARAMETER WorkDir
    Pasta onde clonar repositórios. Padrão: pasta temp do usuário
    (%TEMP%\cloudflare-pages-deploy\<nome-repo>).

.OUTPUTS
    JSON com { path, source_type, ready }.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('local', 'github', 'gitlab')]
    [string]$SourceType,

    [string]$Path,
    [string]$RepoUrl,
    [string]$Branch,
    [string]$SubPath,
    [string]$WorkDir
)

$ErrorActionPreference = 'Stop'

function Write-Result($resolvedPath, $ready, $note) {
    [PSCustomObject]@{
        source_type = $SourceType
        path        = $resolvedPath
        ready       = $ready
        note        = $note
    } | ConvertTo-Json
}

switch ($SourceType) {
    'local' {
        if (-not $Path) { throw '-Path é obrigatório para -SourceType local' }
        $full = Resolve-Path -Path $Path -ErrorAction SilentlyContinue
        if (-not $full) { throw "Pasta não encontrada: $Path" }
        $hasFiles = Get-ChildItem -Path $full -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $hasFiles) { throw "A pasta $full existe mas está vazia." }
        Write-Result -resolvedPath $full.Path -ready $true -note 'Pasta local validada.'
    }
    { $_ -in 'github', 'gitlab' } {
        if (-not $RepoUrl) { throw '-RepoUrl é obrigatório para -SourceType github/gitlab' }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw "Git não está instalado ou não está no PATH. Instale o Git for Windows para clonar repositórios."
        }

        $repoName = [System.IO.Path]::GetFileNameWithoutExtension(($RepoUrl -split '/')[-1])
        if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP 'cloudflare-pages-deploy' }
        New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
        $cloneDir = Join-Path $WorkDir $repoName

        # git escreve progresso normal no stderr; com $ErrorActionPreference='Stop'
        # isso vira exceção falsa mesmo em sucesso. Baixamos para 'Continue'
        # ao redor das chamadas git e checamos $LASTEXITCODE manualmente.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if (Test-Path (Join-Path $cloneDir '.git')) {
                Push-Location $cloneDir
                try {
                    git fetch origin *>&1 | Out-Null
                    $targetBranch = if ($Branch) { $Branch } else { (git remote show origin | Select-String 'HEAD branch' | ForEach-Object { ($_ -split ':')[1].Trim() }) }
                    git checkout $targetBranch *>&1 | Out-Null
                    git pull origin $targetBranch *>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Falha ao atualizar o repositório (branch '$targetBranch')." }
                } finally {
                    Pop-Location
                }
            } else {
                $cloneArgs = @('clone', '--depth', '1')
                if ($Branch) { $cloneArgs += @('--branch', $Branch) }
                $cloneArgs += @($RepoUrl, $cloneDir)
                $gitOut = & git @cloneArgs *>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    throw "Falha ao clonar $RepoUrl : $gitOut`nSe o repositório é privado, configure o acesso Git da máquina (gh auth login / chave SSH) e tente de novo."
                }
            }
        } finally {
            $ErrorActionPreference = $prevEap
        }

        $finalPath = if ($SubPath) { Join-Path $cloneDir $SubPath } else { $cloneDir }
        if (-not (Test-Path $finalPath)) { throw "Subpasta '$SubPath' não encontrada dentro do repositório clonado." }
        Write-Result -resolvedPath $finalPath -ready $true -note "Repositório clonado/atualizado em $cloneDir."
    }
}
