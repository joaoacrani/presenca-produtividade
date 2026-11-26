# Testes Pester (compativeis com Pester 3.4 e 5). Rodar: Invoke-Pester .\tests
# Nao tocam na rede nem no sistema: o MAC do gateway e simulado.

$raiz = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $raiz 'Agent\Presenca.psm1') -Force
$cfg = Get-Content -Path (Join-Path $raiz 'Config\unidades.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Novo-Candidato($ip, $gw, $nome = 'Wi-Fi', $indice = 5) {
    [pscustomobject]@{ Adaptador = $nome; Indice = $indice; IpLocal = $ip; Gateway = $gw }
}
function Mac-Fixo([string]$mac) { { param($g, $i) $mac }.GetNewClosure() }

Describe 'ConvertTo-MacNormal' {
    It 'normaliza separadores e caixa' {
        ConvertTo-MacNormal '02:00:00:00:00:01' | Should Be '02-00-00-00-00-01'
        ConvertTo-MacNormal '0200.0000.0001'    | Should Be '02-00-00-00-00-01'
    }
    It 'devolve nulo para vazio ou tamanho invalido' {
        ConvertTo-MacNormal ''        | Should BeNullOrEmpty
        ConvertTo-MacNormal '60-BE'   | Should BeNullOrEmpty
    }
}

Describe 'Test-IpEmSubrede' {
    It 'aceita IP dentro da sub-rede' {
        Test-IpEmSubrede '10.10.30.55' '10.10.28.0/22' | Should Be $true
        Test-IpEmSubrede '10.20.15.200' '10.20.8.0/21' | Should Be $true
    }
    It 'rejeita IP fora da sub-rede' {
        Test-IpEmSubrede '10.30.32.10' '10.10.28.0/22' | Should Be $false
        Test-IpEmSubrede '192.168.1.10' '10.20.8.0/21' | Should Be $false
    }
    It 'respeita os limites da sub-rede' {
        Test-IpEmSubrede '10.10.28.0'   '10.10.28.0/22' | Should Be $true
        Test-IpEmSubrede '10.10.31.255' '10.10.28.0/22' | Should Be $true
        Test-IpEmSubrede '10.10.27.255' '10.10.28.0/22' | Should Be $false
        Test-IpEmSubrede '10.30.32.0'   '10.10.28.0/22' | Should Be $false
    }
}

Describe 'Test-Corresponde' {
    It 'acha padrao parcial, sem diferenciar caixa' {
        Test-Corresponde 'TAP-Windows Adapter V9' @('tap-windows') | Should Be $true
    }
    It 'nao acha quando nada bate' {
        Test-Corresponde 'Intel(R) Wi-Fi 6 AX201' @('Hyper-V', 'VirtualBox') | Should Be $false
    }
}

Describe 'Test-ForaDoHorario' {
    It 'padrao 24h: madrugada de domingo coleta' { Test-ForaDoHorario ([datetime]'2026-11-15 03:00') | Should Be $false }
    It 'padrao 24h: 23:59 coleta' { Test-ForaDoHorario ([datetime]'2026-11-16 23:59') | Should Be $false }
    It 'padrao 24h: sabado coleta' { Test-ForaDoHorario ([datetime]'2026-11-14 10:00') | Should Be $false }
    It 'janela 8-18: segunda 10h esta dentro' { Test-ForaDoHorario ([datetime]'2026-11-16 10:00') 8 18 $true | Should Be $false }
    It 'janela 8-18: segunda 07:59 esta fora' { Test-ForaDoHorario ([datetime]'2026-11-16 07:59') 8 18 $true | Should Be $true }
    It 'janela 8-18: segunda 08:00 esta dentro' { Test-ForaDoHorario ([datetime]'2026-11-16 08:00') 8 18 $true | Should Be $false }
    It 'janela 8-18: segunda 18:00 esta fora' { Test-ForaDoHorario ([datetime]'2026-11-16 18:00') 8 18 $true | Should Be $true }
    It 'janela 8-18: sabado esta fora' { Test-ForaDoHorario ([datetime]'2026-11-14 10:00') 8 18 $true | Should Be $true }
}

