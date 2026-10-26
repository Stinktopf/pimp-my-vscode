#requires -Version 5.1
# Windows integration test; first run may download Tectonic's TeX support files.
[CmdletBinding()]
param([switch]$Offline)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    & (Join-Path $PSScriptRoot 'Test-Project.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Offline project validation failed.' }
    $root = Split-Path -Parent $PSScriptRoot
    $document = Join-Path $root 'examples\main.tex'
    $outDir = Join-Path $root 'examples\build'
    $wrapper = Join-Path $root 'scripts\tectonic-build.ps1'
    if ($Offline) { & $wrapper -Document $document -OutDir $outDir -Offline }
    else { & $wrapper -Document $document -OutDir $outDir }
    if ($LASTEXITCODE -ne 0) { throw 'Tectonic compilation failed.' }
    $pdf = Join-Path $outDir 'main.pdf'
    $log = Join-Path $outDir 'main.log'
    if (-not (Test-Path -LiteralPath $pdf -PathType Leaf) -or
        -not (Test-Path -LiteralPath $log -PathType Leaf)) {
        throw 'Expected PDF and log were not written.'
    }
    $pdfBytes = [IO.File]::ReadAllBytes($pdf)
    if ($pdfBytes.Length -lt 1024 -or
        [Text.Encoding]::ASCII.GetString($pdfBytes, 0, 5) -cne '%PDF-') {
        throw 'Invalid PDF output.'
    }
    Write-Host "Smoke test passed ($($pdfBytes.Length) PDF bytes)."
    exit 0
} catch {
    Write-Error ("Smoke test failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
