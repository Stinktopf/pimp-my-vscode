#requires -Version 5.1
<#
.SYNOPSIS
  Launch a conflict-free VS Code environment for LaTeX Workshop or vscode-pdf.
.DESCRIPTION
  Uses supported --user-data-dir and --extensions-dir isolation, not VS Code
  profile creation. Each mode has its own user-local data and extension tree.
  Existing VS Code profiles, global extensions, and user settings are untouched.
.EXAMPLE
  .\pdf-mode.cmd -Mode LaTeX
.EXAMPLE
  .\pdf-mode.cmd -Mode PDF -Workspace "C:\Work\My Notes"
.EXAMPLE
  .\pdf-mode.cmd -Mode LaTeX -NoLaunch
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('LaTeX', 'PDF')]
    [string]$Mode,
    [string]$Workspace,
    [string]$CliPath,
    [string]$StateRoot,
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\VSCode.Extensions.ps1')
. (Join-Path $PSScriptRoot 'scripts\Tectonic.Core.ps1')
. (Join-Path $PSScriptRoot 'scripts\VSCode.LaTeX.ps1')

function Resolve-CodeCli {
    if (-not [string]::IsNullOrWhiteSpace($CliPath)) {
        $path = (Resolve-Path -LiteralPath $CliPath -ErrorAction Stop).ProviderPath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            ([IO.Path]::GetExtension($path) -notin @('.cmd', '.exe'))) {
            throw '-CliPath must point to an existing VS Code .cmd or .exe.'
        }
        return $path
    }
    $found = Get-VSCodeCliPath
    if (-not $found) { throw 'VS Code CLI not found. Install VS Code first or specify -CliPath.' }
    return $found
}

function Get-ModeExtensions([string]$Cli, [string]$DataDir, [string]$ExtensionsDir) {
    $exitCode = 1
    $args = @('--list-extensions', '--user-data-dir', $DataDir, '--extensions-dir', $ExtensionsDir)
    $lines = @(Invoke-VSCodeCli -CliPath $Cli -CliArguments $args -ExitCode ([ref]$exitCode) -QuietDep0169)
    if ($exitCode -ne 0) { throw 'Could not list extensions in the isolated mode.' }
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $candidate = ([string]$line).Trim()
        if ($candidate -cmatch '^[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+$') { $found.Add($candidate) }
    }
    return $found.ToArray()
}

