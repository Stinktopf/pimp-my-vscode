#requires -Version 5.1
<#
.SYNOPSIS
  Install the audited Tectonic release for the current Windows user.
.EXAMPLE
  .\setup.ps1 -Install -Test
.EXAMPLE
  .\setup.ps1 -Install -ArchivePath 'C:\Downloads\tectonic.zip'
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Check,
    [switch]$Test,
    [string]$ArchivePath,
    [switch]$SkipExtension
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Tectonic.Core.ps1')
. (Join-Path $PSScriptRoot 'scripts\VSCode.Extensions.ps1')

function Install-Tectonic($Release, $Paths, [string]$LocalArchive) {
    New-Item -ItemType Directory -Path $Paths.Root -Force | Out-Null
    # Prevent two installers from interleaving changes to the same version folder.
    $lockPath = Join-Path $Paths.Root '.install.lock'
    try {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw 'Another installation may be running. Close it and retry.'
    }
    $stage = $null
    $backup = $null
    $committed = $false
    try {
        # Validate any explicitly supplied archive, even when installation is current.
        # An incorrect file must never be silently accepted as a successful install.
        if (-not [string]::IsNullOrWhiteSpace($LocalArchive)) {
            $candidate = (Resolve-Path -LiteralPath $LocalArchive -ErrorAction Stop).ProviderPath
            Assert-PinnedArchive $candidate $Release
        }
        $validInstall = $false
        try {
            Assert-TrustedInstall $Paths $Release
            Assert-TectonicVersion $Paths.Exe ([string]$Release.version)
            $validInstall = $true
        } catch {
            Write-Verbose "Existing installation requires repair: $($_.Exception.Message)"
        }
        if ($validInstall) {
            Write-Host "Tectonic $($Release.version) is already verified."
            return
        }

        $id = [guid]::NewGuid().ToString('N')
        $stage = Join-Path $Paths.Root ('.staging-' + $id)
        New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
        $stageArchive = Join-Path $stage 'release.zip'
        $stageExe = Join-Path $stage 'tectonic.exe'

        if (-not [string]::IsNullOrWhiteSpace($LocalArchive)) {
            $source = (Resolve-Path -LiteralPath $LocalArchive -ErrorAction Stop).ProviderPath
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw '-ArchivePath must refer to a regular file.'
            }
            Copy-Item -LiteralPath $source -Destination $stageArchive -ErrorAction Stop
        } else {
            $cacheValid = $false
            try {
                Assert-PinnedArchive $Paths.Archive $Release
                $cacheValid = $true
            } catch {
                Write-Verbose 'No valid local release ZIP available.'
            }
            if ($cacheValid) {
                Copy-Item -LiteralPath $Paths.Archive -Destination $stageArchive -ErrorAction Stop
            } else {
                Write-Host "Downloading official Tectonic $($Release.version) release..."
                [Net.ServicePointManager]::SecurityProtocol =
                    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri ([string]$Release.url) -OutFile $stageArchive -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 180 -ErrorAction Stop
            }
        }

        # Verify the exact downloadable bytes before any executable is extracted or run.
        Assert-PinnedArchive $stageArchive $Release
        Copy-VerifiedExecutable $stageArchive $stageExe $Release
        $stagePaths = [pscustomobject]@{ Archive = $stageArchive; Exe = $stageExe }
        Assert-TrustedInstall $stagePaths $Release
        Assert-TectonicVersion $stageExe ([string]$Release.version)

        if (Test-Path -LiteralPath $Paths.Directory) {
            $backup = Join-Path $Paths.Root ('.previous-' + $id)
            Move-Item -LiteralPath $Paths.Directory -Destination $backup -ErrorAction Stop
        }
        try {
            Move-Item -LiteralPath $stage -Destination $Paths.Directory -ErrorAction Stop
            $stage = $null
            Assert-TrustedInstall $Paths $Release
            Assert-TectonicVersion $Paths.Exe ([string]$Release.version)
            $committed = $true
        } catch {
            # If activation or post-activation checks fail, roll back whenever possible.
            if (Test-Path -LiteralPath $Paths.Directory) {
                Remove-Item -LiteralPath $Paths.Directory -Recurse -Force -ErrorAction Stop
            }
            if ($backup) {
                Move-Item -LiteralPath $backup -Destination $Paths.Directory -ErrorAction Stop
                $backup = $null
            }
            throw
        }
        Write-Host "Installed and verified Tectonic $($Release.version) in $($Paths.Directory)"
    } finally {
        if ($stage -and (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            if ($committed) {
                Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Write-Warning "Previous installation preserved for recovery: $backup"
            }
        }
        $lock.Dispose()
    }
}

