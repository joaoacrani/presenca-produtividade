@echo off
title Gerar Instalador EXE do Agente
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Agent\Gerar-Instalador.ps1" %*
echo.
pause
