# Testes do atualizador automatico do agent (assinatura, whitelist, anti-downgrade, rollback).
# Rodar:  Invoke-Pester .\Testes\Atualizador.Tests.ps1
$raiz = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $raiz 'Agent\Atualizador.psm1') -Force

function Novo-ParDeChaves {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 1024
    $rsa.PersistKeyInCsp = $false
    return @{ Privada = $rsa.ToXmlString($true); Publica = $rsa.ToXmlString($false) }
}
function Novo-Zip([hashtable]$Arquivos) {
    Add-Type -AssemblyName System.IO.Compression
    $ms = New-Object System.IO.MemoryStream
    $z = New-Object System.IO.Compression.ZipArchive ($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($n in $Arquivos.Keys) {
        $b = [System.Text.Encoding]::UTF8.GetBytes([string]$Arquivos[$n])
        $e = $z.CreateEntry($n); $s = $e.Open(); $s.Write($b, 0, $b.Length); $s.Dispose()
    }
    $z.Dispose(); $r = $ms.ToArray(); $ms.Dispose()
    return , $r
}
function Assinar([byte[]]$Bytes, [string]$Privada) {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false; $rsa.FromXmlString($Privada)
    return [Convert]::ToBase64String($rsa.SignData($Bytes, 'SHA256'))
}
# Monta um "PC" de teste: pasta instalada na versao $VersaoInstalada e um pacote na pasta de entrada
function Novo-Cenario($Pasta, $Chaves, $VersaoInstalada, $Zip, [string]$Assinatura, [string]$VersaoManifesto) {
    $dest = Join-Path $Pasta 'PresencaAgente'; $dados = Join-Path $Pasta 'dados'; $entrada = Join-Path $dados 'entrada'
    $null = New-Item -ItemType Directory -Path $dest, $entrada -Force
    Set-Content (Join-Path $dest 'versao.txt') $VersaoInstalada -Encoding ASCII
    Set-Content (Join-Path $dest 'Detectar-Presenca.ps1') '# antigo' -Encoding UTF8
    Set-Content (Join-Path $dest 'chave-publica.xml') $Chaves.Publica -Encoding UTF8
    [System.IO.File]::WriteAllBytes((Join-Path $entrada 'pacote.zip'), $Zip)
    @{ versao = $VersaoManifesto; sha256 = (Get-Sha256Hex $Zip); assinatura = $Assinatura } | ConvertTo-Json | Set-Content (Join-Path $entrada 'manifest.json') -Encoding UTF8
    return @{ Destino = $dest; Dados = $dados }
}
function Texto($caminho) { (Get-Content $caminho -Raw).Trim() }

Describe 'Atualizador: assinatura' {
    $k = Novo-ParDeChaves; $outra = Novo-ParDeChaves
    $conteudo = [System.Text.Encoding]::UTF8.GetBytes('conteudo do pacote')
    $sig = Assinar $conteudo $k.Privada
    It 'aceita assinatura correta' { Test-AssinaturaPacote $conteudo $sig $k.Publica | Should Be $true }
    It 'rejeita conteudo adulterado' { Test-AssinaturaPacote ([System.Text.Encoding]::UTF8.GetBytes('conteudo do pacotE')) $sig $k.Publica | Should Be $false }
    It 'rejeita assinatura de outra chave' { Test-AssinaturaPacote $conteudo (Assinar $conteudo $outra.Privada) $k.Publica | Should Be $false }
    It 'rejeita assinatura vazia ou lixo sem estourar erro' {
        Test-AssinaturaPacote $conteudo '' $k.Publica | Should Be $false
        Test-AssinaturaPacote $conteudo 'nao-e-base64!!' $k.Publica | Should Be $false
    }
}

Describe 'Atualizador: conteudo do pacote' {
    It 'le arquivos permitidos' {
        $r = Read-EntradasPacote (Novo-Zip @{ 'versao.txt' = '2.0.0'; 'Presenca.psm1' = '# x' })
        $r.Count | Should Be 2
    }
    It 'rejeita arquivo fora da lista' {
        { Read-EntradasPacote (Novo-Zip @{ 'versao.txt' = '2.0.0'; 'malware.ps1' = '# x' }) } | Should Throw 'nao permitido'
    }
    It 'rejeita caminho com pasta ou ..' {
        { Read-EntradasPacote (Novo-Zip @{ '..\Presenca.psm1' = '# x' }) } | Should Throw 'nao permitido'
        { Read-EntradasPacote (Novo-Zip @{ 'sub/versao.txt' = '2.0.0' }) } | Should Throw 'nao permitido'
    }
    It 'nao deixa o pacote trocar o agente.json (token/servidor)' {
        { Read-EntradasPacote (Novo-Zip @{ 'agente.json' = '{}' }) } | Should Throw 'nao permitido'
    }
}

Describe 'Atualizador: ciclo completo' {
    $k = Novo-ParDeChaves
    $ok = { param($p) $true }
    $falha = { param($p) $false }
    $novo = @{ 'versao.txt' = '1.2.0'; 'Detectar-Presenca.ps1' = '# novo' }

    It 'instala pacote assinado e mais novo' {
        $zip = Novo-Zip $novo
        $c = Novo-Cenario (Join-Path $TestDrive 'a') $k '1.1.0' $zip (Assinar $zip $k.Privada) '1.2.0'
        (Invoke-CicloAtualizacao -Destino $c.Destino -PastaDados $c.Dados -Fumaca $ok) | Should Be 'atualizado-para 1.2.0'
        Texto (Join-Path $c.Destino 'versao.txt') | Should Be '1.2.0'
        Texto (Join-Path $c.Destino 'Detectar-Presenca.ps1') | Should Be '# novo'
        @(Get-ChildItem (Join-Path $c.Dados 'entrada') -Force).Count | Should Be 0; Test-Path (Join-Path $c.Dados 'entrada') | Should Be $true
    }
    It 'recusa assinatura invalida e nao muda nada' {
        $zip = Novo-Zip $novo
        $outra = Novo-ParDeChaves
        $c = Novo-Cenario (Join-Path $TestDrive 'b') $k '1.1.0' $zip (Assinar $zip $outra.Privada) '1.2.0'
        (Invoke-CicloAtualizacao -Destino $c.Destino -PastaDados $c.Dados -Fumaca $ok) | Should Be 'rejeitada'
        Texto (Join-Path $c.Destino 'versao.txt') | Should Be '1.1.0'
        Texto (Join-Path $c.Destino 'Detectar-Presenca.ps1') | Should Be '# antigo'
    }
    It 'nao instala versao igual ou anterior (anti-downgrade)' {
        $zip = Novo-Zip @{ 'versao.txt' = '1.0.0'; 'Detectar-Presenca.ps1' = '# velho' }
        $c = Novo-Cenario (Join-Path $TestDrive 'c') $k '1.1.0' $zip (Assinar $zip $k.Privada) '1.0.0'
        (Invoke-CicloAtualizacao -Destino $c.Destino -PastaDados $c.Dados -Fumaca $ok) | Should Be 'sem-novidade'
        Texto (Join-Path $c.Destino 'Detectar-Presenca.ps1') | Should Be '# antigo'
    }
    It 'manifesto mentindo a versao (pacote velho assinado + manifesto novo) e recusado' {
        $zip = Novo-Zip @{ 'versao.txt' = '1.0.0'; 'Detectar-Presenca.ps1' = '# velho' }
        $c = Novo-Cenario (Join-Path $TestDrive 'd') $k '1.1.0' $zip (Assinar $zip $k.Privada) '9.9.9'
        (Invoke-CicloAtualizacao -Destino $c.Destino -PastaDados $c.Dados -Fumaca $ok) | Should Be 'rejeitada'
        Texto (Join-Path $c.Destino 'versao.txt') | Should Be '1.1.0'
        Texto (Join-Path $c.Destino 'Detectar-Presenca.ps1') | Should Be '# antigo'
    }
    It 'desfaz tudo (rollback) se o teste de fumaca falhar, e nao tenta a mesma versao de novo' {
        $zip = Novo-Zip $novo
        $c = Novo-Cenario (Join-Path $TestDrive 'e') $k '1.1.0' $zip (Assinar $zip $k.Privada) '1.2.0'
        (Invoke-CicloAtualizacao -Destino $c.Destino -PastaDados $c.Dados -Fumaca $falha) | Should Be 'rejeitada'
        Texto (Join-Path $c.Destino 'versao.txt') | Should Be '1.1.0'
        Texto (Join-Path $c.Destino 'Detectar-Presenca.ps1') | Should Be '# antigo'
        # o mesmo pacote reaparece na entrada: nao e tentado de novo
        $entrada = Join-Path $c.Dados 'entrada'
        $null = New-Item -ItemType Directory -Path $entrada -Force
        [System.IO.File]::WriteAllBytes((Join-Path $entrada 'pacote.zip'), $zip)
        @{ versao = '1.2.0'; sha256 = (Get-Sha256Hex $zip); assinatura = (Assinar $zip $k.Privada) } | ConvertTo-Json | Set-Content (Join-Path $entrada 'manifest.json') -Encoding UTF8
        (Invoke-CicloAtualizacao -Destino $c.Destino -PastaDados $c.Dados -Fumaca $ok) | Should Be 'rejeitada'
        Texto (Join-Path $c.Destino 'versao.txt') | Should Be '1.1.0'
    }
    It 'rejeita arquivo com erro de sintaxe antes de tocar no agent' {
        $zip = Novo-Zip @{ 'versao.txt' = '1.3.0'; 'Detectar-Presenca.ps1' = 'function { ((( ' }
        $c = Novo-Cenario (Join-Path $TestDrive 'f') $k '1.1.0' $zip (Assinar $zip $k.Privada) '1.3.0'
        (Invoke-CicloAtualizacao -Destino $c.Destino -PastaDados $c.Dados -Fumaca $ok) | Should Be 'rejeitada'
        Texto (Join-Path $c.Destino 'Detectar-Presenca.ps1') | Should Be '# antigo'
    }
    It 'sem pacote nem servidor: sem novidade' {
        $dest = Join-Path $TestDrive 'g'; $null = New-Item -ItemType Directory -Path $dest -Force
        Set-Content (Join-Path $dest 'versao.txt') '1.1.0' -Encoding ASCII
        (Invoke-CicloAtualizacao -Destino $dest -PastaDados (Join-Path $TestDrive 'gd') -Fumaca $ok) | Should Be 'sem-novidade'
    }
}

Describe 'Atualizador: versao local, tarefa agendada e chave do projeto' {
    It 'sem versao.txt vale 0.0.0 (agents antigos)' { (Get-VersaoLocal (Join-Path $TestDrive 'vazio')).ToString() | Should Be '0.0.0' }
    It 'le a versao do arquivo' {
        $p = Join-Path $TestDrive 'v'; $null = New-Item -ItemType Directory $p -Force
        Set-Content (Join-Path $p 'versao.txt') '1.4.2' -Encoding ASCII
        (Get-VersaoLocal $p).ToString() | Should Be '1.4.2'
    }
    It 'XML da tarefa e valido e roda como SYSTEM' {
        $xml = [xml](New-XmlTarefaAtualizador -Script 'C:\Program Files\PresencaAgente\Atualizar-Agente.ps1')
        $xml.Task.Principals.Principal.UserId | Should Be 'S-1-5-18'
        $xml.Task.Actions.Exec.Arguments | Should Match 'Atualizar-Agente.ps1'
    }
    It 'versao.txt do projeto e valido' {
        $v = $null
        [version]::TryParse((Get-Content (Join-Path $raiz 'Agent\versao.txt') -Raw).Trim(), [ref]$v) | Should Be $true
    }
    It 'chave-publica.xml do projeto carrega e NAO contem parte privada' {
        $txt = Get-Content (Join-Path $raiz 'Agent\chave-publica.xml') -Raw
        { $r = New-Object System.Security.Cryptography.RSACryptoServiceProvider; $r.FromXmlString($txt) } | Should Not Throw
        $txt | Should Not Match '<D>'
    }
    It 'todos os arquivos da lista de atualizacao existem na pasta Agent' {
        foreach ($n in (Get-ArquivosAtualizaveis)) { Test-Path (Join-Path $raiz "Agent\$n") | Should Be $true }
    }
}

Describe 'Atualizador: pasta de entrada e recriada se sumir' {
    It 'o ciclo recria a pasta entrada ausente' {
        $dest = Join-Path $TestDrive 'h'; $null = New-Item -ItemType Directory -Path $dest -Force
        Set-Content (Join-Path $dest 'versao.txt') '1.1.0' -Encoding ASCII
        $dados = Join-Path $TestDrive 'hd'
        Test-Path (Join-Path $dados 'entrada') | Should Be $false
        $null = Invoke-CicloAtualizacao -Destino $dest -PastaDados $dados -Fumaca { param($p) $true }
        Test-Path (Join-Path $dados 'entrada') | Should Be $true
    }
}

Describe 'Atualizador: entrada em Aplicativos instalados e desinstalacao' {
    $base = 'HKCU:\Software\PresencaPP-Teste'
    $chave = "$base\Uninstall\PresencaAgentePP"; $chaveInno = "$base\Uninstall\PresencaAgentePP_is1"
    BeforeEach { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }
    AfterEach { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }

    It 'registra a entrada com nome, versao e comando de desinstalar' {
        (Register-DesinstalacaoWindows -Destino 'C:\Program Files\PresencaAgente' -Versao '1.1.5' -Chave $chave -ChaveInno $chaveInno) | Should Be 'registrado'
        $p = Get-ItemProperty $chave
        $p.DisplayName | Should Be 'Agente de Presenca'
        $p.DisplayVersion | Should Be '1.1.5'
        $p.NoModify | Should Be 1
        $p.QuietUninstallString | Should Match 'Atualizar-Agente.ps1'
        $p.QuietUninstallString | Should Match '-Desinstalar'
    }
    It 'o UninstallString pede administrador e leva ao -Desinstalar' {
        $c = Get-ComandoDesinstalar 'C:\Program Files\PresencaAgente'
        $c.Interativo | Should Match '-EncodedCommand'
        $b64 = ($c.Interativo -split '-EncodedCommand ')[1].Trim()
        $dec = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($b64))
        $dec | Should Match 'RunAs'
        $dec | Should Match 'Atualizar-Agente.ps1'
        $dec | Should Match '-Desinstalar'
    }
    It 'registrar de novo so atualiza a versao (nao duplica)' {
        $null = Register-DesinstalacaoWindows -Destino 'C:\x' -Versao '1.1.5' -Chave $chave -ChaveInno $chaveInno
        $null = Register-DesinstalacaoWindows -Destino 'C:\x' -Versao '1.1.6' -Chave $chave -ChaveInno $chaveInno
        (Get-ItemProperty $chave).DisplayVersion | Should Be '1.1.6'
    }
    It 'se o instalador .exe (Inno) ja registrou, remove a nossa e so atualiza a versao dele' {
        $null = New-Item $chaveInno -Force
        Set-ItemProperty $chaveInno -Name DisplayVersion -Value '1.1.4'
        $null = New-Item $chave -Force
        (Register-DesinstalacaoWindows -Destino 'C:\x' -Versao '1.1.5' -Chave $chave -ChaveInno $chaveInno) | Should Be 'inno'
        Test-Path $chave | Should Be $false
        (Get-ItemProperty $chaveInno).DisplayVersion | Should Be '1.1.5'
    }
    It 'Remove-AgenteInstalado apaga pastas e a entrada, sem mexer em outras pastas' {
        $dest = Join-Path $TestDrive 'PresencaAgente'; $dados = Join-Path $TestDrive 'dadosPA'; $outra = Join-Path $TestDrive 'Outra'
        $null = New-Item -ItemType Directory -Path $dest, "$dest.bak", $dados, $outra -Force
        Set-Content (Join-Path $dest 'versao.txt') '1.1.5'
        Set-Content (Join-Path $outra 'x.txt') 'fica'
        $null = Register-DesinstalacaoWindows -Destino $dest -Versao '1.1.5' -Chave $chave -ChaveInno $chaveInno
        Remove-AgenteInstalado -Destino $dest -PastaDados $dados -Tarefas @('PresencaTeste-Inexistente') -Chave $chave
        Test-Path $dest | Should Be $false
        Test-Path "$dest.bak" | Should Be $false
        Test-Path $dados | Should Be $false
        Test-Path $chave | Should Be $false
        Test-Path (Join-Path $outra 'x.txt') | Should Be $true
    }
}
