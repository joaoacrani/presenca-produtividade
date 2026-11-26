# Testes da publicacao do servidor por FTPS (sem rede): arquivos proibidos, URLs, linha de credencial do curl,
# configuracao criptografada, leitura dos sites do FileZilla e o fluxo de publicar, reverter e simular com um "servidor" de mentira.
$raiz = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $raiz 'Servidor\Publicar\Publicacao.psm1') -Force

Describe 'Publicacao: o que nunca vai para o servidor' {
    It 'bloqueia config.php, a pasta de dados, chaves e bancos' {
        foreach ($p in 'config.php', '_app/config.php', '_APP/Config.PHP', '_app/dados/presenca.sqlite', '_app/dados/agente/pacote.zip', '_app/dados', '_app/dados/remoto.key', 'x/y.key', 'a.sqlite', 'a.sqlite-wal', 'cert.pem', '_app\dados\x.txt') {
            Test-ArquivoProibido $p | Should Be $true
        }
    }
    It 'libera os arquivos normais do painel' {
        foreach ($p in 'index.php', '.htaccess', '_app/lib/db.php', '_app/public/style.css', '_app/unidades.json', '_app/public/com espaco.js') { Test-ArquivoProibido $p | Should Be $false }
    }
    It 'a lista de uma pasta exclui o proibido e deixa index.php por ultimo' {
        $t = Join-Path $TestDrive 'pacote'
        $null = New-Item -ItemType Directory -Path "$t\_app\lib", "$t\_app\dados" -Force
        foreach ($f in 'index.php', '.htaccess', '_app\lib\a.php', '_app\config.php', '_app\dados\banco.sqlite', '_app\dados\remoto.key') { Set-Content (Join-Path $t $f) 'x' -Encoding ASCII }
        $lista = @(Get-ArquivosPublicacao $t)
        ($lista | ForEach-Object { $_.Rel }) -join '|' | Should Be '.htaccess|_app/lib/a.php|index.php'
    }
}

Describe 'Publicacao: URL e credenciais do curl' {
    $cfg = [pscustomobject]@{ servidor = 'ftp.exemplo.com.br'; porta = 21; protocolo = 'ftps-explicito'; pasta = 'public_html/presenca' }
    It 'monta a URL com a pasta remota e codifica espacos' {
        (New-UrlRemota $cfg '_app/public/com espaco.js') | Should Be 'ftp://ftp.exemplo.com.br:21/public_html/presenca/_app/public/com%20espaco.js'
        (New-UrlRemota $cfg '' -Diretorio) | Should Be 'ftp://ftp.exemplo.com.br:21/public_html/presenca/'
        (New-UrlRemota $cfg '_app/lib' -Diretorio) | Should Be 'ftp://ftp.exemplo.com.br:21/public_html/presenca/_app/lib/'
    }
    It 'FTPS implicito usa ftps:// e pasta vazia vai para a raiz' {
        $c = [pscustomobject]@{ servidor = 'h'; porta = 990; protocolo = 'ftps-implicito'; pasta = '' }
        (New-UrlRemota $c 'index.php') | Should Be 'ftps://h:990/index.php'
    }
    It 'a linha de usuario e senha escapa aspas e barra invertida e nunca vai na linha de comando' {
        (New-ConfigCurl 'u@x.com' 'a"b\c$d') | Should Be 'user = "u@x.com:a\"b\\c$d"'
    }
    It 'SFTP ainda nao e suportado e avisa com clareza' {
        $c = [pscustomobject]@{ servidor = 'h'; porta = 22; protocolo = 'sftp'; pasta = ''; usuario = 'u'; certificado = 'estrito'; Senha = (ConvertTo-SenhaSegura 'x') }
        { Invoke-CurlFtp -Cfg $c -Url 'ftp://h/' } | Should Throw 'FTPS'
    }
}

Describe 'Publicacao: configuracao guardada com a senha criptografada' {
    It 'grava, le de volta e nao deixa a senha em texto no arquivo' {
        $arq = Join-Path $TestDrive 'publicacao.json'
        Save-ConfigPublicacao -Arquivo $arq -Dados @{ servidor = 'ftp.x.com'; porta = 21; protocolo = 'ftps-explicito'; usuario = 'user@x.com'; pasta = '/public_html/presenca/'; url_publica = 'https://x.com/presenca/'; certificado = 'estrito' } -Senha (ConvertTo-SenhaSegura 'Segredo!123')
        (Get-Content $arq -Raw).Contains('Segredo') | Should Be $false
        $c = Get-ConfigPublicacao -Arquivo $arq
        $c.servidor | Should Be 'ftp.x.com'; $c.pasta | Should Be 'public_html/presenca'; $c.url_publica | Should Be 'https://x.com/presenca'
        (ConvertFrom-SenhaSegura $c.Senha) | Should Be 'Segredo!123'
    }
    It 'sem arquivo devolve nulo' { (Get-ConfigPublicacao -Arquivo (Join-Path $TestDrive 'nao-existe.json')) | Should Be $null }
}

