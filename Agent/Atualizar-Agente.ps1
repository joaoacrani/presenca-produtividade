<#
.SYNOPSIS
  Atualizador automatico do agent. Roda como SYSTEM (tarefa "PresencaAgenteUpdate"), no boot e a cada 6 h.
  So instala pacote com assinatura valida; se algo falhar, desfaz (rollback).

  Tambem mantem a entrada do agent em "Aplicativos instalados" (Painel de Controle) e, com -Desinstalar,
  remove o agent deste PC (e o que o botao Desinstalar do Windows executa).
#>
param([switch]$Desinstalar, [switch]$Batimento, [switch]$Software)
$ErrorActionPreference = 'Stop'
$pasta = $PSScriptRoot
Import-Module (Join-Path $pasta 'Presenca.psm1') -Force
Import-Module (Join-Path $pasta 'Atualizador.psm1') -Force
Initialize-RedeAgente

$dados = Join-Path $env:ProgramData 'PresencaAgente'
if ($Desinstalar) {
    Remove-AgenteInstalado -Destino $pasta -PastaDados $dados
    exit 0
}
$servidor = $null; $token = $null; $a = $null
$arqAgente = Join-Path $pasta 'agente.json'
if (Test-Path $arqAgente) {
    try { $a = Get-Content $arqAgente -Raw -Encoding UTF8 | ConvertFrom-Json; $servidor = $a.servidor; $token = $a.token } catch { }
}

# Token proprio da maquina (servidor 2.0+): troca o token de cadastro por um que so vale para este host. Se o servidor ainda
# nao suportar ou estiver fora do ar, nada muda e tenta de novo na proxima rodada.
try {
    if ($servidor -and $token -and ($token -notlike 'ppm_*')) {
        $tk = Register-TokenAgente -Servidor $servidor -ArquivoAgente $arqAgente
        if ($tk -eq 'trocado') {
            try { $a = Get-Content $arqAgente -Raw -Encoding UTF8 | ConvertFrom-Json; $token = $a.token } catch { }
            Write-LogAtualizador (Join-Path $dados 'atualizador.log') 'token proprio da maquina: trocado'
            # o coletor de programas fica rodando com o token que leu ao iniciar: reinicia para pegar o novo
            Stop-ScheduledTask -TaskName 'PresencaAgenteFoco' -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Start-ScheduledTask -TaskName 'PresencaAgenteFoco' -ErrorAction SilentlyContinue
        } elseif ($tk -notin 'ok', 'sem-token') { Write-LogAtualizador (Join-Path $dados 'atualizador.log') "token proprio da maquina: $tk" }
    }
} catch { try { Write-LogAtualizador (Join-Path $dados 'atualizador.log') "token proprio: erro $($_.Exception.Message)" } catch { } }

# Modo batimento (tarefa SYSTEM "PresencaAgenteBatimento", so nos servidores): avisa que a maquina esta no ar e sai.
# Roda sem ninguem logado, a cada 5 min. Nao atualiza nada: isso fica com a tarefa de 6 em 6 horas.
if ($Batimento) {
    if ($servidor -and $token) { [void](Send-Batimento -Servidor $servidor -Token $token) }
    exit 0
}

# Modo software (tarefa SYSTEM "PresencaAgenteSoftware", a cada 15 min): executa as instalacoes pedidas pelo painel e sai.
# So roda pacote com assinatura valida (chave-publica.xml) e arquivo com o mesmo SHA-256. Desligavel em agente.json: executar_software = false.
function Invoke-SoftwareDestePc {
    if (-not ($servidor -and $token) -or ($a -and $a.executar_software -eq $false)) { return 'desligado' }
    $chave = Join-Path $pasta 'chave-publica.xml'
    if (-not (Test-Path $chave)) { return 'sem-chave' }
    $xmlChave = Get-Content -Path $chave -Raw -Encoding UTF8
    return (Invoke-TarefasSoftware -Servidor $servidor -Token $token -ChavePublicaXml $xmlChave -PastaBase (Join-Path $dados 'software') -ArquivoLog (Join-Path $dados 'atualizador.log'))
}
if ($Software) {
    try { Write-Host ("Software: " + (Invoke-SoftwareDestePc)) } catch { try { Write-LogAtualizador (Join-Path $dados 'atualizador.log') "software: erro $($_.Exception.Message)" } catch { } }
    exit 0
}

