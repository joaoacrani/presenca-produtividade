# Atualizador automatico do agent.
# Seguranca: o pacote so e instalado se a assinatura RSA (SHA-256) conferir com a chave publica embutida
# (chave-publica.xml). A chave privada nunca fica no servidor nem no PC do colaborador.
# O pacote so pode conter os arquivos da lista abaixo; nada alem disso e gravado.

$script:ArquivosPermitidos = @(
    'Detectar-Presenca.ps1', 'Presenca.psm1', 'Navegacao.psm1', 'Atualizador.psm1',
    'Atualizar-Agente.ps1', 'chave-publica.xml', 'versao.txt'
)
$script:TamanhoMaxArquivo = 2MB

function Get-ArquivosAtualizaveis { return $script:ArquivosPermitidos }

function Get-VersaoLocal([string]$Pasta) {
    $f = Join-Path $Pasta 'versao.txt'
    if (Test-Path $f) {
        $txt = (Get-Content -Path $f -Raw -Encoding UTF8).Trim()
        $v = $null
        if ([version]::TryParse($txt, [ref]$v)) { return $v }
    }
    return [version]'0.0.0'
}

function Write-LogAtualizador {
    param([string]$Arquivo, [string]$Mensagem)
    try {
        $pasta = Split-Path -Parent $Arquivo
        if (-not (Test-Path $pasta)) { $null = New-Item -ItemType Directory -Path $pasta -Force }
        if ((Test-Path $Arquivo) -and (Get-Item $Arquivo).Length -gt 200KB) {
            $resto = Get-Content -Path $Arquivo -Tail 300 -Encoding UTF8
            Set-Content -Path $Arquivo -Value $resto -Encoding UTF8
        }
        Add-Content -Path $Arquivo -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Mensagem) -Encoding UTF8
    } catch { }
}

# Verdadeiro so se a assinatura (base64) do conteudo confere com a chave publica (XML do .NET).
function Test-AssinaturaPacote {
    param([byte[]]$Bytes, [string]$AssinaturaBase64, [string]$ChavePublicaXml)
    try {
        if (-not $Bytes -or -not $AssinaturaBase64 -or -not $ChavePublicaXml) { return $false }
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.FromXmlString($ChavePublicaXml)
        $sig = [Convert]::FromBase64String($AssinaturaBase64.Trim())
        return [bool]$rsa.VerifyData($Bytes, 'SHA256', $sig)
    } catch { return $false }
}

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

# Le o zip da memoria e devolve @{ nome = bytes }. Rejeita qualquer entrada fora da lista permitida
# (inclui caminhos com pasta ou ".."), duplicadas, grandes demais ou diretorios.
function Read-EntradasPacote {
    param([byte[]]$Bytes)
    Add-Type -AssemblyName System.IO.Compression
    $ms = New-Object System.IO.MemoryStream (, $Bytes)
    $zip = New-Object System.IO.Compression.ZipArchive ($ms, [System.IO.Compression.ZipArchiveMode]::Read)
    $res = @{}
    try {
        foreach ($e in $zip.Entries) {
            $nome = $e.FullName
            if ($script:ArquivosPermitidos -cnotcontains $nome) { throw "arquivo nao permitido no pacote: $nome" }
            if ($res.ContainsKey($nome)) { throw "arquivo duplicado no pacote: $nome" }
            if ($e.Length -gt $script:TamanhoMaxArquivo) { throw "arquivo grande demais no pacote: $nome" }
            $in = $e.Open()
            $buf = New-Object System.IO.MemoryStream
            try { $in.CopyTo($buf) } finally { $in.Dispose() }
            $res[$nome] = $buf.ToArray()
        }
    } finally { $zip.Dispose(); $ms.Dispose() }
    return $res
}

