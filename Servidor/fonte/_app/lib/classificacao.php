<?php
// Classificacao de dominios em produtivo / improdutivo / neutro.
// A classificacao e feita na hora do relatorio (nao fica gravada nos acessos): mudar uma regra vale
// para todo o historico. Regra = dominio; vale tambem para os subdominios (a mais especifica vence).

const CATEGORIAS = ['produtivo', 'improdutivo', 'neutro'];

function regrasPadrao()
{
    return [
        'produtivo' => [
            'legale.com.br', 'legalone.com.br', 'jus.br', 'pje.jus.br', 'oab.org.br', 'jusbrasil.com.br',
            'gov.br', 'receita.fazenda.gov.br', 'office.com', 'microsoft.com', 'microsoftonline.com', 'sharepoint.com',
            'outlook.com', 'outlook.live.com', 'teams.microsoft.com', 'office365.com', 'live.com',
            'docs.google.com', 'drive.google.com', 'sheets.google.com', 'meet.google.com', 'calendar.google.com',
            'zoom.us', 'github.com', 'stackoverflow.com', 'claude.ai', 'anthropic.com', 'adobe.com',
            'tjsp.jus.br', 'trt15.jus.br', 'stf.jus.br', 'stj.jus.br', 'planalto.gov.br', 'conjur.com.br', 'migalhas.com.br',
        ],
        'improdutivo' => [
            'youtube.com', 'youtu.be', 'facebook.com', 'instagram.com', 'tiktok.com', 'twitter.com', 'x.com', 'kwai.com',
            'netflix.com', 'primevideo.com', 'disneyplus.com', 'hbomax.com', 'max.com', 'globoplay.globo.com', 'twitch.tv',
            'spotify.com', 'deezer.com', 'pinterest.com', 'reddit.com', '9gag.com', 'tinder.com', 'discord.com',
            'mercadolivre.com.br', 'shopee.com.br', 'amazon.com.br', 'aliexpress.com', 'magazineluiza.com.br',
            'americanas.com.br', 'olx.com.br', 'shein.com', 'casasbahia.com.br', 'kabum.com.br',
            'ge.globo.com', 'uol.com.br', 'terra.com.br', 'bet365.com', 'betano.com', 'blaze.com', 'stake.com',
            'steampowered.com', 'roblox.com', 'epicgames.com', 'friv.com', 'poki.com',
        ],
        'neutro' => [
            'google.com', 'bing.com', 'duckduckgo.com', 'whatsapp.com', 'web.whatsapp.com', 'linkedin.com',
            'wikipedia.org', 'g1.globo.com', 'globo.com', 'folha.uol.com.br', 'estadao.com.br', 'gmail.com', 'mail.google.com',
            'translate.google.com', 'maps.google.com', 'correios.com.br',
            'itau.com.br', 'bb.com.br', 'caixa.gov.br', 'bradesco.com.br', 'santander.com.br', 'sicredi.com.br',
        ],
    ];
}

function semearRegras(PDO $db, $agora)
{
    $n = (int)$db->query('SELECT COUNT(*) FROM regras')->fetchColumn();
    if ($n > 0) return;
    $st = $db->prepare('INSERT OR IGNORE INTO regras (padrao, categoria, criado_por, criado_em) VALUES (?,?,?,?)');
    foreach (regrasPadrao() as $cat => $lista) {
        foreach ($lista as $p) $st->execute([$p, $cat, 'padrao', $agora]);
    }
}

function normalizarPadrao($p)
{
    $p = strtolower(trim((string)$p));
    $p = preg_replace('#^[a-z]+://#', '', $p);
    $p = preg_replace('#/.*$#', '', $p);
    $p = preg_replace('/^www\./', '', $p);
    $p = trim($p, '.');
    if ($p === '' || strlen($p) > 120 || !preg_match('/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/', $p)) return null;
    return $p;
}

// ---------- programas (aplicativos): regras com o prefixo "app:" na mesma tabela de regras ----------

function ehNavegadorProc($proc)
{
    return in_array(strtolower((string)$proc), ['chrome', 'msedge', 'firefox', 'brave', 'opera', 'opera_gx', 'vivaldi', 'iexplore', 'waterfox', 'arc'], true);
}

