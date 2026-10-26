#requires -Version 5.1
<#
.SYNOPSIS
  Reproducible Windows VS Code workstation setup. User-scoped, non-destructive.
.EXAMPLE
  .\pimp-my-vscode.cmd
.EXAMPLE
  .\pimp-my-vscode.cmd -Action Capture
.EXAMPLE
  .\pimp-my-vscode.cmd -Action Restore
.EXAMPLE
  .\pimp-my-vscode.cmd -Action Backup
.EXAMPLE
  .\pimp-my-vscode.cmd -UninstallVscodePdf  # explicitly removes vscode-pdf from the selected VS Code profile
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Capture', 'Restore', 'Check', 'Backup')]
    [string]$Action = 'Install',
    [switch]$SkipLaTeX,
    [switch]$SkipExtensions,
    [switch]$UninstallVscodePdf,
    [switch]$DryRun,
    [string]$VSCodeProfile,
    [string]$CliPath,
    [string]$SnapshotPath,
    [switch]$ForceCapture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\VSCode.Extensions.ps1')

function Assert-HostWindows {
    if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows.' }
}

function Get-Manifest {
    $path = Join-Path $PSScriptRoot 'config\extensions.json'
    $value = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($value.schema -ne 2 -or $null -eq $value.extensions -or $null -eq $value.conflicts) {
        throw 'Unsupported extension manifest schema.'
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (@($value.extensions).Count -eq 0) { throw 'Extension manifest is empty.' }
    foreach ($item in @($value.extensions)) {
        $id = [string]$item
        if ($id -cnotmatch '^[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+$') { throw "Invalid extension ID: $id" }
        if (-not $seen.Add($id)) { throw "Duplicate extension ID: $id" }
    }
    foreach ($item in @($value.conflicts)) {
        $id = [string]$item
        if ($id -cnotmatch '^[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+$') { throw "Invalid conflict extension ID: $id" }
        if ($seen.Contains($id)) { throw "Conflicting extension was recommended: $id" }
    }
    return $value
}

function Get-SnapshotFile {
    if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
        return (Join-Path $PSScriptRoot 'config\extensions.snapshot.json')
    }
    return [IO.Path]::GetFullPath($SnapshotPath)
}

function Assert-ExtensionIds([object[]]$Ids) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $output = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in $Ids) {
        $id = [string]$raw
        if ($id -cnotmatch '^[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+$') {
            throw "Unexpected extension ID: $id"
        }
        if ($seen.Add($id)) { $output.Add($id) }
    }
    return $output.ToArray()
}

function Get-DesiredExtensions($Manifest, [string]$Mode) {
    # A single built-in installation: the complete workstation extension inventory.
    $result = @($Manifest.extensions)
    if ($Mode -eq 'Restore') {
        $file = Get-SnapshotFile
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Extension snapshot not found: $file. Run -Action Capture first."
        }
        $snapshot = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($snapshot.schema -ne 1 -or $null -eq $snapshot.ids) {
            throw 'Invalid extension snapshot schema.'
        }
        $result = @($snapshot.ids)
        if (-not $result.Count) { throw 'Extension snapshot is empty.' }
    }
    $items = @(Assert-ExtensionIds $result)
    $filtered = @($items | Where-Object {
        $item = $_
        -not (@($Manifest.conflicts) | Where-Object { $_ -ieq $item })
    })
    return $filtered
}

function Get-CodeCli {
    if (-not [string]::IsNullOrWhiteSpace($CliPath)) {
        $resolved = (Resolve-Path -LiteralPath $CliPath -ErrorAction Stop).ProviderPath
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or
            ([IO.Path]::GetExtension($resolved) -notin @('.cmd', '.exe'))) {
            throw '-CliPath must reference an existing .cmd or .exe file.'
        }
        return $resolved
    }
    $found = Get-VSCodeCliPath
    if (-not $found) {
        throw 'VS Code CLI not found. Install the official VS Code user edition or pass -CliPath.'
    }
    return $found
}

