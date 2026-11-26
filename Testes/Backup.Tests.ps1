# Testes das funcoes do backup do servidor (Backup.psm1).
$raiz = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $raiz 'Servidor\Publicar\Backup.psm1') -Force

Describe 'Backup: conferencia do arquivo' {
    It 'reconhece um banco SQLite e rejeita outros arquivos' {
        $ok = Join-Path $TestDrive 'a.sqlite'
        $b = [System.Text.Encoding]::ASCII.GetBytes('SQLite format 3') + [byte]0 + (New-Object byte[] 100)
        [System.IO.File]::WriteAllBytes($ok, $b)
        (Test-ArquivoSqlite $ok) | Should Be $true
        $ruim = Join-Path $TestDrive 'b.sqlite'
        Set-Content -Path $ruim -Value '<html>erro 404</html>' -Encoding ASCII
        (Test-ArquivoSqlite $ruim) | Should Be $false
        (Test-ArquivoSqlite (Join-Path $TestDrive 'nao-existe')) | Should Be $false
        $curto = Join-Path $TestDrive 'c.sqlite'
        [System.IO.File]::WriteAllBytes($curto, [byte[]](1, 2, 3))
        (Test-ArquivoSqlite $curto) | Should Be $false
    }
}

Describe 'Backup: compactacao' {
    It 'o gzip volta igual ao original' {
        $o = Join-Path $TestDrive 'orig.bin'
        $bytes = New-Object byte[] 50000
        (New-Object System.Random 7).NextBytes($bytes)
        [System.IO.File]::WriteAllBytes($o, $bytes)
        $gz = Join-Path $TestDrive 'orig.bin.gz'
        Compress-ArquivoGzip -Origem $o -Destino $gz
        $ent = [System.IO.File]::OpenRead($gz)
        $g = New-Object System.IO.Compression.GZipStream($ent, [System.IO.Compression.CompressionMode]::Decompress)
        $ms = New-Object System.IO.MemoryStream
        $g.CopyTo($ms); $g.Dispose(); $ent.Dispose()
        [System.Convert]::ToBase64String($ms.ToArray()) | Should Be ([System.Convert]::ToBase64String($bytes))
    }
}

Describe 'Backup: rotacao' {
    function Novo($dias) { [pscustomobject]@{ Name = ('presenca-d{0}.sqlite.gz' -f $dias); LastWriteTime = (Get-Date '2026-11-24').AddDays(-$dias) } }
    It 'com poucas copias nao apaga nada' {
        @(Get-BackupsParaApagar @((Novo 0), (Novo 1), (Novo 2)) 14 8).Count | Should Be 0
    }
    It 'guarda as 14 mais novas e uma por semana nas semanas anteriores' {
        $todas = 0..59 | ForEach-Object { Novo $_ }
        $apagar = @(Get-BackupsParaApagar $todas 14 8)
        $mantidas = @($todas | Where-Object { $apagar -notcontains $_.Name })
        ($mantidas | Where-Object { $_.Name -match 'd(\d+)\.' -and [int]$Matches[1] -lt 14 }).Count | Should Be 14
        $mantidas.Count | Should BeLessThan 24
        $mantidas.Count | Should BeGreaterThan 14
        ($apagar -contains 'presenca-d0.sqlite.gz') | Should Be $false
        ($apagar -contains 'presenca-d13.sqlite.gz') | Should Be $false
        ($apagar -contains 'presenca-d59.sqlite.gz') | Should Be $true
    }
}

Describe 'Backup: configuracao e script' {
    It 'o script tem os parametros e so apaga a copia do servidor depois de comprimir e conferir' {
        $t = Get-Content (Join-Path $raiz 'Servidor\Publicar\Backup-Servidor.ps1') -Raw
        $t | Should Match '\[switch\]\$Agendar'
        $t | Should Match 'NAO foi apagada'
        ($t.IndexOf('Compress-ArquivoGzip') -lt $t.IndexOf('+DELE presenca-snapshot.sqlite')) | Should Be $true
        ($t.IndexOf('Test-ArquivoSqlite') -lt $t.IndexOf('Compress-ArquivoGzip')) | Should Be $true
    }
    It 'os arquivos novos sao so ASCII (PowerShell 5.1)' {
        foreach ($f in 'Servidor\Publicar\Backup.psm1', 'Servidor\Publicar\Backup-Servidor.ps1', 'Ferramentas\Backup-Repositorio.ps1') {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $raiz $f))
            (@($bytes | Where-Object { $_ -gt 127 }).Count) | Should Be 0
        }
    }
}

