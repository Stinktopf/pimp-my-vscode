#requires -Version 5.1
# Integration test: absolute paths and output folders with spaces must work.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$folder = Join-Path ([IO.Path]::GetTempPath()) ('latex path with spaces ' + [char]0x00FC + ' ' + [guid]::NewGuid().ToString('N'))
try {
    if ($env:OS -ne 'Windows_NT') { throw 'This test requires Windows.' }
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $document = Join-Path $folder 'example document.tex'
    Copy-Item -LiteralPath (Join-Path $root 'examples\main.tex') -Destination $document
    & (Join-Path $root 'scripts\tectonic-build.ps1') -Document $document -OutDir 'build output' -Offline
    if ($LASTEXITCODE -ne 0) { throw 'Build with spaces failed.' }
    $pdf = Join-Path $folder 'build output\example document.pdf'
    if (-not (Test-Path -LiteralPath $pdf -PathType Leaf)) {
        throw 'Expected PDF in the space-containing output directory.'
    }
    Write-Host 'Paths with spaces test passed.'
    exit 0
} catch {
    Write-Error ("Path test failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
} finally {
    if (Test-Path -LiteralPath $folder) {
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
