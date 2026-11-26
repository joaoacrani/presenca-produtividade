# Funcoes do agente de presenca. Separadas do script para poderem ser testadas (Pester).

function ConvertTo-IpNumero([string]$ip) {
    $bytes = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [uint64][BitConverter]::ToUInt32($bytes, 0)
}

function Test-IpEmSubrede([string]$ip, [string]$cidr) {
    $partes  = $cidr.Split('/')
    $rede    = ConvertTo-IpNumero $partes[0]
    $prefixo = [int]$partes[1]
    $mascara = [uint64]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefixo))
    return ((([uint64](ConvertTo-IpNumero $ip)) -band $mascara) -eq ($rede -band $mascara))
}

function Test-Corresponde([string]$texto, $padroes) {
    foreach ($p in @($padroes)) {
        if ($texto -like "*$p*") { return $true }
    }
    return $false
}

function ConvertTo-MacNormal([string]$mac) {
    if (-not $mac) { return $null }
    $limpo = ($mac -replace '[:\-\.]', '').ToUpper()
    if ($limpo.Length -ne 12) { return $null }
    return ($limpo -replace '(..)(?=.)', '$1-')
}

function Test-ForaDoHorario([datetime]$Agora, [int]$HoraInicio = 0, [int]$HoraFim = 24, [bool]$SomenteDiasUteis = $false) {
    # Padrao: coleta 24h, todos os dias. Para limitar, passe a janela (ex.: 8, 18, $true).
    $dia = [int]$Agora.DayOfWeek
    if ($SomenteDiasUteis -and ($dia -eq 0 -or $dia -eq 6)) { return $true }
    return ($Agora.Hour -lt $HoraInicio -or $Agora.Hour -ge $HoraFim)
}

function Get-MacGateway([string]$gateway, [int]$indiceInterface) {
    for ($i = 0; $i -lt 2; $i++) {
        $vizinho = Get-NetNeighbor -IPAddress $gateway -InterfaceIndex $indiceInterface -ErrorAction SilentlyContinue |
            Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress -notmatch '^(00-)*00$' } |
            Select-Object -First 1
        if ($vizinho) { return (ConvertTo-MacNormal $vizinho.LinkLayerAddress) }
        if ($i -eq 0) { $null = Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue }
    }
    return $null
}

function Get-UsuarioLogado {
    try {
        $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($u) { return $u }
    } catch { }
    return "$env:USERDOMAIN\$env:USERNAME"
}

function Get-CandidatosRede($Config) {
    $candidatos = @()
    foreach ($c in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
        if (-not $c.IPv4DefaultGateway) { continue }
        if ($c.NetAdapter -and $c.NetAdapter.Status -ne 'Up') { continue }
        if (Test-Corresponde $c.InterfaceDescription $Config.adaptadores_ignorar) { continue }
        $ipLocal = @($c.IPv4Address)[0].IPAddress
        if (-not $ipLocal -or $ipLocal.StartsWith('169.254.')) { continue }
        $candidatos += [pscustomobject]@{
            Adaptador = $c.InterfaceAlias
            Indice    = [int]$c.InterfaceIndex
            IpLocal   = $ipLocal
            Gateway   = @($c.IPv4DefaultGateway)[0].NextHop
        }
    }
    # Quem chama deve usar @(Get-CandidatosRede ...)
    return $candidatos
}

function Get-VpnAtivos($Config) {
    $lista = @(Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and (Test-Corresponde $_.InterfaceDescription $Config.adaptadores_vpn) })
    # Quem chama deve usar @(Get-VpnAtivos ...) para a contagem valer com 0, 1 ou varios itens.
    return $lista
}

# Decide Presencial / Presencial via VPN / Remoto via VPN / Remoto / Sem rede.
# "Presencial via VPN" = na rede fisica de uma unidade, mas com a VPN ligada.
# $ObterMac: scriptblock { param($gateway, $indice) } que devolve o MAC do gateway (injetavel para testes).
function Resolve-Presenca {
    param(
        $Candidatos,
        $Config,
        [bool]$VpnAtiva,
        [scriptblock]$ObterMac
    )
    $resultado = $null; $unidade = ''; $confianca = ''; $macConfere = ''; $motivo = ''
    $gwInfo = ''; $macInfo = ''; $ipInfo = ''; $adInfo = ''
    $avisos = @()

    foreach ($cand in @($Candidatos)) {
        $mac = ConvertTo-MacNormal ([string](& $ObterMac $cand.Gateway $cand.Indice))
        foreach ($u in $Config.unidades) {
            if (-not (Test-IpEmSubrede $cand.IpLocal $u.sub_rede)) { continue }
            $pares = @($u.gateways | Where-Object { $_.ip -eq $cand.Gateway })
            if ($pares.Count -eq 0) { continue }
            $macsOk = @($pares | ForEach-Object { ConvertTo-MacNormal $_.mac } | Where-Object { $_ })
            if ($macsOk.Count -eq 0) {
                $estadoMac = 'nao_configurado'; $nivel = 'media'
            } elseif (-not $mac) {
                $estadoMac = 'indisponivel';    $nivel = 'media'
            } elseif ($macsOk -contains $mac) {
                $estadoMac = 'sim';             $nivel = 'alta'
            } else {
                $avisos += "Gateway e sub-rede de $($u.nome), mas o MAC do gateway e diferente do esperado."
                continue
            }
            $resultado = 'Presencial'; $unidade = $u.nome; $confianca = $nivel; $macConfere = $estadoMac
            $motivo = "Rede fisica de $($u.nome) (gateway $($cand.Gateway))"
            if ($VpnAtiva) { $resultado = 'Presencial via VPN'; $motivo += ' com VPN ativa' }
            $gwInfo = $cand.Gateway; $macInfo = $mac; $ipInfo = $cand.IpLocal; $adInfo = $cand.Adaptador
            break
        }
        if ($resultado) { break }
        if (-not $gwInfo) { $gwInfo = $cand.Gateway; $macInfo = $mac; $ipInfo = $cand.IpLocal; $adInfo = $cand.Adaptador }
    }

    if (-not $resultado) {
        if (@($Candidatos).Count -eq 0) {
            $resultado = 'Sem rede'; $confianca = 'baixa'; $motivo = 'Nenhum adaptador fisico com gateway'
        } elseif ($VpnAtiva) {
            $resultado = 'Remoto via VPN'; $confianca = 'alta'; $motivo = 'Rede fisica nao e de escritorio e a VPN esta ativa'
        } else {
            $resultado = 'Remoto'; $confianca = 'alta'; $motivo = 'Rede fisica nao e de escritorio'
        }
        if ($avisos.Count -gt 0) { $motivo += ' | ' + ($avisos -join ' '); $confianca = 'media' }
    }

    return [pscustomobject]@{
        Resultado  = $resultado
        Unidade    = $unidade
        Confianca  = $confianca
        MacConfere = $macConfere
        Motivo     = $motivo
        Gateway    = $gwInfo
        GatewayMac = $macInfo
        IpLocal    = $ipInfo
        Adaptador  = $adInfo
    }
}

# Informacoes extras (nao alteram o resultado): sessao remota, tela bloqueada, ociosidade.
function Get-EstadoSessao {
    $remota = ($env:SESSIONNAME -like 'RDP-*')
    $minhaSessao = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $bloqueada = [bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $minhaSessao })
    $ocioso = $null
    try {
        if (-not ('PresencaPP.Ociosidade' -as [type])) {
            Add-Type -Namespace PresencaPP -Name Ociosidade -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
public static long Segundos() {
    LASTINPUTINFO i = new LASTINPUTINFO(); i.cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf(i);
    if (!GetLastInputInfo(ref i)) return -1;
    return ((long)(uint)Environment.TickCount - (long)i.dwTime) / 1000;
}
'@
        }
        $s = [PresencaPP.Ociosidade]::Segundos()
        if ($s -ge 0) { $ocioso = [int]$s }
    } catch { }
    return [pscustomobject]@{ SessaoRemota = $remota; Bloqueada = $bloqueada; OciosoSeg = $ocioso }
}

# ---------- nome completo do usuario ----------

