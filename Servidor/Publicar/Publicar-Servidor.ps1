<#
.SYNOPSIS
  Publica o servidor (ou a atualizacao do agent) na hospedagem por FTPS, com backup do que sera trocado, conferencia
  do /health no final e reversao automatica se algo falhar. Nunca envia config.php nem a pasta _app\dados.

.EXAMPLE
  .\Publicar-Servidor.ps1                       # servidor: Entregas\Servidor\presenca-atualizacao.zip
  .\Publicar-Servidor.ps1 -Agente               # atualizacao do agent: Entregas\Atualizacao\manifest.json + pacote.zip
  .\Publicar-Servidor.ps1 -SimularApenas        # so lista o que seria enviado
  .\Publicar-Servidor.ps1 -Reverter .\Entregas\Publicacoes\20261124-153000-servidor
#>
param(
    [string]$Pacote,
    [switch]$Agente,
    [switch]$SimularApenas,
    [switch]$Sim,            # nao pergunta "PUBLICAR?" (use so quando o administrador ja autorizou)
    [string]$Reverter
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Publicacao.psm1') -Force
$raiz = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$cfg = Get-ConfigPublicacao
if (-not $cfg) { Write-Host 'A publicacao ainda nao foi configurada. Rode antes: Servidor\Publicar\Configurar-Publicacao.ps1' -ForegroundColor Red; exit 2 }

function Escrever-Log([string]$Pasta, [string]$Linha) { Add-Content -Path (Join-Path $Pasta 'publicacao.log') -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Linha) -Encoding UTF8 }

# ---------- reverter ----------
if ($Reverter) {
    Write-Host "Revertendo com a copia guardada em $Reverter ..."
    $r = Undo-Publicacao -Cfg $cfg -PastaBackup $Reverter
    Write-Host ("Revertidos: {0}. Falhas: {1}" -f $r.Revertidos, @($r.Falhas).Count)
    $s = Test-SaudeServidor $cfg.url_publica
    Write-Host ("/health: {0} (versao {1})" -f $(if ($s.Ok) { 'ok' } else { 'FALHOU' }), $s.Versao)
    exit $(if (@($r.Falhas).Count -eq 0 -and $s.Ok) { 0 } else { 1 })
}

# ---------- o que sera enviado ----------
$tmp = $null
if ($Agente) {
    $pasta = Join-Path $raiz 'Entregas\Atualizacao'
    $man = Join-Path $pasta 'manifest.json'; $zip = Join-Path $pasta 'pacote.zip'
    if (-not (Test-Path $man) -or -not (Test-Path $zip)) { throw "Faltam manifest.json e pacote.zip em $pasta (rode o atalho 5)." }
    $m = Get-Content $man -Raw -Encoding UTF8 | ConvertFrom-Json
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne ([string]$m.sha256).ToLowerInvariant()) { throw 'O pacote.zip nao confere com o sha256 do manifest.json: refaca a atualizacao assinada.' }
    $arquivos = @([pscustomobject]@{ Rel = '_app/dados/agente/pacote.zip'; Completo = $zip }, [pscustomobject]@{ Rel = '_app/dados/agente/manifest.json'; Completo = $man })
    $rotulo = "agente-$($m.versao)"
} else {
    if (-not $Pacote) { $Pacote = Join-Path $raiz 'Entregas\Servidor\presenca-atualizacao.zip' }
    if (-not (Test-Path $Pacote)) { throw "Pacote nao encontrado: $Pacote (rode o atalho 4)." }
    $tmp = Join-Path $env:TEMP ('presenca-pub-' + [guid]::NewGuid().ToString('N'))
    Expand-Archive -Path $Pacote -DestinationPath $tmp -Force
    $arquivos = @(Get-ArquivosPublicacao $tmp)
    if (-not ($arquivos | Where-Object { $_.Rel -eq 'index.php' })) { throw 'O pacote nao tem index.php: nao parece ser o pacote do servidor.' }
    $rotulo = 'servidor'
}
$total = ($arquivos | ForEach-Object { (Get-Item $_.Completo).Length } | Measure-Object -Sum).Sum
Write-Host ''
Write-Host ("Publicar {0}: {1} arquivo(s), {2:N0} KB" -f $rotulo, @($arquivos).Count, ($total / 1024)) -ForegroundColor Cyan
Write-Host ("Destino: {0}:{1}/{2} ({3})" -f $cfg.servidor, $cfg.porta, $cfg.pasta, $cfg.protocolo)
Write-Host 'Nao sera enviado: config.php, _app\dados (banco, chaves) nem arquivos .key/.sqlite.'
if ($SimularApenas) { $arquivos | ForEach-Object { Write-Host "  $($_.Rel)" }; Write-Host 'Simulacao: nada foi enviado.'; if ($tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }; exit 0 }
if (-not $Sim) { if ((Read-Host 'Digite PUBLICAR para continuar') -ne 'PUBLICAR') { Write-Host 'Cancelado.'; exit 1 } }

