#requires -Version 5.1
# Offline validation: no network, VS Code, Tectonic, or administrator access required.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $root = Split-Path -Parent $PSScriptRoot
    $files = @(
        '.editorconfig', 'setup.ps1', 'pimp-my-vscode.ps1', 'pimp-my-vscode.cmd', 'pdf-mode.cmd', 'pdf-mode.ps1', 'config\extensions.json', 'tests\Test-Workstation.ps1', 'tests\Test-Policy.ps1', 'scripts\Tectonic.Core.ps1', 'scripts\VSCode.Extensions.ps1', 'scripts\VSCode.LaTeX.ps1', 'scripts\tectonic-build.ps1', 'tests\Test-GlobalLaTeX.ps1',
        'tests\Test-Project.ps1', 'tests\Test-PdfMode.ps1', 'tests\Test-Hash.ps1', 'tests\Test-Integrity.ps1',
        'tests\Test-Trust.ps1', 'tests\Test-Paths.ps1', 'tests\Test-VSCode.ps1',
        'tests\Invoke-SmokeTest.ps1', 'README.md', 'examples\main.tex',
        'config\tectonic-release.json', '.vscode\settings.json',
        '.vscode\extensions.json', '.vscode\tasks.json',
        '.github\workflows\windows-smoke.yml', '.gitignore'
    )
    foreach ($relative in $files) {
        $file = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Missing: $relative"
        }
        if ($relative.EndsWith('.ps1')) {
            $tokens = $null
            $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
            if ($null -ne $errors -and $errors.Count -gt 0) {
                throw "PowerShell parse error in $relative`: $($errors[0].Message)"
            }
        }
    }

    . (Join-Path $root 'scripts\Tectonic.Core.ps1')
    $release = Get-PinnedRelease $root
    if ([string]$release.version -cne '0.17.0') { throw 'Unexpected Tectonic release.' }

    # The setup repository must not shadow the user-level LaTeX tool with a
    # relative %WORKSPACE_FOLDER%/scripts path.
    $settings = Get-Content -LiteralPath (Join-Path $root '.vscode\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($settings.PSObject.Properties | Where-Object { $_.Name -like 'latex-workshop.*' }).Count -ne 0) {
        throw 'Workspace must not override the project-independent LaTeX settings.'
    }
    . (Join-Path $root 'scripts\VSCode.LaTeX.ps1')
    $sampleWrapper = 'C:\Users\Sample User\AppData\Local\pimp-my-vscode\modes\latex-runtime\scripts\tectonic-build.ps1'
    $global = Get-GlobalLaTeXSettings $sampleWrapper
    $tools = @($global['latex-workshop.latex.tools'])
    $recipes = @($global['latex-workshop.latex.recipes'])
    if ($tools.Count -ne 1 -or $tools[0].name -cne 'tectonic-local' -or
        $tools[0].command -cne 'powershell.exe') { throw 'Unexpected global LaTeX tool.' }
    $expectedArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        $sampleWrapper, '-Document', '%DOC_EXT_W32%', '-OutDir', '%OUTDIR_W32%')
    if ((@($tools[0].args) -join "`n") -cne ($expectedArgs -join "`n")) {
        throw 'Unexpected project-independent LaTeX tool arguments.'
    }
    if ($recipes.Count -ne 1 -or $recipes[0].tools[0] -cne 'tectonic-local' -or
        $global['latex-workshop.latex.autoBuild.run'] -cne 'onSave' -or
        $global['latex-workshop.latex.outDir'] -cne '%DIR%/build') {
        throw 'Unexpected global LaTeX recipe.'
    }
    $extensions = Get-Content -LiteralPath (Join-Path $root '.vscode\extensions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($extensions.recommendations).Count -ne 13 -or
        $null -ne $extensions.PSObject.Properties['unwantedRecommendations']) {
        throw 'Unexpected extension recommendations or PDF-mode exclusions.'
    }
    $tasks = Get-Content -LiteralPath (Join-Path $root '.vscode\tasks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($tasks.tasks).Count -ne 2) { throw 'Expected two VS Code tasks.' }
    foreach ($task in @($tasks.tasks)) {
        if ($task.command -cne 'powershell.exe' -or
            (@($task.args)[0..4] -join "`n") -cne (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File') -join "`n")) {
            throw 'Unexpected VS Code task PowerShell invocation.'
        }
    }
    $launcher = Get-Content -LiteralPath (Join-Path $root 'pimp-my-vscode.cmd') -Raw -Encoding Ascii
    if ($launcher -notmatch [regex]::Escape('-ExecutionPolicy Bypass -File "%~dp0pimp-my-vscode.ps1"')) {
        throw 'Missing process-scoped execution-policy launch in pimp-my-vscode.cmd.'
    }
    $modeLauncher = Get-Content -LiteralPath (Join-Path $root 'pdf-mode.cmd') -Raw -Encoding Ascii
    if ($modeLauncher -notmatch 'choice /C LPX' -or
        $modeLauncher -notmatch 'ExecutionPolicy Bypass -File') {
        throw 'Missing interactive mode launcher.'
    }
    $pdfScript = Get-Content -LiteralPath (Join-Path $root 'pdf-mode.ps1') -Raw -Encoding UTF8
    if ($pdfScript -notmatch 'Set-IsolatedLaTeXSettings' -or $pdfScript -notmatch 'Install-LocalLaTeXRuntime' -or
        $pdfScript -notmatch '--user-data-dir' -or $pdfScript -notmatch '--extensions-dir' -or
        $pdfScript -match 'Wait-ForProfile|Get-ProfileState|--profile') {
        throw 'PDF mode must use supported isolated data and extension directories, not fragile profile detection.'
    }
    if ($launcher -notmatch 'pdf-mode.cmd') {
        throw 'Normal installer must offer PDF mode selection.'
    }
    $manifest = Get-Content -LiteralPath (Join-Path $root 'config\extensions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne 2 -or @($manifest.extensions).Count -ne 14 -or
        @($manifest.extensions) -notcontains 'James-Yu.latex-workshop' -or
        @($manifest.extensions) -notcontains 'sonarsource.sonarlint-vscode' -or
        @($manifest.extensions) -notcontains 'marp-team.marp-vscode' -or
        @($manifest.conflicts)[0] -cne 'tomoki1207.pdf') {
        throw 'Invalid VS Code workstation extension manifest.'
    }
    if ((@($extensions.recommendations) -join ',') -cne (@($manifest.extensions | Where-Object { $_ -ine 'James-Yu.latex-workshop' }) -join ',')) {
        throw 'VS Code workspace recommendations must contain only the 13 conflict-free shared extensions.'
    }
    Write-Host "Project validation passed ($($files.Count) files, PowerShell syntax, VS Code JSON, pinned release)."
    exit 0
} catch {
    Write-Error ("Project validation failed: " + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
