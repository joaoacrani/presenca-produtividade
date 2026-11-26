# Testes do batimento dos servidores (tarefa SYSTEM que avisa "no ar" sem usuario logado).
$raiz = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $raiz 'Agent\Atualizador.psm1') -Force
Import-Module (Join-Path $raiz 'Agent\Presenca.psm1') -Force

Describe 'Batimento: tarefa agendada' {
    It 'XML e valido, roda como SYSTEM, a cada 5 min e no boot, chamando o atualizador com -Batimento' {
        $xml = [xml](New-XmlTarefaBatimento -Script 'C:\Program Files\PresencaAgente\Atualizar-Agente.ps1')
        $xml.Task.Principals.Principal.UserId | Should Be 'S-1-5-18'
        $xml.Task.Triggers.TimeTrigger.Repetition.Interval | Should Be 'PT5M'
        ($xml.Task.Triggers.BootTrigger -ne $null) | Should Be $true
        $xml.Task.Actions.Exec.Arguments | Should Match 'Atualizar-Agente.ps1'
        $xml.Task.Actions.Exec.Arguments | Should Match '-Batimento'
        $xml.Task.Settings.ExecutionTimeLimit | Should Be 'PT2M'
    }
    It 'o atualizador aceita -Batimento e o desinstalador conhece a tarefa' {
        (Get-Content (Join-Path $raiz 'Agent\Atualizar-Agente.ps1') -Raw) | Should Match '\[switch\]\$Batimento'
        (Get-Content (Join-Path $raiz 'Agent\Atualizador.psm1') -Raw) | Should Match "'PresencaAgenteBatimento'(, 'PresencaAgenteSoftware')?\),"
    }
}

Describe 'Batimento: Sync-TarefaBatimento segue a politica do painel' {
    BeforeEach {
        $global:logBat = New-Object System.Collections.ArrayList
        Mock -ModuleName Atualizador Register-ScheduledTask { [void]$global:logBat.Add('registrou') }
        Mock -ModuleName Atualizador Unregister-ScheduledTask { [void]$global:logBat.Add('removeu') }
        Mock -ModuleName Atualizador Start-ScheduledTask { [void]$global:logBat.Add('iniciou') }
        Mock -ModuleName Atualizador Stop-ScheduledTask { }
    }
    It 'servidor sem tarefa: cria e inicia' {
        Mock -ModuleName Atualizador Get-ScheduledTask { $null }
        (Sync-TarefaBatimento -Destino $TestDrive -Politica $true) | Should Be 'criada'
        ($global:logBat -join ',') | Should Be 'registrou,iniciou'
    }
    It 'servidor que ja tem a tarefa: nao mexe, a nao ser que tenha acabado de atualizar' {
        Mock -ModuleName Atualizador Get-ScheduledTask { [pscustomobject]@{ TaskName = 'PresencaAgenteBatimento' } }
        (Sync-TarefaBatimento -Destino $TestDrive -Politica $true) | Should Be 'mantida'
        $global:logBat.Count | Should Be 0
        (Sync-TarefaBatimento -Destino $TestDrive -Politica $true -Atualizou $true) | Should Be 'criada'
    }
    It 'deixou de ser servidor: remove a tarefa' {
        Mock -ModuleName Atualizador Get-ScheduledTask { [pscustomobject]@{ TaskName = 'PresencaAgenteBatimento' } }
        (Sync-TarefaBatimento -Destino $TestDrive -Politica $false) | Should Be 'removida'
        ($global:logBat -join ',') | Should Be 'removeu'
    }
    It 'nao e servidor e nao tem tarefa: nada a fazer' {
        Mock -ModuleName Atualizador Get-ScheduledTask { $null }
        (Sync-TarefaBatimento -Destino $TestDrive -Politica $false) | Should Be 'mantida'
        $global:logBat.Count | Should Be 0
    }
    It 'servidor do painel inalcancavel: nao decide nada (nao remove nem cria)' {
        Mock -ModuleName Atualizador Get-ScheduledTask { [pscustomobject]@{ TaskName = 'PresencaAgenteBatimento' } }
        (Sync-TarefaBatimento -Destino $TestDrive -Politica $null) | Should Be 'sem-decisao'
        $global:logBat.Count | Should Be 0
    }
}

Describe 'Batimento: politica e envio' {
    It 'Get-BatimentoPolitica devolve true, false ou null (servidor fora do ar)' {
        Mock -ModuleName Presenca Invoke-RestMethod { [pscustomobject]@{ ativo = $true } }
        (Get-BatimentoPolitica -Servidor 'https://x/p' -Token 't') | Should Be $true
        Mock -ModuleName Presenca Invoke-RestMethod { [pscustomobject]@{ ativo = $false } }
        (Get-BatimentoPolitica -Servidor 'https://x/p' -Token 't') | Should Be $false
        Mock -ModuleName Presenca Invoke-RestMethod { throw 'sem rede' }
        (Get-BatimentoPolitica -Servidor 'https://x/p' -Token 't') | Should BeNullOrEmpty
    }
    It 'Send-Batimento manda o nome da maquina e a hora do boot para a rota certa' {
        $global:chamadaBat = $null
        Mock -ModuleName Presenca Invoke-RestMethod { $global:chamadaBat = @{ Uri = $Uri; Corpo = [Text.Encoding]::UTF8.GetString($Body) } }
        (Send-Batimento -Servidor 'https://x/p/' -Token 't') | Should Be $true
        $global:chamadaBat.Uri | Should Be 'https://x/p/api/batimento'
        $j = $global:chamadaBat.Corpo | ConvertFrom-Json
        $j.host | Should Be $env:COMPUTERNAME
        ([long]$j.boot -gt 1500000000000) | Should Be $true
    }
    It 'Send-Batimento devolve false se o servidor nao responde' {
        Mock -ModuleName Presenca Invoke-RestMethod { throw 'fora' }
        (Send-Batimento -Servidor 'https://x/p' -Token 't') | Should Be $false
    }
    It 'Get-InicioSistemaMs devolve uma data no passado' {
        $ms = Get-InicioSistemaMs
        ($ms -gt 1500000000000 -and $ms -lt ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())) | Should Be $true
    }
}
