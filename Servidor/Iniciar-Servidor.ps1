# Liga o servidor de presenca/produtividade LOCAL (so para testes; o de producao e o da hospedagem).
# E o mesmo codigo PHP da hospedagem (Servidor\fonte), rodando no servidor embutido do PHP.
# Na primeira vez cria Servidor\local\config.php com token e senha (reaproveita os do servidor Node antigo, se existirem).
$ErrorActionPreference = 'Stop'
$raiz     = Split-Path -Parent $PSScriptRoot
$pasta    = Join-Path $PSScriptRoot 'local'
$cfgFile  = Join-Path $pasta 'config.php'
$web      = Join-Path $PSScriptRoot 'fonte'
$porta    = 3000
$url      = "http://localhost:$porta"

# Atualiza o PATH desta janela (o PHP pode ter sido instalado depois que o terminal abriu)
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
if (-not (Get-Command php -ErrorAction SilentlyContinue)) {
    Write-Host 'PHP nao encontrado. Instale com:  winget install PHP.PHP.8.3' -ForegroundColor Red
    exit 1
}

function Novo-Aleatorio([int]$bytes) {
    $b = New-Object byte[] $bytes
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($b); $rng.Dispose()
    return $b
}

if (-not (Test-Path $cfgFile)) {
    $null = New-Item -ItemType Directory -Path $pasta -Force
    $token = $null; $senha = $null; $usuario = 'admin'
    $envAntigo = Join-Path $raiz '_legado\server-node\.env'
    if (Test-Path $envAntigo) {
        $ev = @{}
        Get-Content $envAntigo | ForEach-Object { if ($_ -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$') { $ev[$matches[1]] = $matches[2] } }
        $token = $ev['AGENT_TOKEN']; $senha = $ev['PAINEL_PASS']; if ($ev['PAINEL_USER']) { $usuario = $ev['PAINEL_USER'] }
    }
    if (-not $token) { $token = -join ((Novo-Aleatorio 24) | ForEach-Object { '{0:x2}' -f $_ }) }
    if (-not $senha) {
        $alfabeto = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
        $senha = -join ((Novo-Aleatorio 14) | ForEach-Object { $alfabeto[$_ % $alfabeto.Length] })
    }
    $dados = (Join-Path $pasta 'dados') -replace '\\', '/'
    $unid  = (Join-Path $raiz 'Config\unidades.json') -replace '\\', '/'
    $php = "<?php`nreturn [`n    'agent_token' => '$token',`n    'painel_user' => '$usuario',`n    'painel_pass' => '$senha',`n    'online_min' => 45,`n    'dados_dir' => '$dados',`n    'unidades_file' => '$unid',`n];`n"
    [IO.File]::WriteAllText($cfgFile, $php, (New-Object Text.UTF8Encoding($false)))
    # Guarda o token tambem no formato que o instalador do agent le
    "AGENT_TOKEN=$token`nPAINEL_USER=$usuario`nPAINEL_PASS=$senha" | Set-Content -Path (Join-Path $pasta '.env') -Encoding UTF8
    Write-Host 'Primeira execucao: configuracao criada em Servidor\local\config.php' -ForegroundColor Green
}

$cfg = @{}
Get-Content (Join-Path $pasta '.env') | ForEach-Object { if ($_ -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$') { $cfg[$matches[1]] = $matches[2] } }

Write-Host ''
Write-Host '============================================='
Write-Host "  Painel:   $url"
Write-Host "  Usuario:  $($cfg['PAINEL_USER'])"
Write-Host "  Senha:    $($cfg['PAINEL_PASS'])"
Write-Host '============================================='
Write-Host '(a senha so vale na PRIMEIRA execucao: depois de criada, ela fica no banco. Troque pelo painel: "Trocar senha")'
Write-Host ''

# Firewall: deixa os outros PCs da mesma rede acessarem a porta (so a sub-rede local). Pede permissao uma vez.
$regra = "Presenca Servidor (TCP $porta)"
if (-not (Get-NetFirewallRule -DisplayName $regra -ErrorAction SilentlyContinue)) {
    Write-Host "Liberando a porta $porta no firewall para outros PCs da rede (o Windows vai pedir permissao)..." -ForegroundColor Yellow
    $cmd = "New-NetFirewallRule -DisplayName '$regra' -Direction Inbound -Protocol TCP -LocalPort $porta -Action Allow -Profile Any -RemoteAddress LocalSubnet | Out-Null"
    try { Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile', '-Command', $cmd }
    catch { Write-Host 'Nao foi liberado (permissao negada). Outros PCs nao vao conseguir enviar dados.' -ForegroundColor Red }
}
$ipRede = ''
try {
    $ipRede = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
              Select-Object -First 1 | ForEach-Object { @($_.IPv4Address)[0].IPAddress }
} catch { }
if ($ipRede) { Write-Host "Endereco para os outros PCs (teste na rede interna): http://${ipRede}:$porta" -ForegroundColor Cyan; Write-Host '' }

# Ja esta rodando?
try {
    Invoke-RestMethod "$url/health" -TimeoutSec 2 | Out-Null
    Write-Host 'O servidor ja esta rodando. Abrindo o painel...' -ForegroundColor Yellow
    Start-Process $url
    exit 0
} catch { }

# Extensoes do PHP (PDO SQLite e mbstring) quando o php.ini nao as habilita
$phpBin = (php -r 'echo PHP_BINARY;')
$extDir = Join-Path (Split-Path -Parent $phpBin) 'ext'
$flags = @()
if (Test-Path (Join-Path $extDir 'php_pdo_sqlite.dll')) {
    $flags = @('-d', "extension_dir=$extDir", '-d', 'extension=pdo_sqlite', '-d', 'extension=sqlite3', '-d', 'extension=mbstring')
}

Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile -Command Start-Sleep 2; Start-Process '$url'"
Write-Host 'Servidor ligado. MANTENHA ESTA JANELA ABERTA (fechar = desligar).' -ForegroundColor Cyan
$env:PRESENCA_CONFIG = $cfgFile
& php @flags -S "0.0.0.0:$porta" -t $web (Join-Path $web 'index.php')
