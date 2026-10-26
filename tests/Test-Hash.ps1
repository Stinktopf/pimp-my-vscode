#requires -Version 5.1
# Offline hashing regression, including hosts without Get-FileHash.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$folder = Join-Path ([IO.Path]::GetTempPath()) ('vscode sha256 with spaces ' + [guid]::NewGuid().ToString('N'))
try {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $root 'scripts\Tectonic.Core.ps1')

    # If the helper accidentally uses Get-FileHash, fail even on hosts that have it.
    function Get-FileHash { throw 'Regression: Get-FileHash must not be required.' }

    New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
    $file = Join-Path $folder 'sha 256 sample.txt'
    [IO.File]::WriteAllBytes($file, [Text.Encoding]::ASCII.GetBytes('abc'))
    $actual = Get-Sha256File -Path $file
    if ($actual -cne 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') {
        throw "Incorrect SHA-256 for known test vector: $actual"
    }

    $archive = Join-Path $folder 'test archive.zip'
    [IO.File]::WriteAllBytes($archive, (New-Object byte[] 4096))
    $expected = Get-Sha256File -Path $archive
    Assert-PinnedArchive $archive ([pscustomobject]@{ sha256 = $expected })
    [IO.File]::AppendAllText($archive, 'tampered')
    $rejected = $false
    try {
        Assert-PinnedArchive $archive ([pscustomobject]@{ sha256 = $expected })
    } catch {
        $rejected = $_.Exception.Message -like '*SHA-256 mismatch*'
    }
    if (-not $rejected) { throw 'A modified release archive was not rejected.' }

    Write-Host 'SHA-256 regression passed (no Get-FileHash, known vector, spaces, tamper rejection).'
    exit 0
} catch {
    Write-Error ("SHA-256 regression failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
} finally {
    if (Test-Path -LiteralPath $folder) {
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
