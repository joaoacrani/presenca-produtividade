# Instala o agent neste PC apontando para o servidor. Pede permissao de administrador sozinho.
# Uso:  Instalar-Agente-Facil.ps1                       (servidor local: http://localhost:3000)
#       Instalar-Agente-Facil.ps1 -Servidor https://presenca.suaempresa.com.br -Token SEU_TOKEN
param(
    [string]$Servidor = 'http://localhost:3000',
    [string]$Token
)
$ErrorActionPreference = 'Stop'

# Pacote gerado por Gerar-Pacote.ps1: servidor e token vem do pacote.json ao lado deste script
$arqPacote = Join-Path $PSScriptRoot 'pacote.json'
if ((-not $Token) -and (Test-Path $arqPacote)) {
    $p = Get-Content $arqPacote -Raw -Encoding UTF8 | ConvertFrom-Json
    $Servidor = $p.servidor
    $Token = $p.token
}

$admin =([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Servidor `"$Servidor`""
    if ($Token) { $a += " -Token `"$Token`"" }
    Start-Process powershell -Verb RunAs -ArgumentList $a
    exit 0
}

try {
    if (-not $Token) {
        $envFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'Servidor\local\.env'
        if (-not (Test-Path $envFile)) { throw 'Ligue o servidor uma vez (Iniciar-Servidor.bat) antes de instalar o agent: ele gera o token.' }
        $linha = Get-Content $envFile | Where-Object { $_ -match '^\s*AGENT_TOKEN\s*=' } | Select-Object -First 1
        $Token = ($linha -replace '^\s*AGENT_TOKEN\s*=\s*', '').Trim()
        if (-not $Token) { throw 'AGENT_TOKEN nao encontrado em Servidor\local\.env' }
    }

    & (Join-Path $PSScriptRoot 'Install-Agente.ps1') -Servidor $Servidor -Token $Token

    Write-Host 'Executando o agent uma vez agora...'
    Start-ScheduledTask -TaskName 'PresencaAgente'
    Start-Sleep -Seconds 6
    $info = Get-ScheduledTaskInfo -TaskName 'PresencaAgente'
    Write-Host "Ultimo resultado da tarefa: $($info.LastTaskResult) (0 = sucesso)"
    Write-Host ''
    Write-Host 'Pronto. Atualize o painel: este PC deve aparecer.' -ForegroundColor Green
    Write-Host '(O agent envia dados 24h, todos os dias.)'
} catch {
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
}
Read-Host 'Pressione Enter para fechar'
