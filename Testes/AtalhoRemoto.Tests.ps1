# O atalho pp-remoto:// so pode aceitar ID numerico e senha alfanumerica; nada alem disso chega a um comando.
$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Remoto\pp-remoto.ps1'

Describe 'pp-remoto: so a janela principal do RustDesk e fechada' {
    It 'principal (titulo RustDesk) pode fechar' { (& $script -SoValidar -Titulo 'RustDesk') | Should Be $true }
    It 'sessoes abertas nao sao fechadas (acesso a outra maquina em andamento)' {
        foreach ($t in '199602839@desktop - Remote Desktop - RustDesk', '123456789@srv - File Transfer - RustDesk', '', 'Outro programa') {
            (& $script -SoValidar -Titulo $t) | Should Be $false
        }
    }
}

Describe 'pp-remoto: validacao do link' {
    It 'aceita ID e senha validos' {
        $r = & $script -Url 'pp-remoto://conectar?id=413462412&senha=AbCdEfGh1234567890xy' -SoValidar
        $r.Id | Should Be '413462412'
        $r.Senha | Should Be 'AbCdEfGh1234567890xy'
    }
    It 'aceita o link como o navegador o reescreve (barra antes da interrogacao e no fim)' {
        foreach ($u in 'pp-remoto://conectar/?id=413462412&senha=AbCdEfGh1234567890xy', 'pp-remoto://conectar/?id=413462412&senha=AbCdEfGh1234567890xy/', 'pp-remoto://conectar?id=413462412&senha=AbCdEfGh1234567890xy/') {
            $r = & $script -Url $u -SoValidar
            $r.Id | Should Be '413462412'
            $r.Senha | Should Be 'AbCdEfGh1234567890xy'
        }
    }
    It 'recusa tentativas de injecao e formatos errados' {
        $ruins = @(
            'pp-remoto://conectar?id=123456789&senha=curta',
            'pp-remoto://conectar?id=abc&senha=AbCdEfGh1234567890xy',
            'pp-remoto://conectar?id=123456789&senha=AbCdEfGh1234567890xy;calc',
            'pp-remoto://conectar?id=123456789&senha=AbCdEfGh1234567890xy&x=1',
            'pp-remoto://conectar?id=123456789 & calc&senha=AbCdEfGh1234567890xy',
            'pp-remoto://conectar?id=1234567890123&senha=AbCdEfGh1234567890xy',
            'pp-remoto://outra?id=123456789&senha=AbCdEfGh1234567890xy',
            'rustdesk://conectar?id=123456789&senha=AbCdEfGh1234567890xy',
            ''
        )
        foreach ($u in $ruins) { $r = & $script -Url $u -SoValidar; ($null -eq $r) | Should Be $true }
    }
}
