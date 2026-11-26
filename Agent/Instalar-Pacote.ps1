# Instalacao silenciosa a partir de um pacote (usada pelo instalador .exe): le servidor e token do pacote.json
# que esta ao lado deste script, chama o Install-Agente.ps1 e dispara a primeira leitura. Precisa de administrador.
param([switch]$SemRegistroDesinstalacao)
$ErrorActionPreference = 'Stop'
$arq = Join-Path $PSScriptRoot 'pacote.json'
if (-not (Test-Path $arq)) { Write-Error 'pacote.json nao encontrado ao lado do instalador.'; exit 2 }
$p = Get-Content $arq -Raw -Encoding UTF8 | ConvertFrom-Json
$args2 = @{ Servidor = $p.servidor; Token = $p.token }
if ($SemRegistroDesinstalacao) { $args2.SemRegistroDesinstalacao = $true }
& (Join-Path $PSScriptRoot 'Install-Agente.ps1') @args2
try { Start-ScheduledTask -TaskName 'PresencaAgente' } catch { }
exit 0
