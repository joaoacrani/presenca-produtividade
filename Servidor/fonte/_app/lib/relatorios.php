<?php
// Relatorios: produtividade (acessos), presenca por dia e visao BI.

function periodoDe($get, $cfg, $agora, $padraoDias = 7)
{
    $tz = fusoDe($cfg);
    $hoje = diaLocal($agora, $tz);
    $ate = isset($get['ate']) && dataValida($get['ate']) ? $get['ate'] : $hoje;
    if (isset($get['de']) && dataValida($get['de'])) {
        $de = $get['de'];
    } else {
        $de = (new DateTimeImmutable($ate, $tz))->modify('-' . ($padraoDias - 1) . ' days')->format('Y-m-d');
    }
    if ($de > $ate) { $t = $de; $de = $ate; $ate = $t; }
    $limite = (new DateTimeImmutable($ate, $tz))->modify('-365 days')->format('Y-m-d');
    if ($de < $limite) $de = $limite;
    return [$de, $ate, $hoje];
}

function diasUteis($de, $ate, $cfg)
{
    $tz = fusoDe($cfg);
    $fer = isset($cfg['feriados']) && is_array($cfg['feriados']) ? $cfg['feriados'] : [];
    $out = [];
    $d = new DateTimeImmutable($de, $tz);
    $fim = new DateTimeImmutable($ate, $tz);
    while ($d <= $fim) {
        $dow = (int)$d->format('N');
        $s = $d->format('Y-m-d');
        if ($dow <= 5 && !in_array($s, $fer, true)) $out[] = $s;
        $d = $d->modify('+1 day');
    }
    return $out;
}

// Hosts marcados como servidor (maiusculo): [HOST => true]
function mapaServidores(PDO $db)
{
    $m = [];
    foreach ($db->query('SELECT host FROM servidores') as $r) $m[strtoupper($r['host'])] = true;
    return $m;
}

function mapaColaboradores(PDO $db)
{
    $m = [];
    foreach ($db->query('SELECT login, nome, setor, ativo, cargo, centro_custo, rh, jornada_horas FROM colaboradores') as $c) {
        $m[$c['login']] = ['nome' => (string)$c['nome'], 'setor' => (string)$c['setor'],
            'ativo' => (int)$c['ativo'] === 1, 'cargo' => (string)$c['cargo'], 'centro_custo' => (string)$c['centro_custo'], 'rh' => (int)$c['rh'] === 1, 'jornada_horas' => $c['jornada_horas'] === null ? null : (float)$c['jornada_horas']];
    }
    return $m;
}

function identidade($login, $colabs)
{
    $nome = isset($colabs[$login]) ? $colabs[$login]['nome'] : '';
    return ['login' => $login, 'nome' => $nome, 'colaborador' => nomeExibicao($login, $nome),
        'setor' => isset($colabs[$login]) ? $colabs[$login]['setor'] : ''];
}

function pctProdutivo($prod, $improd)
{
    $d = $prod + $improd;
    return $d > 0 ? round($prod * 100 / $d, 1) : null;
}

// Filtro por colaborador(es) para as consultas: null = todos, texto = um login, lista = varios (lista vazia = ninguem).
function sqlFiltroLogins($loginFiltro, array &$args, $coluna = 'login')
{
    if ($loginFiltro === null) return '';
    if (is_string($loginFiltro)) { $args[] = $loginFiltro; return " AND $coluna = ?"; }
    $logins = [];
    foreach ((array)$loginFiltro as $l) if (is_string($l) && $l !== '' && !in_array($l, $logins, true)) $logins[] = $l;
    $logins = array_slice($logins, 0, 500);
    if (!$logins) return ' AND 1 = 0';
    foreach ($logins as $l) $args[] = $l;
    return " AND $coluna IN (" . implode(',', array_fill(0, count($logins), '?')) . ')';
}

// "?logins=ana,bruno" (ou usuario DOMINIO\ana) -> ['ana','bruno']. Sem o parametro = null (todos). Parametro vazio = [] (ninguem).
function loginsDaConsulta($get)
{
    if (!isset($get['logins'])) return null;
    $out = [];
    foreach (explode(',', (string)$get['logins']) as $x) { $l = loginDe($x); if ($l !== '' && !in_array($l, $out, true)) $out[] = $l; }
    return array_slice($out, 0, 500);
}

