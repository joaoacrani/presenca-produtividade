<#
.SYNOPSIS
  Copia de seguranca da PASTA do projeto (scripts, atalhos .bat, codigo, documentacao, testes) para o OneDrive, em um zip por dia.
  Fica de fora tudo que e segredo ou pode ser regerado: credenciais.json, chaves\, config.php, .env, bancos, Entregas\ (tem o
  token dos agents), Servidor\local\, .git (o .bundle do Backup-Repositorio.ps1 ja cobre o historico) e node_modules.
  Guarda um zip por dia (se rodar de novo no mesmo dia, troca o de hoje): 14 dias mais novos e um por semana nas 8 semanas anteriores.

.EXAMPLE
  .\Ferramentas\Backup-Pasta.ps1                       # usa a pasta do OneDrive ja configurada (presenca.backupRepo) + \Pasta
  .\Ferramentas\Backup-Pasta.ps1 -Destino "D:\Backups"
  .\Ferramentas\Backup-Pasta.ps1 -Agendar              # cria a tarefa diaria das 12:30 (so roda com o seu usuario logado)
#>
param(
    [string]$Destino,
    [switch]$Agendar,
    [switch]$Silencioso,
    [int]$Diarios = 14,
    [int]$Semanas = 8,
    [int]$PularSeRecenteMin = 0
)
$ErrorActionPreference = 'Continue'   # git escreve avisos em stderr: o resultado vem do codigo de saida
$raiz = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $raiz 'Servidor\Publicar\Backup.psm1') -Force
Set-Location $raiz

function Escrever([string]$t, [string]$cor = '') { if (-not $Silencioso) { if ($cor) { Write-Host $t -ForegroundColor $cor } else { Write-Host $t } } }

if ($Agendar) {
    $acao = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Silencioso' -f (Join-Path $PSScriptRoot 'Backup-Pasta.ps1'))
    $gatilho = New-ScheduledTaskTrigger -Daily -At '12:30'
    $conf = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName 'PresencaBackupPasta' -Action $acao -Trigger $gatilho -Settings $conf -Description 'Backup diario da pasta do projeto de presenca para o OneDrive' -Force | Out-Null
    Write-Host 'Tarefa "PresencaBackupPasta" criada: todo dia as 12:30 (ou na primeira oportunidade, se o PC estiver desligado).' -ForegroundColor Green
    exit 0
}

if (-not $Destino) {
    $base = (& git config --local --get presenca.backupRepo 2>$null)
    if ($LASTEXITCODE -eq 0 -and $base) { $Destino = Join-Path ([string]$base).Trim() 'Pasta' }
}
if (-not $Destino) { Escrever 'Informe a pasta de destino: .\Ferramentas\Backup-Pasta.ps1 -Destino <pasta> (ou configure o backup do git com Backup-Repositorio.ps1 -Pasta).' 'Red'; exit 2 }
if (-not (Test-Path $Destino)) { $null = New-Item -ItemType Directory -Path $Destino -Force }

$hoje = Get-Date
$arq = Join-Path $Destino ("presenca-pasta-{0:yyyyMMdd}.zip" -f $hoje)
if ($PularSeRecenteMin -gt 0 -and (Test-Path $arq) -and (($hoje - (Get-Item $arq).LastWriteTime).TotalMinutes -lt $PularSeRecenteMin)) { Escrever 'Backup da pasta ja feito ha pouco: nada a fazer.'; exit 0 }
try {
    $r = New-ZipDaPasta -Raiz $raiz -Destino $arq
    $copias = @(Get-ChildItem $Destino -Filter 'presenca-pasta-*.zip' -ErrorAction SilentlyContinue)
    foreach ($nome in (Get-BackupsParaApagar $copias $Diarios $Semanas)) { Remove-Item (Join-Path $Destino $nome) -Force }
    $log = Join-Path $Destino 'backup-pasta.log'
    $msg = "{0:yyyy-MM-dd HH:mm:ss} ok: {1} arquivos, {2:N1} MB ({3})" -f (Get-Date), $r.Arquivos, ($r.Bytes / 1MB), (Split-Path -Leaf $arq)
    Add-Content -Path $log -Value $msg -Encoding UTF8
    Escrever ("Backup da pasta: {0} arquivos, {1:N1} MB em {2}. Segredos e saidas geradas ficaram de fora." -f $r.Arquivos, ($r.Bytes / 1MB), $arq) 'Green'
    exit 0
} catch {
    Add-Content -Path (Join-Path $Destino 'backup-pasta.log') -Value ("{0:yyyy-MM-dd HH:mm:ss} FALHOU: {1}" -f (Get-Date), $_.Exception.Message) -Encoding UTF8
    Escrever ("FALHOU: " + $_.Exception.Message) 'Red'
    exit 1
}