Describe 'Resolve-Presenca' {
    It 'MTZ com gateway e MAC corretos: Presencial, confianca alta' {
        $r = Resolve-Presenca -Candidatos @(Novo-Candidato '10.10.29.10' '10.10.30.1') -Config $cfg -VpnAtiva $false -ObterMac (Mac-Fixo '02-00-00-00-00-01')
        $r.Resultado | Should Be 'Presencial'
        $r.Unidade   | Should Be 'MTZ'
        $r.Confianca | Should Be 'alta'
        $r.MacConfere | Should Be 'sim'
    }
    It 'aceita o MAC em formato diferente (dois pontos, minusculo)' {
        $r = Resolve-Presenca -Candidatos @(Novo-Candidato '10.10.29.10' '10.10.30.1') -Config $cfg -VpnAtiva $false -ObterMac (Mac-Fixo '02:00:00:00:00:01')
        $r.Resultado | Should Be 'Presencial'
        $r.Confianca | Should Be 'alta'
    }
    It 'FL1 e FL2 sao reconhecidas' {
        (Resolve-Presenca -Candidatos @(Novo-Candidato '10.20.9.20' '10.20.10.2') -Config $cfg -VpnAtiva $false -ObterMac (Mac-Fixo '02-00-00-00-00-02')).Unidade | Should Be 'FL1'
        (Resolve-Presenca -Candidatos @(Novo-Candidato '10.30.32.50' '10.30.32.254') -Config $cfg -VpnAtiva $false -ObterMac (Mac-Fixo '02-00-00-00-00-03')).Unidade | Should Be 'FL2'
    }
    It 'VPN ligada no escritorio: Presencial via VPN, mantendo a unidade e a confianca' {
        $r = Resolve-Presenca -Candidatos @(Novo-Candidato '10.10.29.10' '10.10.30.1') -Config $cfg -VpnAtiva $true -ObterMac (Mac-Fixo '02-00-00-00-00-01')
        $r.Resultado | Should Be 'Presencial via VPN'
        $r.Unidade   | Should Be 'MTZ'
        $r.Confianca | Should Be 'alta'
        $r.Motivo    | Should Match 'VPN ativa'
    }
    It 'sem VPN no escritorio continua Presencial (nao vira "via VPN")' {
        (Resolve-Presenca -Candidatos @(Novo-Candidato '10.10.29.10' '10.10.30.1') -Config $cfg -VpnAtiva $false -ObterMac (Mac-Fixo '02-00-00-00-00-01')).Resultado | Should Be 'Presencial'
    }
    It 'MAC divergente com VPN ligada: nao e Presencial via VPN, e Remoto via VPN' {
        $r = Resolve-Presenca -Candidatos @(Novo-Candidato '10.10.29.10' '10.10.30.1') -Config $cfg -VpnAtiva $true -ObterMac (Mac-Fixo 'AA-BB-CC-DD-EE-FF')
        $r.Resultado | Should Be 'Remoto via VPN'
    }
    It 'FL1 e FL2 tambem viram Presencial via VPN com a VPN ligada' {
        (Resolve-Presenca -Candidatos @(Novo-Candidato '10.20.9.20' '10.20.10.2') -Config $cfg -VpnAtiva $true -ObterMac (Mac-Fixo '02-00-00-00-00-02')).Resultado | Should Be 'Presencial via VPN'
        (Resolve-Presenca -Candidatos @(Novo-Candidato '10.30.32.50' '10.30.32.254') -Config $cfg -VpnAtiva $true -ObterMac (Mac-Fixo '02-00-00-00-00-03')).Unidade | Should Be 'FL2'
    }
    It 'MAC indisponivel: Presencial com confianca media' {
        $r = Resolve-Presenca -Candidatos @(Novo-Candidato '10.10.29.10' '10.10.30.1') -Config $cfg -VpnAtiva $false -ObterMac { param($g, $i) $null }
        $r.Resultado  | Should Be 'Presencial'
        $r.Confianca  | Should Be 'media'
        $r.MacConfere | Should Be 'indisponivel'
    }
    It 'MAC diferente do esperado: nao e Presencial, vira Remoto com aviso e confianca media' {
        $r = Resolve-Presenca -Candidatos @(Novo-Candidato '10.10.29.10' '10.10.30.1') -Config $cfg -VpnAtiva $false -ObterMac (Mac-Fixo 'AA-BB-CC-DD-EE-FF')
        $r.Resultado | Should Be 'Remoto'
        $r.Confianca | Should Be 'media'
        $r.Motivo    | Should Match 'MAC do gateway e diferente'
    }
    It 'rede de casa (192.168.1.x): Remoto' {
        $r = Resolve-Presenca -Candidatos @(Novo-Candidato '192.168.1.20' '192.168.1.1') -Config $cfg -VpnAtiva $false -ObterMac (Mac-Fixo '11-22-33-44-55-66')
        $r.Resultado | Should Be 'Remoto'
        $r.Unidade   | Should BeNullOrEmpty
    }
    It 'rede de casa com VPN: Remoto via VPN' {
        $r = Resolve-Presenca -Candidatos @(Novo-Candidato '192.168.1.20' '192.168.1.1') -Config $cfg -VpnAtiva $true -ObterMac (Mac-Fixo '11-22-33-44-55-66')
        $r.Resultado | Should Be 'Remoto via VPN'
    }
    It 'gateway de outra unidade com IP da sub-rede errada: nao e Presencial' {
        # IP de MTZ, mas gateway de FL1
        $r = Resolve-Presenca -Candidatos @(Novo-Candidato '10.10.29.10' '10.20.10.1') -Config $cfg -VpnAtiva $false -ObterMac (Mac-Fixo '00-00-5E-00-01-01')
        $r.Resultado | Should Be 'Remoto'
    }
    It 'sem nenhuma rede fisica: Sem rede, confianca baixa' {
        $r = Resolve-Presenca -Candidatos @() -Config $cfg -VpnAtiva $false -ObterMac { param($g, $i) $null }
        $r.Resultado | Should Be 'Sem rede'
        $r.Confianca | Should Be 'baixa'
    }
    It 'com Wi-Fi de casa e cabo no escritorio ao mesmo tempo: Presencial' {
        $cands = @((Novo-Candidato '192.168.1.20' '192.168.1.1' 'Wi-Fi' 3), (Novo-Candidato '10.10.29.10' '10.10.30.1' 'Ethernet' 7))
        $mac = { param($g, $i) if ($g -eq '10.10.30.1') { '02-00-00-00-00-01' } else { '11-22-33-44-55-66' } }
        $r = Resolve-Presenca -Candidatos $cands -Config $cfg -VpnAtiva $false -ObterMac $mac
        $r.Resultado | Should Be 'Presencial'
        $r.Unidade   | Should Be 'MTZ'
    }
    It 'unidade sem MAC configurado: Presencial com confianca media' {
        $cfg2 = '{"unidades":[{"nome":"X","sub_rede":"10.0.0.0/24","gateways":[{"ip":"10.0.0.1"}]}]}' | ConvertFrom-Json
        $r = Resolve-Presenca -Candidatos @(Novo-Candidato '10.0.0.5' '10.0.0.1') -Config $cfg2 -VpnAtiva $false -ObterMac (Mac-Fixo '02-00-00-00-00-01')
        $r.Resultado  | Should Be 'Presencial'
        $r.Confianca  | Should Be 'media'
        $r.MacConfere | Should Be 'nao_configurado'
    }
}