# "DOMINIO\joao.silva" -> "joao.silva"
function ConvertTo-LoginSimples([string]$Usuario) {
    if (-not $Usuario) { return '' }
    $l = $Usuario.Split('\')[-1]
    if ($l.Contains('@')) { $l = $l.Split('@')[0] }
    return $l.Trim()
}

# Extrai o nome da saida de "net user <login>" (Windows em ingles: "Full Name"; em portugues: "Nome completo")
function ConvertFrom-NetUserNome($Linhas) {
    foreach ($l in @($Linhas)) {
        if ($l -match '^\s*(Full Name|Nome completo)\s{2,}(.+?)\s*$') { return $matches[2].Trim() }
    }
    return ''
}

# Busca o nome completo (displayName do Active Directory; se nao houver, conta local). Guarda em cache por 24 h
# (1 h se a busca falhou) para nao consultar o controlador de dominio a cada execucao. Nunca gera erro.
function Get-NomeCompleto {
    param([string]$Usuario, [string]$ArquivoCache, [datetime]$Agora = (Get-Date))
    $login = ConvertTo-LoginSimples $Usuario
    if ($login -notmatch '^[A-Za-z0-9._\- ]{1,64}$') { return '' }
    $epoch = [DateTimeOffset]::new($Agora).ToUnixTimeSeconds()
    if ($ArquivoCache -and (Test-Path $ArquivoCache)) {
        try {
            $c = Get-Content -Path $ArquivoCache -Raw -Encoding UTF8 | ConvertFrom-Json
            $validade = if ($c.nome) { 86400 } else { 3600 }
            if ($c.login -eq $login -and ($epoch - [long]$c.epoch) -lt $validade -and ($epoch - [long]$c.epoch) -ge 0) { return [string]$c.nome }
        } catch { }
    }
    $nome = ''
    try {
        $b = [adsisearcher]"(&(objectCategory=person)(objectClass=user)(sAMAccountName=$login))"
        $b.ClientTimeout = [TimeSpan]::FromSeconds(5)
        $b.ServerTimeLimit = [TimeSpan]::FromSeconds(5)
        $null = $b.PropertiesToLoad.Add('displayname')
        $r = $b.FindOne()
        if ($r -and $r.Properties['displayname'].Count -gt 0) { $nome = [string]$r.Properties['displayname'][0] }
    } catch { }
    if (-not $nome) {
        try { $nome = ConvertFrom-NetUserNome (& "$env:SystemRoot\System32\net.exe" user $login 2>$null) } catch { }
    }
    $nome = $nome.Trim()
    if ($ArquivoCache) {
        try {
            $pasta = Split-Path -Parent $ArquivoCache
            if (-not (Test-Path $pasta)) { $null = New-Item -ItemType Directory -Path $pasta -Force }
            @{ login = $login; nome = $nome; epoch = $epoch } | ConvertTo-Json | Set-Content -Path $ArquivoCache -Encoding UTF8
        } catch { }
    }
    return $nome
}

# ---------- rede do agente (proxy e TLS) ----------

# Ultimo erro de rede (para o agent mostrar o MOTIVO quando nao consegue enviar)
$script:UltimoErroRede = ''
function Get-UltimoErroRede { return $script:UltimoErroRede }
function Set-UltimoErroRede($Erro) {
    $m = ''
    try { $m = $Erro.Exception.Message; if ($Erro.Exception.InnerException) { $m += ' | ' + $Erro.Exception.InnerException.Message } } catch { }
    $script:UltimoErroRede = $m
}

# Usa o proxy do Windows com as credenciais do usuario logado (proxy corporativo que exige autenticacao devolve 407
# para o PowerShell por padrao) e garante TLS 1.2. Nunca gera erro.
function Initialize-RedeAgente {
    try {
        $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
        [System.Net.WebRequest]::DefaultWebProxy = $proxy
    } catch { }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
}

# ---------- envio ao servidor (com fila offline) ----------

function Send-Registro {
    param(
        [Parameter(Mandatory)] $Registro,
        [Parameter(Mandatory)] [string]$Servidor,
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$PastaFila
    )
    $headers = @{ Authorization = "Bearer $Token" }
    $uri = ($Servidor.TrimEnd('/')) + '/api/registros'
    if (-not (Test-Path $PastaFila)) { $null = New-Item -ItemType Directory -Path $PastaFila -Force }

    # Tenta enviar os pendentes (mais antigos primeiro) e depois o atual; se algum falhar, o atual vai para a fila.
    $pendentes = @(Get-ChildItem -Path $PastaFila -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
    $falhou = $false
    foreach ($f in $pendentes) {
        try {
            $corpo = Get-Content -Path $f.FullName -Raw -Encoding UTF8
            Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($corpo)) -TimeoutSec 10 | Out-Null
            Remove-Item $f.FullName -Force
        } catch { Set-UltimoErroRede $_; $falhou = $true; break }
    }
    $json = $Registro | ConvertTo-Json -Compress
    if (-not $falhou) {
        try {
            Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 10 | Out-Null
            return 'enviado'
        } catch { Set-UltimoErroRede $_; $falhou = $true }
    }
    # Limita a fila a 500 arquivos para nao crescer sem fim.
    if ((Get-ChildItem -Path $PastaFila -Filter '*.json').Count -lt 500) {
        $nome = (Get-Date).ToString('yyyyMMddHHmmssfff') + '.json'
        Set-Content -Path (Join-Path $PastaFila $nome) -Value $json -Encoding UTF8
    }
    return 'na_fila'
}

function Update-ConfigUnidades {
    param([string]$Servidor, [string]$Token, [string]$Destino)
    try {
        $uri = ($Servidor.TrimEnd('/')) + '/api/config/unidades'
        $conteudo = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 10
        # So aceita se tiver o formato esperado
        if ($conteudo.unidades) {
            $conteudo | ConvertTo-Json -Depth 10 | Set-Content -Path $Destino -Encoding UTF8
            return $true
        }
    } catch { }
    return $false
}

# ---------- anti-rajada ----------

# Verdadeiro se este mesmo estado (assinatura) ja foi registrado ha menos de $JanelaSeg segundos.
# Estado diferente NUNCA e redundante: uma mudanca real de rede/VPN sempre e registrada.
function Test-RegistroRedundante {
    param([string]$Assinatura, [string]$ArquivoEstado, [datetime]$Agora, [int]$JanelaSeg = 30)
    if (-not (Test-Path $ArquivoEstado)) { return $false }
    try { $e = Get-Content -Path $ArquivoEstado -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $false }
    if (-not $e -or $e.assinatura -ne $Assinatura -or $null -eq $e.epoch) { return $false }
    $agoraEpoch = [DateTimeOffset]::new($Agora).ToUnixTimeSeconds()
    $dif = $agoraEpoch - [long]$e.epoch
    return ($dif -ge 0 -and $dif -lt $JanelaSeg)
}

function Save-EstadoEnvio {
    param([string]$Assinatura, [string]$ArquivoEstado, [datetime]$Agora)
    @{ assinatura = $Assinatura; epoch = [DateTimeOffset]::new($Agora).ToUnixTimeSeconds() } |
        ConvertTo-Json | Set-Content -Path $ArquivoEstado -Encoding UTF8
}

# ---------- tarefa agendada (XML) ----------

# Monta o XML da tarefa: logon + a cada N min + troca de rede (eventos do Windows) + desbloqueio da sessao.
# Eventos do log NetworkProfile: 10000/10001 = rede conectou/desconectou; 4004 = mudanca de estado da rede
# (e o unico que o Windows gera ao ligar/desligar a VPN quando o PC ja esta numa rede, ex.: cabo no escritorio).
# $PrincipalXml: trecho <Principal>...</Principal> (o instalador usa o grupo "Usuarios" pelo SID).
function New-XmlTarefaPresenca {
    param(
        [Parameter(Mandatory)] [string]$Comando,
        [Parameter(Mandatory)] [string]$Argumentos,
        [Parameter(Mandatory)] [string]$PrincipalXml,
        [int]$IntervaloMin = 5,
        [int]$AtrasoRedeSeg = 20
    )
    $esc = { param($s) [Security.SecurityElement]::Escape($s) }
    $consulta = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000 or EventID=10001 or EventID=4004)]]</Select></Query></QueryList>'
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Agente de presenca: detecta onde o PC esta (escritorio ou fora).</Description></RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>
    <TimeTrigger>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition><Interval>PT${IntervaloMin}M</Interval></Repetition>
    </TimeTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$(& $esc $consulta)</Subscription>
      <Delay>PT${AtrasoRedeSeg}S</Delay>
    </EventTrigger>
    <SessionStateChangeTrigger>
      <Enabled>true</Enabled>
      <StateChange>SessionUnlock</StateChange>
      <Delay>PT10S</Delay>
    </SessionStateChangeTrigger>
  </Triggers>
  <Principals>
    $PrincipalXml
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $esc $Comando)</Command>
      <Arguments>$(& $esc $Argumentos)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

# ---------- programas em foco: quanto tempo cada programa ficou na frente ----------
# Um coletor leve (PresencaAgenteFoco, no contexto do usuario) olha a janela em primeiro plano a cada 5 s e grava
# "segmentos" (programa, titulo da janela, inicio, duracao) numa fila local. O agent de 5 em 5 min envia a fila.
# Nao conta o tempo com a tela bloqueada ou sem teclado/mouse ha 5 min. Nao captura o conteudo das janelas.
# Navegadores: so o programa (os sites ja vem do historico), o que evita um segmento a cada troca de aba.

$script:NavegadoresFoco = @('chrome', 'msedge', 'firefox', 'brave', 'opera', 'opera_gx', 'vivaldi', 'iexplore', 'waterfox', 'arc')
$script:ProcessosInativos = @('LockApp', 'LogonUI', 'ScreenSaver', 'scrnsave')

function Test-NavegadorFoco([string]$Processo) { return ($script:NavegadoresFoco -contains $Processo.ToLower()) }

function ConvertTo-TituloFoco([string]$Titulo, [int]$Max = 150) {
    if (-not $Titulo) { return '' }
    $t = ($Titulo -replace '[\x00-\x1F]', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    return $t
}

# Fecha o segmento aberto e devolve o objeto a enviar (ou $null se durou menos de 1 s).
function Close-SegmentoFoco($Seg, [long]$Fim) {
    $dur = $Fim - $Seg.Inicio
    if ($dur -lt 1) { return $null }
    return [pscustomobject]@{ ts = ([long]$Seg.Inicio * 1000); seg = [int]$dur; proc = $Seg.Processo; titulo = $Seg.Titulo }
}

# Maquina de estados (pura, testavel). $Estado.Atual guarda o segmento aberto.
# $Amostra: $null (sem janela) ou objeto com Processo, Titulo e OciosoSeg. $Agora: epoch em segundos.
# Devolve a lista de segmentos FECHADOS neste passo.
function Update-EstadoFoco {
    param(
        [Parameter(Mandatory)] [hashtable]$Estado,
        $Amostra, [Parameter(Mandatory)] [long]$Agora,
        [int]$OciosoMaxSeg = 300, [int]$BlocoMaxSeg = 300, [bool]$Titulos = $true
    )
    $fechados = New-Object System.Collections.ArrayList
    $atual = $Estado.Atual
    $inativo = ($null -eq $Amostra) -or ($script:ProcessosInativos -contains $Amostra.Processo) -or ($Amostra.OciosoSeg -ge $OciosoMaxSeg)
    if ($inativo) {
        if ($atual) { $c = Close-SegmentoFoco $atual $atual.Fim; if ($c) { [void]$fechados.Add($c) }; $Estado.Atual = $null }
        return $fechados.ToArray()
    }
    $titulo = if ($Titulos -and -not (Test-NavegadorFoco $Amostra.Processo)) { ConvertTo-TituloFoco $Amostra.Titulo } else { '' }
    $chave = "$($Amostra.Processo)|$titulo"
    if ($atual -and $atual.Chave -eq $chave -and ($Agora - $atual.Inicio) -lt $BlocoMaxSeg) {
        $atual.Fim = $Agora
        return $fechados.ToArray()
    }
    if ($atual) { $c = Close-SegmentoFoco $atual $Agora; if ($c) { [void]$fechados.Add($c) } }
    $Estado.Atual = @{ Inicio = $Agora; Fim = $Agora; Processo = [string]$Amostra.Processo; Titulo = $titulo; Chave = $chave }
    return $fechados.ToArray()
}

function Initialize-FocoNativo {
    if ('PresencaPP.JanelaFoco' -as [type]) { return }
    Add-Type -Namespace PresencaPP -Name JanelaFoco -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder sb, int max);
[DllImport("kernel32.dll")] public static extern bool SetProcessWorkingSetSize(IntPtr proc, IntPtr min, IntPtr max);
// devolve a memoria ociosa ao Windows (o coletor fica horas parado esperando; sem isso o PowerShell mantem ~100 MB)
public static void Enxugar() { SetProcessWorkingSetSize(System.Diagnostics.Process.GetCurrentProcess().Handle, (IntPtr)(-1), (IntPtr)(-1)); }
'@
}

