@echo off
title Gerar Pacote do Servidor (hospedagem)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Servidor\Gerar-Hospedagem.ps1" %*
echo.
pause
