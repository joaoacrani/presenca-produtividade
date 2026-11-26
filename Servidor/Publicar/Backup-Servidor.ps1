<#
.SYNOPSIS
  Baixa o instantaneo do banco e as chaves do servidor (FTPS), confere, comprime no PC e apaga a copia do servidor
  (para nao ocupar o disco da hospedagem). Guarda as 14 copias diarias mais novas e uma por semana nas 8 semanas anteriores.

.EXAMPLE
  .\Backup-Servidor.ps1 -Destino D:\Backups\Presenca     # primeira vez: escolhe a pasta (fica guardada)
  .\Backup-Servidor.ps1                                  # usa a pasta guardada
  .\Backup-Servidor.ps1 -Agendar                         # cria a tarefa diaria das 03:30 (so roda com o seu usuario logado)
#>
param(
    [string]$Destino,
    [switch]$Agendar,
    [switch]$Silencioso,
    [int]$Diarios = 14,
    [int]$Semanas = 8,
    [switch]$MantemNoServidor
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Publicacao.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.psm1') -Force

if (-not $Destino) { $c = Get-ConfigBackup; if ($c) { $Destino = $c.destino } }
if (-not $Destino) { Write-Host 'Informe a pasta dos backups na primeira vez: .\Backup-Servidor.ps1 -Destino D:\Backups\Presenca' -ForegroundColor Red; exit 2 }
if (-not (Test-Path $Destino)) { $null = New-Item -ItemType Directory -Path $Destino -Force }
Save-ConfigBackup $Destino
$log = Join-Path $Destino 'backup.log'
function Escrever([string]$t, [string]$cor = '') {
    Add-Content -Path $log -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $t) -Encoding UTF8
    if (-not $Silencioso) { if ($cor) { Write-Host $t -ForegroundColor $cor } else { Write-Host $t } }
}

if ($Agendar) {
    $script = Join-Path $PSScriptRoot 'Backup-Servidor.ps1'
    $acao = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Silencioso' -f $script)
    $gatilho = New-ScheduledTaskTrigger -Daily -At '03:30'
    $conf = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName 'PresencaBackupServidor' -Action $acao -Trigger $gatilho -Settings $conf -Description 'Backup diario do servidor de presenca (banco e chaves)' -Force | Out-Null
    Write-Host 'Tarefa "PresencaBackupServidor" criada: todo dia as 03:30 (ou na primeira oportunidade, se o PC estiver desligado).' -ForegroundColor Green
    Write-Host 'Ela usa a configuracao de FTP do seu usuario, entao so roda com voce logado.'
    exit 0
}

$cfg = Get-ConfigPublicacao
if (-not $cfg) { Escrever 'A publicacao ainda nao foi configurada (rode Servidor\Publicar\Configurar-Publicacao.ps1).' 'Red'; exit 2 }

$agora = Get-Date
$carimbo = $agora.ToString('yyyyMMdd-HHmm')
$tmp = Join-Path $env:TEMP ('presenca-bkp-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp -Force
$codigoFinal = 0
try {
    # 1) banco
    $remoto = '_app/dados/backup/presenca-snapshot.sqlite'
    $local = Join-Path $tmp 'presenca.sqlite'
    Escrever 'Baixando o instantaneo do banco...'
    $d = Invoke-CurlFtp -Cfg $cfg -Url (New-UrlRemota $cfg $remoto) -Extra @('-o', $local) -TimeoutSeg 3600
    if (-not $d.Ok) {
        if ($d.Codigo -in 78, 19, 9) { Escrever 'O servidor ainda nao gerou o instantaneo de hoje (ele gera sozinho no primeiro envio do dia). Tente mais tarde.' 'Yellow'; $codigoFinal = 3 }
        else { throw "Falha ao baixar o banco (curl $($d.Codigo)): $($d.Saida)" }
    } else {
        if (-not (Test-ArquivoSqlite $local)) { throw 'O arquivo baixado nao e um banco SQLite valido: a copia do servidor NAO foi apagada.' }
        $integ = Test-IntegridadeSqlite $local
        if ($integ -eq 'falhou') { throw 'A conferencia de integridade do banco falhou: a copia do servidor NAO foi apagada.' }
        $tam = (Get-Item $local).Length
        $gz = Join-Path $Destino ("presenca-{0}.sqlite.gz" -f $carimbo)
        Compress-ArquivoGzip -Origem $local -Destino $gz
        Escrever ("Banco: {0:N1} MB -> {1:N1} MB comprimido ({2}). Integridade: {3}." -f ($tam / 1MB), ((Get-Item $gz).Length / 1MB), (Split-Path -Leaf $gz), $integ) 'Green'
        # 2) so apaga a copia do servidor depois de a do PC estar pronta
        if (-not $MantemNoServidor) {
            $pai = New-UrlRemota $cfg '_app/dados/backup' -Diretorio
            $x = Invoke-CurlFtp -Cfg $cfg -Url $pai -Extra @('-Q', '+DELE presenca-snapshot.sqlite', '--list-only', '-o', 'NUL')
            if ($x.Ok) { Escrever 'Copia do servidor apagada (o disco da hospedagem volta ao normal).' } else { Escrever "Nao consegui apagar a copia do servidor (curl $($x.Codigo)): ela sera trocada no proximo dia." 'Yellow' }
        }
    }

    # 3) chaves (so guarda uma nova versao se mudaram)
    $pastaChaves = Join-Path $Destino 'chaves'
    foreach ($nome in 'remoto.key', 'pseudonimo.key') {
        $arq = Join-Path $tmp $nome
        $k = Invoke-CurlFtp -Cfg $cfg -Url (New-UrlRemota $cfg ("_app/dados/" + $nome)) -Extra @('-o', $arq)
        if (-not $k.Ok) { if ($k.Codigo -in 78, 19) { Escrever "Chave $nome ainda nao existe no servidor (normal se o recurso nunca foi usado)." } else { Escrever "Falha ao baixar $nome (curl $($k.Codigo))." 'Yellow'; $codigoFinal = 1 }; continue }
        if (-not (Test-Path $pastaChaves)) { $null = New-Item -ItemType Directory -Path $pastaChaves -Force }
        $hash = (Get-FileHash $arq -Algorithm SHA256).Hash
        $existe = Get-ChildItem $pastaChaves -Filter "$nome.*" -ErrorAction SilentlyContinue | Where-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash -eq $hash } | Select-Object -First 1
        if (-not $existe) { Copy-Item $arq (Join-Path $pastaChaves ("{0}.{1}" -f $nome, $carimbo)); Escrever "Chave $nome guardada (nova ou alterada)." 'Green' }
    }

    # 4) rotacao: nao deixa os backups crescerem sem fim
    $copias = @(Get-ChildItem $Destino -Filter 'presenca-*.sqlite.gz' -ErrorAction SilentlyContinue)
    foreach ($nome in (Get-BackupsParaApagar $copias $Diarios $Semanas)) { Remove-Item (Join-Path $Destino $nome) -Force; Escrever "Rotacao: removida a copia antiga $nome" }
    $ocupado = (Get-ChildItem $Destino -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Escrever ("Pasta de backups: {0} arquivo(s), {1:N1} MB no total." -f @(Get-ChildItem $Destino -Recurse -File).Count, ($ocupado / 1MB))
} catch {
    Escrever ("FALHOU: " + $_.Exception.Message) 'Red'
    $codigoFinal = 1
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit $codigoFinal
