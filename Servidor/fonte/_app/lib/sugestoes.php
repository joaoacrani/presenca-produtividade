<?php
// Classificacao AUTOMATICA de sites e programas: um catalogo embutido (pensado para um escritorio de advocacia no Brasil)
// mais regras por padrao (sufixos institucionais e palavras-chave). O resultado vira regras comuns na tabela `regras`,
// marcadas com criado_por = 'auto': aparecem na tela de Classificacao, podem ser trocadas/removidas uma a uma ou todas de uma vez.
// So classifica quando ha motivo; o resto continua na lista "sem classificacao" para o gestor decidir.
// O servidor nunca visita os sites: a sugestao vem apenas do NOME do dominio/programa.

function catalogoDominios()
{
    return [
        'produtivo' => [
            // judiciario, sistemas juridicos, cartorios e orgaos (jus.br, gov.br, mp.br, adv.br... entram por sufixo)
            'projuris.com.br', 'astrea.net.br', 'advbox.com.br', 'thomsonreuters.com.br', 'thomsonreuters.com', 'elaw.com.br', 'elaw.com',
            'digesto.com.br', 'jus.com.br', 'jota.info', 'jurinews.com.br', 'dizerodireito.com.br', 'ambito-juridico.com.br', 'escavador.com',
            'jusdigital.com.br', 'lexml.gov.br', 'pjeoffice.com.br', 'certisign.com.br', 'soluti.com.br', 
            'docusign.com', 'docusign.net', 'clicksign.com', 'd4sign.com.br', 'autentique.com.br', 'zapsign.com.br', 'portaldeassinaturas.com.br',
            'onr.org.br', 'arisp.com.br', 'e-notariado.org.br', 'notariado.org.br', 'ridigital.org.br', 'registrocivil.org.br', 'censec.org.br', 'cnb.org.br',
            'cnpja.com', 'receitaws.com.br', 'casadosdados.com.br', 'cnpj.biz',
            // Microsoft 365 / Google Workspace e colaboracao
            'cloud.microsoft', 'microsoft365.com', 'office.net', 'onedrive.com', '1drv.ms', 'powerbi.com', 'dynamics.com', 'teams.live.com',
            'slides.google.com', 'forms.gle', 'script.google.com', 'notebooklm.google.com', 'gemini.google.com', 'workspace.google.com',
            'atlassian.net', 'atlassian.com', 'trello.com', 'notion.so', 'asana.com', 'monday.com', 'slack.com', 'clickup.com', 'figma.com',
            'canva.com', 'miro.com', 'lucid.app', 'lucidchart.com', 'zoom.com', 'webex.com', 'gotomeeting.com', 'whereby.com', 'calendly.com',
            // ferramentas de PDF e documentos
            'ilovepdf.com', 'smallpdf.com', 'pdf24.org', 'sejda.com', 'pdfescape.com', 'convertio.co', 'online-convert.com', 'freeconvert.com', 'pdf2go.com', 'adobe.io',
            // desenvolvimento, TI e IA
            'githubusercontent.com', 'gitlab.com', 'bitbucket.org', 'stackexchange.com', 'npmjs.com', 'pypi.org', 'dev.azure.com', 'visualstudio.com', 'azure.com',
            'aws.amazon.com', 'docker.com', 'python.org', 'php.net', 'nodejs.org', 'w3schools.com', 'vercel.com', 'netlify.com',
            'openai.com', 'chatgpt.com', 'perplexity.ai', 'deepseek.com', 'mistral.ai', 'huggingface.co',
        ],
        'neutro' => [
            // consultas de IP, testes de velocidade (infraestrutura)
            'ipify.org', 'ifconfig.me', 'icanhazip.com', 'ipinfo.io', 'whatismyip.com', 'speedtest.net', 'fast.com', 'ookla.com', 'nperf.com', 'llm-stats.com',
            // CDN, scripts, telemetria, anuncios e autenticacao que carregam em segundo plano
            'cloudflare.com', 'cloudflare-dns.com', 'cloudfront.net', 'akamaihd.net', 'akamai.net', 'fastly.net', 'jsdelivr.net', 'cdnjs.com', 'unpkg.com',
            'gstatic.com', 'googleapis.com', 'googleusercontent.com', 'gvt1.com', 'ggpht.com', 'googletagmanager.com', 'google-analytics.com', 'doubleclick.net',
            'googlesyndication.com', 'googleadservices.com', 'recaptcha.net', 'hcaptcha.com', 'facebook.net', 'hotjar.com', 'clarity.ms', 'msauth.net',
            'msftauth.net', 'msn.com', 'windowsupdate.com', 'windows.com', 'digicert.com', 'sectigo.com', 'letsencrypt.org', 'onetrust.com', 'cookielaw.org',
            'sentry.io', 'datadoghq.com', 'newrelic.com', 'segment.com', 'amplitude.com', 'mixpanel.com', 'amazonaws.com', 'azureedge.net', 'windows.net',
            'google.com.br', 'accounts.google.com',
            // suporte remoto e transferencia de arquivos
            'anydesk.com', 'rustdesk.com', 'teamviewer.com', 'supremocontrol.com', 'dwservice.net', 'dropbox.com', 'wetransfer.com', 'we.tl', 'mega.nz', 'box.com',
            // mensagens, mapas, consultas e utilidades
            'telegram.org', 't.me', 'telegram.me', 'web.telegram.org', 'signal.org', 'whatsapp.net', 'waze.com', 'openstreetmap.org', 'viacep.com.br',
            'brasilapi.com.br', 'wikimedia.org', 'archive.org', 'deepl.com', 'translate.goog', 'vimeo.com', 'medium.com', 'github.io',
            'shopify.com', 'zendesk.com', 'freshdesk.com', 'intercom.io', 'registro.br', 'godaddy.com', 'locaweb.com.br', 'hostgator.com.br', 'umbler.com',
            'eset.com', 'uptodown.com', 'softonic.com', 'ambientnoise.io', 'noise-foundation.com', 'mynoise.net', 'asoftmurmur.com',
            // bancos e pagamentos (uso pessoal)
            'nubank.com.br', 'inter.co', 'bancointer.com.br', 'btgpactual.com', 'xpi.com.br', 'c6bank.com.br', 'safra.com.br', 'pagseguro.uol.com.br',
            'pagbank.com.br', 'mercadopago.com.br', 'picpay.com',
            // noticias e portais
            'cnnbrasil.com.br', 'bbc.com', 'bbc.co.uk', 'nytimes.com', 'valor.globo.com', 'exame.com', 'infomoney.com.br', 'poder360.com.br', 'oglobo.globo.com',
            'veja.abril.com.br', 'istoe.com.br', 'r7.com', 'metropoles.com', 'correiobraziliense.com.br', 'cartacapital.com.br',
            // ensino
            'udemy.com', 'coursera.org', 'alura.com.br', 'fgv.br', 'scielo.br',
        ],
        'improdutivo' => [
            // redes sociais e mensagens de entretenimento
            'fb.com', 'fb.watch', 'fbcdn.net', 'cdninstagram.com', 'threads.net', 'threads.com', 'snapchat.com', 'tumblr.com', 'vk.com', 'bsky.app',
            'mastodon.social', 'twimg.com', 't.co', 'tiktokcdn.com', 'tiktokv.com', 'byteoversea.com', 'badoo.com', 'bumble.com', 'happn.com',
            // video e musica
            'googlevideo.com', 'ytimg.com', 'youtube-nocookie.com', 'nflxvideo.net', 'nflximg.net', 'aiv-cdn.net', 'paramountplus.com', 'tv.apple.com',
            'crunchyroll.com', 'dailymotion.com', 'kick.com', 'ttvnw.net', 'scdn.co', 'soundcloud.com', 'last.fm', 'tidal.com', 'music.apple.com', 'tunein.com',
            // compras, ofertas, delivery, viagens
            'amazon.com', 'alibaba.com', 'temu.com', 'mercadolibre.com', 'magalu.com', 'submarino.com.br', 'shoptime.com.br', 'pontofrio.com.br', 'extra.com.br',
            'carrefour.com.br', 'fastshop.com.br', 'buscape.com.br', 'zoom.com.br', 'promobit.com.br', 'pelando.com.br', 'cuponomia.com.br', 'meliuz.com.br',
            'ifood.com.br', 'rappi.com.br', 'enjoei.com.br', 'webmotors.com.br', 'icarros.com.br', 'vivareal.com.br', 'zapimoveis.com.br', 'quintoandar.com.br',
            'netshoes.com.br', 'dafiti.com.br', 'centauro.com.br', 'lojasrenner.com.br', 'cea.com.br', 'riachuelo.com.br', 'leroymerlin.com.br', 'petz.com.br',
            'drogasil.com.br', 'drogaraia.com.br', 'booking.com', 'airbnb.com.br', 'decolar.com', 'voegol.com.br', 'maxmilhas.com.br', '123milhas.com', 'hurb.com',
            // apostas
            'betfair.com', 'sportingbet.com', 'esportesdasorte.com', 'superbet.com', 'vaidebet.com', 'bet7k.com', 'novibet.com', '1xbet.com', 'estrelabet.com',
            'betnacional.com', 'pixbet.com',
            // jogos
            'steamcommunity.com', 'steamstatic.com', 'riotgames.com', 'leagueoflegends.com', 'minecraft.net', 'mojang.com', 'ea.com', 'battle.net', 'blizzard.com',
            'ubisoft.com', 'xbox.com', 'playstation.com', 'nintendo.com', 'garena.com', 'supercell.com', 'king.com', 'miniclip.com', 'crazygames.com', 'y8.com',
            'itch.io', 'gog.com', 'rockstargames.com', 'fandom.com', 'ign.com', 'gamespot.com',
            // adulto
            'pornhub.com', 'xvideos.com', 'xnxx.com', 'xhamster.com', 'redtube.com', 'youporn.com', 'onlyfans.com', 'chaturbate.com', 'tube8.com', 'spankbang.com', 'erome.com',
            // entretenimento, esportes e variedades
            'imgur.com', 'ifunny.co', 'buzzfeed.com', 'boredpanda.com', 'knowyourmeme.com', 'globoesporte.com', 'espn.com.br', 'espn.com', 'lance.com.br',
            'gazetaesportiva.com', 'cartola.globo.com', 'cbf.com.br', 'transfermarkt.com', 'sofascore.com', 'flashscore.com', '365scores.com', 'gshow.globo.com',
            'caras.uol.com.br', 'ig.com.br', 'bol.com.br', 'thepiratebay.org', '1337x.to', 'yts.mx',
        ],
    ];
}