# ---------- confere o destino ----------
$t = Test-ConexaoPublicacao $cfg
if (-not $t.Ok) { throw ("Nao consegui conectar (curl {0}): {1}" -f $t.Codigo, $t.Erro) }
if (-not $Agente -and -not ($t.Itens -contains '_app' -and $t.Itens -contains 'index.php')) { throw 'A pasta remota nao parece ser a do painel (falta index.php/_app). Nada foi enviado. Rode o Configurar-Publicacao de novo.' }

# ---------- publica com backup ----------
$backup = Join-Path $raiz ('Entregas\Publicacoes\{0:yyyyMMdd-HHmmss}-{1}' -f (Get-Date), $rotulo)
$null = New-Item -ItemType Directory -Path $backup -Force
Escrever-Log $backup "inicio $rotulo, $(@($arquivos).Count) arquivo(s)"
$falhou = $null
try {
    $null = Publish-Arquivos -Cfg $cfg -Arquivos $arquivos -PastaBackup (Join-Path $backup 'anterior') -AoProgredir { param($n, $de, $rel) Write-Progress -Activity 'Publicando' -Status "$n de ${de}: $rel" -PercentComplete (100 * $n / $de) }
    Write-Progress -Activity 'Publicando' -Completed
} catch { $falhou = $_.Exception.Message }

# ---------- confere ----------
if (-not $falhou) {
    if ($Agente) {
        $tok = $null
        $cred = Join-Path $raiz 'Servidor\credenciais.json'
        if (Test-Path $cred) { $tok = (Get-Content $cred -Raw -Encoding UTF8 | ConvertFrom-Json).token }
        try {
            $v = Invoke-RestMethod -Uri ($cfg.url_publica.TrimEnd('/') + '/api/agente/versao') -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec 30
            if ([string]$v.versao -ne [string]$m.versao) { $falhou = "O servidor ainda informa a versao $($v.versao) em vez de $($m.versao)." } else { Write-Host ("Agent publicado: o servidor informa a versao {0}." -f $v.versao) -ForegroundColor Green }
        } catch { $falhou = 'Nao consegui conferir /api/agente/versao: ' + $_.Exception.Message }
    } else {
        $s = Test-SaudeServidor $cfg.url_publica
        if (-not $s.Ok) { $falhou = "O /health nao respondeu ok depois de publicar: $($s.Detalhe)" } else { Write-Host ("/health ok. Versao do servidor: {0}." -f $s.Versao) -ForegroundColor Green }
    }
}
if ($tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

if ($falhou) {
    Write-Host "PROBLEMA: $falhou" -ForegroundColor Red
    Escrever-Log $backup "falhou: $falhou"
    Write-Host 'Revertendo automaticamente para a versao anterior...' -ForegroundColor Yellow
    $r = Undo-Publicacao -Cfg $cfg -PastaBackup (Join-Path $backup 'anterior')
    Write-Host ("Revertidos: {0}. Falhas ao reverter: {1}" -f $r.Revertidos, @($r.Falhas).Count)
    if (-not $Agente) { $s2 = Test-SaudeServidor $cfg.url_publica; Write-Host ("/health depois de reverter: {0}" -f $(if ($s2.Ok) { 'ok' } else { 'FALHOU - verifique o servidor' })) }
    Escrever-Log $backup "revertido: $($r.Revertidos)"
    exit 1
}
Escrever-Log $backup 'concluido'
Write-Host ''
Write-Host 'Publicado com sucesso.' -ForegroundColor Green
Write-Host "Copia da versao anterior: $backup\anterior"
Write-Host "Para desfazer: .\Servidor\Publicar\Publicar-Servidor.ps1 -Reverter `"$backup\anterior`""
