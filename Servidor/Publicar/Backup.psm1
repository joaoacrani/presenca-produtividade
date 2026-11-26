# Funcoes do backup do servidor (copia do banco e das chaves para o PC). Sem acentos: PowerShell 5.1 le o arquivo sem BOM como ANSI.

# O arquivo e um banco SQLite de verdade? (os 16 primeiros bytes sao "SQLite format 3" + byte zero)
function Test-ArquivoSqlite([string]$Caminho) {
    if (-not (Test-Path $Caminho)) { return $false }
    try {
        $fs = [System.IO.File]::OpenRead($Caminho)
        try {
            $buf = New-Object byte[] 16
            $n = $fs.Read($buf, 0, 16)
            if ($n -lt 16) { return $false }
            $esperado = [System.Text.Encoding]::ASCII.GetBytes("SQLite format 3") + [byte]0
            for ($i = 0; $i -lt 16; $i++) { if ($buf[$i] -ne $esperado[$i]) { return $false } }
            return $true
        } finally { $fs.Dispose() }
    } catch { return $false }
}

# Conferencia profunda (PRAGMA integrity_check) quando o PHP do PC tem SQLite. Devolve 'ok', 'falhou' ou 'indisponivel'.
function Test-IntegridadeSqlite([string]$Caminho) {
    $php = Get-Command php -ErrorAction SilentlyContinue
    if (-not $php) { return 'indisponivel' }
    try {
        $dirBin = Split-Path -Parent $php.Source
        $ext = Join-Path $dirBin 'ext'
        $flags = @()
        if (Test-Path (Join-Path $ext 'php_pdo_sqlite.dll')) { $flags = @('-d', "extension_dir=$ext", '-d', 'extension=pdo_sqlite', '-d', 'extension=sqlite3') }
        $arq = $Caminho.Replace('\', '/')
        # So aspas simples dentro do codigo PHP: o PowerShell 5.1 remove as aspas duplas dos argumentos de programas externos
        $codigo = '$d = new PDO(''sqlite:' + $arq + '''); echo $d->query(''PRAGMA integrity_check'')->fetchColumn();'
        $saida = (& $php.Source @flags -r $codigo 2>&1 | Out-String).Trim()
        if ($saida -eq 'ok') { return 'ok' }
        # banco danificado de verdade (a conferencia fala em "malformed" / "not a database" / lista de erros do SQLite)
        if ($saida -match 'malformed|not a database|corrupt|\*\*\* in database|rowid|Page \d+') { return 'falhou' }
        # qualquer outra coisa (PHP sem SQLite, erro de sintaxe, aviso) e problema da ferramenta, nao do banco: nao bloqueia o backup
        return 'indisponivel'
    } catch { return 'indisponivel' }
}

function Compress-ArquivoGzip([string]$Origem, [string]$Destino) {
    $ent = [System.IO.File]::OpenRead($Origem)
    try {
        $sai = [System.IO.File]::Create($Destino)
        try {
            $gz = New-Object System.IO.Compression.GZipStream($sai, [System.IO.Compression.CompressionLevel]::Optimal)
            try { $ent.CopyTo($gz) } finally { $gz.Dispose() }
        } finally { $sai.Dispose() }
    } finally { $ent.Dispose() }
}

# Quais copias apagar: guarda as $Diarios mais novas e, das demais, a mais nova de cada semana (ate $Semanas semanas).
# $Arquivos: objetos com Name e LastWriteTime. Devolve os nomes a apagar.
function Get-BackupsParaApagar($Arquivos, [int]$Diarios = 14, [int]$Semanas = 8) {
    $ordenados = @($Arquivos | Sort-Object LastWriteTime -Descending)
    if ($ordenados.Count -le $Diarios) { return @() }
    $manter = @{}
    $ordenados | Select-Object -First $Diarios | ForEach-Object { $manter[$_.Name] = $true }
    $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
    $vistas = @{}
    foreach ($a in ($ordenados | Select-Object -Skip $Diarios)) {
        $d = $a.LastWriteTime
        $semana = $cal.GetWeekOfYear($d, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)
        $chave = '{0}-{1:00}' -f $d.Year, $semana
        if (-not $vistas.ContainsKey($chave) -and $vistas.Count -lt $Semanas) { $vistas[$chave] = $true; $manter[$a.Name] = $true }
    }
    return @($ordenados | Where-Object { -not $manter.ContainsKey($_.Name) } | ForEach-Object { $_.Name })
}

function Get-CaminhoConfigBackup { return (Join-Path (Join-Path $env:LOCALAPPDATA 'PresencaPP') 'backup.json') }

function Get-ConfigBackup {
    $f = Get-CaminhoConfigBackup
    if (-not (Test-Path $f)) { return $null }
    try { return (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-ConfigBackup([string]$Destino) {
    $f = Get-CaminhoConfigBackup
    $pasta = Split-Path -Parent $f
    if (-not (Test-Path $pasta)) { $null = New-Item -ItemType Directory -Path $pasta -Force }
    (@{ destino = $Destino } | ConvertTo-Json) | Set-Content -Path $f -Encoding UTF8
}

# ---------- backup da pasta do projeto ----------

# O que NAO vai no zip da pasta: segredos (credenciais, chaves, config.php, .env), banco, saidas geradas (Entregas tem o token do agent),
# historico do git (o .bundle ja cobre) e pastas de dependencias. $Rel e o caminho relativo a raiz do projeto.
function Test-ExcluirDaPasta([string]$Rel) {
    $r = ($Rel -replace '\\', '/').TrimStart('/')
    $nome = ($r -split '/')[-1].ToLowerInvariant()
    foreach ($pre in '.git/', 'Entregas/', 'chaves/', 'Servidor/local/', 'Servidor/build/') { if ($r.StartsWith($pre, [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
    foreach ($meio in '/node_modules/', '/_app/dados/', '/.git/') { if (('/' + $r).IndexOf($meio, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }
    if ($nome -in 'credenciais.json', 'config.php', '.env', 'publicacao.json', 'backup.json') { return $true }
    foreach ($ext in '.key', '.pem', '.pfx', '.sqlite', '.sqlite-wal', '.sqlite-shm', '.db') { if ($nome.EndsWith($ext)) { return $true } }
    return $false
}

# Zip da pasta do projeto sem os arquivos excluidos. Grava num arquivo temporario e so entao troca o destino (o OneDrive nunca
# sincroniza um zip pela metade). Devolve @{ Arquivos; Bytes }.
function New-ZipDaPasta([string]$Raiz, [string]$Destino) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $raizCompleta = (Resolve-Path $Raiz).Path.TrimEnd('\')
    $tmp = $Destino + '.parcial'
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    $n = 0
    $fs = [System.IO.File]::Create($tmp)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in (Get-ChildItem -LiteralPath $raizCompleta -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                $rel = $f.FullName.Substring($raizCompleta.Length + 1)
                if (Test-ExcluirDaPasta $rel) { continue }
                try {
                    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, ($rel -replace '\\', '/'), [System.IO.Compression.CompressionLevel]::Optimal)
                    $n++
                } catch { }   # arquivo aberto por outro programa: fica para o proximo backup
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
    if (Test-Path $Destino) { Remove-Item $Destino -Force }
    Move-Item -LiteralPath $tmp -Destination $Destino
    return @{ Arquivos = $n; Bytes = (Get-Item $Destino).Length }
}

Export-ModuleMember -Function *