Describe 'unidades.json' {
    It 'todas as sub-redes sao CIDR validos e cada unidade tem gateways' {
        foreach ($u in $cfg.unidades) {
            $u.sub_rede | Should Match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'
            @($u.gateways).Count | Should BeGreaterThan 0
            foreach ($g in $u.gateways) {
                # cada gateway precisa estar dentro da sub-rede da propria unidade
                Test-IpEmSubrede $g.ip $u.sub_rede | Should Be $true
                if ($g.mac) { ConvertTo-MacNormal $g.mac | Should Not BeNullOrEmpty }
            }
        }
    }
    It 'nomes de unidade sao unicos' {
        $nomes = @($cfg.unidades | ForEach-Object { $_.nome })
        ($nomes | Select-Object -Unique).Count | Should Be $nomes.Count
    }
}


Describe 'New-XmlTarefaPresenca' {
    $principal = '<Principal id="Author"><GroupId>S-1-5-32-545</GroupId><RunLevel>LeastPrivilege</RunLevel></Principal>'
    $xmlTxt = New-XmlTarefaPresenca -Comando 'C:\Windows\System32\conhost.exe' -Argumentos '--headless powershell.exe -File "C:\Program Files\X\a.ps1"' -PrincipalXml $principal -IntervaloMin 5 -AtrasoRedeSeg 20
    It 'gera um XML valido' {
        { [xml]$xmlTxt } | Should Not Throw
    }
    It 'tem os quatro gatilhos: logon, repeticao, troca de rede e desbloqueio' {
        $x = [xml]$xmlTxt
        $x.Task.Triggers.LogonTrigger | Should Not BeNullOrEmpty
        $x.Task.Triggers.TimeTrigger.Repetition.Interval | Should Be 'PT5M'
        $x.Task.Triggers.EventTrigger.Delay | Should Be 'PT20S'
        $x.Task.Triggers.EventTrigger.Subscription | Should Match 'EventID=10000 or EventID=10001'
        $x.Task.Triggers.EventTrigger.Subscription | Should Match 'EventID=4004'
        $x.Task.Triggers.EventTrigger.Subscription | Should Match 'NetworkProfile/Operational'
        $x.Task.Triggers.SessionStateChangeTrigger.StateChange | Should Be 'SessionUnlock'
    }
    It 'usa o intervalo informado' {
        ([xml](New-XmlTarefaPresenca -Comando 'a' -Argumentos 'b' -PrincipalXml $principal -IntervaloMin 10)).Task.Triggers.TimeTrigger.Repetition.Interval | Should Be 'PT10M'
    }
    It 'preserva aspas e espacos nos argumentos e roda sem sobreposicao' {
        $x = [xml]$xmlTxt
        $x.Task.Actions.Exec.Arguments | Should Match 'Program Files'
        $x.Task.Settings.MultipleInstancesPolicy | Should Be 'IgnoreNew'
    }
}

