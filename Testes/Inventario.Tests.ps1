# Testes da coleta de inventario da maquina (tipo, disco, coleta real, envio diario).
$raiz = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $raiz 'Agent\Presenca.psm1') -Force

Describe 'ConvertTo-TipoMaquina' {
    It 'notebook pela caixa (portatil, notebook, 2 em 1)' {
        ConvertTo-TipoMaquina @(10) 2 | Should Be 'NOTEBOOK'
        ConvertTo-TipoMaquina @(9) 0 | Should Be 'NOTEBOOK'
        ConvertTo-TipoMaquina @(31) 0 | Should Be 'NOTEBOOK'
    }
    It 'desktop (torre, mini, all in one)' {
        ConvertTo-TipoMaquina @(3) 1 | Should Be 'DESKTOP'
        ConvertTo-TipoMaquina @(6) 0 | Should Be 'DESKTOP'
        ConvertTo-TipoMaquina @(13) 0 | Should Be 'DESKTOP'
    }
    It 'servidor (rack)' { ConvertTo-TipoMaquina @(23) 4 | Should Be 'SERVIDOR' }
    It 'sem caixa conhecida usa o tipo de sistema, senao OUTRO' {
        ConvertTo-TipoMaquina @(1) 2 | Should Be 'NOTEBOOK'
        ConvertTo-TipoMaquina @() 1 | Should Be 'DESKTOP'
        ConvertTo-TipoMaquina @(1) 0 | Should Be 'OUTRO'
    }
}

Describe 'ConvertTo-TipoDisco' {
    It 'NVMe pelo barramento' { ConvertTo-TipoDisco 'SSD' 'NVMe' 'qualquer' | Should Be 'NVMe' }
    It 'SSD e HDD pelo tipo de midia' {
        ConvertTo-TipoDisco 'SSD' 'SATA' 'Samsung' | Should Be 'SSD'
        ConvertTo-TipoDisco 'HDD' 'SATA' 'WDC' | Should Be 'HDD'
    }
    It 'sem tipo, tenta pelo nome do modelo' {
        ConvertTo-TipoDisco 'Unspecified' '' 'KINGSTON SA400S37 SSD' | Should Be 'SSD'
        ConvertTo-TipoDisco '' '' 'NVMe SM2P41D3 ADATA 512GB' | Should Be 'NVMe'
        ConvertTo-TipoDisco '' '' 'WDC WD10EZEX' | Should Be 'Desconhecido'
    }
}

Describe 'Get-InventarioMaquina (coleta real deste PC)' {
    $inv = Get-InventarioMaquina
    It 'traz identificacao basica da maquina' {
        $inv.host | Should Be $env:COMPUTERNAME
        $inv.tipo | Should Match '^(NOTEBOOK|DESKTOP|SERVIDOR|OUTRO)$'
        $inv.so | Should Match 'Windows'
        $inv.so_versao | Should Match '^\d+\.\d+'
    }
    It 'memoria e disco em numeros plausiveis' {
        $inv.ram_gb -ge 1 | Should Be $true
        $inv.disco_total_gb -ge 1 | Should Be $true
        @($inv.discos).Count -ge 1 | Should Be $true
        @($inv.discos)[0].tipo | Should Match '^(SSD|NVMe|HDD|Desconhecido)$'
    }
    It 'IPs sao IPv4 validos, sem loopback nem link-local' {
        foreach ($ip in @($inv.ips)) { $ip | Should Match '^\d{1,3}(\.\d{1,3}){3}$'; $ip | Should Not Match '^(127\.|169\.254\.)' }
    }
    It 'serializa em JSON (e o que vai para o servidor)' {
        $j = $inv | ConvertTo-Json -Depth 5 -Compress | ConvertFrom-Json
        $j.host | Should Be $inv.host
        $j.ram_gb | Should Be $inv.ram_gb
    }
}

