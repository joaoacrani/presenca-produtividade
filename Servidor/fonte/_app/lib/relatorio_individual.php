<?php
// Relatorio individual de produtividade (so administradores): o MESMO modelo do relatorio do escritorio (cabecalho, quatro indicadores,
// periodo, metas, secoes numeradas, rodape), mas sobre uma pessoa so e comparado com a media do escritorio.
// Usa as metricas validadas do relatorio geral (score, tempo ativo, disponibilidade, ocioso, participacao por categoria) e as mesmas
// metas (relMetas). Mede uso do computador, nao o resultado do trabalho: o texto do relatorio diz isso.

// Pessoa: so loga se existe no cadastro ou tem leitura (o painel lista os colaboradores conhecidos).
function relIndividualExiste(PDO $db, $login, $colabs)
{
    if (isset($colabs[$login])) return true;
    $st = $db->prepare('SELECT 1 FROM registros WHERE login = ? LIMIT 1');
    $st->execute([$login]);
    return (bool)$st->fetchColumn();
}

// Onde o tempo foi: sites (nav_dia) e programas (foco_dia) da pessoa no periodo, com a categoria de cada um.
function relIndividualTempo(PDO $db, $login, $de, $ate)
{
    $regras = carregarRegras($db);
    $sites = []; $progs = []; $cat = ['produtivo' => 0, 'neutro' => 0, 'improdutivo' => 0];
    $st = $db->prepare('SELECT dominio, SUM(segundos) AS seg, SUM(visitas) AS vis FROM nav_dia WHERE login = ? AND dia >= ? AND dia <= ? GROUP BY dominio');
    $st->execute([$login, $de, $ate]);
    foreach ($st->fetchAll() as $r) {
        $c = classificarDominio($r['dominio'], $regras)[0];
        $seg = (int)$r['seg'];
        $cat[$c] += $seg;
        $sites[] = ['nome' => $r['dominio'], 'categoria' => $c, 'seg' => $seg, 'visitas' => (int)$r['vis']];
    }
    $st = $db->prepare('SELECT processo, SUM(segundos) AS seg FROM foco_dia WHERE login = ? AND dia >= ? AND dia <= ? GROUP BY processo');
    $st->execute([$login, $de, $ate]);
    foreach ($st->fetchAll() as $r) {
        $c = classificarApp($r['processo'], $regras)[0];
        if ($c === 'navegador') continue;   // o navegador ja vale pelos sites
        $seg = (int)$r['seg'];
        $cat[$c] += $seg;
        $progs[] = ['nome' => nomeProgramaAmigavel($r['processo']), 'categoria' => $c, 'seg' => $seg];
    }
    $cmp = function ($x, $y) { return $y['seg'] <=> $x['seg'] ?: strcmp($x['nome'], $y['nome']); };
    usort($sites, $cmp); usort($progs, $cmp);
    $total = array_sum($cat);
    $pct = function ($l) use ($total) { foreach ($l as &$x) $x['pct'] = $total > 0 ? round($x['seg'] * 100 / $total, 1) : null; return $l; };
    return ['sites' => $pct(array_slice($sites, 0, 10)), 'programas' => $pct(array_slice($progs, 0, 10)),
        'categorias' => ['produtivo_seg' => $cat['produtivo'], 'neutro_seg' => $cat['neutro'], 'improdutivo_seg' => $cat['improdutivo'], 'total_seg' => $total]];
}

