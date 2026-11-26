# Testes da coleta de programas em foco (maquina de estados, fila e envio).
$raiz = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $raiz 'Agent\Presenca.psm1') -Force

function Amostra($proc, $titulo = '', $ocioso = 0) { [pscustomobject]@{ Processo = $proc; Titulo = $titulo; OciosoSeg = $ocioso } }

Describe 'Update-EstadoFoco' {
    It 'mesma janela continua o mesmo segmento (nada fechado ainda)' {
        $e = @{ Atual = $null }
        $f1 = @(Update-EstadoFoco -Estado $e -Amostra (Amostra 'WINWORD' 'Contrato.docx - Word') -Agora 1000)
        $f2 = @(Update-EstadoFoco -Estado $e -Amostra (Amostra 'WINWORD' 'Contrato.docx - Word') -Agora 1005)
        @($f1).Count | Should Be 0
        @($f2).Count | Should Be 0
        $e.Atual.Inicio | Should Be 1000
        $e.Atual.Fim | Should Be 1005
    }
    It 'trocar de programa fecha o anterior com a duracao ate a troca' {
        $e = @{ Atual = $null }
        $null = Update-EstadoFoco -Estado $e -Amostra (Amostra 'WINWORD' 'a') -Agora 1000
        $null = Update-EstadoFoco -Estado $e -Amostra (Amostra 'WINWORD' 'a') -Agora 1005
        $f = @(Update-EstadoFoco -Estado $e -Amostra (Amostra 'EXCEL' 'b') -Agora 1010)
        $f.Count | Should Be 1
        $f[0].proc | Should Be 'WINWORD'
        $f[0].seg | Should Be 10
        $f[0].ts | Should Be 1000000
        $e.Atual.Processo | Should Be 'EXCEL'
    }
    It 'mudar so o titulo (mesmo programa) tambem fecha o segmento' {
        $e = @{ Atual = $null }
        $null = Update-EstadoFoco -Estado $e -Amostra (Amostra 'EXCEL' 'Planilha1') -Agora 1000
        $f = @(Update-EstadoFoco -Estado $e -Amostra (Amostra 'EXCEL' 'Planilha2') -Agora 1020)
        $f.Count | Should Be 1
        $f[0].titulo | Should Be 'Planilha1'
        $f[0].seg | Should Be 20
    }
    It 'navegador: o titulo (aba) nao quebra o segmento nem e enviado' {
        $e = @{ Atual = $null }
        $null = Update-EstadoFoco -Estado $e -Amostra (Amostra 'chrome' 'Gmail - Caixa de entrada') -Agora 1000
        $f = @(Update-EstadoFoco -Estado $e -Amostra (Amostra 'chrome' 'Legale Web') -Agora 1010)
        $f.Count | Should Be 0
        $e.Atual.Titulo | Should Be ''
    }
    It 'tela bloqueada ou ocioso 5 min fecha o segmento no ultimo instante ativo e para de contar' {
        $e = @{ Atual = $null }
        $null = Update-EstadoFoco -Estado $e -Amostra (Amostra 'WINWORD' 'x') -Agora 1000
        $null = Update-EstadoFoco -Estado $e -Amostra (Amostra 'WINWORD' 'x') -Agora 1100
        $f = @(Update-EstadoFoco -Estado $e -Amostra (Amostra 'WINWORD' 'x' 400) -Agora 1500)
        $f.Count | Should Be 1
        $f[0].seg | Should Be 100
        $e.Atual | Should Be $null
        # voltou: novo segmento a partir de agora, sem contar o intervalo parado
        $null = Update-EstadoFoco -Estado $e -Amostra (Amostra 'WINWORD' 'x' 2) -Agora 1600
        $e.Atual.Inicio | Should Be 1600
        $g = @(Update-EstadoFoco -Estado $e -Amostra (Amostra 'LockApp' '') -Agora 1700)
        $g.Count | Should Be 0   # so houve uma amostra ativa depois de voltar: durou 0 s
    }
    It 'sem janela em foco (area de trabalho bloqueada) tambem encerra' {
        $e = @{ Atual = $null }
        $null = Update-EstadoFoco -Estado $e -Amostra (Amostra 'OUTLOOK' 'Caixa') -Agora 1000
        $null = Update-EstadoFoco -Estado $e -Amostra (Amostra 'OUTLOOK' 'Caixa') -Agora 1030
        $f = @(Update-EstadoFoco -Estado $e -Amostra $null -Agora 1035)
        $f.Count | Should Be 1
        $f[0].seg | Should Be 30
    }
    It 'divide em blocos de ate 5 min (nao perde tudo se o PC desligar)' {
        $e = @{ Atual = $null }
        $total = 0
        $t = 1000
        $null = Update-EstadoFoco -Estado $e -Amostra (Amostra 'EXCEL' 'p') -Agora $t
        while ($t -lt 1000 + 900) { $t += 5; $f = @(Update-EstadoFoco -Estado $e -Amostra (Amostra 'EXCEL' 'p') -Agora $t); foreach ($s in $f) { $total += $s.seg; $s.seg -le 300 | Should Be $true } }
        $total + ($e.Atual.Fim - $e.Atual.Inicio) | Should Be 900
    }
    It 'sem coleta de titulos, o titulo vai vazio' {
        $e = @{ Atual = $null }
        $null = Update-EstadoFoco -Estado $e -Amostra (Amostra 'WINWORD' 'Sigiloso.docx') -Agora 1000 -Titulos $false
        $e.Atual.Titulo | Should Be ''
    }
    It 'titulo longo e cortado e caracteres de controle viram espaco' {
        (ConvertTo-TituloFoco ("a`r`nb" + ('x' * 300))).Length | Should Be 150
        (ConvertTo-TituloFoco "a`tb") | Should Be 'a b'
    }
}

