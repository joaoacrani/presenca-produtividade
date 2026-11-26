<#
.SYNOPSIS
  Instala (ou remove) o agente de presenca neste PC. Precisa rodar como Administrador.

.DESCRIPTION
  - Copia o agente para C:\Program Files\PresencaAgente
  - Grava agente.json com o endereco do servidor e o token
  - Cria a tarefa agendada "PresencaAgente": roda no logon e a cada N minutos, no contexto do usuario
    logado (necessario para saber a sessao/bloqueio/ociosidade), sem janela visivel.

.EXAMPLE
  .\Install-Agente.ps1 -Servidor https://presenca.exemplo.com.br -Token SEU_TOKEN
  .\Install-Agente.ps1 -Servidor https://... -Token ... -SemNavegacao   (so presenca, sem coletar sites acessados)
  .\Install-Agente.ps1 -Desinstalar
#>
[CmdletBinding()]
param(
    [string]$Servidor,
    [string]$Token,
    [int]$IntervaloMin = 5,
    [switch]$SemNavegacao,
    [switch]$Desinstalar,
    [switch]$SemRegistroDesinstalacao   # usado pelo instalador .exe (que tem a propria entrada no Windows)
)

$ErrorActionPreference = 'Stop'
$nomeTarefa = 'PresencaAgente'
$destino    = Join-Path $env:ProgramFiles 'PresencaAgente'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Error 'Execute este script como Administrador.'; exit 1 }

$nomeTarefaUpdate = 'PresencaAgenteUpdate'
$nomeTarefaFoco = 'PresencaAgenteFoco'
$arquivosAgente = 'Detectar-Presenca.ps1', 'Presenca.psm1', 'Navegacao.psm1', 'Atualizador.psm1', 'Atualizar-Agente.ps1', 'chave-publica.xml', 'versao.txt'
$pastaDadosSistema = Join-Path $env:ProgramData 'PresencaAgente'

if ($Desinstalar) {
    Unregister-ScheduledTask -TaskName $nomeTarefa -Confirm:$false -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $nomeTarefaFoco -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $nomeTarefaFoco -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $nomeTarefaUpdate -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($p in $destino, "$destino.bak", "$destino.novo", $pastaDadosSistema) { if (Test-Path $p) { Remove-Item -Path $p -Recurse -Force } }
    $modUpd = Join-Path $PSScriptRoot 'Atualizador.psm1'
    if (Test-Path $modUpd) { Import-Module $modUpd -Force; Remove-DesinstalacaoWindows }
    Write-Host 'Agente removido. (Os dados locais em %LOCALAPPDATA%\PresencaPP de cada usuario nao foram apagados.)'
    exit 0
}

if (-not $Servidor -or -not $Token) { Write-Error 'Informe -Servidor e -Token.'; exit 1 }
$httpLocal = '^http://(10(\.\d{1,3}){3}|192\.168(\.\d{1,3}){2}|172\.(1[6-9]|2\d|3[01])(\.\d{1,3}){2}|localhost|127\.0\.0\.1)(:\d+)?/?$'
if ($Servidor -notmatch '^https://' -and $Servidor -notmatch $httpLocal) {
    Write-Error 'O servidor deve usar https:// (http so e aceito para localhost e IPs de rede interna, em testes).'; exit 1
}
if ($Servidor -like 'http://*') { Write-Host 'Aviso: conexao sem criptografia (http). Use apenas em teste, dentro da rede interna.' -ForegroundColor Yellow }
if ($IntervaloMin -lt 5) { Write-Error 'IntervaloMin minimo: 5.'; exit 1 }

