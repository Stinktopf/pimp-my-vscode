#requires -Version 5.1
# Offline regression: local unsigned scripts must be rejected under AllSigned, but
# the documented one-process launch must run the reviewed local project validation.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    if ($env:OS -ne 'Windows_NT') { throw 'This test requires Windows.' }
    $root = Split-Path -Parent $PSScriptRoot
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) {
        throw 'Expected Windows PowerShell executable missing.'
    }
    # The test script is intentionally unsigned, so AllSigned must reject it.
    & $psExe -NoProfile -NonInteractive -ExecutionPolicy AllSigned -File (Join-Path $root 'tests\Test-Project.ps1') 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        throw 'Unsigned test script was unexpectedly accepted under AllSigned.'
    }
    # A new process setting, not a persistent change to CurrentUser or LocalMachine.
    & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Test-Project.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw 'Explicit process-scoped invocation failed.'
    }
    Write-Host 'Process-scoped execution policy regression passed.'
    exit 0
} catch {
    Write-Error ("Execution policy test failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
