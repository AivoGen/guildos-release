@echo off
setlocal

set "SCRIPT=%TEMP%\guildos-daemon-install.ps1"
set "URL=https://github.com/AivoGen/guildos-release/releases/latest/download/guildos-daemon-install.ps1"
if not "%GUILDOS_DAEMON_INSTALL_PS1_URL%"=="" set "URL=%GUILDOS_DAEMON_INSTALL_PS1_URL%"

powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -UseBasicParsing '%URL%' -OutFile '%SCRIPT%'" || exit /b 4
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