$origem = $PSScriptRoot
# No pacote, unidades.json fica ao lado; rodando direto da pasta do projeto, vem de ..\Config\
$arqUnidades = Join-Path $origem 'unidades.json'
if (-not (Test-Path $arqUnidades)) { $arqUnidades = Join-Path (Split-Path -Parent $origem) 'Config\unidades.json' }
foreach ($arq in $arquivosAgente) {
    if (-not (Test-Path (Join-Path $origem $arq))) { Write-Error "Arquivo nao encontrado: $arq (para gerar a chave: Agent\Assinar-Atualizacao.ps1 -NovaChave)"; exit 1 }
}
if (-not (Test-Path $arqUnidades)) { Write-Error 'Arquivo nao encontrado: unidades.json'; exit 1 }

if (-not (Test-Path $destino)) { $null = New-Item -ItemType Directory -Path $destino -Force }
foreach ($arq in $arquivosAgente) {
    Copy-Item -Path (Join-Path $origem $arq) -Destination $destino -Force
}
Copy-Item -Path $arqUnidades -Destination (Join-Path $destino 'unidades.json') -Force
@{ servidor = $Servidor; token = $Token; coletar_navegacao = (-not $SemNavegacao) } | ConvertTo-Json | Set-Content -Path (Join-Path $destino 'agente.json') -Encoding UTF8

# Programa: conhost --headless evita o "piscar" de janela do PowerShell
$script = Join-Path $destino 'Detectar-Presenca.ps1'
$argumentos = "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
# Gatilhos: logon, a cada N min, troca de rede (eventos do Windows), desbloqueio de tela.
# Grupo "Usuarios" pelo SID (S-1-5-32-545): o nome muda conforme o idioma do Windows (Users / Usuarios)
Import-Module (Join-Path $destino 'Presenca.psm1') -Force
$principalXml = '<Principal id="Author"><GroupId>S-1-5-32-545</GroupId><RunLevel>LeastPrivilege</RunLevel></Principal>'
$xml = New-XmlTarefaPresenca -Comando "$env:SystemRoot\System32\conhost.exe" -Argumentos $argumentos `
        -PrincipalXml $principalXml -IntervaloMin $IntervaloMin

Register-ScheduledTask -TaskName $nomeTarefa -Xml $xml -Force | Out-Null

# Coletor de programas em uso (tempo na frente de cada programa): tarefa propria, sempre rodando enquanto o usuario esta logado
$argFoco = "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -Foco"
$xmlFoco = New-XmlTarefaFoco -Comando "$env:SystemRoot\System32\conhost.exe" -Argumentos $argFoco -PrincipalXml $principalXml
Register-ScheduledTask -TaskName $nomeTarefaFoco -Xml $xmlFoco -Force | Out-Null
try { Start-ScheduledTask -TaskName $nomeTarefaFoco } catch { }

# Atualizador automatico: tarefa SYSTEM (no boot e a cada 6 h). Pasta "entrada": o agent do usuario deixa ali o
# pacote baixado (quando so ele tem acesso a internet/proxy); a instalacao exige assinatura valida de qualquer forma.
Import-Module (Join-Path $destino 'Atualizador.psm1') -Force
$entrada = Join-Path $pastaDadosSistema 'entrada'
$null = New-Item -ItemType Directory -Path $entrada -Force
& icacls.exe $entrada /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
$xmlUpdate = New-XmlTarefaAtualizador -Script (Join-Path $destino 'Atualizar-Agente.ps1')
Register-ScheduledTask -TaskName $nomeTarefaUpdate -Xml $xmlUpdate -Force | Out-Null

if (-not $SemRegistroDesinstalacao) {
    $null = Register-DesinstalacaoWindows -Destino $destino -Versao ((Get-Content (Join-Path $destino 'versao.txt') -Raw).Trim())
}

Write-Host "Agente instalado em $destino (versao $((Get-Content (Join-Path $destino 'versao.txt') -Raw).Trim())). Tarefa '$nomeTarefa': a cada $IntervaloMin min, ao trocar de rede, ao fazer logon e ao desbloquear a tela."
Write-Host "Atualizacao automatica ativa (tarefa '$nomeTarefaUpdate')."
Write-Host 'Teste agora: Start-ScheduledTask -TaskName PresencaAgente'

