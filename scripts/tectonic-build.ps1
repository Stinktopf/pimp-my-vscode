#requires -Version 5.1
<#
.SYNOPSIS
  Compile a TeX file using only the pinned, verified user-local Tectonic.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Document,
    [Parameter(Position = 1)]
    [string]$OutDir,
    [switch]$Offline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Tectonic.Core.ps1')

try {
    Assert-WindowsX64
    $project = Split-Path -Parent $PSScriptRoot
    $release = Get-PinnedRelease $project
    $paths = Get-TectonicPaths $release
    Assert-TrustedInstall $paths $release

    $file = (Resolve-Path -LiteralPath $Document -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
        [IO.Path]::GetExtension($file) -ine '.tex') { throw '-Document must be a .tex file.' }
    $sourceDir = Split-Path -Parent $file
    if ([string]::IsNullOrWhiteSpace($OutDir)) {
        $destination = Join-Path $sourceDir 'build'
    } elseif ([IO.Path]::IsPathRooted($OutDir)) {
        $destination = [IO.Path]::GetFullPath($OutDir)
    } else {
        $destination = [IO.Path]::GetFullPath((Join-Path $sourceDir $OutDir))
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null

    $arguments = @('-X', 'compile', '--untrusted', '--synctex', '--keep-logs',
        '--keep-intermediates', '--outdir', $destination)
    if ($Offline) { $arguments += '--only-cached' }
    $arguments += $file

    # Defense in depth: the engine also honors this environment setting.
    $oldUntrusted = [Environment]::GetEnvironmentVariable('TECTONIC_UNTRUSTED_MODE', 'Process')
    $env:TECTONIC_UNTRUSTED_MODE = '1'
    Write-Host "Compiling $file"
    Push-Location -LiteralPath $sourceDir
    try {
        & $paths.Exe @arguments
        $result = $LASTEXITCODE
    } finally {
        Pop-Location
        [Environment]::SetEnvironmentVariable('TECTONIC_UNTRUSTED_MODE', $oldUntrusted, 'Process')
    }
    if ($result -ne 0) { throw "Tectonic failed with exit code $result." }
    $pdf = Join-Path $destination ([IO.Path]::GetFileNameWithoutExtension($file) + '.pdf')
    if (-not (Test-Path -LiteralPath $pdf -PathType Leaf)) { throw "PDF missing: $pdf" }
    $stream = [IO.File]::OpenRead($pdf)
    try {
        if ($stream.Length -lt 1024) { throw 'PDF is unexpectedly small.' }
        $signature = New-Object byte[] 5
        $null = $stream.Read($signature, 0, 5)
        if ([Text.Encoding]::ASCII.GetString($signature) -cne '%PDF-') { throw 'Invalid PDF header.' }
    } finally { $stream.Dispose() }
    Write-Host "PDF: $pdf"
    exit 0
} catch {
    Write-Error ("Build failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