Describe 'Backup: conferencia de integridade com o PHP do PC' {
    $php = Get-Command php -ErrorAction SilentlyContinue
    $ext = if ($php) { Join-Path (Split-Path -Parent $php.Source) 'ext' } else { '' }
    $temSqlite = [bool]($php -and (Test-Path (Join-Path $ext 'php_pdo_sqlite.dll')))
    function Novo-Banco([string]$Caminho) {
        $arq = $Caminho.Replace('\', '/')
        $codigo = '$d = new PDO(''sqlite:' + $arq + '''); $d->exec(''CREATE TABLE t (a TEXT)''); $s = $d->prepare(''INSERT INTO t VALUES (?)''); for ($i = 0; $i < 3000; $i++) { $s->execute([str_repeat(''x'', 50) . $i]); }'
        & $php.Source '-d' "extension_dir=$ext" '-d' 'extension=pdo_sqlite' '-d' 'extension=sqlite3' -r $codigo 2>&1 | Out-Null
    }
    It 'banco bom: ok (mesmo com caminho com espacos)' -Skip:(-not $temSqlite) {
        $pasta = Join-Path $TestDrive 'pasta com espaco'
        $null = New-Item -ItemType Directory -Path $pasta -Force
        $bom = Join-Path $pasta 'bom.sqlite'
        Novo-Banco $bom
        (Test-ArquivoSqlite $bom) | Should Be $true
        (Test-IntegridadeSqlite $bom) | Should Be 'ok'
    }
    It 'banco danificado: falhou' -Skip:(-not $temSqlite) {
        $bom = Join-Path $TestDrive 'orig.sqlite'
        Novo-Banco $bom
        $bytes = [System.IO.File]::ReadAllBytes($bom)
        for ($i = 4096; $i -lt [Math]::Min($bytes.Length, 4096 + 2048); $i++) { $bytes[$i] = 0xFF }   # estraga uma pagina no meio
        $ruim = Join-Path $TestDrive 'ruim.sqlite'
        [System.IO.File]::WriteAllBytes($ruim, $bytes)
        (Test-IntegridadeSqlite $ruim) | Should Be 'falhou'
    }
    It 'sem PHP com SQLite a conferencia fica indisponivel e nao bloqueia o backup' {
        $naoBanco = Join-Path $TestDrive 'texto.txt'
        Set-Content -Path $naoBanco -Value 'nao e um banco' -Encoding ASCII
        (Test-IntegridadeSqlite $naoBanco) | Should Not Be 'ok'
    }
}

Describe 'Backup da pasta do projeto' {
    It 'segredos, bancos, saidas geradas e historico do git ficam de fora; o resto entra' {
        foreach ($f in 'Servidor/credenciais.json', 'chaves/atualizador-privada.xml', 'Servidor/fonte/_app/config.php', 'Servidor/local/config.php', 'Servidor/fonte/_app/dados/presenca.sqlite',
                 'Entregas/Agente/Pacote-Agente.zip', '.git/config', 'DesignSystem/pacote/node_modules/x.js', 'x/remoto.key', 'a/b/certificado.pem', 'Servidor/build/index.php', '.env') {
            (Test-ExcluirDaPasta $f) | Should Be $true
        }
        foreach ($f in 'README.md', '2 - Instalar Agente neste PC.bat', 'Agent/Presenca.psm1', 'Servidor/fonte/index.php', 'Servidor/fonte/_app/lib/config_extra.php', 'Testes/servidor.test.js', 'Docs/GUIA-HOSPEDAGEM.md', 'Config/unidades.json', 'Agent/chave-publica.xml') {
            (Test-ExcluirDaPasta $f) | Should Be $false
        }
        (Test-ExcluirDaPasta 'Servidor\credenciais.json') | Should Be $true   # barra invertida do Windows tambem
    }
    It 'o zip traz so o permitido e sobrescreve o do mesmo dia' {
        $raiz = Join-Path $TestDrive 'proj'
        foreach ($d in 'Agent', 'Servidor\fonte', 'chaves', 'Entregas\Agente', '.git') { $null = New-Item -ItemType Directory -Path (Join-Path $raiz $d) -Force }
        Set-Content (Join-Path $raiz 'README.md') 'oi'; Set-Content (Join-Path $raiz 'Agent\a.ps1') 'a'; Set-Content (Join-Path $raiz 'Servidor\fonte\index.php') 'p'
        Set-Content (Join-Path $raiz 'Servidor\credenciais.json') 'segredo'; Set-Content (Join-Path $raiz 'chaves\k.xml') 'segredo'
        Set-Content (Join-Path $raiz 'Entregas\Agente\t.zip') 'token'; Set-Content (Join-Path $raiz '.git\config') 'x'
        $zipArq = Join-Path $TestDrive 'out.zip'
        $r = New-ZipDaPasta -Raiz $raiz -Destino $zipArq
        $r.Arquivos | Should Be 3
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [System.IO.Compression.ZipFile]::OpenRead($zipArq)
        $nomes = @($z.Entries | ForEach-Object { $_.FullName } | Sort-Object)
        $z.Dispose()
        ($nomes -join ',') | Should Be 'Agent/a.ps1,README.md,Servidor/fonte/index.php'
        $r2 = New-ZipDaPasta -Raiz $raiz -Destino $zipArq
        $r2.Arquivos | Should Be 3
        (Test-Path ($zipArq + '.parcial')) | Should Be $false
    }
    It 'o script e o atalho existem e so tem ASCII' {
        foreach ($f in 'Ferramentas\Backup-Pasta.ps1', '10 - Backup da Pasta do Projeto.bat') {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $raiz $f))
            (@($bytes | Where-Object { $_ -gt 127 }).Count) | Should Be 0
        }
    }
}