// Sufixos institucionais: qualquer endereco que termine neles recebe a categoria.
function sufixosInstitucionais()
{
    return [
        'jus.br' => 'produtivo', 'mp.br' => 'produtivo', 'def.br' => 'produtivo', 'leg.br' => 'produtivo', 'gov.br' => 'produtivo',
        'adv.br' => 'produtivo', 'not.br' => 'produtivo', 'mil.br' => 'neutro', 'edu.br' => 'neutro',
    ];
}

function catalogoApps()
{
    return [
        'produtivo' => ['foxitreader', 'foxitphantom', 'pdfxedit', 'slack', 'webex', 'ciscocollabhost', 'skype', 'devenv', 'pycharm64',
            'idea64', 'notepad++', 'sublime_text', 'gitkraken', 'githubdesktop', 'putty', 'winscp', 'filezilla', 'mobaxterm', 'ssms', 'dbeaver', 'postman', 'wps', 'et', 'wpp',
            'soffice', 'soffice.bin', 'swriter', 'scalc', 'thunderbird', 'projuris', 'astrea', 'advbox', 'pjeoffice', 'pjeofficeprocess', 'receitanetbx', 'receitanet', 'sped',
            'sefip', 'conectividadesocial', 'esocial', 'dirf', 'irpf'],
        'neutro' => ['svchost', 'dllhost', 'conhost', 'runtimebroker', 'searchapp', 'textinputhost', 'applicationframehost', 'msedgewebview2', 'anydesk', 'teamviewer',
            'rustdesk', 'supremo', 'dwagent', 'mstsc', 'onedrive', 'snipaste', 'greenshot', 'lightshot', '7zfm', 'winrar', 'vlc', 'mpc-hc', 'sharex', 'ditto', 'powertoys',
            'teracopy', 'egui', 'ekrn', 'gamingservices', 'obs64', 'telegram', 'signal', 'zapcallapp'],
        'improdutivo' => ['battle.net', 'blizzard', 'origin', 'eadesktop', 'ubisoftconnect', 'upc', 'goggalaxy', 'xboxapp', 'netflix', 'primevideo', 'disneyplus', 'tiktok',
            'instagram', 'wallpaperengine', 'wallpaper32', 'bluestacks', 'hd-player', 'nox', 'ldplayer', 'freefire'],
    ];
}

