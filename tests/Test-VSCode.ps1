#requires -Version 5.1
# Offline tests for workspace PDF ownership and extension conflict detection.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $root 'scripts\VSCode.Extensions.ps1')

    $ids = @('James-Yu.LaTeX-Workshop', 'tomoki1207.PDF', 'other.extension')
    if (-not (Test-InstalledExtension -Ids $ids -Id 'james-yu.latex-workshop')) {
        throw 'Case-insensitive LaTeX Workshop detection failed.'
    }
    if (-not (Test-InstalledExtension -Ids $ids -Id 'tomoki1207.pdf')) {
        throw 'vscode-pdf conflict detection failed.'
    }
    if (Test-InstalledExtension -Ids @('random.pdfviewer') -Id 'tomoki1207.pdf') {
        throw 'False-positive PDF conflict detection.'
    }
    if (Test-InstalledExtension -Ids @() -Id 'tomoki1207.pdf') {
        throw 'Empty extension list was incorrectly marked as conflicting.'
    }

    $settings = Get-Content -LiteralPath (Join-Path $root '.vscode\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $settings.PSObject.Properties['workbench.editorAssociations']) {
        throw 'Shared workspace settings must not force the LaTeX PDF editor in PDF mode.'
    }
    $extensions = Get-Content -LiteralPath (Join-Path $root '.vscode\extensions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $extensions.PSObject.Properties['unwantedRecommendations']) {
        throw 'Shared workspace must not exclude vscode-pdf when PDF mode is supported.'
    }
    Write-Host 'VS Code conflict checks passed (offline).'
    exit 0
} catch {
    Write-Error ("VS Code checks failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
