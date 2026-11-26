<#
.SYNOPSIS
  Gera o pacote de atualizacao do agent e o assina com a chave PRIVADA (que fica offline, fora do servidor e do git).

.DESCRIPTION
  -NovaChave   cria o par de chaves RSA 2048: grava a privada em -Chave (padrao: chaves\atualizador-privada.xml,
               ignorada pelo git) e a publica em Agent\chave-publica.xml (esta SIM vai no git e no pacote do agent).
               Depois de gerar, copie a privada para um pendrive/cofre e apague-a do PC de trabalho.
  (sem -NovaChave) monta Entregas\Atualizacao\pacote.zip + manifest.json assinados, com a versao de Agent\versao.txt.
               Suba esses dois arquivos para  _app/dados/agente/  na hospedagem.

.EXAMPLE
  .\Assinar-Atualizacao.ps1 -NovaChave
  .\Assinar-Atualizacao.ps1 -Chave E:\cofre\atualizador-privada.xml
#>
param(
    [string]$Chave,
    [switch]$NovaChave
)
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
if (-not $Chave) { $Chave = Join-Path $raiz 'chaves\atualizador-privada.xml' }
$arqPublica = Join-Path $PSScriptRoot 'chave-publica.xml'
Import-Module (Join-Path $PSScriptRoot 'Atualizador.psm1') -Force

if ($NovaChave) {
    if ((Test-Path $Chave) -or (Test-Path $arqPublica)) {
        Write-Host 'Ja existe uma chave. Trocar a chave exige reinstalar TODOS os agents. Apague os arquivos manualmente se for isso mesmo que quer.' -ForegroundColor Red
        exit 1
    }
    $pastaChave = Split-Path -Parent $Chave
    if (-not (Test-Path $pastaChave)) { $null = New-Item -ItemType Directory -Path $pastaChave -Force }
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 2048
    $rsa.PersistKeyInCsp = $false
    [System.IO.File]::WriteAllText($Chave, $rsa.ToXmlString($true), [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($arqPublica, $rsa.ToXmlString($false), [System.Text.Encoding]::UTF8)
    Write-Host "Chave privada: $Chave"
    Write-Host "Chave publica: $arqPublica"
    Write-Host 'GUARDE a privada em local seguro/offline e faca copia. Sem ela nao ha como assinar atualizacoes.' -ForegroundColor Yellow
    exit 0
}

if (-not (Test-Path $Chave)) { Write-Host "Chave privada nao encontrada: $Chave (use -Chave <caminho>)" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $arqPublica)) { Write-Host 'Agent\chave-publica.xml nao existe. Rode -NovaChave primeiro.' -ForegroundColor Red; exit 1 }
$versaoTxt = (Get-Content (Join-Path $PSScriptRoot 'versao.txt') -Raw).Trim()
$v = $null
if (-not [version]::TryParse($versaoTxt, [ref]$v)) { Write-Host "versao.txt invalida: $versaoTxt" -ForegroundColor Red; exit 1 }

$saida = Join-Path $raiz 'Entregas\Atualizacao'
if (-not (Test-Path $saida)) { $null = New-Item -ItemType Directory -Path $saida -Force }
$zipPath = Join-Path $saida 'pacote.zip'
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Add-Type -AssemblyName System.IO.Compression
$ms = New-Object System.IO.MemoryStream
$zip = New-Object System.IO.Compression.ZipArchive ($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
foreach ($nome in (Get-ArquivosAtualizaveis)) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $nome))
    $e = $zip.CreateEntry($nome)
    $s = $e.Open(); $s.Write($bytes, 0, $bytes.Length); $s.Dispose()
}
$zip.Dispose()
$pacote = $ms.ToArray(); $ms.Dispose()

$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
$rsa.PersistKeyInCsp = $false
$rsa.FromXmlString([System.IO.File]::ReadAllText($Chave))
$assinatura = [Convert]::ToBase64String($rsa.SignData($pacote, 'SHA256'))

# confere com a chave publica que vai nos agents, antes de liberar
$pub = [System.IO.File]::ReadAllText($arqPublica)
if (-not (Test-AssinaturaPacote -Bytes $pacote -AssinaturaBase64 $assinatura -ChavePublicaXml $pub)) {
    Write-Host 'A chave privada nao corresponde a Agent\chave-publica.xml. Nada foi gerado.' -ForegroundColor Red; exit 1
}
[System.IO.File]::WriteAllBytes($zipPath, $pacote)
[ordered]@{ versao = $versaoTxt; sha256 = (Get-Sha256Hex $pacote); tamanho = $pacote.Length; assinatura = $assinatura } |
    ConvertTo-Json | Set-Content -Path (Join-Path $saida 'manifest.json') -Encoding UTF8

Write-Host "Atualizacao $versaoTxt assinada em $saida" -ForegroundColor Green
Write-Host 'Suba pacote.zip e manifest.json para  _app/dados/agente/  na hospedagem (sobrescrevendo os antigos).'
Write-Host 'Os agents instalados com o atualizador pegam sozinhos em ate 6 horas.'
