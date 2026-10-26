#requires -Version 5.1
# User-scoped LaTeX Workshop configuration shared by every folder opened in LaTeX mode.
# Does not touch the normal VS Code profile or arbitrary project folders.
Set-StrictMode -Version Latest

function ConvertFrom-VSCodeJsonc([string]$Content) {
    # VS Code accepts JSON with line/block comments and trailing commas.
    # Remove only JSONC syntax while respecting escaped characters in strings.
    $clean = [System.Text.StringBuilder]::new()
    $insideString = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false
    for ($i = 0; $i -lt $Content.Length; $i++) {
        $c = $Content[$i]
        $next = if ($i + 1 -lt $Content.Length) { $Content[$i+1] } else { [char]0 }
        if ($lineComment) {
            if ($c -eq "`n" -or $c -eq "`r") {
                $lineComment = $false
                $null = $clean.Append($c)
            }
            continue
        }
        if ($blockComment) {
            if ($c -eq '*' -and $next -eq '/') { $blockComment = $false; $i++ }
            elseif ($c -eq "`n" -or $c -eq "`r") { $null = $clean.Append($c) }
            continue
        }
        if ($insideString) {
            $null = $clean.Append($c)
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $insideString = $false }
            continue
        }
        if ($c -eq '"') { $insideString = $true; $null = $clean.Append($c); continue }
        if ($c -eq '/' -and $next -eq '/') { $lineComment = $true; $i++; continue }
        if ($c -eq '/' -and $next -eq '*') { $blockComment = $true; $i++; continue }
        $null = $clean.Append($c)
    }
    if ($blockComment -or $insideString) { throw 'VS Code settings.json contains an unfinished comment or string.' }
    $intermediate = $clean.ToString()
    # Strip trailing commas outside strings (comments are already gone).
    $result = [System.Text.StringBuilder]::new()
    $insideString = $false
    $escaped = $false
    for ($i = 0; $i -lt $intermediate.Length; $i++) {
        $c = $intermediate[$i]
        if ($insideString) {
            $null = $result.Append($c)
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $insideString = $false }
            continue
        }
        if ($c -eq '"') { $insideString = $true; $null = $result.Append($c); continue }
        if ($c -eq ',') {
            $j = $i + 1
            while ($j -lt $intermediate.Length -and [char]::IsWhiteSpace($intermediate[$j])) { $j++ }
            if ($j -lt $intermediate.Length -and ($intermediate[$j] -eq '}' -or $intermediate[$j] -eq ']')) {
                continue
            }
        }
        $null = $result.Append($c)
    }
    $parsed = ConvertFrom-Json -InputObject $result.ToString() -ErrorAction Stop
    if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) {
        throw 'VS Code user settings must contain a JSON object.'
    }
    return $parsed
}

function Get-GlobalLaTeXSettings([string]$BuildScript) {
    if (-not [IO.Path]::IsPathRooted($BuildScript)) { throw 'Build wrapper must have an absolute path.' }
    return [ordered]@{
        'latex-workshop.latex.recipes' = @([ordered]@{ name = 'Tectonic'; tools = @('tectonic-local') })
        'latex-workshop.latex.tools' = @([ordered]@{
            name = 'tectonic-local'; command = 'powershell.exe';
            args = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
                $BuildScript, '-Document', '%DOC_EXT_W32%', '-OutDir', '%OUTDIR_W32%')
        })
        'latex-workshop.latex.recipe.default' = 'first'
        'latex-workshop.latex.outDir' = '%DIR%/build'
        'latex-workshop.latex.autoBuild.run' = 'onSave'
        'latex-workshop.view.pdf.viewer' = 'tab'
    }
}