// "app:winword" (minusculo). Devolve null se invalido.
function normalizarPadraoApp($p)
{
    $p = strtolower(trim((string)$p));
    if (!preg_match('/^app:[a-z0-9][a-z0-9 ._()+-]{0,59}$/', $p)) return null;
    return $p;
}

// Devolve [categoria, regra|null]. Navegadores ficam fora ('navegador'): o tempo deles ja e medido pelos sites.
function classificarApp($proc, array $regras)
{
    if (ehNavegadorProc($proc)) return ['navegador', null];
    $k = 'app:' . strtolower((string)$proc);
    return isset($regras[$k]) ? [$regras[$k], $k] : ['neutro', null];
}

function regrasAppPadrao()
{
    return [
        'produtivo' => ['winword', 'excel', 'powerpnt', 'outlook', 'olk', 'acrobat', 'acrord32', 'acrord64', 'onenote', 'visio', 'msaccess', 'mspub',
            'ms-teams', 'teams', 'zoom', 'code', 'claude', 'legaleweb', 'legalone'],
        'improdutivo' => ['robloxplayerbeta', 'robloxstudiobeta', 'steam', 'steamwebhelper', 'epicgameslauncher', 'spotify', 'discord', 'minecraft', 'leagueclient', 'valorant'],
        'neutro' => ['explorer', 'lockapp', 'shellexperiencehost', 'searchhost', 'startmenuexperiencehost', 'notepad', 'calc', 'systemsettings', 'taskmgr',
            'cmd', 'powershell', 'windowsterminal', 'whatsapp.root', 'whatsapp', 'copilotapp', 'snippingtool', 'mspaint'],
    ];
}

// Uma vez por banco: acrescenta as regras de programas (sem mexer nas que o administrador ja criou).
function semearRegrasApp(PDO $db, $agora)
{
    if (metaGet($db, 'regras_app_v1') !== null) return;
    $st = $db->prepare('INSERT OR IGNORE INTO regras (padrao, categoria, criado_por, criado_em) VALUES (?,?,?,?)');
    foreach (regrasAppPadrao() as $cat => $lista) foreach ($lista as $p) $st->execute(['app:' . $p, $cat, 'padrao', $agora]);
    metaSet($db, 'regras_app_v1', '1');
}

function carregarRegras(PDO $db)
{
    $mapa = [];
    foreach ($db->query('SELECT padrao, categoria FROM regras') as $r) $mapa[$r['padrao']] = $r['categoria'];
    return $mapa;
}

// Devolve [categoria, regra|null]. Procura do dominio completo para a raiz (a.b.c.com, b.c.com, c.com, com).
function classificarDominio($dominio, array $regras)
{
    $partes = explode('.', strtolower($dominio));
    for ($i = 0; $i < count($partes); $i++) {
        $cand = implode('.', array_slice($partes, $i));
        if (isset($regras[$cand])) return [$regras[$cand], $cand];
    }
    return ['neutro', null];
}

// Dominio de uma URL (sem "www."). Devolve null se nao for http/https.
function dominioDeUrl($url)
{
    $u = parse_url((string)$url);
    if (!is_array($u) || empty($u['host']) || empty($u['scheme'])) return null;
    $esq = strtolower($u['scheme']);
    if ($esq !== 'http' && $esq !== 'https') return null;
    $h = strtolower(rtrim($u['host'], '.'));
    $h = preg_replace('/^www\./', '', $h);
    if ($h === '' || strlen($h) > 150) return null;
    return $h;
}

// Remove consulta e fragmento (podem conter tokens/dados pessoais) e limita o tamanho.
function urlSemConsulta($url)
{
    $u = parse_url((string)$url);
    if (!is_array($u) || empty($u['host']) || empty($u['scheme'])) return null;
    $esq = strtolower($u['scheme']);
    if ($esq !== 'http' && $esq !== 'https') return null;
    $p = isset($u['path']) ? $u['path'] : '/';
    return $esq . '://' . strtolower($u['host']) . cortar($p, 200);
}
