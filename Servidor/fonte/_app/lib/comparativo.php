<?php
// Comparativo Home x Presencial (so administradores): produtividade do mesmo colaborador nos dias de trabalho em casa
// e nos dias no escritorio. Usa o que ja existe (presenca_dia, nav_dia e foco_dia), sem coleta nova.

// Local do dia = onde o computador ficou mais tempo (mais leituras): 60% em casa e 40% no escritorio = dia de home.
// Dia com poucas leituras (PC ligado menos de ~1 h, 'parcial_abaixo_leituras') ou sem rede nao entra: nao ha como afirmar.
// Empate (raro) vale como remoto. VPN: "Presencial via VPN" conta como presencial e "Remoto via VPN" como remoto.
function modoDoDia($d, $cfg)
{
    if ($d === null) return null;
    $validos = (int)$d['pres'] + (int)$d['rem'];
    if ($validos < (int)$cfg['parcial_abaixo_leituras']) return null;
    return $d['pres'] > $d['rem'] ? 'presencial' : 'remoto';
}

function acumuladorModo() { return ['dias' => 0, 'dias_com_uso' => 0, 'produtivo' => 0, 'improdutivo' => 0, 'neutro' => 0]; }

// Numeros de um modo: % produtivo (prod / (prod + improd)) e tempo produtivo por dia (media dos dias com uso do computador).
function metricasModo($a)
{
    $uso = $a['dias_com_uso'];
    $total = $a['produtivo'] + $a['improdutivo'] + $a['neutro'];
    return [
        'dias' => $a['dias'], 'dias_com_uso' => $uso,
        'produtivo' => $a['produtivo'], 'improdutivo' => $a['improdutivo'], 'neutro' => $a['neutro'],
        'pct_produtivo' => pctProdutivo($a['produtivo'], $a['improdutivo']),
        'prod_seg_dia' => $uso > 0 ? (int)round($a['produtivo'] / $uso) : null,
        'total_seg_dia' => $uso > 0 ? (int)round($total / $uso) : null,
    ];
}

function difMetricas($rem, $pres, $campo)
{
    return ($rem[$campo] === null || $pres[$campo] === null) ? null : round($rem[$campo] - $pres[$campo], 1);
}

// ?min=N (1 a 30) troca o minimo de dias em cada modo so nesta consulta (seletor da tela); sem ele vale o config.php (padrao 3).
function cfgComparativo($cfg, $get)
{
    if (isset($get['min']) && ctype_digit((string)$get['min'])) $cfg['comparativo_min_dias'] = max(1, min(30, (int)$get['min']));
    return $cfg;
}

// $loginsFiltro: null = todos, lista = so esses (busca do painel). Com um unico login, devolve tambem o dia a dia.
function relatorioComparativo(PDO $db, $cfg, $de, $ate, $agora, $loginsFiltro = null)
{
    $minDias = max(1, (int)(isset($cfg['comparativo_min_dias']) ? $cfg['comparativo_min_dias'] : 3));
    $hoje = diaLocal($agora, fusoDe($cfg));
    $prod = relatorioProdutividade($db, $cfg, $de, $ate, $loginsFiltro, true, true);
    $porLoginDia = $prod['por_login_dia'];
    $pdia = presencaPorDia($db, $de, $ate, $loginsFiltro);
    $colabs = mapaColaboradores($db);
    $detalhar = is_array($loginsFiltro) && count($loginsFiltro) === 1;
    $zero = ['produtivo' => 0, 'improdutivo' => 0, 'neutro' => 0];

    $linhas = []; $fora = [];
    $geral = ['presencial' => acumuladorModo(), 'remoto' => acumuladorModo()];
    foreach ($pdia as $login => $dias) {
        if (isset($colabs[$login]) && !$colabs[$login]['ativo']) continue;
        $acc = ['presencial' => acumuladorModo(), 'remoto' => acumuladorModo()];
        $lista = [];
        ksort($dias);
        foreach ($dias as $dia => $d) {
            if ($dia > $hoje) continue;
            $modo = modoDoDia($d, $cfg);
            if ($modo === null) continue;
            $u = isset($porLoginDia[$login][$dia]) ? $porLoginDia[$login][$dia] : $zero;
            $tot = $u['produtivo'] + $u['improdutivo'] + $u['neutro'];
            $acc[$modo]['dias']++;
            if ($tot > 0) {
                $acc[$modo]['dias_com_uso']++;
                foreach (['produtivo', 'improdutivo', 'neutro'] as $k) $acc[$modo][$k] += $u[$k];
            }
            if ($detalhar) {
                $lista[] = ['dia' => $dia, 'modo' => $modo, 'leituras_presencial' => (int)$d['pres'], 'leituras_remoto' => (int)$d['rem'],
                    'produtivo' => $u['produtivo'], 'improdutivo' => $u['improdutivo'], 'neutro' => $u['neutro'],
                    'pct_produtivo' => pctProdutivo($u['produtivo'], $u['improdutivo'])];
            }
        }
        $id = identidade($login, $colabs);
        if ($acc['presencial']['dias'] < $minDias || $acc['remoto']['dias'] < $minDias) {
            // trabalha so de um lugar (ou ainda tem poucos dias): nao entra na comparacao, mas explica por que
            if ($acc['presencial']['dias'] + $acc['remoto']['dias'] > 0 && count($fora) < 50) {
                $fora[] = ['login' => $login, 'colaborador' => $id['colaborador'], 'dias_presencial' => $acc['presencial']['dias'], 'dias_remoto' => $acc['remoto']['dias']];
            }
            continue;
        }
        $p = metricasModo($acc['presencial']); $r = metricasModo($acc['remoto']);
        $linha = $id + ['presencial' => $p, 'remoto' => $r,
            'dif_pct' => difMetricas($r, $p, 'pct_produtivo'), 'dif_prod_seg_dia' => ($r['prod_seg_dia'] === null || $p['prod_seg_dia'] === null) ? null : $r['prod_seg_dia'] - $p['prod_seg_dia']];
        if ($detalhar) $linha['dias'] = $lista;
        $linhas[] = $linha;
        foreach (['presencial', 'remoto'] as $m) foreach ($acc[$m] as $k => $v) $geral[$m][$k] += $v;
    }
    usort($linhas, function ($a, $b) { return strcasecmp($a['colaborador'], $b['colaborador']); });
    usort($fora, function ($a, $b) {
        $pa = min($a['dias_presencial'], $a['dias_remoto']); $pb = min($b['dias_presencial'], $b['dias_remoto']);
        return $pa !== $pb ? $pb <=> $pa : strcasecmp($a['colaborador'], $b['colaborador']);
    });
    $gp = metricasModo($geral['presencial']); $gr = metricasModo($geral['remoto']);
    return [
        'de' => $de, 'ate' => $ate, 'min_dias' => $minDias,
        'colaboradores' => $linhas, 'fora' => $fora,
        'geral' => ['colaboradores' => count($linhas), 'presencial' => $gp, 'remoto' => $gr,
            'dif_pct' => difMetricas($gr, $gp, 'pct_produtivo'),
            'dif_prod_seg_dia' => ($gr['prod_seg_dia'] === null || $gp['prod_seg_dia'] === null) ? null : $gr['prod_seg_dia'] - $gp['prod_seg_dia']],
    ];
}
