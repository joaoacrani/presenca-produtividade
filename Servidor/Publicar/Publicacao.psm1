# Publicacao do servidor na hospedagem por FTP com TLS (FTPS), sem a senha passar pelo chat nem ficar em arquivo do projeto.
# - A senha fica so em %LOCALAPPDATA%\PresencaPP\publicacao.json, criptografada com a conta do Windows de quem configurou (DPAPI).
# - Nunca envia config.php, a pasta _app\dados (banco e chaves) nem arquivos .key/.sqlite.
# - Antes de trocar cada arquivo, guarda a copia que esta no servidor (backup) e permite reverter.
# ASCII apenas: o PowerShell 5.1 le .psm1 sem BOM como ANSI.

$script:PastaCfg = Join-Path $env:LOCALAPPDATA 'PresencaPP'

function Get-CaminhoConfigPublicacao { return (Join-Path $script:PastaCfg 'publicacao.json') }

function ConvertTo-SenhaSegura([string]$Texto) {
    $s = New-Object System.Security.SecureString
    foreach ($c in $Texto.ToCharArray()) { $s.AppendChar($c) }
    $s.MakeReadOnly()
    return $s
}
function ConvertFrom-SenhaSegura([System.Security.SecureString]$Senha) {
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Senha)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

# protocolo: ftps-explicito (padrao, o mais comum), ftps-implicito ou ftp (sem criptografia: so para teste local)
function Save-ConfigPublicacao {
    param([Parameter(Mandatory)] [hashtable]$Dados, [Parameter(Mandatory)] [System.Security.SecureString]$Senha, [string]$Arquivo = (Get-CaminhoConfigPublicacao))
    $pasta = Split-Path -Parent $Arquivo
    if (-not (Test-Path $pasta)) { $null = New-Item -ItemType Directory -Path $pasta -Force }
    $obj = [ordered]@{
        servidor = [string]$Dados.servidor; porta = [int]$Dados.porta; protocolo = [string]$Dados.protocolo; usuario = [string]$Dados.usuario
        pasta = ([string]$Dados.pasta).Trim('/'); url_publica = ([string]$Dados.url_publica).TrimEnd('/'); certificado = [string]$Dados.certificado
        senha = (ConvertFrom-SecureString $Senha)
    }
    $obj | ConvertTo-Json | Set-Content -Path $Arquivo -Encoding UTF8
}

function Get-ConfigPublicacao {
    param([string]$Arquivo = (Get-CaminhoConfigPublicacao))
    if (-not (Test-Path $Arquivo)) { return $null }
    $j = Get-Content $Arquivo -Raw -Encoding UTF8 | ConvertFrom-Json
    return [pscustomobject]@{
        servidor = $j.servidor; porta = [int]$j.porta; protocolo = $j.protocolo; usuario = $j.usuario; pasta = $j.pasta; url_publica = $j.url_publica
        certificado = $(if ($j.certificado) { $j.certificado } else { 'estrito' }); Senha = (ConvertTo-SecureString $j.senha)
    }
}

# ---------- FileZilla: le os sites salvos (a senha e decodificada na memoria e nunca e exibida) ----------
# Protocol do FileZilla: 0 FTP (TLS explicito se o servidor tiver), 1 SFTP, 3 FTPS implicito, 4 FTPS explicito, 5 FTP sem criptografia
function Read-SitesFileZilla {
    param([string]$Arquivo = (Join-Path $env:APPDATA 'FileZilla\sitemanager.xml'))
    if (-not (Test-Path $Arquivo)) { return @() }
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($Arquivo)
    $sites = @()
    foreach ($s in $xml.SelectNodes('//Server')) {
        $nome = [string]$s.SelectSingleNode('Name').InnerText
        $pass = $s.SelectSingleNode('Pass')
        $senha = $null; $criptografada = $false
        if ($pass) {
            $enc = $pass.GetAttribute('encoding')
            if ($enc -eq 'base64') { try { $senha = ConvertTo-SenhaSegura ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pass.InnerText))) } catch { $senha = $null } }
            elseif ($enc -eq 'crypt') { $criptografada = $true }
            elseif ($pass.InnerText) { $senha = ConvertTo-SenhaSegura $pass.InnerText }
        }
        $proto = [int]$(if ($s.SelectSingleNode('Protocol')) { $s.SelectSingleNode('Protocol').InnerText } else { 0 })
        $sites += [pscustomobject]@{
            Nome = $nome; Servidor = [string]$s.SelectSingleNode('Host').InnerText; Porta = [int]$(if ($s.SelectSingleNode('Port')) { $s.SelectSingleNode('Port').InnerText } else { 21 })
            ProtocoloFileZilla = $proto; Usuario = [string]$s.SelectSingleNode('User').InnerText; Senha = $senha; SenhaCriptografada = $criptografada
        }
    }
    return $sites
}
function ConvertTo-ProtocoloPublicacao([int]$ProtocoloFileZilla) {
    switch ($ProtocoloFileZilla) { 3 { return 'ftps-implicito' } 5 { return 'ftp' } 1 { return 'sftp' } default { return 'ftps-explicito' } }
}

