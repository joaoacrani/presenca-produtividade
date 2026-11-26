# Gera o instalador .exe do agent (Inno Setup): Entregas\Agente\Instalar-Agente-PP-<versao>.exe
# O .exe contem servidor + token (como o .zip): nao compartilhe fora da empresa.
# Aparece em "Aplicativos instalados" com botao Desinstalar. Instalacao silenciosa: <exe> /VERYSILENT /SUPPRESSMSGBOXES
param([string]$Servidor = 'https://presenca.example.com/presenca')
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

$iscc = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    Write-Host 'Inno Setup 6 nao encontrado. Instale com:  winget install JRSoftware.InnoSetup' -ForegroundColor Red
    exit 1
}

# 1) monta a pasta do pacote (Pacote-Agente) com servidor/token
& (Join-Path $PSScriptRoot 'Gerar-Pacote.ps1') -Servidor $Servidor | Out-Null
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { Write-Host 'Falha ao montar o pacote.' -ForegroundColor Red; exit 1 }
$origem = Join-Path $raiz 'Entregas\Agente\Pacote-Agente'
if (-not (Test-Path (Join-Path $origem 'pacote.json'))) { Write-Host 'Pacote nao foi gerado.' -ForegroundColor Red; exit 1 }
$versao = (Get-Content (Join-Path $PSScriptRoot 'versao.txt') -Raw).Trim()
$saida = Join-Path $raiz 'Entregas\Agente'

# 2) compila numa pasta temporaria (antivirus/sincronizacao podem cortar o arquivo quando ele e gravado direto na pasta de entrega)
$tmpSaida = Join-Path $env:TEMP ('inno-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpSaida -Force
& $iscc "/DOrigem=$origem" "/DVersao=$versao" "/DSaida=$tmpSaida" (Join-Path $PSScriptRoot 'Instalador.iss') | Select-Object -Last 6
if ($LASTEXITCODE -ne 0) { Write-Host 'Falha ao compilar o instalador.' -ForegroundColor Red; exit 1 }

# 3) copia para Entregas e CONFERE: o arquivo entregue tem de ser identico ao compilado (senao o Windows acusa "programa corrompido")
$nomeExe = "Instalar-Agente-PP-$versao.exe"
$exeTmp = Join-Path $tmpSaida $nomeExe
$exe = Join-Path $saida $nomeExe
if (-not (Test-Path $exeTmp)) { Write-Host 'O compilador nao gerou o instalador.' -ForegroundColor Red; exit 1 }
Copy-Item $exeTmp $exe -Force
Start-Sleep -Seconds 2
if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne (Get-FileHash $exeTmp -Algorithm SHA256).Hash) {
    Write-Host "O arquivo entregue NAO confere com o compilado (tamanho $((Get-Item $exe).Length) x $((Get-Item $exeTmp).Length)). Nao use este instalador." -ForegroundColor Red
    Write-Host "Provavel causa: antivirus ou sincronizacao mexendo na pasta Entregas. Compilado integro em: $exeTmp" -ForegroundColor Yellow
    exit 1
}
Remove-Item $tmpSaida -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "Instalador pronto: $exe" -ForegroundColor Green
Write-Host "Tamanho: $([math]::Round((Get-Item $exe).Length / 1KB)) KB. Contem o token da hospedagem: use so dentro da empresa."