# Esvazia a pasta de entrada SEM apaga-la: ela foi criada pelo instalador com permissao para os usuarios.
function Clear-PastaEntrada([string]$Pasta) {
    if (Test-Path $Pasta) { Get-ChildItem -Path $Pasta -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
}

# Garante que a pasta de entrada existe e que os usuarios podem gravar nela (o agent do usuario deixa o pacote ali).
function Initialize-PastaEntrada([string]$Pasta) {
    try {
        if (-not (Test-Path $Pasta)) { $null = New-Item -ItemType Directory -Path $Pasta -Force }
        & icacls.exe $Pasta /grant "*S-1-5-32-545:(OI)(CI)M" 2>&1 | Out-Null
    } catch { }
}

function Test-SintaxeArquivo([string]$Nome, [byte[]]$Bytes) {
    $texto = [System.Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xFEFF)
    if ($Nome -match '\.(ps1|psm1)$') {
        $tokens = $null; $erros = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($texto, [ref]$tokens, [ref]$erros)
        return (@($erros).Count -eq 0)
    }
    if ($Nome -like '*.xml') { try { $null = [xml]$texto; return $true } catch { return $false } }
    if ($Nome -eq 'versao.txt') { $v = $null; return [version]::TryParse($texto.Trim(), [ref]$v) }
    return $true
}

# Teste de fumaca padrao: um PowerShell novo precisa conseguir carregar os modulos instalados.
function Test-FumacaAgente([string]$Pasta) {
    try {
        $cmd = "`$ErrorActionPreference='Stop'; foreach (`$m in 'Presenca','Navegacao','Atualizador') { Import-Module (Join-Path '$Pasta' (`$m + '.psm1')) -Force }; if (-not (Get-Command Resolve-Presenca -ErrorAction Stop)) { exit 2 }; exit 0"
        $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc" `
                -Wait -PassThru -WindowStyle Hidden
        return ($p.ExitCode -eq 0)
    } catch { return $false }
}

# Instala os arquivos (ja verificados) em $Destino. Faz copia de seguranca e desfaz tudo se algo falhar.
# $Fumaca: scriptblock { param($Pasta) ... } que devolve $true se o agent instalado esta saudavel.
function Install-Atualizacao {
    param(
        [Parameter(Mandatory)] [hashtable]$Arquivos,
        [Parameter(Mandatory)] [string]$Destino,
        [scriptblock]$Fumaca = { param($p) Test-FumacaAgente $p }
    )
    foreach ($nome in $Arquivos.Keys) {
        if ($script:ArquivosPermitidos -cnotcontains $nome) { throw "arquivo nao permitido: $nome" }
        if (-not (Test-SintaxeArquivo $nome $Arquivos[$nome])) { throw "arquivo invalido no pacote: $nome" }
    }
    if (-not $Arquivos.ContainsKey('versao.txt')) { throw 'pacote sem versao.txt' }

    $bak = "$Destino.bak"; $novo = "$Destino.novo"
    foreach ($p in $bak, $novo) { if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
    $null = New-Item -ItemType Directory -Path $bak, $novo -Force
    foreach ($nome in $Arquivos.Keys) { [System.IO.File]::WriteAllBytes((Join-Path $novo $nome), $Arquivos[$nome]) }

    # copia de seguranca do que existe hoje; guarda a lista do que NAO existia para remover no rollback
    $existiam = @()
    foreach ($nome in $Arquivos.Keys) {
        $f = Join-Path $Destino $nome
        if (Test-Path $f) { Copy-Item $f (Join-Path $bak $nome) -Force; $existiam += $nome }
    }
    # ordem: o proprio atualizador e a versao por ultimo (a versao so muda se tudo deu certo)
    $ordem = @($Arquivos.Keys | Where-Object { $_ -notin 'Atualizar-Agente.ps1', 'versao.txt' }) +
             @($Arquivos.Keys | Where-Object { $_ -eq 'Atualizar-Agente.ps1' }) +
             @($Arquivos.Keys | Where-Object { $_ -eq 'versao.txt' })
    try {
        foreach ($nome in $ordem) { Copy-Item (Join-Path $novo $nome) (Join-Path $Destino $nome) -Force }
        if (-not [bool](& $Fumaca $Destino)) { throw 'teste de fumaca falhou apos a atualizacao' }
    } catch {
        $motivo = $_.Exception.Message
        foreach ($nome in $Arquivos.Keys) {
            $f = Join-Path $Destino $nome
            if ($existiam -contains $nome) { Copy-Item (Join-Path $bak $nome) $f -Force }
            elseif (Test-Path $f) { Remove-Item $f -Force }
        }
        throw "atualizacao desfeita (rollback): $motivo"
    } finally {
        if (Test-Path $novo) { Remove-Item $novo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---------- rede ----------

function Get-ManifestoRemoto {
    param([string]$Servidor, [string]$Token)
    $uri = $Servidor.TrimEnd('/') + '/api/agente/versao'
    return Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 15
}

function Get-PacoteRemoto {
    param([string]$Servidor, [string]$Token)
    $wc = New-Object System.Net.WebClient
    try {
        $wc.Headers.Add('Authorization', "Bearer $Token")
        return , $wc.DownloadData($Servidor.TrimEnd('/') + '/api/agente/pacote')
    } finally { $wc.Dispose() }
}

# Roda no contexto do USUARIO (que ja tem proxy/credenciais funcionando): baixa a atualizacao para a pasta de entrada.
# Quem instala e a tarefa SYSTEM, que so confia na assinatura, nunca na pasta de entrada.
function Save-AtualizacaoEntrada {
    param([string]$Servidor, [string]$Token, [version]$VersaoLocal, [string]$PastaEntrada)
    $m = Get-ManifestoRemoto -Servidor $Servidor -Token $Token
    $v = $null
    if (-not $m -or -not [version]::TryParse([string]$m.versao, [ref]$v) -or $v -le $VersaoLocal) { return $false }
    $arqManifesto = Join-Path $PastaEntrada 'manifest.json'
    if (Test-Path $arqManifesto) {
        try { $atual = Get-Content $arqManifesto -Raw -Encoding UTF8 | ConvertFrom-Json; if ($atual.versao -eq $m.versao -and (Test-Path (Join-Path $PastaEntrada 'pacote.zip'))) { return $false } } catch { }
    }
    $bytes = Get-PacoteRemoto -Servidor $Servidor -Token $Token
    if ((Get-Sha256Hex $bytes) -ne ([string]$m.sha256).ToLower()) { return $false }
    if (-not (Test-Path $PastaEntrada)) { $null = New-Item -ItemType Directory -Path $PastaEntrada -Force }
    [System.IO.File]::WriteAllBytes((Join-Path $PastaEntrada 'pacote.zip'), $bytes)
    $m | ConvertTo-Json | Set-Content -Path $arqManifesto -Encoding UTF8
    return $true
}

# ---------- ciclo completo (tarefa SYSTEM) ----------
# Devolve um texto de status: 'atualizado-para X', 'sem-novidade', 'rejeitada', 'falhou'.
function Invoke-CicloAtualizacao {
    param(
        [Parameter(Mandatory)] [string]$Destino,
        [Parameter(Mandatory)] [string]$PastaDados,   # ex.: C:\ProgramData\PresencaAgente
        [string]$Servidor, [string]$Token,
        [scriptblock]$Fumaca = { param($p) Test-FumacaAgente $p }
    )
    $log = Join-Path $PastaDados 'atualizador.log'
    $entrada = Join-Path $PastaDados 'entrada'
    $arqRejeitada = Join-Path $PastaDados 'versao-rejeitada.txt'
    Initialize-PastaEntrada $entrada
    $local = Get-VersaoLocal $Destino

    $manifesto = $null; $bytes = $null
    # 1) tenta baixar direto; 2) se nao der (proxy), usa o que o agent do usuario deixou na pasta de entrada
    try {
        if ($Servidor -and $Token) {
            $manifesto = Get-ManifestoRemoto -Servidor $Servidor -Token $Token
            $vr = $null
            if ($manifesto -and [version]::TryParse([string]$manifesto.versao, [ref]$vr) -and $vr -gt $local) {
                $bytes = Get-PacoteRemoto -Servidor $Servidor -Token $Token
            }
        }
    } catch { Write-LogAtualizador $log "download direto falhou: $($_.Exception.Message)"; $manifesto = $null; $bytes = $null }
    if (-not $bytes) {
        $m2 = Join-Path $entrada 'manifest.json'; $z2 = Join-Path $entrada 'pacote.zip'
        if ((Test-Path $m2) -and (Test-Path $z2)) {
            try { $manifesto = Get-Content $m2 -Raw -Encoding UTF8 | ConvertFrom-Json; $bytes = [System.IO.File]::ReadAllBytes($z2) } catch { $manifesto = $null; $bytes = $null }
        }
    }
    if (-not $manifesto -or -not $bytes) { return 'sem-novidade' }

    try {
        $versaoManifesto = [version]([string]$manifesto.versao)
        if ($versaoManifesto -le $local) {
            Clear-PastaEntrada $entrada
            return 'sem-novidade'
        }
        if ((Test-Path $arqRejeitada) -and ((Get-Content $arqRejeitada -Raw).Trim() -eq [string]$versaoManifesto)) { return 'rejeitada' }

        $chaveArq = Join-Path $Destino 'chave-publica.xml'
        if (-not (Test-Path $chaveArq)) { throw 'chave-publica.xml ausente neste PC' }
        $chave = Get-Content $chaveArq -Raw -Encoding UTF8
        if (-not (Test-AssinaturaPacote -Bytes $bytes -AssinaturaBase64 ([string]$manifesto.assinatura) -ChavePublicaXml $chave)) {
            throw "assinatura INVALIDA para a versao $versaoManifesto - pacote descartado"
        }
        $arquivos = Read-EntradasPacote -Bytes $bytes
        if (-not $arquivos.ContainsKey('versao.txt')) { throw 'pacote sem versao.txt' }
        $versaoPacote = [version]([System.Text.Encoding]::UTF8.GetString($arquivos['versao.txt']).Trim())
        if ($versaoPacote -ne $versaoManifesto) { throw 'versao do manifesto difere da versao dentro do pacote' }
        if ($versaoPacote -le $local) { throw 'pacote nao e mais novo que o instalado' }

        Install-Atualizacao -Arquivos $arquivos -Destino $Destino -Fumaca $Fumaca
        Write-LogAtualizador $log "OK: $local -> $versaoPacote"
        Clear-PastaEntrada $entrada
        return "atualizado-para $versaoPacote"
    } catch {
        Write-LogAtualizador $log "FALHOU: $($_.Exception.Message)"
        try { Set-Content -Path $arqRejeitada -Value ([string]$manifesto.versao) -Encoding ASCII } catch { }
        Clear-PastaEntrada $entrada
        return 'rejeitada'
    }
}

# ---------- tarefa agendada (SYSTEM) ----------

function New-XmlTarefaAtualizador {
    param([Parameter(Mandatory)] [string]$Script, [int]$IntervaloHoras = 6)
    $esc = { param($s) [Security.SecurityElement]::Escape($s) }
    $argumentos = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`""
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Atualizador do agente de presenca: instala somente pacotes com assinatura valida.</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT5M</Delay></BootTrigger>
    <TimeTrigger>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition><Interval>PT${IntervaloHoras}H</Interval></Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$(& $esc $argumentos)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

# ---------- batimento dos servidores (tarefa SYSTEM, a cada 5 min, sem depender de usuario logado) ----------
function New-XmlTarefaBatimento {
    param([Parameter(Mandatory)] [string]$Script, [int]$IntervaloMinutos = 5)
    $esc = { param($s) [Security.SecurityElement]::Escape($s) }
    $argumentos = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`" -Batimento"
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Batimento do servidor: avisa o painel que a maquina esta no ar (nao depende de usuario logado).</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT1M</Delay></BootTrigger>
    <TimeTrigger>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition><Interval>PT${IntervaloMinutos}M</Interval></Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>LeastPrivilege</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$(& $esc $argumentos)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

# Cria (ou atualiza) a tarefa de batimento. Chamada pelo atualizador SYSTEM quando o painel diz que esta maquina e servidor.
function Register-TarefaBatimento {
    param([Parameter(Mandatory)] [string]$Destino, [string]$Nome = 'PresencaAgenteBatimento')
    $xml = New-XmlTarefaBatimento -Script (Join-Path $Destino 'Atualizar-Agente.ps1')
    Register-ScheduledTask -TaskName $Nome -Xml $xml -Force | Out-Null
}

# Mantem a tarefa de acordo com a politica do painel: $true cria (se nao existe, ou se acabou de atualizar), $false remove, $null nao mexe.
# Devolve: criada | removida | mantida | sem-decisao
function Sync-TarefaBatimento {
    param([Parameter(Mandatory)] [string]$Destino, $Politica, [bool]$Atualizou = $false, [string]$Nome = 'PresencaAgenteBatimento')
    if ($null -eq $Politica) { return 'sem-decisao' }
    $existe = [bool](Get-ScheduledTask -TaskName $Nome -ErrorAction SilentlyContinue)
    if ($Politica) {
        if (-not $existe -or $Atualizou) {
            Register-TarefaBatimento -Destino $Destino -Nome $Nome
            Start-ScheduledTask -TaskName $Nome -ErrorAction SilentlyContinue
            return 'criada'
        }
        return 'mantida'
    }
    if ($existe) {
        Stop-ScheduledTask -TaskName $Nome -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $Nome -Confirm:$false -ErrorAction SilentlyContinue
        return 'removida'
    }
    return 'mantida'
}

# ---------- instalacao e desinstalacao de software (tarefa SYSTEM "PresencaAgenteSoftware", a cada 15 min) ----------
# O painel (ou uma politica automatica) enfileira uma tarefa por maquina. O agent so executa se (1) a assinatura RSA do manifesto confere com a
# chave publica embutida (chave-publica.xml) e (2) o arquivo baixado tem o mesmo SHA-256 e tamanho do manifesto. Sem as duas coisas nada e executado.
# Pacote zip: extraido numa pasta so de SYSTEM/administradores, com nomes validados (sem "..", sem caminho absoluto, sem nome reservado) e limites
# de quantidade e tamanho. Gatilho: se o arquivo ja existe, a instalacao e ignorada. Desinstalacao: por codigo MSI, por nome em Programas e
# Recursos ou por script do pacote. Exige o token proprio da maquina (ppm_). Desligavel em agente.json: executar_software = false.

$script:SoftwareTipos = @('msi', 'exe', 'ps1', 'cmd', 'vbs', 'zip')
$script:SoftwareTiposExec = @('msi', 'exe', 'ps1', 'cmd', 'vbs')
$script:SoftwareCodigosOk = @(0, 3010, 1641)   # 3010 e 1641 = ok, mas pede reinicio
$script:SoftwareTempoMaxSeg = 3600
$script:SoftwareZipMaxArquivos = 2000
$script:SoftwareZipMaxBytes = 2147483648

# Tipo executavel pela extensao (bat conta como cmd); '' se nao for executavel.
function Get-TipoSoftware {
    param([string]$Nome)
    $e = [IO.Path]::GetExtension([string]$Nome).TrimStart('.').ToLowerInvariant()
    if ($e -ceq 'bat') { return 'cmd' }
    if ($script:SoftwareTiposExec -ccontains $e) { return $e }
    return ''
}

# Um trecho de caminho dentro do zip (mesma regra do servidor).
function Test-SegmentoSoftware {
    param([string]$S)
    if (-not $S -or $S.Length -gt 100) { return $false }
    if ($S -notmatch '^[A-Za-z0-9._ ()\[\]-]+$') { return $false }
    if ($S -eq '.' -or $S -eq '..' -or $S -match '[. ]$') { return $false }
    return ($S -notmatch '^(?i)(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)')
}

# Caminho relativo com "/" (ate 8 niveis, cada trecho valido).
function Test-CaminhoRelSoftware {
    param([string]$P)
    if (-not $P -or $P.Length -gt 240) { return $false }
    $partes = $P.Split('/')
    if ($partes.Count -gt 8) { return $false }
    foreach ($s in $partes) { if (-not (Test-SegmentoSoftware $s)) { return $false } }
    return $true
}

# Gatilho: caminho absoluto local, com variaveis [programfiles] etc. (mesma regra do servidor).
function Test-GatilhoSoftware {
    param([string]$G)
    if (-not $G -or $G.Length -gt 260) { return $false }
    if ($G -match '[<>"|?*\x00-\x1f]' -or $G.Contains('..')) { return $false }
    return ($G -match '^(?i)(\[(programfiles|programfiles\(x86\)|programfiles\(x64\)|programdata|windir|system32|systemdrive)\]|[A-Za-z]:)\\[^\\]')
}

# Troca as variaveis do gatilho pelos caminhos desta maquina. [programfiles] = Program Files nativo (64 bits em Windows 64 bits).
function Expand-GatilhoSoftware {
    param([string]$G)
    $nativo = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $x86 = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { $env:ProgramFiles }
    $mapa = @{ 'programfiles' = $nativo; 'programfiles(x64)' = $nativo; 'programfiles(x86)' = $x86; 'programdata' = $env:ProgramData
               'windir' = $env:SystemRoot; 'system32' = (Join-Path $env:SystemRoot 'System32'); 'systemdrive' = $env:SystemDrive }
    $r = [regex]::Replace($G, '\[(programfiles\(x86\)|programfiles\(x64\)|programfiles|programdata|windir|system32|systemdrive)\]',
        { param($m) $mapa[$m.Groups[1].Value.ToLowerInvariant()] }, 'IgnoreCase')
    return $r
}

# $true se o arquivo gatilho ja existe nesta maquina.
function Test-GatilhoExiste {
    param([string]$G)
    if (-not $G) { return $false }
    $c = Expand-GatilhoSoftware -G $G
    if ($c -notmatch '^[A-Za-z]:\\[^\\]') { return $false }
    return (Test-Path -LiteralPath $c -PathType Leaf)
}

# $true se o manifesto (ja com a assinatura conferida) tem todos os campos no formato esperado.
function Test-ManifestoSoftware {
    param($M)
    try {
        if (-not $M) { return $false }
        if ([int]$M.v -ne 2) { return $false }
        if ([string]$M.pid -cnotmatch '^[0-9a-f]{32}$') { return $false }
        if ($script:SoftwareTipos -cnotcontains [string]$M.tipo) { return $false }
        if ([string]$M.sha256 -cnotmatch '^[0-9a-f]{64}$') { return $false }
        if ([long]$M.tamanho -lt 1) { return $false }
        if ([string]$M.arquivo -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._ -]{0,100}$') { return $false }
        if ($null -eq $M.args -or ([string]$M.args).Length -gt 1000) { return $false }
        if ([string]$M.tipo -ceq 'zip') {
            if (-not ([string]$M.arquivo).EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) { return $false }
            if (-not (Test-CaminhoRelSoftware ([string]$M.executavel)) -or -not (Get-TipoSoftware ([string]$M.executavel))) { return $false }
        } else {
            if ((Get-TipoSoftware ([string]$M.arquivo)) -cne [string]$M.tipo) { return $false }
            if ($M.executavel) { return $false }
        }
        if ($M.gatilho -and -not (Test-GatilhoSoftware ([string]$M.gatilho))) { return $false }
        $d = $M.desinstalar
        if ($d) {
            if ($d.args -and ([string]$d.args).Length -gt 500) { return $false }
            switch ([string]$d.modo) {
                'msi' { if ([string]$d.codigo -cnotmatch '^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') { return $false } }
                'nome' { if (-not ([string]$d.software).Trim() -or ([string]$d.software).Length -gt 120) { return $false } }
                'script' {
                    if ([string]$M.tipo -ceq 'zip') {
                        if (-not (Test-CaminhoRelSoftware ([string]$d.arquivo)) -or @('ps1', 'cmd', 'vbs') -cnotcontains (Get-TipoSoftware ([string]$d.arquivo))) { return $false }
                    } elseif (@('ps1', 'cmd', 'vbs') -cnotcontains [string]$M.tipo) { return $false }
                }
                default { return $false }
            }
        }
        return $true
    } catch { return $false }
}

# Executavel e argumentos para cada tipo. $Caminho = arquivo ja baixado/extraido e conferido. -Tipo e -Argumentos substituem os do manifesto
# (usado para o arquivo de dentro do zip e para a desinstalacao).
function Get-ComandoSoftware {
    param([Parameter(Mandatory)] $M, [Parameter(Mandatory)] [string]$Caminho, [string]$Tipo = '', $Argumentos = $null)
    $sys = Join-Path $env:SystemRoot 'System32'
    $args1 = if ($null -ne $Argumentos) { [string]$Argumentos } else { [string]$M.args }
    $t = if ($Tipo) { $Tipo } else { [string]$M.tipo }
    switch ($t) {
        'msi' { return @{ Exe = (Join-Path $sys 'msiexec.exe'); Args = "/i `"$Caminho`" $args1".TrimEnd() } }
        'exe' { return @{ Exe = $Caminho; Args = $args1 } }
        'ps1' { return @{ Exe = (Join-Path $sys 'WindowsPowerShell\v1.0\powershell.exe'); Args = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Caminho`" $args1".TrimEnd() } }
        'cmd' {
            $interno = "`"$Caminho`""
            if ($args1) { $interno += " $args1" }
            return @{ Exe = (Join-Path $sys 'cmd.exe'); Args = "/d /c `"$interno`"" }
        }
        'vbs' { return @{ Exe = (Join-Path $sys 'cscript.exe'); Args = "//nologo `"$Caminho`" $args1".TrimEnd() } }
        default { throw "tipo de pacote nao suportado: $t" }
    }
}

# Separa "caminho\programa.exe args" (com ou sem aspas) em @{ Exe; Args }. Usado nas desinstalacoes lidas do registro.
function Split-ComandoTexto {
    param([string]$Texto)
    $t = ([string]$Texto).Trim()
    if ($t -match '^"([^"]+)"\s*(.*)$') { return @{ Exe = $Matches[1]; Args = $Matches[2] } }
    if ($t -match '^(?i)(.+?\.exe)\s*(.*)$') { return @{ Exe = $Matches[1]; Args = $Matches[2] } }
    throw 'nao foi possivel entender o comando de desinstalacao do programa'
}

# Programa instalado (Programas e Recursos) pelo nome exato (sem diferenciar maiusculas); com * no nome vale como curinga.
function Get-ProgramaInstalado {
    param([Parameter(Mandatory)] [string]$Nome)
    $chaves = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $n = $Nome.Trim()
    $achados = @(Get-ItemProperty -Path $chaves -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -and $(if ($n.Contains('*')) { ([string]$_.DisplayName).Trim() -like $n } else { ([string]$_.DisplayName).Trim() -ieq $n }) })
    return $achados
}

# Comando de desinstalacao de um programa lido do registro. MSI: msiexec /x {GUID}. Senao: QuietUninstallString, ou UninstallString quando o
# administrador informou os parametros silenciosos. Sem forma silenciosa nao executa (ficaria esperando alguem clicar).
function Get-ComandoDesinstalarPrograma {
    param([Parameter(Mandatory)] $Programa, [string]$ArgsExtra = '')
    $us = [string]$Programa.UninstallString; $qus = [string]$Programa.QuietUninstallString
    $sys = Join-Path $env:SystemRoot 'System32'
    if ($us -match '(?i)msiexec' -and $us -match '(\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\})') {
        $a = if ($ArgsExtra) { $ArgsExtra } else { '/qn /norestart' }
        return @{ Exe = (Join-Path $sys 'msiexec.exe'); Args = "/x $($Matches[1]) $a".TrimEnd() }
    }
    if ($qus) {
        $c = Split-ComandoTexto $qus
        if ($ArgsExtra) { $c.Args = ($c.Args + ' ' + $ArgsExtra).Trim() }
    } elseif ($us -and $ArgsExtra) {
        $c = Split-ComandoTexto $us
        $c.Args = ($c.Args + ' ' + $ArgsExtra).Trim()
    } else { throw 'este programa nao tem desinstalacao silenciosa; informe os parametros silenciosos do fabricante na desinstalacao do pacote' }
    if ($c.Exe -notmatch '^[A-Za-z]:\\' -or -not (Test-Path -LiteralPath $c.Exe -PathType Leaf)) { throw "o desinstalador do programa nao foi encontrado ($($c.Exe))" }
    return $c
}

# Roda o processo, espera ate $TimeoutSeg e devolve @{ Codigo; Saida; TempoEsgotado }. Saida = fim da saida padrao + erro (ate 3500 caracteres).
# Roda com prioridade baixa para nao atrapalhar quem esta trabalhando.
function Invoke-ProcessoSoftware {
    param([Parameter(Mandatory)] [string]$Exe, [string]$Argumentos = '', [Parameter(Mandatory)] [string]$Pasta, [int]$TimeoutSeg = 3600)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe; $psi.Arguments = $Argumentos; $psi.WorkingDirectory = $Pasta
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $esgotou = $false
    try {
        [void]$p.Start()
        try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
        $to = $p.StandardOutput.ReadToEndAsync(); $te = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSeg * 1000)) { $esgotou = $true; try { $p.Kill() } catch { } }
        $saida = ''
        foreach ($t in $to, $te) { if ($t.Wait(5000)) { $saida += $t.Result } }
        $codigo = if ($esgotou) { -1 } else { $p.ExitCode }
        $saida = $saida.Trim()
        if ($esgotou) { $saida = "tempo esgotado (${TimeoutSeg}s); processo encerrado. " + $saida }
        if ($saida.Length -gt 3500) { $saida = '...' + $saida.Substring($saida.Length - 3500) }
        return @{ Codigo = $codigo; Saida = $saida; TempoEsgotado = $esgotou }
    } finally { $p.Dispose() }
}

# Pasta de trabalho so para SYSTEM e administradores (um usuario comum nao pode trocar o arquivo entre a conferencia e a execucao).
function New-PastaSoftware {
    param([Parameter(Mandatory)] [string]$Base)
    $d = Join-Path $Base ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $d -Force
    $eu = '*' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + ':(OI)(CI)F'   # quem esta rodando (SYSTEM no uso real)
    & icacls.exe $d /inheritance:r /grant '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' $eu 2>&1 | Out-Null
    return $d
}

# Extrai o zip com seguranca: valida TODOS os nomes antes de gravar qualquer coisa, impede sair da pasta de destino (zip-slip), limita a
# quantidade de arquivos e o tamanho realmente gravado (zip bomba). Devolve a lista de arquivos extraidos (caminhos relativos com "/").
function Expand-ZipSeguro {
    param([Parameter(Mandatory)] [string]$Zip, [Parameter(Mandatory)] [string]$Destino)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $raiz = [IO.Path]::GetFullPath($Destino).TrimEnd('\') + '\'
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        if ($z.Entries.Count -lt 1 -or $z.Entries.Count -gt $script:SoftwareZipMaxArquivos) { throw "o zip tem arquivos demais (maximo $($script:SoftwareZipMaxArquivos))" }
        $lista = New-Object System.Collections.Generic.List[object]
        foreach ($e in $z.Entries) {
            $n = $e.FullName.TrimEnd('/')
            if (-not $n -or -not (Test-CaminhoRelSoftware $n)) { throw "o zip tem um nome de arquivo nao permitido: $n" }
            $alvo = [IO.Path]::GetFullPath((Join-Path $raiz ($n -replace '/', '\')))
            if (-not $alvo.StartsWith($raiz, [StringComparison]::OrdinalIgnoreCase)) { throw "o zip tenta gravar fora da pasta de trabalho: $n" }
            $lista.Add(@{ E = $e; Nome = $n; Alvo = $alvo; Pasta = $e.FullName.EndsWith('/') })
        }
        $total = [long]0; $extraidos = New-Object System.Collections.Generic.List[string]
        foreach ($i in $lista) {
            if ($i.Pasta) { $null = New-Item -ItemType Directory -Path $i.Alvo -Force; continue }
            $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($i.Alvo)) -Force
            $ent = $i.E.Open(); $sai = [IO.File]::Create($i.Alvo)
            try {
                $buf = New-Object byte[] 81920
                while (($lido = $ent.Read($buf, 0, $buf.Length)) -gt 0) {
                    $total += $lido
                    if ($total -gt $script:SoftwareZipMaxBytes) { throw 'o zip descompactado passa de 2 GB; nada foi executado' }
                    $sai.Write($buf, 0, $lido)
                }
            } finally { $sai.Dispose(); $ent.Dispose() }
            $extraidos.Add($i.Nome)
        }
        return , @($extraidos)
    } finally { $z.Dispose() }
}

# Reserva a tarefa ('executando') ou informa o resultado ('ok'/'falhou'). Devolve $true se o servidor aceitou.
function Send-ResultadoSoftware {
    param([Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token, [Parameter(Mandatory)] [int]$Id,
          [Parameter(Mandatory)] [string]$Estado, $Codigo = $null, [string]$Saida = '')
    $corpo = @{ host = $env:COMPUTERNAME; id = $Id; estado = $Estado; codigo = $Codigo; saida = $Saida } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Uri (($Servidor.TrimEnd('/')) + '/api/agente/tarefas/resultado') -Method Post -Headers @{ Authorization = "Bearer $Token" } `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($corpo)) -TimeoutSec 30 | Out-Null
        return $true
    } catch { return $false }
}

function Receive-ArquivoSoftware {
    param([Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token, [Parameter(Mandatory)] [string]$IdPacote, [Parameter(Mandatory)] [string]$Destino)
    $uri = ($Servidor.TrimEnd('/')) + '/api/agente/software?pid=' + [uri]::EscapeDataString($IdPacote) + '&host=' + [uri]::EscapeDataString($env:COMPUTERNAME)
    $wc = New-Object System.Net.WebClient
    try { $wc.Headers.Add('Authorization', "Bearer $Token"); $wc.DownloadFile($uri, $Destino) } finally { $wc.Dispose() }
}

# Baixa o pacote para a pasta de trabalho e confere tamanho e SHA-256 do manifesto. Se for zip, extrai e devolve a pasta com o conteudo.
# Devolve @{ Arquivo; Conteudo } (Conteudo so no zip).
function Get-PacoteSoftware {
    param([Parameter(Mandatory)] $M, [Parameter(Mandatory)] [string]$Dir, [Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token)
    $arq = Join-Path $Dir ([string]$M.arquivo)
    Receive-ArquivoSoftware -Servidor $Servidor -Token $Token -IdPacote ([string]$M.pid) -Destino $arq
    if ((Get-Item $arq).Length -ne [long]$M.tamanho) { throw 'o arquivo baixado tem tamanho diferente do assinado; nada foi executado' }
    if ((Get-FileHash -Path $arq -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$M.sha256) { throw 'o SHA-256 do arquivo baixado difere do assinado; nada foi executado' }
    if ([string]$M.tipo -cne 'zip') { return @{ Arquivo = $arq; Conteudo = $null } }
    $conteudo = Join-Path $Dir 'conteudo'
    $null = New-Item -ItemType Directory -Path $conteudo -Force
    $null = Expand-ZipSeguro -Zip $arq -Destino $conteudo
    return @{ Arquivo = $arq; Conteudo = $conteudo }
}

# Caminho de um arquivo de dentro do zip ja extraido; confere que existe e que esta dentro da pasta de conteudo.
function Resolve-ArquivoNoZip {
    param([Parameter(Mandatory)] [string]$Conteudo, [Parameter(Mandatory)] [string]$Relativo)
    $raiz = [IO.Path]::GetFullPath($Conteudo).TrimEnd('\') + '\'
    $c = [IO.Path]::GetFullPath((Join-Path $raiz ($Relativo -replace '/', '\')))
    if (-not $c.StartsWith($raiz, [StringComparison]::OrdinalIgnoreCase)) { throw "arquivo fora do pacote: $Relativo" }
    if (-not (Test-Path -LiteralPath $c -PathType Leaf)) { throw "o arquivo '$Relativo' nao existe dentro do zip" }
    return $c
}

# Executa UMA tarefa ja validada (assinatura e manifesto conferidos). Devolve @{ Estado = 'ok'|'falhou'; Codigo; Saida }.
function Invoke-AcaoSoftware {
    param([Parameter(Mandatory)] $M, [Parameter(Mandatory)] [string]$Acao, [Parameter(Mandatory)] [string]$Dir,
          [Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token)
    $tempo = $script:SoftwareTempoMaxSeg
    if ($Acao -ceq 'instalar') {
        if ($M.gatilho -and (Test-GatilhoExiste ([string]$M.gatilho))) {
            return @{ Estado = 'ok'; Codigo = 0; Saida = "ignorada: o arquivo gatilho ja existe ($(Expand-GatilhoSoftware ([string]$M.gatilho))); nada foi instalado" }
        }
        $p = Get-PacoteSoftware -M $M -Dir $Dir -Servidor $Servidor -Token $Token
        if ([string]$M.tipo -ceq 'zip') {
            $arq = Resolve-ArquivoNoZip -Conteudo $p.Conteudo -Relativo ([string]$M.executavel)
            $c = Get-ComandoSoftware -M $M -Caminho $arq -Tipo (Get-TipoSoftware ([string]$M.executavel))
            $pasta = [IO.Path]::GetDirectoryName($arq)
        } else {
            $c = Get-ComandoSoftware -M $M -Caminho $p.Arquivo
            $pasta = $Dir
        }
        $res = Invoke-ProcessoSoftware -Exe $c.Exe -Argumentos $c.Args -Pasta $pasta -TimeoutSeg $tempo
        $ok = ($script:SoftwareCodigosOk -contains [int]$res.Codigo)
        $saida = $res.Saida
        if ($ok -and [int]$res.Codigo -ne 0) { $saida = ("codigo {0}: concluido, reinicio pendente. " -f $res.Codigo) + $saida }
        # Gatilho informado e o instalador terminou sem erro: o arquivo precisa ter aparecido, senao a instalacao nao valeu.
        if ($ok -and [int]$res.Codigo -eq 0 -and $M.gatilho -and -not (Test-GatilhoExiste ([string]$M.gatilho))) {
            $ok = $false
            $saida = "o instalador terminou sem erro, mas o arquivo gatilho nao apareceu ($(Expand-GatilhoSoftware ([string]$M.gatilho))). " + $saida
        }
        return @{ Estado = $(if ($ok) { 'ok' } else { 'falhou' }); Codigo = $res.Codigo; Saida = $saida }
    }
    if ($Acao -cne 'desinstalar' -or -not $M.desinstalar) { throw 'este pacote nao tem desinstalacao definida' }
    $d = $M.desinstalar
    $extra = if ($d.args) { [string]$d.args } else { '' }
    if ($M.gatilho -and -not (Test-GatilhoExiste ([string]$M.gatilho))) {
        return @{ Estado = 'ok'; Codigo = 0; Saida = 'ignorada: o arquivo gatilho nao existe; o programa ja nao esta instalado' }
    }
    switch ([string]$d.modo) {
        'msi' {
            $a = if ($extra) { $extra } else { '/qn /norestart' }
            $c = @{ Exe = (Join-Path (Join-Path $env:SystemRoot 'System32') 'msiexec.exe'); Args = "/x $([string]$d.codigo) $a".TrimEnd() }
            $pasta = $Dir
        }
        'nome' {
            $achados = @(Get-ProgramaInstalado -Nome ([string]$d.software))
            if ($achados.Count -eq 0) { return @{ Estado = 'ok'; Codigo = 0; Saida = "ignorada: '$([string]$d.software)' nao esta instalado" } }
            if ($achados.Count -gt 1) { throw "o nome '$([string]$d.software)' corresponde a $($achados.Count) programas instalados; use o nome completo ou o codigo MSI" }
            $c = Get-ComandoDesinstalarPrograma -Programa $achados[0] -ArgsExtra $extra
            $pasta = $Dir
        }
        'script' {
            $p = Get-PacoteSoftware -M $M -Dir $Dir -Servidor $Servidor -Token $Token
            if ([string]$M.tipo -ceq 'zip') {
                $arq = Resolve-ArquivoNoZip -Conteudo $p.Conteudo -Relativo ([string]$d.arquivo)
                $c = Get-ComandoSoftware -M $M -Caminho $arq -Tipo (Get-TipoSoftware ([string]$d.arquivo)) -Argumentos $extra
                $pasta = [IO.Path]::GetDirectoryName($arq)
            } else {
                $c = Get-ComandoSoftware -M $M -Caminho $p.Arquivo -Argumentos $extra
                $pasta = $Dir
            }
        }
        default { throw 'modo de desinstalacao invalido' }
    }
    $res = Invoke-ProcessoSoftware -Exe $c.Exe -Argumentos $c.Args -Pasta $pasta -TimeoutSeg $tempo
    $ok = ($script:SoftwareCodigosOk -contains [int]$res.Codigo)
    $saida = $res.Saida
    if ($ok -and [int]$res.Codigo -ne 0) { $saida = ("codigo {0}: concluido, reinicio pendente. " -f $res.Codigo) + $saida }
    if ($ok -and $M.gatilho -and (Test-GatilhoExiste ([string]$M.gatilho))) { $saida = 'atencao: o arquivo gatilho ainda existe depois da desinstalacao. ' + $saida }
    return @{ Estado = $(if ($ok) { 'ok' } else { 'falhou' }); Codigo = $res.Codigo; Saida = $saida }
}

# Executa as tarefas de software desta maquina. Devolve: sem-token | sem-servidor | nada | executadas-N
function Invoke-TarefasSoftware {
    param(
        [Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token, [Parameter(Mandatory)] [string]$ChavePublicaXml,
        [Parameter(Mandatory)] [string]$PastaBase, [string]$ArquivoLog = ''
    )
    if ($Token -notlike 'ppm_*') { return 'sem-token' }
    try {
        $r = Invoke-RestMethod -Uri (($Servidor.TrimEnd('/')) + '/api/agente/tarefas?host=' + [uri]::EscapeDataString($env:COMPUTERNAME)) `
                -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 20
    } catch { return 'sem-servidor' }
    $lista = @($r.tarefas)
    if ($lista.Count -eq 0) { return 'nada' }
    $feitas = 0
    foreach ($t in $lista) {
        $id = [int]$t.id
        if (-not (Send-ResultadoSoftware -Servidor $Servidor -Token $Token -Id $id -Estado 'executando')) { continue }   # outra rodada ja pegou
        $dir = $null
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$t.manifesto)
            if (-not (Test-AssinaturaPacote -Bytes $bytes -AssinaturaBase64 ([string]$t.assinatura) -ChavePublicaXml $ChavePublicaXml)) {
                throw 'a assinatura do pacote nao confere com a chave publica deste agent; nada foi executado'
            }
            $m = [string]$t.manifesto | ConvertFrom-Json
            if (-not (Test-ManifestoSoftware $m) -or ([string]$m.pid -ne [string]$t.pid)) { throw 'manifesto invalido; nada foi executado' }
            $acao = if ($t.acao) { [string]$t.acao } else { 'instalar' }
            if ($acao -cnotin 'instalar', 'desinstalar') { throw 'acao desconhecida; nada foi executado' }
            $dir = New-PastaSoftware -Base $PastaBase
            if ($ArquivoLog) { Write-LogAtualizador $ArquivoLog ("software: {0} '{1}' (tarefa {2})" -f $acao, $m.nome, $id) }
            $res = Invoke-AcaoSoftware -M $m -Acao $acao -Dir $dir -Servidor $Servidor -Token $Token
            [void](Send-ResultadoSoftware -Servidor $Servidor -Token $Token -Id $id -Estado $res.Estado -Codigo $res.Codigo -Saida $res.Saida)
            if ($ArquivoLog) { Write-LogAtualizador $ArquivoLog ("software: tarefa {0} terminou ({1}, codigo {2})" -f $id, $res.Estado, $res.Codigo) }
        } catch {
            [void](Send-ResultadoSoftware -Servidor $Servidor -Token $Token -Id $id -Estado 'falhou' -Codigo $null -Saida ([string]$_.Exception.Message))
            if ($ArquivoLog) { Write-LogAtualizador $ArquivoLog ("software: tarefa {0} falhou: {1}" -f $id, $_.Exception.Message) }
        } finally {
            if ($dir -and (Test-Path $dir)) { Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $feitas++
    }
    return "executadas-$feitas"
}

function New-XmlTarefaSoftware {
    param([Parameter(Mandatory)] [string]$Script, [int]$IntervaloMinutos = 15)
    $esc = { param($s) [Security.SecurityElement]::Escape($s) }
    $argumentos = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`" -Software"
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Instalacao de software pedida pelo painel (so executa pacotes assinados pela empresa).</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT3M</Delay></BootTrigger>
    <TimeTrigger>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition><Interval>PT${IntervaloMinutos}M</Interval></Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT3H</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$(& $esc $argumentos)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

# Cria a tarefa (se nao existe ou se acabou de atualizar) ou remove ($Ligada = $false). Devolve: criada | removida | mantida
function Sync-TarefaSoftware {
    param([Parameter(Mandatory)] [string]$Destino, [bool]$Ligada = $true, [bool]$Atualizou = $false, [string]$Nome = 'PresencaAgenteSoftware')
    $existe = [bool](Get-ScheduledTask -TaskName $Nome -ErrorAction SilentlyContinue)
    if ($Ligada) {
        if (-not $existe -or $Atualizou) {
            Register-ScheduledTask -TaskName $Nome -Xml (New-XmlTarefaSoftware -Script (Join-Path $Destino 'Atualizar-Agente.ps1')) -Force | Out-Null
            return 'criada'
        }
        return 'mantida'
    }
    if ($existe) {
        Stop-ScheduledTask -TaskName $Nome -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $Nome -Confirm:$false -ErrorAction SilentlyContinue
        return 'removida'
    }
    return 'mantida'
}

# ---------- coletor de programas em uso (tarefa do usuario, criada pelo SYSTEM) ----------
function Register-TarefaFoco {
    param([Parameter(Mandatory)] [string]$Destino, [string]$Nome = 'PresencaAgenteFoco')
    $script = Join-Path $Destino 'Detectar-Presenca.ps1'
    $argumentos = "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -Foco"
    $principal = '<Principal id="Author"><GroupId>S-1-5-32-545</GroupId><RunLevel>LeastPrivilege</RunLevel></Principal>'
    $xml = New-XmlTarefaFoco -Comando (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argumentos $argumentos -PrincipalXml $principal
    Register-ScheduledTask -TaskName $Nome -Xml $xml -Force | Out-Null
}

# ---------- "Programas e Recursos" / Aplicativos instalados do Windows ----------
# Entrada propria (usada por quem instalou pelo script/zip). Quem instala pelo .exe (Inno Setup) tem a entrada do
# Inno (<AppId>_is1); nesse caso a nossa e removida para nao aparecer duas vezes.
$script:ChaveDesinstalacao = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PresencaAgentePP'
$script:ChaveInno = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PresencaAgentePP_is1'

# Comando que o Windows executa ao clicar em Desinstalar: pede permissao de administrador e roda
# "Atualizar-Agente.ps1 -Desinstalar". Usa -EncodedCommand para nao depender de aspas.
function Get-ComandoDesinstalar([string]$Destino) {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path $Destino 'Atualizar-Agente.ps1'
    $interno = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Desinstalar"
    $cmd = "Start-Process -FilePath '$ps' -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '" + ($interno -replace "'", "''") + "'"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    return @{
        Interativo = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc"
        Silencioso = "`"$ps`" $interno"
    }
}

# Cria/atualiza a entrada (ou so atualiza a versao da entrada do Inno). Devolve 'inno' ou 'registrado'.
function Register-DesinstalacaoWindows {
    param(
        [Parameter(Mandatory)] [string]$Destino,
        [Parameter(Mandatory)] [string]$Versao,
        [string]$Chave = $script:ChaveDesinstalacao,
        [string]$ChaveInno = $script:ChaveInno
    )
    if (Test-Path $ChaveInno) {
        Remove-Item $Chave -Recurse -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $ChaveInno -Name 'DisplayVersion' -Value $Versao -ErrorAction SilentlyContinue
        return 'inno'
    }
    $c = Get-ComandoDesinstalar $Destino
    $null = New-Item -Path $Chave -Force
    $valores = [ordered]@{
        DisplayName          = 'Agente de Presenca'
        DisplayVersion       = $Versao
        Publisher            = 'Presenca e Produtividade'
        InstallLocation      = $Destino
        UninstallString      = $c.Interativo
        QuietUninstallString = $c.Silencioso
    }
    foreach ($k in $valores.Keys) { Set-ItemProperty -Path $Chave -Name $k -Value $valores[$k] -Type String }
    foreach ($k in 'NoModify', 'NoRepair') { Set-ItemProperty -Path $Chave -Name $k -Value 1 -Type DWord }
    return 'registrado'
}

function Remove-DesinstalacaoWindows([string]$Chave = $script:ChaveDesinstalacao) {
    if (Test-Path $Chave) { Remove-Item $Chave -Recurse -Force -ErrorAction SilentlyContinue }
}

# Remove o agent deste PC: tarefas agendadas, pastas e a entrada do Windows. Os dados locais de cada usuario
# (%LOCALAPPDATA%\PresencaPP) sao mantidos. Falhas pontuais sao ignoradas (ex.: o desinstalador do Inno em uso).
function Remove-AgenteInstalado {
    param(
        [Parameter(Mandatory)] [string]$Destino,
        [Parameter(Mandatory)] [string]$PastaDados,
        [string[]]$Tarefas = @('PresencaAgente', 'PresencaAgenteUpdate', 'PresencaAgenteFoco', 'PresencaAgenteBatimento', 'PresencaAgenteSoftware'),
        [string]$Chave = $script:ChaveDesinstalacao
    )
    foreach ($t in $Tarefas) { Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
    foreach ($p in $Destino, "$Destino.bak", "$Destino.novo", $PastaDados) {
        if (Test-Path $p) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Remove-DesinstalacaoWindows -Chave $Chave
}

Export-ModuleMember -Function *
