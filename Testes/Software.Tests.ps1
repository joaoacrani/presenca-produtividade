# Testes da instalacao de software no agent (manifesto assinado, hash, execucao, resultado).
# Rodar:  Invoke-Pester .\Testes\Software.Tests.ps1
$raiz = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $raiz 'Agent\Atualizador.psm1') -Force

function Novo-ParDeChaves {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 1024
    $rsa.PersistKeyInCsp = $false
    return @{ Privada = $rsa.ToXmlString($true); Publica = $rsa.ToXmlString($false) }
}
function Assinar-Texto([string]$Texto, [string]$Privada) {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false; $rsa.FromXmlString($Privada)
    return [Convert]::ToBase64String($rsa.SignData([System.Text.Encoding]::UTF8.GetBytes($Texto), 'SHA256'))
}
function Novo-Manifesto([byte[]]$Conteudo, [string]$Tipo = 'cmd', [string]$Arquivo = 'instala.cmd', [string]$Args = '') {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $h = (($sha.ComputeHash($Conteudo) | ForEach-Object { $_.ToString('x2') }) -join '')
    $o = [ordered]@{ v = 2; pid = ([guid]::NewGuid().ToString('N')); nome = 'Teste'; tipo = $Tipo; arquivo = $Arquivo; sha256 = $h; tamanho = $Conteudo.Length; args = $Args; criado = 1 }
    return ($o | ConvertTo-Json -Compress)
}

Describe 'Software: manifesto' {
    $base = [pscustomobject]@{ v = 2; pid = ('a' * 32); tipo = 'msi'; arquivo = 'a.msi'; sha256 = ('b' * 64); tamanho = 10; args = '/qn'; nome = 'x' }
    function Com($campo, $valor) { $c = $base.PSObject.Copy(); $c.$campo = $valor; return $c }
    It 'aceita um manifesto completo' {
        (Test-ManifestoSoftware $base) | Should Be $true
        (Test-ManifestoSoftware (Com 'tipo' 'cmd')) | Should Be $false   # extensao nao bate com o tipo
        (Test-ManifestoSoftware (Com 'arquivo' 'a.CMD')) | Should Be $false
        $cmd = Com 'tipo' 'cmd'; $cmd.arquivo = 'a.bat'
        (Test-ManifestoSoftware $cmd) | Should Be $true
    }
    It 'recusa campos fora do formato' {
        foreach ($c in @(@('v', 1), @('pid', 'abc'), @('pid', ('A' * 32)), @('tipo', 'dll'), @('sha256', 'xyz'), @('tamanho', 0),
                         @('arquivo', '..\x.msi'), @('arquivo', 'a/b.msi'), @('arquivo', 'C:\a.msi'), @('args', ('x' * 1001)))) {
            (Test-ManifestoSoftware (Com $c[0] $c[1])) | Should Be $false
        }
        (Test-ManifestoSoftware $null) | Should Be $false
    }
}

Describe 'Software: comando por tipo' {
    It 'msi, exe, ps1, cmd e vbs' {
        $m = { param($t, $a) [pscustomobject]@{ tipo = $t; args = $a } }
        $r = Get-ComandoSoftware -M (& $m 'msi' '/qn /norestart') -Caminho 'C:\w\a.msi'
        $r.Exe | Should Match 'msiexec\.exe$'; $r.Args | Should Be '/i "C:\w\a.msi" /qn /norestart'
        $r = Get-ComandoSoftware -M (& $m 'exe' '/S') -Caminho 'C:\w\s.exe'
        $r.Exe | Should Be 'C:\w\s.exe'; $r.Args | Should Be '/S'
        $r = Get-ComandoSoftware -M (& $m 'ps1' '-X 1') -Caminho 'C:\w\a.ps1'
        $r.Exe | Should Match 'powershell\.exe$'; $r.Args | Should Match '-ExecutionPolicy Bypass -File "C:\\w\\a\.ps1" -X 1$'
        $r = Get-ComandoSoftware -M (& $m 'cmd' '') -Caminho 'C:\w\a.cmd'
        $r.Exe | Should Match 'cmd\.exe$'; $r.Args | Should Be '/d /c ""C:\w\a.cmd""'
        $r = Get-ComandoSoftware -M (& $m 'vbs' 'a') -Caminho 'C:\w\a.vbs'
        $r.Exe | Should Match 'cscript\.exe$'; $r.Args | Should Be '//nologo "C:\w\a.vbs" a'
        { Get-ComandoSoftware -M (& $m 'dll' '') -Caminho 'x' } | Should Throw
    }
}

