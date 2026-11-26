<?php
// API v1 (somente leitura) para o analista de dados extrair o que o painel mostra, sem ficar baixando planilhas.
// Autenticacao por token proprio (criado na Administracao), separado do token dos agents e da sessao do painel.
// Documentacao: README (secao "API para o analista de dados") e GET /api/v1/openapi.json.

const API_VERSAO = 1;
const API_MAX_DIAS_LISTA = 62;     // /dias devolve uma linha por colaborador e dia: pede-se de mes em mes
const API_MAX_DIAS_RESUMO = 400;   // resumos agregam em blocos, podem cobrir o historico todo
const API_PAGINA_PADRAO = 1000;
const API_PAGINA_MAX = 5000;
const API_NOMES_DIA = ['', 'segunda', 'terca', 'quarta', 'quinta', 'sexta', 'sabado', 'domingo'];

// ---------- tokens ----------

function apiTokenHash($token) { return hash('sha256', (string)$token); }

// Cria o token. O valor em texto so existe aqui (no banco fica so o hash): quem criou precisa copiar na hora.
function criarApiToken(PDO $db, $agora, $nome, $diasValidade, $anonimizar, $por)
{
    $nome = trim(cortar((string)$nome, 60));
    if ($nome === '') return ['erro' => 'nome obrigatorio'];
    $dias = (int)$diasValidade;
    if ($dias < 0 || $dias > 3650) return ['erro' => 'validade invalida (0 a 3650 dias, 0 = sem validade)'];
    $token = 'ppa_' . bin2hex(random_bytes(20));
    $expira = $dias > 0 ? $agora + $dias * 86400000 : null;
    $db->prepare('INSERT INTO api_tokens (nome, hash, prefixo, criado_em, criado_por, expira_em, anonimizar) VALUES (?,?,?,?,?,?,?)')
       ->execute([$nome, apiTokenHash($token), substr($token, 0, 8), $agora, cortar((string)$por, 60), $expira, $anonimizar ? 1 : 0]);
    return ['id' => (int)$db->lastInsertId(), 'nome' => $nome, 'token' => $token, 'prefixo' => substr($token, 0, 8), 'expira_em' => $expira, 'anonimizar' => (bool)$anonimizar];
}

function listarApiTokens(PDO $db, $agora)
{
    $out = [];
    foreach ($db->query('SELECT id, nome, prefixo, criado_em, criado_por, expira_em, ultimo_uso, revogado_em, anonimizar, usos FROM api_tokens ORDER BY id DESC') as $r) {
        $estado = $r['revogado_em'] !== null ? 'revogado' : (($r['expira_em'] !== null && (int)$r['expira_em'] <= $agora) ? 'expirado' : 'ativo');
        $out[] = ['id' => (int)$r['id'], 'nome' => $r['nome'], 'prefixo' => $r['prefixo'], 'criado_em' => (int)$r['criado_em'], 'criado_por' => $r['criado_por'],
            'expira_em' => $r['expira_em'] === null ? null : (int)$r['expira_em'], 'ultimo_uso' => $r['ultimo_uso'] === null ? null : (int)$r['ultimo_uso'],
            'anonimizar' => (int)$r['anonimizar'] === 1, 'usos' => (int)$r['usos'], 'estado' => $estado];
    }
    return $out;
}

function revogarApiToken(PDO $db, $id, $agora)
{
    $st = $db->prepare('UPDATE api_tokens SET revogado_em = ? WHERE id = ? AND revogado_em IS NULL');
    $st->execute([$agora, (int)$id]);
    return $st->rowCount() > 0;
}

// Token enviado em "Authorization: Bearer ...": devolve a linha do token (e registra o uso) ou null.
function apiTokenAtual(PDO $db, $agora)
{
    $h = cabecalhoAuth();
    if (strncmp($h, 'Bearer ', 7) !== 0) return null;
    $t = substr($h, 7);
    if (strncmp($t, 'ppa_', 4) !== 0 || strlen($t) > 100) return null;
    $st = $db->prepare('SELECT * FROM api_tokens WHERE hash = ? AND revogado_em IS NULL AND (expira_em IS NULL OR expira_em > ?)');
    $st->execute([apiTokenHash($t), $agora]);
    $r = $st->fetch();
    if (!$r) return null;
    $db->prepare('UPDATE api_tokens SET ultimo_uso = ?, usos = usos + 1 WHERE id = ?')->execute([$agora, $r['id']]);
    return $r;
}

