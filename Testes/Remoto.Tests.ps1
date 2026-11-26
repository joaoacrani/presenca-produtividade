# Testes do acesso remoto (RustDesk): senha, estado protegido e comportamento sem servidor.
$raiz = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $raiz 'Agent\Presenca.psm1') -Force

Describe 'New-SenhaRemota' {
    It 'tem o tamanho pedido e so letras e numeros' {
        $s = New-SenhaRemota 20
        $s.Length | Should Be 20
        ($s -match '^[A-Za-z0-9]{20}$') | Should Be $true
    }
    It 'nao repete entre chamadas' {
        $todas = 1..50 | ForEach-Object { New-SenhaRemota 20 }
        ($todas | Select-Object -Unique).Count | Should Be 50
    }
}

Describe 'Estado protegido (DPAPI)' {
    It 'grava e le a senha sem deixa-la em texto puro' {
        $arq = Join-Path $env:TEMP ('rd-estado-' + [guid]::NewGuid().ToString('N') + '.json')
        Save-EstadoRemoto $arq '123456789' 'SenhaSecreta123' $true
        (Get-Content $arq -Raw) | Should Not Match 'SenhaSecreta123'
        $e = Get-EstadoRemoto $arq
        $e.id | Should Be '123456789'
        $e.senha | Should Be 'SenhaSecreta123'
        $e.enviado | Should Be $true
        Remove-Item $arq -Force
    }
    It 'arquivo inexistente ou corrompido vira $null' {
        Get-EstadoRemoto (Join-Path $env:TEMP 'nao-existe-rd.json') | Should BeNullOrEmpty
        $arq = Join-Path $env:TEMP ('rd-ruim-' + [guid]::NewGuid().ToString('N') + '.json')
        Set-Content $arq 'isto nao e json'
        Get-EstadoRemoto $arq | Should BeNullOrEmpty
        Remove-Item $arq -Force
    }
}

