<#
  Instala o cliente RustDesk e aponta para o relay da empresa (piloto).
  Executar como ADMINISTRADOR, no PC que sera acessado.
  Ao final mostra o ID e a senha de acesso permanente deste PC.
  Uso:  powershell -ExecutionPolicy Bypass -File .\Instalar-RustDesk-Piloto.ps1
#>
param(
    [string]$Servidor = 'remoto.example.com',
    [string]$Chave    = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
    [string]$Versao   = '1.5.3',
    [string]$Sha256   = '523ba0efbf62a21739961b62c7daaffb44d3da86139c546b364fd4e1333ed249'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Execute este script como Administrador.' }

# Confere se o PC enxerga o relay
$dns = Resolve-DnsName $Servidor -ErrorAction SilentlyContinue
if (-not $dns) { throw "Nao consegui resolver $Servidor. Este PC precisa estar na rede interna (ou na VPN)." }
foreach ($p in 21116, 21117) {
    if (-not (Test-NetConnection $Servidor -Port $p -WarningAction SilentlyContinue).TcpTestSucceeded) {
        throw "Sem acesso a $Servidor porta $p."
    }
}

$exe = Join-Path $env:TEMP "rustdesk-$Versao-x86_64.exe"
Write-Host "Baixando RustDesk $Versao ..."
Invoke-WebRequest -UseBasicParsing "https://github.com/rustdesk/rustdesk/releases/download/$Versao/rustdesk-$Versao-x86_64.exe" -OutFile $exe
$hash = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
if ($hash -ne $Sha256) { Remove-Item $exe -Force; throw "Hash do instalador nao confere ($hash). Abortado." }

Write-Host 'Instalando (silencioso) ...'
Start-Process $exe -ArgumentList '--silent-install' -Wait
Remove-Item $exe -Force

$rd = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
if (-not (Test-Path $rd)) { throw 'RustDesk nao foi instalado.' }

# Fecha a interface aberta pelo instalador e registra o servico do Windows
# (sem o servico o PC so consegue controlar outros, nao ser controlado)
Get-Process rustdesk -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2
if (-not (Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue)) {
    & $rd --install-service
    Start-Sleep 5
}
$svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
if (-not $svc) { throw 'O servico RustDesk nao foi criado. Rode este script como Administrador.' }
Set-Service RustDesk -StartupType Automatic
if ($svc.Status -ne 'Running') { Start-Service RustDesk; Start-Sleep 3 }

Write-Host 'Configurando o servidor da empresa ...'
& $rd --option custom-rendezvous-server $Servidor
& $rd --option relay-server $Servidor
& $rd --option key $Chave
& $rd --option stop-service N
Start-Sleep 2

# Senha de acesso permanente (aleatoria, 16 caracteres)
$chars = (48..57) + (65..90) + (97..122)
$senha = -join (1..16 | ForEach-Object { [char]($chars | Get-Random) })
& $rd --password $senha
Start-Sleep 2

Restart-Service RustDesk -ErrorAction SilentlyContinue
Start-Sleep 5

$id = $null
for ($i = 0; $i -lt 15 -and -not $id; $i++) {
    $o = (& $rd --get-id 2>$null | Out-String).Trim()
    if ($o -match '^\d{6,}$') { $id = $o } else { Start-Sleep 2 }
}

Write-Host ''
Write-Host '=============================================' -ForegroundColor Green
Write-Host " PC:     $env:COMPUTERNAME"
Write-Host " ID:     $id"
Write-Host " Senha:  $senha"
Write-Host '=============================================' -ForegroundColor Green
Write-Host 'Anote o ID e a senha (so para o piloto). Nao envie por e-mail ou chat.'
