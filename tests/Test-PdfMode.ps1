#requires -Version 5.1
# Offline Windows regression for independent --user-data-dir / --extensions-dir modes.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testDir = $null
$originalNodeOptionsExists = Test-Path -LiteralPath 'Env:NODE_OPTIONS'
$originalNodeOptions = if ($originalNodeOptionsExists) { $env:NODE_OPTIONS } else { $null }
try {
    if ($env:OS -ne 'Windows_NT') { throw 'Windows is required for mock .cmd testing.' }
    $env:NODE_OPTIONS = '--trace-warnings'
    $root = Split-Path -Parent $PSScriptRoot
    $testDir = Join-Path $env:TEMP ('VS Code isolated modes with spaces ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testDir | Out-Null
    $cli = Join-Path $testDir 'code.cmd'
    @'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "OP=%~1"
if /I "%OP%"=="--new-window" (
  echo %NODE_OPTIONS%>>"%~dp0launch-node.log"
) else (
  echo %NODE_OPTIONS%>>"%~dp0node-options.log"
)
if /I "%OP%"=="--list-extensions" goto parse
if /I "%OP%"=="--install-extension" goto parse
if /I "%OP%"=="--new-window" goto parse
exit /b 40
:parse
set "UD="
set "ED="
set "FO="
:next
if "%~1"=="" goto done
if /I "%~1"=="--profile" exit /b 41
if /I "%~1"=="--user-data-dir" (
  set "UD=%~2"
  shift /1
  shift /1
  goto next
)
if /I "%~1"=="--extensions-dir" (
  set "ED=%~2"
  shift /1
  shift /1
  goto next
)
if /I "%~1"=="--install-extension" (
  if "%~2"=="" exit /b 42
  echo %~2>>"%~dp0pending.txt"
  shift /1
  shift /1
  goto next
)
if /I "%~1"=="--list-extensions" (
  shift /1
  goto next
)
if /I "%~1"=="--new-window" (
  shift /1
  goto next
)
set "FO=%~1"
shift /1
goto next
:done
if "%UD%"=="" exit /b 43
if "%ED%"=="" exit /b 44
if /I "%OP%"=="--new-window" goto open
if /I "%OP%"=="--install-extension" goto install
if /I "%OP%"=="--list-extensions" goto list
exit /b 45
:list
if exist "%ED%\ids.txt" type "%ED%\ids.txt"
exit /b 0
:install
if not exist "%ED%" exit /b 46
if not exist "%UD%" exit /b 47
if not exist "%~dp0pending.txt" exit /b 48
type "%~dp0pending.txt" >> "%ED%\ids.txt"
del /q "%~dp0pending.txt" >nul
 echo 1>>"%~dp0installs.log"
exit /b 0
:open
if "%FO%"=="" exit /b 49
if not exist "%UD%" exit /b 50
if not exist "%ED%" exit /b 51
 echo %ED%>>"%~dp0opens.log"
exit /b 0
'@ | Set-Content -LiteralPath $cli -Encoding Ascii
    $script = Join-Path $root 'pdf-mode.ps1'
    $state = Join-Path $testDir 'mode data'
    $workspace = Join-Path $testDir 'folder with spaces'
    New-Item -ItemType Directory -Path $workspace | Out-Null

    & $script -Mode LaTeX -CliPath $cli -StateRoot $state -Workspace $workspace -NoLaunch
    if ($LASTEXITCODE -ne 0 -or (Test-Path (Join-Path $testDir 'opens.log'))) {
        throw 'LaTeX NoLaunch failed or opened a VS Code window.'
    }
    $la = Join-Path $state 'latex\extensions\ids.txt'
    $pd = Join-Path $state 'pdf\extensions\ids.txt'
    $latex = @(Get-Content -LiteralPath $la)
    if ($latex.Count -ne 14 -or $latex -notcontains 'James-Yu.latex-workshop' -or
        $latex -contains 'tomoki1207.pdf') { throw 'LaTeX mode extension isolation failed.' }
    if (@(Get-Content (Join-Path $testDir 'installs.log')).Count -ne 1) {
        throw 'Expected one batched LaTeX installation.'
    }
    # Every unrelated workspace opened in this isolated mode inherits settings
    # pointing at a user-local wrapper, never the setup repository.
    $settingsPath = Join-Path $state 'latex\user-data\User\settings.json'
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $wrapper = [string]@($settings.'latex-workshop.latex.tools')[0].args[5]
    $expectedWrapper = Join-Path $state 'latex-runtime\scripts\tectonic-build.ps1'
    if (-not [IO.Path]::IsPathRooted($wrapper)) {
        throw "LaTeX build wrapper path is not absolute: $wrapper"
    }
    if (-not [string]::Equals([IO.Path]::GetFullPath($wrapper),
            [IO.Path]::GetFullPath($expectedWrapper),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "LaTeX build wrapper path mismatch. Expected: $expectedWrapper; got: $wrapper"
    }
    if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) {
        throw "Installed LaTeX build wrapper was not found: $wrapper"
    }
    if ($wrapper -match 'WORKSPACE_FOLDER') {
        throw 'LaTeX build wrapper must not refer to the workspace.'
    }
    if ($settings.'latex-workshop.latex.autoBuild.run' -cne 'onSave') {
        throw 'LaTeX Workshop auto-build setting is not onSave.'
    }
    foreach ($relative in @('scripts\Tectonic.Core.ps1', 'config\tectonic-release.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $state ('latex-runtime\' + $relative)) -PathType Leaf)) {
            throw "Global runtime missing $relative"
        }
    }

    & $script -Mode LaTeX -CliPath $cli -StateRoot $state -Workspace $workspace -NoLaunch
    if ($LASTEXITCODE -ne 0 -or @(Get-Content (Join-Path $testDir 'installs.log')).Count -ne 1) {
        throw 'Repeated LaTeX setup was not idempotent.'
    }
    if ((Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).'latex-workshop.latex.tools'[0].args[5] -cne $wrapper) {
        throw 'Re-run rewrote the global build path.'
    }


    & $script -Mode PDF -CliPath $cli -StateRoot $state -Workspace $workspace
    if ($LASTEXITCODE -ne 0) { throw 'PDF mode launch failed.' }
    $pdf = @(Get-Content -LiteralPath $pd)
    if ($pdf.Count -ne 14 -or $pdf -notcontains 'tomoki1207.pdf' -or
        $pdf -contains 'James-Yu.latex-workshop') { throw 'PDF mode extension isolation failed.' }
    if (@(Get-Content (Join-Path $testDir 'installs.log')).Count -ne 2 -or
        @(Get-Content (Join-Path $testDir 'opens.log')).Count -ne 1) {
        throw 'Expected one batched PDF install and one launch.'
    }
    & $script -Mode LaTeX -CliPath $cli -StateRoot $state -Workspace $workspace
    if ($LASTEXITCODE -ne 0 -or @(Get-Content (Join-Path $testDir 'installs.log')).Count -ne 2 -or
        @(Get-Content (Join-Path $testDir 'opens.log')).Count -ne 2) {
        throw 'Re-selecting LaTeX mode must launch once without reinstalling.'
    }
    if ($la -eq $pd -or -not (Test-Path (Join-Path $state 'latex\user-data')) -or
        -not (Test-Path (Join-Path $state 'pdf\user-data'))) {
        throw 'Per-mode user-data directories are missing.'
    }
    # An unsafe external modification fails before installation or launch.
    Add-Content -LiteralPath $la -Value 'tomoki1207.pdf' -Encoding Ascii
    & $script -Mode LaTeX -CliPath $cli -StateRoot $state -Workspace $workspace -NoLaunch 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0 -or @(Get-Content (Join-Path $testDir 'installs.log')).Count -ne 2 -or
        @(Get-Content (Join-Path $testDir 'opens.log')).Count -ne 2) {
        throw 'Conflicting mode did not fail safely.'
    }
    if (Test-Path -LiteralPath (Join-Path $testDir 'uninstall.log')) {
        throw 'No extensions may be uninstalled.'
    }
    $nodeOptions = @(Get-Content -LiteralPath (Join-Path $testDir 'node-options.log'))
    if (@($nodeOptions | Where-Object { $_ -notmatch '--disable-warning=DEP0169' }).Count -gt 0) {
        throw 'CLI operations did not selectively suppress DEP0169.'
    }
    if (Test-Path -LiteralPath (Join-Path $testDir 'launch-node.log')) {
        $launchOptions = @(Get-Content -LiteralPath (Join-Path $testDir 'launch-node.log'))
        if (@($launchOptions | Where-Object { $_ -match '--disable-warning=DEP0169' }).Count -gt 0) {
            throw 'Node suppression leaked into opened VS Code windows.'
        }
    }
    Write-Host 'Isolated PDF mode tests passed (isolation, switch, clean CLI warnings, conflict rejection).'
    exit 0
} catch {
    Write-Error ('PDF mode test failed: ' + $_.Exception.Message) -ErrorAction Continue
    exit 1
} finally {
    if ($originalNodeOptionsExists) { $env:NODE_OPTIONS = $originalNodeOptions }
    else { Remove-Item -LiteralPath 'Env:NODE_OPTIONS' -ErrorAction SilentlyContinue }
    if ($testDir -and (Test-Path -LiteralPath $testDir)) {
        Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
