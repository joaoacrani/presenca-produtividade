<#
.SYNOPSIS
  Configura (uma unica vez) a publicacao do servidor por FTPS. A senha NAO passa pelo chat nem fica em arquivo do projeto:
  ela e lida do FileZilla (ou digitada aqui) e guardada criptografada, so para o seu usuario do Windows.
  Rode no seu PC:  powershell -ExecutionPolicy Bypass -File .\Servidor\Publicar\Configurar-Publicacao.ps1
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Publicacao.psm1') -Force

Write-Host ''
Write-Host '== Configurar a publicacao do servidor ==' -ForegroundColor Cyan
Write-Host 'A senha do FTP sera guardada criptografada em' (Get-CaminhoConfigPublicacao)
Write-Host '(so o seu usuario do Windows neste PC consegue ler). Ela nunca e mostrada.'
Write-Host ''

$servidor = $null; $porta = 21; $protocolo = 'ftps-explicito'; $usuario = $null; $senha = $null

# 1) Tenta aproveitar o que ja esta salvo no FileZilla
$sites = @(Read-SitesFileZilla)
if ($sites.Count -gt 0) {
    Write-Host 'Sites salvos no FileZilla:'
    for ($i = 0; $i -lt $sites.Count; $i++) { Write-Host ('  [{0}] {1}  ({2}, usuario {3})' -f ($i + 1), $sites[$i].Nome, $sites[$i].Servidor, $sites[$i].Usuario) }
    $r = Read-Host 'Numero do site do servidor (Enter para digitar os dados na mao)'
    if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $sites.Count) {
        $s = $sites[[int]$r - 1]
        $servidor = ($s.Servidor -replace '^(ftp|ftps|sftp)://', '').Trim('/')
        $porta = $s.Porta; $usuario = $s.Usuario; $protocolo = ConvertTo-ProtocoloPublicacao $s.ProtocoloFileZilla
        if ($protocolo -eq 'sftp') { throw 'Esse site usa SFTP. Este script usa FTPS: no painel da hospedagem veja se existe FTPS (explicito) e crie/ajuste o site no FileZilla, ou me diga para eu suportar SFTP.' }
        if ($protocolo -eq 'ftp') { Write-Host 'ATENCAO: esse site esta como FTP sem criptografia. Vou usar FTPS explicito (a senha nao pode trafegar aberta).' -ForegroundColor Yellow; $protocolo = 'ftps-explicito' }
        if ($s.Senha) { $senha = $s.Senha; Write-Host 'Senha lida do FileZilla (nao exibida).' -ForegroundColor Green }
        elseif ($s.SenhaCriptografada) { Write-Host 'O FileZilla esta com senha mestra: nao consigo ler a senha dele. Digite a senha abaixo (ou troque a senha do FTP no painel da hospedagem).' -ForegroundColor Yellow }
        else { Write-Host 'O FileZilla nao tem senha salva para esse site. Digite abaixo.' -ForegroundColor Yellow }
    }
} else { Write-Host 'Nao encontrei sites salvos no FileZilla neste PC.' }

# 2) O que faltar, digita
if (-not $servidor) { $servidor = (Read-Host 'Servidor FTP (ex.: ftp.seudominio.com.br)').Trim() -replace '^(ftp|ftps)://', '' }
if (-not $usuario) { $usuario = (Read-Host 'Usuario do FTP').Trim() }
if (-not $senha) { $senha = Read-Host 'Senha do FTP (nao aparece na tela)' -AsSecureString }

# 3) Endereco publico e pasta remota
$urlPadrao = ''
$cred = Join-Path (Split-Path -Parent $PSScriptRoot) 'credenciais.json'
if (Test-Path $cred) { try { $urlPadrao = (Get-Content $cred -Raw -Encoding UTF8 | ConvertFrom-Json).url } catch { } }
$u = Read-Host ('Endereco publico do painel' + $(if ($urlPadrao) { " [$urlPadrao]" } else { '' }))
$urlPublica = if ($u) { $u.Trim() } else { $urlPadrao }
if ($urlPublica -notmatch '^https://') { throw 'O endereco precisa comecar com https://' }

$cfg = [pscustomobject]@{ servidor = $servidor; porta = $porta; protocolo = $protocolo; usuario = $usuario; pasta = ''; url_publica = $urlPublica; certificado = 'estrito'; Senha = $senha }

Write-Host ''
Write-Host 'Testando a conexao...'
$t = Test-ConexaoPublicacao $cfg
if (-not $t.Ok -and $t.Erro -match 'SSL|certificate|certificado|schannel|TLS') {
    Write-Host ''; Write-Host 'O certificado do servidor FTP nao confere com o nome usado (comum em hospedagem compartilhada).' -ForegroundColor Yellow
    Write-Host 'Posso aceitar esse certificado: a conexao continua criptografada, mas deixa de verificar quem esta do outro lado.'
    if ((Read-Host 'Aceitar mesmo assim? (S/N)') -match '^[sS]') { $cfg.certificado = 'aceitar'; $t = Test-ConexaoPublicacao $cfg }
}
if (-not $t.Ok) { throw ("Nao consegui conectar (curl {0}): {1}" -f $t.Codigo, $t.Erro) }
Write-Host 'Conectou. Conteudo da pasta inicial do FTP:' -ForegroundColor Green
$t.Itens | Select-Object -First 25 | ForEach-Object { Write-Host "   $_" }

# 4) Pasta do site (precisa ter index.php e a pasta _app)
$ok = $false
while (-not $ok) {
    $p = (Read-Host 'Pasta do painel no servidor (ex.: public_html/presenca; deixe vazio se a pasta inicial ja e a do painel)').Trim().Trim('/')
    $cfg.pasta = $p
    $t2 = Test-ConexaoPublicacao $cfg
    if (-not $t2.Ok) { Write-Host "Nao consegui abrir essa pasta: $($t2.Erro)" -ForegroundColor Yellow; continue }
    if ($t2.Itens -contains 'index.php' -and $t2.Itens -contains '_app') { $ok = $true; Write-Host 'Achei index.php e _app: e a pasta do painel.' -ForegroundColor Green }
    else {
        Write-Host 'Essa pasta NAO parece ser a do painel (falta index.php e/ou _app). Conteudo:' -ForegroundColor Yellow
        $t2.Itens | Select-Object -First 25 | ForEach-Object { Write-Host "   $_" }
    }
}

Save-ConfigPublicacao -Dados @{ servidor = $cfg.servidor; porta = $cfg.porta; protocolo = $cfg.protocolo; usuario = $cfg.usuario; pasta = $cfg.pasta; url_publica = $cfg.url_publica; certificado = $cfg.certificado } -Senha $senha
Write-Host ''
Write-Host 'Pronto. Configuracao guardada. A senha nao foi mostrada em lugar nenhum.' -ForegroundColor Green
Write-Host 'Pode me avisar que ja configurou: a partir de agora eu consigo publicar (sempre pedindo o seu OK).'