Describe 'Software: execucao do processo' {
    It 'devolve codigo e saida' {
        $r = Invoke-ProcessoSoftware -Exe (Join-Path $env:SystemRoot 'System32\cmd.exe') -Argumentos '/d /c "echo ola mundo & exit /b 3"' -Pasta $env:TEMP -TimeoutSeg 20
        $r.Codigo | Should Be 3
        $r.Saida | Should Be 'ola mundo'
        $r.TempoEsgotado | Should Be $false
    }
    It 'encerra o que passa do tempo' {
        $r = Invoke-ProcessoSoftware -Exe (Join-Path $env:SystemRoot 'System32\cmd.exe') -Argumentos '/d /c "ping -n 30 127.0.0.1 >nul"' -Pasta $env:TEMP -TimeoutSeg 1
        $r.TempoEsgotado | Should Be $true
        $r.Codigo | Should Be -1
        $r.Saida | Should Match 'tempo esgotado'
    }
    It 'corta a saida muito longa' {
        $r = Invoke-ProcessoSoftware -Exe (Join-Path $env:SystemRoot 'System32\cmd.exe') -Argumentos '/d /c "for /l %i in (1,1,600) do @echo linha-numero-%i-xxxxxxxxxx"' -Pasta $env:TEMP -TimeoutSeg 30
        $r.Saida.Length | Should BeLessThan 3600
        $r.Saida | Should Match 'linha-numero-600'
    }
}

