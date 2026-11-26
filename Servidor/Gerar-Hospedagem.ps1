# Monta o pacote do servidor PHP para subir na hospedagem (hospedagem compartilhada): Entregas\Servidor\presenca.zip
# Gera token e senha na primeira vez e guarda em Servidor\credenciais.json (NAO compartilhe esse arquivo).
param([string]$Url)
$ErrorActionPreference = 'Stop'

$raiz   = Split-Path -Parent $PSScriptRoot
$pastaServ = $PSScriptRoot
$origem = Join-Path $pastaServ 'fonte'
$build  = Join-Path $pastaServ 'build\presenca'
$credFile = Join-Path $pastaServ 'credenciais.json'

if (-not $Url) { $Url = Read-Host 'Endereco final do servidor (ex.: https://presenca.example.com/presenca)' }
$Url = $Url.Trim().TrimEnd('/')
if ($Url -notmatch '^https://') { Write-Host 'O endereco precisa comecar com https://' -ForegroundColor Red; exit 1 }

function Novo-Aleatorio([int]$bytes) {
    $b = New-Object byte[] $bytes
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($b); $rng.Dispose()
    return $b
}

if (Test-Path $credFile) {
    $c = Get-Content $credFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $token = $c.token; $user = $c.usuario; $senha = $c.senha
    Write-Host 'Reaproveitando token e senha ja gerados (Servidor\credenciais.json).'
} else {
    $token = -join ((Novo-Aleatorio 24) | ForEach-Object { '{0:x2}' -f $_ })
    $alfabeto = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $senha = -join ((Novo-Aleatorio 16) | ForEach-Object { $alfabeto[$_ % $alfabeto.Length] })
    $user = 'admin'
}
@{ url = $Url; usuario = $user; senha = $senha; token = $token } | ConvertTo-Json | Set-Content $credFile -Encoding UTF8

# Monta a pasta
if (Test-Path $build) { Remove-Item $build -Recurse -Force }
$null = New-Item -ItemType Directory -Path (Join-Path $build '_app\public') -Force
Copy-Item (Join-Path $origem 'index.php')  $build
Copy-Item (Join-Path $origem '.htaccess')  $build
Copy-Item (Join-Path $origem '_app\.htaccess') (Join-Path $build '_app')
Copy-Item (Join-Path $raiz 'Config\unidades.json') (Join-Path $build '_app')
Copy-Item (Join-Path $origem '_app\lib') (Join-Path $build '_app') -Recurse
Copy-Item (Join-Path $origem '_app\public\*') (Join-Path $build '_app\public') -Recurse

$cfgPhp = "<?php`nreturn [`n    'agent_token' => '$token',`n    'painel_user' => '$user',`n    'painel_pass' => '$senha',`n    'online_min' => 20,`n    'retencao_dias' => 90,            // leituras de presenca (minuto a minuto)`n    'retencao_nav_dias' => 30,       // URLs detalhadas (o resumo por dominio fica por retencao_agregados_dias)`n    'retencao_agregados_dias' => 400,`n    'fuso' => 'America/Sao_Paulo',`n    'sessao_horas' => 12,`n    'presenca_min_leituras' => 3,    // leituras presenciais minimas para o dia contar como presencial`n    'presenca_pct_min' => 50,        // e % minimo das leituras do dia`n    'feriados' => [],                // ex.: ['2026-04-21', '2026-05-01']`n    // --- seguranca do painel ---`n    'exigir_2fa' => false,           // true = todos precisam ativar a verificacao em 2 etapas`n    'login_max_falhas_ip' => 20,     // falhas de login por IP em 15 min antes de bloquear o IP`n    'retencao_auditoria_dias' => 365,`n];`n"
[IO.File]::WriteAllText((Join-Path $build '_app\config.php'), $cfgPhp, (New-Object Text.UTF8Encoding($false)))

$zip = Join-Path $raiz 'Entregas\Servidor\presenca.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
# Zip montado a mao: nomes com "/" (o Compress-Archive do PowerShell 5.1 grava "\", que quebra em servidor Linux)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs = [IO.File]::Open($zip, [IO.FileMode]::Create)
$za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
$buildFull = (Resolve-Path $build).Path.TrimEnd('\')
foreach ($f in Get-ChildItem -Path $buildFull -Recurse -File -Force) {
    $rel = $f.FullName.Substring($buildFull.Length + 1).Replace('\', '/')
    $e = $za.CreateEntry($rel, [IO.Compression.CompressionLevel]::Optimal)
    $es = $e.Open(); $bytes = [IO.File]::ReadAllBytes($f.FullName); $es.Write($bytes, 0, $bytes.Length); $es.Dispose()
}
$za.Dispose(); $fs.Dispose()
$z = [IO.Compression.ZipFile]::OpenRead($zip)
$nomes = $z.Entries | ForEach-Object { $_.FullName }
$z.Dispose()
if (-not ($nomes -contains '.htaccess')) { Write-Host 'ATENCAO: .htaccess nao entrou no zip.' -ForegroundColor Red; exit 1 }

# Zip de ATUALIZACAO: mesmo conteudo, SEM o config.php (nao sobrescreve senha/token/ajustes ja feitos na hospedagem).
# Os dados (_app/dados) nunca fazem parte de nenhum zip.
$zipAtu = Join-Path $raiz 'Entregas\Servidor\presenca-atualizacao.zip'
if (Test-Path $zipAtu) { Remove-Item $zipAtu -Force }
$fs2 = [IO.File]::Open($zipAtu, [IO.FileMode]::Create)
$za2 = New-Object IO.Compression.ZipArchive($fs2, [IO.Compression.ZipArchiveMode]::Create)
foreach ($f in Get-ChildItem -Path $buildFull -Recurse -File -Force) {
    $rel = $f.FullName.Substring($buildFull.Length + 1).Replace('\', '/')
    if ($rel -eq '_app/config.php') { continue }
    $e = $za2.CreateEntry($rel, [IO.Compression.CompressionLevel]::Optimal)
    $es = $e.Open(); $bytes = [IO.File]::ReadAllBytes($f.FullName); $es.Write($bytes, 0, $bytes.Length); $es.Dispose()
}
$za2.Dispose(); $fs2.Dispose()

Write-Host ''
Write-Host 'Pacote do servidor pronto:' -ForegroundColor Green
Write-Host "  Zip completo (primeira instalacao): $zip"
Write-Host "  Zip de atualizacao (sem config.php): $zipAtu"
Write-Host "  Painel:   $Url/"
Write-Host "  Usuario:  $user"
Write-Host "  Senha:    $senha"
Write-Host '  (token e senha ficam em Servidor\credenciais.json)'