try {
    if ($env:OS -ne 'Windows_NT') { throw 'The mode launcher requires Windows.' }
    $cli = Resolve-CodeCli
    $workspacePath = if ([string]::IsNullOrWhiteSpace($Workspace)) {
        $PSScriptRoot
    } else {
        (Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).ProviderPath
    }
    if (-not (Test-Path -LiteralPath $workspacePath -PathType Container)) {
        throw "Workspace directory not found: $workspacePath"
    }
    $baseDir = if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        [IO.Path]::GetFullPath($StateRoot)
    } elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $modern = Join-Path $env:LOCALAPPDATA 'pimp-my-vscode\modes'
        # Keep existing isolated environments and installed extensions after a rename.
        $existing = $null
        foreach ($priorName in @('pimpy-my-vscode', 'VSCodeSetup')) {
            $priorDir = Join-Path $env:LOCALAPPDATA ($priorName + '\modes')
            if ((Test-Path -LiteralPath $priorDir -PathType Container) -and
                -not (Test-Path -LiteralPath $modern -PathType Container)) {
                $existing = $priorDir
                break
            }
        }
        if ($existing) { $existing } else { $modern }
    } else {
        throw 'LOCALAPPDATA is unavailable. Set -StateRoot to a writable directory.'
    }
    $modeDir = Join-Path $baseDir $Mode.ToLowerInvariant()
    $dataDir = Join-Path $modeDir 'user-data'
    $extensionsDir = Join-Path $modeDir 'extensions'
    foreach ($dir in @($dataDir, $extensionsDir)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
    }

    $manifestPath = Join-Path $PSScriptRoot 'config\extensions.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne 2 -or @($manifest.extensions).Count -ne 14 -or
        @($manifest.conflicts) -notcontains 'tomoki1207.pdf') {
        throw 'Unexpected extension manifest.'
    }
    $latexId = 'James-Yu.latex-workshop'
    $pdfId = 'tomoki1207.pdf'
    $selected = if ($Mode -eq 'LaTeX') { $latexId } else { $pdfId }
    $opposite = if ($Mode -eq 'LaTeX') { $pdfId } else { $latexId }
    $wanted = @($manifest.extensions | Where-Object { $_ -ine $latexId }) + @($selected)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $wanted) {
        if ([string]$id -cnotmatch '^[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+$' -or
            -not $seen.Add([string]$id)) {
            throw "Invalid or duplicate extension ID: $id"
        }
    }

    $installed = @(Get-ModeExtensions -Cli $cli -DataDir $dataDir -ExtensionsDir $extensionsDir)
    if (Test-InstalledExtension -Ids $installed -Id $opposite) {
        throw "Both PDF extensions were found in $extensionsDir. This environment was modified outside the setup; disable or remove $opposite there manually. No extensions were removed by this script."
    }
    $missing = @($wanted | Where-Object { -not (Test-InstalledExtension -Ids $installed -Id $_) })
    if ($missing.Count -gt 0) {
        Write-Host "Preparing $Mode mode: installing $($missing.Count) extension(s) into an isolated directory..."
        $installArgs = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $missing) {
            $installArgs.Add('--install-extension')
            $installArgs.Add([string]$id)
        }
        $installArgs.Add('--user-data-dir')
        $installArgs.Add($dataDir)
        $installArgs.Add('--extensions-dir')
        $installArgs.Add($extensionsDir)
        $exitCode = 1
        Invoke-VSCodeCli -CliPath $cli -CliArguments $installArgs.ToArray() -ExitCode ([ref]$exitCode) -QuietDep0169
        if ($exitCode -ne 0) {
            Write-Warning 'VS Code reported an extension installation error; checking the actual result.'
        }
    }
    $verified = @(Get-ModeExtensions -Cli $cli -DataDir $dataDir -ExtensionsDir $extensionsDir)
    if (Test-InstalledExtension -Ids $verified -Id $opposite) {
        throw "Conflicting PDF extension detected in $Mode mode: $opposite."
    }
    $failed = @($wanted | Where-Object { -not (Test-InstalledExtension -Ids $verified -Id $_) })
    if ($failed.Count -gt 0) { throw "Incomplete $Mode environment: $($failed -join ', ')." }

    if ($Mode -eq 'LaTeX') {
        # Installed outside the setup ZIP so other repositories do not need its scripts.
        $wrapper = Install-LocalLaTeXRuntime -SourceRoot $PSScriptRoot -ModesRoot $baseDir
        Set-IsolatedLaTeXSettings -DataDir $dataDir -ModesRoot $baseDir -BuildScript $wrapper
    }

    if (-not $NoLaunch) {
        Write-Host "Opening VS Code in $Mode mode (separate user data and extensions)..."
        # Keep --new-window: never reuse an existing window with a different extension set.
        $exitCode = 1
        $args = @('--new-window', '--user-data-dir', $dataDir, '--extensions-dir', $extensionsDir, $workspacePath)
        Invoke-VSCodeCli -CliPath $cli -CliArguments $args -ExitCode ([ref]$exitCode)
        if ($exitCode -ne 0) { throw 'VS Code could not open the isolated window.' }
    }
    Write-Host "Ready: $Mode mode; $($wanted.Count) verified extensions. Existing VS Code unchanged."
    if (-not $NoLaunch) {
        Write-Host 'Use .\pdf-mode.cmd to switch modes; launch through this script for isolation.'
    }
    exit 0
} catch {
    Write-Error ('PDF mode failed: ' + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
