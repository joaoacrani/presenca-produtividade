@echo off
title Configurar a publicacao do servidor (uma vez)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Servidor\Publicar\Configurar-Publicacao.ps1" %*
echo.
pause