# Programa e titulo da janela em primeiro plano (ou $null).
function Get-JanelaEmFoco {
    Initialize-FocoNativo
    $h = [PresencaPP.JanelaFoco]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return $null }
    [uint32]$procId = 0
    [void][PresencaPP.JanelaFoco]::GetWindowThreadProcessId($h, [ref]$procId)
    $sb = New-Object System.Text.StringBuilder 512
    [void][PresencaPP.JanelaFoco]::GetWindowText($h, $sb, 512)
    $nome = ''
    try { $nome = [System.Diagnostics.Process]::GetProcessById([int]$procId).ProcessName } catch { }
    if (-not $nome) { return $null }
    return [pscustomobject]@{ Processo = $nome; Titulo = $sb.ToString() }
}

function Get-OciosoSegundos {
    try {
        if (-not ('PresencaPP.Ociosidade' -as [type])) { $null = Get-EstadoSessao }
        $s = [PresencaPP.Ociosidade]::Segundos()
        if ($s -ge 0) { return [int]$s }
    } catch { }
    return 0
}

function Add-SegmentosFoco([string]$Arquivo, $Segmentos) {
    $linhas = @($Segmentos | Where-Object { $_ } | ForEach-Object { $_ | ConvertTo-Json -Compress })
    if ($linhas.Count -eq 0) { return }
    $pasta = Split-Path -Parent $Arquivo
    if (-not (Test-Path $pasta)) { $null = New-Item -ItemType Directory -Path $pasta -Force }
    Add-Content -Path $Arquivo -Value $linhas -Encoding UTF8
}