// ---------- pseudonimos ----------

function apiChavePseudonimo($cfg)
{
    static $k = null;
    if ($k !== null) return $k;
    $f = $cfg['dados_dir'] . '/pseudonimo.key';
    if (!is_file($f)) { file_put_contents($f, bin2hex(random_bytes(32))); @chmod($f, 0600); }
    $k = trim((string)file_get_contents($f));
    return $k;
}
// Mesmo login = mesmo codigo sempre (da para acompanhar uma pessoa ao longo dos meses), mas nao da para voltar ao login sem a chave.
function apiPseudonimo($cfg, $login) { return 'p' . substr(hash_hmac('sha256', (string)$login, apiChavePseudonimo($cfg)), 0, 12); }

// ---------- parametros ----------

function apiErro($status, $msg) { responderJson($status, ['erro' => $msg]); }

function apiPeriodo($get, $cfg, $agora, $maxDias, $padraoDias = 30)
{
    $hoje = diaLocal($agora, fusoDe($cfg));
    $ate = $hoje;
    if (isset($get['ate'])) { if (!dataValida($get['ate'])) apiErro(400, 'data final invalida (use AAAA-MM-DD)'); $ate = $get['ate']; }
    if ($ate > $hoje) $ate = $hoje;
    if (isset($get['de'])) { if (!dataValida($get['de'])) apiErro(400, 'data inicial invalida (use AAAA-MM-DD)'); $de = $get['de']; }
    else $de = (new DateTimeImmutable($ate, fusoDe($cfg)))->modify('-' . ($padraoDias - 1) . ' days')->format('Y-m-d');
    if ($de > $ate) apiErro(400, 'a data inicial e depois da final');
    $dias = (int)((strtotime($ate) - strtotime($de)) / 86400) + 1;
    if ($dias > $maxDias) apiErro(400, "periodo de $dias dias: o maximo para esta rota e $maxDias (peca em partes)");
    return [$de, $ate, $hoje];
}

// ?logins=a,b filtra. Com token pseudonimizado vale o codigo (pNNNN), nao o login real.
function apiLoginsFiltro(PDO $db, $cfg, $get, $tok)
{
    if (!isset($get['logins'])) return null;
    $pedidos = [];
    foreach (explode(',', (string)$get['logins']) as $x) { $x = loginDe($x); if ($x !== '') $pedidos[$x] = true; }
    if ((int)$tok['anonimizar'] !== 1) return array_slice(array_keys($pedidos), 0, 500);
    $out = [];
    foreach (array_keys(mapaColaboradores($db)) as $login) if (isset($pedidos[apiPseudonimo($cfg, $login)])) $out[] = $login;
    return array_slice($out, 0, 500);
}

function apiPagina($get)
{
    $pag = isset($get['pagina']) && ctype_digit((string)$get['pagina']) ? max(1, (int)$get['pagina']) : 1;
    $lim = isset($get['limite']) && ctype_digit((string)$get['limite']) ? max(1, min(API_PAGINA_MAX, (int)$get['limite'])) : API_PAGINA_PADRAO;
    return [$pag, $lim];
}

// ---------- dados por colaborador e dia ----------

// Segundos por categoria (sites + programas, mesma regra do BI), tempo ativo (qualquer janela em foco) e tempo de navegacao.
function apiProdutividadeDia(PDO $db, $de, $ate, $logins)
{
    $regras = carregarRegras($db);
    $zero = ['produtivo' => 0, 'improdutivo' => 0, 'neutro' => 0];
    $cat = []; $ativo = []; $navTot = []; $cache = [];
    $args = [$de, $ate];
    $f = sqlFiltroLogins($logins, $args);
    $st = $db->prepare('SELECT login, dia, dominio, segundos FROM nav_dia WHERE dia >= ? AND dia <= ?' . $f);
    $st->execute($args);
    while ($r = $st->fetch()) {
        $d = $r['dominio'];
        if (!isset($cache[$d])) $cache[$d] = classificarDominio($d, $regras)[0];
        $l = $r['login']; $dia = $r['dia']; $seg = (int)$r['segundos'];
        if (!isset($cat[$l][$dia])) $cat[$l][$dia] = $zero;
        $cat[$l][$dia][$cache[$d]] += $seg;
        $navTot[$l][$dia] = (isset($navTot[$l][$dia]) ? $navTot[$l][$dia] : 0) + $seg;
    }
    $args = [$de, $ate];
    $f = sqlFiltroLogins($logins, $args);
    $st = $db->prepare('SELECT login, dia, processo, segundos FROM foco_dia WHERE dia >= ? AND dia <= ?' . $f);
    $st->execute($args);
    while ($r = $st->fetch()) {
        $l = $r['login']; $dia = $r['dia']; $seg = (int)$r['segundos'];
        $ativo[$l][$dia] = (isset($ativo[$l][$dia]) ? $ativo[$l][$dia] : 0) + $seg;
        $c = classificarApp($r['processo'], $regras)[0];
        if ($c === 'navegador') continue;      // navegador ja vale pelos sites
        if (!isset($cat[$l][$dia])) $cat[$l][$dia] = $zero;
        $cat[$l][$dia][$c] += $seg;
    }
    return [$cat, $ativo, $navTot];
}

