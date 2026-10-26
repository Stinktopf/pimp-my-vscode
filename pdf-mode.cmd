@echo off
setlocal DisableDelayedExpansion
rem Interactive selection for two isolated VS Code PDF modes.
rem No global extension removal and no persistent execution policy changes.
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" (
  echo Windows PowerShell 5.1 is required. 1>&2
  exit /b 1
)
if not "%~1"=="" goto runargs
echo.
echo Select the PDF extension active in VS Code:
echo   [L] LaTeX Workshop  - build and preview LaTeX documents
echo   [P] vscode-pdf      - view general PDF documents
echo   [X] Cancel
echo.
choice /C LPX /N /M "Select L, P or X: "
if errorlevel 3 exit /b 0
if errorlevel 2 goto pdf
if errorlevel 1 goto latex
echo No selection made. 1>&2
exit /b 1
:latex
"%PS_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0pdf-mode.ps1" -Mode LaTeX
exit /b %ERRORLEVEL%
:pdf
"%PS_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0pdf-mode.ps1" -Mode PDF
exit /b %ERRORLEVEL%
:runargs
"%PS_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0pdf-mode.ps1" %*
exit /b %ERRORLEVEL%