# ---------- curl ----------
function Get-ExeCurl { return (Join-Path $env:SystemRoot 'System32\curl.exe') }

# Linha de configuracao do curl com usuario e senha (vai pela entrada padrao: a senha nao aparece na linha de comando do processo)
function New-ConfigCurl([string]$Usuario, [string]$Senha) {
    $esc = { param($t) $t.Replace('\', '\\').Replace('"', '\"') }   # dentro de aspas, o curl trata \ e " como escapes
    return ('user = "{0}:{1}"' -f (& $esc $Usuario), (& $esc $Senha))
}

function New-UrlRemota($Cfg, [string]$Caminho, [switch]$Diretorio) {
    $esquema = if ($Cfg.protocolo -eq 'ftps-implicito') { 'ftps' } else { 'ftp' }
    $partes = @($Cfg.pasta, $Caminho) | Where-Object { $_ } | ForEach-Object { $_.Trim('/') -split '/' } | Where-Object { $_ }
    $cam = ($partes | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $url = "${esquema}://$($Cfg.servidor):$($Cfg.porta)/$cam"
    if ($Diretorio -and -not $url.EndsWith('/')) { $url += '/' }
    return $url
}

# Executa o curl como processo (a senha vai pela entrada padrao, nao pela linha de comando). Devolve @{ Ok; Codigo; Saida }.
# Codigos 78 e 19 = arquivo nao existe no servidor, 9 = pasta nao existe (arquivo novo).
function Invoke-CurlFtp {
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string]$Url, [string[]]$Extra = @(), [int]$TimeoutSeg = 120)
    if ($Cfg.protocolo -eq 'sftp') { throw 'SFTP ainda nao e suportado por este script: use FTPS (explicito) no painel da hospedagem.' }
    $a = @('--silent', '--show-error', '--connect-timeout', '25', '--max-time', [string]$TimeoutSeg, '--ssl-no-revoke')
    if ($Cfg.protocolo -eq 'ftps-explicito') { $a += '--ssl-reqd' }
    if ($Cfg.certificado -eq 'aceitar') { $a += '--insecure' }
    $a += $Extra
    $a += @('-K', '-', $Url)
    $linha = ($a | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-ExeCurl); $psi.Arguments = $linha
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $senha = ConvertFrom-SenhaSegura $Cfg.Senha
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((New-ConfigCurl $Cfg.usuario $senha) + "`n")
        $senha = $null
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.Close()
        $tarefaErr = $p.StandardError.ReadToEndAsync()
        $saida = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        $erro = $tarefaErr.Result
        $codigo = $p.ExitCode
    } finally { $p.Dispose() }
    $texto = (($saida + "`n" + $erro).Trim())
    return @{ Ok = ($codigo -eq 0); Codigo = $codigo; Saida = $texto }
}

function Test-ConexaoPublicacao($Cfg) {
    $r = Invoke-CurlFtp -Cfg $Cfg -Url (New-UrlRemota $Cfg '' -Diretorio) -Extra @('--list-only') -TimeoutSeg 40
    $itens = @()
    if ($r.Ok) { $itens = @($r.Saida -split "`r?`n" | Where-Object { $_ }) }
    return @{ Ok = $r.Ok; Codigo = $r.Codigo; Erro = $(if ($r.Ok) { '' } else { $r.Saida }); Itens = $itens }
}