// Score (metrica validada): (produtivo x 1,0 + neutro x 0,5) / tempo total x 100, com o tempo total = produtivo + neutro + improdutivo.
function apiScore($prod, $neutro, $improd)
{
    $t = $prod + $neutro + $improd;
    return $t > 0 ? round(($prod + 0.5 * $neutro) * 100 / $t, 1) : null;
}

function apiHoraLocal($ms, DateTimeZone $tz) { return (new DateTime('@' . intdiv((int)$ms, 1000)))->setTimezone($tz)->format('H:i'); }
function apiMinutosDe($hhmm) { return (int)substr($hhmm, 0, 2) * 60 + (int)substr($hhmm, 3, 2); }

// Linhas de um bloco de dias: uma por colaborador e dia (a uniao de presenca, sites e programas).
function apiLinhasBloco(PDO $db, $cfg, $a, $b, $logins, $hoje, $colabs)
{
    list($cat, $ativo, $navTot) = apiProdutividadeDia($db, $a, $b, $logins);
    $pres = presencaPorDia($db, $a, $b, $logins);
    $tz = fusoDe($cfg);
    $clique = [];
    $args = [$a, $b];
    $f = sqlFiltroLogins($logins, $args);
    $st = $db->prepare('SELECT login, dia, primeiro, ultimo FROM atividade_dia WHERE dia >= ? AND dia <= ?' . $f);
    $st->execute($args);
    while ($r = $st->fetch()) $clique[$r['login']][$r['dia']] = [(int)$r['primeiro'], (int)$r['ultimo']];
    $jornadaPadrao = isset($cfg['jornada_horas']) && (float)$cfg['jornada_horas'] > 0 ? (float)$cfg['jornada_horas'] : 8.0;
    $chaves = [];
    foreach ([$cat, $ativo, $pres] as $mapa) foreach ($mapa as $l => $dias) foreach ($dias as $dia => $_) $chaves[$dia][$l] = true;
    ksort($chaves);
    $zero = ['produtivo' => 0, 'improdutivo' => 0, 'neutro' => 0];
    $linhas = [];
    foreach ($chaves as $dia => $porLogin) {
        if ($dia > $hoje) continue;
        $dow = (int)(new DateTimeImmutable($dia))->format('N');
        $ls = array_keys($porLogin); sort($ls);
        foreach ($ls as $l) {
            if (isset($colabs[$l]) && !$colabs[$l]['ativo']) continue;
            $p = isset($pres[$l][$dia]) ? $pres[$l][$dia] : null;
            $u = isset($cat[$l][$dia]) ? $cat[$l][$dia] : $zero;
            $modo = modoDoDia($p, $cfg);
            if ($modo === null) {
                $validos = $p ? $p['pres'] + $p['rem'] : 0;
                $modo = $validos > 0 ? 'parcial' : (($p && $p['semrede'] > 0) ? 'sem_rede' : 'sem_leitura');
            }
            $tempoAtivo = isset($ativo[$l][$dia]) ? (int)$ativo[$l][$dia] : 0;
            $cl = isset($clique[$l][$dia]) ? $clique[$l][$dia] : null;
            // ocioso = tempo entre o primeiro e o ultimo clique sem atividade (inclui o almoco); so quando ha cliques e uso no dia
            $ocioso = ($cl && $tempoAtivo > 0) ? max(0, (int)round(($cl[1] - $cl[0]) / 1000) - $tempoAtivo) : null;
            $jor = isset($colabs[$l]) && $colabs[$l]['jornada_horas'] !== null ? (float)$colabs[$l]['jornada_horas'] : $jornadaPadrao;
            $linhas[] = [
                'login' => $l, 'nome' => isset($colabs[$l]) ? (string)$colabs[$l]['nome'] : '', 'dia' => $dia, 'dia_semana' => $dow, 'modalidade' => $modo,
                'leituras_presencial' => $p ? (int)$p['pres'] : 0, 'leituras_remoto' => $p ? (int)$p['rem'] : 0, 'leituras_sem_rede' => $p ? (int)$p['semrede'] : 0,
                'unidade' => $p ? unidadePrincipal($p) : '',
                'tempo_ativo_seg' => $tempoAtivo, 'navegacao_seg' => isset($navTot[$l][$dia]) ? (int)$navTot[$l][$dia] : 0,
                'produtivo_seg' => $u['produtivo'], 'improdutivo_seg' => $u['improdutivo'], 'neutro_seg' => $u['neutro'],
                'pct_produtivo' => pctProdutivo($u['produtivo'], $u['improdutivo']),
                'score' => apiScore($u['produtivo'], $u['neutro'], $u['improdutivo']),
                'primeiro_click' => $cl ? apiHoraLocal($cl[0], $tz) : null, 'ultimo_click' => $cl ? apiHoraLocal($cl[1], $tz) : null,
                'ocioso_seg' => $ocioso, 'jornada_horas' => $jor,
            ];
        }
    }
    return $linhas;
}

