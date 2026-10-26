#requires -Version 5.1
# Shared verification code. This file contains no entry-point actions.
Set-StrictMode -Version Latest

function Assert-WindowsX64 {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem -or
        -not [Environment]::Is64BitProcess) {
        throw '64-bit Windows PowerShell on Windows x64 is required.'
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or
        -not [IO.Path]::IsPathRooted($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA must be an absolute directory.'
    }
}

function Get-PinnedRelease([string]$ProjectRoot) {
    $file = Join-Path $ProjectRoot 'config\tectonic-release.json'
    $release = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $expectedUrl = 'https://github.com/tectonic-typesetting/tectonic/releases/download/' +
        'tectonic%400.17.0/tectonic-0.17.0-x86_64-pc-windows-msvc.zip'
    if ([string]$release.version -cne '0.17.0' -or
        [string]$release.platform -cne 'x86_64-pc-windows-msvc' -or
        [string]$release.url -cne $expectedUrl -or
        [string]$release.sha256 -cne 'f61ce51f0b0ade1015b7de7ef368541c5424e9756ecbd0d7af97d6d48030845f') {
        throw 'Release metadata differs from the audited pin.'
    }
    return $release
}

function Get-TectonicPaths($Release) {
    Assert-WindowsX64
    $root = Join-Path $env:LOCALAPPDATA 'pimp-my-vscode\tectonic'
    # Reuse verified installations from previous package names without another download.
    foreach ($priorName in @('pimpy-my-vscode', 'LaTeXWorkstation')) {
        $previous = Join-Path $env:LOCALAPPDATA ($priorName + '\tectonic')
        if ((Test-Path -LiteralPath (Join-Path $previous ([string]$Release.version)) -PathType Container) -and
            -not (Test-Path -LiteralPath (Join-Path $root ([string]$Release.version)) -PathType Container)) {
            $root = $previous
            break
        }
    }
    $versionDir = Join-Path $root ([string]$Release.version)
    return [pscustomobject]@{
        Root = $root
        Directory = $versionDir
        Archive = Join-Path $versionDir 'release.zip'
        Exe = Join-Path $versionDir 'tectonic.exe'
    }
}

# Hash files through the .NET runtime. Do not depend on Get-FileHash or
# PowerShell module auto-loading: some locked-down hosts omit the cmdlet.
# Stream the file rather than reading the entire archive into memory.
function Get-Sha256File([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A file path is required for SHA-256 verification.'
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash($stream)
            return [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Assert-PinnedArchive([string]$Archive, $Release) {
    if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) {
        throw "Pinned release ZIP missing: $Archive"
    }
    $bytes = (Get-Item -LiteralPath $Archive -ErrorAction Stop).Length
    if ($bytes -lt 1024 -or $bytes -gt 150MB) {
        throw "Unexpected release ZIP size: $Archive"
    }
    $actual = (Get-Sha256File -Path $Archive)
    if ($actual -ine [string]$Release.sha256) {
        throw "Release ZIP SHA-256 mismatch: $Archive"
    }
}

function Get-ArchiveExecutableHash([string]$Archive, $Release) {
    Assert-PinnedArchive $Archive $Release
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $entries = @($zip.Entries | Where-Object { $_.Name -ceq 'tectonic.exe' })
        if ($entries.Count -ne 1 -or $entries[0].Length -lt 1024 -or
            $entries[0].Length -gt 250MB) {
            throw 'Verified archive must contain exactly one valid-sized tectonic.exe.'
        }
        $stream = $entries[0].Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = $sha.ComputeHash($stream)
            return [BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
            $stream.Dispose()
        }
    } finally {
        $zip.Dispose()
    }
}

function Copy-VerifiedExecutable([string]$Archive, [string]$Destination, $Release) {
    $expectedHash = Get-ArchiveExecutableHash $Archive $Release
    # Extract only the expected executable; no arbitrary ZIP paths reach the disk.
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $entry = @($zip.Entries | Where-Object { $_.Name -ceq 'tectonic.exe' })[0]
        $inputStream = $entry.Open()
        try {
            $outputStream = [IO.File]::Create($Destination)
            try { $inputStream.CopyTo($outputStream) }
            finally { $outputStream.Dispose() }
        } finally { $inputStream.Dispose() }
    } finally { $zip.Dispose() }
    if ((Get-Sha256File -Path $Destination) -ine $expectedHash) {
        throw 'Extracted Tectonic executable does not match the pinned archive.'
    }
}

function Assert-TrustedInstall($Paths, $Release) {
    if (-not (Test-Path -LiteralPath $Paths.Exe -PathType Leaf)) {
        throw 'Tectonic executable missing.'
    }
    # The fixed archive hash is the trust anchor, not a locally writable .sha256 sidecar.
    $expectedExeHash = Get-ArchiveExecutableHash $Paths.Archive $Release
    if ((Get-Sha256File -Path $Paths.Exe) -ine $expectedExeHash) {
        throw 'Installed executable differs from the pinned, verified release ZIP.'
    }
}

function Assert-TectonicVersion([string]$Exe, [string]$Version) {
    $output = (& $Exe --version 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or
        $output -notmatch ('(?<![0-9.])' + [regex]::Escape($Version) + '(?![0-9.])')) {
        throw "Tectonic executable did not report version $Version."
    }
}