Describe 'Janela de progresso da instalacao (Show-RemotoInstalacao)' {
    function Nova-PastaAgente($json) {
        $p = Join-Path $env:TEMP ('rd-agente-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $p | Out-Null
        if ($json) { Set-Content (Join-Path $p 'agente.json') -Value $json -Encoding UTF8 }
        return $p
    }
    It 'sem servidor/token no agente.json: avisa e nao quebra' {
        $p = Nova-PastaAgente '{"servidor":""}'
        $saida = (Show-RemotoInstalacao -PastaAgente $p -SemEspera *>&1 | Out-String)
        $saida | Should Match 'nada a fazer'
        Remove-Item $p -Recurse -Force
    }
    It 'respeita acesso_remoto = false' {
        $p = Nova-PastaAgente '{"servidor":"http://127.0.0.1:1","token":"x","acesso_remoto":false}'
        $saida = (Show-RemotoInstalacao -PastaAgente $p -SemEspera *>&1 | Out-String)
        $saida | Should Match 'desativado neste PC'
        Remove-Item $p -Recurse -Force
    }
    It 'servidor fora do ar: mostra as etapas e explica o resultado, sem instalar nada' {
        $p = Nova-PastaAgente '{"servidor":"http://127.0.0.1:1","token":"x"}'
        $saida = (Show-RemotoInstalacao -PastaAgente $p -SemEspera *>&1 | Out-String)
        $saida | Should Match 'ACESSO REMOTO'
        $saida | Should Match '1/5'
        $saida | Should Match 'Nao consegui falar com o servidor'
        Remove-Item $p -Recurse -Force
    }
    It 'fora da janela de instalacao nada e escrito na tela (atualizacao automatica e silenciosa)' {
        $mod = Get-Module Presenca
        $saida = (& $mod { $script:RemotoMostrar = $false; Write-TelaRemoto 'nao pode aparecer' } *>&1 | Out-String)
        $saida | Should Not Match 'nao pode aparecer'
    }
}

Describe 'Limpeza de resquicios do RustDesk (so listagem: nada e apagado nos testes)' {
    It 'Get-RestosRustDesk devolve uma lista, sem erro' {
        $r = @(Get-RestosRustDesk)
        ($r -is [array]) | Should Be $true
        foreach ($x in $r) { ($x -match '^(servico|pasta|registro):') | Should Be $true }
    }
    It 'Remove-RustDeskCompleto -Simular lista os restos e nao apaga nada' {
        $antes = @(Get-RestosRustDesk).Count
        $lista = @(Remove-RustDeskCompleto -Simular)
        $lista.Count | Should Be $antes
        @(Get-RestosRustDesk).Count | Should Be $antes
    }
    It 'Stop-RustDeskJanelas nao quebra mesmo sem RustDesk aberto' {
        { Stop-RustDeskJanelas } | Should Not Throw
    }
}

Describe 'Arquivo de configuracao do RustDesk (RustDesk2.toml)' {
    $dir = Join-Path $env:TEMP ('rd-toml-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $dir | Out-Null
    $opc = [ordered]@{ 'custom-rendezvous-server' = 'remoto.exemplo.com'; 'relay-server' = 'remoto.exemplo.com'; 'key' = 'CHAVE='; 'stop-service' = 'N' }

    It 'Read-TomlRemoto le as opcoes e o rendezvous_server do topo' {
        $a = Join-Path $dir 'lido.toml'
        Set-Content $a -Encoding UTF8 -Value @("rendezvous_server = 'remoto.exemplo.com:21116'", 'nat_type = 1', '', '[options]', "av1-test = 'N'", "custom-rendezvous-server = 'remoto.exemplo.com'", '', '[outra]', "custom-rendezvous-server = 'NAO-LER'")
        $r = Read-TomlRemoto $a
        $r.Existe | Should Be $true
        $r.RendezvousServer | Should Be 'remoto.exemplo.com:21116'
        $r.Opcoes['custom-rendezvous-server'] | Should Be 'remoto.exemplo.com'
        $r.Opcoes['av1-test'] | Should Be 'N'
        (Read-TomlRemoto (Join-Path $dir 'nao-existe.toml')).Existe | Should Be $false
    }
    It 'Set-OpcoesToml cria o arquivo, mantem o resto, troca valores velhos e e idempotente' {
        $a = Join-Path $dir 'novo\RustDesk2.toml'
        Get-FaltaNoToml $a $opc | Should Be @('custom-rendezvous-server', 'relay-server', 'key', 'stop-service')
        Set-OpcoesToml -Arquivo $a -Opcoes $opc
        @(Get-FaltaNoToml $a $opc).Count | Should Be 0
        $b = Join-Path $dir 'velho.toml'
        Set-Content $b -Encoding UTF8 -Value @("rendezvous_server = 'rs-ny.rustdesk.com:21116'", 'nat_type = 2', '', '[options]', "stop-service = 'Y'", "av1-test = 'N'", "key = 'ANTIGA'", '', '[outra]', "x = '1'")
        Set-OpcoesToml -Arquivo $b -Opcoes $opc
        Set-OpcoesToml -Arquivo $b -Opcoes $opc
        $txt = Get-Content $b -Raw
        @(Get-FaltaNoToml $b $opc).Count | Should Be 0
        $txt | Should Match "rendezvous_server = 'rs-ny.rustdesk.com:21116'"
        $txt | Should Match "av1-test = 'N'"
        $txt | Should Match '\[outra\]'
        $txt | Should Not Match 'ANTIGA'
        ([regex]::Matches($txt, 'stop-service')).Count | Should Be 1
        ([regex]::Matches($txt, '\[options\]')).Count | Should Be 1
        Test-Path ($b + '.novo') | Should Be $false
    }
    It 'Get-FaltaNoToml lista so o que esta errado' {
        $a = Join-Path $dir 'parcial.toml'
        Set-Content $a -Encoding UTF8 -Value @('[options]', "key = 'CHAVE='", "relay-server = 'outro.com'")
        Get-FaltaNoToml $a $opc | Should Be @('custom-rendezvous-server', 'relay-server', 'stop-service')
    }
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Senha confirmada pelo RustDesk e prazo do fluxo' {
    $dir = Join-Path $env:TEMP ('rd-pw-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $dir | Out-Null
    $exe = Join-Path $dir 'rustdesk-falso.cmd'
    Set-Content $exe -Encoding ASCII -Value @('@echo off', 'set "D=%~dp0"', 'if /i "%~1"=="--password" ( if exist "%D%ipc.on" echo Done! )', 'exit /b 0')
    It 'Set-SenhaRemota so devolve verdadeiro com a confirmacao "Done!" do RustDesk' {
        & (Get-Module Presenca) { $script:RemotoFatorEspera = 0 }
        try {
            Set-SenhaRemota $exe 'SenhaTeste1234567890' | Should Be $false     # IPC mudo: sem confirmacao
            New-Item (Join-Path $dir 'ipc.on') -ItemType File | Out-Null
            Set-SenhaRemota $exe 'SenhaTeste1234567890' | Should Be $true
        } finally { & (Get-Module Presenca) { $script:RemotoFatorEspera = 1 } }
    }
    It 'Test-PrazoRemoto: sem prazo nao vence; com prazo vencido, vence' {
        & (Get-Module Presenca) { $script:RemotoPrazo = $null }
        (& (Get-Module Presenca) { Test-PrazoRemoto }) | Should Be $false
        & (Get-Module Presenca) { $script:RemotoPrazo = (Get-Date).AddMinutes(-1) }
        (& (Get-Module Presenca) { Test-PrazoRemoto }) | Should Be $true
        & (Get-Module Presenca) { $script:RemotoPrazo = $null }
    }
    It 'Get-ProgramasRemoto usa a pasta de 64 bits' {
        $p = Get-ProgramasRemoto
        ($p -match 'Program Files') | Should Be $true
    }
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ConfigRelay: cenarios do campo (com um RustDesk de mentira)' {
    # O "RustDesk" de mentira imita o IPC: so responde quando existe ipc.on (processo --server de pe); --option grava e le valores.
    $base = Join-Path $env:TEMP ('rd-cfg-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $base | Out-Null
    $cmd = @(
        '@echo off', 'set "D=%~dp0"',
        'if /i "%~1"=="--get-id" goto getid', 'if /i "%~1"=="--password" goto pw', 'if /i "%~1"=="--option" goto opt', 'exit /b 0',
        ':getid', 'if exist "%D%ipc.on" echo 123456789', 'exit /b 0',
        ':pw', 'if exist "%D%ipc.on" echo Done!', 'exit /b 0',
        ':opt', 'if not exist "%D%ipc.on" exit /b 0', 'if "%~3"=="" goto optget',
        '>"%D%opt_%~2" echo %~3', '>>"%D%toml.txt" echo %~2 = ''%~3''', 'exit /b 0',
        ':optget', 'if exist "%D%opt_%~2" type "%D%opt_%~2"', 'exit /b 0'
    )

    function Novo-Cenario([string]$nome) {
        $d = Join-Path $base $nome
        New-Item -ItemType Directory $d | Out-Null
        Set-Content (Join-Path $d 'rustdesk-falso.cmd') -Encoding ASCII -Value $cmd
        Set-Content (Join-Path $d 'toml.txt') -Encoding ASCII -Value @("rendezvous_server = 'rs-ny.rustdesk.com:21116'", '[options]')
        $global:RdTeste = @{ Dir = $d; Toml = (Join-Path $d 'toml.txt'); AoIniciar = {}; Paradas = 0 }
        & (Get-Module Presenca) { param($e, $t) $script:RemotoFatorEspera = 0; $script:RemotoExeTeste = $e; $script:RemotoTomlTeste = $t; $script:RemotoChave = 'CHAVETESTE'; $script:RemotoUltimoErro = '' } (Join-Path $d 'rustdesk-falso.cmd') (Join-Path $d 'toml.txt')
        Mock Stop-RustDeskTudo { $global:RdTeste.Paradas++ } -ModuleName Presenca
        Mock Stop-RustDeskProcessos {} -ModuleName Presenca
        Mock Start-ServicoRustDeskSeguro { & $global:RdTeste.AoIniciar; return $true } -ModuleName Presenca
        return $d
    }
    function Fim-Cenario {
        & (Get-Module Presenca) { $script:RemotoFatorEspera = 1; $script:RemotoExeTeste = $null; $script:RemotoTomlTeste = $null; $script:RemotoChave = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8='; $script:RemotoUltimoErro = '' }
        Remove-Variable RdTeste -Scope Global -ErrorAction SilentlyContinue
    }
    $exe = { param($d) Join-Path $d 'rustdesk-falso.cmd' }

    It 'A) IPC funciona: grava pelo RustDesk e prova no arquivo (canal ipc)' {
        $d = Novo-Cenario 'a'
        try {
            New-Item (Join-Path $d 'ipc.on') -ItemType File | Out-Null
            $ok = & (Get-Module Presenca) { param($e) Set-ConfigRelay -Exe $e } (& $exe $d)
            $ok | Should Be $true
            (& (Get-Module Presenca) { $script:RemotoCanal }) | Should Be 'ipc'
            $t = Read-TomlRemoto $global:RdTeste.Toml
            $t.Opcoes['custom-rendezvous-server'] | Should Be 'remoto.example.com'
            $t.Opcoes['key'] | Should Be 'CHAVETESTE'
        } finally { Fim-Cenario }
    }
    It 'B) IPC mudo (ninguem na tela do Windows): grava o arquivo com tudo parado e prova depois de religar (canal arquivo)' {
        $d = Novo-Cenario 'b'
        try {
            # ao "religar", o servidor de mentira sobe (ipc.on) e carrega as opcoes que estao no arquivo
            $global:RdTeste.AoIniciar = {
                New-Item (Join-Path $global:RdTeste.Dir 'ipc.on') -ItemType File -Force | Out-Null
                $t = Read-TomlRemoto $global:RdTeste.Toml
                foreach ($k in $t.Opcoes.Keys) { Set-Content (Join-Path $global:RdTeste.Dir "opt_$k") -Value $t.Opcoes[$k] -Encoding ASCII }
            }
            $ok = & (Get-Module Presenca) { param($e) Set-ConfigRelay -Exe $e } (& $exe $d)
            $ok | Should Be $true
            (& (Get-Module Presenca) { $script:RemotoCanal }) | Should Be 'arquivo'
            @(Get-FaltaNoToml $global:RdTeste.Toml (Get-OpcoesRemoto)).Count | Should Be 0
        } finally { Fim-Cenario }
    }
    It 'C) um processo velho sobrescreve o arquivo: NAO declara sucesso e diz o que viu' {
        $d = Novo-Cenario 'c'
        try {
            $global:RdTeste.AoIniciar = {
                New-Item (Join-Path $global:RdTeste.Dir 'ipc.on') -ItemType File -Force | Out-Null
                Set-Content $global:RdTeste.Toml -Value @("rendezvous_server = 'rs-ny.rustdesk.com:21116'", '[options]') -Encoding ASCII
            }
            $ok = & (Get-Module Presenca) { param($e) Set-ConfigRelay -Exe $e } (& $exe $d)
            $ok | Should Be $false
            (& (Get-Module Presenca) { $script:RemotoUltimoErro }) | Should Match 'nao fixou'
        } finally { Fim-Cenario }
    }
    It 'D) ja estava correta e provada: nao mexe em nada (canal ja-estava)' {
        $d = Novo-Cenario 'd'
        try {
            New-Item (Join-Path $d 'ipc.on') -ItemType File | Out-Null
            $o = Get-OpcoesRemoto
            Set-OpcoesToml -Arquivo $global:RdTeste.Toml -Opcoes $o
            foreach ($k in $o.Keys) { Set-Content (Join-Path $d "opt_$k") -Value $o[$k] -Encoding ASCII }
            $ok = & (Get-Module Presenca) { param($e) Set-ConfigRelay -Exe $e } (& $exe $d)
            $ok | Should Be $true
            (& (Get-Module Presenca) { $script:RemotoCanal }) | Should Be 'ja-estava'
            $global:RdTeste.Paradas | Should Be 0   # nao parou nem religou nada
        } finally { Fim-Cenario }
    }
    It 'E) IPC responde mas o RustDesk discorda do arquivo: corrige (nao se contenta so com o arquivo)' {
        $d = Novo-Cenario 'e'
        try {
            New-Item (Join-Path $d 'ipc.on') -ItemType File | Out-Null
            $o = Get-OpcoesRemoto
            Set-OpcoesToml -Arquivo $global:RdTeste.Toml -Opcoes $o         # arquivo certo...
            foreach ($k in $o.Keys) { Set-Content (Join-Path $d "opt_$k") -Value 'valor-diferente' -Encoding ASCII }   # ...mas o processo em memoria tem outro valor
            $ok = & (Get-Module Presenca) { param($e) Set-ConfigRelay -Exe $e } (& $exe $d)
            (& (Get-Module Presenca) { $script:RemotoCanal }) | Should Not Be 'ja-estava'
        } finally { Fim-Cenario }
    }
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Execucao unica do acesso remoto' {
    It 'segunda execucao enquanto outra roda devolve em-andamento' {
        $seg = Start-Job { $m = New-Object System.Threading.Mutex($false, 'Global\PresencaAgenteRemoto'); [void]$m.WaitOne(0); Start-Sleep -Seconds 12; $m.ReleaseMutex() }
        Start-Sleep -Seconds 3
        try { Invoke-RemotoGarantir -Servidor 'http://127.0.0.1:1' -Token 'x' -PastaDados $env:TEMP | Should Be 'em-andamento' }
        finally { Stop-Job $seg -ErrorAction SilentlyContinue; Remove-Job $seg -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Sem servidor / sem rede' {
    It 'Test-PortaTcp em porta fechada devolve falso' {
        Test-PortaTcp '127.0.0.1' 1 500 | Should Be $false
    }
    It 'politica com servidor fora do ar devolve $null (nao decide nada)' {
        $r = Get-RemotoPolitica -Servidor 'http://127.0.0.1:1' -Token 'x'
        ($null -eq $r) | Should Be $true
    }
    It 'Wait-ServicoRustDesk devolve o servico que existe e $null para o que nao existe' {
        (Wait-ServicoRustDesk -Segundos 4 -Nome 'Spooler').Name | Should Be 'Spooler'
        ($null -eq (Wait-ServicoRustDesk -Segundos 1 -Nome 'ServicoQueNaoExiste123')) | Should Be $true
    }
    It 'Wait-RustDeskPronto com programa inexistente devolve falso sem estourar erro' {
        Wait-RustDeskPronto 'C:\nao-existe\RustDesk.exe' 1 | Should Be $false
    }
    It 'Write-LogRemoto grava no log local e nao quebra sem pasta definida' {
        Write-LogRemoto 'sem pasta definida'   # nao pode lancar erro
        $pasta = Join-Path $env:TEMP ('rd-log-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $pasta | Out-Null
        $mod = Get-Module Presenca
        & $mod { param($p) $script:RemotoPastaLog = $p; Write-LogRemoto 'linha de teste' } $pasta
        (Get-Content (Join-Path $pasta 'remoto.log') -Raw) | Should Match 'linha de teste'
        Remove-Item $pasta -Recurse -Force
    }
    It 'Send-RemotoStatus com servidor fora do ar devolve falso e nao quebra o fluxo' {
        $r = Send-RemotoStatus -Servidor 'http://127.0.0.1:1' -Token 'x' -Estado 'baixando' -Detalhe 'teste'
        $r | Should Be $false
    }
    It 'Invoke-RemotoGarantir devolve sem-servidor e nao toca em nada' {
        Invoke-RemotoGarantir -Servidor 'http://127.0.0.1:1' -Token 'x' -PastaDados $env:TEMP | Should Be 'sem-servidor'
    }
}
