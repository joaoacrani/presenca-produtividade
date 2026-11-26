<#
  Atalho "pp-remoto://" do painel: abre o RustDesk ja conectando na maquina escolhida.
  Instalado uma vez por PC de quem acessa (Instalar-Atalho-Remoto.ps1); o navegador chama este script com o link.
  Motivo: o RustDesk ignora o link rustdesk:// quando a janela dele ja esta aberta; aqui a janela aberta e fechada antes.
  So aceita ID numerico e senha alfanumerica; qualquer outra coisa e recusada sem executar nada.
#>
param([string]$Url, [switch]$SoValidar, [string]$Titulo)

function Read-LinkRemoto([string]$Texto) {
    # o navegador pode reescrever o link com uma barra antes da interrogacao (conectar/?id=...) e outra no fim
    if ($Texto -match '^pp-remoto://conectar/?\?id=(\d{6,12})&senha=([A-Za-z0-9]{12,64})/?$') {
        return [pscustomobject]@{ Id = $Matches[1]; Senha = $Matches[2] }
    }
    return $null
}

# Janela PRINCIPAL do RustDesk (a que bloqueia o link): o titulo e exatamente RustDesk. As janelas de sessao tem o titulo
# 'ID@maquina - Remote Desktop - RustDesk' (ou File Transfer etc.) e NAO podem ser fechadas: o administrador pode estar
# conectado em outra maquina enquanto abre esta.
function Test-JanelaPrincipalRustDesk([string]$Titulo) { return ($Titulo.Trim() -eq 'RustDesk') }

if ($SoValidar) {
    if ($PSBoundParameters.ContainsKey('Titulo')) { return (Test-JanelaPrincipalRustDesk $Titulo) }
    return (Read-LinkRemoto $Url)
}

function Show-Aviso([string]$Texto) {
    try { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($Texto, 'Acesso remoto', 'OK', 'Warning') } catch { }
}

$d = Read-LinkRemoto $Url
if (-not $d) { Show-Aviso 'Link de acesso remoto invalido.'; exit 1 }
$rd = Join-Path $env:ProgramFiles 'RustDesk\RustDesk.exe'
if (-not (Test-Path $rd)) { Show-Aviso 'O RustDesk nao esta instalado neste PC.'; exit 2 }

# Fecha so a janela PRINCIPAL do RustDesk desta sessao do Windows (o servico, a bandeja e as sessoes de acesso ja abertas continuam)
$sessao = (Get-Process -Id $PID).SessionId
Get-Process rustdesk -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessao -and $_.MainWindowHandle -ne 0 -and (Test-JanelaPrincipalRustDesk $_.MainWindowTitle) } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800

Start-Process "rustdesk://connection/new/$($d.Id)?password=$($d.Senha)"