Describe 'Software: tarefas (assinatura, hash e resultado)' {
    $chaves = Novo-ParDeChaves
    $outra = Novo-ParDeChaves
    $conteudo = [System.Text.Encoding]::ASCII.GetBytes("@echo off`r`necho instalando`r`nexit /b 0`r`n")

    function Rodar($tarefa, [byte[]]$baixar, [string]$token = 'ppm_abc') {
        $global:swResp = @($tarefa)
        $global:swBaixar = $baixar
        $global:swLog = New-Object System.Collections.ArrayList
        $global:swBaixou = 0
        Mock -ModuleName Atualizador Invoke-RestMethod { [pscustomobject]@{ tarefas = $global:swResp } }
        Mock -ModuleName Atualizador Send-ResultadoSoftware { [void]$global:swLog.Add(@{ id = $Id; estado = $Estado; codigo = $Codigo; saida = $Saida }); $true }
        Mock -ModuleName Atualizador Receive-ArquivoSoftware { $global:swBaixou++; [System.IO.File]::WriteAllBytes($Destino, $global:swBaixar) }
        $r = Invoke-TarefasSoftware -Servidor 'https://x.example/p' -Token $token -ChavePublicaXml $chaves.Publica -PastaBase (Join-Path $TestDrive 'sw')
        return $r
    }
    function Tarefa($manifesto, $privada = $chaves.Privada) {
        $m = $manifesto | ConvertFrom-Json
        return [pscustomobject]@{ id = 7; pid = [string]$m.pid; manifesto = $manifesto; assinatura = (Assinar-Texto $manifesto $privada) }
    }

    It 'executa o pacote assinado cujo arquivo confere e informa ok' {
        $man = Novo-Manifesto $conteudo
        (Rodar (Tarefa $man) $conteudo) | Should Be 'executadas-1'
        $global:swLog.Count | Should Be 2
        $global:swLog[0].estado | Should Be 'executando'
        $global:swLog[1].estado | Should Be 'ok'
        $global:swLog[1].codigo | Should Be 0
        $global:swLog[1].saida | Should Match 'instalando'
        (Get-ChildItem (Join-Path $TestDrive 'sw') -ErrorAction SilentlyContinue | Measure-Object).Count | Should Be 0   # limpou a pasta de trabalho
    }
    It 'codigo de saida de falha vira falhou, e 3010 (reinicio) vira ok' {
        $falha = [System.Text.Encoding]::ASCII.GetBytes("@exit /b 1603`r`n")
        (Rodar (Tarefa (Novo-Manifesto $falha)) $falha) | Should Be 'executadas-1'
        $global:swLog[1].estado | Should Be 'falhou'; $global:swLog[1].codigo | Should Be 1603
        $reinicio = [System.Text.Encoding]::ASCII.GetBytes("@exit /b 3010`r`n")
        (Rodar (Tarefa (Novo-Manifesto $reinicio)) $reinicio) | Should Be 'executadas-1'
        $global:swLog[1].estado | Should Be 'ok'; $global:swLog[1].saida | Should Match 'reinicio pendente'
    }
    It 'assinatura de outra chave: nao baixa nem executa' {
        $man = Novo-Manifesto $conteudo
        (Rodar (Tarefa $man $outra.Privada) $conteudo) | Should Be 'executadas-1'
        $global:swBaixou | Should Be 0
        $global:swLog[1].estado | Should Be 'falhou'
        $global:swLog[1].saida | Should Match 'assinatura'
    }
    It 'manifesto alterado depois de assinado: nao executa' {
        $man = Novo-Manifesto $conteudo
        $t = Tarefa $man
        $t.manifesto = $man.Replace('"args":""', '"args":"& calc"')
        $t.manifesto | Should Not Be $man
        (Rodar $t $conteudo) | Should Be 'executadas-1'
        $global:swBaixou | Should Be 0
        $global:swLog[1].estado | Should Be 'falhou'
    }
    It 'arquivo trocado no servidor (hash diferente): nao executa' {
        $man = Novo-Manifesto $conteudo
        $troca = [System.Text.Encoding]::ASCII.GetBytes("@echo off`r`necho malicioso!`r`nexit /b 0`r`n")
        $troca.Length | Should Be $conteudo.Length   # mesmo tamanho: so o hash pega
        (Rodar (Tarefa $man) $troca) | Should Be 'executadas-1'
        $global:swLog[1].estado | Should Be 'falhou'
        $global:swLog[1].saida | Should Match 'SHA-256'
        $global:swLog[1].saida | Should Not Match 'malicioso'
    }
    It 'sem token proprio da maquina nao faz nada' {
        (Rodar (Tarefa (Novo-Manifesto $conteudo)) $conteudo 'token-de-cadastro') | Should Be 'sem-token'
        $global:swLog.Count | Should Be 0
    }
    It 'se o servidor nao deixa reservar a tarefa (outra rodada pegou), nao executa' {
        $global:swResp = @(Tarefa (Novo-Manifesto $conteudo))
        $global:swLog = New-Object System.Collections.ArrayList
        Mock -ModuleName Atualizador Invoke-RestMethod { [pscustomobject]@{ tarefas = $global:swResp } }
        Mock -ModuleName Atualizador Send-ResultadoSoftware { [void]$global:swLog.Add($Estado); $false }
        Mock -ModuleName Atualizador Receive-ArquivoSoftware { throw 'nao devia baixar' }
        (Invoke-TarefasSoftware -Servidor 'https://x.example/p' -Token 'ppm_abc' -ChavePublicaXml $chaves.Publica -PastaBase (Join-Path $TestDrive 'sw')) | Should Be 'executadas-0'
        ($global:swLog -join ',') | Should Be 'executando'
    }
}

Describe 'Software: tarefa agendada e arquivos' {
    It 'a tarefa roda como SYSTEM a cada 15 min com o modo -Software' {
        $x = New-XmlTarefaSoftware -Script 'C:\Program Files\PresencaAgente\Atualizar-Agente.ps1'
        $x | Should Match 'S-1-5-18'
        $x | Should Match 'PT15M'
        $x | Should Match '-Software'
        { [xml]$x } | Should Not Throw
    }
    It 'o atualizador remove a tarefa de software ao desinstalar' {
        (Get-Content (Join-Path $raiz 'Agent\Atualizador.psm1') -Raw) | Should Match "'PresencaAgenteSoftware'\),"
    }
    It 'os arquivos do agent continuam so ASCII (PowerShell 5.1)' {
        foreach ($f in 'Agent\Atualizador.psm1', 'Agent\Atualizar-Agente.ps1') {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $raiz $f))
            (@($bytes | Where-Object { $_ -gt 127 }).Count) | Should Be 0
        }
    }
    It 'a versao do agent subiu para 1.7.0' {
        ((Get-Content (Join-Path $raiz 'Agent\versao.txt') -Raw).Trim()) | Should Be '1.7.0'
    }
}

