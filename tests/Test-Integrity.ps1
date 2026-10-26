#requires -Version 5.1
# Offline negative test: a forged ZIP must never be extracted or installed.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$originalLocalAppData = $env:LOCALAPPDATA
$stage = Join-Path ([IO.Path]::GetTempPath()) ('latex-integrity-' + [guid]::NewGuid().ToString('N'))

try {
    if ($env:OS -ne 'Windows_NT') { throw 'This test requires Windows.' }
    $isolated = Join-Path $stage 'local app data'
    New-Item -ItemType Directory -Path $isolated -Force | Out-Null
    $env:LOCALAPPDATA = $isolated
    $badZip = Join-Path $stage 'wrong checksum.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($badZip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $zip.CreateEntry('tectonic.exe')
        $stream = $entry.Open()
        try {
            $payload = New-Object byte[] 4096
            $stream.Write($payload, 0, $payload.Length)
        } finally { $stream.Dispose() }
    } finally { $zip.Dispose() }
    $root = Split-Path -Parent $PSScriptRoot
    & (Join-Path $root 'setup.ps1') -Install -ArchivePath $badZip -SkipExtension
    if ($LASTEXITCODE -eq 0) { throw 'Installer accepted an unpinned archive.' }
    $installed = Join-Path $isolated 'pimp-my-vscode\tectonic\0.17.0\tectonic.exe'
    if (Test-Path -LiteralPath $installed) { throw 'Installer executed or installed unverified contents.' }
    Write-Host 'Unpinned release rejection test passed.'
    exit 0
} catch {
    Write-Error ("Integrity test failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
