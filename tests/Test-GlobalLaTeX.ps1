#requires -Version 5.1
# Offline test of project-independent LaTeX settings and runtime. -Build additionally
# compiles a TeX file in an unrelated folder using an installed Tectonic release.
[CmdletBinding()]
param([switch]$Build)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testDir = $null
try {
    if ($env:OS -ne 'Windows_NT') { throw 'Windows is required.' }
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $root 'scripts\Tectonic.Core.ps1')
    . (Join-Path $root 'scripts\VSCode.LaTeX.ps1')

    $testDir = Join-Path $env:TEMP ('pimp latex standalone with spaces ' + [guid]::NewGuid().ToString('N'))
    $modesDir = Join-Path $testDir 'modes'
    $dataDir = Join-Path $modesDir 'latex\user-data'
    $userDir = Join-Path $dataDir 'User'
    New-Item -ItemType Directory -Path $userDir -Force | Out-Null
    $settingsFile = Join-Path $userDir 'settings.json'
    # Real VS Code JSONC with comments, trailing commas and an unrelated setting.
    @'
{
  // Preserve arbitrary user settings.
  "editor.fontSize": 17,
  "files.exclude": { "**/example": true, },
  /* This key looks like a comment: "https://host" */
  "editor.insertSpaces": false,
}
'@ | Set-Content -LiteralPath $settingsFile -Encoding UTF8

    $wrapper = Install-LocalLaTeXRuntime -SourceRoot $root -ModesRoot $modesDir
    Set-IsolatedLaTeXSettings -DataDir $dataDir -ModesRoot $modesDir -BuildScript $wrapper
    $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
    $recipe = @($settings.'latex-workshop.latex.recipes')[0]
    $tool = @($settings.'latex-workshop.latex.tools')[0]
    if ($settings.'editor.fontSize' -ne 17 -or $settings.'editor.insertSpaces' -ne $false -or
        $settings.'files.exclude'.'**/example' -ne $true -or
        $recipe.name -cne 'Tectonic' -or $tool.args[5] -cne $wrapper -or
        $tool.args[7] -cne '%DOC_EXT_W32%' -or
        $settings.'latex-workshop.latex.autoBuild.run' -cne 'onSave') {
        throw 'Existing VS Code preferences were lost, or the global Tectonic tool is incorrect.'
    }
    if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $modesDir 'latex-runtime\config\tectonic-release.json') -PathType Leaf)) {
        throw 'Standalone runtime files are missing.'
    }
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $modesDir 'settings-backups') -File)
    if ($backups.Count -ne 1 -or
        -not (Select-String -LiteralPath $backups[0].FullName -Pattern 'editor.fontSize' -Quiet)) {
        throw 'Previous settings were not backed up.'
    }
    $beforeBytes = [IO.File]::ReadAllBytes($settingsFile)
    Set-IsolatedLaTeXSettings -DataDir $dataDir -ModesRoot $modesDir -BuildScript $wrapper
    $afterBytes = [IO.File]::ReadAllBytes($settingsFile)
    if ([Convert]::ToBase64String($beforeBytes) -cne [Convert]::ToBase64String($afterBytes) -or
        @(Get-ChildItem -LiteralPath (Join-Path $modesDir 'settings-backups') -File).Count -ne 1) {
        throw 'Idempotent configuration modified working settings or created an unnecessary backup.'
    }

    # A damaged copied runtime must be repaired from the repository (without network).
    'damaged' | Set-Content -LiteralPath $wrapper -Encoding Ascii
    $restored = Install-LocalLaTeXRuntime -SourceRoot $root -ModesRoot $modesDir
    if ($restored -cne $wrapper -or
        (Get-Sha256File $restored) -cne (Get-Sha256File (Join-Path $root 'scripts\tectonic-build.ps1'))) {
        throw 'Damaged local runtime was not repaired.'
    }

    # Invalid JSON must not overwrite an existing settings file.
    '{ invalid json' | Set-Content -LiteralPath $settingsFile -Encoding Ascii
    $rejected = $false
    try {
        Set-IsolatedLaTeXSettings -DataDir $dataDir -ModesRoot $modesDir -BuildScript $wrapper
    } catch { $rejected = $true }
    if (-not $rejected -or [IO.File]::ReadAllText($settingsFile) -notmatch 'invalid json') {
        throw 'Malformed settings were overwritten instead of rejected.'
    }

    if ($Build) {
        $repo = Join-Path $testDir 'another independent LaTeX repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        $tex = Join-Path $repo 'main.tex'
        Copy-Item -LiteralPath (Join-Path $root 'examples\main.tex') -Destination $tex
        $pdfDir = Join-Path $repo 'build'
        & $wrapper -Document $tex -OutDir $pdfDir -Offline
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $pdfDir 'main.pdf') -PathType Leaf)) {
            throw 'Standalone LaTeX build from an unrelated repository failed.'
        }
    }
    Write-Host 'Global LaTeX tests passed (JSONC merge, backup, idempotence, runtime repair, standalone project).'
    exit 0
} catch {
    Write-Error ('Global LaTeX test failed: ' + $_.Exception.Message) -ErrorAction Continue
    exit 1
} finally {
    if ($testDir -and (Test-Path -LiteralPath $testDir)) {
        Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