# ---------- v1.7.0: pacote zip, gatilho, desinstalacao ----------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Novo-Zip([string]$Caminho, $Arquivos) {   # $Arquivos: hashtable nome-no-zip => texto
    $fs = [System.IO.File]::Create($Caminho)
    $z = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    foreach ($k in $Arquivos.Keys) {
        $e = $z.CreateEntry($k)
        $w = New-Object System.IO.StreamWriter($e.Open())
        $w.Write([string]$Arquivos[$k]); $w.Dispose()
    }
    $z.Dispose(); $fs.Dispose()
}
function Novo-ManifestoV2([byte[]]$Conteudo, $Campos) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $h = (($sha.ComputeHash($Conteudo) | ForEach-Object { $_.ToString('x2') }) -join '')
    $o = [ordered]@{ v = 2; pid = ([guid]::NewGuid().ToString('N')); nome = 'Teste v2'; tipo = 'zip'; arquivo = 'pacote.zip'; sha256 = $h; tamanho = $Conteudo.Length; args = ''; criado = 1 }
    foreach ($k in $Campos.Keys) { $o[$k] = $Campos[$k] }
    return ($o | ConvertTo-Json -Compress -Depth 5)
}

Describe 'Software v2: manifesto do zip, gatilho e desinstalacao' {
    $base = [pscustomobject]@{ v = 2; pid = ('a' * 32); tipo = 'zip'; arquivo = 'p.zip'; executavel = 'installer/setup.msi'; sha256 = ('b' * 64); tamanho = 10; args = '/qn'; nome = 'x' }
    function Com($campo, $valor) { $c = $base.PSObject.Copy(); $c | Add-Member -NotePropertyName $campo -NotePropertyValue $valor -Force; return $c }
    It 'aceita zip com executavel valido e recusa o resto' {
        (Test-ManifestoSoftware $base) | Should Be $true
        foreach ($ruim in @('', '../x.msi', 'C:/x.msi', '/x.msi', 'a\b.msi', 'a/nul.cmd', 'a/b.dll', 'a//b.msi', 'a/b.msi ')) {
            (Test-ManifestoSoftware (Com 'executavel' $ruim)) | Should Be $false
        }
        (Test-ManifestoSoftware (Com 'arquivo' 'p.msi')) | Should Be $false     # zip precisa terminar em .zip
    }
    It 'executavel fora de pacote zip e recusado' {
        $m = [pscustomobject]@{ v = 2; pid = ('a' * 32); tipo = 'msi'; arquivo = 'a.msi'; executavel = 'x.msi'; sha256 = ('b' * 64); tamanho = 10; args = ''; nome = 'x' }
        (Test-ManifestoSoftware $m) | Should Be $false
    }
    It 'gatilho: caminho completo com variaveis, sem curinga nem ..' {
        foreach ($ok in '[programfiles]\App\app.exe', '[ProgramFiles(x86)]\App\a.exe', '[programdata]\x\y.txt', 'C:\Program Files\App\a.exe') { (Test-GatilhoSoftware $ok) | Should Be $true }
        foreach ($ruim in '', 'app.exe', '\\srv\share\a.exe', '[programfiles]\..\x.exe', '[programfiles]\App\*.exe', '[outra]\a.exe', 'C:a.exe', '[programfiles]App') { (Test-GatilhoSoftware $ruim) | Should Be $false }
        (Test-ManifestoSoftware (Com 'gatilho' '[programfiles]\A\a.exe')) | Should Be $true
        (Test-ManifestoSoftware (Com 'gatilho' '..\a.exe')) | Should Be $false
    }
    It 'as variaveis do gatilho viram os caminhos desta maquina' {
        (Expand-GatilhoSoftware '[programfiles]\A\a.exe') | Should Match '^[A-Za-z]:\\.*Program Files\\A\\a\.exe$'
        (Expand-GatilhoSoftware '[PROGRAMDATA]\x.txt') | Should Be (Join-Path $env:ProgramData 'x.txt')
        (Expand-GatilhoSoftware '[windir]\x') | Should Be (Join-Path $env:SystemRoot 'x')
    }
    It 'desinstalacao: modos msi, nome e script validados' {
        (Test-ManifestoSoftware (Com 'desinstalar' ([pscustomobject]@{ modo = 'msi'; codigo = '{6B1F2D4E-1A2B-4C3D-8E9F-0123456789AB}' }))) | Should Be $true
        (Test-ManifestoSoftware (Com 'desinstalar' ([pscustomobject]@{ modo = 'msi'; codigo = 'qualquer' }))) | Should Be $false
        (Test-ManifestoSoftware (Com 'desinstalar' ([pscustomobject]@{ modo = 'nome'; software = 'OpenVPN' }))) | Should Be $true
        (Test-ManifestoSoftware (Com 'desinstalar' ([pscustomobject]@{ modo = 'nome'; software = '' }))) | Should Be $false
        (Test-ManifestoSoftware (Com 'desinstalar' ([pscustomobject]@{ modo = 'script'; arquivo = 'installer/remover.cmd' }))) | Should Be $true
        (Test-ManifestoSoftware (Com 'desinstalar' ([pscustomobject]@{ modo = 'script'; arquivo = 'installer/remover.exe' }))) | Should Be $false
        (Test-ManifestoSoftware (Com 'desinstalar' ([pscustomobject]@{ modo = 'formatar' }))) | Should Be $false
    }
}