// Percorre o periodo em blocos de ~1 mes (memoria baixa mesmo para 400 dias x 430 colaboradores) e chama $fn($linha).
function apiPercorrerDias(PDO $db, $cfg, $de, $ate, $logins, $hoje, callable $fn)
{
    @set_time_limit(180);
    $tz = fusoDe($cfg);
    $colabs = mapaColaboradores($db);
    $fim = new DateTimeImmutable($ate, $tz);
    for ($c = new DateTimeImmutable($de, $tz); $c <= $fim; $c = $c->modify('+32 days')) {
        $b = $c->modify('+31 days');
        if ($b > $fim) $b = $fim;
        foreach (apiLinhasBloco($db, $cfg, $c->format('Y-m-d'), $b->format('Y-m-d'), $logins, $hoje, $colabs) as $linha) $fn($linha);
    }
}

// Troca login/nome pelo codigo quando o token e pseudonimizado.
function apiApresentar($cfg, $tok, array $linha)
{
    if ((int)$tok['anonimizar'] !== 1) return $linha;
    $linha['login'] = apiPseudonimo($cfg, $linha['login']);
    if (array_key_exists('nome', $linha)) $linha['nome'] = null;
    return $linha;
}

// ---------- agregacao ----------

function apiAcum()
{
    return ['dias' => 0, 'dias_uso' => 0, 'ativo' => 0, 'produtivo' => 0, 'improdutivo' => 0, 'neutro' => 0, 'jornada' => 0.0,
        'ocioso' => 0, 'ocioso_n' => 0, 'pmin' => 0, 'umin' => 0, 'click_n' => 0, 'logins' => []];
}
function apiAcumular(array &$a, array $r)
{
    $a['dias']++;
    if ($r['tempo_ativo_seg'] > 0) { $a['dias_uso']++; $a['ativo'] += $r['tempo_ativo_seg']; $a['jornada'] += (float)$r['jornada_horas'] * 3600; }
    $a['produtivo'] += $r['produtivo_seg']; $a['improdutivo'] += $r['improdutivo_seg']; $a['neutro'] += $r['neutro_seg'];
    if ($r['ocioso_seg'] !== null) { $a['ocioso'] += $r['ocioso_seg']; $a['ocioso_n']++; }
    if ($r['primeiro_click'] !== null) { $a['pmin'] += apiMinutosDe($r['primeiro_click']); $a['umin'] += apiMinutosDe($r['ultimo_click']); $a['click_n']++; }
    $a['logins'][$r['login']] = true;
}
function apiMinHHMM($min) { return sprintf('%02d:%02d', intdiv((int)round($min), 60), ((int)round($min)) % 60); }
function apiAcumFinal(array $a)
{
    $total = $a['produtivo'] + $a['improdutivo'] + $a['neutro'];
    $pc = function ($v) use ($total) { return $total > 0 ? round($v * 100 / $total, 1) : null; };
    return [
        'colaboradores' => count($a['logins']), 'dias_registro' => $a['dias'], 'dias_com_uso' => $a['dias_uso'],
        'tempo_ativo_seg' => $a['ativo'], 'tempo_ativo_medio_dia_seg' => $a['dias_uso'] > 0 ? (int)round($a['ativo'] / $a['dias_uso']) : null,
        'produtivo_seg' => $a['produtivo'], 'improdutivo_seg' => $a['improdutivo'], 'neutro_seg' => $a['neutro'],
        'pct_produtivo' => pctProdutivo($a['produtivo'], $a['improdutivo']),
        // metricas validadas: participacao de cada categoria no tempo total classificado, score e disponibilidade
        'pct_tempo_produtivo' => $pc($a['produtivo']), 'pct_tempo_neutro' => $pc($a['neutro']), 'pct_tempo_improdutivo' => $pc($a['improdutivo']),
        'score' => apiScore($a['produtivo'], $a['neutro'], $a['improdutivo']),
        'disponibilidade_pct' => $a['jornada'] > 0 ? round($a['ativo'] * 100 / $a['jornada'], 1) : null,
        'ocioso_medio_dia_seg' => $a['ocioso_n'] > 0 ? (int)round($a['ocioso'] / $a['ocioso_n']) : null,
        'primeiro_click_medio' => $a['click_n'] > 0 ? apiMinHHMM($a['pmin'] / $a['click_n']) : null,
        'ultimo_click_medio' => $a['click_n'] > 0 ? apiMinHHMM($a['umin'] / $a['click_n']) : null,
    ];
}