Describe 'Get-VpnAtivos (usado como @(Get-VpnAtivos) no script)' {
    Context 'um unico adaptador de VPN ativo' {
        Mock -ModuleName Presenca Get-NetAdapter {
            [pscustomobject]@{ Name = 'OpenVPN TAP-Windows6'; InterfaceDescription = 'TAP-Windows Adapter V9'; Status = 'Up' }
            [pscustomobject]@{ Name = 'Wi-Fi'; InterfaceDescription = 'Intel(R) Wi-Fi 6E AX211'; Status = 'Up' }
            [pscustomobject]@{ Name = 'OpenVPN Wintun'; InterfaceDescription = 'Wintun Userspace Tunnel'; Status = 'Disconnected' }
        }
        It 'conta 1 e traz o nome do adaptador' {
            $v = @(Get-VpnAtivos $cfg)
            $v.Count | Should Be 1
            $v[0].InterfaceDescription | Should Be 'TAP-Windows Adapter V9'
            (($v | ForEach-Object { $_.InterfaceDescription }) -join ' + ') | Should Be 'TAP-Windows Adapter V9'
        }
    }
    Context 'VPN desconectada (so o Wi-Fi ativo)' {
        Mock -ModuleName Presenca Get-NetAdapter {
            [pscustomobject]@{ Name = 'Wi-Fi'; InterfaceDescription = 'Intel(R) Wi-Fi 6E AX211'; Status = 'Up' }
            [pscustomobject]@{ Name = 'OpenVPN TAP-Windows6'; InterfaceDescription = 'TAP-Windows Adapter V9'; Status = 'Disconnected' }
        }
        It 'conta 0 (nao pode virar "VPN ativa")' {
            $v = @(Get-VpnAtivos $cfg)
            $v.Count | Should Be 0
            ($v.Count -gt 0) | Should Be $false
        }
    }
    Context 'dois adaptadores de VPN ativos' {
        Mock -ModuleName Presenca Get-NetAdapter {
            [pscustomobject]@{ Name = 'a'; InterfaceDescription = 'TAP-Windows Adapter V9'; Status = 'Up' }
            [pscustomobject]@{ Name = 'b'; InterfaceDescription = 'Wintun Userspace Tunnel'; Status = 'Up' }
        }
        It 'conta 2' { @(Get-VpnAtivos $cfg).Count | Should Be 2 }
    }
}