// ---------- produtividade ----------

// $incluirProgramas: soma o tempo dos programas em foco (exceto navegadores, que ja valem pelos sites) nas categorias.
function relatorioProdutividade(PDO $db, $cfg, $de, $ate, $loginFiltro = null, $incluirProgramas = true, $comDia = false)
{
    $regras = carregarRegras($db);
    $colabs = mapaColaboradores($db);
    $sql = 'SELECT login, dia, dominio, visitas, segundos FROM nav_dia WHERE dia >= ? AND dia <= ?';
    $args = [$de, $ate];
    $sql .= sqlFiltroLogins($loginFiltro, $args);
    $st = $db->prepare($sql);
    $st->execute($args);

    $zero = ['produtivo' => 0, 'improdutivo' => 0, 'neutro' => 0];
    $porLogin = []; $porDia = []; $doms = []; $cache = []; $segProg = []; $apps = []; $porLoginDia = [];
    while ($r = $st->fetch()) {
        $d = $r['dominio'];
        if (!isset($cache[$d])) $cache[$d] = classificarDominio($d, $regras);
        $cat = $cache[$d][0];
        $seg = (int)$r['segundos']; $vis = (int)$r['visitas'];
        $l = $r['login'];
        if (!isset($porLogin[$l])) $porLogin[$l] = ['seg' => $zero, 'vis' => $zero];
        $porLogin[$l]['seg'][$cat] += $seg; $porLogin[$l]['vis'][$cat] += $vis;
        if (!isset($porDia[$r['dia']])) $porDia[$r['dia']] = $zero;
        $porDia[$r['dia']][$cat] += $seg;
        if ($comDia) { if (!isset($porLoginDia[$l][$r['dia']])) $porLoginDia[$l][$r['dia']] = $zero; $porLoginDia[$l][$r['dia']][$cat] += $seg; }
        if (!isset($doms[$d])) $doms[$d] = ['dominio' => $d, 'categoria' => $cat, 'regra' => $cache[$d][1], 'segundos' => 0, 'visitas' => 0, 'usuarios' => []];
        $doms[$d]['segundos'] += $seg; $doms[$d]['visitas'] += $vis; $doms[$d]['usuarios'][$l] = true;
    }

    if ($incluirProgramas) {
        $sql = 'SELECT login, dia, processo, segundos FROM foco_dia WHERE dia >= ? AND dia <= ?';
        $args = [$de, $ate];
        $sql .= sqlFiltroLogins($loginFiltro, $args);
        $st = $db->prepare($sql);
        $st->execute($args);
        while ($r = $st->fetch()) {
            $c = classificarApp($r['processo'], $regras);
            if ($c[0] === 'navegador') continue;
            $cat = $c[0]; $seg = (int)$r['segundos']; $l = $r['login'];
            if (!isset($porLogin[$l])) $porLogin[$l] = ['seg' => $zero, 'vis' => $zero];
            $porLogin[$l]['seg'][$cat] += $seg;
            if (!isset($segProg[$l])) $segProg[$l] = $zero;
            $segProg[$l][$cat] += $seg;
            if (!isset($porDia[$r['dia']])) $porDia[$r['dia']] = $zero;
            $porDia[$r['dia']][$cat] += $seg;
            if ($comDia) { if (!isset($porLoginDia[$l][$r['dia']])) $porLoginDia[$l][$r['dia']] = $zero; $porLoginDia[$l][$r['dia']][$cat] += $seg; }
            $p = $r['processo'];
            if (!isset($apps[$p])) $apps[$p] = ['processo' => $p, 'categoria' => $cat, 'segundos' => 0, 'usuarios' => []];
            $apps[$p]['segundos'] += $seg; $apps[$p]['usuarios'][$l] = true;
        }
    }

    $colab = [];
    $tot = ['seg' => $zero, 'vis' => $zero];
    foreach ($porLogin as $l => $v) {
        $total = array_sum($v['seg']);
        $linha = identidade($l, $colabs);
        $linha['segundos'] = $v['seg']; $linha['visitas'] = $v['vis']; $linha['total_seg'] = $total;
        $linha['segundos_programas'] = isset($segProg[$l]) ? $segProg[$l] : $zero;
        $linha['pct_produtivo'] = pctProdutivo($v['seg']['produtivo'], $v['seg']['improdutivo']);
        $linha['pct_improdutivo'] = $linha['pct_produtivo'] === null ? null : round(100 - $linha['pct_produtivo'], 1);
        $colab[] = $linha;
        foreach (CATEGORIAS as $c) { $tot['seg'][$c] += $v['seg'][$c]; $tot['vis'][$c] += $v['vis'][$c]; }
    }
    usort($colab, function ($a, $b) { return strcasecmp($a['colaborador'], $b['colaborador']); });

    ksort($porDia);
    $dias = [];
    foreach ($porDia as $dia => $v) $dias[] = ['dia' => $dia] + $v;

    $top = ['produtivo' => [], 'improdutivo' => [], 'neutro' => []];
    $semRegra = [];
    uasort($doms, function ($a, $b) { return $b['segundos'] <=> $a['segundos']; });
    foreach ($doms as $d) {
        $item = ['dominio' => $d['dominio'], 'segundos' => $d['segundos'], 'visitas' => $d['visitas'], 'usuarios' => count($d['usuarios'])];
        if (count($top[$d['categoria']]) < 10) $top[$d['categoria']][] = $item;
        if ($d['regra'] === null && count($semRegra) < 15) $semRegra[] = $item;
    }
    $quem = quemAcessou($db, $de, $ate, array_column($semRegra, 'dominio'), $loginFiltro);
    foreach ($semRegra as &$sr) $sr['quem'] = isset($quem[$sr['dominio']]) ? $quem[$sr['dominio']] : [];
    unset($sr);
    $topProg = ['produtivo' => [], 'improdutivo' => [], 'neutro' => []];
    uasort($apps, function ($a, $b) { return $b['segundos'] <=> $a['segundos']; });
    foreach ($apps as $a) {
        if (count($topProg[$a['categoria']]) < 10) $topProg[$a['categoria']][] = ['processo' => $a['processo'], 'nome' => nomeProgramaAmigavel($a['processo']), 'segundos' => $a['segundos'], 'usuarios' => count($a['usuarios'])];
    }
    $saida = [
        'de' => $de, 'ate' => $ate, 'colaboradores' => $colab, 'dias' => $dias, 'top' => $top, 'top_programas' => $topProg, 'sem_regra' => $semRegra,
        'totais' => ['segundos' => $tot['seg'], 'visitas' => $tot['vis'], 'total_seg' => array_sum($tot['seg']),
            'pct_produtivo' => pctProdutivo($tot['seg']['produtivo'], $tot['seg']['improdutivo'])],
    ];
    if ($comDia) $saida['por_login_dia'] = $porLoginDia;   // so para o comparativo Home x Presencial (nao vai no JSON do BI)
    return $saida;
}

