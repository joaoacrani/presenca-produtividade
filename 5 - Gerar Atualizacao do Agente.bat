@echo off
title Gerar Atualizacao do Agente (assinada)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Agent\Assinar-Atualizacao.ps1" %*
echo.
pause