function apiGrupoChave($agrupar, array $r)
{
    switch ($agrupar) {
        case 'dia': return $r['dia'];
        case 'dia_semana': return (string)$r['dia_semana'];
        case 'mes': return substr($r['dia'], 0, 7);
        case 'modalidade': return $r['modalidade'];
        default: return $r['login'];
    }
}

// Uma passada no periodo (so dias uteis, como no relatorio mensal): geral, por modalidade, dia da semana, dia e colaborador.
function apiAgregarPeriodo(PDO $db, $cfg, $de, $ate, $logins, $hoje, $soUteis = true)
{
    $uteis = $soUteis ? array_flip(diasUteis($de, $ate, $cfg)) : null;
    $geral = apiAcum();
    $grp = ['modalidade' => [], 'dia_semana' => [], 'dia' => [], 'colaborador' => []];
    apiPercorrerDias($db, $cfg, $de, $ate, $logins, $hoje, function ($r) use (&$geral, &$grp, $uteis) {
        if ($uteis !== null && !isset($uteis[$r['dia']])) return;
        apiAcumular($geral, $r);
        $chaves = ['modalidade' => $r['modalidade'], 'dia_semana' => (string)$r['dia_semana'], 'dia' => $r['dia'], 'colaborador' => $r['login']];
        foreach ($chaves as $nome => $k) {
            if (!isset($grp[$nome][$k])) $grp[$nome][$k] = apiAcum();
            apiAcumular($grp[$nome][$k], $r);
        }
    });
    return ['geral' => $geral, 'modalidade' => $grp['modalidade'], 'dia_semana' => $grp['dia_semana'], 'dia' => $grp['dia'], 'colaborador' => $grp['colaborador'],
        'dias_uteis' => $uteis === null ? null : count($uteis)];
}

// ---------- rotas ----------

function apiSaida($dados) { responderJson(200, ['versao_api' => API_VERSAO] + $dados); }

// CSV para maquina (pandas, Power BI): virgula, ponto decimal, UTF-8 sem BOM, true/false. (O CSV do painel e o do Excel brasileiro: ponto e virgula e virgula decimal.)
function apiCelulaCsv($v)
{
    if ($v === null) return '';
    if (is_bool($v)) return $v ? 'true' : 'false';
    $s = (string)$v;
    if ($s !== '' && strpos("=+-@\t\r", $s[0]) !== false && !preg_match('/^-?\d+(\.\d+)?$/', $s)) $s = "'" . $s;   // evita formula se abrirem no Excel
    if (preg_match('/[",\r\n]/', $s)) $s = '"' . str_replace('"', '""', $s) . '"';
    return $s;
}

function apiCsv($nome, array $cabecalho, array $linhas)
{
    http_response_code(200);
    cabecalhosBase();
    header('Content-Type: text/csv; charset=utf-8');
    header('Content-Disposition: attachment; filename="' . preg_replace('/[^A-Za-z0-9._-]/', '_', $nome) . '"');
    echo implode(',', $cabecalho) . "\r\n";
    foreach ($linhas as $l) echo implode(',', array_map(function ($c) use ($l) { return apiCelulaCsv($l[$c]); }, $cabecalho)) . "\r\n";
    exit;
}

