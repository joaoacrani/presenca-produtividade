@echo off
title Backup da pasta do projeto (OneDrive)
rem Copia a pasta do projeto (sem segredos) para o OneDrive. Para rodar todo dia as 12:30: 10 - Backup da Pasta do Projeto.bat -Agendar
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Ferramentas\Backup-Pasta.ps1" %*
echo.
pause
