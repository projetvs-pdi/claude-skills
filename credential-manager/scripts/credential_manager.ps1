<#
.SYNOPSIS
    Credential Manager - Gerenciador seguro de credenciais (PowerShell nativo, sem dependencias).

.DESCRIPTION
    Usa DPAPI do Windows (ConvertTo-SecureString / ConvertFrom-SecureString) para
    criptografar a senha, vinculada ao usuario e maquina atuais. O blob criptografado
    fica em disco em: $env:LOCALAPPDATA\credential-manager\<service>__<username>.cred
    Ninguem alem do usuario/maquina que criou o blob consegue descriptografa-lo.

.PARAMETER Action
    save | load | delete | exists | get-or-prompt

.PARAMETER Username
    Identificador do usuario (ex.: email)

.PARAMETER Password
    Senha em texto plano (apenas para 'save'). Evite passar em linha de comando quando
    possivel; prefira 'get-or-prompt' que pede via Read-Host -AsSecureString.

.PARAMETER Service
    Nome do servico/aplicacao (padrao: simples-agenda). Permite armazenar credenciais
    de multiplas aplicacoes sem colisao.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File credential_manager.ps1 -Action save -Username user@ex.com -Password minhasenha -Service simples-agenda

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File credential_manager.ps1 -Action load -Username user@ex.com -Service simples-agenda
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("save", "load", "delete", "exists", "get-or-prompt")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [string]$Password,

    [string]$Service = "simples-agenda",

    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Get-CredentialStoreDir {
    # Por padrao o cofre fica em %LOCALAPPDATA%, mas em maquina com perfil
    # roaming corporativo (ou pasta sincronizada) esse diretorio nao e estavel:
    # observamos o arquivo de credencial voltar sozinho a uma versao anterior
    # COM o timestamp antigo preservado - assinatura de restauracao por agente
    # de perfil/sync, nao de escrita normal. O efeito e um save que aparenta ter
    # funcionado e minutos depois volta a entregar a senha antiga.
    #
    # CLAUDE_SKILLS_CRED_DIR aponta o cofre para fora do perfil. O blob DPAPI
    # continua valido: ele e vinculado a usuario+maquina, nunca ao caminho.
    $override = $env:CLAUDE_SKILLS_CRED_DIR
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        # Falhar alto: cair de volta no diretorio instavel reintroduziria o bug
        # que este override existe para evitar.
        if (-not (Test-Path $override)) {
            New-Item -ItemType Directory -Path $override -Force -ErrorAction Stop | Out-Null
        }
        return $override
    }
    $dir = Join-Path $env:LOCALAPPDATA "credential-manager"
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-CredentialFilePath {
    param([string]$ServiceName, [string]$User)
    # Sanitiza nomes para uso seguro em nome de arquivo
    $safeService = ($ServiceName -replace '[^a-zA-Z0-9_.-]', '_')
    $safeUser = ($User -replace '[^a-zA-Z0-9_.@-]', '_')
    $dir = Get-CredentialStoreDir
    return Join-Path $dir "$safeService`__$safeUser.cred"
}

function Save-Credential {
    param([string]$ServiceName, [string]$User, [string]$PlainPassword)

    $path = Get-CredentialFilePath -ServiceName $ServiceName -User $User
    try {
        $secure = ConvertTo-SecureString -String $PlainPassword -AsPlainText -Force
        $encrypted = ConvertFrom-SecureString -SecureString $secure
        Set-Content -Path $path -Value $encrypted -Encoding UTF8 -Force
        return $true
    }
    catch {
        Write-Host "[ERRO] Falha ao salvar credenciais: $_"
        return $false
    }
}

function Load-Credential {
    param([string]$ServiceName, [string]$User)

    $path = Get-CredentialFilePath -ServiceName $ServiceName -User $User
    if (-not (Test-Path $path)) {
        return $null
    }
    try {
        $encrypted = Get-Content -Path $path -Raw
        $secure = ConvertTo-SecureString -String $encrypted.Trim()
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        return $plain
    }
    catch {
        Write-Host "[ERRO] Falha ao carregar credenciais (blob corrompido ou de outro usuario/maquina): $_"
        return $null
    }
}

function Remove-Credential {
    param([string]$ServiceName, [string]$User)

    $path = Get-CredentialFilePath -ServiceName $ServiceName -User $User
    if (Test-Path $path) {
        try {
            Remove-Item -Path $path -Force -Confirm:$false
            return $true
        }
        catch {
            Write-Host "[ERRO] Falha ao deletar credenciais: $_"
            return $false
        }
    }
    # Ja nao existe - nao e erro
    return $true
}

function Test-CredentialExists {
    param([string]$ServiceName, [string]$User)
    $path = Get-CredentialFilePath -ServiceName $ServiceName -User $User
    return (Test-Path $path)
}

# ===== Execucao principal =====

switch ($Action) {
    "save" {
        if (-not $Password) {
            Write-Host "[ERRO] -Password e obrigatorio para 'save'"
            exit 1
        }
        $ok = Save-Credential -ServiceName $Service -User $Username -PlainPassword $Password
        if ($Json) {
            @{ success = $ok } | ConvertTo-Json -Compress
        }
        if (-not $ok) { exit 1 }
        if (-not $Json) { Write-Host "[OK] Credenciais salvas para $Username" }
    }

    "load" {
        $pwd = Load-Credential -ServiceName $Service -User $Username
        if ($null -eq $pwd) {
            if ($Json) {
                @{ found = $false } | ConvertTo-Json -Compress
            }
            else {
                Write-Host "[ERRO] Credenciais nao encontradas para $Username"
            }
            exit 1
        }
        if ($Json) {
            @{ found = $true; password = $pwd } | ConvertTo-Json -Compress
        }
        else {
            Write-Output $pwd
        }
    }

    "delete" {
        $ok = Remove-Credential -ServiceName $Service -User $Username
        if ($Json) {
            @{ success = $ok } | ConvertTo-Json -Compress
        }
        if (-not $ok) { exit 1 }
        if (-not $Json) { Write-Host "[OK] Credenciais deletadas para $Username" }
    }

    "exists" {
        $exists = Test-CredentialExists -ServiceName $Service -User $Username
        if ($Json) {
            @{ exists = $exists } | ConvertTo-Json -Compress
        }
        else {
            Write-Output $(if ($exists) { "sim" } else { "nao" })
        }
    }

    "get-or-prompt" {
        $pwd = Load-Credential -ServiceName $Service -User $Username
        if ($null -ne $pwd) {
            if ($Json) {
                @{ username = $Username; password = $pwd } | ConvertTo-Json -Compress
            }
            else {
                Write-Output "$Username`:$pwd"
            }
            exit 0
        }

        Write-Host "[*] Credenciais nao encontradas para $Username"
        $secureInput = Read-Host -Prompt "Senha" -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureInput)
        try {
            $plainInput = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        if (-not $plainInput) {
            Write-Host "[CANCELADO] Operacao abortada pelo usuario"
            exit 1
        }

        $saveChoice = Read-Host -Prompt "Salvar credenciais para proximas vezes? [s/N]"
        if ($saveChoice -match '^(s|sim|y|yes)$') {
            if (Save-Credential -ServiceName $Service -User $Username -PlainPassword $plainInput) {
                Write-Host "[OK] Credenciais salvas com seguranca"
            }
            else {
                Write-Host "[AVISO] Credenciais nao puderam ser salvas, mas serao usadas agora"
            }
        }

        if ($Json) {
            @{ username = $Username; password = $plainInput } | ConvertTo-Json -Compress
        }
        else {
            Write-Output "$Username`:$plainInput"
        }
    }
}