Describe 'Janela em foco (API real do Windows)' {
    It 'devolve programa e titulo da janela atual (ou nada, se nao houver janela ativa)' {
        $j = Get-JanelaEmFoco
        if ($j) { $j.Processo | Should Not BeNullOrEmpty } else { $true | Should Be $true }
    }
    It 'ociosidade e um numero >= 0' { (Get-OciosoSegundos) -ge 0 | Should Be $true }
}

Describe 'Fila e envio (Send-Foco)' {
    # servidor falso: HttpListener local que guarda o que recebe
    function Novo-ServidorFalso([int]$Porta, [int]$Status = 200) {
        $l = New-Object System.Net.HttpListener; $l.Prefixes.Add("http://127.0.0.1:$Porta/"); $l.Start()
        $recebidos = New-Object System.Collections.ArrayList
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript({ param($l, $rec, $status)
            while ($l.IsListening) {
                try { $c = $l.GetContext() } catch { break }
                $sr = New-Object IO.StreamReader($c.Request.InputStream, [Text.Encoding]::UTF8); $corpo = $sr.ReadToEnd()
                [void]$rec.Add(@{ Url = $c.Request.Url.AbsolutePath; Auth = $c.Request.Headers['Authorization']; Corpo = $corpo })
                $c.Response.StatusCode = $status; $b = [Text.Encoding]::UTF8.GetBytes('{"ok":true}'); $c.Response.OutputStream.Write($b, 0, $b.Length); $c.Response.Close()
            } }).AddArgument($l).AddArgument($recebidos).AddArgument($Status)
        $h = $ps.BeginInvoke()
        return @{ Listener = $l; Ps = $ps; Recebidos = $recebidos }
    }
    function Parar-ServidorFalso($s) { try { $s.Listener.Stop(); $s.Listener.Close() } catch { }; try { $s.Ps.Dispose() } catch { } }

    It 'envia o que esta na fila, em lote, com token e apaga so depois do OK' {
        $pasta = Join-Path $TestDrive 'dados1'; $null = New-Item -ItemType Directory $pasta -Force
        Add-SegmentosFoco (Join-Path $pasta 'foco-pendente.jsonl') @(
            [pscustomobject]@{ ts = 1000000; seg = 30; proc = 'WINWORD'; titulo = 'Contrato com acento: ação' },
            [pscustomobject]@{ ts = 1030000; seg = 12; proc = 'EXCEL'; titulo = 'Planilha1' })
        $srv = Novo-ServidorFalso 18761
        try {
            $r = Send-Foco -Servidor 'http://127.0.0.1:18761' -Token 'tok-123' -PastaDados $pasta -Maquina 'PC1' -Usuario 'CORP\ana' -NomeCompleto 'Ana'
            $r.Enviados | Should Be 2
            $r.Falhou | Should Be $false
            $srv.Recebidos.Count | Should Be 1
            $srv.Recebidos[0].Url | Should Be '/api/foco'
            $srv.Recebidos[0].Auth | Should Be 'Bearer tok-123'
            $j = $srv.Recebidos[0].Corpo | ConvertFrom-Json
            $j.host | Should Be 'PC1'
            @($j.itens).Count | Should Be 2
            $j.itens[0].titulo | Should Be 'Contrato com acento: ação'
            @(Get-ChildItem $pasta -Filter 'foco-*').Count | Should Be 0
        } finally { Parar-ServidorFalso $srv }
    }
    It 'sem servidor, a fila fica guardada e e reenviada depois (nada se perde)' {
        $pasta = Join-Path $TestDrive 'dados2'; $null = New-Item -ItemType Directory $pasta -Force
        Add-SegmentosFoco (Join-Path $pasta 'foco-pendente.jsonl') @([pscustomobject]@{ ts = 5000000; seg = 60; proc = 'OUTLOOK'; titulo = 'Caixa' })
        $r = Send-Foco -Servidor 'http://127.0.0.1:18799' -Token 't' -PastaDados $pasta -Maquina 'PC1'
        $r.Falhou | Should Be $true
        $r.Enviados | Should Be 0
        @(Get-ChildItem $pasta -Filter 'foco-envio-*.jsonl').Count | Should Be 1
        # novos segmentos continuam entrando na fila nova enquanto isso
        Add-SegmentosFoco (Join-Path $pasta 'foco-pendente.jsonl') @([pscustomobject]@{ ts = 5100000; seg = 20; proc = 'EXCEL'; titulo = 'P' })
        $srv = Novo-ServidorFalso 18762
        try {
            $r2 = Send-Foco -Servidor 'http://127.0.0.1:18762' -Token 't' -PastaDados $pasta -Maquina 'PC1'
            $r2.Enviados | Should Be 2
            $r2.Falhou | Should Be $false
            @(Get-ChildItem $pasta -Filter 'foco-*').Count | Should Be 0
        } finally { Parar-ServidorFalso $srv }
    }
    It 'servidor respondendo erro mantem os arquivos' {
        $pasta = Join-Path $TestDrive 'dados3'; $null = New-Item -ItemType Directory $pasta -Force
        Add-SegmentosFoco (Join-Path $pasta 'foco-pendente.jsonl') @([pscustomobject]@{ ts = 7000000; seg = 5; proc = 'EXCEL'; titulo = '' })
        $srv = Novo-ServidorFalso 18763 500
        try {
            $r = Send-Foco -Servidor 'http://127.0.0.1:18763' -Token 't' -PastaDados $pasta -Maquina 'PC1'
            $r.Falhou | Should Be $true
            @(Get-ChildItem $pasta -Filter 'foco-envio-*.jsonl').Count | Should Be 1
        } finally { Parar-ServidorFalso $srv }
    }
}