function apiRotaColaboradores(PDO $db, $cfg, $tok, $get)
{
    list($pag, $lim) = apiPagina($get);
    $primeiro = []; $ultimo = [];
    foreach ($db->query('SELECT login, MIN(dia) AS a, MAX(dia) AS b FROM presenca_dia GROUP BY login') as $r) { $primeiro[$r['login']] = $r['a']; $ultimo[$r['login']] = $r['b']; }
    $linhas = [];
    foreach (mapaColaboradores($db) as $login => $c) {
        $linhas[] = ['login' => $login, 'nome' => $c['nome'], 'setor' => $c['setor'], 'ativo' => (bool)$c['ativo'],
            'primeiro_dia' => isset($primeiro[$login]) ? $primeiro[$login] : null, 'ultimo_dia' => isset($ultimo[$login]) ? $ultimo[$login] : null,
            // vem do cadastro do RH (Administracao): null enquanto nao preenchido
            'cargo' => $c['cargo'] !== '' ? $c['cargo'] : null, 'centro_custo' => $c['centro_custo'] !== '' ? $c['centro_custo'] : null, 'vinculo_rh' => (bool)$c['rh']];
    }
    usort($linhas, function ($a, $b) { return strcmp($a['login'], $b['login']); });
    $total = count($linhas);
    $itens = array_map(function ($l) use ($cfg, $tok) { return apiApresentar($cfg, $tok, $l); }, array_slice($linhas, ($pag - 1) * $lim, $lim));
    if (isset($get['formato']) && $get['formato'] === 'csv') apiCsv('colaboradores.csv', array_keys($itens ? $itens[0] : ['login' => 0]), $itens);
    apiSaida(['total' => $total, 'pagina' => $pag, 'limite' => $lim, 'paginas' => (int)max(1, ceil($total / $lim)), 'itens' => $itens]);
}

function apiRotaDias(PDO $db, $cfg, $tok, $get, $agora)
{
    list($de, $ate, $hoje) = apiPeriodo($get, $cfg, $agora, API_MAX_DIAS_LISTA);
    list($pag, $lim) = apiPagina($get);
    $logins = apiLoginsFiltro($db, $cfg, $get, $tok);
    $uteis = (isset($get['dias']) && $get['dias'] === 'uteis') ? array_flip(diasUteis($de, $ate, $cfg)) : null;
    $linhas = [];
    apiPercorrerDias($db, $cfg, $de, $ate, $logins, $hoje, function ($r) use (&$linhas, $uteis) { if ($uteis === null || isset($uteis[$r['dia']])) $linhas[] = $r; });
    $total = count($linhas);
    $itens = array_map(function ($l) use ($cfg, $tok) { return apiApresentar($cfg, $tok, $l); }, array_slice($linhas, ($pag - 1) * $lim, $lim));
    if (isset($get['formato']) && $get['formato'] === 'csv') {
        $cab = ['login', 'nome', 'dia', 'dia_semana', 'modalidade', 'leituras_presencial', 'leituras_remoto', 'leituras_sem_rede', 'unidade', 'tempo_ativo_seg', 'navegacao_seg', 'produtivo_seg', 'improdutivo_seg', 'neutro_seg', 'pct_produtivo', 'score', 'primeiro_click', 'ultimo_click', 'ocioso_seg', 'jornada_horas'];
        apiCsv("dias_{$de}_a_{$ate}.csv", $cab, $itens);
    }
    apiSaida(['de' => $de, 'ate' => $ate, 'total' => $total, 'pagina' => $pag, 'limite' => $lim, 'paginas' => (int)max(1, ceil($total / $lim)), 'itens' => $itens]);
}

