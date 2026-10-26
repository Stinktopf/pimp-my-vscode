# pimp-my-vscode

A lightweight Windows VS Code setup with 14 extensions, verified Tectonic, and two isolated PDF modes.

## Install

Extract the ZIP and run in PowerShell:

```powershell
.\pimp-my-vscode.cmd
```

Choose **L** (LaTeX Workshop) or **P** (vscode-pdf). Both remain installed separately.

## LaTeX in any repository

The LaTeX mode installs its build wrapper and LaTeX Workshop settings **for that mode**, not into each repository. Open any existing LaTeX folder in the LaTeX-mode window, or run from the setup folder:

```powershell
.\pdf-mode.cmd -Mode LaTeX -Workspace "C:\path\to\your-repo"
```

Save a `.tex` file to build its PDF into a `build/` folder next to the root document.

## Switch PDF mode

```powershell
.\pdf-mode.cmd
```

The PDF mode uses `vscode-pdf`; LaTeX mode uses LaTeX Workshop. Launch through `pdf-mode.cmd` to retain isolation. Opening regular VS Code uses your original settings and extensions, unchanged.

## Maintenance

```powershell
.\pimp-my-vscode.cmd -Action Check
.\pimp-my-vscode.cmd -Action Capture
.\pimp-my-vscode.cmd -Action Backup
```

User-scoped, no admin rights or remote PowerShell scripts. Downloads are SHA-256 verified. User-level LaTeX settings are backed up before changes. Windows tests are included in `tests/`.