$status = Invoke-CicloAtualizacao -Destino $pasta -PastaDados $dados -Servidor $servidor -Token $token
Write-Host $status

# Tarefa de instalacao de software (a cada 15 min): so com token proprio da maquina e sem executar_software = false.
try {
    $ligada = [bool]($servidor -and $token -and ($token -like 'ppm_*') -and -not ($a -and $a.executar_software -eq $false))
    $sw = Sync-TarefaSoftware -Destino $pasta -Ligada $ligada -Atualizou ($status -like 'atualizado-para*')
    if ($sw -in 'criada', 'removida') { Write-LogAtualizador (Join-Path $dados 'atualizador.log') "tarefa de software: $sw" }
    # PC novo (ou recem-atualizado): aplica as politicas de instalacao automaticas ja agora, em vez de esperar os 15 min da tarefa.
    if ($ligada) { Start-ScheduledTask -TaskName 'PresencaAgenteSoftware' -ErrorAction SilentlyContinue }
} catch { try { Write-LogAtualizador (Join-Path $dados 'atualizador.log') "tarefa de software: erro $($_.Exception.Message)" } catch { } }

# Coletor de programas em uso: cria a tarefa nos PCs instalados antes dele existir e reinicia o coletor depois de
# uma atualizacao (o processo em execucao ainda esta com o codigo antigo). Desligavel em agente.json: coletar_foco = false.
try {
    if (-not ($a -and $a.coletar_foco -eq $false)) {
        if (-not (Get-ScheduledTask -TaskName 'PresencaAgenteFoco' -ErrorAction SilentlyContinue)) {
            Register-TarefaFoco -Destino $pasta
            Start-ScheduledTask -TaskName 'PresencaAgenteFoco' -ErrorAction SilentlyContinue
        } elseif ($status -like 'atualizado-para*') {
            Stop-ScheduledTask -TaskName 'PresencaAgenteFoco' -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Start-ScheduledTask -TaskName 'PresencaAgenteFoco' -ErrorAction SilentlyContinue
        }
    }
} catch { }

# Servidores (marcados no painel) ganham a tarefa de batimento SYSTEM, que informa "no ar" sem depender de usuario logado.
# Se a maquina deixar de ser servidor, a tarefa e removida. Servidor inalcancavel: nao mexe em nada.
try {
    if ($servidor -and $token) {
        $bat = Sync-TarefaBatimento -Destino $pasta -Politica (Get-BatimentoPolitica -Servidor $servidor -Token $token) -Atualizou ($status -like 'atualizado-para*')
        if ($bat -in 'criada', 'removida') { Write-LogAtualizador (Join-Path $dados 'atualizador.log') "batimento: $bat" }
    }
} catch { try { Write-LogAtualizador (Join-Path $dados 'atualizador.log') "batimento: erro $($_.Exception.Message)" } catch { } }

# Se acabou de se atualizar, recarrega o codigo NOVO do modulo para o acesso remoto ja rodar a versao corrigida nesta mesma rodada
# (sem isso, o codigo antigo, ja carregado na memoria, rodaria mais uma vez e a correcao so valeria 6 horas depois).
if ($status -like 'atualizado-para*') { try { Import-Module (Join-Path $pasta 'Presenca.psm1') -Force } catch { } }

# Acesso remoto (RustDesk): so age quando o servidor libera esta maquina (Administracao > Acesso remoto) e o relay da
# empresa esta alcancavel. Desligavel neste PC em agente.json: acesso_remoto = false.
try {
    if ($servidor -and $token -and -not ($a -and $a.acesso_remoto -eq $false)) {
        $rem = Invoke-RemotoGarantir -Servidor $servidor -Token $token -PastaDados $dados
        Write-Host "Acesso remoto: $rem"
        if ($rem -notin 'ok', 'desligado', 'sem-servidor', 'sem-relay') { Write-LogAtualizador (Join-Path $dados 'atualizador.log') "acesso remoto: $rem" }
    }
} catch { try { Write-LogAtualizador (Join-Path $dados 'atualizador.log') "acesso remoto: erro $($_.Exception.Message)" } catch { } }

# Mantem a entrada de "Aplicativos instalados" (cria nos PCs instalados antes do .exe e atualiza a versao exibida)
try { $null = Register-DesinstalacaoWindows -Destino $pasta -Versao ((Get-VersaoLocal $pasta).ToString()) } catch { }
