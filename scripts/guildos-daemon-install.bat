@echo off
setlocal

net session >nul 2>&1
if errorlevel 1 (
  echo Administrator privileges are required. Re-run this installer from an Administrator PowerShell or Command Prompt.
  exit /b 7
)

set "SCRIPT=%TEMP%\guildos-daemon-install.ps1"
set "URL=https://github.com/AivoGen/guildos-release/releases/latest/download/guildos-daemon-install.ps1"
if not "%GUILDOS_DAEMON_INSTALL_PS1_URL%"=="" set "URL=%GUILDOS_DAEMON_INSTALL_PS1_URL%"

powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%SCRIPT%' -ErrorAction Stop } catch { Write-Host ('download failed from %URL%: ' + $_) -ForegroundColor Red; exit 4 }" || exit /b 4
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
