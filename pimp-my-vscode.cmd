@echo off
setlocal DisableDelayedExpansion
rem Runs local user-scoped installation and offers a PDF-mode selector.
rem No system-wide policy, PATH or extension removals.
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" (
  echo Windows PowerShell 5.1 was not found. 1>&2
  exit /b 1
)
"%PS_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0pimp-my-vscode.ps1" %*
if errorlevel 1 exit /b %ERRORLEVEL%
rem Only plain interactive installation opens the PDF selector.
rem Maintenance options and automated invocations never open VS Code.
if not "%~1"=="" exit /b 0
call "%~dp0pdf-mode.cmd"
exit /b %ERRORLEVEL%