function montarRelatorioIndividual(PDO $db, $cfg, $login, $tipo, $ref, $deLivre, $ateLivre, $agora)
{
    @set_time_limit(180);
    $tz = fusoDe($cfg);
    $hoje = diaLocal($agora, $tz);
    list($de, $fimCheio, $rotuloPeriodo, $subtitulo) = relPeriodo($cfg, $tipo, $ref, $deLivre, $ateLivre, $hoje);
    $ate = $fimCheio > $hoje ? $hoje : $fimCheio;
    $colabs = mapaColaboradores($db);
    $metas = relMetas($cfg);
    $c = isset($colabs[$login]) ? $colabs[$login] : ['nome' => '', 'cargo' => '', 'centro_custo' => '', 'rh' => false, 'jornada_horas' => null];
    $nome = $c['nome'] !== '' ? relUpper($c['nome']) : 'LOGIN ' . $login;
    $jornadaPadrao = isset($cfg['jornada_horas']) && (float)$cfg['jornada_horas'] > 0 ? (float)$cfg['jornada_horas'] : 8.0;

    $rel = ['tipo' => 'individual', 'periodo_tipo' => $tipo, 'referencia' => $ref, 'titulo' => 'RELATÓRIO INDIVIDUAL DE PRODUTIVIDADE',
        'subtitulo' => 'Análise Presença e Produtividade - ' . $nome . ' - ' . $rotuloPeriodo, 'rotulo_periodo' => $rotuloPeriodo, 'gerado_em' => $agora, 'metas' => $metas,
        'pessoa' => ['login' => $login, 'nome' => $nome, 'cargo' => $c['cargo'], 'centro_custo' => $c['centro_custo'], 'rh' => (bool)$c['rh'],
            'jornada_horas' => $c['jornada_horas'] !== null ? (float)$c['jornada_horas'] : $jornadaPadrao]];

    // ---- uma passada no periodo (so dias uteis): escritorio inteiro, cada pessoa (para a posicao) e os dias da pessoa ----
    $uteis = array_flip(diasUteis($de, $ate, $cfg));
    $geral = apiAcum(); $porPessoa = []; $meu = apiAcum(); $modo = []; $dow = []; $dias = [];
    apiPercorrerDias($db, $cfg, $de, $ate, null, $hoje, function ($r) use (&$geral, &$porPessoa, &$meu, &$modo, &$dow, &$dias, $uteis, $login) {
        if (!isset($uteis[$r['dia']])) return;
        apiAcumular($geral, $r);
        if (!isset($porPessoa[$r['login']])) $porPessoa[$r['login']] = apiAcum();
        apiAcumular($porPessoa[$r['login']], $r);
        if ($r['login'] !== $login) return;
        apiAcumular($meu, $r);
        if (!isset($modo[$r['modalidade']])) $modo[$r['modalidade']] = apiAcum();
        apiAcumular($modo[$r['modalidade']], $r);
        if (!isset($dow[$r['dia_semana']])) $dow[$r['dia_semana']] = apiAcum();
        apiAcumular($dow[$r['dia_semana']], $r);
        $dias[] = $r;
    });
    $fer = array_values(array_filter(isset($cfg['feriados']) && is_array($cfg['feriados']) ? $cfg['feriados'] : [], function ($f) use ($de, $ate) {
        return is_string($f) && $f >= $de && $f <= $ate && (int)(new DateTimeImmutable($f))->format('N') <= 5;
    }));
    $rel['periodo'] = ['de' => $de, 'ate' => $ate, 'dias_uteis' => count($uteis), 'feriados_excluidos' => $fer, 'parcial' => $ate < $fimCheio];
    $f = apiAcumFinal($meu); $fg = apiAcumFinal($geral);
    if ($f['dias_registro'] === 0) { $rel['sem_dados'] = true; return $rel; }

    // ---- indicadores da pessoa x media do escritorio x meta ----
    $ativoH = $f['tempo_ativo_medio_dia_seg'] === null ? null : round($f['tempo_ativo_medio_dia_seg'] / 3600, 1);
    $ativoHg = $fg['tempo_ativo_medio_dia_seg'] === null ? null : round($fg['tempo_ativo_medio_dia_seg'] / 3600, 1);
    $ocioso = $f['ocioso_medio_dia_seg'] === null ? null : round($f['ocioso_medio_dia_seg'] / 60);
    $ociosog = $fg['ocioso_medio_dia_seg'] === null ? null : round($fg['ocioso_medio_dia_seg'] / 60);
    $fmtH = function ($v) { return $v === null ? '-' : relFmt($v) . ' h'; };
    $fmtP = function ($v) { return $v === null ? '-' : relFmt($v) . '%'; };
    $mk = function ($nome, $valor, $esc, $meta, $ok) { return ['indicador' => $nome, 'valor' => $valor, 'escritorio' => $esc, 'meta' => $meta, 'atingida' => $ok]; };
    $rel['indicadores'] = [
        $mk('Tempo de tela ativo por dia', $fmtH($ativoH), $fmtH($ativoHg), '≥ ' . relFmt($metas['tempo_ativo_h'], 0) . ' h', $ativoH !== null && $ativoH >= $metas['tempo_ativo_h']),
        $mk('Taxa de disponibilidade (tempo ativo ÷ jornada)', $fmtP($f['disponibilidade_pct']), $fmtP($fg['disponibilidade_pct']), '≥ ' . relFmt($metas['disponibilidade_pct'], 0) . '%', $f['disponibilidade_pct'] !== null && $f['disponibilidade_pct'] >= $metas['disponibilidade_pct']),
        $mk('Tempo ocioso por dia (entre o primeiro e o último clique)', $ocioso === null ? '-' : relFmt($ocioso, 0) . ' min', $ociosog === null ? '-' : relFmt($ociosog, 0) . ' min', '< ' . relFmt($metas['ocioso_min'], 0) . ' min', $ocioso !== null && $ocioso < $metas['ocioso_min']),
        $mk('Tempo em apps e sites produtivos', $fmtP($f['pct_tempo_produtivo']), $fmtP($fg['pct_tempo_produtivo']), '≥ ' . relFmt($metas['produtivo_pct'], 0) . '%', $f['pct_tempo_produtivo'] !== null && $f['pct_tempo_produtivo'] >= $metas['produtivo_pct']),
        $mk('Tempo em apps e sites neutros', $fmtP($f['pct_tempo_neutro']), $fmtP($fg['pct_tempo_neutro']), '≤ ' . relFmt($metas['neutro_pct'], 0) . '%', $f['pct_tempo_neutro'] !== null && $f['pct_tempo_neutro'] <= $metas['neutro_pct']),
        $mk('Tempo em apps e sites improdutivos', $fmtP($f['pct_tempo_improdutivo']), $fmtP($fg['pct_tempo_improdutivo']), '< ' . relFmt($metas['improdutivo_pct'], 0) . '%', $f['pct_tempo_improdutivo'] !== null && $f['pct_tempo_improdutivo'] < $metas['improdutivo_pct']),
        $mk('Score de produtividade', $f['score'] === null ? '-' : relFmt($f['score']), $fg['score'] === null ? '-' : relFmt($fg['score']), '≥ ' . relFmt($metas['score'], 0) . ' pontos', $f['score'] !== null && $f['score'] >= $metas['score']),
    ];
    $rel['kpis'] = ['score' => $f['score'], 'tempo_ativo_medio_dia_seg' => $f['tempo_ativo_medio_dia_seg'], 'pct_tempo_produtivo' => $f['pct_tempo_produtivo'], 'dias_registro' => $f['dias_registro'], 'score_escritorio' => $fg['score']];
    $rel['cliques'] = ['primeiro_medio' => $f['primeiro_click_medio'], 'ultimo_medio' => $f['ultimo_click_medio'], 'primeiro_escritorio' => $fg['primeiro_click_medio'], 'ultimo_escritorio' => $fg['ultimo_click_medio']];
    $fx = $f['score'] === null ? null : relFaixaDe($f['score']);
    $rel['classificacao'] = $fx === null ? null : ['faixa' => relUpper($fx['nome']), 'score' => $f['score'], 'meta' => $metas['score'], 'acima_da_meta' => $f['score'] >= $metas['score']];

    // ---- posicao entre os colaboradores com 5 ou mais dias ----
    $base = [];
    foreach ($porPessoa as $l => $a) { $x = apiAcumFinal($a); if ($x['score'] !== null && $x['dias_registro'] >= 5) $base[$l] = $x['score']; }
    $rel['posicao'] = null;
    if (isset($base[$login]) && count($base) >= 5) {
        $abaixo = 0; foreach ($base as $s) if ($s < $base[$login]) $abaixo++;
        $pos = 1; foreach ($base as $s) if ($s > $base[$login]) $pos++;
        $rel['posicao'] = ['posicao' => $pos, 'de' => count($base), 'acima_de_pct' => round($abaixo * 100 / (count($base) - 1), 0)];
    }

    // ---- evolucao (ate 6 periodos com dados) ----
    $evolucao = []; $anterior = null;
    if ($tipo === 'mensal' || $tipo === 'semanal') {
        for ($i = 5; $i >= 0; $i--) {
            if ($tipo === 'mensal') {
                $ini = (new DateTimeImmutable($de, $tz))->modify("-$i months");
                $d0 = $ini->format('Y-m-01'); $d1 = $ini->modify('last day of this month')->format('Y-m-d');
                $rot = REL_MESES_ABREV[(int)$ini->format('n')] . '/' . $ini->format('Y'); $chave = $ini->format('Y-m');
            } else {
                $ini = (new DateTimeImmutable($de, $tz))->modify('-' . (7 * $i) . ' days');
                $d0 = $ini->format('Y-m-d'); $d1 = $ini->modify('+6 days')->format('Y-m-d');
                $rot = substr(relDiaBR($d0), 0, 5) . ' a ' . substr(relDiaBR($d1), 0, 5); $chave = $d0;
            }
            if ($d0 > $hoje) continue;
            if ($d1 > $hoje) $d1 = $hoje;
            if ($i === 0) { $a = $meu; $du = count($uteis); }
            else { $x = apiAgregarPeriodo($db, $cfg, $d0, $d1, [$login], $hoje, true); $a = $x['geral']; $du = $x['dias_uteis']; }
            $ff = apiAcumFinal($a);
            if ($ff['dias_registro'] === 0) continue;
            $linha = ['chave' => $chave, 'rotulo' => $rot, 'dias_uteis' => $du, 'dias' => $ff['dias_registro'], 'score' => $ff['score'],
                'tempo_ativo_medio_dia_seg' => $ff['tempo_ativo_medio_dia_seg'], 'pct_tempo_produtivo' => $ff['pct_tempo_produtivo']];
            if ($i > 0) $anterior = $linha;
            $evolucao[] = $linha;
        }
    }
    $rel['evolucao'] = $evolucao;

    // ---- modalidade e dia da semana da pessoa ----
    $mod = [];
    foreach (['presencial', 'remoto'] as $m) if (isset($modo[$m])) { $x = apiAcumFinal($modo[$m]); $mod[] = ['modalidade' => REL_ROTULO_MODO[$m], 'registros' => $x['dias_registro'], 'score' => $x['score'], 'pct_tempo_produtivo' => $x['pct_tempo_produtivo'], 'tempo_ativo_medio_dia_seg' => $x['tempo_ativo_medio_dia_seg']]; }
    $outros = 0; foreach ($modo as $m => $a) if ($m !== 'presencial' && $m !== 'remoto') $outros += $a['dias'];
    $rel['modalidade'] = $mod; $rel['dias_sem_local'] = $outros;
    $dw = [];
    for ($d = 1; $d <= 5; $d++) if (isset($dow[$d])) { $x = apiAcumFinal($dow[$d]); $dw[] = ['dia_semana' => $d, 'nome' => ucfirst(API_NOMES_DIA[$d]), 'score' => $x['score'], 'pct_tempo_produtivo' => $x['pct_tempo_produtivo'], 'tempo_ativo_medio_dia_seg' => $x['tempo_ativo_medio_dia_seg'], 'registros' => $x['dias_registro']]; }
    $rel['dia_semana'] = $dw;

    // ---- onde o tempo foi ----
    $rel['tempo'] = relIndividualTempo($db, $login, $de, $ate);

    // ---- dia a dia ----
    $rotModo = ['presencial' => 'Presencial', 'remoto' => 'Remoto', 'parcial' => 'Parcial', 'sem_rede' => 'Sem rede', 'sem_leitura' => 'Sem leitura'];
    $diario = [];
    foreach ($dias as $r) $diario[] = ['dia' => $r['dia'], 'dia_semana' => ucfirst(API_NOMES_DIA[$r['dia_semana']]), 'modalidade' => isset($rotModo[$r['modalidade']]) ? $rotModo[$r['modalidade']] : $r['modalidade'],
        'score' => $r['score'], 'tempo_ativo_seg' => $r['tempo_ativo_seg'], 'primeiro_click' => $r['primeiro_click'], 'ultimo_click' => $r['ultimo_click'], 'ocioso_seg' => $r['ocioso_seg']];
    usort($diario, function ($x, $y) { return strcmp($x['dia'], $y['dia']); });
    $rel['diario'] = $diario;

    // ---- achados e recomendacoes (por regras, a partir dos numeros) ----
    $pPres = isset($modo['presencial']) ? apiAcumFinal($modo['presencial']) : null;
    $pRem = isset($modo['remoto']) ? apiAcumFinal($modo['remoto']) : null;
    $achados = [];
    if ($f['dias_registro'] < 5) $achados[] = 'Poucos dias registrados (' . $f['dias_registro'] . '): o score de um período curto oscila muito. Interpretar com cautela e confirmar férias, afastamento, admissão ou desligamento.';
    if ($f['score'] !== null && $fg['score'] !== null) {
        $dif = round($f['score'] - $fg['score'], 1);
        $achados[] = 'Score ' . relFmt($f['score']) . ' (' . ($rel['classificacao']['faixa']) . '), ' . (abs($dif) < 1 ? 'em linha com' : ($dif > 0 ? relFmt($dif) . ' ponto(s) acima da' : relFmt(abs($dif)) . ' ponto(s) abaixo da')) . ' média do escritório (' . relFmt($fg['score']) . ').';
    }
    if ($rel['posicao']) $achados[] = 'Posição no escritório: ' . $rel['posicao']['posicao'] . 'º de ' . $rel['posicao']['de'] . ' colaboradores com 5 ou mais dias registrados (acima de ' . $rel['posicao']['acima_de_pct'] . '% deles).';
    if ($ativoH !== null) $achados[] = 'Tempo de tela ativo de ' . relFmt($ativoH) . ' h por dia (meta ≥ ' . relFmt($metas['tempo_ativo_h'], 0) . ' h; escritório ' . $fmtH($ativoHg) . ').';
    if ($pPres && $pRem && $pPres['score'] !== null && $pRem['score'] !== null) {
        $dif = round($pPres['score'] - $pRem['score'], 1);
        $achados[] = 'Presencial vs. remoto: score ' . relFmt($pPres['score']) . ' (' . $pPres['dias_registro'] . ' dia(s)) vs. ' . relFmt($pRem['score']) . ' (' . $pRem['dias_registro'] . ' dia(s)), diferença de ' . relFmt(abs($dif)) . ' ponto(s)' . (min($pPres['dias_registro'], $pRem['dias_registro']) < 5 ? '; poucos dias em um dos modos, pouco representativo' : '') . '.';
    }
    if (count($dw) >= 2) {
        $ord = $dw; usort($ord, function ($x, $y) { return $y['score'] <=> $x['score']; });
        $achados[] = 'Variação semanal: ' . $ord[0]['nome'] . ' tem o melhor score (' . relFmt($ord[0]['score']) . ') e ' . $ord[count($ord) - 1]['nome'] . ' o menor (' . relFmt($ord[count($ord) - 1]['score']) . ').';
    }
    if ($anterior && $anterior['score'] !== null && $f['score'] !== null) {
        $d1 = round($f['score'] - $anterior['score'], 1);
        $achados[] = 'Versus ' . ($tipo === 'semanal' ? 'a semana anterior (' . $anterior['rotulo'] . ')' : relMesNome($anterior['chave'])) . ': score ' . relFmt($f['score']) . ' vs. ' . relFmt($anterior['score']) . ' (' . ($d1 >= 0 ? '+' : '-') . relFmt(abs($d1)) . ').';
    }
    $nao = []; foreach ($rel['indicadores'] as $ind) if (!$ind['atingida']) $nao[] = $ind['indicador'];
    $achados[] = count($nao) === 0 ? 'Todas as metas foram atingidas no período.' : count($nao) . ' de ' . count($rel['indicadores']) . ' metas não foram atingidas: ' . implode('; ', $nao) . '.';
    $rel['achados'] = $achados;

    $rec = [['titulo' => 'Como ler este relatório', 'texto' => 'Os números medem o uso do computador (programas e sites em foco), não o resultado do trabalho. Audiências, reuniões, atendimentos e leitura de documentos em papel não aparecem aqui. Use como ponto de partida para uma conversa, não como avaliação isolada.']];
    if ($f['dias_registro'] < 5) $rec[] = ['titulo' => 'Poucos dias registrados', 'texto' => 'Confirmar com o RH e o coordenador se houve férias, afastamento, entrada ou saída no período antes de interpretar o score.'];
    $tem = $rel['tempo'];
    if ($f['pct_tempo_improdutivo'] !== null && $f['pct_tempo_improdutivo'] >= $metas['improdutivo_pct']) $rec[] = ['titulo' => 'Sites e programas improdutivos', 'texto' => 'O tempo improdutivo (' . relFmt($f['pct_tempo_improdutivo']) . '%) passou da meta. Conferir a seção "Onde o tempo foi gasto": às vezes a classificação do site ou programa precisa ser revista (uso legítimo classificado como improdutivo) antes de qualquer conversa.'];
    if ($ocioso !== null && $ocioso >= $metas['ocioso_min']) $rec[] = ['titulo' => 'Tempo ocioso', 'texto' => 'O tempo entre o primeiro e o último clique sem atividade (' . relFmt($ocioso, 0) . ' min/dia) inclui o almoço e pausas. Considerar rotina de trabalho (reuniões, audiências, tarefas fora do computador) antes de concluir algo.'];
    if ($ativoH !== null && $ativoH < $metas['tempo_ativo_h']) $rec[] = ['titulo' => 'Tempo de tela', 'texto' => 'O tempo de tela ativo (' . relFmt($ativoH) . ' h/dia) está abaixo da meta. Verificar se a função envolve atividades fora do computador e se o equipamento ou os sistemas têm falhas que atrapalham o uso.'];
    if ($f['score'] !== null && $f['score'] < $metas['score'] && $f['dias_registro'] >= 5) $rec[] = ['titulo' => 'Score abaixo da meta', 'texto' => 'Conversar com o coordenador sobre carga de trabalho, ferramentas e uso do equipamento, olhando também a tendência (seção Evolução) e não só este período.'];
    if ($f['score'] !== null && $f['score'] >= 85 && $f['dias_registro'] >= 5) $rec[] = ['titulo' => 'Reconhecimento', 'texto' => 'Desempenho na faixa Excelente: vale reconhecer e, se fizer sentido, compartilhar boas práticas com a equipe.'];
    $rel['recomendacoes'] = $rec;
    return $rel;
}
