<#
.SYNOPSIS
  Copia de seguranca do repositorio git para uma pasta (por exemplo, dentro do OneDrive) e, se pedido, roda os testes
  (a "integracao continua" local). A copia e um unico arquivo .bundle (historico completo): o OneDrive sincroniza um arquivo so,
  sem o risco de corromper uma pasta .git sincronizada ao vivo.

.EXAMPLE
  .\Ferramentas\Backup-Repositorio.ps1 -Pasta "C:\Users\voce\OneDrive - Empresa\Backups\Presenca"   # primeira vez: guarda a pasta
  .\Ferramentas\Backup-Repositorio.ps1                    # usa a pasta guardada
  .\Ferramentas\Backup-Repositorio.ps1 -Testar            # alem da copia, roda os testes e grava o resultado em Entregas\ci\ultimo.txt

  Para restaurar em outro PC:  git clone presenca-agente-AAAAMMDD-HHMMSS.bundle C:\PresencaAgente
#>
param(
    [string]$Pasta,
    [switch]$Testar,
    [int]$Manter = 30
)
$ErrorActionPreference = 'Continue'   # git e node escrevem avisos em stderr: o resultado vem do codigo de saida
$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz

function Git-Config([string]$chave) { $v = (& git config --local --get $chave 2>$null); if ($LASTEXITCODE -eq 0) { return ([string]$v).Trim() } return '' }

if ($Pasta) { & git config --local presenca.backupRepo $Pasta | Out-Null }
else { $Pasta = Git-Config 'presenca.backupRepo' }

$ciDir = Join-Path $raiz 'Entregas\ci'
if (-not (Test-Path $ciDir)) { $null = New-Item -ItemType Directory -Path $ciDir -Force }
$logCi = Join-Path $ciDir 'ultimo.txt'
function Anotar([string]$t) { Add-Content -Path $logCi -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $t) -Encoding UTF8 }

$resumo = @()
if ($Pasta) {
    try {
        if (-not (Test-Path $Pasta)) { $null = New-Item -ItemType Directory -Path $Pasta -Force }
        $arq = Join-Path $Pasta ("presenca-agente-{0:yyyyMMdd-HHmmss}.bundle" -f (Get-Date))
        & git bundle create $arq --all 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git bundle falhou' }
        & git bundle verify $arq 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'a copia gerada nao passou na verificacao (git bundle verify)' }
        $copias = @(Get-ChildItem $Pasta -Filter 'presenca-agente-*.bundle' | Sort-Object LastWriteTime -Descending)
        if ($copias.Count -gt $Manter) { $copias | Select-Object -Skip $Manter | Remove-Item -Force }
        $resumo += ("backup: ok ({0}, {1:N1} MB, {2} copia(s) na pasta)" -f (Split-Path -Leaf $arq), ((Get-Item $arq).Length / 1MB), [Math]::Min($Manter, $copias.Count))
    } catch { $resumo += "backup: FALHOU - $($_.Exception.Message)" }
} else { $resumo += 'backup: pasta nao configurada (use -Pasta)' }

if ($Testar) {
    $ok = $true
    $t = & node --test (Join-Path $raiz 'Testes\servidor.test.js') 2>&1 | Out-String
    $m = [regex]::Match($t, 'pass (\d+)[\s\S]*?fail (\d+)')
    $falhas = if ($m.Success) { [int]$m.Groups[2].Value } else { -1 }
    if ($falhas -ne 0) { $ok = $false }
    $resumo += ("testes do servidor: {0} passaram, {1} falharam" -f $(if ($m.Success) { $m.Groups[1].Value } else { '?' }), $(if ($falhas -ge 0) { $falhas } else { '?' }))
    $p = Invoke-Pester -Path (Join-Path $raiz 'Testes') -PassThru -Quiet 2>$null
    if ($p) { $resumo += ("testes do agent (Pester): {0} passaram, {1} falharam" -f $p.PassedCount, $p.FailedCount); if ($p.FailedCount -gt 0) { $ok = $false } }
    $resumo += $(if ($ok) { 'resultado: VERDE' } else { 'resultado: VERMELHO (veja os testes antes de publicar)' })
}
$commit = (& git rev-parse --short HEAD 2>$null)
Anotar ("commit {0} | {1}" -f $commit, ($resumo -join ' | '))
$resumo | ForEach-Object { Write-Host $_ }
