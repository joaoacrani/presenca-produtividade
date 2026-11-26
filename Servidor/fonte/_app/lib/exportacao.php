<?php
// Relatorio completo em Excel (.xlsx): so o que importa, sem as colunas vazias/"Pendente" dos relatorios de referencia.
// Abas: Resumo por colaborador | Dia a dia | Localizacao (trechos) | Acessos (admin).

const EXPORT_LOC_MAX_DIAS = 14;     // a aba de localizacao cobre no maximo os ultimos 14 dias do periodo
const EXPORT_MAX_LINHAS = 100000;   // limite por aba (Excel suporta 1 milhao, mas o servidor e compartilhado)
const EXPORT_LACUNA_MS = 1800000;   // mais de 30 min sem leitura = o PC ficou desligado/sem rede: novo trecho

function rotuloCategoria($c)
{
    $m = ['produtivo' => 'Produtivo', 'improdutivo' => 'Improdutivo', 'neutro' => 'Neutro'];
    return isset($m[$c]) ? $m[$c] : ucfirst((string)$c);
}

function textoUnidades($u)
{
    $p = [];
    foreach ((array)$u as $nome => $n) $p[] = $nome . ': ' . $n;
    return implode(' · ', $p);
}

function abaResumo(PDO $db, $cfg, $de, $ate, $agora)
{
    $bi = relatorioBI($db, $cfg, $de, $ate, $agora, false); // so sites: os programas tem colunas proprias
    $foco = focoPorLogin($db, $de, $ate);
    $linhas = [];
    foreach ($bi['colaboradores'] as $c) {
        $s = $c['segundos'];
        $den = $s['produtivo'] + $s['improdutivo'];
        $f = isset($foco[$c['login']]) ? $foco[$c['login']] : null;
        $denG = $den + ($f ? $f['produtivo'] + $f['improdutivo'] : 0);
        $linhas[] = [$c['colaborador'], $c['login'], $c['setor'], textoUnidades($c['unidades']),
            $c['dias_presenciais'], $c['dias_remotos'], $c['dias_parciais'], $c['dias_sem_registro'], $c['dias_uteis'],
            xDur($c['total_seg']), xDur($s['produtivo']), xDur($s['improdutivo']), xDur($s['neutro']),
            xPct($c['pct_produtivo']), xPct($den > 0 ? round($s['improdutivo'] * 100 / $den, 1) : null),
            $f ? xDur($f['ativo']) : null, $f ? xDur($f['navegador']) : null, $f ? xDur($f['produtivo']) : null, $f ? xDur($f['improdutivo']) : null, $f ? xDur($f['neutro']) : null,
            $denG > 0 ? xPct(round(($s['produtivo'] + ($f ? $f['produtivo'] : 0)) * 100 / $denG, 1)) : null];
    }
    return ['nome' => 'Resumo por colaborador',
        'cabecalho' => ['Colaborador', 'Login', 'Setor', 'Unidades (dias presenciais)', 'Dias presenciais', 'Dias remotos', 'Dias parciais', 'Dias sem registro', 'Dias úteis',
            'Tempo de navegação', 'Produtivo', 'Improdutivo', 'Neutro', '% produtivo', '% improdutivo',
            'Tempo ativo no PC', 'Tempo no navegador (em foco)', 'Programas produtivo', 'Programas improdutivo', 'Programas neutro', '% produtivo geral (sites + programas)'],
        'larguras' => [38, 16, 16, 24, 11, 11, 11, 11, 9, 14, 12, 12, 12, 11, 11, 13, 14, 12, 12, 12, 16],
        'linhas' => $linhas];
}

