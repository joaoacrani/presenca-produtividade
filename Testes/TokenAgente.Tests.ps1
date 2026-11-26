# Testes da troca do token de cadastro pelo token proprio da maquina (Register-TokenAgente).
$raiz = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $raiz 'Agent\Presenca.psm1') -Force

Describe 'Token proprio da maquina' {
    BeforeEach {
        $script:arq = Join-Path $TestDrive 'agente.json'
        @{ servidor = 'https://exemplo.com/presenca'; token = 'cadastro-123'; coletar_navegacao = $true } | ConvertTo-Json | Set-Content -Path $script:arq -Encoding UTF8
    }
    It 'troca o token de cadastro pelo da maquina e mantem o restante da configuracao' {
        Mock -ModuleName Presenca Invoke-RestMethod { [pscustomobject]@{ ok = $true; token = 'ppm_abc123' } }
        (Register-TokenAgente -Servidor 'https://exemplo.com/presenca' -ArquivoAgente $script:arq) | Should Be 'trocado'
        $j = Get-Content $script:arq -Raw -Encoding UTF8 | ConvertFrom-Json
        $j.token | Should Be 'ppm_abc123'
        $j.servidor | Should Be 'https://exemplo.com/presenca'
        $j.coletar_navegacao | Should Be $true
        (Test-Path ($script:arq + '.novo')) | Should Be $false
    }
    It 'envia o nome desta maquina e usa o token de cadastro no cabecalho' {
        $global:chamada = $null
        Mock -ModuleName Presenca Invoke-RestMethod { $global:chamada = @{ auth = $Headers.Authorization; uri = $Uri; corpo = [Text.Encoding]::UTF8.GetString($Body) }; [pscustomobject]@{ ok = $true; token = 'ppm_x' } }
        (Register-TokenAgente -Servidor 'https://exemplo.com/presenca' -ArquivoAgente $script:arq) | Should Be 'trocado'
        $global:chamada.auth | Should Be 'Bearer cadastro-123'
        $global:chamada.uri | Should Be 'https://exemplo.com/presenca/api/agente/registrar'
        $global:chamada.corpo | Should Match ("""host"":""" + $env:COMPUTERNAME)
    }
    It 'quem ja tem token da maquina nao chama o servidor' {
        @{ servidor = 'https://exemplo.com/presenca'; token = 'ppm_ja' } | ConvertTo-Json | Set-Content -Path $script:arq -Encoding UTF8
        Mock -ModuleName Presenca Invoke-RestMethod { throw 'nao deveria chamar' }
        (Register-TokenAgente -Servidor 'https://exemplo.com/presenca' -ArquivoAgente $script:arq) | Should Be 'ok'
    }
    It 'servidor fora do ar ou antigo: nada muda no arquivo' {
        Mock -ModuleName Presenca Invoke-RestMethod { throw 'sem conexao' }
        (Register-TokenAgente -Servidor 'https://exemplo.com/presenca' -ArquivoAgente $script:arq) | Should Match '^falha-http-'
        (Get-Content $script:arq -Raw -Encoding UTF8 | ConvertFrom-Json).token | Should Be 'cadastro-123'
    }
    It 'resposta sem token valido: nada muda' {
        Mock -ModuleName Presenca Invoke-RestMethod { [pscustomobject]@{ ok = $true } }
        (Register-TokenAgente -Servidor 'https://exemplo.com/presenca' -ArquivoAgente $script:arq) | Should Be 'falha-resposta'
        (Get-Content $script:arq -Raw -Encoding UTF8 | ConvertFrom-Json).token | Should Be 'cadastro-123'
    }
    It 'sem arquivo ou sem token: nao faz nada' {
        (Register-TokenAgente -Servidor 'x' -ArquivoAgente (Join-Path $TestDrive 'nao-existe.json')) | Should Be 'falha-leitura'
        @{ servidor = 'x' } | ConvertTo-Json | Set-Content -Path $script:arq -Encoding UTF8
        (Register-TokenAgente -Servidor 'x' -ArquivoAgente $script:arq) | Should Be 'sem-token'
    }
    It 'o atualizador chama a troca e reinicia o coletor de programas' {
        $t = Get-Content (Join-Path $raiz 'Agent\Atualizar-Agente.ps1') -Raw
        $t | Should Match 'Register-TokenAgente'
        $t | Should Match "ppm_\*"
    }
    It 'a versao do agent foi incrementada' {
        ((Get-Content (Join-Path $raiz 'Agent\versao.txt') -Raw).Trim()) | Should Be '1.7.0'
    }
}