// Dominios ainda sem regra, mais acessados no periodo (para o gestor classificar)
function dominiosSemRegra(PDO $db, $de, $ate, $limite = 100)
{
    $regras = carregarRegras($db);
    $st = $db->prepare('SELECT dominio, SUM(segundos) AS seg, SUM(visitas) AS vis, COUNT(DISTINCT login) AS usuarios
        FROM nav_dia WHERE dia >= ? AND dia <= ? GROUP BY dominio ORDER BY seg DESC, vis DESC');
    $st->execute([$de, $ate]);
    $out = [];
    foreach ($st->fetchAll() as $r) {
        if (classificarDominio($r['dominio'], $regras)[1] !== null) continue;
        $out[] = ['dominio' => $r['dominio'], 'segundos' => (int)$r['seg'], 'visitas' => (int)$r['vis'], 'usuarios' => (int)$r['usuarios']];
        if (count($out) >= $limite) break;
    }
    $quem = quemAcessou($db, $de, $ate, array_column($out, 'dominio'));
    foreach ($out as &$o) $o['quem'] = isset($quem[$o['dominio']]) ? $quem[$o['dominio']] : [];
    unset($o);
    return $out;
}

// Quem acessou cada dominio no periodo (do resumo diario, que dura mais que os acessos brutos):
// [dominio => [ {login, colaborador, segundos, visitas}, ... ]] do que mais acessou para o que menos.
function quemAcessou(PDO $db, $de, $ate, array $dominios, $loginFiltro = null)
{
    $out = [];
    if (!$dominios) return $out;
    $colabs = mapaColaboradores($db);
    $marcas = implode(',', array_fill(0, count($dominios), '?'));
    $args = array_merge([$de, $ate], array_values($dominios));
    $filtro = sqlFiltroLogins($loginFiltro, $args);
    $st = $db->prepare('SELECT dominio, login, SUM(segundos) AS seg, SUM(visitas) AS vis FROM nav_dia
        WHERE dia >= ? AND dia <= ? AND dominio IN (' . $marcas . ')' . $filtro . ' GROUP BY dominio, login ORDER BY seg DESC, vis DESC');
    $st->execute($args);
    foreach ($st->fetchAll() as $r) {
        $i = identidade($r['login'], $colabs);
        $out[$r['dominio']][] = ['login' => $r['login'], 'colaborador' => $i['colaborador'],
            'segundos' => (int)$r['seg'], 'visitas' => (int)$r['vis']];
    }
    return $out;
}

// "Pre-identificacao" de um site: o que os proprios acessos revelam (titulos das paginas, caminhos, quando e quem).
// O servidor nunca visita o site: so le o que os agents ja enviaram (retencao dos acessos brutos: retencao_nav_dias).
function detalheDominio(PDO $db, $cfg, $dominio, $de, $ate)
{
    $tz = fusoDe($cfg);
    $ini = (new DateTimeImmutable($de . ' 00:00:00', $tz))->getTimestamp() * 1000;
    $fim = (new DateTimeImmutable($ate . ' 23:59:59', $tz))->getTimestamp() * 1000;
    $st = $db->prepare('SELECT titulo, COUNT(*) AS n FROM navegacao WHERE dominio = ? AND ts >= ? AND ts <= ?
        AND titulo IS NOT NULL AND titulo <> \'\' GROUP BY titulo ORDER BY n DESC LIMIT 8');
    $st->execute([$dominio, $ini, $fim]);
    $titulos = [];
    foreach ($st->fetchAll() as $r) $titulos[] = ['titulo' => $r['titulo'], 'acessos' => (int)$r['n']];
    $st = $db->prepare('SELECT url, COUNT(*) AS n, SUM(duracao_seg) AS seg FROM navegacao WHERE dominio = ? AND ts >= ? AND ts <= ?
        AND url IS NOT NULL AND url <> \'\' GROUP BY url ORDER BY n DESC, seg DESC LIMIT 8');
    $st->execute([$dominio, $ini, $fim]);
    $caminhos = [];
    foreach ($st->fetchAll() as $r) $caminhos[] = ['url' => $r['url'], 'acessos' => (int)$r['n'], 'segundos' => (int)$r['seg']];
    $st = $db->prepare('SELECT MIN(ts) AS primeiro, MAX(ts) AS ultimo, COUNT(*) AS n, GROUP_CONCAT(DISTINCT navegador) AS nav
        FROM navegacao WHERE dominio = ? AND ts >= ? AND ts <= ?');
    $st->execute([$dominio, $ini, $fim]);
    $r = $st->fetch();
    $q = quemAcessou($db, $de, $ate, [$dominio]);
    $cl = classificarDominio($dominio, carregarRegras($db));
    return [
        'dominio' => $dominio, 'de' => $de, 'ate' => $ate,
        'categoria' => $cl[0], 'tem_regra' => $cl[1] !== null,
        'colaboradores' => isset($q[$dominio]) ? $q[$dominio] : [],
        'titulos' => $titulos, 'caminhos' => $caminhos,
        'primeiro_ts' => $r && $r['primeiro'] !== null ? (int)$r['primeiro'] : null,
        'ultimo_ts' => $r && $r['ultimo'] !== null ? (int)$r['ultimo'] : null,
        'acessos_brutos' => $r ? (int)$r['n'] : 0,
        'navegadores' => $r && $r['nav'] ? explode(',', $r['nav']) : [],
    ];
}

// ---------- presenca por dia ----------

function presencaPorDia(PDO $db, $de, $ate, $loginFiltro = null)
{
    $sql = 'SELECT login, dia, resultado, unidade, n FROM presenca_dia WHERE dia >= ? AND dia <= ?';
    $args = [$de, $ate];
    $sql .= sqlFiltroLogins($loginFiltro, $args);
    $st = $db->prepare($sql);
    $st->execute($args);
    $m = [];
    while ($r = $st->fetch()) {
        $l = $r['login']; $d = $r['dia'];
        if (!isset($m[$l][$d])) $m[$l][$d] = ['pres' => 0, 'rem' => 0, 'semrede' => 0, 'unidades' => []];
        $n = (int)$r['n'];
        if (ehPresencial($r['resultado'])) {
            $m[$l][$d]['pres'] += $n;
            $u = $r['unidade'] !== '' ? $r['unidade'] : '?';
            $m[$l][$d]['unidades'][$u] = (isset($m[$l][$d]['unidades'][$u]) ? $m[$l][$d]['unidades'][$u] : 0) + $n;
        } elseif ($r['resultado'] === 'Sem rede') {
            $m[$l][$d]['semrede'] += $n;
        } else {
            $m[$l][$d]['rem'] += $n;
        }
    }
    return $m;
}

// Regra do dia: "Presencial" se houver pelo menos presenca_min_leituras leituras presenciais e elas forem
// pelo menos presenca_pct_min % das leituras com rede. Senao: com menos de parcial_abaixo_leituras leituras com rede
// no dia = "Parcial" (PC ligado pouco tempo: nao da para afirmar remoto); com mais = "Remoto". Sem leituras = "Sem registro".
function statusDoDia($d, $cfg)
{
    if ($d === null) return 'Sem registro';
    $validos = $d['pres'] + $d['rem'];
    if ($validos === 0) return $d['semrede'] > 0 ? 'Sem rede' : 'Sem registro';
    if ($d['pres'] >= (int)$cfg['presenca_min_leituras'] && $d['pres'] * 100 >= $validos * (float)$cfg['presenca_pct_min']) return 'Presencial';
    if ($validos < (int)$cfg['parcial_abaixo_leituras']) return 'Parcial';
    return 'Remoto';
}

function unidadePrincipal($d)
{
    if (!$d || !$d['unidades']) return '';
    $u = $d['unidades']; arsort($u); $k = array_keys($u);
    return (string)$k[0];
}

// $inicio: primeiro dia com dados do colaborador; dias anteriores (antes do monitoramento) nao entram na conta.
function primeiroDiaPorLogin(PDO $db)
{
    $m = [];
    foreach ($db->query('SELECT login, MIN(dia) AS d FROM presenca_dia GROUP BY login') as $r) $m[$r['login']] = $r['d'];
    return $m;
}

function resumoPresenca($dias, $porDia, $cfg, $hoje, $inicio = '')
{
    $r = ['dias_uteis' => 0, 'presenciais' => 0, 'remotos' => 0, 'parciais' => 0, 'sem_registro' => 0, 'por_unidade' => [], 'detalhe' => []];
    foreach ($dias as $dia) {
        if ($dia > $hoje) continue; // dia que ainda nao aconteceu
        if ($inicio !== '' && $dia < $inicio) continue; // antes de o colaborador ser monitorado
        $d = isset($porDia[$dia]) ? $porDia[$dia] : null;
        $s = statusDoDia($d, $cfg);
        $r['dias_uteis']++;
        $un = '';
        if ($s === 'Presencial') { $r['presenciais']++; $un = unidadePrincipal($d); if ($un !== '') $r['por_unidade'][$un] = (isset($r['por_unidade'][$un]) ? $r['por_unidade'][$un] : 0) + 1; }
        elseif ($s === 'Remoto') $r['remotos']++;
        elseif ($s === 'Parcial') $r['parciais']++;
        else $r['sem_registro']++;
        $r['detalhe'][] = ['dia' => $dia, 'status' => $s, 'unidade' => $un,
            'leituras_presenciais' => $d ? $d['pres'] : 0, 'leituras_total' => $d ? $d['pres'] + $d['rem'] : 0];
    }
    return $r;
}

// ---------- BI ----------

function relatorioBI(PDO $db, $cfg, $de, $ate, $agora, $incluirProgramas = true, $loginsFiltro = null)
{
    $tz = fusoDe($cfg);
    $hoje = diaLocal($agora, $tz);
    $prod = relatorioProdutividade($db, $cfg, $de, $ate, $loginsFiltro, $incluirProgramas);
    $colabs = mapaColaboradores($db);
    $dias = diasUteis($de, $ate, $cfg);
    $porDia = presencaPorDia($db, $de, $ate, $loginsFiltro);
    $inicios = primeiroDiaPorLogin($db);

    $porLogin = [];
    foreach ($prod['colaboradores'] as $c) $porLogin[$c['login']] = $c;
    $logins = array_keys($porLogin);
    foreach (array_keys($porDia) as $l) if (!in_array($l, $logins, true)) $logins[] = $l;

    $linhas = []; $unidades = []; $localDia = [];
    $sumPres = 0; $sumRem = 0; $sumSem = 0; $sumParc = 0;
    foreach ($logins as $l) {
        if (isset($colabs[$l]) && !$colabs[$l]['ativo']) continue;
        $res = resumoPresenca($dias, isset($porDia[$l]) ? $porDia[$l] : [], $cfg, $hoje, isset($inicios[$l]) ? $inicios[$l] : '');
        $p = isset($porLogin[$l]) ? $porLogin[$l] : null;
        $linha = identidade($l, $colabs);
        $linha += [
            'dias_uteis' => $res['dias_uteis'], 'dias_presenciais' => $res['presenciais'], 'dias_remotos' => $res['remotos'],
            'dias_parciais' => $res['parciais'], 'dias_sem_registro' => $res['sem_registro'], 'unidades' => (object)$res['por_unidade'],
            'segundos' => $p ? $p['segundos'] : ['produtivo' => 0, 'improdutivo' => 0, 'neutro' => 0],
            'segundos_programas' => $p && isset($p['segundos_programas']) ? $p['segundos_programas'] : ['produtivo' => 0, 'improdutivo' => 0, 'neutro' => 0],
            'total_seg' => $p ? $p['total_seg'] : 0, 'pct_produtivo' => $p ? $p['pct_produtivo'] : null,
        ];
        // datas de cada situacao (alimenta o detalhe ao clicar nos cartoes do BI)
        $datas = ['presencial' => [], 'remoto' => [], 'parcial' => [], 'sem' => []];
        foreach ($res['detalhe'] as $dd) {
            $k = $dd['status'] === 'Presencial' ? 'presencial' : ($dd['status'] === 'Remoto' ? 'remoto' : ($dd['status'] === 'Parcial' ? 'parcial' : 'sem'));
            $datas[$k][] = $k === 'presencial' ? [$dd['dia'], $dd['unidade']] : $dd['dia'];
        }
        $linha['datas'] = $datas;
        $linhas[] = $linha;
        $sumPres +=$res['presenciais']; $sumRem += $res['remotos']; $sumSem += $res['sem_registro']; $sumParc += $res['parciais'];
        foreach ($res['por_unidade'] as $u => $n) $unidades[$u] = (isset($unidades[$u]) ? $unidades[$u] : 0) + $n;
        foreach ($res['detalhe'] as $d) {
            if (!isset($localDia[$d['dia']])) $localDia[$d['dia']] = ['dia' => $d['dia'], 'presencial' => 0, 'remoto' => 0, 'parcial' => 0];
            if ($d['status'] === 'Presencial') $localDia[$d['dia']]['presencial']++;
            elseif ($d['status'] === 'Remoto') $localDia[$d['dia']]['remoto']++;
            elseif ($d['status'] === 'Parcial') $localDia[$d['dia']]['parcial']++;
        }
    }
    usort($linhas, function ($a, $b) { return strcasecmp($a['colaborador'], $b['colaborador']); });
    ksort($localDia);
    $comDados = $sumPres + $sumRem;
    return [
        'de' => $de, 'ate' => $ate,
        'kpis' => [
            'colaboradores' => count($linhas),
            'pct_produtivo' => $prod['totais']['pct_produtivo'],
            'tempo_total_seg' => $prod['totais']['total_seg'],
            'dias_presenciais' => $sumPres, 'dias_remotos' => $sumRem, 'dias_parciais' => $sumParc, 'dias_sem_registro' => $sumSem,
            'pct_presencial' => $comDados > 0 ? round($sumPres * 100 / $comDados, 1) : null,
        ],
        'colaboradores' => $linhas, 'dias_produtividade' => $prod['dias'], 'dias_local' => array_values($localDia),
        'unidades' => (object)$unidades, 'top' => $prod['top'], 'top_programas' => $prod['top_programas'], 'sem_regra' => $prod['sem_regra'],
        'totais' => $prod['totais'],
    ];
}

function detalheColaborador(PDO $db, $cfg, $login, $de, $ate, $agora)
{
    $hoje = diaLocal($agora, fusoDe($cfg));
    $colabs = mapaColaboradores($db);
    $prod = relatorioProdutividade($db, $cfg, $de, $ate, $login);
    $res = resumoPresenca(diasUteis($de, $ate, $cfg), (presencaPorDia($db, $de, $ate, $login)[$login] ?? []), $cfg, $hoje, (primeiroDiaPorLogin($db)[$login] ?? ''));
    $regras = carregarRegras($db);
    $tz = fusoDe($cfg);
    $ini = (new DateTimeImmutable($de . ' 00:00:00', $tz))->getTimestamp() * 1000;
    $fim = (new DateTimeImmutable($ate . ' 23:59:59', $tz))->getTimestamp() * 1000;
    $st = $db->prepare('SELECT ts, host, dominio, url, titulo, navegador, duracao_seg FROM navegacao
        WHERE login = ? AND ts >= ? AND ts <= ? ORDER BY ts DESC LIMIT 300');
    $st->execute([$login, $ini, $fim]);
    $visitas = [];
    foreach ($st->fetchAll() as $v) {
        $v['ts'] = (int)$v['ts']; $v['duracao_seg'] = (int)$v['duracao_seg'];
        $v['categoria'] = classificarDominio($v['dominio'], $regras)[0];
        $visitas[] = $v;
    }
    return ['colaborador' => identidade($login, $colabs), 'de' => $de, 'ate' => $ate,
        'produtividade' => $prod, 'presenca' => $res, 'visitas' => $visitas];
}

// ---------- CSV (Excel pt-BR: separador ";", UTF-8 com BOM) ----------

function celulaCsv($v)
{
    if ($v === null) return '';
    if (is_float($v)) $v = str_replace('.', ',', (string)$v);
    $s = (string)$v;
    if ($s !== '' && strpos("=+-@\t\r", $s[0]) !== false && !preg_match('/^-?\d+([.,]\d+)?$/', $s)) $s = "'" . $s; // evita formula
    if (preg_match('/[";\r\n]/', $s)) $s = '"' . str_replace('"', '""', $s) . '"';
    return $s;
}

function enviarCsv($nomeArquivo, array $cabecalho, array $linhas)
{
    http_response_code(200);
    cabecalhosBase();
    header('Content-Type: text/csv; charset=utf-8');
    header('Content-Disposition: attachment; filename="' . preg_replace('/[^A-Za-z0-9._-]/', '_', $nomeArquivo) . '"');
    echo "\xEF\xBB\xBF";
    echo implode(';', array_map('celulaCsv', $cabecalho)) . "\r\n";
    foreach ($linhas as $l) echo implode(';', array_map('celulaCsv', $l)) . "\r\n";
    exit;
}

function horasMin($seg)
{
    return round($seg / 60, 1); // minutos
}
