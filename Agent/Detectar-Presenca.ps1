<#
.SYNOPSIS
  Agente de presenca: detecta se este PC esta no escritorio ou fora.

.DESCRIPTION
  Regra (resumo):
    1. Procura os adaptadores de rede FISICOS que tem gateway (ignora VPN, Hyper-V, VirtualBox etc.).
    2. Se o gateway e o IP local batem com uma unidade do unidades.json (e o MAC do gateway confere,
       quando configurado), o resultado e "Presencial" na unidade
       (ou "Presencial via VPN" se a VPN tambem estiver ligada).
    3. Senao, se algum adaptador de VPN esta ativo, o resultado e "Remoto via VPN".
    4. Senao, "Remoto". Se nao ha rede fisica com gateway, "Sem rede".
  A unidade e sempre identificada pela rede FISICA; a VPN ligada so muda o rotulo para "... via VPN".
  Sessao remota (RDP), tela bloqueada e ociosidade sao gravadas como colunas extras e NAO mudam o resultado.

  Se existir agente.json (servidor + token), o registro tambem e enviado ao servidor central
  (com fila local quando nao ha conexao) e o unidades.json e atualizado a partir do servidor.

.PARAMETER Detalhado
  Inclui gateway, MAC do gateway, IP local e adaptador no registro. Use nos testes.
.PARAMETER IgnorarHorario
  Por padrao registra 24h, todos os dias (a janela e definida em Test-ForaDoHorario).
.PARAMETER SoMostrar
  Mostra o resultado na tela e nao grava nem envia nada.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Detectar-Presenca.ps1 -Detalhado -IgnorarHorario -SoMostrar
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$Saida,
    [string]$ConfigAgente,
    [switch]$Detalhado,
    [switch]$IgnorarHorario,
    [switch]$SoMostrar,
    [switch]$Forcar,
    [switch]$SemNavegacao,
    [switch]$Foco,         # modo coletor de programas em uso (fica rodando; iniciado pela tarefa PresencaAgenteFoco)
    [switch]$Inventario    # mostra o inventario desta maquina (modelo, serie, SO, RAM, disco, IP) e sai; nada e enviado
)

$pastaScript = $PSScriptRoot
if (-not $pastaScript -and $MyInvocation.MyCommand.Path) { $pastaScript = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $pastaScript) { $pastaScript = (Get-Location).Path }
$pastaDados = Join-Path $env:LOCALAPPDATA 'PresencaPP'
if (-not $Config) {
    $Config = Join-Path $pastaScript 'unidades.json'
    if (-not (Test-Path $Config)) { $alt = Join-Path (Split-Path -Parent $pastaScript) 'Config\unidades.json'; if (Test-Path $alt) { $Config = $alt } }  # rodando da pasta do projeto
}
if (-not $Saida)        { $Saida        = Join-Path $pastaDados 'presenca.csv' }
if (-not $ConfigAgente) { $ConfigAgente = Join-Path $pastaScript 'agente.json' }

Import-Module (Join-Path $pastaScript 'Presenca.psm1') -Force
Import-Module (Join-Path $pastaScript 'Navegacao.psm1') -Force
$arqAtualizador = Join-Path $pastaScript 'Atualizador.psm1'
if (Test-Path $arqAtualizador) { Import-Module $arqAtualizador -Force }
Initialize-RedeAgente  # proxy do Windows com as credenciais do usuario + TLS 1.2

# ---------- mostrar o inventario e sair ----------
if ($Inventario) { Get-InventarioMaquina | ConvertTo-Json -Depth 4; exit 0 }

