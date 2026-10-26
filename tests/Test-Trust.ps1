#requires -Version 5.1
# Integration test: modified executables/archives must fail closed, then recover offline.
# Operates in a disposable LOCALAPPDATA sandbox, never on the real installation.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$realLocalAppData = $env:LOCALAPPDATA
$root = Split-Path -Parent $PSScriptRoot
$stage = Join-Path ([IO.Path]::GetTempPath()) ('latex-trust-' + [guid]::NewGuid().ToString('N'))

try {
    if ($env:OS -ne 'Windows_NT') { throw 'This test requires Windows.' }
    . (Join-Path $root 'scripts\Tectonic.Core.ps1')
    $release = Get-PinnedRelease $root
    $realPaths = Get-TectonicPaths $release
    Assert-TrustedInstall $realPaths $release
    $originalArchive = $realPaths.Archive

    $env:LOCALAPPDATA = Join-Path $stage 'local app data'
    $paths = Get-TectonicPaths $release
    New-Item -ItemType Directory -Path $paths.Directory -Force | Out-Null
    Copy-Item -LiteralPath $realPaths.Archive -Destination $paths.Archive
    Copy-Item -LiteralPath $realPaths.Exe -Destination $paths.Exe

    Add-Content -LiteralPath $paths.Exe -Value 'test-tamper' -Encoding Ascii
    & (Join-Path $root 'scripts\tectonic-build.ps1') -Document (Join-Path $root 'examples\main.tex') -Offline
    if ($LASTEXITCODE -eq 0) { throw 'Build accepted a modified executable.' }
    & (Join-Path $root 'setup.ps1') -Check
    if ($LASTEXITCODE -eq 0) { throw 'Check accepted a modified executable.' }
    & (Join-Path $root 'setup.ps1') -Install -ArchivePath $originalArchive -SkipExtension
    if ($LASTEXITCODE -ne 0) { throw 'Offline executable repair failed.' }
    Assert-TrustedInstall $paths $release

    $badArchive = Join-Path $stage 'invalid archive.zip'
    [IO.File]::WriteAllText($badArchive, 'Not the pinned release')
    & (Join-Path $root 'setup.ps1') -Install -ArchivePath $badArchive -SkipExtension
    if ($LASTEXITCODE -eq 0) { throw 'Installer accepted a forged archive over a valid installation.' }
    Assert-TrustedInstall $paths $release

    Add-Content -LiteralPath $paths.Archive -Value 'test-tamper' -Encoding Ascii
    & (Join-Path $root 'scripts\tectonic-build.ps1') -Document (Join-Path $root 'examples\main.tex') -Offline
    if ($LASTEXITCODE -eq 0) { throw 'Build accepted a modified release ZIP.' }
    & (Join-Path $root 'setup.ps1') -Install -ArchivePath $originalArchive -SkipExtension
    if ($LASTEXITCODE -ne 0) { throw 'Offline archive repair failed.' }
    Assert-TrustedInstall $paths $release

    Write-Host 'Trust and offline repair tests passed.'
    exit 0
} catch {
    Write-Error ("Trust test failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
} finally {
    $env:LOCALAPPDATA = $realLocalAppData
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
