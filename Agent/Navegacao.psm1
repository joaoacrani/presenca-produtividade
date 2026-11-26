# Coleta de sites acessados a partir do historico dos navegadores (Chrome, Edge, Brave, Firefox).
# So le o historico do proprio usuario logado. Nao captura conteudo das paginas, formularios, senhas nem janela anonima
# (o navegador nao grava historico em janela anonima). A consulta (?...) e o fragmento (#...) das URLs sao removidos
# aqui, antes do envio, porque podem conter tokens e dados pessoais.
# Funcoes puras (sem acesso ao disco) ficam separadas para poderem ser testadas com Pester.

# ---------- leitor SQLite (winsqlite3.dll vem com o Windows 10/11; nao precisa instalar nada) ----------

function Initialize-SqliteLeitor {
    if ('PresencaPP.SqliteLeitor' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace PresencaPP {
public static class SqliteLeitor {
    const string DLL = "winsqlite3.dll";
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_close(IntPtr db);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nByte, out IntPtr stmt, IntPtr tail);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_column_bytes(IntPtr stmt, int i);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_finalize(IntPtr stmt);
    static byte[] Z(string s) { byte[] b = Encoding.UTF8.GetBytes(s); byte[] r = new byte[b.Length + 1]; Array.Copy(b, r, b.Length); return r; }
    public static List<string[]> Consultar(string arquivo, string sql) {
        IntPtr db;
        if (sqlite3_open_v2(Z(arquivo), out db, 2, IntPtr.Zero) != 0) { if (db != IntPtr.Zero) sqlite3_close(db); throw new Exception("nao foi possivel abrir o banco"); }
        try {
            IntPtr st;
            if (sqlite3_prepare_v2(db, Z(sql), -1, out st, IntPtr.Zero) != 0) throw new Exception("consulta invalida");
            try {
                List<string[]> lista = new List<string[]>();
                int n = sqlite3_column_count(st);
                while (sqlite3_step(st) == 100) {
                    string[] l = new string[n];
                    for (int i = 0; i < n; i++) {
                        IntPtr p = sqlite3_column_text(st, i);
                        if (p == IntPtr.Zero) { l[i] = ""; continue; }
                        int len = sqlite3_column_bytes(st, i);
                        byte[] b = new byte[len];
                        Marshal.Copy(p, b, 0, len);
                        l[i] = Encoding.UTF8.GetString(b);
                    }
                    lista.Add(l);
                }
                return lista;
            } finally { sqlite3_finalize(st); }
        } finally { sqlite3_close(db); }
    }
}
}
'@
}

# ---------- funcoes puras ----------

# "https://www.site.com:8080/a/b?token=x#y" -> "https://www.site.com/a/b"; devolve $null se nao for http/https
function ConvertTo-UrlSemConsulta([string]$Url) {
    if ($Url -notmatch '^(?i)(https?)://([^/?#:@\s]+)(:\d+)?(/[^?#\s]*)?(?=[?#]|$)') { return $null }
    $esq = $matches[1].ToLower(); $host_ = $matches[2].ToLower(); $caminho = $matches[4]
    if (-not $caminho) { $caminho = '/' }
    if ($caminho.Length -gt 200) { $caminho = $caminho.Substring(0, 200) }
    return "${esq}://$host_$caminho"
}

# Sites que nao interessam (maquina local / enderecos internos de desenvolvimento)
function Test-HostIgnorado([string]$Url, $Ignorar) {
    if ($Url -notmatch '^https?://([^/]+)') { return $true }
    $h = $matches[1] -replace ':\d+$', ''
    if ($h -eq 'localhost' -or $h -like '127.*' -or $h -like '*.localhost') { return $true }
    foreach ($p in @($Ignorar)) { if ($p -and ($h -eq $p -or $h.EndsWith(".$p"))) { return $true } }
    return $false
}

# Tempo estimado de cada visita = ate a proxima visita (em qualquer navegador), no maximo $LimiteSeg.
# A duracao que o Chrome grava conta abas abertas em segundo plano; por isso nao e usada.
# So sao enviadas visitas com mais de $LimiteSeg de idade (ja tem a proxima visita, ou o tempo ja estourou o limite):
# as mais recentes esperam a proxima execucao. Visitas: objetos com Fonte, Ms, Url, Titulo, Navegador.
function Get-LoteNavegacao {
    param($Visitas, [long]$AgoraMs, [int]$LimiteSeg = 300, [int]$Max = 400)
    $ord = @($Visitas | Sort-Object Ms)
    $enviar = @()
    for ($i = 0; $i -lt $ord.Count; $i++) {
        $v = $ord[$i]
        if ($v.Ms -gt ($AgoraMs - $LimiteSeg * 1000)) { break }   # ainda pode estar aberta
        $gap = if ($i + 1 -lt $ord.Count) { [math]::Floor(($ord[$i + 1].Ms - $v.Ms) / 1000) } else { $LimiteSeg }
        $dur = [math]::Max(1, [math]::Min($gap, $LimiteSeg))
        $enviar += [pscustomobject]@{ Fonte = $v.Fonte; ts = [long]$v.Ms; url = $v.Url; titulo = $v.Titulo; navegador = $v.Navegador; duracao_seg = [int]$dur }
        if ($enviar.Count -ge $Max) { break }
    }
    return $enviar
}