# ---------- modo coletor de programas em uso ----------
if ($Foco) {
    $cfgFoco = $null
    if (Test-Path $ConfigAgente) { try { $cfgFoco = Get-Content -Path $ConfigAgente -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    if ($cfgFoco -and $cfgFoco.coletar_foco -eq $false) { Write-Host 'Coleta de programas desativada (agente.json: coletar_foco = false).'; exit 0 }
    $titulosFoco = -not ($cfgFoco -and $cfgFoco.coletar_titulos_janela -eq $false)
    if (-not (Test-Path $pastaDados)) { $null = New-Item -ItemType Directory -Path $pastaDados -Force }
    Write-Host (Start-ColetaFoco -PastaDados $pastaDados -Titulos $titulosFoco)
    exit 0
}

$agora = Get-Date
if (-not $IgnorarHorario -and (Test-ForaDoHorario $agora)) {
    Write-Host 'Fora do horario de coleta. Nada registrado. Use -IgnorarHorario para testar.'
    exit 0
}

# ---------- agente.json (opcional) ----------
$agente = $null
if (Test-Path $ConfigAgente) {
    try { $agente = Get-Content -Path $ConfigAgente -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
$usarServidor = ($agente -and $agente.servidor -and $agente.token -and -not $SoMostrar)

# Atualiza unidades.json a partir do servidor (cache em pasta de dados, para nao exigir permissao na pasta do programa)
$configCache = Join-Path $pastaDados 'unidades.json'
if ($usarServidor) {
    if (-not (Test-Path $pastaDados)) { $null = New-Item -ItemType Directory -Path $pastaDados -Force }
    $null = Update-ConfigUnidades -Servidor $agente.servidor -Token $agente.token -Destino $configCache
}
$arquivoConfig = $Config
if ((-not $PSBoundParameters.ContainsKey('Config')) -and (Test-Path $configCache)) { $arquivoConfig = $configCache }

try {
    $cfg = Get-Content -Path $arquivoConfig -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
} catch {
    Write-Error "Nao foi possivel ler a configuracao em '$arquivoConfig': $($_.Exception.Message)"
    exit 1
}

# ---------- coleta e decisao ----------
$vpnAtivos  = @(Get-VpnAtivos $cfg)
$candidatos = @(Get-CandidatosRede $cfg)
$d = Resolve-Presenca -Candidatos $candidatos -Config $cfg -VpnAtiva ($vpnAtivos.Count -gt 0) `
        -ObterMac { param($g, $i) Get-MacGateway $g $i }
$sessao = Get-EstadoSessao
$usuarioLogado = Get-UsuarioLogado
$nomeCompleto = Get-NomeCompleto -Usuario $usuarioLogado -ArquivoCache $(if ($SoMostrar) { $null } else { Join-Path $pastaDados 'nome.json' })

$versaoAgente = if (Get-Command Get-VersaoLocal -ErrorAction SilentlyContinue) { (Get-VersaoLocal $pastaScript).ToString() } else { '' }

$registro = [pscustomobject]@{
    data_hora     = $agora.ToString('yyyy-MM-ddTHH:mm:sszzz')
    host          = $env:COMPUTERNAME
    usuario       = $usuarioLogado
    nome_completo = $nomeCompleto
    resultado     = $d.Resultado
    unidade       = $d.Unidade
    vpn_ativa     = $(if ($vpnAtivos.Count -gt 0) { 'sim' } else { 'nao' })
    vpn_adaptador = ($vpnAtivos | ForEach-Object { $_.InterfaceDescription }) -join ' + '
    confianca     = $d.Confianca
    mac_confere   = $d.MacConfere
    motivo        = $d.Motivo
    sessao_remota = $(if ($sessao.SessaoRemota) { 'sim' } else { 'nao' })
    bloqueada     = $(if ($sessao.Bloqueada) { 'sim' } else { 'nao' })
    ocioso_seg    = $sessao.OciosoSeg
    gw_ip         = $(if ($Detalhado) { $d.Gateway } else { '' })
    gw_mac        = $(if ($Detalhado) { $d.GatewayMac } else { '' })
    ip_local      = $(if ($Detalhado) { $d.IpLocal } else { '' })
    adaptador     = $(if ($Detalhado) { $d.Adaptador } else { '' })
    versao_agente = $versaoAgente
}

$registro | Format-List

$coletarNavegacao = (-not $SemNavegacao) -and (-not ($agente -and $agente.coletar_navegacao -eq $false))
$limiteVisitaSeg  = if ($agente -and $agente.limite_visita_seg) { [int]$agente.limite_visita_seg } else { 300 }
$ignorarHosts     = if ($agente) { @($agente.ignorar_sites) } else { @() }

if ($SoMostrar) {
    if ($coletarNavegacao) {
        $nav = Get-NavegacaoNova -PastaDados $pastaDados -LimiteSeg $limiteVisitaSeg -IgnorarHosts $ignorarHosts
        Write-Host "Navegacao: $(@($nav.Lote).Count) acesso(s) novo(s) seriam enviados (nada foi enviado)."
        @($nav.Lote) | Select-Object -First 5 | ForEach-Object { Write-Host "  $($_.navegador)  $($_.duracao_seg)s  $($_.url)" }
    }
    Write-Host 'Modo -SoMostrar: nada foi gravado.'
    exit 0
}

# Anti-rajada: uma troca de rede gera varios eventos seguidos. O agent SEMPRE le o estado atual, mas nao registra
# de novo se o estado for igual ao ultimo registrado ha menos de 30 s (um estado diferente e sempre registrado).
$assinatura = "$($d.Resultado)|$($d.Unidade)|$($registro.vpn_ativa)|$($d.Gateway)|$($d.IpLocal)"
$arqEstado  = Join-Path $pastaDados 'ultimo-envio.json'
if (-not $Forcar -and (Test-RegistroRedundante -Assinatura $assinatura -ArquivoEstado $arqEstado -Agora $agora -JanelaSeg 30)) {
    Write-Host 'Mesmo estado registrado ha menos de 30 s (rajada de eventos); ignorando. Use -Forcar para registrar mesmo assim.'
    exit 0
}

try {
    $pasta = Split-Path -Parent $Saida
    if (-not (Test-Path $pasta)) { $null = New-Item -ItemType Directory -Path $pasta -Force }
    $registro | Select-Object * -ExcludeProperty versao_agente | Export-Csv -Path $Saida -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
    Write-Host "Registro gravado em: $Saida"
} catch {
    Write-Error "Nao foi possivel gravar em '$Saida': $($_.Exception.Message)"
    exit 1
}
try {
    if (-not (Test-Path $pastaDados)) { $null = New-Item -ItemType Directory -Path $pastaDados -Force }
    Save-EstadoEnvio -Assinatura $assinatura -ArquivoEstado $arqEstado -Agora $agora
} catch { }

if ($usarServidor) {
    $status = Send-Registro -Registro $registro -Servidor $agente.servidor -Token $agente.token `
                -PastaFila (Join-Path $pastaDados 'fila')
    Write-Host "Servidor: $status"
    if ($status -ne 'enviado' -and (Get-UltimoErroRede)) { Write-Host "  Motivo: $(Get-UltimoErroRede)" -ForegroundColor Yellow }

    # Atualizacao: a cada ~1 h confere se ha versao nova e deixa o pacote na pasta de entrada (a tarefa SYSTEM instala).
    if ($status -eq 'enviado' -and (Get-Command Save-AtualizacaoEntrada -ErrorAction SilentlyContinue)) {
        try {
            $arqChecagem = Join-Path $pastaDados 'ultima-checagem-update.txt'
            $deve = (-not (Test-Path $arqChecagem)) -or (((Get-Date) - (Get-Item $arqChecagem).LastWriteTime).TotalMinutes -ge 60)
            if ($deve) {
                Set-Content -Path $arqChecagem -Value (Get-Date -Format o) -Encoding ASCII
                $entradaUpd = Join-Path $env:ProgramData 'PresencaAgente\entrada'
                if (Test-Path $entradaUpd) {
                    if (Save-AtualizacaoEntrada -Servidor $agente.servidor -Token $agente.token -VersaoLocal (Get-VersaoLocal $pastaScript) -PastaEntrada $entradaUpd) {
                        Write-Host 'Atualizacao baixada; sera instalada pelo atualizador.'
                    }
                }
            }
        } catch { }
    }

    # Sites acessados (historico dos navegadores). O ponto de leitura so avanca depois que o servidor confirma o recebimento;
    # sem internet, os mesmos acessos sao reenviados na proxima execucao.
    if ($coletarNavegacao) {
        try {
            $nav = Get-NavegacaoNova -PastaDados $pastaDados -LimiteSeg $limiteVisitaSeg -IgnorarHosts $ignorarHosts
            if (@($nav.Lote).Count -gt 0) {
                $ok = Send-Navegacao -Lote $nav.Lote -Servidor $agente.servidor -Token $agente.token -Maquina $env:COMPUTERNAME `
                        -Usuario $usuarioLogado -NomeCompleto $nomeCompleto
                if ($ok) { Save-CursorNavegacao -Cursor $nav.Cursor -Arquivo $nav.ArquivoCursor }
                Write-Host "Navegacao: $(@($nav.Lote).Count) acesso(s) - $(if ($ok) { 'enviado' } else { 'falhou, tentara de novo' })"
                if (-not $ok -and (Get-UltimoErroRede)) { Write-Host "  Motivo: $(Get-UltimoErroRede)" -ForegroundColor Yellow }
            } else {
                Save-CursorNavegacao -Cursor $nav.Cursor -Arquivo $nav.ArquivoCursor
                Write-Host 'Navegacao: nada novo.'
            }
        } catch { Write-Host "Navegacao: erro ($($_.Exception.Message))" }
    }

    # Inventario da maquina: 1x por dia (e quando a versao do agent muda). Nunca derruba a execucao.
    if (Get-Command Invoke-InventarioDiario -ErrorAction SilentlyContinue) {
        try {
            $ri = Invoke-InventarioDiario -Servidor $agente.servidor -Token $agente.token -ArquivoEstado (Join-Path $pastaDados 'inventario.json') -VersaoAgente $versaoAgente
            if ($ri -ne 'nao-precisa') { Write-Host "Inventario: $ri" }
        } catch { Write-Host "Inventario: erro ($($_.Exception.Message))" }
    }

    # Programas em uso (fila gravada pelo coletor PresencaAgenteFoco): envia o que houver; sem rede, fica na fila local.
    if (-not ($agente -and $agente.coletar_foco -eq $false) -and (Get-Command Send-Foco -ErrorAction SilentlyContinue)) {
        try {
            $rf = Send-Foco -Servidor $agente.servidor -Token $agente.token -PastaDados $pastaDados -Maquina $env:COMPUTERNAME -Usuario $usuarioLogado -NomeCompleto $nomeCompleto
            if ($rf.Enviados -gt 0 -or $rf.Falhou) { Write-Host "Programas em uso: $($rf.Enviados) segmento(s) $(if ($rf.Falhou) { '- falhou, tentara de novo' } else { 'enviado(s)' })" }
        } catch { Write-Host "Programas em uso: erro ($($_.Exception.Message))" }
    }
}