function apiRotaResumo(PDO $db, $cfg, $tok, $get, $agora)
{
    list($de, $ate, $hoje) = apiPeriodo($get, $cfg, $agora, API_MAX_DIAS_RESUMO);
    $agr = isset($get['agrupar']) ? (string)$get['agrupar'] : 'dia';
    if (!in_array($agr, ['dia', 'dia_semana', 'mes', 'modalidade', 'colaborador'], true)) apiErro(400, 'agrupar deve ser dia, dia_semana, mes, modalidade ou colaborador');
    $dias = isset($get['dias']) ? (string)$get['dias'] : 'uteis';
    if (!in_array($dias, ['uteis', 'todos'], true)) apiErro(400, 'dias deve ser uteis ou todos');
    $logins = apiLoginsFiltro($db, $cfg, $get, $tok);
    $uteis = $dias === 'uteis' ? array_flip(diasUteis($de, $ate, $cfg)) : null;
    $geral = apiAcum(); $grupos = [];
    apiPercorrerDias($db, $cfg, $de, $ate, $logins, $hoje, function ($r) use (&$geral, &$grupos, $agr, $uteis) {
        if ($uteis !== null && !isset($uteis[$r['dia']])) return;
        apiAcumular($geral, $r);
        $k = apiGrupoChave($agr, $r);
        if (!isset($grupos[$k])) $grupos[$k] = apiAcum();
        apiAcumular($grupos[$k], $r);
    });
    ksort($grupos);
    $itens = [];
    foreach ($grupos as $k => $a) {
        $chave = $agr === 'colaborador' ? apiApresentar($cfg, $tok, ['login' => $k])['login'] : $k;
        $linha = ['grupo' => $chave] + apiAcumFinal($a);
        if ($agr === 'dia_semana') $linha['nome'] = API_NOMES_DIA[(int)$k];
        $itens[] = $linha;
    }
    if ($agr === 'colaborador') usort($itens, function ($x, $y) { return strcmp($x['grupo'], $y['grupo']); });
    apiSaida(['de' => $de, 'ate' => $ate, 'agrupar' => $agr, 'dias' => $dias, 'dias_uteis_no_periodo' => $uteis === null ? null : count($uteis), 'geral' => apiAcumFinal($geral), 'itens' => $itens]);
}

// Mesmo relatorio da aba "Relatorio" (todas as secoes). Com token pseudonimizado, as pessoas viram codigos e perdem o nome.
function apiAnonimizarRelatorio($cfg, array $rel)
{
    $troca = function (array $itens) use ($cfg) {
        return array_map(function ($p) use ($cfg) { $p['login'] = apiPseudonimo($cfg, $p['login']); $p['nome'] = null; return $p; }, $itens);
    };
    foreach (['critico', 'atencao', 'acompanhamento'] as $k) if (isset($rel['alertas'][$k])) $rel['alertas'][$k] = $troca($rel['alertas'][$k]);
    if (isset($rel['alertas']['poucos_dias']['itens'])) $rel['alertas']['poucos_dias']['itens'] = $troca($rel['alertas']['poucos_dias']['itens']);
    if (!empty($rel['alertas']['sem_rh']['itens'])) $rel['alertas']['sem_rh']['itens'] = $troca($rel['alertas']['sem_rh']['itens']);
    if (isset($rel['top10'])) $rel['top10'] = $troca($rel['top10']);
    return $rel;
}

function apiRotaMensal(PDO $db, $cfg, $tok, $get, $agora)
{
    $mes = isset($get['mes']) ? (string)$get['mes'] : '';
    if (!preg_match('/^(\d{4})-(0[1-9]|1[0-2])$/', $mes)) apiErro(400, 'mes obrigatorio no formato AAAA-MM');
    if ($mes . '-01' > diaLocal($agora, fusoDe($cfg))) apiErro(400, 'mes no futuro');
    $rel = montarRelatorio($db, $cfg, 'mensal', $mes, null, null, $agora);
    apiSaida((int)$tok['anonimizar'] === 1 ? apiAnonimizarRelatorio($cfg, $rel) : $rel);
}