function Configure-VSCode {
    foreach ($name in @('.vscode\settings.json', '.vscode\extensions.json')) {
        $file = Join-Path $PSScriptRoot $name
        $null = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    Write-Host 'Project-local LaTeX Workshop settings validated.'

    $cliPath = Get-VSCodeCliPath
    if (-not $cliPath) {
        Write-Warning 'VS Code CLI not found at a standard install location. Install LaTeX Workshop from the Extensions view in VS Code.'
        return $false
    }
    try {
        $installed = @(Get-VSCodeExtensionIds -CliPath $cliPath)
        if (-not (Test-InstalledExtension -Ids $installed -Id 'James-Yu.latex-workshop')) {
            Write-Host 'Installing LaTeX Workshop for the current VS Code user...'
            & $cliPath --install-extension 'James-Yu.latex-workshop'
            if ($LASTEXITCODE -ne 0) { throw 'VS Code reported an extension installation failure.' }
            $installed = @(Get-VSCodeExtensionIds -CliPath $cliPath)
            if (-not (Test-InstalledExtension -Ids $installed -Id 'James-Yu.latex-workshop')) {
                throw 'The VS Code CLI did not confirm that LaTeX Workshop was installed.'
            }
        } else {
            Write-Host 'LaTeX Workshop is already installed.'
        }

        if (Test-InstalledExtension -Ids $installed -Id 'tomoki1207.pdf') {
            Write-Warning ('vscode-pdf (tomoki1207.pdf) is installed and can conflict with ' +
                'LaTeX Workshop. In VS Code: Extensions > vscode-pdf > gear icon > ' +
                'Disable (Workspace), then run Developer: Reload Window. ' +
                'The extension is not removed or disabled globally.')
        }
        return $true
    } catch {
        Write-Warning "VS Code extension setup incomplete: $($_.Exception.Message)"
        return $false
    }
}

try {
    if (-not ($Install -or $Check -or $Test)) {
        Write-Host 'Usage: .\setup.ps1 -Install [-Test] | -Check | -Test'
        exit 0
    }
    if ($ArchivePath -and -not $Install) { throw '-ArchivePath requires -Install.' }
    if ($SkipExtension -and -not $Install) { throw '-SkipExtension requires -Install.' }
    Assert-WindowsX64
    $release = Get-PinnedRelease $PSScriptRoot
    $paths = Get-TectonicPaths $release

    & (Join-Path $PSScriptRoot 'tests\Test-Project.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Project validation failed.' }

    $extensionReady = $true
    if ($Install) {
        Install-Tectonic $release $paths $ArchivePath
        if (-not $SkipExtension) { $extensionReady = Configure-VSCode }

    }
    if ($Check -or $Test) {
        Assert-TrustedInstall $paths $release
        Assert-TectonicVersion $paths.Exe ([string]$release.version)
    }
    if ($Test) {
        & (Join-Path $PSScriptRoot 'tests\Invoke-SmokeTest.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'PDF smoke test failed.' }
    }
    if ($extensionReady) {
        if (-not ($Install -and $SkipExtension)) {
            Write-Host 'Tectonic ready.'
        }
    } else {
        Write-Warning 'Tectonic is ready, but LaTeX Workshop requires manual installation in VS Code.'
    }
    exit 0
} catch {
    Write-Error ("Setup failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
