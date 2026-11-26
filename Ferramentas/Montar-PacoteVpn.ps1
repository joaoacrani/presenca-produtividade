# Monta o pacote zip do OpenVPN + perfil do escritorio para cadastrar em Administracao > Politicas de Instalacao.
# Le a pasta de origem (openvpn-install.msi e config\*.ovpn), junta os scripts de Modelos\VPN e grava o zip em Servidor\local\pacote-vpn\.
# Essa pasta e ignorada pelo git e fora do backup para o OneDrive: o .ovpn tem certificado e chave privada do cliente. O conteudo dos arquivos
# nao e lido nem mostrado aqui, so copiado para dentro do zip.
param(
    [Parameter(Mandatory)] [string]$Origem,
    [string]$Saida = ''
)
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
if (-not $Saida) { $Saida = Join-Path $raiz 'Servidor\local\pacote-vpn' }
$msi = Join-Path $Origem 'openvpn-install.msi'
$ovpns = @(Get-ChildItem -Path (Join-Path $Origem 'config') -Filter '*.ovpn' -File -ErrorAction SilentlyContinue)
if (-not (Test-Path -LiteralPath $msi)) { throw "nao achei $msi" }
if ($ovpns.Count -lt 1) { throw "nao achei nenhum .ovpn em $(Join-Path $Origem 'config')" }
$null = New-Item -ItemType Directory -Path $Saida -Force
$zip = Join-Path $Saida 'openvpn-escritorio.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $msi, 'openvpn-install.msi', [System.IO.Compression.CompressionLevel]::Optimal)
    foreach ($s in 'instalar.cmd', 'remover.cmd') {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, (Join-Path $raiz "Modelos\VPN\$s"), $s, [System.IO.Compression.CompressionLevel]::Optimal)
    }
    foreach ($o in $ovpns) {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $o.FullName, ('config/' + $o.Name), [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $z.Dispose() }
$info = Get-Item -LiteralPath $zip
"Pacote pronto: $zip ($([math]::Round($info.Length / 1MB, 1)) MB)"
"Perfil(is) incluido(s): " + (($ovpns | ForEach-Object { $_.Name }) -join ', ')
''
'No painel (Administracao > Politicas de Instalacao), use:'
'  Arquivo do pacote ........ openvpn-escritorio.zip'
'  Arquivo a executar ....... instalar.cmd'
'  Nome do software ......... OpenVPN'
'  Arquivo gatilho .......... (deixe VAZIO: o instalar.cmd ja pula o MSI se o OpenVPN existe)'
'  Desinstalacao ............ por script do pacote: remover.cmd'
'Depois ligue "Aplicar automaticamente" (alvo vazio = todas, ou ex.: MTZ*).'