Describe 'Software v2: zip extraido com seguranca' {
    It 'extrai arquivos e pastas' {
        $z = Join-Path $TestDrive 'ok.zip'; $d = Join-Path $TestDrive 'ok'
        Novo-Zip $z @{ 'installer/setup.cmd' = 'echo oi'; 'installer/config/Escritorio.ovpn' = 'client'; 'leia-me.txt' = 'x' }
        $l = Expand-ZipSeguro -Zip $z -Destino $d
        @($l).Count | Should Be 3
        (Get-Content -Raw (Join-Path $d 'installer\config\Escritorio.ovpn')) | Should Be 'client'
    }
    It 'recusa zip-slip e nomes perigosos sem gravar nada' {
        $i = 0
        foreach ($nome in '../fora.txt', 'a/../../fora.txt', 'C:/fora.txt', '/fora.txt', 'nul.txt', 'a\b.txt', '.hidden/../../x', 'a:b.txt') {
            $i++
            $z = Join-Path $TestDrive "ruim$i.zip"; $d = Join-Path $TestDrive "ruim$i"
            Novo-Zip $z @{ 'bom.txt' = 'ok'; $nome = 'malicioso' }
            { Expand-ZipSeguro -Zip $z -Destino $d } | Should Throw
            (Test-Path (Join-Path $d 'bom.txt')) | Should Be $false      # valida tudo antes de gravar qualquer coisa
            (Test-Path (Join-Path $TestDrive 'fora.txt')) | Should Be $false
        }
    }
}

