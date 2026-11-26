@echo off
title Backup do servidor (banco e chaves)
rem Primeira vez: 9 - Backup do Servidor.bat -Destino D:\Backups\Presenca   (a pasta fica guardada). Depois, so dar duplo clique.
rem Para rodar todo dia as 03:30: 9 - Backup do Servidor.bat -Agendar
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Servidor\Publicar\Backup-Servidor.ps1" %*
echo.
pause
