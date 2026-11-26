# Monta a pasta "Pacote-Agente" (e um .zip) para instalar o agent em OUTRO PC com um duplo clique.
# O pacote ja leva o endereco do servidor e o token.
param([string]$Servidor)
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

if (-not $Servidor) {
    # Sugere o IP desta maquina na rede interna (para testes no escritorio)
    $sugestao = ''
    try {
        $ip = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
              Select-Object -First 1 | ForEach-Object { @($_.IPv4Address)[0].IPAddress }
        if ($ip) { $sugestao = "http://${ip}:3000" }
    } catch { }
    Write-Host 'Teste na rede do escritorio: use o endereco desta maquina. Uso real: use o https:// publico.'
    $msg = 'Endereco do servidor'
    if ($sugestao) { $msg += " (Enter = $sugestao)" }
    $Servidor = Read-Host $msg
    if (-not $Servidor -and $sugestao) { $Servidor = $sugestao }
}
$Servidor = $Servidor.Trim().TrimEnd('/')
$httpLocal = '^http://(10(\.\d{1,3}){3}|192\.168(\.\d{1,3}){2}|172\.(1[6-9]|2\d|3[01])(\.\d{1,3}){2}|localhost|127\.0\.0\.1)(:\d+)?$'
if ($Servidor -notmatch '^https://' -and $Servidor -notmatch $httpLocal) {
    Write-Host 'Endereco invalido: use https://... ou, so para teste, http://IP-da-rede-interna:3000' -ForegroundColor Red
    exit 1
}

# Token: se o endereco e o da hospedagem (Servidor\credenciais.json), usa o dela; senao, o do servidor local (Servidor\local\.env)
$token = $null
$credFile = Join-Path $raiz 'Servidor\credenciais.json'
if ((Test-Path $credFile) -and $Servidor -match '^https://') {
    $c = Get-Content $credFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($c.url.TrimEnd('/') -eq $Servidor) { $token = $c.token; Write-Host 'Usando o token da hospedagem.' }
}
if (-not $token) {
    $envFile = Join-Path $raiz 'Servidor\local\.env'
    if (-not (Test-Path $envFile)) { Write-Host 'Ligue o servidor uma vez (1 - Iniciar Servidor.bat) para gerar o token.' -ForegroundColor Red; exit 1 }
    $linha = Get-Content $envFile | Where-Object { $_ -match '^\s*AGENT_TOKEN\s*=' } | Select-Object -First 1
    $token = ($linha -replace '^\s*AGENT_TOKEN\s*=\s*', '').Trim()
    if (-not $token) { Write-Host 'AGENT_TOKEN nao encontrado em Servidor\local\.env' -ForegroundColor Red; exit 1 }
}

$pacote = Join-Path $raiz 'Entregas\Agente\Pacote-Agente'
if (Test-Path $pacote) { Remove-Item $pacote -Recurse -Force }
$null = New-Item -ItemType Directory -Path $pacote -Force

foreach ($a in 'Detectar-Presenca.ps1', 'Presenca.psm1', 'Navegacao.psm1', 'Atualizador.psm1', 'Atualizar-Agente.ps1',
               'chave-publica.xml', 'versao.txt', 'Install-Agente.ps1', 'Instalar-Agente-Facil.ps1', 'Instalar-Pacote.ps1') {
    if (-not (Test-Path (Join-Path $PSScriptRoot $a))) {
        Write-Host "Arquivo ausente: Agent\$a. Para a chave publica rode: Agent\Assinar-Atualizacao.ps1 -NovaChave" -ForegroundColor Red
        exit 1
    }
    Copy-Item (Join-Path $PSScriptRoot $a) $pacote
}
Copy-Item (Join-Path $raiz 'Config\unidades.json') $pacote
@{ servidor = $Servidor; token = $token } | ConvertTo-Json | Set-Content (Join-Path $pacote 'pacote.json') -Encoding UTF8

@'
@echo off
title Instalar Agente de Presenca
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar-Agente-Facil.ps1"
'@ | Set-Content (Join-Path $pacote 'INSTALAR.bat') -Encoding ASCII

@'
INSTALACAO DO AGENTE DE PRESENCA

1. Copie esta pasta inteira para o PC (ou extraia o .zip).
2. De dois cliques em INSTALAR.bat e clique em "Sim" quando o Windows pedir permissao.
3. Aguarde a mensagem "Pronto". Pode apagar a pasta depois.

Para remover: abra o PowerShell como administrador nesta pasta e rode  .\Install-Agente.ps1 -Desinstalar
Este pacote contem um token: nao compartilhe fora da empresa.

O QUE O AGENTE COLETA: a localizacao do PC (rede/VPN), o nome do usuario e os SITES acessados nos navegadores
(dominio e caminho, sem os parametros da URL; nada de conteudo, senhas ou janela anonima).
Informe os colaboradores antes de instalar. Para instalar SEM coletar sites, rode em um PowerShell de administrador:
  .\Install-Agente.ps1 -Servidor <endereco> -Token <token> -SemNavegacao
'@ | Set-Content (Join-Path $pacote 'LEIA-ME.txt') -Encoding UTF8

$zip = Join-Path $raiz 'Entregas\Agente\Pacote-Agente.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $pacote '*') -DestinationPath $zip

Write-Host ''
Write-Host "Pacote pronto para o servidor $Servidor" -ForegroundColor Green
Write-Host "  Pasta: $pacote"
Write-Host "  Zip:   $zip"
Write-Host 'Leve a pasta (ou o zip) para o outro PC e de dois cliques em INSTALAR.bat.'