Describe 'Software v2: tarefas com zip, gatilho e desinstalacao' {
    $chaves = Novo-ParDeChaves
    function Rodar2($manifesto, [byte[]]$baixar, [string]$acao = 'instalar') {
        $m = $manifesto | ConvertFrom-Json
        $t = [pscustomobject]@{ id = 9; pid = [string]$m.pid; acao = $acao; manifesto = $manifesto; assinatura = (Assinar-Texto $manifesto $chaves.Privada) }
        $global:swResp = @($t); $global:swBaixar = $baixar; $global:swLog = New-Object System.Collections.ArrayList; $global:swBaixou = 0
        Mock -ModuleName Atualizador Invoke-RestMethod { [pscustomobject]@{ tarefas = $global:swResp } }
        Mock -ModuleName Atualizador Send-ResultadoSoftware { [void]$global:swLog.Add(@{ id = $Id; estado = $Estado; codigo = $Codigo; saida = $Saida }); $true }
        Mock -ModuleName Atualizador Receive-ArquivoSoftware { $global:swBaixou++; [System.IO.File]::WriteAllBytes($Destino, $global:swBaixar) }
        return (Invoke-TarefasSoftware -Servidor 'https://x.example/p' -Token 'ppm_abc' -ChavePublicaXml $chaves.Publica -PastaBase (Join-Path $TestDrive 'sw2'))
    }
    function ZipBytes($arquivos) { $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.zip'); Novo-Zip $p $arquivos; return [System.IO.File]::ReadAllBytes($p) }

    It 'zip: extrai, roda o script de dentro (com os arquivos ao lado) e informa ok' {
        $alvo = Join-Path $env:TEMP ('swzip-' + [guid]::NewGuid().ToString('N') + '.txt')
        $bytes = ZipBytes @{ 'installer/instalar.cmd' = "@echo off`r`ncopy /y `"%~dp0config\perfil.txt`" `"%~1`" >nul`r`necho copiado`r`nexit /b 0`r`n"; 'installer/config/perfil.txt' = 'perfil-do-escritorio' }
        try {
            $man = Novo-ManifestoV2 $bytes @{ executavel = 'installer/instalar.cmd'; args = "`"$alvo`"" }
            (Rodar2 $man $bytes) | Should Be 'executadas-1'
            $global:swLog[1].estado | Should Be 'ok'
            $global:swLog[1].saida | Should Match 'copiado'
            (Get-Content -Raw $alvo) | Should Be 'perfil-do-escritorio'
            (Get-ChildItem (Join-Path $TestDrive 'sw2') -ErrorAction SilentlyContinue | Measure-Object).Count | Should Be 0
        } finally { Remove-Item $alvo -Force -ErrorAction SilentlyContinue }
    }
    It 'zip com nome de arquivo perigoso: falha sem executar' {
        $bytes = ZipBytes @{ 'installer/instalar.cmd' = '@exit /b 0'; '../fora.txt' = 'x' }
        $man = Novo-ManifestoV2 $bytes @{ executavel = 'installer/instalar.cmd' }
        (Rodar2 $man $bytes) | Should Be 'executadas-1'
        $global:swLog[1].estado | Should Be 'falhou'
        $global:swLog[1].saida | Should Match 'nao permitido'
    }
    It 'zip sem o executavel indicado: falha' {
        $bytes = ZipBytes @{ 'installer/outro.cmd' = '@exit /b 0' }
        $man = Novo-ManifestoV2 $bytes @{ executavel = 'installer/instalar.cmd' }
        (Rodar2 $man $bytes) | Should Be 'executadas-1'
        $global:swLog[1].estado | Should Be 'falhou'; $global:swLog[1].saida | Should Match 'nao existe dentro do zip'
    }
    It 'gatilho ja existe: ignora a instalacao sem baixar nada' {
        $trig = Join-Path $env:TEMP ('gatilho-' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -Path $trig -Value 'x'
        try {
            $bytes = ZipBytes @{ 'a.cmd' = '@exit /b 1' }
            $man = Novo-ManifestoV2 $bytes @{ executavel = 'a.cmd'; gatilho = $trig }
            (Rodar2 $man $bytes) | Should Be 'executadas-1'
            $global:swBaixou | Should Be 0
            $global:swLog[1].estado | Should Be 'ok'; $global:swLog[1].saida | Should Match 'ignorada'
        } finally { Remove-Item $trig -Force -ErrorAction SilentlyContinue }
    }
    It 'gatilho que nao aparece depois da instalacao vira falha' {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("@exit /b 0`r`n")
        $man = Novo-Manifesto $bytes 'cmd' 'a.cmd'
        $o = $man | ConvertFrom-Json; $o.v = 2; $o | Add-Member -NotePropertyName gatilho -NotePropertyValue 'C:\nao-existe-swtest\app.exe'
        $man = $o | ConvertTo-Json -Compress
        (Rodar2 $man $bytes) | Should Be 'executadas-1'
        $global:swLog[1].estado | Should Be 'falhou'; $global:swLog[1].saida | Should Match 'gatilho nao apareceu'
    }
    It 'desinstalar por script do pacote' {
        $alvo = Join-Path $env:TEMP ('swrem-' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -Path $alvo -Value 'instalado'
        $bytes = ZipBytes @{ 'instalar.cmd' = '@exit /b 0'; 'remover.cmd' = "@del /q `"%~1`"`r`n@echo removido`r`n@exit /b 0`r`n" }
        try {
            $man = Novo-ManifestoV2 $bytes @{ executavel = 'instalar.cmd'; desinstalar = [ordered]@{ modo = 'script'; arquivo = 'remover.cmd'; args = "`"$alvo`"" } }
            (Rodar2 $man $bytes 'desinstalar') | Should Be 'executadas-1'
            $global:swLog[1].estado | Should Be 'ok'; $global:swLog[1].saida | Should Match 'removido'
            (Test-Path $alvo) | Should Be $false
        } finally { Remove-Item $alvo -Force -ErrorAction SilentlyContinue }
    }
    It 'desinstalar por codigo MSI usa msiexec /x e nao baixa o pacote' {
        $bytes = ZipBytes @{ 'a.cmd' = '@exit /b 0' }
        $man = Novo-ManifestoV2 $bytes @{ executavel = 'a.cmd'; desinstalar = [ordered]@{ modo = 'msi'; codigo = '{6B1F2D4E-1A2B-4C3D-8E9F-0123456789AB}' } }
        $global:swCmd = $null
        Mock -ModuleName Atualizador Invoke-ProcessoSoftware { $global:swCmd = "$Exe|$Argumentos"; @{ Codigo = 0; Saida = 'ok'; TempoEsgotado = $false } }
        (Rodar2 $man $bytes 'desinstalar') | Should Be 'executadas-1'
        $global:swBaixou | Should Be 0
        $global:swCmd | Should Match 'msiexec\.exe\|/x \{6B1F2D4E-1A2B-4C3D-8E9F-0123456789AB\} /qn /norestart$'
        $global:swLog[1].estado | Should Be 'ok'
    }
    It 'desinstalar por nome: programa ausente e ignorado; achado roda o desinstalador' {
        $bytes = ZipBytes @{ 'a.cmd' = '@exit /b 0' }
        $man = Novo-ManifestoV2 $bytes @{ executavel = 'a.cmd'; desinstalar = [ordered]@{ modo = 'nome'; software = 'Programa Teste' } }
        Mock -ModuleName Atualizador Get-ProgramaInstalado { @() }
        (Rodar2 $man $bytes 'desinstalar') | Should Be 'executadas-1'
        $global:swLog[1].estado | Should Be 'ok'; $global:swLog[1].saida | Should Match 'ignorada'
        $global:swCmd = $null
        Mock -ModuleName Atualizador Get-ProgramaInstalado { @([pscustomobject]@{ DisplayName = 'Programa Teste'; UninstallString = 'MsiExec.exe /X{6B1F2D4E-1A2B-4C3D-8E9F-0123456789AB}'; QuietUninstallString = $null }) }
        Mock -ModuleName Atualizador Invoke-ProcessoSoftware { $global:swCmd = "$Exe|$Argumentos"; @{ Codigo = 0; Saida = ''; TempoEsgotado = $false } }
        (Rodar2 $man $bytes 'desinstalar') | Should Be 'executadas-1'
        $global:swCmd | Should Match '/x \{6B1F2D4E-1A2B-4C3D-8E9F-0123456789AB\} /qn /norestart$'
        $global:swLog[1].estado | Should Be 'ok'
    }
    It 'acao desinstalar em pacote sem desinstalacao definida: falha' {
        $bytes = ZipBytes @{ 'a.cmd' = '@exit /b 0' }
        $man = Novo-ManifestoV2 $bytes @{ executavel = 'a.cmd' }
        (Rodar2 $man $bytes 'desinstalar') | Should Be 'executadas-1'
        $global:swLog[1].estado | Should Be 'falhou'; $global:swLog[1].saida | Should Match 'desinstalacao'
    }
}

Describe 'Software v2: desinstalador lido do registro' {
    It 'MSI vira msiexec /x com os parametros silenciosos' {
        $c = Get-ComandoDesinstalarPrograma -Programa ([pscustomobject]@{ UninstallString = 'MsiExec.exe /I{6B1F2D4E-1A2B-4C3D-8E9F-0123456789AB}'; QuietUninstallString = $null })
        $c.Exe | Should Match 'msiexec\.exe$'; $c.Args | Should Be '/x {6B1F2D4E-1A2B-4C3D-8E9F-0123456789AB} /qn /norestart'
    }
    It 'sem forma silenciosa e sem parametros do administrador: nao executa' {
        { Get-ComandoDesinstalarPrograma -Programa ([pscustomobject]@{ UninstallString = '"C:\Windows\System32\cmd.exe" /c x'; QuietUninstallString = $null }) } | Should Throw 'silenciosa'
    }
    It 'usa o QuietUninstallString e junta os parametros extras' {
        $c = Get-ComandoDesinstalarPrograma -Programa ([pscustomobject]@{ UninstallString = 'x'; QuietUninstallString = '"C:\Windows\System32\cmd.exe" /c exit' }) -ArgsExtra '/extra'
        $c.Exe | Should Be 'C:\Windows\System32\cmd.exe'; $c.Args | Should Be '/c exit /extra'
    }
    It 'separa caminho e argumentos com e sem aspas' {
        $a = Split-ComandoTexto '"C:\Program Files\X\un.exe" /S /v"/qn"'
        $a.Exe | Should Be 'C:\Program Files\X\un.exe'; $a.Args | Should Be '/S /v"/qn"'
        $b = Split-ComandoTexto 'C:\X\un.exe /S'
        $b.Exe | Should Be 'C:\X\un.exe'; $b.Args | Should Be '/S'
        { Split-ComandoTexto 'rundll32 foo' } | Should Throw
    }
}
