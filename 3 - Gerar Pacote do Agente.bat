@echo off
title Gerar Pacote do Agente
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Agent\Gerar-Pacote.ps1" %*
echo.
pause
