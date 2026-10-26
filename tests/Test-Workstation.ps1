#requires -Version 5.1
# Offline Windows test: exercises the real workstation CLI against a local mock.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testDir = $null
$originalNodeOptionsExists = Test-Path -LiteralPath 'Env:NODE_OPTIONS'
$originalNodeOptions = if ($originalNodeOptionsExists) { $env:NODE_OPTIONS } else { $null }
try {
    if ($env:OS -ne 'Windows_NT') { throw 'Windows is required for the .cmd CLI test.' }
    $root = Split-Path -Parent $PSScriptRoot
    $testDir = Join-Path $env:TEMP ('workstation cli with spaces ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testDir | Out-Null
    $cli = Join-Path $testDir 'code.cmd'
    $installed = Join-Path $testDir 'installed.txt'
    $snapshotPath = Join-Path $testDir 'extension snapshot.json'
    $log = Join-Path $testDir 'install.log'
    @'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
if /I "%~1"=="--list-extensions" (
  echo %NODE_OPTIONS%>>"%~dp0node-options.log"
  type "%~dp0installed.txt"
  exit /b 0
)
if /I "%~1"=="--uninstall-extension" (
  if /I not "%~2"=="tomoki1207.pdf" exit /b 8
  findstr /I /L /V /X /C:"tomoki1207.pdf" "%~dp0installed.txt" > "%~dp0removed.tmp"
  move /Y "%~dp0removed.tmp" "%~dp0installed.txt" >NUL
  echo removed>>"%~dp0uninstall.log"
  exit /b 0
)
if /I "%~1"=="--install-extension" (
  echo %NODE_OPTIONS%>>"%~dp0node-options.log"
  echo call>>"%~dp0install-calls.log"
  goto add
)
exit /b 7
:add
if "%~1"=="" exit /b 0
if /I not "%~1"=="--install-extension" exit /b 7
if "%~2"=="" exit /b 7
echo %~2>>"%~dp0installed.txt"
echo %~2>>"%~dp0install.log"
shift
shift
goto add
'@ | Set-Content -LiteralPath $cli -Encoding Ascii
    $originalNodeOptionsExists = Test-Path -LiteralPath 'Env:NODE_OPTIONS'
    $originalNodeOptions = if ($originalNodeOptionsExists) { $env:NODE_OPTIONS } else { $null }
    $env:NODE_OPTIONS = '--trace-warnings'
    @('tomoki1207.pdf', 'Example.Abc') | Set-Content -LiteralPath $installed -Encoding Ascii

    # Default installation must contain the entire fixed inventory (no preset selection).
    $expectedManifest = Get-Content -LiteralPath (Join-Path $root 'config\extensions.json') -Raw | ConvertFrom-Json
    $expected = @($expectedManifest.extensions)
    if ($expected.Count -ne 14) { throw 'Expected full workstation inventory.' }
    & (Join-Path $root 'pimp-my-vscode.ps1') -Action Install -SkipLaTeX -CliPath $cli
    if ($LASTEXITCODE -ne 0) { throw 'Default full workstation installation failed.' }
    $attempted = @(Get-Content -LiteralPath $log)
    if ($attempted.Count -ne 14) { throw 'Default installation did not install all 14 extensions.' }
    if (@(Get-Content -LiteralPath (Join-Path $testDir 'install-calls.log')).Count -ne 1) {
        throw 'Extension installation should use one CLI call, not one process per extension.'
    }
    foreach ($item in $expected) {
        if (@($attempted | Where-Object { $_ -ieq $item }).Count -ne 1) {
            throw "Extension missing or duplicated: $item"
        }
    }
    & (Join-Path $root 'pimp-my-vscode.ps1') -Action Install -SkipLaTeX -CliPath $cli
    if ($LASTEXITCODE -ne 0 -or @(Get-Content -LiteralPath $log).Count -ne 14 -or
        @(Get-Content -LiteralPath (Join-Path $testDir 'install-calls.log')).Count -ne 1) {
        throw 'Re-running the installer was not idempotent.'
    }
    & (Join-Path $root 'pimp-my-vscode.ps1') -Action Check -CliPath $cli
    if ($LASTEXITCODE -ne 0) { throw 'Fixed inventory check failed.' }

    & (Join-Path $root 'pimp-my-vscode.ps1') -Action Capture -CliPath $cli -SnapshotPath $snapshotPath
    if ($LASTEXITCODE -ne 0) { throw 'Snapshot capture failed.' }
    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json
    if (@($snapshot.ids).Count -ne 16 -or
        @($snapshot.ids) -notcontains 'tomoki1207.pdf' -or
        @($snapshot.ids) -notcontains 'Example.Abc') { throw 'Snapshot inventory is incomplete.' }

    # Restore is a separate optional maintenance action, not an install preset.
    @('tomoki1207.pdf') | Set-Content -LiteralPath $installed -Encoding Ascii
    Remove-Item -LiteralPath $log -Force
    & (Join-Path $root 'pimp-my-vscode.ps1') -Action Restore -CliPath $cli -SnapshotPath $snapshotPath
    if ($LASTEXITCODE -ne 0) { throw 'Snapshot restore failed.' }
    $attempted = @(Get-Content -LiteralPath $log)
    if ($attempted.Count -ne 15 -or @($attempted | Where-Object { $_ -ieq 'tomoki1207.pdf' }).Count -gt 0) {
        throw 'Restore did not filter the PDF conflict or lost extensions.'
    }
    & (Join-Path $root 'pimp-my-vscode.ps1') -Action Restore -CliPath $cli -SnapshotPath $snapshotPath
    if ($LASTEXITCODE -ne 0 -or @(Get-Content -LiteralPath $log).Count -ne 15) {
        throw 'Re-running snapshot restore was not idempotent.'
    }

    # Malformed snapshots must fail before reaching the mock CLI.
    '{"schema":1,"ids":["bad & command"]}' | Set-Content -LiteralPath $snapshotPath -Encoding Ascii
    & (Join-Path $root 'pimp-my-vscode.ps1') -Action Restore -CliPath $cli -SnapshotPath $snapshotPath 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0 -or @(Get-Content -LiteralPath $log).Count -ne 15) {
        throw 'Invalid extension ID was accepted or invoked.'
    }
    # The default must never uninstall an existing extension. Opt-in removal is explicit.
    if (-not (Select-String -LiteralPath $installed -Pattern '^tomoki1207[.]pdf$' -Quiet)) {
        throw 'Default setup unexpectedly removed vscode-pdf.'
    }
    & (Join-Path $root 'pimp-my-vscode.ps1') -Action Check -UninstallVscodePdf -CliPath $cli 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'Conflict removal must be restricted to Install.' }
    & (Join-Path $root 'pimp-my-vscode.ps1') -Action Install -SkipLaTeX -UninstallVscodePdf -CliPath $cli
    if ($LASTEXITCODE -ne 0 -or
        (Select-String -LiteralPath $installed -Pattern '^tomoki1207[.]pdf$' -Quiet)) {
        throw 'Explicit vscode-pdf uninstallation failed.'
    }
    if (@(Get-Content -LiteralPath (Join-Path $testDir 'uninstall.log')).Count -ne 1) {
        throw 'Unexpected number of vscode-pdf uninstall calls.'
    }
    & (Join-Path $root 'pimp-my-vscode.ps1') -Action Install -SkipLaTeX -UninstallVscodePdf -CliPath $cli
    if ($LASTEXITCODE -ne 0 -or
        @(Get-Content -LiteralPath (Join-Path $testDir 'uninstall.log')).Count -ne 1) {
        throw 'Explicit conflict removal is not idempotent.'
    }
    $nodeOptions = @(Get-Content -LiteralPath (Join-Path $testDir 'node-options.log'))
    if (@($nodeOptions | Where-Object { $_ -notmatch '--disable-warning=DEP0169' }).Count -gt 0 -or
        $env:NODE_OPTIONS -cne '--trace-warnings') {
        throw 'Targeted CLI warning suppression or restoration failed.'
    }
    Write-Host 'Workstation mock-CLI tests passed (batch install, clean deprecation flag, idempotence, capture/restore, opt-in PDF removal).'  
    exit 0
} catch {
    Write-Error ("Workstation test failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
} finally {
    if ($originalNodeOptionsExists) { $env:NODE_OPTIONS = $originalNodeOptions }
    else { Remove-Item -LiteralPath 'Env:NODE_OPTIONS' -ErrorAction SilentlyContinue }
    if ($testDir -and (Test-Path -LiteralPath $testDir)) {
        Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