Describe 'Publicacao: sites salvos no FileZilla' {
    It 'le host, usuario, protocolo e decodifica a senha sem exibir; reconhece senha mestra' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<FileZilla3><Servers><Folder expanded="1">Meus
<Server><Host>ftp.exemplo.com.br</Host><Port>21</Port><Protocol>4</Protocol><User>app@exemplo.com.br</User><Pass encoding="base64">U2VjcmV0byExMjM=</Pass><Name>Hospedagem</Name></Server>
<Server><Host>outro.com</Host><Port>2222</Port><Protocol>1</Protocol><User>x</User><Pass encoding="crypt" index="0" salt="a" pubkey="b">zzz</Pass><Name>Com senha mestra</Name></Server>
<Server><Host>sem.senha.com</Host><Port>21</Port><Protocol>0</Protocol><User>y</User><Name>Sem senha</Name></Server>
</Folder></Servers></FileZilla3>
'@
        $arq = Join-Path $TestDrive 'sitemanager.xml'
        Set-Content $arq $xml -Encoding UTF8
        $s = @(Read-SitesFileZilla -Arquivo $arq)
        $s.Count | Should Be 3
        $s[0].Nome | Should Be 'Hospedagem'; $s[0].Servidor | Should Be 'ftp.exemplo.com.br'; $s[0].Usuario | Should Be 'app@exemplo.com.br'; $s[0].Porta | Should Be 21
        ($s[0].Senha -is [System.Security.SecureString]) | Should Be $true
        (ConvertFrom-SenhaSegura $s[0].Senha) | Should Be 'Secreto!123'
        (ConvertTo-ProtocoloPublicacao $s[0].ProtocoloFileZilla) | Should Be 'ftps-explicito'
        $s[1].SenhaCriptografada | Should Be $true; $s[1].Senha | Should Be $null
        (ConvertTo-ProtocoloPublicacao $s[1].ProtocoloFileZilla) | Should Be 'sftp'
        $s[2].Senha | Should Be $null; $s[2].SenhaCriptografada | Should Be $false
        (ConvertTo-ProtocoloPublicacao 3) | Should Be 'ftps-implicito'; (ConvertTo-ProtocoloPublicacao 5) | Should Be 'ftp'
    }
    It 'sem o arquivo do FileZilla devolve lista vazia' { @(Read-SitesFileZilla -Arquivo (Join-Path $TestDrive 'nada.xml')).Count | Should Be 0 }
}