Describe 'Get-CandidatosRede (usado como @(Get-CandidatosRede) no script)' {
    function global:Nova-Config($alias, $desc, $ip, $gw, $status = 'Up') {
        [pscustomobject]@{
            InterfaceAlias = $alias; InterfaceDescription = $desc; InterfaceIndex = 5
            IPv4Address = [pscustomobject]@{ IPAddress = $ip }
            IPv4DefaultGateway = $(if ($gw) { [pscustomobject]@{ NextHop = $gw } } else { $null })
            NetAdapter = [pscustomobject]@{ Status = $status }
        }
    }
    Context 'so Wi-Fi do hotspot com gateway; VPN e virtuais sem gateway' {
        Mock -ModuleName Presenca Get-NetIPConfiguration {
            Nova-Config 'Wi-Fi' 'Intel(R) Wi-Fi 6E AX211' '172.20.10.2' '172.20.10.1'
            Nova-Config 'OpenVPN TAP-Windows6' 'TAP-Windows Adapter V9' '10.20.30.3' $null
            Nova-Config 'vEthernet (Default Switch)' 'Hyper-V Virtual Ethernet Adapter' '172.28.224.1' $null
        }
        It 'devolve exatamente 1 candidato, com Gateway como texto' {
            $c = @(Get-CandidatosRede $cfg)
            $c.Count | Should Be 1
            $c[0].Gateway | Should Be '172.20.10.1'
            $c[0].IpLocal | Should Be '172.20.10.2'
        }
        It 'resultado final: Remoto (sem VPN) e Remoto via VPN (com VPN)' {
            $c = @(Get-CandidatosRede $cfg)
            (Resolve-Presenca -Candidatos $c -Config $cfg -VpnAtiva $false -ObterMac { param($g, $i) '02-00-00-00-00-06' }).Resultado | Should Be 'Remoto'
            (Resolve-Presenca -Candidatos $c -Config $cfg -VpnAtiva $true  -ObterMac { param($g, $i) '02-00-00-00-00-06' }).Resultado | Should Be 'Remoto via VPN'
        }
    }
    Context 'nenhuma rede fisica com gateway' {
        Mock -ModuleName Presenca Get-NetIPConfiguration {
            Nova-Config 'Wi-Fi' 'Intel(R) Wi-Fi 6E AX211' '169.254.1.1' $null 'Disconnected'
        }
        It 'conta 0 e o resultado e Sem rede' {
            $c = @(Get-CandidatosRede $cfg)
            $c.Count | Should Be 0
            (Resolve-Presenca -Candidatos $c -Config $cfg -VpnAtiva $false -ObterMac { param($g, $i) $null }).Resultado | Should Be 'Sem rede'
        }
    }
    Context 'cabo no escritorio e Wi-Fi ao mesmo tempo' {
        Mock -ModuleName Presenca Get-NetIPConfiguration {
            Nova-Config 'Wi-Fi' 'Intel(R) Wi-Fi 6E AX211' '192.168.1.20' '192.168.1.1'
            Nova-Config 'Ethernet' 'Realtek PCIe GbE Family Controller' '10.10.30.222' '10.10.30.1'
        }
        It 'devolve 2 candidatos' { @(Get-CandidatosRede $cfg).Count | Should Be 2 }
    }
}