Describe 'Coletor (loop real por alguns segundos)' {
    It 'roda, grava segmentos validos na fila e nao deixa lixo' {
        $pasta = Join-Path $TestDrive 'coleta'; $null = New-Item -ItemType Directory $pasta -Force
        # mutex proprio: no PC de quem desenvolve o coletor real (PresencaAgenteFoco) ja segura o mutex padrao
        $r = Start-ColetaFoco -PastaDados $pasta -IntervaloSeg 1 -DuracaoMaxSeg 4 -NomeMutex 'Local\PresencaPP-FocoTeste'
        $r | Should Be 'fim-do-teste'
        $arq = Join-Path $pasta 'foco-pendente.jsonl'
        if (Test-Path $arq) {
            foreach ($l in (Get-Content $arq -Encoding UTF8)) { $o = $l | ConvertFrom-Json; $o.proc | Should Not BeNullOrEmpty; $o.seg -ge 1 | Should Be $true; $o.ts -gt 1700000000000 | Should Be $true }
        }
    }
    It 'duas instancias na mesma sessao: a segunda sai na hora' {
        # a instancia 'dona' do mutex precisa estar em OUTRA thread (o mutex e reentrante na mesma thread)
        $ps = [PowerShell]::Create(); $null = $ps.AddScript({ $m = New-Object System.Threading.Mutex($false, 'Local\PresencaPP-Foco'); [void]$m.WaitOne(0); Start-Sleep -Seconds 6; $m.ReleaseMutex() }); $h = $ps.BeginInvoke()
        Start-Sleep -Milliseconds 800
        try { (Start-ColetaFoco -PastaDados (Join-Path $TestDrive 'x') -IntervaloSeg 1 -DuracaoMaxSeg 2) | Should Be 'ja-em-execucao' } finally { $ps.Stop(); $ps.Dispose() }
    }
}

Describe 'Tarefa agendada do coletor' {
    It 'XML valido, sem limite de tempo, no logon e como vigia' {
        $xml = [xml](New-XmlTarefaFoco -Comando 'conhost.exe' -Argumentos '--headless powershell.exe -File "C:\x\Detectar-Presenca.ps1" -Foco' -PrincipalXml '<Principal id="Author"><GroupId>S-1-5-32-545</GroupId><RunLevel>LeastPrivilege</RunLevel></Principal>')
        $xml.Task.Settings.ExecutionTimeLimit | Should Be 'PT0S'
        $xml.Task.Settings.MultipleInstancesPolicy | Should Be 'IgnoreNew'
        $xml.Task.Triggers.LogonTrigger | Should Not BeNullOrEmpty
        $xml.Task.Actions.Exec.Arguments | Should Match '-Foco'
    }
}