function Get-CodeArgs([string[]]$Arguments) {
    $argsToUse = @($Arguments)
    if (-not [string]::IsNullOrWhiteSpace($VSCodeProfile)) {
        $argsToUse += @('--profile', $VSCodeProfile)
    }
    return $argsToUse
}

function Get-Installed([string]$Cli) {
    $argsToUse = @(Get-CodeArgs -Arguments @('--list-extensions'))
    $exitCode = 1
    $lines = @(Invoke-VSCodeCli -CliPath $Cli -CliArguments $argsToUse -ExitCode ([ref]$exitCode) -QuietDep0169 2>$null)
    if ($exitCode -ne 0) { throw 'VS Code CLI extension listing failed.' }
    $found = @()
    foreach ($line in $lines) {
        $id = ([string]$line).Trim()
        if ($id -cmatch '^[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+$') { $found += $id }
    }
    return @(Assert-ExtensionIds $found)
}

function Save-Snapshot([string]$Cli) {
    $file = Get-SnapshotFile
    $ids = @(Get-Installed $Cli | Sort-Object)
    if (-not $ids.Count) { throw 'VS Code CLI reported no extensions. Refusing to overwrite snapshot.' }
    if ((Test-Path -LiteralPath $file) -and -not $ForceCapture) {
        throw "Snapshot already exists: $file. Use -ForceCapture to replace it."
    }
    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $snapshot = [ordered]@{
        schema = 1
        capturedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        ids = @($ids)
    }
    $temp = Join-Path $dir ('.extensions-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, ($snapshot | ConvertTo-Json -Depth 5) + "`n", ([System.Text.UTF8Encoding]::new($false)))
        Move-Item -LiteralPath $temp -Destination $file -Force:$ForceCapture -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
    Write-Host "Captured $($ids.Count) extension IDs in $file"
    Write-Host 'Review this list before storing it in your own repository.'
}

function Save-UserBackup {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw 'APPDATA is not available.'
    }
    $source = Join-Path $env:APPDATA 'Code\User'
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "VS Code user configuration not found: $source"
    }
    $dir = Join-Path $PSScriptRoot ('backups\vscode-user-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
    $copied = 0
    foreach ($name in @('settings.json', 'keybindings.json')) {
        $file = Join-Path $source $name
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Copy-Item -LiteralPath $file -Destination (Join-Path $dir $name) -ErrorAction Stop
            $copied++
        }
    }
    $snippetDir = Join-Path $source 'snippets'
    if (Test-Path -LiteralPath $snippetDir -PathType Container) {
        Copy-Item -LiteralPath $snippetDir -Destination (Join-Path $dir 'snippets') -Recurse -ErrorAction Stop
        $copied++
    }
    if (-not $copied) { throw 'No user settings, keybindings or snippets were found.' }
    Write-Host "Local backup created: $dir"
    Write-Warning 'Backups may contain private data or tokens. Do not upload or commit them.'
}

