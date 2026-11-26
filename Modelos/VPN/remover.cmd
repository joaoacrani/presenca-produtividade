@echo off
rem Remove o perfil do escritorio e desinstala o OpenVPN Client usando o proprio MSI do pacote.
setlocal
set "AQUI=%~dp0"
set "DESTINO=%ProgramFiles%\OpenVPN\config"

for %%F in ("%AQUI%config\*.ovpn") do del /q "%DESTINO%\%%~nxF" >nul 2>&1
msiexec /x "%AQUI%openvpn-install.msi" /qn /norestart
set "RC=%ERRORLEVEL%"
echo msiexec /x terminou com codigo %RC%
exit /b %RC%