Describe 'Invoke-InventarioDiario (envio 1x por dia)' {
    function Novo-ServidorFalso([int]$Porta, [int]$Status = 200) {
        $l = New-Object System.Net.HttpListener; $l.Prefixes.Add("http://127.0.0.1:$Porta/"); $l.Start()
        $rec = New-Object System.Collections.ArrayList
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript({ param($l, $rec, $status)
            while ($l.IsListening) {
                try { $c = $l.GetContext() } catch { break }
                $sr = New-Object IO.StreamReader($c.Request.InputStream, [Text.Encoding]::UTF8)
                [void]$rec.Add(@{ Url = $c.Request.Url.AbsolutePath; Auth = $c.Request.Headers['Authorization']; Corpo = $sr.ReadToEnd() })
                $c.Response.StatusCode = $status; $b = [Text.Encoding]::UTF8.GetBytes('{"ok":true}'); $c.Response.OutputStream.Write($b, 0, $b.Length); $c.Response.Close()
            } }).AddArgument($l).AddArgument($rec).AddArgument($Status)
        $null = $ps.BeginInvoke()
        return @{ Listener = $l; Ps = $ps; Recebidos = $rec }
    }
    function Parar-ServidorFalso($s) { try { $s.Listener.Stop(); $s.Listener.Close() } catch { }; try { $s.Ps.Dispose() } catch { } }

    It 'primeira vez envia (com token); logo depois nao repete; versao nova do agent reenvia' {
        $estado = Join-Path $TestDrive 'inv1.json'
        $srv = Novo-ServidorFalso 18771
        try {
            (Invoke-InventarioDiario -Servidor 'http://127.0.0.1:18771' -Token 'tok' -ArquivoEstado $estado -VersaoAgente '1.3.0') | Should Be 'enviado'
            $srv.Recebidos.Count | Should Be 1
            $srv.Recebidos[0].Url | Should Be '/api/inventario'
            $srv.Recebidos[0].Auth | Should Be 'Bearer tok'
            ($srv.Recebidos[0].Corpo | ConvertFrom-Json).host | Should Be $env:COMPUTERNAME
            (Invoke-InventarioDiario -Servidor 'http://127.0.0.1:18771' -Token 'tok' -ArquivoEstado $estado -VersaoAgente '1.3.0') | Should Be 'nao-precisa'
            $srv.Recebidos.Count | Should Be 1
            (Invoke-InventarioDiario -Servidor 'http://127.0.0.1:18771' -Token 'tok' -ArquivoEstado $estado -VersaoAgente '1.3.1') | Should Be 'enviado'
            $srv.Recebidos.Count | Should Be 2
        } finally { Parar-ServidorFalso $srv }
    }
    It 'passadas 24 h, envia de novo' {
        $estado = Join-Path $TestDrive 'inv2.json'
        @{ quando = (Get-Date).AddHours(-25).ToString('o'); versao = '1.3.0' } | ConvertTo-Json | Set-Content $estado -Encoding UTF8
        $srv = Novo-ServidorFalso 18772
        try { (Invoke-InventarioDiario -Servidor 'http://127.0.0.1:18772' -Token 'tok' -ArquivoEstado $estado -VersaoAgente '1.3.0') | Should Be 'enviado' } finally { Parar-ServidorFalso $srv }
    }
    It 'servidor fora do ar: falha, nao marca como enviado e tenta de novo na proxima execucao' {
        $estado = Join-Path $TestDrive 'inv3.json'
        (Invoke-InventarioDiario -Servidor 'http://127.0.0.1:18799' -Token 'tok' -ArquivoEstado $estado -VersaoAgente '1.3.0') | Should Be 'falhou'
        Test-Path $estado | Should Be $false
        $srv = Novo-ServidorFalso 18773
        try { (Invoke-InventarioDiario -Servidor 'http://127.0.0.1:18773' -Token 'tok' -ArquivoEstado $estado -VersaoAgente '1.3.0') | Should Be 'enviado' } finally { Parar-ServidorFalso $srv }
    }
    It 'servidor respondendo erro tambem conta como falha' {
        $estado = Join-Path $TestDrive 'inv4.json'
        $srv = Novo-ServidorFalso 18774 500
        try { (Invoke-InventarioDiario -Servidor 'http://127.0.0.1:18774' -Token 'tok' -ArquivoEstado $estado -VersaoAgente '1.3.0') | Should Be 'falhou' } finally { Parar-ServidorFalso $srv }
        Test-Path $estado | Should Be $false
    }
}