# Loop do coletor. Uma instancia por sessao de usuario (mutex). $DuracaoMaxSeg > 0 so para testes.
function Start-ColetaFoco {
    param([Parameter(Mandatory)] [string]$PastaDados, [int]$IntervaloSeg = 5, [bool]$Titulos = $true, [int]$DuracaoMaxSeg = 0, [string]$NomeMutex = 'Local\PresencaPP-Foco')
    $mutex = New-Object System.Threading.Mutex($false, $NomeMutex)
    if (-not $mutex.WaitOne(0)) { return 'ja-em-execucao' }
    try {
        $fila = Join-Path $PastaDados 'foco-pendente.jsonl'
        $aberto = Join-Path $PastaDados 'foco-aberto.json'
        # recupera o segmento que estava aberto se o coletor/PC foi encerrado de repente (perde no maximo ~1 min)
        if (Test-Path $aberto) {
            try {
                $r = Get-Content $aberto -Raw -Encoding UTF8 | ConvertFrom-Json
                $c = Close-SegmentoFoco @{ Inicio = [long]$r.Inicio; Processo = $r.Processo; Titulo = $r.Titulo } ([long]$r.Fim)
                if ($c) { Add-SegmentosFoco $fila @($c) }
            } catch { }
            Remove-Item $aberto -Force -ErrorAction SilentlyContinue
        }
        $estado = @{ Atual = $null }
        $inicio = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $ultimoCheckpoint = $inicio
        while ($true) {
            $agora = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $am = $null
            try {
                $j = Get-JanelaEmFoco
                if ($j) { $am = [pscustomobject]@{ Processo = $j.Processo; Titulo = $j.Titulo; OciosoSeg = (Get-OciosoSegundos) } }
            } catch { }
            $fechados = Update-EstadoFoco -Estado $estado -Amostra $am -Agora $agora -Titulos $Titulos
            try { Add-SegmentosFoco $fila $fechados } catch { }
            if (($agora - $ultimoCheckpoint) -ge 60) {
                $ultimoCheckpoint = $agora
                try { [System.GC]::Collect(); [PresencaPP.JanelaFoco]::Enxugar() } catch { }
                try {
                    if ($estado.Atual) { $estado.Atual | ConvertTo-Json -Compress | Set-Content -Path $aberto -Encoding UTF8 }
                    elseif (Test-Path $aberto) { Remove-Item $aberto -Force -ErrorAction SilentlyContinue }
                } catch { }
            }
            if ($DuracaoMaxSeg -gt 0 -and ($agora - $inicio) -ge $DuracaoMaxSeg) {
                if ($estado.Atual) { try { Add-SegmentosFoco $fila @(Close-SegmentoFoco $estado.Atual $estado.Atual.Fim) } catch { } }
                return 'fim-do-teste'
            }
            Start-Sleep -Seconds $IntervaloSeg
        }
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

# Envia a fila de programas em foco. A fila "foco-pendente.jsonl" e girada para "foco-envio-*.jsonl" (o coletor segue
# gravando num arquivo novo); cada arquivo so e apagado depois que o servidor confirma. Sem rede, tudo fica na fila.
function Send-Foco {
    param(
        [Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token, [Parameter(Mandatory)] [string]$PastaDados,
        [string]$Maquina = $env:COMPUTERNAME, [string]$Usuario, [string]$NomeCompleto, [int]$LoteMax = 400
    )
    $pend = Join-Path $PastaDados 'foco-pendente.jsonl'
    if ((Test-Path $pend) -and (Get-Item $pend).Length -gt 0) {
        try { Move-Item -Path $pend -Destination (Join-Path $PastaDados ('foco-envio-{0:yyyyMMddHHmmssfff}.jsonl' -f (Get-Date))) -ErrorAction Stop } catch { }
    }
    $arquivos = @(Get-ChildItem -Path $PastaDados -Filter 'foco-envio-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name)
    # protege o disco: guarda no maximo os 500 arquivos mais recentes
    if ($arquivos.Count -gt 500) { $arquivos | Select-Object -First ($arquivos.Count - 500) | Remove-Item -Force -ErrorAction SilentlyContinue; $arquivos = @($arquivos | Select-Object -Last 500) }
    $enviados = 0; $falhou = $false
    foreach ($f in $arquivos) {
        $itens = @(Get-Content -Path $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ })
        $ok = $true
        for ($i = 0; $i -lt $itens.Count; $i += $LoteMax) {
            $lote = @($itens[$i..([Math]::Min($i + $LoteMax, $itens.Count) - 1)])
            $corpo = [pscustomobject]@{ host = $Maquina; usuario = $Usuario; nome_completo = $NomeCompleto; itens = @($lote | ForEach-Object { [pscustomobject]@{ ts = $_.ts; seg = $_.seg; proc = $_.proc; titulo = $_.titulo } }) } | ConvertTo-Json -Depth 4 -Compress
            try {
                Invoke-RestMethod -Uri (($Servidor.TrimEnd('/')) + '/api/foco') -Method Post -Headers @{ Authorization = "Bearer $Token" } `
                    -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($corpo)) -TimeoutSec 20 | Out-Null
                $enviados += $lote.Count
            } catch { if (Get-Command Set-UltimoErroRede -ErrorAction SilentlyContinue) { Set-UltimoErroRede $_ }; $ok = $false; break }
        }
        if ($ok) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue } else { $falhou = $true; break }
    }
    return [pscustomobject]@{ Enviados = $enviados; Falhou = $falhou }
}

# Tarefa agendada do coletor: roda no logon (e a cada 10 min como vigia; se ja estiver rodando, e ignorada).
function New-XmlTarefaFoco {
    param([Parameter(Mandatory)] [string]$Comando, [Parameter(Mandatory)] [string]$Argumentos, [Parameter(Mandatory)] [string]$PrincipalXml)
    $esc = { param($s) [Security.SecurityElement]::Escape($s) }
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Coletor de programas em uso (tempo na frente de cada programa) do agente de presenca.</Description></RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>
    <TimeTrigger>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition><Interval>PT10M</Interval></Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    $PrincipalXml
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $esc $Comando)</Command>
      <Arguments>$(& $esc $Argumentos)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

# ---------- inventario da maquina (modelo, serie, sistema, memoria, disco, rede) ----------
# Coleta so dados de hardware/sistema (nada de arquivos ou programas instalados). Enviado 1x por dia e quando a versao do agent muda.

# Tipo pela caixa (SMBIOS ChassisTypes): notebook, desktop, servidor ou outro.
function ConvertTo-TipoMaquina($ChassisTypes, $PcSystemType) {
    $notebook = 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32
    $desktop = 3, 4, 5, 6, 7, 13, 15, 16, 24, 34, 35, 36
    $servidor = 17, 23, 25, 28
    $tipos = @($ChassisTypes | ForEach-Object { [int]$_ })
    foreach ($c in $tipos) { if ($notebook -contains $c) { return 'NOTEBOOK' } }
    foreach ($c in $tipos) { if ($desktop -contains $c) { return 'DESKTOP' } }
    foreach ($c in $tipos) { if ($servidor -contains $c) { return 'SERVIDOR' } }
    if ($PcSystemType -eq 2) { return 'NOTEBOOK' }
    if ($PcSystemType -eq 1) { return 'DESKTOP' }
    return 'OUTRO'
}

# SSD / NVMe / HDD a partir do que o Windows informa (cai no nome do modelo se vier "Unspecified").
function ConvertTo-TipoDisco([string]$MediaType, [string]$BusType, [string]$Modelo) {
    if ($BusType -match 'NVMe') { return 'NVMe' }
    if ($MediaType -match '^(SSD|4)$') { return 'SSD' }
    if ($MediaType -match '^(HDD|3)$') { return 'HDD' }
    if ($Modelo -match 'nvme') { return 'NVMe' }
    if ($Modelo -match 'ssd|solid|\bm\.?2\b') { return 'SSD' }
    return 'Desconhecido'
}

function Get-InventarioMaquina {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $enc = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

    $discos = @()
    try {
        $discos = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.Size -gt 0 } | ForEach-Object {
            [pscustomobject]@{ modelo = ([string]$_.FriendlyName).Trim(); tipo = (ConvertTo-TipoDisco ([string]$_.MediaType) ([string]$_.BusType) ([string]$_.FriendlyName)); gb = [int][math]::Round($_.Size / 1GB) } })
    } catch { }
    if ($discos.Count -eq 0) {
        $discos = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object { $_.Size -gt 0 } | ForEach-Object {
            [pscustomobject]@{ modelo = ([string]$_.Model).Trim(); tipo = (ConvertTo-TipoDisco '' '' ([string]$_.Model)); gb = [int][math]::Round($_.Size / 1GB) } })
    }
    $c = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue

    # rede: adaptador com gateway (o que sai para a rede); IPv4 e MAC
    $ips = @(); $mac = ''
    try {
        $cfg = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4Address -and $_.NetAdapter.Status -eq 'Up' })
        # so os adaptadores que saem para a rede (com gateway); adaptadores virtuais (VirtualBox, WSL, Hyper-V) ficam de fora
        $prim = @($cfg | Where-Object { $_.IPv4DefaultGateway })
        if ($prim.Count -eq 0) { $prim = @($cfg | Where-Object { $_.NetAdapter.InterfaceDescription -notmatch 'Virtual|VMware|Hyper-V|VPN|Loopback|WSL' } | Select-Object -First 1) }
        foreach ($i in $prim) { foreach ($a in @($i.IPv4Address)) { if ($a.IPAddress -and $a.IPAddress -notmatch '^(127\.|169\.254\.)' -and ($ips -notcontains $a.IPAddress)) { $ips += $a.IPAddress } } }
        if ($prim.Count -gt 0) { $mac = ([string]$prim[0].NetAdapter.MacAddress) }
    } catch { }

    $versaoExib = ''
    try { $versaoExib = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).DisplayVersion } catch { }
    $ultimoBoot = ''; $instalado = ''
    if ($os -and $os.LastBootUpTime) { $ultimoBoot = $os.LastBootUpTime.ToString('yyyy-MM-ddTHH:mm:sszzz') }
    if ($os -and $os.InstallDate) { $instalado = $os.InstallDate.ToString('yyyy-MM-dd') }
    $ramGb = if ($cs -and $cs.TotalPhysicalMemory) { [int][math]::Round($cs.TotalPhysicalMemory / 1GB) } else { 0 }
    $total = 0; foreach ($d in $discos) { $total += $d.gb }

    return [pscustomobject]@{
        host            = $env:COMPUTERNAME
        fabricante      = if ($cs) { ([string]$cs.Manufacturer).Trim() } else { '' }
        modelo          = if ($cs) { ([string]$cs.Model).Trim() } else { '' }
        serie           = if ($bios) { ([string]$bios.SerialNumber).Trim() } else { '' }
        tipo            = (ConvertTo-TipoMaquina $(if ($enc) { $enc.ChassisTypes } else { @() }) $(if ($cs) { $cs.PCSystemType } else { 0 }))
        so              = if ($os) { ([string]$os.Caption).Trim() } else { '' }
        so_versao       = if ($os) { ([string]$os.Version) } else { '' }
        so_exibicao     = $versaoExib
        so_arquitetura  = if ($os) { ([string]$os.OSArchitecture) } else { '' }
        so_instalado_em = $instalado
        cpu             = if ($cpu) { ([string]$cpu.Name).Trim() } else { '' }
        ram_gb          = $ramGb
        discos          = $discos
        disco_total_gb  = [int]$total
        disco_c_total_gb = if ($c) { [int][math]::Round($c.Size / 1GB) } else { 0 }
        disco_c_livre_gb = if ($c) { [int][math]::Round($c.FreeSpace / 1GB) } else { 0 }
        ips             = $ips
        mac             = $mac
        dominio         = if ($cs -and $cs.PartOfDomain) { ([string]$cs.Domain) } else { '' }
        bios_versao     = if ($bios) { ([string]$bios.SMBIOSBIOSVersion).Trim() } else { '' }
        ultimo_boot     = $ultimoBoot
    }
}

# Envia o inventario. Devolve $true se o servidor confirmou.
function Send-Inventario {
    param([Parameter(Mandatory)] $Inventario, [Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token)
    $corpo = $Inventario | ConvertTo-Json -Depth 5 -Compress
    try {
        Invoke-RestMethod -Uri (($Servidor.TrimEnd('/')) + '/api/inventario') -Method Post -Headers @{ Authorization = "Bearer $Token" } `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($corpo)) -TimeoutSec 20 | Out-Null
        return $true
    } catch { if (Get-Command Set-UltimoErroRede -ErrorAction SilentlyContinue) { Set-UltimoErroRede $_ }; return $false }
}

# 1x por dia (e quando a versao do agent muda): coleta e envia. $ArquivoEstado guarda quando/qual versao foi enviada.
function Invoke-InventarioDiario {
    param([Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token, [Parameter(Mandatory)] [string]$ArquivoEstado, [string]$VersaoAgente = '', [int]$HorasEntreEnvios = 24, [switch]$Forcar)
    $deve = $Forcar.IsPresent
    if (-not $deve) {
        if (-not (Test-Path $ArquivoEstado)) { $deve = $true }
        else {
            try {
                $e = Get-Content $ArquivoEstado -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($e.versao -ne $VersaoAgente) { $deve = $true }
                elseif (((Get-Date) - [datetime]$e.quando).TotalHours -ge $HorasEntreEnvios) { $deve = $true }
            } catch { $deve = $true }
        }
    }
    if (-not $deve) { return 'nao-precisa' }
    $inv = Get-InventarioMaquina
    if (Send-Inventario -Inventario $inv -Servidor $Servidor -Token $Token) {
        @{ quando = (Get-Date).ToString('o'); versao = $VersaoAgente } | ConvertTo-Json | Set-Content -Path $ArquivoEstado -Encoding UTF8
        return 'enviado'
    }
    return 'falhou'
}

# ---------- acesso remoto (RustDesk) ----------
# Roda no atualizador (SYSTEM). So age quando o servidor libera esta maquina (Administracao > Acesso remoto) e o relay da
# empresa esta alcancavel; fora da rede (sem relay) nao mexe em nada e tenta de novo no proximo ciclo.
# A senha de acesso permanente e gerada AQUI (aleatoria, por maquina) e enviada ao servidor, que a guarda cifrada.
$script:RemotoServidor = 'remoto.example.com'
$script:RemotoChave    = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8='
$script:RemotoVersao   = '1.5.3'
$script:RemotoSha256   = '523ba0efbf62a21739961b62c7daaffb44d3da86139c546b364fd4e1333ed249'

function New-SenhaRemota([int]$Tamanho = 20) {
    $alfabeto = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $b = New-Object byte[] 1
    $r = New-Object System.Text.StringBuilder
    while ($r.Length -lt $Tamanho) { $rng.GetBytes($b); if ($b[0] -lt 248) { [void]$r.Append($alfabeto[$b[0] % 62]) } }  # 248 = 62*4: sem vies
    $rng.Dispose()
    return $r.ToString()
}

function Test-PortaTcp([string]$Alvo, [int]$Porta, [int]$TimeoutMs = 3000) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $a = $c.BeginConnect($Alvo, $Porta, $null, $null)
        $ok = $a.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($ok) { try { $c.EndConnect($a) } catch { $ok = $false } }
        $c.Close()
        return $ok
    } catch { return $false }
}

# ---------- batimento dos servidores (tarefa SYSTEM, sem usuario logado) ----------

# $true = esta maquina esta marcada como servidor no painel (deve ter a tarefa de batimento), $false = nao, $null = servidor inalcancavel (nao decide nada)
function Get-BatimentoPolitica {
    param([Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token)
    try {
        $uri = ($Servidor.TrimEnd('/')) + '/api/batimento/politica?host=' + [uri]::EscapeDataString($env:COMPUTERNAME)
        $r = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 15
        return [bool]$r.ativo
    } catch { return $null }
}

# Hora em que o Windows ligou (epoch em milissegundos), ou 0 se nao conseguir ler.
function Get-InicioSistemaMs {
    try {
        $b = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        return [long][Math]::Floor(([DateTimeOffset]$b).ToUnixTimeMilliseconds())
    } catch { return [long]0 }
}

function Send-Batimento {
    param([Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token)
    $corpo = @{ host = $env:COMPUTERNAME; boot = (Get-InicioSistemaMs) } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Uri (($Servidor.TrimEnd('/')) + '/api/batimento') -Method Post -Headers @{ Authorization = "Bearer $Token" } `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($corpo)) -TimeoutSec 15 | Out-Null
        return $true
    } catch { return $false }
}

# Troca o token de cadastro (o do instalador) por um token proprio desta maquina (ppm_...): o servidor so o aceita para este host,
# entao quem ler o agente.json de um PC nao consegue falar em nome de outro. Roda no atualizador (SYSTEM).
# Devolve: 'ok' (ja tinha), 'trocado', 'sem-token', 'falha-leitura', 'falha-http-<codigo>', 'falha-resposta', 'falha-gravacao'.
function Register-TokenAgente {
    param([Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$ArquivoAgente)
    try { $a = Get-Content -Path $ArquivoAgente -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { return 'falha-leitura' }
    if (-not $a -or -not $a.token) { return 'sem-token' }
    if ([string]$a.token -like 'ppm_*') { return 'ok' }
    $corpo = @{ host = $env:COMPUTERNAME } | ConvertTo-Json -Compress
    try {
        $r = Invoke-RestMethod -Uri (($Servidor.TrimEnd('/')) + '/api/agente/registrar') -Method Post -Headers @{ Authorization = "Bearer $($a.token)" } `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($corpo)) -TimeoutSec 20
    } catch {
        $cod = 0
        try { $cod = [int]$_.Exception.Response.StatusCode } catch { }
        return ('falha-http-' + $cod)
    }
    if (-not $r -or -not ([string]$r.token -like 'ppm_*')) { return 'falha-resposta' }
    try {
        $a | Add-Member -NotePropertyName token -NotePropertyValue ([string]$r.token) -Force
        $tmp = $ArquivoAgente + '.novo'
        ($a | ConvertTo-Json -Depth 5) | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $ArquivoAgente -Force
    } catch { return 'falha-gravacao' }
    return 'trocado'
}

function Get-RemotoPolitica {
    param([Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token)
    try {
        $uri = ($Servidor.TrimEnd('/')) + '/api/remoto/politica?host=' + [uri]::EscapeDataString($env:COMPUTERNAME)
        $r = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 15
        return [bool]$r.ativo
    } catch { return $null }   # $null = servidor inalcancavel (nao decide nada)
}

function Send-RemotoRegistro {
    param([Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token, [Parameter(Mandatory)] [string]$Id, [Parameter(Mandatory)] [string]$Senha)
    $corpo = @{ host = $env:COMPUTERNAME; id = $Id; senha = $Senha } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Uri (($Servidor.TrimEnd('/')) + '/api/remoto') -Method Post -Headers @{ Authorization = "Bearer $Token" } `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($corpo)) -TimeoutSec 20 | Out-Null
        return $true
    } catch { return $false }
}

function Install-RustDeskCliente {
    param([scriptblock]$AoInstalar)
    $v = $script:RemotoVersao
    $exe = Join-Path $env:TEMP "rustdesk-$v-x86_64.exe"
    Get-ArquivoComProgresso -Url "https://github.com/rustdesk/rustdesk/releases/download/$v/rustdesk-$v-x86_64.exe" -Destino $exe `
        -Progresso { param($mb) Write-TelaRemoto ("`r  Baixando: {0} MB de ~25 MB   " -f $mb) 'Gray' -SemQuebra }
    Write-TelaRemoto ''
    Write-TelaRemoto '  Conferindo a assinatura (hash) do instalador...'
    $hash = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $script:RemotoSha256) { Remove-Item $exe -Force -ErrorAction SilentlyContinue; throw "hash do instalador do RustDesk nao confere ($hash)" }
    if ($AoInstalar) { & $AoInstalar }
    try {
        # Start-Process -Wait espera tambem o que o instalador abre (ele abre o proprio RustDesk no fim e a espera nunca acabava):
        # aqui espera so o instalador e depois fecha o que ele deixou aberto.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe; $psi.Arguments = '--silent-install'; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit(240000)) { try { $p.Kill() } catch { }; throw 'o instalador do RustDesk nao terminou em 4 minutos' }
        foreach ($i in 1..3) { Start-Sleep -Seconds 3; Stop-RustDeskProcessos }
    } finally { Remove-Item $exe -Force -ErrorAction SilentlyContinue }
}

# Fecha todos os processos do RustDesk (janela, bandeja e servico). O servico e religado nas etapas seguintes.
function Stop-RustDeskProcessos {
    Get-Process -Name rustdesk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# Fecha so janelas do RustDesk (processos com tela), sem derrubar o servico.
function Stop-RustDeskJanelas {
    Get-Process -Name rustdesk -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Stop-Process -Force -ErrorAction SilentlyContinue
}

# Caminhos e chaves que o RustDesk deixa na maquina (pastas de programa, configuracao do servico, perfis, atalhos, registro).
function Get-RestosRustDesk {
    $achados = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in @(Get-Service -Name 'RustDesk*' -ErrorAction SilentlyContinue)) { $achados.Add("servico:$($s.Name)") }
    $pastas = @(
        (Join-Path $env:ProgramFiles 'RustDesk'), (Join-Path (Get-ProgramasRemoto) 'RustDesk'), (Join-Path ${env:ProgramFiles(x86)} 'RustDesk'), (Join-Path $env:ProgramData 'RustDesk'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\RustDesk'),
        'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk', 'C:\Windows\ServiceProfiles\NetworkService\AppData\Roaming\RustDesk',
        'C:\Windows\System32\config\systemprofile\AppData\Roaming\RustDesk'
    )
    foreach ($u in @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
        $pastas += (Join-Path $u.FullName 'AppData\Roaming\RustDesk')
        $pastas += (Join-Path $u.FullName 'AppData\Local\RustDesk')
    }
    foreach ($p in $pastas) { if ($p -and (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)) { $achados.Add("pasta:$p") } }
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk', 'HKLM:\SOFTWARE\Classes\rustdesk') {
        if (Test-Path -LiteralPath $k) { $achados.Add("registro:$k") }
    }
    return $achados.ToArray()
}

# Remove TUDO do RustDesk (servicos, processos, programa, configuracoes, atalhos, registro e regras de firewall) e o estado local do agente.
# So e chamada pelo fluxo do acesso remoto: com restos sem o programa instalado, ou quando o servico nao registra (reinstala do zero depois).
function Remove-RustDeskCompleto {
    param([string]$PastaDados, [switch]$Simular)
    if ($Simular) { return @(Get-RestosRustDesk) }   # so lista o que seria removido (usado nos testes, nada e apagado)
    Write-LogRemoto 'removendo o RustDesk por completo'
    foreach ($s in @(Get-Service -Name 'RustDesk*' -ErrorAction SilentlyContinue)) {
        try { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue } catch { }
    }
    Stop-RustDeskProcessos
    Start-Sleep -Seconds 2
    foreach ($s in @(Get-Service -Name 'RustDesk*' -ErrorAction SilentlyContinue)) {
        $o = (& sc.exe delete $s.Name 2>&1 | Out-String).Trim()
        Write-LogRemoto "  sc delete $($s.Name) => $o"
    }
    Stop-RustDeskProcessos
    Start-Sleep -Seconds 2
    foreach ($r in @(Get-RestosRustDesk | Where-Object { $_ -like 'pasta:*' })) {
        $p = $r.Substring(6)
        for ($i = 0; $i -lt 3; $i++) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $p)) { break }
            Start-Sleep -Seconds 2; Stop-RustDeskProcessos
        }
        if (Test-Path -LiteralPath $p) { Write-LogRemoto "  nao consegui apagar: $p" }
    }
    foreach ($r in @(Get-RestosRustDesk | Where-Object { $_ -like 'registro:*' })) { Remove-Item -LiteralPath $r.Substring(9) -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') {
        try { Remove-ItemProperty -Path $k -Name 'RustDesk' -ErrorAction SilentlyContinue } catch { }
    }
    try { Get-NetFirewallRule -DisplayName 'RustDesk*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue } catch { }
    if ($PastaDados) { Remove-Item -LiteralPath (Join-Path $PastaDados 'remoto.json') -Force -ErrorAction SilentlyContinue }
    $sobrou = @(Get-RestosRustDesk)
    Write-LogRemoto "limpeza concluida; restos: $($sobrou.Count)"
    return $sobrou.Count
}

# Janela de progresso: so aparece quando a instalacao e feita pelo EXE (Show-RemotoInstalacao liga $script:RemotoMostrar).
# Nas atualizacoes automaticas (SYSTEM, sem tela) nada e escrito. Texto em ASCII de proposito (o console do Windows e os .psm1 sem BOM).
$script:RemotoMostrar = $false
function Write-TelaRemoto([string]$Texto, [string]$Cor = 'Gray', [switch]$SemQuebra) {
    if (-not $script:RemotoMostrar) { return }
    try { if ($SemQuebra) { Write-Host $Texto -ForegroundColor $Cor -NoNewline } else { Write-Host $Texto -ForegroundColor $Cor } } catch { }
}

# Baixa um arquivo e chama $Progresso com os MB ja baixados (o Invoke-WebRequest com barra de progresso fica muito lento no PowerShell 5.1).
function Get-ArquivoComProgresso([string]$Url, [string]$Destino, [scriptblock]$Progresso) {
    $wc = New-Object System.Net.WebClient
    try {
        $tarefa = $wc.DownloadFileTaskAsync($Url, $Destino)
        $ultimo = -1
        while (-not $tarefa.IsCompleted) {
            Start-Sleep -Milliseconds 600
            if ($Progresso -and (Test-Path $Destino)) {
                $mb = [math]::Round((Get-Item $Destino).Length / 1MB, 1)
                if ($mb -ne $ultimo) { & $Progresso $mb; $ultimo = $mb }
            }
        }
        if ($tarefa.IsFaulted) { throw $tarefa.Exception.InnerException }
        if ($Progresso -and (Test-Path $Destino)) { & $Progresso ([math]::Round((Get-Item $Destino).Length / 1MB, 1)) }
    } finally { $wc.Dispose() }
}

# Log local do acesso remoto (C:\ProgramData\PresencaAgente\remoto.log): diz em que etapa parou, sem depender do painel.
function Write-LogRemoto([string]$Texto) {
    try {
        if (-not $script:RemotoPastaLog) { return }
        $arq = Join-Path $script:RemotoPastaLog 'remoto.log'
        if ((Test-Path $arq) -and (Get-Item $arq).Length -gt 200KB) { Move-Item $arq ($arq + '.antigo') -Force }
        Add-Content -Path $arq -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Texto) -Encoding UTF8
    } catch { }
}

# Espera o servico do Windows aparecer (devolve o servico ou $null).
function Wait-ServicoRustDesk([int]$Segundos = 30, [string]$Nome = 'RustDesk') {
    $fim = (Get-Date).AddSeconds($Segundos * $script:RemotoFatorEspera)
    do {
        $s = Get-Service -Name $Nome -ErrorAction SilentlyContinue
        if ($s) { return $s }
        Wait-Remoto 2
    } while ((Get-Date) -lt $fim)
    return $null
}

# Espera o servico do RustDesk responder (o --get-id so devolve o ID quando o servico esta de pe).
function Wait-RustDeskPronto([string]$Exe, [int]$SegundosMax = 60) {
    $fim = (Get-Date).AddSeconds($SegundosMax * $script:RemotoFatorEspera)
    do {
        try { if ((& $Exe --get-id 2>$null | Out-String).Trim() -match '^\d{6,12}$') { return $true } } catch { }
        if ((Get-Date) -lt $fim) { Wait-Remoto 2 }
    } while ((Get-Date) -lt $fim)
    return $false
}

# Informa ao servidor a etapa em que o agent esta (aparece no painel). Nunca derruba o fluxo: se falhar, so devolve $false.
function Send-RemotoStatus {
    param([Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token, [Parameter(Mandatory)] [string]$Estado, [string]$Detalhe = '')
    $corpo = @{ host = $env:COMPUTERNAME; estado = $Estado; detalhe = $Detalhe } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Uri (($Servidor.TrimEnd('/')) + '/api/remoto/status') -Method Post -Headers @{ Authorization = "Bearer $Token" } `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($corpo)) -TimeoutSec 10 | Out-Null
        return $true
    } catch { return $false }
}

function Get-EstadoRemoto([string]$Arquivo) {
    if (-not (Test-Path $Arquivo)) { return $null }
    try {
        $e = Get-Content $Arquivo -Raw -Encoding UTF8 | ConvertFrom-Json
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $senha = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$e.senha), $null, 'LocalMachine'))
        return [pscustomobject]@{ id = [string]$e.id; senha = $senha; enviado = [bool]$e.enviado }
    } catch { return $null }
}

function Save-EstadoRemoto([string]$Arquivo, [string]$Id, [string]$Senha, [bool]$Enviado) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $prot = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Senha), $null, 'LocalMachine'))
    @{ id = $Id; senha = $prot; enviado = $Enviado } | ConvertTo-Json | Set-Content -Path $Arquivo -Encoding UTF8
}

# Inicia o servico e espera ficar "Running". Se nao subir, registra o motivo no log (configuracao do servico e erros do Windows).
function Start-ServicoRustDeskSeguro {
    $s = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    if (-not $s) { return $false }
    if ($s.Status -ne 'Running') {
        try {
            Set-Service -Name 'RustDesk' -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name 'RustDesk' -ErrorAction Stop
        } catch {
            $script:RemotoUltimoErro = $_.Exception.Message
            Write-LogRemoto "  Start-Service falhou: $($_.Exception.Message)"
            try { Write-LogRemoto ('  sc qc: ' + ((& sc.exe qc RustDesk 2>&1 | Out-String) -replace '\s+', ' ').Trim()) } catch { }
            try {
                foreach ($ev in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Level = 2; StartTime = (Get-Date).AddMinutes(-3) } -MaxEvents 3 -ErrorAction SilentlyContinue)) {
                    Write-LogRemoto ('  evento do Windows: ' + (($ev.Message -replace '\s+', ' ').Trim()))
                }
            } catch { }
        }
    }
    for ($i = 0; $i -lt 10; $i++) {
        if ((Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue).Status -eq 'Running') { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

# Garante o servico do Windows do RustDesk (devolve o servico ou $null). Sem servico a maquina so controla os outros, nao pode ser acessada.
# Servico que existe mas NAO sobe tambem conta como defeito ($null): o fluxo entao limpa tudo e reinstala.
function Initialize-ServicoRustDesk {
    param([Parameter(Mandatory)] [string]$Exe, [scriptblock]$Informar)
    # 1) o instalador do RustDesk registra o servico alguns segundos DEPOIS de terminar: espera antes de mexer
    $svc = Wait-ServicoRustDesk -Segundos 45
    if (-not $svc) {
        # 2) pede ao proprio RustDesk para registrar o servico
        if ($Informar) { & $Informar 'configurando' 'registrando o servico do Windows' }
        Write-LogRemoto 'servico nao apareceu apos a instalacao; rodando --install-service'
        Stop-RustDeskProcessos
        $saida = (& $Exe --install-service 2>&1 | Out-String).Trim()
        if ($saida) { Write-LogRemoto "  --install-service => $saida" }
        $svc = Wait-ServicoRustDesk -Segundos 30
    }
    if (-not $svc) {
        # 3) plano B: cria o servico direto no Windows, do mesmo jeito que o RustDesk (nome RustDesk, inicio automatico)
        Write-LogRemoto 'servico ainda ausente; criando com New-Service'
        try {
            $null = New-Service -Name 'RustDesk' -BinaryPathName ('"' + $Exe + '" --service') -DisplayName 'RustDesk Service' -StartupType Automatic -ErrorAction Stop
            Start-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
        } catch { Write-LogRemoto "  New-Service falhou: $($_.Exception.Message)"; $script:RemotoUltimoErro = $_.Exception.Message }
        $svc = Wait-ServicoRustDesk -Segundos 15
    }
    if ($svc -and -not (Start-ServicoRustDeskSeguro)) {
        Write-LogRemoto 'o servico existe, mas nao inicia'
        if (-not $script:RemotoUltimoErro) { $script:RemotoUltimoErro = 'o servico RustDesk existe, mas nao inicia' }
        return $null
    }
    return $svc
}
# ---------- configuracao do relay: em camadas e COM PROVA ----------
# Fatos do codigo-fonte do RustDesk 1.5.3 que orientam isto:
#  - --option / --password / --config so funcionam com o RustDesk instalado e com privilegio de administrador/SYSTEM, falam por IPC
#    com o processo "--server" e, se o IPC falha, NAO avisam (--option ignora o erro em silencio).
#  - O "--server" roda como SYSTEM, e e quem registra a maquina no relay. Ele so e iniciado pelo servico quando existe sessao de
#    console (alguem na tela de login ou logado). Sem ele nao ha IPC: nao da para definir senha nem ler o ID.
#  - A configuracao do SYSTEM fica em C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml.
#    Cada processo guarda a configuracao em memoria e regrava o arquivo quando muda algo: editar o arquivo com o RustDesk rodando
#    nao vale (ele sobrescreve); com todos os processos parados, vale.
# Por isso: tenta o IPC; confere o RESULTADO NO ARQUIVO (prova que persistiu); se nao deu, para tudo, grava o arquivo e religa.
$script:RemotoFatorEspera = 1
$script:RemotoPrazo = $null
$script:RemotoCanal = ''
$script:RemotoDetalhe = ''

# Espera em segundos (os testes zeram o fator para nao demorar).
function Wait-Remoto([double]$Segundos) {
    $s = $Segundos * $script:RemotoFatorEspera
    if ($s -gt 0) { Start-Sleep -Milliseconds ([int]($s * 1000)) }
}

# O atualizador roda com limite de 10 min: o fluxo todo tem prazo proprio (8 min) e continua na proxima rodada.
function Test-PrazoRemoto { return [bool]($script:RemotoPrazo -and ((Get-Date) -gt $script:RemotoPrazo)) }

# Pasta de programas de 64 bits mesmo se o PowerShell for de 32 bits.
function Get-ProgramasRemoto { if ($env:ProgramW6432) { return $env:ProgramW6432 } else { return $env:ProgramFiles } }
function Get-ExeRustDesk { if ($script:RemotoExeTeste) { return $script:RemotoExeTeste } else { return (Join-Path (Get-ProgramasRemoto) 'RustDesk\RustDesk.exe') } }
function Get-TomlServico {
    if ($script:RemotoTomlTeste) { return $script:RemotoTomlTeste }
    return (Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml')
}
function Get-OpcoesRemoto {
    return [ordered]@{ 'custom-rendezvous-server' = $script:RemotoServidor; 'relay-server' = $script:RemotoServidor; 'key' = $script:RemotoChave; 'stop-service' = 'N' }
}

# Le o RustDesk2.toml: opcoes da secao [options] e o rendezvous_server do topo (o RustDesk grava o host do relay ali depois de medir a latencia).
function Read-TomlRemoto([string]$Arquivo) {
    $opc = @{}; $rv = ''
    if (-not (Test-Path -LiteralPath $Arquivo)) { return [pscustomobject]@{ Existe = $false; Opcoes = $opc; RendezvousServer = $rv } }
    $secao = ''
    foreach ($l in (Get-Content -LiteralPath $Arquivo -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $t = ([string]$l).Trim()
        if ($t -match '^\[(.+)\]$') { $secao = $Matches[1]; continue }
        if (($t -match "^([A-Za-z0-9_-]+)\s*=\s*'(.*)'\s*$") -or ($t -match '^([A-Za-z0-9_-]+)\s*=\s*"(.*)"\s*$')) {
            if ($secao -eq 'options') { $opc[$Matches[1]] = $Matches[2] }
            elseif ($secao -eq '' -and $Matches[1] -eq 'rendezvous_server') { $rv = $Matches[2] }
        }
    }
    return [pscustomobject]@{ Existe = $true; Opcoes = $opc; RendezvousServer = $rv }
}

# Quais opcoes esperadas NAO estao (com o valor certo) no arquivo.
function Get-FaltaNoToml([string]$Arquivo, $Opcoes) {
    $t = Read-TomlRemoto $Arquivo
    return @($Opcoes.Keys | Where-Object { $t.Opcoes[$_] -ne $Opcoes[$_] })
}

# Garante as chaves da secao [options] mantendo todo o resto do arquivo. Grava por arquivo temporario + troca.
function Set-OpcoesToml {
    param([Parameter(Mandatory)] [string]$Arquivo, [Parameter(Mandatory)] $Opcoes)
    $linhas = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $Arquivo) { foreach ($l in (Get-Content -LiteralPath $Arquivo -Encoding UTF8)) { $linhas.Add([string]$l) } }
    $ini = -1
    for ($i = 0; $i -lt $linhas.Count; $i++) { if ($linhas[$i].Trim() -eq '[options]') { $ini = $i; break } }
    if ($ini -lt 0) { if ($linhas.Count -gt 0 -and $linhas[$linhas.Count - 1].Trim() -ne '') { $linhas.Add('') }; $linhas.Add('[options]'); $ini = $linhas.Count - 1 }
    $fim = $linhas.Count
    for ($i = $ini + 1; $i -lt $linhas.Count; $i++) { if ($linhas[$i].Trim() -match '^\[.+\]$') { $fim = $i; break } }
    $pendentes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in $Opcoes.Keys) { $pendentes.Add([string]$k) }
    for ($i = $ini + 1; $i -lt $fim; $i++) {
        if ($linhas[$i] -match '^\s*([A-Za-z0-9_-]+)\s*=') {
            $k = $Matches[1]
            if ($Opcoes.Contains($k)) { $linhas[$i] = "$k = '$($Opcoes[$k])'"; [void]$pendentes.Remove($k) }
        }
    }
    $pos = $ini + 1
    foreach ($k in ($pendentes | Sort-Object)) { $linhas.Insert($pos, "$k = '$($Opcoes[$k])'"); $pos++ }
    $pasta = Split-Path -Parent $Arquivo
    if ($pasta -and -not (Test-Path -LiteralPath $pasta)) { $null = New-Item -ItemType Directory -Path $pasta -Force }
    $tmp = $Arquivo + '.novo'
    [System.IO.File]::WriteAllLines($tmp, $linhas.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Arquivo -Force
}

# Valor de uma opcao segundo o proprio RustDesk (via IPC); vazio se o IPC nao responde.
function Get-OpcaoRustDesk([string]$Exe, [string]$Chave) {
    try { return (& $Exe --option $Chave 2>$null | Out-String).Trim() } catch { return '' }
}

# Para o servico e TODOS os processos do RustDesk (o --server e outros podem sobreviver ao Stop-Service e regravariam o arquivo).
function Stop-RustDeskTudo {
    foreach ($s in @(Get-Service -Name 'RustDesk*' -ErrorAction SilentlyContinue)) { try { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue } catch { } }
    for ($i = 0; $i -lt 15; $i++) {
        Stop-RustDeskProcessos
        Wait-Remoto 1
        if (-not (Get-Process -Name rustdesk -ErrorAction SilentlyContinue)) { break }
    }
}

# Define a senha permanente e CONFIRMA: o --password imprime "Done!" so quando o IPC aceitou (sem isso a senha guardada no painel seria falsa).
function Set-SenhaRemota([string]$Exe, [string]$Senha) {
    for ($i = 1; $i -le 3; $i++) {
        $o = ''
        try { $o = (& $Exe --password $Senha 2>&1 | Out-String).Trim() } catch { }
        if ($o -match 'Done') { return $true }
        Write-LogRemoto "  --password tentativa $i sem confirmacao (saida: '$o')"
        Wait-Remoto 3
    }
    return $false
}

# Configura o relay da empresa e PROVA. Devolve $true so quando o arquivo de configuracao do servico mostra as 4 opcoes e, se o
# RustDesk responde, ele concorda. Define $script:RemotoCanal ('ja-estava', 'ipc' ou 'arquivo') e, se falhar, RemotoUltimoErro.
function Set-ConfigRelay {
    param([Parameter(Mandatory)] [string]$Exe, [scriptblock]$Informar)
    $opc = Get-OpcoesRemoto
    $toml = Get-TomlServico
    $script:RemotoCanal = ''
    $estaOk = {
        $f = @(Get-FaltaNoToml $toml $opc)
        if ($f.Count -gt 0) { return $false }
        if (Wait-RustDeskPronto $Exe 3) { foreach ($k in $opc.Keys) { if ((Get-OpcaoRustDesk $Exe $k) -ne $opc[$k]) { return $false } } }
        return $true
    }
    $resumo = {
        $t = Read-TomlRemoto $toml
        $arq = ($opc.Keys | ForEach-Object { "$_=" + [string]$t.Opcoes[$_] }) -join '; '
        "arquivo[$arq]"
    }
    $ipc = Wait-RustDeskPronto $Exe 25
    Write-LogRemoto ("config do relay: RustDesk " + $(if ($ipc) { 'responde (IPC ok)' } else { 'NAO responde (sem processo --server; ninguem na tela do Windows?)' }))
    if ($ipc -and (& $estaOk)) { $script:RemotoCanal = 'ja-estava'; Write-LogRemoto 'config do relay: ja estava correta e provada'; return $true }

    # 1) IPC (rapido, e o proprio RustDesk que grava). Depois religa tudo para o registro usar a configuracao nova.
    if ($ipc -and -not (Test-PrazoRemoto)) {
        if ($Informar) { & $Informar 'configurando' 'gravando a configuracao do relay (pelo RustDesk)' }
        foreach ($k in $opc.Keys) {
            if ((Get-OpcaoRustDesk $Exe $k) -ne $opc[$k]) {
                $saida = ''
                try { $saida = (& $Exe --option $k $opc[$k] 2>&1 | Out-String).Trim() } catch { }
                if ($saida) { Write-LogRemoto "  --option $k => $saida" }
                Wait-Remoto 1
            }
        }
        Wait-Remoto 3
        Stop-RustDeskTudo
        [void](Start-ServicoRustDeskSeguro)
        [void](Wait-RustDeskPronto $Exe 45)
        if (& $estaOk) { $script:RemotoCanal = 'ipc'; Write-LogRemoto 'config do relay: gravada pelo IPC e provada no arquivo'; return $true }
        Write-LogRemoto ('config do relay: IPC nao fixou a configuracao. ' + (& $resumo))
    }

    # 2) arquivo: com tudo parado (ou sem --server), grava o arquivo do servico e religa. Ate 2 voltas.
    for ($v = 1; $v -le 2 -and -not (Test-PrazoRemoto); $v++) {
        if ($Informar) { & $Informar 'configurando' "gravando a configuracao do relay (arquivo, volta $v)" }
        Stop-RustDeskTudo
        try {
            Set-OpcoesToml -Arquivo $toml -Opcoes $opc
        } catch { Write-LogRemoto "  gravar $toml falhou: $($_.Exception.Message)"; $script:RemotoUltimoErro = "nao consegui gravar $toml : $($_.Exception.Message)"; continue }
        if (@(Get-FaltaNoToml $toml $opc).Count -gt 0) { Write-LogRemoto '  o arquivo gravado nao confere na releitura'; continue }
        [void](Start-ServicoRustDeskSeguro)
        [void](Wait-RustDeskPronto $Exe 45)
        Wait-Remoto 20   # tempo para um processo velho (se existir) regravar por cima; so entao conferimos
        if (& $estaOk) { $script:RemotoCanal = 'arquivo'; Write-LogRemoto "config do relay: gravada no arquivo (volta $v) e provada depois de religar"; return $true }
        Write-LogRemoto ("config do relay: o arquivo foi sobrescrito ou o RustDesk discorda (volta $v). " + (& $resumo))
    }
    if (-not $script:RemotoUltimoErro) { $script:RemotoUltimoErro = 'a configuracao do relay nao fixou: ' + (& $resumo) }
    return $false
}

# Devolve um texto de status: desligado | sem-servidor | sem-relay | falha-instalacao | falha-servico | falha-config | sem-id | falha-senha | aguardando-sessao | prazo-esgotado | falha-envio | registrado | ok
# $Informar (opcional) recebe (etapa, detalhe) nas etapas demoradas (baixando, instalando, configurando).
function Invoke-RemotoEtapas {
    param([Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token, [Parameter(Mandatory)] [string]$PastaDados, [scriptblock]$Informar)
    $script:RemotoPastaLog = $PastaDados
    $script:RemotoPrazo = (Get-Date).AddMinutes(8)
    $script:RemotoDetalhe = ''
    $info = { param($e, $d) Write-LogRemoto "etapa: $e $d"; if ($Informar) { & $Informar $e $d } }
    $quemSou = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { '?' }
    $logados = @(Get-Process -Name explorer -ErrorAction SilentlyContinue).Count
    Write-LogRemoto "---- inicio: usuario=$quemSou powershell=$($PSVersionTable.PSVersion) 64bits=$([Environment]::Is64BitProcess) sessoes-com-explorer=$logados exe=$(Get-ExeRustDesk)"
    Write-TelaRemoto '  [1/5] Verificando se esta maquina esta liberada para acesso remoto...' 'White'
    $pol = Get-RemotoPolitica -Servidor $Servidor -Token $Token
    if ($null -eq $pol) { return 'sem-servidor' }
    if (-not $pol) { return 'desligado' }
    Write-TelaRemoto '        Liberada.' 'Green'
    Write-TelaRemoto "  [2/5] Verificando o acesso ao relay da empresa ($($script:RemotoServidor))..." 'White'
    foreach ($p in 21116, 21117) { if (-not (Test-PortaTcp $script:RemotoServidor $p)) { return 'sem-relay' } }
    Write-TelaRemoto '        Relay acessivel.' 'Green'

    $rd = Get-ExeRustDesk
    $svc = $null
    # Ate 2 voltas: se o servico nao registra (resquicio de instalacao antiga, por exemplo), remove TUDO e reinstala do zero.
    for ($volta = 1; $volta -le 2; $volta++) {
        if (-not (Test-Path $rd)) {
            $restos = @(Get-RestosRustDesk)
            if ($restos.Count -gt 0) {
                Write-TelaRemoto '  Encontrei restos de uma instalacao antiga do RustDesk: removendo antes de instalar...' 'Yellow'
                Write-LogRemoto "restos encontrados sem o programa instalado ($($restos.Count)): $($restos -join ' | ')"
                [void](Remove-RustDeskCompleto -PastaDados $PastaDados)
            }
            Write-TelaRemoto "  [3/5] Baixando e instalando o RustDesk $($script:RemotoVersao) (pode levar 1 a 2 minutos)..." 'White'
            & $info 'baixando' "RustDesk $($script:RemotoVersao)"
            try { Install-RustDeskCliente -AoInstalar { Write-TelaRemoto '  Instalando o RustDesk...' 'White'; & $info 'instalando' '' } } catch { $script:RemotoUltimoErro = $_.Exception.Message; return 'falha-instalacao' }
            if (-not (Test-Path $rd)) { $script:RemotoUltimoErro = 'o instalador terminou mas o RustDesk nao apareceu'; return 'falha-instalacao' }
            Write-TelaRemoto '        RustDesk instalado.' 'Green'
        } else {
            Write-TelaRemoto '  [3/5] RustDesk ja esta instalado neste PC.' 'White'
        }
        Write-TelaRemoto '  [4/5] Configurando o servico e o relay da empresa...' 'White'
        $svc = Initialize-ServicoRustDesk -Exe $rd -Informar $info
        if ($svc) { break }
        if ($volta -eq 1) {
            Write-TelaRemoto '        Nao consegui registrar o servico. Removendo TUDO do RustDesk e reinstalando do zero...' 'Yellow'
            Write-LogRemoto 'servico nao registrou; limpeza completa e nova instalacao'
            $script:RemotoUltimoErro = ''
            $sobrou = Remove-RustDeskCompleto -PastaDados $PastaDados
            if ($sobrou -gt 0) { Write-TelaRemoto "        (ficaram $sobrou item(ns) que nao consegui apagar; o log lista quais)" 'Yellow' }
        }
    }
    if (-not $svc) {
        if (-not $script:RemotoUltimoErro) { $script:RemotoUltimoErro = 'o servico RustDesk nao foi criado, nem apos limpar e reinstalar (veja remoto.log)' }
        Write-LogRemoto "falha-servico: $($script:RemotoUltimoErro)"
        return 'falha-servico'
    }
    Write-TelaRemoto '        Servico do RustDesk registrado.' 'Green'
    Set-Service -Name 'RustDesk' -StartupType Automatic
    Stop-RustDeskJanelas

    # configuracao do relay: em camadas e COM PROVA no arquivo (ver Set-ConfigRelay)
    if (Test-PrazoRemoto) { $script:RemotoUltimoErro = 'o prazo de 8 minutos acabou antes de configurar o relay'; return 'prazo-esgotado' }
    & $info 'configurando' 'configurando o relay da empresa'
    [void](Start-ServicoRustDeskSeguro)
    if (-not (Set-ConfigRelay -Exe $rd -Informar $info)) { Write-LogRemoto "falha-config: $($script:RemotoUltimoErro)"; return 'falha-config' }
    Write-LogRemoto "relay configurado e provado (canal: $($script:RemotoCanal))"
    Write-TelaRemoto '        Relay da empresa configurado e conferido.' 'Green'
    Write-TelaRemoto '  [5/5] Registrando esta maquina no servidor (ID e senha propria)...' 'White'

    # Sem processo --server (ninguem na tela do Windows) nao ha IPC: senha e ID ficam para a proxima rodada
    if (Test-PrazoRemoto) { $script:RemotoUltimoErro = 'o prazo de 8 minutos acabou antes de registrar'; return 'prazo-esgotado' }
    if (-not (Wait-RustDeskPronto $rd 45)) { Write-LogRemoto 'RustDesk sem resposta: falta alguem na tela do Windows para concluir o registro'; return 'aguardando-sessao' }

    # senha propria desta maquina (gerada uma vez e guardada protegida com DPAPI); reaplicada a cada rodada e CONFIRMADA pelo RustDesk
    $arqEstado = Join-Path $PastaDados 'remoto.json'
    $estado = Get-EstadoRemoto $arqEstado
    $nova = (-not $estado) -or (-not $estado.senha)
    $senha = if ($nova) { New-SenhaRemota 20 } else { $estado.senha }
    if (-not (Set-SenhaRemota -Exe $rd -Senha $senha)) { $script:RemotoUltimoErro = 'o RustDesk nao confirmou a senha (--password sem "Done")'; Write-LogRemoto "falha-senha: $($script:RemotoUltimoErro)"; return 'falha-senha' }
    if ($nova) { Save-EstadoRemoto $arqEstado '' $senha $false }

    $id = $null
    for ($i = 0; $i -lt 10 -and -not $id; $i++) {
        $o = (& $rd --get-id 2>$null | Out-String).Trim()
        if ($o -match '^\d{6,12}$') { $id = $o } else { Wait-Remoto 2 }
    }
    if (-not $id) { return 'sem-id' }

    # prova extra (nao reprova): o RustDesk grava o host do relay no topo do RustDesk2.toml depois de falar com ele
    $vistoNoRelay = $false
    for ($i = 0; $i -lt 8 -and -not $vistoNoRelay; $i++) {
        if ((Read-TomlRemoto (Get-TomlServico)).RendezvousServer -like "*$($script:RemotoServidor)*") { $vistoNoRelay = $true } else { Wait-Remoto 5 }
    }
    $script:RemotoDetalhe = "config:$($script:RemotoCanal); relay:" + $(if ($vistoNoRelay) { 'conversando' } else { 'aguardando' })

    if ($nova -or -not $estado -or $estado.id -ne $id -or -not $estado.enviado) {
        Save-EstadoRemoto $arqEstado $id $senha $false
        if (Send-RemotoRegistro -Servidor $Servidor -Token $Token -Id $id -Senha $senha) { Save-EstadoRemoto $arqEstado $id $senha $true; return 'registrado' }
        return 'falha-envio'
    }
    return 'ok'
}


# Executa as etapas e informa ao servidor o andamento e o resultado final (o painel mostra na gaveta da maquina).
# Uma execucao por vez: o instalador (EXE) e a tarefa do atualizador podem coincidir; a segunda recebe 'em-andamento'.
function Invoke-RemotoGarantir {
    param([Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token, [Parameter(Mandatory)] [string]$PastaDados)
    $script:RemotoUltimoErro = ''
    $mx = $null; $tem = $false
    try { $mx = New-Object System.Threading.Mutex($false, 'Global\PresencaAgenteRemoto') } catch { $mx = New-Object System.Threading.Mutex($false, 'Local\PresencaAgenteRemoto') }
    try {
        try { $tem = $mx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $tem = $true }
        if (-not $tem) { return 'em-andamento' }
        $informar = { param($e, $d) $null = Send-RemotoStatus -Servidor $Servidor -Token $Token -Estado $e -Detalhe $d }
        $r = Invoke-RemotoEtapas -Servidor $Servidor -Token $Token -PastaDados $PastaDados -Informar $informar
        $null = Complete-RemotoResultado -Servidor $Servidor -Token $Token -Resultado $r
        return $r
    } finally { if ($tem) { try { $mx.ReleaseMutex() } catch { } }; $mx.Dispose() }
}

function Complete-RemotoResultado {
    param([Parameter(Mandatory)] [string]$Servidor, [Parameter(Mandatory)] [string]$Token, [Parameter(Mandatory)] [string]$Resultado)
    $r = $Resultado
    if ($r -ne 'desligado' -and $r -ne 'sem-servidor') {
        $detalhe = if ([string]$script:RemotoUltimoErro) { [string]$script:RemotoUltimoErro } else { [string]$script:RemotoDetalhe }
        Write-LogRemoto "resultado: $r $detalhe"
        $enviou = Send-RemotoStatus -Servidor $Servidor -Token $Token -Estado $r -Detalhe $detalhe
        if (-not $enviou) { Write-LogRemoto 'aviso: nao consegui informar o andamento ao servidor (o servidor ja foi atualizado com a versao 1.4.2?)' }
    }
    return $r
}

# Janela de progresso da instalacao pelo EXE: roda o fluxo do acesso remoto mostrando cada etapa e o resultado.
# Chamada pelo instalador (Instalador.iss) so em instalacao com tela; nao e usada nas atualizacoes automaticas.
function Show-RemotoInstalacao {
    param([Parameter(Mandatory)] [string]$PastaAgente, [switch]$SemEspera)
    $script:RemotoMostrar = $true
    try { $Host.UI.RawUI.WindowTitle = 'Acesso remoto - Agente' } catch { }
    Write-Host ''
    Write-Host '  ACESSO REMOTO (RustDesk)' -ForegroundColor Cyan
    Write-Host '  ------------------------'
    $a = $null
    try { $a = Get-Content (Join-Path $PastaAgente 'agente.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (-not ($a -and $a.servidor -and $a.token)) {
        Write-Host '  Este agente nao tem servidor/token configurado; nada a fazer.' -ForegroundColor Yellow
        if (-not $SemEspera) { Start-Sleep -Seconds 6 }; return
    }
    if ($a.acesso_remoto -eq $false) {
        Write-Host '  O acesso remoto esta desativado neste PC (agente.json: acesso_remoto = false).' -ForegroundColor Yellow
        if (-not $SemEspera) { Start-Sleep -Seconds 6 }; return
    }
    try { Initialize-RedeAgente } catch { }
    $dados = Join-Path $env:ProgramData 'PresencaAgente'
    if (-not (Test-Path $dados)) { $null = New-Item -ItemType Directory -Path $dados -Force }
    $r = Invoke-RemotoGarantir -Servidor $a.servidor -Token $a.token -PastaDados $dados
    Write-Host ''
    $textos = @{
        'ok'               = @('Green',  'Pronto: o acesso remoto ja estava funcionando neste PC.')
        'registrado'       = @('Green',  'PRONTO: acesso remoto instalado e registrado no painel.')
        'desligado'        = @('Yellow', 'Este PC NAO esta liberado para acesso remoto. Nada foi instalado. Libere em Administracao > Acesso remoto no painel e rode o atualizador de novo.')
        'sem-servidor'     = @('Yellow', 'Nao consegui falar com o servidor do painel agora. O agente tenta de novo sozinho mais tarde.')
        'sem-relay'        = @('Yellow', 'Este PC nao alcanca o relay da empresa (fora da rede interna?). O agente tenta de novo sozinho mais tarde.')
        'em-andamento'     = @('Yellow', 'Outra execucao do acesso remoto esta em andamento neste PC. Aguarde alguns minutos e confira no painel.')
        'falha-instalacao' = @('Red',    ('FALHA ao instalar o RustDesk: ' + $script:RemotoUltimoErro))
        'falha-servico'    = @('Red',    ('FALHA ao registrar/iniciar o servico do RustDesk no Windows: ' + $script:RemotoUltimoErro))
        'falha-config'     = @('Red',    ('FALHA ao gravar a configuracao do relay: ' + $script:RemotoUltimoErro))
        'sem-id'           = @('Red',    'O RustDesk foi instalado, mas ainda nao gerou o ID. O agente tenta de novo sozinho.')
        'falha-senha'      = @('Red',    ('O RustDesk nao confirmou a senha de acesso: ' + $script:RemotoUltimoErro))
        'aguardando-sessao' = @('Yellow', 'RustDesk instalado e configurado, mas falta alguem entrar na tela do Windows deste PC para concluir o registro (senha e ID). O agente conclui sozinho.')
        'prazo-esgotado'   = @('Yellow', 'O tempo maximo desta etapa acabou antes de terminar. O agente continua sozinho na proxima rodada.')
        'falha-envio'      = @('Red',    'O RustDesk esta pronto, mas nao consegui registrar no servidor. O agente tenta de novo sozinho.')
    }
    $t = $textos[$r]
    if (-not $t) { $t = @('Yellow', "Resultado: $r") }
    Write-Host ('  ' + $t[1]) -ForegroundColor $t[0]
    Write-Host ''
    Write-Host '  Detalhes tecnicos: C:\ProgramData\PresencaAgente\remoto.log' -ForegroundColor DarkGray
    if ($t[0] -eq 'Red') {
        Write-Host '  Pressione ENTER para fechar esta janela.' -ForegroundColor Gray
        if (-not $SemEspera) { try { [void](Read-Host) } catch { Start-Sleep -Seconds 15 } }
    } else {
        Write-Host '  Esta janela fecha sozinha em instantes.' -ForegroundColor DarkGray
        if (-not $SemEspera) { Start-Sleep -Seconds 8 }
    }
}

Export-ModuleMember -Function *
