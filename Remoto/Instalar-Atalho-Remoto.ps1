<#
  Instala, para o usuario atual, o atalho pp-remoto:// usado pelo botao "Acesso remoto" do painel.
  Rodar UMA vez em cada PC de quem acessa. Nao precisa de administrador (grava so no perfil do usuario).
  Uso:  powershell -ExecutionPolicy Bypass -File .\Instalar-Atalho-Remoto.ps1
#>
$ErrorActionPreference = 'Stop'
$origem = Join-Path $PSScriptRoot 'pp-remoto.ps1'
if (-not (Test-Path $origem)) { throw "Nao encontrei pp-remoto.ps1 ao lado deste script." }
$pasta = Join-Path $env:LOCALAPPDATA 'PresencaPP\remoto'
New-Item -ItemType Directory -Force $pasta | Out-Null
$destino = Join-Path $pasta 'pp-remoto.ps1'
Copy-Item $origem $destino -Force

$base = 'HKCU:\Software\Classes\pp-remoto'
New-Item -Path "$base\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path $base -Name '(default)' -Value 'URL:Acesso remoto'
Set-ItemProperty -Path $base -Name 'URL Protocol' -Value ''
$cmd = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $destino + '" "%1"'
Set-ItemProperty -Path "$base\shell\open\command" -Name '(default)' -Value $cmd

Write-Host 'Atalho instalado para este usuario.' -ForegroundColor Green
Write-Host 'Agora, no painel, abra uma maquina com a etiqueta Remoto e clique em "Acesso remoto".'
Write-Host 'Na primeira vez o navegador pergunta se pode abrir o aplicativo: marque para lembrar a escolha.'