try {
    Assert-HostWindows
    if ($Action -ne 'Install' -and ($SkipLaTeX -or $SkipExtensions -or $DryRun)) {
        throw '-SkipLaTeX, -SkipExtensions and -DryRun apply only to -Action Install.'
    }
    if ($ForceCapture -and $Action -ne 'Capture') { throw '-ForceCapture requires -Action Capture.' }
    if ($UninstallVscodePdf -and $Action -ne 'Install') { throw '-UninstallVscodePdf requires -Action Install.' }
    if ($UninstallVscodePdf -and ($SkipExtensions -or $DryRun)) { throw '-UninstallVscodePdf cannot be combined with -SkipExtensions or -DryRun.' }
    if ($Action -eq 'Backup') {
        Save-UserBackup
        exit 0
    }
    $manifest = Get-Manifest
    if ($Action -eq 'Capture') {
        $cli = Get-CodeCli
        Save-Snapshot $cli
        exit 0
    }

    if ($Action -eq 'Install' -and -not $SkipLaTeX) {
        if ($DryRun) { Write-Host 'Dry run: would install/verify user-local Tectonic.' }
        else {
            $script = Join-Path $PSScriptRoot 'setup.ps1'
            & $script -Install -SkipExtension
            if ($LASTEXITCODE -ne 0) { throw 'LaTeX setup failed; extension installation was skipped.' }
        }
    }
    if ($SkipExtensions -and $Action -eq 'Install') {
        Write-Host 'Skipping optional VS Code extension management.'
        exit 0
    }

    $desired = @(Get-DesiredExtensions $manifest $Action)
    $cli = Get-CodeCli
    $current = @(Get-Installed $cli)
    $pdfExtension = 'tomoki1207.pdf'
    $pdfIsInstalled = Test-InstalledExtension -Ids $current -Id $pdfExtension
    if ($UninstallVscodePdf) {
        if ($pdfIsInstalled) {
            Write-Host ('Uninstalling vscode-pdf from the selected VS Code profile ' +
                '(explicitly requested; affects all its workspaces)...')
            $removeArgs = @(Get-CodeArgs -Arguments @('--uninstall-extension', $pdfExtension))
            $exitCode = 1
            Invoke-VSCodeCli -CliPath $cli -CliArguments $removeArgs -ExitCode ([ref]$exitCode) -QuietDep0169
            if ($exitCode -ne 0) { throw 'VS Code CLI could not uninstall vscode-pdf.' }
            $current = @(Get-Installed $cli)
            if (Test-InstalledExtension -Ids $current -Id $pdfExtension) {
                throw 'vscode-pdf still appears installed after the uninstall command.'
            }
            Write-Host 'vscode-pdf removed. Reload or restart VS Code to deactivate it.'
        } else {
            Write-Host 'vscode-pdf is already absent; nothing to uninstall.'
        }
    }
    if ($Action -eq 'Restore') {
        foreach ($excluded in @($manifest.conflicts)) {
            Write-Host "Snapshot exclusions: $excluded (not reinstalled automatically)."
        }
    }
    $missing = @($desired | Where-Object { -not (Test-InstalledExtension -Ids $current -Id $_) })
    if ($Action -eq 'Check' -or $DryRun) {
        Write-Host "Workstation extensions: installed $($desired.Count - $missing.Count)/$($desired.Count); missing $($missing.Count)."
        foreach ($item in $missing) { Write-Host "  MISSING $item" }
        if ($Action -eq 'Check' -and $missing.Count -gt 0) { exit 2 }
        exit 0
    }

    if ($missing.Count -gt 0) {
        Write-Host "Installing $($missing.Count) VS Code extension(s) in one CLI invocation..."
        $installArgs = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $missing) {
            $installArgs.Add('--install-extension')
            $installArgs.Add([string]$item)
        }
        $argsToUse = @(Get-CodeArgs -Arguments $installArgs.ToArray())
        $exitCode = 1
        Invoke-VSCodeCli -CliPath $cli -CliArguments $argsToUse -ExitCode ([ref]$exitCode) -QuietDep0169
        if ($exitCode -ne 0) {
            Write-Warning 'The VS Code CLI returned a non-zero status; verifying actual installed extensions.'
        }
    }
    $after = @(Get-Installed $cli)
    $failed = @($desired | Where-Object { -not (Test-InstalledExtension -Ids $after -Id $_) })
    if ($failed.Count) {
        throw "Extension setup incomplete: $($failed -join ', ')."
    }
    Write-Host "pimp-my-vscode ready: $($desired.Count) requested extensions verified."
    if ($UninstallVscodePdf) {
        Write-Host 'Only vscode-pdf was eligible for removal by your explicit request.'
    } else {
        Write-Host 'Your existing extensions and VS Code user settings were not removed or overwritten.'
    }
} catch {
    Write-Error ("pimp-my-vscode failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