# ---------- arquivos ----------
# O que NUNCA vai para o servidor: configuracao, banco, chaves e dados (o pacote ja nao leva, e aqui e conferido de novo)
function Test-ArquivoProibido([string]$Rel) {
    $r = $Rel.Replace('\', '/').TrimStart('/').ToLowerInvariant()
    if ($r -eq 'config.php' -or $r.EndsWith('/config.php')) { return $true }
    if ($r.StartsWith('_app/dados/') -or $r -eq '_app/dados') { return $true }
    if ($r.EndsWith('.key') -or $r.EndsWith('.sqlite') -or $r.EndsWith('.sqlite-wal') -or $r.EndsWith('.sqlite-shm') -or $r.EndsWith('.pem')) { return $true }
    return $false
}

# Lista os arquivos de uma pasta ja extraida: [{Rel; Completo}], index.php por ultimo (e ele que "liga" a versao nova)
function Get-ArquivosPublicacao([Parameter(Mandatory)] [string]$Pasta) {
    $base = (Resolve-Path $Pasta).Path.TrimEnd('\')
    $lista = @()
    foreach ($f in Get-ChildItem -Path $base -Recurse -File) {
        $rel = $f.FullName.Substring($base.Length + 1).Replace('\', '/')
        if (Test-ArquivoProibido $rel) { continue }
        $lista += [pscustomobject]@{ Rel = $rel; Completo = $f.FullName }
    }
    return @($lista | Sort-Object @{ Expression = { $_.Rel -eq 'index.php' } }, Rel)
}

# ---------- publicar, conferir e reverter ----------
# Baixa a copia atual de cada arquivo (backup) e envia o novo. Devolve o que foi feito, para poder reverter.
function Publish-Arquivos {
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] $Arquivos, [Parameter(Mandatory)] [string]$PastaBackup, [switch]$Simular, [scriptblock]$AoProgredir)
    $manifesto = @(); $n = 0
    if (-not (Test-Path $PastaBackup)) { $null = New-Item -ItemType Directory -Path $PastaBackup -Force }
    foreach ($a in $Arquivos) {
        $n++
        if ($AoProgredir) { & $AoProgredir $n @($Arquivos).Count $a.Rel }
        if ($Simular) { $manifesto += [pscustomobject]@{ rel = $a.Rel; existia = $null; enviado = $false }; continue }
        $bak = Join-Path $PastaBackup ($a.Rel -replace '/', '\')
        $bakDir = Split-Path -Parent $bak
        if (-not (Test-Path $bakDir)) { $null = New-Item -ItemType Directory -Path $bakDir -Force }
        $url = New-UrlRemota $Cfg $a.Rel
        $d = Invoke-CurlFtp -Cfg $Cfg -Url $url -Extra @('-o', $bak)
        $existia = $d.Ok
        # 78 e 19: o arquivo nao existe. 9: a pasta ainda nao existe (arquivo novo).
        if (-not $d.Ok -and $d.Codigo -notin 78, 19, 9) { throw "Falha ao ler a copia atual de $($a.Rel) (curl $($d.Codigo)): $($d.Saida)" }
        if (-not $existia -and (Test-Path $bak)) { Remove-Item $bak -Force -ErrorAction SilentlyContinue }
        $u = Invoke-CurlFtp -Cfg $Cfg -Url $url -Extra @('--ftp-create-dirs', '-T', $a.Completo)
        $manifesto += [pscustomobject]@{ rel = $a.Rel; existia = $existia; enviado = $u.Ok }
        if (-not $u.Ok) { Save-ManifestoPublicacao $manifesto $PastaBackup; throw "Falha ao enviar $($a.Rel) (curl $($u.Codigo)): $($u.Saida)" }
    }
    Save-ManifestoPublicacao $manifesto $PastaBackup
    return $manifesto
}

function Save-ManifestoPublicacao($Manifesto, [string]$PastaBackup) {
    ConvertTo-Json -InputObject @($Manifesto) | Set-Content -Path (Join-Path $PastaBackup 'manifesto.json') -Encoding UTF8
}

# Volta ao estado anterior: reenvia a copia guardada de quem ja existia e apaga o que era novo.
function Undo-Publicacao {
    param([Parameter(Mandatory)] $Cfg, [Parameter(Mandatory)] [string]$PastaBackup)
    $arq = Join-Path $PastaBackup 'manifesto.json'
    if (-not (Test-Path $arq)) { throw "Manifesto nao encontrado em $PastaBackup" }
    $itens = @(Get-Content $arq -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })   # o PowerShell 5.1 entrega a lista JSON como um unico objeto: desembrulha
    $feitos = 0; $falhas = @()
    foreach ($i in $itens) {
        if (-not $i.enviado -and $null -eq $i.existia) { continue }
        $url = New-UrlRemota $Cfg $i.rel
        if ($i.existia) {
            $bak = Join-Path $PastaBackup ($i.rel -replace '/', '\')
            $r = Invoke-CurlFtp -Cfg $Cfg -Url $url -Extra @('--ftp-create-dirs', '-T', $bak)
        } else {
            $pai = New-UrlRemota $Cfg (($i.rel -split '/' | Select-Object -SkipLast 1) -join '/') -Diretorio
            $r = Invoke-CurlFtp -Cfg $Cfg -Url $pai -Extra @('-Q', ('+DELE ' + (($i.rel -split '/')[-1])), '--list-only', '-o', 'NUL')
        }
        if ($r.Ok) { $feitos++ } else { $falhas += $i.rel }
    }
    return @{ Revertidos = $feitos; Falhas = $falhas }
}

# Confere o servidor depois de publicar: /health responde ok (e devolve a versao do servidor)
function Test-SaudeServidor([string]$UrlPublica) {
    try {
        $r = Invoke-WebRequest -Uri ($UrlPublica.TrimEnd('/') + '/health') -UseBasicParsing -TimeoutSec 30
        $j = $r.Content | ConvertFrom-Json
        return @{ Ok = ([bool]$j.ok -and [bool]$j.sqlite); Versao = [string]$j.versao; Detalhe = $r.Content }
    } catch { return @{ Ok = $false; Versao = ''; Detalhe = $_.Exception.Message } }
}

Export-ModuleMember -Function *