# ---------- historico dos navegadores ----------

function Get-FontesHistorico {
    $fontes = @()
    $local = $env:LOCALAPPDATA
    $cromios = @(
        @{ N = 'Chrome'; P = Join-Path $local 'Google\Chrome\User Data' },
        @{ N = 'Edge';   P = Join-Path $local 'Microsoft\Edge\User Data' },
        @{ N = 'Brave';  P = Join-Path $local 'BraveSoftware\Brave-Browser\User Data' }
    )
    foreach ($c in $cromios) {
        if (-not (Test-Path $c.P)) { continue }
        foreach ($perfil in @(Get-ChildItem -Path $c.P -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            $h = Join-Path $perfil.FullName 'History'
            if (Test-Path $h) { $fontes += [pscustomobject]@{ Navegador = $c.N; Tipo = 'cromio'; Arquivo = $h } }
        }
    }
    $ff = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
    if (Test-Path $ff) {
        foreach ($perfil in @(Get-ChildItem -Path $ff -Directory -ErrorAction SilentlyContinue)) {
            $h = Join-Path $perfil.FullName 'places.sqlite'
            if (Test-Path $h) { $fontes += [pscustomobject]@{ Navegador = 'Firefox'; Tipo = 'firefox'; Arquivo = $h } }
        }
    }
    return $fontes
}

# Copia o arquivo (o navegador o mantem aberto) para uma pasta temporaria, le e apaga a copia.
function Read-HistoricoFonte {
    param($Fonte, [long]$DesdeMs, [string]$PastaTemp, [int]$Limite = 600)
    Initialize-SqliteLeitor
    if (-not (Test-Path $PastaTemp)) { $null = New-Item -ItemType Directory -Path $PastaTemp -Force }
    $copia = Join-Path $PastaTemp ([guid]::NewGuid().ToString('N') + '.db')
    $inv = [Globalization.CultureInfo]::InvariantCulture
    try {
        foreach ($sufixo in '', '-wal') {
            $orig = $Fonte.Arquivo + $sufixo
            if (-not (Test-Path $orig)) { continue }
            $in = [IO.File]::Open($orig, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try { $out = [IO.File]::Create($copia + $sufixo); try { $in.CopyTo($out) } finally { $out.Dispose() } } finally { $in.Dispose() }
        }
        if ($Fonte.Tipo -eq 'cromio') {
            $desdeUs = ($DesdeMs + 11644473600000) * 1000
            $sql = 'SELECT v.visit_time, u.url, u.title FROM visits v JOIN urls u ON u.id = v.url ' +
                   "WHERE v.visit_time > $($desdeUs.ToString($inv)) AND (v.transition & 255) NOT IN (3, 4) ORDER BY v.visit_time LIMIT $Limite"
            $conv = { param($x) [long]([long]$x / 1000 - 11644473600000) }
        } else {
            $desdeUs = $DesdeMs * 1000
            $sql = 'SELECT h.visit_date, p.url, p.title FROM moz_historyvisits h JOIN moz_places p ON p.id = h.place_id ' +
                   "WHERE h.visit_date > $($desdeUs.ToString($inv)) AND h.visit_type NOT IN (4, 8) ORDER BY h.visit_date LIMIT $Limite"
            $conv = { param($x) [long]([long]$x / 1000) }
        }
        $linhas = [PresencaPP.SqliteLeitor]::Consultar($copia, $sql)
        foreach ($l in $linhas) {
            [pscustomobject]@{ Fonte = $Fonte.Arquivo; Ms = (& $conv $l[0]); Url = $l[1]; Titulo = $l[2]; Navegador = $Fonte.Navegador }
        }
    } finally {
        foreach ($sufixo in '', '-wal') { Remove-Item -Path ($copia + $sufixo) -Force -ErrorAction SilentlyContinue }
    }
}

function Read-CursorNavegacao([string]$Arquivo) {
    $c = @{}
    if (Test-Path $Arquivo) {
        try {
            $j = Get-Content -Path $Arquivo -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $c[$p.Name] = @{ ms = [long]$p.Value.ms; mtime = [long]$p.Value.mtime } }
        } catch { }
    }
    return $c
}
function Save-CursorNavegacao($Cursor, [string]$Arquivo) {
    $o = [ordered]@{}
    foreach ($k in $Cursor.Keys) { $o[$k] = @{ ms = $Cursor[$k].ms; mtime = $Cursor[$k].mtime } }
    $o | ConvertTo-Json | Set-Content -Path $Arquivo -Encoding UTF8
}

# Le o que e novo em todos os navegadores. Devolve { Lote; Cursor } - o cursor so deve ser gravado depois do envio.
function Get-NavegacaoNova {
    param(
        [Parameter(Mandatory)] [string]$PastaDados,
        [datetime]$Agora = (Get-Date),
        [int]$LimiteSeg = 300,
        [int]$PrimeiraJanelaMin = 30,
        $IgnorarHosts
    )
    $agoraMs = [DateTimeOffset]::new($Agora).ToUnixTimeMilliseconds()
    $arqCursor = Join-Path $PastaDados 'nav-cursor.json'
    $cursor = Read-CursorNavegacao $arqCursor
    $todas = @()
    $novoMtime = @{}
    foreach ($f in @(Get-FontesHistorico)) {
        try {
            $mtime = (Get-Item -Path $f.Arquivo).LastWriteTimeUtc.Ticks
            $c = $cursor[$f.Arquivo]
            if ($c -and $c.mtime -eq $mtime) { continue }          # arquivo nao mudou desde a ultima leitura
            $desde = if ($c) { $c.ms } else { $agoraMs - $PrimeiraJanelaMin * 60000 }
            $novoMtime[$f.Arquivo] = $mtime
            $todas += @(Read-HistoricoFonte -Fonte $f -DesdeMs $desde -PastaTemp (Join-Path $PastaDados 'tmp'))
        } catch { }   # navegador aberto/travado: tenta de novo na proxima execucao
    }
    $validas = @()
    foreach ($v in $todas) {
        $u = ConvertTo-UrlSemConsulta $v.Url
        if (-not $u -or (Test-HostIgnorado $u $IgnorarHosts)) { continue }
        $t = [string]$v.Titulo; if ($t.Length -gt 150) { $t = $t.Substring(0, 150) }
        $validas += [pscustomobject]@{ Fonte = $v.Fonte; Ms = $v.Ms; Url = $u; Titulo = $t; Navegador = $v.Navegador }
    }
    $lote = @(Get-LoteNavegacao -Visitas $validas -AgoraMs $agoraMs -LimiteSeg $LimiteSeg)
    # Novo cursor por arquivo lido: o maior instante enviado. O "mtime" so e guardado (para pular a leitura na proxima vez)
    # quando nao sobrou nenhuma visita pendente naquele arquivo (as recentes esperam a proxima execucao).
    $novo = @{}
    foreach ($k in $cursor.Keys) { $novo[$k] = $cursor[$k] }
    foreach ($f in $novoMtime.Keys) {
        $enviadas = @($lote | Where-Object { $_.Fonte -eq $f })
        $maxEnviado = if ($enviadas.Count) { [long]($enviadas | Measure-Object -Property ts -Maximum).Maximum } else { $null }
        $pendentes = @($validas | Where-Object { $_.Fonte -eq $f -and ($null -eq $maxEnviado -or $_.Ms -gt $maxEnviado) }).Count
        $base = if ($cursor[$f]) { [long]$cursor[$f].ms } else { $agoraMs - $PrimeiraJanelaMin * 60000 }
        if ($null -ne $maxEnviado) { $ms = $maxEnviado }
        elseif ($pendentes -gt 0)  { $ms = $base }
        else                       { $ms = [long][math]::Max($base, $agoraMs - $LimiteSeg * 1000) }
        $novo[$f] = @{ ms = $ms; mtime = $(if ($pendentes -gt 0) { [long]0 } else { [long]$novoMtime[$f] }) }
    }    return [pscustomobject]@{ Lote = $lote; Cursor = $novo; ArquivoCursor = $arqCursor }
}

function Send-Navegacao {
    param(
        [Parameter(Mandatory)] $Lote,
        [Parameter(Mandatory)] [string]$Servidor,
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$Maquina,
        [string]$Usuario, [string]$NomeCompleto
    )
    $visitas = @($Lote | ForEach-Object { [pscustomobject]@{ ts = $_.ts; url = $_.url; titulo = $_.titulo; navegador = $_.navegador; duracao_seg = $_.duracao_seg } })
    $corpo = [pscustomobject]@{ host = $Maquina; usuario = $Usuario; nome_completo = $NomeCompleto; visitas = $visitas } | ConvertTo-Json -Depth 4 -Compress
    try {
        Invoke-RestMethod -Uri (($Servidor.TrimEnd('/')) + '/api/navegacao') -Method Post -Headers @{ Authorization = "Bearer $Token" } `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($corpo)) -TimeoutSec 20 | Out-Null
        return $true
    } catch { if (Get-Command Set-UltimoErroRede -ErrorAction SilentlyContinue) { Set-UltimoErroRede $_ }; return $false }
}

Export-ModuleMember -Function *
