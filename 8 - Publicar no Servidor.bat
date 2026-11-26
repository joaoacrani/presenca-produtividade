@echo off
title Publicar no servidor (hospedagem)
rem Sem parametros: publica Entregas\Servidor\presenca-atualizacao.zip. Com -Agente: publica a atualizacao assinada do agent. Com -SimularApenas: so lista.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Servidor\Publicar\Publicar-Servidor.ps1" %*
echo.
pause