function indiceCatalogo($qual)
{
    static $cache = [];
    if (!isset($cache[$qual])) {
        $i = [];
        foreach (($qual === 'app' ? catalogoApps() : catalogoDominios()) as $cat => $lista) foreach ($lista as $d) $i[$d] = $cat;
        $cache[$qual] = $i;
    }
    return $cache[$qual];
}

// "scania.elaw.com.br" -> "elaw.com.br"; "api.ipify.org" -> "ipify.org".
function dominioRegistravel($d)
{
    $p = explode('.', strtolower($d));
    $n = count($p);
    if ($n <= 2) return implode('.', $p);
    $segundo = ['com', 'net', 'org', 'gov', 'edu', 'adv', 'jus', 'mp', 'def', 'leg', 'mil', 'not', 'eco', 'blog', 'art', 'eng', 'ind', 'inf'];
    if (strlen($p[$n - 1]) === 2 && in_array($p[$n - 2], $segundo, true)) return implode('.', array_slice($p, -3));
    return implode('.', array_slice($p, -2));
}

// Devolve ['padrao' => regra a gravar, 'categoria' => ..., 'motivo' => ...] ou null quando nao ha certeza.
function sugerirDominio($dominio)
{
    $d = strtolower(trim((string)$dominio));
    if ($d === '' || strpos($d, '.') === false) return null;
    $idx = indiceCatalogo('dom');
    $partes = explode('.', $d);
    // 1) catalogo: do endereco completo para a raiz (o mais especifico vence)
    for ($i = 0; $i < count($partes) - 1; $i++) {
        $cand = implode('.', array_slice($partes, $i));
        if (isset($idx[$cand])) return ['padrao' => $cand, 'categoria' => $idx[$cand], 'motivo' => 'catalogo'];
    }
    // 2) sufixos institucionais (.jus.br, .adv.br, .not.br...)
    foreach (sufixosInstitucionais() as $suf => $cat) {
        if ($d === $suf || substr($d, -strlen($suf) - 1) === '.' . $suf) return ['padrao' => $suf, 'categoria' => $cat, 'motivo' => 'sufixo institucional (.' . $suf . ')'];
    }
    // 3) palavras-chave no nome do dominio (so no nome registrado, nao em subdominios)
    $reg = dominioRegistravel($d);
    $nome = explode('.', $reg)[0];
    $regras = [
        ['improdutivo', 'conteudo adulto', '/(porn|xxx|xvideos|xnxx|xhamster|redtube|youporn|onlyfans|hentai|camgirl|chaturbate|spankbang)/'],
        ['improdutivo', 'apostas', '/(^|-)bet(-|$)|^bet[0-9]|bet(365|ano|fair|nacional|7k|boo|sson|way)|cassino|casino|poker|apostas?|jogodobicho/'],
        ['improdutivo', 'loja/compras', '/^(loja|lojas|shop|outlet|oferta|ofertas|cupom|cupons)|^promo(-|$)|^promoc(ao|oes)|(shop|loja|lojas|outlet|ofertas|cupom|cupons)$/'],
        ['improdutivo', 'jogos', '/(^|-)games?(-|$)|games?$|gamer|gaming|^jogos|jogos$|(^|-)jogos(-|$)/'],
        ['improdutivo', 'filmes/series/torrent', '/(filmes|torrent|assistir|animes?|doramas?|novelas)|series(online|hd|gratis|tv)|(online|hd|gratis|tv)series/'],
        ['improdutivo', 'futebol/esportes', '/(futebol|esportes?|palpites?)/'],
    ];
    foreach ($regras as $r) {
        if (preg_match($r[2], $nome)) return ['padrao' => $reg, 'categoria' => $r[0], 'motivo' => 'nome do site sugere ' . $r[1]];
    }
    // 4) enderecos de servico/infraestrutura (api.exemplo.com, cdn.exemplo.com...): so o proprio endereco
    $infra = ['api', 'cdn', 'static', 'assets', 'img', 'images', 'media', 'telemetry', 'metrics', 'logs', 'analytics', 'tracking', 'ads', 'adservice', 'pixel', 'push', 'ocsp', 'crl', 'update', 'updates'];
    if ($d !== $reg && in_array($partes[0], $infra, true)) return ['padrao' => $d, 'categoria' => 'neutro', 'motivo' => 'endereco de servico (' . $partes[0] . '.)'];
    return null;
}