Describe 'Publicacao: publicar com backup, reverter e simular (servidor de mentira)' {
    BeforeEach {
        $global:remotoFake = @{ 'site/index.php' = 'ANTIGO'; 'site/_app/lib/db.php' = 'DB ANTIGO'; 'site/_app/config.php' = 'SEGREDO' }
        $global:chamadasFake = New-Object System.Collections.ArrayList
        Mock -ModuleName Publicacao Invoke-CurlFtp {
            $e = @($Extra); $chave = ([uri]$Url).AbsolutePath.TrimStart('/') -replace '%20', ' '
            [void]$global:chamadasFake.Add(($e -join ' ') + ' ' + $chave)
            $iT = [array]::IndexOf($e, '-T'); $iO = [array]::IndexOf($e, '-o'); $iQ = [array]::IndexOf($e, '-Q')
            if ($iT -ge 0) { $global:remotoFake[$chave] = [IO.File]::ReadAllText($e[$iT + 1]); return @{ Ok = $true; Codigo = 0; Saida = '' } }
            if ($iQ -ge 0) { $nome = ($e[$iQ + 1] -replace '^\+DELE ', ''); $global:remotoFake.Remove($chave + $nome); return @{ Ok = $true; Codigo = 0; Saida = '' } }
            if ($iO -ge 0) { if ($global:remotoFake.ContainsKey($chave)) { [IO.File]::WriteAllText($e[$iO + 1], $global:remotoFake[$chave]); return @{ Ok = $true; Codigo = 0; Saida = '' } } return @{ Ok = $false; Codigo = 78; Saida = 'nao existe' } }
            return @{ Ok = $true; Codigo = 0; Saida = '' }
        }
        $script:cfgF = [pscustomobject]@{ servidor = 'h'; porta = 21; protocolo = 'ftp'; usuario = 'u'; pasta = 'site'; url_publica = 'https://x'; certificado = 'estrito'; Senha = (ConvertTo-SenhaSegura 'x') }
        $pk = Join-Path $TestDrive 'pk'
        if (Test-Path $pk) { Remove-Item $pk -Recurse -Force }
        $null = New-Item -ItemType Directory -Path "$pk\_app\lib", "$pk\_app\dados" -Force
        Set-Content "$pk\index.php" 'NOVO' -Encoding ASCII -NoNewline; Set-Content "$pk\_app\lib\db.php" 'DB NOVO' -Encoding ASCII -NoNewline
        Set-Content "$pk\_app\lib\novo.php" 'NOVO ARQ' -Encoding ASCII -NoNewline; Set-Content "$pk\_app\config.php" 'PERIGO' -Encoding ASCII -NoNewline
        $script:arqF = @(Get-ArquivosPublicacao $pk)
    }
    It 'faz backup do que existia, envia o novo e nao toca no config.php' {
        $bak = Join-Path $TestDrive 'bak1'
        $m = Publish-Arquivos -Cfg $script:cfgF -Arquivos $script:arqF -PastaBackup $bak
        $global:remotoFake['site/index.php'] | Should Be 'NOVO'
        $global:remotoFake['site/_app/lib/novo.php'] | Should Be 'NOVO ARQ'
        $global:remotoFake['site/_app/config.php'] | Should Be 'SEGREDO'
        (Get-Content (Join-Path $bak 'index.php') -Raw) | Should Be 'ANTIGO'
        Test-Path (Join-Path $bak '_app\lib\novo.php') | Should Be $false
        (($m | ForEach-Object { "$($_.rel):$($_.existia)" }) -join ',') | Should Be '_app/lib/db.php:True,_app/lib/novo.php:False,index.php:True'
        ([string]$global:chamadasFake[$global:chamadasFake.Count - 1]).EndsWith('site/index.php') | Should Be $true
    }
    It 'reverter volta o que existia e apaga o que era novo' {
        $bak = Join-Path $TestDrive 'bak2'
        $null = Publish-Arquivos -Cfg $script:cfgF -Arquivos $script:arqF -PastaBackup $bak
        $r = Undo-Publicacao -Cfg $script:cfgF -PastaBackup $bak
        $r.Revertidos | Should Be 3; @($r.Falhas).Count | Should Be 0
        $global:remotoFake['site/index.php'] | Should Be 'ANTIGO'; $global:remotoFake['site/_app/lib/db.php'] | Should Be 'DB ANTIGO'
        $global:remotoFake.ContainsKey('site/_app/lib/novo.php') | Should Be $false
    }
    It 'simular nao fala com o servidor' {
        $null = Publish-Arquivos -Cfg $script:cfgF -Arquivos $script:arqF -PastaBackup (Join-Path $TestDrive 'bak3') -Simular
        $global:chamadasFake.Count | Should Be 0
        $global:remotoFake['site/index.php'] | Should Be 'ANTIGO'
    }
    It 'se um envio falhar, avisa e o manifesto ja permite reverter o que foi enviado' {
        $bak = Join-Path $TestDrive 'bak4'
        Mock -ModuleName Publicacao Invoke-CurlFtp {
            $e = @($Extra); $chave = ([uri]$Url).AbsolutePath.TrimStart('/')
            $iT = [array]::IndexOf($e, '-T'); $iO = [array]::IndexOf($e, '-o')
            if ($iT -ge 0 -and $chave -like '*novo.php') { return @{ Ok = $false; Codigo = 55; Saida = 'queda de conexao' } }
            if ($iT -ge 0) { $global:remotoFake[$chave] = [IO.File]::ReadAllText($e[$iT + 1]); return @{ Ok = $true; Codigo = 0; Saida = '' } }
            if ($iO -ge 0) { if ($global:remotoFake.ContainsKey($chave)) { [IO.File]::WriteAllText($e[$iO + 1], $global:remotoFake[$chave]); return @{ Ok = $true; Codigo = 0; Saida = '' } } return @{ Ok = $false; Codigo = 78; Saida = '' } }
            return @{ Ok = $true; Codigo = 0; Saida = '' }
        }
        { Publish-Arquivos -Cfg $script:cfgF -Arquivos $script:arqF -PastaBackup $bak } | Should Throw 'novo.php'
        $global:remotoFake['site/index.php'] | Should Be 'ANTIGO'   # index.php vai por ultimo: a versao antiga continua no ar
        Test-Path (Join-Path $bak 'manifesto.json') | Should Be $true
    }
}
