@echo off
rem Instala o OpenVPN Client e importa o perfil do escritorio. Roda como SYSTEM, sem janela, pelo agent (politica de instalacao).
rem Os arquivos ficam ao lado deste script: openvpn-install.msi e config\<perfil>.ovpn
rem Regras:
rem  - OpenVPN instalado e integro (programa, GUI e servico): nao reinstala; so importa o perfil se faltar ou estiver diferente.
rem  - Nada instalado, ou instalado com problema / restos de arquivos: limpa os restos e instala do zero.
rem  - Perfis .ovpn que ja existem na pasta de configuracao NAO sao apagados (so o do pacote e substituido, se for diferente).
rem Nao use arquivo gatilho nesta politica.
setlocal
set "AQUI=%~dp0"
set "RAIZ=%ProgramFiles%\OpenVPN"
set "DESTINO=%RAIZ%\config"
set "RC=0"
set "FALHA=0"

rem 1) esta integro?
set "SAUDAVEL=0"
if exist "%RAIZ%\bin\openvpn.exe" if exist "%RAIZ%\bin\openvpn-gui.exe" (
  sc query OpenVPNServiceInteractive >nul 2>&1
  if not errorlevel 1 set "SAUDAVEL=1"
)
if "%SAUDAVEL%"=="1" echo OpenVPN ja instalado e integro: nada a reinstalar
if "%SAUDAVEL%"=="1" goto perfil

rem 2) nao esta integro: se ha restos, limpa; depois instala do zero
if exist "%RAIZ%" (
  echo encontrei restos ou uma instalacao com problema: limpando para instalar do zero
  taskkill /f /im openvpn-gui.exe >nul 2>&1
  net stop OpenVPNServiceInteractive >nul 2>&1
  net stop OpenVPNService >nul 2>&1
  taskkill /f /im openvpn.exe >nul 2>&1
  msiexec /x "%AQUI%openvpn-install.msi" /qn /norestart
  if exist "%RAIZ%\bin" rmdir /s /q "%RAIZ%\bin"
)
msiexec /i "%AQUI%openvpn-install.msi" /qn /norestart
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" if not "%RC%"=="3010" if not "%RC%"=="1641" (
  echo msiexec /i terminou com codigo %RC%
  exit /b %RC%
)

:perfil
rem 3) importa o perfil (so se faltar ou estiver diferente)
if not exist "%DESTINO%" mkdir "%DESTINO%"
for %%F in ("%AQUI%config\*.ovpn") do call :importar "%%~fF" "%%~nxF"
if "%FALHA%"=="1" (
  echo nao foi possivel copiar o perfil para %DESTINO%
  exit /b 1
)

rem 4) confere o resultado
if not exist "%RAIZ%\bin\openvpn.exe" (
  echo o OpenVPN nao ficou instalado em %RAIZ%
  exit /b 2
)
for %%F in ("%AQUI%config\*.ovpn") do if not exist "%DESTINO%\%%~nxF" (
  echo o perfil %%~nxF nao ficou em %DESTINO%
  exit /b 3
)
echo OpenVPN e perfil em ordem
exit /b %RC%

:importar
if exist "%DESTINO%\%~2" (
  fc /b "%~1" "%DESTINO%\%~2" >nul 2>&1
  if not errorlevel 1 (
    echo perfil %~2 ja esta igual
    exit /b 0
  )
)
copy /y "%~1" "%DESTINO%\%~2" >nul
if errorlevel 1 set "FALHA=1"
exit /b 0
