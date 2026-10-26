#requires -Version 5.1
# Helpers only: VS Code CLI discovery and extension-ID checks.
# No global VS Code settings or extensions are modified by these functions.
Set-StrictMode -Version Latest

function Get-VSCodeCliPath {
    # Prefer installed, known VS Code locations over executable names from PATH.
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates += Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin\code.cmd'
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

# Suppress only the known VS Code/Node DEP0169 warning while running the CLI.
# Restore NODE_OPTIONS, even if the CLI fails. Do not silence other warnings.
function Invoke-VSCodeCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CliPath,
        [Parameter(Mandatory = $true)][string[]]$CliArguments,
        [Parameter(Mandatory = $true)][ref]$ExitCode,
        [switch]$QuietDep0169
    )
    $wasSet = Test-Path -LiteralPath 'Env:NODE_OPTIONS'
    $saved = if ($wasSet) { [string]$env:NODE_OPTIONS } else { '' }
    $ExitCode.Value = 1
    try {
        if ($QuietDep0169 -and $saved -notmatch '(?:^|\s)--disable-warning=DEP0169(?:\s|$)') {
            $env:NODE_OPTIONS = ($saved.Trim() + ' --disable-warning=DEP0169').Trim()
        }
        & $CliPath @CliArguments
        $ExitCode.Value = [int]$LASTEXITCODE
    } finally {
        if ($wasSet) { $env:NODE_OPTIONS = $saved }
        else { Remove-Item -LiteralPath 'Env:NODE_OPTIONS' -ErrorAction SilentlyContinue }
    }
}

function Get-VSCodeExtensionIds([string]$CliPath) {
    if ([string]::IsNullOrWhiteSpace($CliPath) -or
        -not (Test-Path -LiteralPath $CliPath -PathType Leaf)) {
        throw 'A valid VS Code CLI path is required.'
    }
    # Filter the CLI's single known deprecation only; keep exit status authoritative.
    $exitCode = 1
    $lines = @(Invoke-VSCodeCli -CliPath $CliPath -CliArguments @('--list-extensions') -ExitCode ([ref]$exitCode) -QuietDep0169 2>$null)
    if ($exitCode -ne 0) { throw 'Could not query installed VS Code extensions.' }
    foreach ($line in $lines) {
        $id = ([string]$line).Trim()
        if ($id -match '^[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+$') { Write-Output $id }
    }
}

function Test-InstalledExtension([string[]]$Ids, [string]$Id) {
    foreach ($candidate in @($Ids)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            $candidate.Trim() -ieq $Id) { return $true }
    }
    return $false
}