Describe 'Anti-rajada (Test-RegistroRedundante / Save-EstadoEnvio)' {
    $arq = Join-Path $TestDrive 'ultimo-envio.json'
    $t0 = [datetime]'2026-11-18 11:02:00'
    It 'sem arquivo de estado: nao e redundante (registra)' {
        Test-RegistroRedundante -Assinatura 'a' -ArquivoEstado $arq -Agora $t0 -JanelaSeg 30 | Should Be $false
    }
    It 'mesmo estado a menos de 30 s: redundante' {
        Save-EstadoEnvio -Assinatura 'Presencial|MTZ|nao' -ArquivoEstado $arq -Agora $t0
        Test-RegistroRedundante -Assinatura 'Presencial|MTZ|nao' -ArquivoEstado $arq -Agora $t0.AddSeconds(5) -JanelaSeg 30 | Should Be $true
        Test-RegistroRedundante -Assinatura 'Presencial|MTZ|nao' -ArquivoEstado $arq -Agora $t0.AddSeconds(29) -JanelaSeg 30 | Should Be $true
    }
    It 'mesmo estado depois de 30 s: registra de novo' {
        Save-EstadoEnvio -Assinatura 'Presencial|MTZ|nao' -ArquivoEstado $arq -Agora $t0
        Test-RegistroRedundante -Assinatura 'Presencial|MTZ|nao' -ArquivoEstado $arq -Agora $t0.AddSeconds(30) -JanelaSeg 30 | Should Be $false
    }
    It 'ESTADO DIFERENTE logo apos um registro (VPN ligou): sempre registra' {
        Save-EstadoEnvio -Assinatura 'Presencial|MTZ|nao' -ArquivoEstado $arq -Agora $t0
        Test-RegistroRedundante -Assinatura 'Presencial via VPN|MTZ|sim' -ArquivoEstado $arq -Agora $t0.AddSeconds(3) -JanelaSeg 30 | Should Be $false
    }
    It 'arquivo corrompido: nao bloqueia o registro' {
        Set-Content -Path $arq -Value '{isto nao e json' -Encoding UTF8
        Test-RegistroRedundante -Assinatura 'a' -ArquivoEstado $arq -Agora $t0 -JanelaSeg 30 | Should Be $false
    }
    It 'relogio voltou no tempo (diferenca negativa): nao bloqueia' {
        Save-EstadoEnvio -Assinatura 'a' -ArquivoEstado $arq -Agora $t0
        Test-RegistroRedundante -Assinatura 'a' -ArquivoEstado $arq -Agora $t0.AddSeconds(-10) -JanelaSeg 30 | Should Be $false
    }
}


# ---------- nome completo e navegacao ----------
Import-Module (Join-Path $raiz 'Agent\Navegacao.psm1') -Force

Describe 'ConvertTo-LoginSimples' {
    It 'tira dominio e sufixo de e-mail' {
        ConvertTo-LoginSimples 'CORP\msouza'      | Should Be 'msouza'
        ConvertTo-LoginSimples 'ana.silva@empresa.com' | Should Be 'ana.silva'
        ConvertTo-LoginSimples 'maria'             | Should Be 'maria'
        ConvertTo-LoginSimples ''                  | Should Be ''
    }
}

Describe 'ConvertFrom-NetUserNome' {
    It 'le o nome na saida em portugues e em ingles' {
        ConvertFrom-NetUserNome @('Nome de usuario    msouza', 'Nome completo       Maria Souza', 'Comentario') | Should Be 'Maria Souza'
        ConvertFrom-NetUserNome @('User name   x', 'Full Name              Maria Souza') | Should Be 'Maria Souza'
    }
    It 'devolve vazio quando nao ha nome' {
        ConvertFrom-NetUserNome @('Nome de usuario    x', 'Nome completo') | Should BeNullOrEmpty
        ConvertFrom-NetUserNome $null | Should BeNullOrEmpty
    }
}

Describe 'Get-NomeCompleto (cache e entradas invalidas)' {
    It 'usa o cache valido sem consultar nada' {
        $arq = Join-Path $env:TEMP ("nome-" + [guid]::NewGuid().ToString('N') + '.json')
        $agora = Get-Date
        @{ login = 'msouza'; nome = 'Maria Souza'; epoch = [DateTimeOffset]::new($agora.AddHours(-2)).ToUnixTimeSeconds() } | ConvertTo-Json | Set-Content $arq -Encoding UTF8
        Get-NomeCompleto -Usuario 'CORP\msouza' -ArquivoCache $arq -Agora $agora | Should Be 'Maria Souza'
        Remove-Item $arq -Force
    }
    It 'recusa login com caracteres estranhos (filtro LDAP)' {
        Get-NomeCompleto -Usuario 'x)(objectClass=*' | Should BeNullOrEmpty
    }
}