function sugerirApp($proc)
{
    $p = strtolower(trim((string)$proc));
    if ($p === '' || ehNavegadorProc($p)) return null;
    $idx = indiceCatalogo('app');
    if (isset($idx[$p])) return ['padrao' => 'app:' . $p, 'categoria' => $idx[$p], 'motivo' => 'catalogo'];
    if (preg_match('/(steam|epicgames|roblox|minecraft|leagueoflegends|valorant|fortnite|genshin)/', $p)) return ['padrao' => 'app:' . $p, 'categoria' => 'improdutivo', 'motivo' => 'jogo'];
    if (preg_match('/(updater|update|helper|broker|host|service|installer|setup|crashhandler|crashreport)$/', $p)) return ['padrao' => 'app:' . $p, 'categoria' => 'neutro', 'motivo' => 'processo auxiliar do sistema'];
    return null;
}

function classificacaoAutomaticaAtiva(PDO $db)
{
    return metaGet($db, 'classificar_auto') !== '0';   // ligada por padrao
}

// Cria regras 'auto' para os dominios/programas sem regra que tenham sugestao. Nao mexe no que ja tem regra.
// Devolve ['aplicadas', 'por_categoria', 'amostra']. Chamar dentro de uma transacao se for gravar muitos.
function aplicarSugestoes(PDO $db, $agora, array $dominios, array $programas = [])
{
    $regras = carregarRegras($db);
    $ins = $db->prepare('INSERT OR IGNORE INTO regras (padrao, categoria, criado_por, criado_em) VALUES (?,?,?,?)');
    $res = ['aplicadas' => 0, 'por_categoria' => ['produtivo' => 0, 'neutro' => 0, 'improdutivo' => 0], 'amostra' => []];
    $gravar = function ($s, $padrao) use (&$regras, $ins, $agora, &$res) {
        if ($padrao === null) return;
        $ins->execute([$padrao, $s['categoria'], 'auto', $agora]);
        if ($ins->rowCount() > 0) {
            $regras[$padrao] = $s['categoria'];
            $res['aplicadas']++;
            $res['por_categoria'][$s['categoria']]++;
            if (count($res['amostra']) < 60) $res['amostra'][] = ['padrao' => $padrao, 'categoria' => $s['categoria'], 'motivo' => $s['motivo']];
        }
    };
    foreach ($dominios as $d) {
        if (classificarDominio($d, $regras)[1] !== null) continue;
        $s = sugerirDominio($d);
        if ($s) $gravar($s, normalizarPadrao($s['padrao']));
    }
    foreach ($programas as $pr) {
        if (ehNavegadorProc($pr) || classificarApp($pr, $regras)[1] !== null) continue;
        $s = sugerirApp($pr);
        if ($s) $gravar($s, normalizarPadraoApp($s['padrao']));
    }
    return $res;
}

// Quantos dominios/programas do periodo continuam sem regra (para dizer "restam N para voce decidir").
function contarSemRegra(PDO $db, $de, $ate)
{
    $regras = carregarRegras($db);
    $st = $db->prepare('SELECT DISTINCT dominio FROM nav_dia WHERE dia >= ? AND dia <= ?');
    $st->execute([$de, $ate]);
    $sites = 0;
    foreach ($st->fetchAll(PDO::FETCH_COLUMN) as $d) if (classificarDominio($d, $regras)[1] === null) $sites++;
    $st = $db->prepare('SELECT DISTINCT processo FROM foco_dia WHERE dia >= ? AND dia <= ?');
    $st->execute([$de, $ate]);
    $progs = 0;
    foreach ($st->fetchAll(PDO::FETCH_COLUMN) as $p) { $c = classificarApp($p, $regras); if ($c[0] !== 'navegador' && $c[1] === null) $progs++; }
    return ['sites' => $sites, 'programas' => $progs];
}