function apiOpenApi()
{
    $per = [
        ['name' => 'de', 'in' => 'query', 'schema' => ['type' => 'string', 'format' => 'date'], 'description' => 'Data inicial (AAAA-MM-DD). Padrao: 30 dias antes de "ate".'],
        ['name' => 'ate', 'in' => 'query', 'schema' => ['type' => 'string', 'format' => 'date'], 'description' => 'Data final (AAAA-MM-DD). Padrao: hoje.'],
        ['name' => 'logins', 'in' => 'query', 'schema' => ['type' => 'string'], 'description' => 'Lista separada por virgula. Com token pseudonimizado, use os codigos (pNNNN).'],
    ];
    $pag = [
        ['name' => 'pagina', 'in' => 'query', 'schema' => ['type' => 'integer', 'minimum' => 1]],
        ['name' => 'limite', 'in' => 'query', 'schema' => ['type' => 'integer', 'minimum' => 1, 'maximum' => API_PAGINA_MAX, 'default' => API_PAGINA_PADRAO]],
        ['name' => 'formato', 'in' => 'query', 'schema' => ['type' => 'string', 'enum' => ['json', 'csv']]],
    ];
    $ok = ['200' => ['description' => 'Sucesso'], '400' => ['description' => 'Parametro invalido'], '401' => ['description' => 'Token ausente, invalido, expirado ou revogado']];
    return [
        'openapi' => '3.0.3',
        'info' => ['title' => 'Presenca e Produtividade - API de dados', 'version' => (string)API_VERSAO, 'description' => 'Somente leitura. Tempos em segundos. Score = (produtivo x 1 + neutro x 0,5) / tempo total x 100. Dias uteis excluem fins de semana e os feriados do config.php.'],
        'security' => [['bearer' => []]],
        'components' => ['securitySchemes' => ['bearer' => ['type' => 'http', 'scheme' => 'bearer']]],
        'paths' => [
            '/api/v1/saude' => ['get' => ['summary' => 'Teste do token', 'responses' => $ok]],
            '/api/v1/colaboradores' => ['get' => ['summary' => 'Cadastro de colaboradores', 'parameters' => $pag, 'responses' => $ok]],
            '/api/v1/dias' => ['get' => ['summary' => 'Uma linha por colaborador e dia (maximo ' . API_MAX_DIAS_LISTA . ' dias por chamada)', 'parameters' => array_merge($per, $pag, [['name' => 'dias', 'in' => 'query', 'schema' => ['type' => 'string', 'enum' => ['todos', 'uteis']], 'description' => 'Padrao: todos']]), 'responses' => $ok]],
            '/api/v1/resumo' => ['get' => ['summary' => 'Agregados (maximo ' . API_MAX_DIAS_RESUMO . ' dias)', 'parameters' => array_merge($per, [['name' => 'agrupar', 'in' => 'query', 'schema' => ['type' => 'string', 'enum' => ['dia', 'dia_semana', 'mes', 'modalidade', 'colaborador']]], ['name' => 'dias', 'in' => 'query', 'schema' => ['type' => 'string', 'enum' => ['uteis', 'todos'], 'default' => 'uteis']]]), 'responses' => $ok]],
            '/api/v1/mensal' => ['get' => ['summary' => 'Relatorio mensal completo (metas, kpis, modalidade, cargo, dia da semana, faixas, alertas, top 10, centros de custo, evolucao, recomendacoes)', 'parameters' => [['name' => 'mes', 'in' => 'query', 'required' => true, 'schema' => ['type' => 'string', 'pattern' => '^[0-9]{4}-[0-9]{2}$']]], 'responses' => $ok]],
        ],
    ];
}

// Ponto de entrada: tudo em /api/v1/*. Responde e encerra.
function tratarApiV1($cfg, $rota, $metodo, $agora)
{
    if ($metodo !== 'GET') apiErro(405, 'a API e somente leitura (GET)');
    $db = abrirBanco($cfg);
    $tok = apiTokenAtual($db, $agora);
    if (!$tok) apiErro(401, 'token invalido, expirado ou revogado');
    $ip = ipCliente($cfg);
    $get = $_GET;
    $rotaCurta = substr($rota, 8);
    $rotas = ['saude', 'colaboradores', 'dias', 'resumo', 'mensal', 'openapi.json'];
    if (!in_array($rotaCurta, $rotas, true)) apiErro(404, 'rota desconhecida: use ' . implode(', ', $rotas));
    $q = http_build_query(array_diff_key($get, ['formato' => 1]));
    auditar($db, $agora, $ip, 'api:' . $tok['nome'], 'api_acesso', $rotaCurta . ($q !== '' ? '?' . $q : ''));
    switch ($rotaCurta) {
        case 'saude':
            apiSaida(['ok' => true, 'hora' => gmdate('c', intdiv($agora, 1000)), 'token' => ['nome' => $tok['nome'], 'expira_em' => $tok['expira_em'] === null ? null : (int)$tok['expira_em'], 'pseudonimizado' => (int)$tok['anonimizar'] === 1]]);
        case 'colaboradores': apiRotaColaboradores($db, $cfg, $tok, $get); break;
        case 'dias': apiRotaDias($db, $cfg, $tok, $get, $agora); break;
        case 'resumo': apiRotaResumo($db, $cfg, $tok, $get, $agora); break;
        case 'mensal': apiRotaMensal($db, $cfg, $tok, $get, $agora); break;
        case 'openapi.json': responderJson(200, apiOpenApi()); break;
    }
}