function Install-LocalLaTeXRuntime([string]$SourceRoot, [string]$ModesRoot) {
    # All three files are needed when the source setup folder is removed.
    $files = @(
        'scripts\tectonic-build.ps1',
        'scripts\Tectonic.Core.ps1',
        'config\tectonic-release.json'
    )
    $runtime = Join-Path $ModesRoot 'latex-runtime'
    $identical = Test-Path -LiteralPath $runtime -PathType Container
    foreach ($relative in $files) {
        $source = Join-Path $SourceRoot $relative
        $target = Join-Path $runtime $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Runtime source missing: $relative" }
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $identical = $false; continue }
        if ((Get-Sha256File $source) -cne (Get-Sha256File $target)) { $identical = $false }
    }
    if ($identical) { return (Join-Path $runtime 'scripts\tectonic-build.ps1') }

    New-Item -ItemType Directory -Path $ModesRoot -Force -ErrorAction Stop | Out-Null
    $suffix = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $ModesRoot ('.latex-runtime-stage-' + $suffix)
    $previous = Join-Path $ModesRoot ('.latex-runtime-backup-' + $suffix)
    $movedOld = $false
    $activated = $false
    try {
        foreach ($relative in $files) {
            $src = Join-Path $SourceRoot $relative
            $dst = Join-Path $stage $relative
            $dir = Split-Path -Parent $dst
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
            if ((Get-Sha256File $src) -cne (Get-Sha256File $dst)) {
                throw "Runtime copy failed verification: $relative"
            }
        }
        if (Test-Path -LiteralPath $runtime) {
            Move-Item -LiteralPath $runtime -Destination $previous -ErrorAction Stop
            $movedOld = $true
        }
        Move-Item -LiteralPath $stage -Destination $runtime -ErrorAction Stop
        $activated = $true
    } catch {
        if ($movedOld) {
            if (Test-Path -LiteralPath $runtime) {
                Remove-Item -LiteralPath $runtime -Recurse -Force -ErrorAction Stop
            }
            Move-Item -LiteralPath $previous -Destination $runtime -ErrorAction Stop
            $movedOld = $false
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($activated -and $movedOld -and (Test-Path -LiteralPath $previous)) {
            Remove-Item -LiteralPath $previous -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host 'Installed project-independent, user-local LaTeX build wrapper.'
    return (Join-Path $runtime 'scripts\tectonic-build.ps1')
}

function Set-IsolatedLaTeXSettings([string]$DataDir, [string]$ModesRoot, [string]$BuildScript) {
    # This file belongs exclusively to the isolated LaTeX mode, not the user's default VS Code.
    $userDir = Join-Path $DataDir 'User'
    $target = Join-Path $userDir 'settings.json'
    $desired = Get-GlobalLaTeXSettings $BuildScript
    New-Item -ItemType Directory -Path $userDir -Force -ErrorAction Stop | Out-Null
    $exists = Test-Path -LiteralPath $target -PathType Leaf
    $current = if ($exists) {
        ConvertFrom-VSCodeJsonc ([IO.File]::ReadAllText($target))
    } else { [pscustomobject]@{} }
    $changed = -not $exists
    foreach ($key in @($desired.Keys)) {
        $wanted = ConvertTo-Json -InputObject $desired[$key] -Depth 25 -Compress
        $property = $current.PSObject.Properties[$key]
        if ($null -eq $property -or
            (ConvertTo-Json -InputObject $property.Value -Depth 25 -Compress) -cne $wanted) {
            $changed = $true
            if ($null -eq $property) {
                $current | Add-Member -NotePropertyName $key -NotePropertyValue $desired[$key]
            } else { $property.Value = $desired[$key] }
        }
    }
    if (-not $changed) { return }
    $backupDir = Join-Path $ModesRoot 'settings-backups'
    $temporary = Join-Path $userDir ('.settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = (ConvertTo-Json -InputObject $current -Depth 25) + "`n"
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText($temporary, $json, $utf8)
        # Read the result before replacing a working settings file.
        $null = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($temporary)) -ErrorAction Stop
        if ($exists) {
            New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
            $backup = Join-Path $backupDir ('latex-settings-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.json')
            [IO.File]::Replace($temporary, $target, $backup)
        } else {
            [IO.File]::Move($temporary, $target)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    Write-Host 'Configured LaTeX Workshop for all folders opened in isolated LaTeX mode.'
}