Describe 'ConvertTo-UrlSemConsulta' {
    It 'remove consulta, fragmento e porta; normaliza caixa' {
        ConvertTo-UrlSemConsulta 'https://WWW.Site.com:8443/a/b?token=SEGREDO&x=1#topo' | Should Be 'https://www.site.com/a/b'
        ConvertTo-UrlSemConsulta 'http://site.com'                                       | Should Be 'http://site.com/'
        ConvertTo-UrlSemConsulta 'https://site.com?q=1'                                  | Should Be 'https://site.com/'
    }
    It 'nao aceita esquemas que nao sao web' {
        ConvertTo-UrlSemConsulta 'file:///C:/segredo.txt' | Should BeNullOrEmpty
        ConvertTo-UrlSemConsulta 'chrome://settings'      | Should BeNullOrEmpty
        ConvertTo-UrlSemConsulta 'javascript:alert(1)'    | Should BeNullOrEmpty
        ConvertTo-UrlSemConsulta 'https://user:senha@x.com/' | Should BeNullOrEmpty
    }
    It 'limita o tamanho do caminho' {
        (ConvertTo-UrlSemConsulta ('https://a.com/' + ('x' * 500))).Length | Should BeLessThan 230
    }
}

Describe 'Test-HostIgnorado' {
    It 'ignora localhost e a lista configurada (com subdominios)' {
        Test-HostIgnorado 'http://localhost:3000/x' $null          | Should Be $true
        Test-HostIgnorado 'http://127.0.0.1/x' $null               | Should Be $true
        Test-HostIgnorado 'https://intranet.empresa.com/x' @('empresa.com') | Should Be $true
        Test-HostIgnorado 'https://youtube.com/x' @('empresa.com')     | Should Be $false
    }
}

Describe 'Get-LoteNavegacao (tempo estimado por visita)' {
    $agora = [DateTimeOffset]::Parse('2026-03-05T12:00:00Z').ToUnixTimeMilliseconds()
    function V($segAtras, $url) { [pscustomobject]@{ Fonte = 'a'; Ms = [long]($agora - $segAtras * 1000); Url = $url; Titulo = 't'; Navegador = 'Edge' } }

    It 'tempo = ate a proxima visita, limitado ao maximo' {
        $l = @(Get-LoteNavegacao -Visitas @((V 1000 'https://a.com/'), (V 970 'https://b.com/'), (V 900 'https://c.com/')) -AgoraMs $agora -LimiteSeg 300)
        $l.Count | Should Be 3
        $l[0].duracao_seg | Should Be 30     # a.com ate b.com
        $l[1].duracao_seg | Should Be 70     # b.com ate c.com
        $l[2].duracao_seg | Should Be 300    # ultima, ja passou o limite
    }
    It 'um intervalo grande vale so o limite (aba esquecida aberta nao conta horas)' {
        $l = @(Get-LoteNavegacao -Visitas @((V 36000 'https://a.com/'), (V 100 'https://b.com/')) -AgoraMs $agora -LimiteSeg 300)
        $l[0].duracao_seg | Should Be 300
    }
    It 'visitas recentes (dentro do limite) esperam a proxima execucao' {
        $l = @(Get-LoteNavegacao -Visitas @((V 1000 'https://a.com/'), (V 100 'https://b.com/')) -AgoraMs $agora -LimiteSeg 300)
        $l.Count | Should Be 1
        $l[0].url | Should Be 'https://a.com/'
    }
    It 'mistura navegadores em ordem de tempo e respeita o maximo por envio' {
        $v = 1..10 | ForEach-Object { V (2000 - $_ * 10) "https://s$_.com/" }
        @(Get-LoteNavegacao -Visitas $v -AgoraMs $agora -Max 4).Count | Should Be 4
    }
    It 'sem visitas devolve lista vazia' {
        @(Get-LoteNavegacao -Visitas @() -AgoraMs $agora).Count | Should Be 0
    }
}


Describe 'Rede do agente (proxy e motivo da falha)' {
    It 'Initialize-RedeAgente nao gera erro' {
        { Initialize-RedeAgente } | Should Not Throw
    }
    It 'servidor inalcancavel: vai para a fila e guarda o MOTIVO da falha' {
        $fila = Join-Path $env:TEMP ('fila-' + [guid]::NewGuid().ToString('N'))
        $reg = [pscustomobject]@{ data_hora = '2026-03-02T09:00:00-03:00'; host = 'T'; resultado = 'Remoto' }
        $status = Send-Registro -Registro $reg -Servidor 'http://127.0.0.1:9' -Token 'x' -PastaFila $fila
        $status | Should Be 'na_fila'
        (Get-UltimoErroRede) | Should Not BeNullOrEmpty
        @(Get-ChildItem $fila -Filter '*.json').Count | Should Be 1
        Remove-Item $fila -Recurse -Force
    }
}