function abaDiaADia(PDO $db, $cfg, $de, $ate, $agora)
{
    $tz = fusoDe($cfg);
    $off = $tz->getOffset(new DateTime('@' . intdiv($agora, 1000)));
    $hoje = diaLocal($agora, $tz);
    $colabs = mapaColaboradores($db);
    $regras = carregarRegras($db);
    $dias = diasUteis($de, $ate, $cfg);
    $porDia = presencaPorDia($db, $de, $ate);
    $inicios = primeiroDiaPorLogin($db);
    $ini = (new DateTimeImmutable($de . ' 00:00:00', $tz))->getTimestamp() * 1000;
    $fim = (new DateTimeImmutable($ate . ' 23:59:59', $tz))->getTimestamp() * 1000;

    // computador e horario de cada colaborador por dia (agregado no SQLite: nao carrega as leituras uma a uma)
    $maq = [];
    $servs = array_keys(mapaServidores($db)); // servidores nao entram nas contas por colaborador
    $filtroServ = $servs ? ' AND UPPER(host) NOT IN (' . implode(',', array_fill(0, count($servs), '?')) . ')' : '';
    $st = $db->prepare('SELECT login, date((ts / 1000) + ?, \'unixepoch\') AS dia, host, MIN(ts) AS a, MAX(ts) AS b, COUNT(*) AS n, GROUP_CONCAT(DISTINCT ip_saida) AS ips
        FROM registros WHERE ts >= ? AND ts <= ?' . $filtroServ . ' GROUP BY login, dia, host');
    $st->execute(array_merge([$off, $ini, $fim], $servs));
    foreach ($st->fetchAll() as $r) {
        $k = $r['login'] . '|' . $r['dia'];
        if (!isset($maq[$k])) $maq[$k] = ['hosts' => [], 'ips' => [], 'a' => (int)$r['a'], 'b' => (int)$r['b']];
        $maq[$k]['hosts'][] = $r['host'];
        foreach (array_filter(explode(',', (string)$r['ips'])) as $ipx) $maq[$k]['ips'][$ipx] = true;
        $maq[$k]['a'] = min($maq[$k]['a'], (int)$r['a']);
        $maq[$k]['b'] = max($maq[$k]['b'], (int)$r['b']);
    }
    // navegacao por dia: tempo por categoria e sites que mais usou
    $nav = [];
    $st = $db->prepare('SELECT login, dia, dominio, segundos FROM nav_dia WHERE dia >= ? AND dia <= ?');
    $st->execute([$de, $ate]);
    foreach ($st->fetchAll() as $r) {
        $k = $r['login'] . '|' . $r['dia'];
        if (!isset($nav[$k])) $nav[$k] = ['produtivo' => 0, 'improdutivo' => 0, 'neutro' => 0, 'dom' => []];
        $cat = classificarDominio($r['dominio'], $regras)[0];
        $nav[$k][$cat] += (int)$r['segundos'];
        $nav[$k]['dom'][$r['dominio']] = (isset($nav[$k]['dom'][$r['dominio']]) ? $nav[$k]['dom'][$r['dominio']] : 0) + (int)$r['segundos'];
    }
    // programas em foco por dia
    $fd = [];
    $st = $db->prepare('SELECT login, dia, processo, segundos FROM foco_dia WHERE dia >= ? AND dia <= ?');
    $st->execute([$de, $ate]);
    foreach ($st->fetchAll() as $r) {
        $k = $r['login'] . '|' . $r['dia'];
        if (!isset($fd[$k])) $fd[$k] = ['ativo' => 0, 'apps' => []];
        $fd[$k]['ativo'] += (int)$r['segundos'];
        if (classificarApp($r['processo'], $regras)[0] !== 'navegador') $fd[$k]['apps'][$r['processo']] = (int)$r['segundos'];
    }
    $logins = array_keys($porDia);
    foreach ($fd as $k => $_) { $l = explode('|', $k)[0]; if (!in_array($l, $logins, true)) $logins[] = $l; }
    foreach ($nav as $k => $_) { $l = explode('|', $k)[0]; if (!in_array($l, $logins, true)) $logins[] = $l; }

    $linhas = [];
    foreach ($logins as $l) {
        if (isset($colabs[$l]) && !$colabs[$l]['ativo']) continue;
        $res = resumoPresenca($dias, isset($porDia[$l]) ? $porDia[$l] : [], $cfg, $hoje, isset($inicios[$l]) ? $inicios[$l] : '');
        $i = identidade($l, $colabs);
        foreach ($res['detalhe'] as $d) {
            $k = $l . '|' . $d['dia'];
            $m = isset($maq[$k]) ? $maq[$k] : null;
            $n = isset($nav[$k]) ? $nav[$k] : null;
            $top = '';
            if ($n) {
                arsort($n['dom']);
                $p = [];
                foreach (array_slice($n['dom'], 0, 3, true) as $dom => $seg) $p[] = $dom . ' (' . max(1, (int)round($seg / 60)) . ' min)';
                $top = implode('; ', $p);
            }
            $den = $n ? $n['produtivo'] + $n['improdutivo'] : 0;
            $g = isset($fd[$k]) ? $fd[$k] : null;
            $topApps = '';
            if ($g && $g['apps']) {
                arsort($g['apps']);
                $pa = [];
                foreach (array_slice($g['apps'], 0, 3, true) as $proc => $seg) $pa[] = nomeProgramaAmigavel($proc) . ' (' . max(1, (int)round($seg / 60)) . ' min)';
                $topApps = implode('; ', $pa);
            }
            $linhas[] = [xDia($d['dia']), $i['colaborador'], $i['login'], $i['setor'], $d['status'], $d['unidade'],
                $m ? implode(' + ', array_unique($m['hosts'])) : '', $m ? implode(' + ', array_keys($m['ips'])) : '', $m ? xDt($m['a']) : null, $m ? xDt($m['b']) : null, $d['leituras_total'],
                $n ? xDur($n['produtivo'] + $n['improdutivo'] + $n['neutro']) : null,
                $n ? xDur($n['produtivo']) : null, $n ? xDur($n['improdutivo']) : null, $n ? xDur($n['neutro']) : null,
                $den > 0 ? xPct(round($n['produtivo'] * 100 / $den, 1)) : null, $top,
                $g ? xDur($g['ativo']) : null, $topApps];
        }
    }
    usort($linhas, function ($a, $b) { return strcasecmp($a[1], $b[1]) ?: strcmp($a[0]['v'], $b[0]['v']); });
    return ['nome' => 'Dia a dia',
        'cabecalho' => ['Data', 'Colaborador', 'Login', 'Setor', 'Situação do dia', 'Unidade', 'Computador', 'IP de saída', 'Primeira leitura', 'Última leitura', 'Leituras com rede',
            'Tempo de navegação', 'Produtivo', 'Improdutivo', 'Neutro', '% produtivo', 'Sites que mais usou', 'Tempo ativo no PC', 'Programas que mais usou'],
        'larguras' => [12, 38, 16, 14, 16, 10, 16, 18, 17, 17, 10, 13, 11, 11, 11, 11, 70, 13, 70],
        'linhas' => $linhas];
}

// Trechos: leituras seguidas com o mesmo local viram uma linha so ("das 08:02 as 12:10, MTZ, presencial").
function abaLocalizacao(PDO $db, $cfg, $de, $ate)
{
    $tz = fusoDe($cfg);
    $colabs = mapaColaboradores($db);
    $servidores = mapaServidores($db);
    $ini = (new DateTimeImmutable($de . ' 00:00:00', $tz))->getTimestamp() * 1000;
    $fim = (new DateTimeImmutable($ate . ' 23:59:59', $tz))->getTimestamp() * 1000;
    $minIni = $fim - EXPORT_LOC_MAX_DIAS * 86400000;
    $recortado = $ini < $minIni;
    if ($recortado) $ini = $minIni;
    $st = $db->prepare('SELECT host, login, nome, ts, resultado, unidade, vpn_ativa, ip_saida FROM registros WHERE ts >= ? AND ts <= ? ORDER BY host, ts');
    $st->execute([$ini, $fim]);
    $linhas = [];
    $atual = null;
    $fecha = function () use (&$atual, &$linhas, $colabs, $servidores) {
        if ($atual === null || count($linhas) >= EXPORT_MAX_LINHAS) return;
        $i = identidade($atual['login'], $colabs);
        $quem = isset($servidores[strtoupper($atual['host'])]) ? 'Servidor - último usuário: ' . nomeExibicao($atual['login'], $atual['nome']) : $i['colaborador'];
        $linhas[] = [$atual['host'], $quem, xDt($atual['a']), xDt($atual['b']), xDur(intdiv($atual['b'] - $atual['a'], 1000)),
            $atual['n'], $atual['resultado'], $atual['unidade'], $atual['vpn'] === 'sim' ? 'sim' : 'não', $atual['ip']];
    };
    while ($r = $st->fetch()) {
        $ts = (int)$r['ts'];
        $login = $r['login'] !== null && $r['login'] !== '' ? $r['login'] : loginDe('');
        $mesmo = $atual !== null && $atual['host'] === $r['host'] && $atual['login'] === $login && $atual['resultado'] === $r['resultado']
            && $atual['unidade'] === (string)$r['unidade'] && $atual['vpn'] === (string)$r['vpn_ativa'] && $atual['ip'] === (string)$r['ip_saida']
            && $ts - $atual['b'] <= EXPORT_LACUNA_MS;
        if ($mesmo) { $atual['b'] = $ts; $atual['n']++; continue; }
        $fecha();
        $atual = ['host' => $r['host'], 'login' => $login, 'nome' => (string)$r['nome'], 'a' => $ts, 'b' => $ts, 'n' => 1, 'resultado' => $r['resultado'],
            'unidade' => (string)$r['unidade'], 'vpn' => (string)$r['vpn_ativa'], 'ip' => (string)$r['ip_saida']];
    }
    $fecha();
    usort($linhas, function ($a, $b) { return strcasecmp($a[1], $b[1]) ?: ($a[2]['v'] <=> $b[2]['v']); });
    return ['nome' => $recortado ? 'Localização (últimos ' . EXPORT_LOC_MAX_DIAS . ' dias)' : 'Localização',
        'cabecalho' => ['Computador', 'Colaborador (servidor: último usuário logado)', 'Início', 'Fim', 'Duração', 'Leituras', 'Local', 'Unidade', 'VPN', 'IP de saída'],
        'larguras' => [16, 38, 17, 17, 11, 9, 20, 10, 7, 18],
        'linhas' => $linhas];
}

// Acessos a sites, um por linha (so administradores). Sem URL: titulo e site bastam para saber o que foi.
function abaAcessos(PDO $db, $cfg, $de, $ate)
{
    $tz = fusoDe($cfg);
    $ini = (new DateTimeImmutable($de . ' 00:00:00', $tz))->getTimestamp() * 1000;
    $fim = (new DateTimeImmutable($ate . ' 23:59:59', $tz))->getTimestamp() * 1000;
    $regras = carregarRegras($db);
    $colabs = mapaColaboradores($db);
    $st = $db->prepare('SELECT ts, host, login, dominio, titulo, navegador, duracao_seg FROM navegacao WHERE ts >= ? AND ts <= ? ORDER BY ts LIMIT ' . EXPORT_MAX_LINHAS);
    $st->execute([$ini, $fim]);
    $linhas = [];
    while ($v = $st->fetch()) {
        $i = identidade($v['login'], $colabs);
        $linhas[] = [xDt((int)$v['ts']), $i['colaborador'], $v['host'], $v['navegador'], $v['dominio'],
            rotuloCategoria(classificarDominio($v['dominio'], $regras)[0]), $v['titulo'], xDur((int)$v['duracao_seg'])];
    }
    return ['nome' => 'Acessos',
        'cabecalho' => ['Data/hora', 'Colaborador', 'Computador', 'Navegador', 'Site', 'Tipo de uso', 'Título da página', 'Duração'],
        'larguras' => [17, 38, 16, 11, 34, 12, 70, 10],
        'linhas' => $linhas];
}

// ---------- programas (aplicativos em foco) ----------

function nomeProgramaAmigavel($proc)
{
    static $m = [
        'winword' => 'Word', 'excel' => 'Excel', 'powerpnt' => 'PowerPoint', 'outlook' => 'Outlook', 'olk' => 'Outlook (novo)', 'onenote' => 'OneNote',
        'visio' => 'Visio', 'msaccess' => 'Access', 'mspub' => 'Publisher', 'acrobat' => 'Adobe Acrobat', 'acrord32' => 'Adobe Reader', 'acrord64' => 'Adobe Reader',
        'ms-teams' => 'Teams', 'teams' => 'Teams', 'zoom' => 'Zoom', 'code' => 'VS Code', 'claude' => 'Claude (app)', 'copilotapp' => 'Copilot',
        'chrome' => 'Chrome', 'msedge' => 'Edge', 'firefox' => 'Firefox', 'brave' => 'Brave', 'opera' => 'Opera', 'opera_gx' => 'Opera GX',
        'explorer' => 'Explorador de Arquivos', 'lockapp' => 'Tela de bloqueio', 'notepad' => 'Bloco de Notas', 'calc' => 'Calculadora',
        'whatsapp.root' => 'WhatsApp (app)', 'whatsapp' => 'WhatsApp (app)', 'robloxplayerbeta' => 'Roblox', 'steam' => 'Steam', 'spotify' => 'Spotify',
        'discord' => 'Discord', 'windowsterminal' => 'Terminal', 'powershell' => 'PowerShell', 'cmd' => 'Prompt de Comando', 'taskmgr' => 'Gerenciador de Tarefas',
        'systemsettings' => 'Configuracoes do Windows', 'snippingtool' => 'Ferramenta de Captura', 'mspaint' => 'Paint',
    ];
    $k = strtolower((string)$proc);
    return isset($m[$k]) ? $m[$k] : (string)$proc;
}

function tipoUsoApp($cat)
{
    return $cat === 'navegador' ? 'Navegador (ver sites)' : rotuloCategoria($cat);
}

// Quem usou cada programa no periodo: [processo => [ {login, colaborador, segundos}, ... ]]
function quemUsouPrograma(PDO $db, $de, $ate, array $procs)
{
    $out = [];
    if (!$procs) return $out;
    $colabs = mapaColaboradores($db);
    $marcas = implode(',', array_fill(0, count($procs), '?'));
    $st = $db->prepare('SELECT processo, login, SUM(segundos) AS seg FROM foco_dia WHERE dia >= ? AND dia <= ? AND processo IN (' . $marcas . ')
        GROUP BY processo, login ORDER BY seg DESC');
    $st->execute(array_merge([$de, $ate], array_values($procs)));
    foreach ($st->fetchAll() as $r) {
        $i = identidade($r['login'], $colabs);
        $out[$r['processo']][] = ['login' => $r['login'], 'colaborador' => $i['colaborador'], 'segundos' => (int)$r['seg']];
    }
    return $out;
}

function programasSemRegra(PDO $db, $de, $ate, $limite = 100)
{
    $regras = carregarRegras($db);
    $st = $db->prepare('SELECT processo, SUM(segundos) AS seg, COUNT(DISTINCT login) AS usuarios FROM foco_dia
        WHERE dia >= ? AND dia <= ? GROUP BY processo ORDER BY seg DESC');
    $st->execute([$de, $ate]);
    $out = [];
    foreach ($st->fetchAll() as $r) {
        $c = classificarApp($r['processo'], $regras);
        if ($c[0] === 'navegador' || $c[1] !== null) continue;
        $out[] = ['processo' => $r['processo'], 'nome' => nomeProgramaAmigavel($r['processo']), 'segundos' => (int)$r['seg'], 'usuarios' => (int)$r['usuarios']];
        if (count($out) >= $limite) break;
    }
    $q = quemUsouPrograma($db, $de, $ate, array_column($out, 'processo'));
    foreach ($out as &$o) $o['quem'] = isset($q[$o['processo']]) ? $q[$o['processo']] : [];
    unset($o);
    return $out;
}
