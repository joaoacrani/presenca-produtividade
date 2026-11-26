@echo off
title Instalar Agente de Presenca
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Agent\Instalar-Agente-Facil.ps1" %*
