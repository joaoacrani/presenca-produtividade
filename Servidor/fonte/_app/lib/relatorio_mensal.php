<?php
// Relatorio de produtividade (mensal ou semanal): monta, a partir dos dados que a propria ferramenta coleta, as secoes
// que o analista fazia a mao (metas, sumario, modalidade, dia da semana, faixas, alertas, top 10, centros de custo,
// evolucao diaria, recomendacoes). So administradores (tem nomes de pessoas). Nada de extracao manual: calcula na hora.
//
// Metricas validadas:
//  - Score = (produtivo x 1,0 + neutro x 0,5) / tempo total x 100 (meta >= 80)
//  - Tempo de tela ativo (>= 6 h/dia), disponibilidade = tempo ativo / jornada contratual (>= 75%), ocioso (< 90 min/dia),
//    primeiro e ultimo clique, participacao de produtivo (>= 70%), neutro (<= 20%) e improdutivo (< 10%) no tempo total.
//  - Base inicial: a media geral do escritorio em todos os indicadores.

const REL_MESES = ['', 'Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho', 'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro'];
const REL_MESES_ABREV = ['', 'Jan', 'Fev', 'Mar', 'Abr', 'Mai', 'Jun', 'Jul', 'Ago', 'Set', 'Out', 'Nov', 'Dez'];
const REL_ROTULO_MODO = ['presencial' => 'Presencial', 'remoto' => 'Remoto (home)'];

function relMetas($cfg)
{
    $m = ['score' => 80, 'tempo_ativo_h' => 6, 'disponibilidade_pct' => 75, 'ocioso_min' => 90, 'produtivo_pct' => 70, 'neutro_pct' => 20, 'improdutivo_pct' => 10];
    if (isset($cfg['relatorio_metas']) && is_array($cfg['relatorio_metas'])) foreach ($cfg['relatorio_metas'] as $k => $v) if (isset($m[$k]) && is_numeric($v)) $m[$k] = (float)$v;
    return $m;
}

// Faixas do score (cortes 30, 50, 70 e 85, como no relatorio de referencia).
function relFaixas()
{
    return [['id' => 'critico', 'nome' => 'Crítico', 'de' => 0, 'ate' => 30, 'rotulo' => 'Crítico (< 30)'],
        ['id' => 'atencao', 'nome' => 'Atenção', 'de' => 30, 'ate' => 50, 'rotulo' => 'Atenção (30-50)'],
        ['id' => 'regular', 'nome' => 'Regular', 'de' => 50, 'ate' => 70, 'rotulo' => 'Regular (50-70)'],
        ['id' => 'bom', 'nome' => 'Bom', 'de' => 70, 'ate' => 85, 'rotulo' => 'Bom (70-85)'],
        ['id' => 'excelente', 'nome' => 'Excelente', 'de' => 85, 'ate' => 101, 'rotulo' => 'Excelente (85 ou mais)']];
}
function relFaixaDe($score)
{
    foreach (relFaixas() as $f) if ($score >= $f['de'] && $score < $f['ate']) return $f;
    return relFaixas()[0];
}

function relUpper($s) { return function_exists('mb_strtoupper') ? mb_strtoupper((string)$s, 'UTF-8') : strtoupper((string)$s); }
function relFmt($v, $casas = 1) { return $v === null ? '-' : number_format((float)$v, $casas, ',', '.'); }
function relHoras($seg) { return $seg === null ? '-' : relFmt($seg / 3600, 1) . ' h'; }
function relDiaBR($d) { return substr($d, 8, 2) . '/' . substr($d, 5, 2) . '/' . substr($d, 0, 4); }
function relMesNome($ym) { return REL_MESES[(int)substr($ym, 5, 2)] . '/' . substr($ym, 0, 4); }

function relPessoa($login, $colabs, array $acum)
{
    $c = isset($colabs[$login]) ? $colabs[$login] : ['nome' => '', 'cargo' => '', 'centro_custo' => '', 'rh' => false];
    $f = apiAcumFinal($acum);
    return ['login' => $login, 'nome' => $c['nome'] !== '' ? relUpper($c['nome']) : 'LOGIN ' . $login,
        'cargo' => $c['cargo'], 'centro_custo' => $c['centro_custo'], 'rh' => $c['rh'],
        'dias' => $f['dias_registro'], 'score' => $f['score'], 'pct_tempo_produtivo' => $f['pct_tempo_produtivo'], 'tempo_ativo_medio_dia_seg' => $f['tempo_ativo_medio_dia_seg']];
}

// Uma passada no periodo (so dias uteis): geral, modalidade, dia da semana, dia, colaborador, cargo x modalidade e centro de custo.
function relAgregar(PDO $db, $cfg, $de, $ate, $hoje, $colabs)
{
    $uteis = array_flip(diasUteis($de, $ate, $cfg));
    $g = ['geral' => apiAcum(), 'modo' => [], 'dow' => [], 'dia' => [], 'col' => [], 'cargo' => [], 'cc' => [], 'dias_uteis' => count($uteis)];
    apiPercorrerDias($db, $cfg, $de, $ate, null, $hoje, function ($r) use (&$g, $uteis, $colabs) {
        if (!isset($uteis[$r['dia']])) return;
        apiAcumular($g['geral'], $r);
        foreach ([['modo', $r['modalidade']], ['dow', $r['dia_semana']], ['dia', $r['dia']], ['col', $r['login']]] as $par) {
            if (!isset($g[$par[0]][$par[1]])) $g[$par[0]][$par[1]] = apiAcum();
            apiAcumular($g[$par[0]][$par[1]], $r);
        }
        $c = isset($colabs[$r['login']]) ? $colabs[$r['login']] : null;
        if ($c && $c['centro_custo'] !== '') {
            if (!isset($g['cc'][$c['centro_custo']])) $g['cc'][$c['centro_custo']] = apiAcum();
            apiAcumular($g['cc'][$c['centro_custo']], $r);
        }
        if ($c && $c['cargo'] !== '' && ($r['modalidade'] === 'presencial' || $r['modalidade'] === 'remoto')) {
            if (!isset($g['cargo'][$c['cargo']][$r['modalidade']])) $g['cargo'][$c['cargo']][$r['modalidade']] = apiAcum();
            apiAcumular($g['cargo'][$c['cargo']][$r['modalidade']], $r);
        }
    });
    return $g;
}

// Periodo do relatorio: mes ("2026-10"), semana (segunda a domingo, a partir de uma data) ou intervalo livre ($de e $ate).
function relPeriodo($cfg, $tipo, $ref, $de, $ate, $hoje)
{
    $tz = fusoDe($cfg);
    if ($tipo === 'mensal') {
        $d0 = $ref . '-01';
        $d1 = (new DateTimeImmutable($d0, $tz))->modify('last day of this month')->format('Y-m-d');
        $titulo = REL_MESES[(int)substr($ref, 5, 2)] . '/' . substr($ref, 0, 4);
        return [$d0, $d1, $titulo, 'Análise Presença e Produtividade - ' . $titulo];
    }
    if ($tipo === 'semanal') {
        $dt = new DateTimeImmutable($ref, $tz);
        $d0 = $dt->modify('-' . ((int)$dt->format('N') - 1) . ' days')->format('Y-m-d');   // segunda-feira da semana de $ref
        $d1 = (new DateTimeImmutable($d0, $tz))->modify('+6 days')->format('Y-m-d');
        return [$d0, $d1, 'semana de ' . substr(relDiaBR($d0), 0, 5) . ' a ' . relDiaBR($d1), 'Análise Presença e Produtividade - semana de ' . relDiaBR($d0) . ' a ' . relDiaBR($d1)];
    }
    return [$de, $ate, relDiaBR($de) . ' a ' . relDiaBR($ate), 'Análise Presença e Produtividade - ' . relDiaBR($de) . ' a ' . relDiaBR($ate)];
}

function montarRelatorio(PDO $db, $cfg, $tipo, $ref, $deLivre, $ateLivre, $agora)
{
    @set_time_limit(180);
    $tz = fusoDe($cfg);
    $hoje = diaLocal($agora, $tz);
    list($de, $fimCheio, $rotuloPeriodo, $subtitulo) = relPeriodo($cfg, $tipo, $ref, $deLivre, $ateLivre, $hoje);
    $ate = $fimCheio > $hoje ? $hoje : $fimCheio;
    $colabs = mapaColaboradores($db);
    $temRh = false; foreach ($colabs as $c) if ($c['rh']) { $temRh = true; break; }
    $metas = relMetas($cfg);

    $rel = [
        'tipo' => $tipo, 'referencia' => $ref, 'titulo' => $tipo === 'semanal' ? 'RELATÓRIO SEMANAL DE PRODUTIVIDADE' : 'RELATÓRIO MENSAL DE PRODUTIVIDADE', 'subtitulo' => $subtitulo, 'rotulo_periodo' => $rotuloPeriodo,
        'gerado_em' => $agora, 'metas' => $metas, 'tem_rh' => $temRh,
        'jornada_padrao_horas' => isset($cfg['jornada_horas']) && (float)$cfg['jornada_horas'] > 0 ? (float)$cfg['jornada_horas'] : 8.0,
    ];
    $g = relAgregar($db, $cfg, $de, $ate, $hoje, $colabs);
    $geral = apiAcumFinal($g['geral']);
    $fer = array_values(array_filter(isset($cfg['feriados']) && is_array($cfg['feriados']) ? $cfg['feriados'] : [], function ($f) use ($de, $ate) {
        return is_string($f) && $f >= $de && $f <= $ate && (int)(new DateTimeImmutable($f))->format('N') <= 5;
    }));
    $rel['periodo'] = ['de' => $de, 'ate' => $ate, 'dias_uteis' => $g['dias_uteis'], 'feriados_excluidos' => $fer, 'parcial' => $ate < $fimCheio];
    if ($geral['colaboradores'] === 0) { $rel['sem_dados'] = true; return $rel; }

    // ---- pessoas ----
    $pessoas = [];
    foreach ($g['col'] as $login => $a) $pessoas[] = relPessoa($login, $colabs, $a);
    $comScore = array_values(array_filter($pessoas, function ($p) { return $p['score'] !== null; }));
    $cinco = array_values(array_filter($comScore, function ($p) { return $p['dias'] >= 5; }));
    $ordenar = function (array $lista, $desc) {
        usort($lista, function ($x, $y) use ($desc) {
            $c = $desc ? $y['score'] <=> $x['score'] : $x['score'] <=> $y['score'];
            return $c !== 0 ? $c : strcmp($x['nome'], $y['nome']);
        });
        return $lista;
    };

    // ---- KPIs, metas e classificacao ----
    $pPres = isset($g['modo']['presencial']) ? apiAcumFinal($g['modo']['presencial']) : null;
    $pRem = isset($g['modo']['remoto']) ? apiAcumFinal($g['modo']['remoto']) : null;
    $dPres = $pPres ? $pPres['dias_registro'] : 0; $dRem = $pRem ? $pRem['dias_registro'] : 0;
    $rel['kpis'] = ['colaboradores' => $geral['colaboradores'], 'score' => $geral['score'], 'tempo_ativo_medio_dia_seg' => $geral['tempo_ativo_medio_dia_seg'],
        'pct_tempo_produtivo' => $geral['pct_tempo_produtivo'], 'registros' => $geral['dias_registro'],
        'pct_dias_presenciais' => ($dPres + $dRem) > 0 ? round($dPres * 100 / ($dPres + $dRem), 1) : null];
    $ativoH = $geral['tempo_ativo_medio_dia_seg'] === null ? null : round($geral['tempo_ativo_medio_dia_seg'] / 3600, 1);
    $ociosoMin = $geral['ocioso_medio_dia_seg'] === null ? null : round($geral['ocioso_medio_dia_seg'] / 60);
    $mk = function ($nome, $valor, $txt, $meta, $ok) { return ['indicador' => $nome, 'valor' => $valor, 'meta' => $meta, 'atingida' => $ok]; };
    $rel['indicadores'] = [
        $mk('Tempo de tela ativo por dia', $ativoH === null ? '-' : relFmt($ativoH) . ' h', '', '≥ ' . relFmt($metas['tempo_ativo_h'], 0) . ' h', $ativoH !== null && $ativoH >= $metas['tempo_ativo_h']),
        $mk('Taxa de disponibilidade (tempo ativo ÷ jornada)', $geral['disponibilidade_pct'] === null ? '-' : relFmt($geral['disponibilidade_pct']) . '%', '', '≥ ' . relFmt($metas['disponibilidade_pct'], 0) . '%', $geral['disponibilidade_pct'] !== null && $geral['disponibilidade_pct'] >= $metas['disponibilidade_pct']),
        $mk('Tempo ocioso por dia (entre o primeiro e o último clique)', $ociosoMin === null ? '-' : relFmt($ociosoMin, 0) . ' min', '', '< ' . relFmt($metas['ocioso_min'], 0) . ' min', $ociosoMin !== null && $ociosoMin < $metas['ocioso_min']),
        $mk('Tempo em apps e sites produtivos', $geral['pct_tempo_produtivo'] === null ? '-' : relFmt($geral['pct_tempo_produtivo']) . '%', '', '≥ ' . relFmt($metas['produtivo_pct'], 0) . '%', $geral['pct_tempo_produtivo'] !== null && $geral['pct_tempo_produtivo'] >= $metas['produtivo_pct']),
        $mk('Tempo em apps e sites neutros', $geral['pct_tempo_neutro'] === null ? '-' : relFmt($geral['pct_tempo_neutro']) . '%', '', '≤ ' . relFmt($metas['neutro_pct'], 0) . '%', $geral['pct_tempo_neutro'] !== null && $geral['pct_tempo_neutro'] <= $metas['neutro_pct']),
        $mk('Tempo em apps e sites improdutivos', $geral['pct_tempo_improdutivo'] === null ? '-' : relFmt($geral['pct_tempo_improdutivo']) . '%', '', '< ' . relFmt($metas['improdutivo_pct'], 0) . '%', $geral['pct_tempo_improdutivo'] !== null && $geral['pct_tempo_improdutivo'] < $metas['improdutivo_pct']),
        $mk('Score de produtividade', $geral['score'] === null ? '-' : relFmt($geral['score']), '', '≥ ' . relFmt($metas['score'], 0) . ' pontos', $geral['score'] !== null && $geral['score'] >= $metas['score']),
    ];
    $rel['cliques'] = ['primeiro_medio' => $geral['primeiro_click_medio'], 'ultimo_medio' => $geral['ultimo_click_medio']];
    $fg = $geral['score'] === null ? null : relFaixaDe($geral['score']);
    $rel['classificacao'] = $fg === null ? null : ['faixa' => relUpper($fg['nome']), 'score' => $geral['score'], 'meta' => $metas['score'], 'acima_da_meta' => $geral['score'] >= $metas['score']];

    // ---- evolucao (ate 6 periodos com dados): meses para o mensal, semanas para o semanal ----
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
            if ($d1 > $hoje) $d1 = $hoje;
            if ($d0 > $hoje) continue;
            $x = $i === 0 ? ['geral' => $g['geral'], 'colaborador' => $g['col'], 'dias_uteis' => $g['dias_uteis']] : apiAgregarPeriodo($db, $cfg, $d0, $d1, null, $hoje, true);
            $f = apiAcumFinal($x['geral']);
            if ($f['colaboradores'] === 0) continue;
            $semRh = null;
            if ($temRh) {
                $tot = 0; $sem = 0;
                foreach ($x['colaborador'] as $l => $a) { $tot += $a['dias']; if (!(isset($colabs[$l]) && $colabs[$l]['rh'])) $sem += $a['dias']; }
                $semRh = $tot > 0 ? round($sem * 100 / $tot, 1) : null;
            }
            $linha = ['chave' => $chave, 'rotulo' => $rot, 'dias_uteis' => $x['dias_uteis'], 'colaboradores' => $f['colaboradores'], 'score' => $f['score'],
                'tempo_ativo_medio_dia_seg' => $f['tempo_ativo_medio_dia_seg'], 'pct_tempo_produtivo' => $f['pct_tempo_produtivo'], 'pct_sem_rh' => $semRh];
            if ($i > 0) $anterior = $linha;
            $evolucao[] = $linha;
        }
    }
    $rel['evolucao'] = $evolucao;

    // ---- modalidade ----
    $outros = apiAcum();
    foreach ($g['modo'] as $m => $a) if ($m !== 'presencial' && $m !== 'remoto') { foreach (['dias', 'dias_uso', 'ativo', 'produtivo', 'improdutivo', 'neutro', 'jornada', 'ocioso', 'ocioso_n', 'pmin', 'umin', 'click_n'] as $k) $outros[$k] += $a[$k]; foreach ($a['logins'] as $l => $_) $outros['logins'][$l] = true; }
    $mod = [];
    $linhaMod = function ($rotulo, $f, $fora) { return ['modalidade' => $rotulo, 'registros' => $f['dias_registro'], 'score' => $f['score'], 'pct_tempo_produtivo' => $f['pct_tempo_produtivo'], 'tempo_ativo_medio_dia_seg' => $f['tempo_ativo_medio_dia_seg'], 'fora_da_comparacao' => $fora]; };
    foreach (['presencial', 'remoto'] as $m) if (isset($g['modo'][$m])) $mod[] = $linhaMod(REL_ROTULO_MODO[$m], apiAcumFinal($g['modo'][$m]), false);
    if ($outros['dias'] > 0) $mod[] = $linhaMod('Sem local definido (poucas leituras ou sem rede)', apiAcumFinal($outros), true);
    $rel['modalidade'] = $mod;
    $rel['pct_registros_sem_local'] = $geral['dias_registro'] > 0 ? round($outros['dias'] * 100 / $geral['dias_registro'], 1) : null;

    // ---- cargo x modalidade (so com o cadastro do RH): delta = presencial - remoto, como no relatorio original ----
    $cm = [];
    foreach ($g['cargo'] as $cargo => $modos) {
        $p = isset($modos['presencial']) ? apiAcumFinal($modos['presencial']) : null;
        $r = isset($modos['remoto']) ? apiAcumFinal($modos['remoto']) : null;
        $cm[] = ['cargo' => $cargo, 'presencial' => $p ? ['score' => $p['score'], 'registros' => $p['dias_registro']] : null,
            'remoto' => $r ? ['score' => $r['score'], 'registros' => $r['dias_registro']] : null,
            'delta' => ($p && $r && $p['score'] !== null && $r['score'] !== null) ? round($p['score'] - $r['score'], 1) : null,
            'pouca_base' => !$r || $r['dias_registro'] < 30];
    }
    usort($cm, function ($x, $y) { return strcmp($x['cargo'], $y['cargo']); });
    $rel['cargo_modalidade'] = $cm ?: null;

    // ---- dia da semana ----
    $dow = [];
    for ($d = 1; $d <= 5; $d++) if (isset($g['dow'][$d])) { $f = apiAcumFinal($g['dow'][$d]); $dow[] = ['dia_semana' => $d, 'nome' => ucfirst(API_NOMES_DIA[$d]), 'score' => $f['score'], 'pct_tempo_produtivo' => $f['pct_tempo_produtivo'], 'tempo_ativo_medio_dia_seg' => $f['tempo_ativo_medio_dia_seg'], 'registros' => $f['dias_registro']]; }
    $rel['dia_semana'] = $dow;

    // ---- distribuicao por faixa de score ----
    $cont = []; foreach (relFaixas() as $f) $cont[$f['id']] = 0;
    foreach ($comScore as $p) $cont[relFaixaDe($p['score'])['id']]++;
    $dist = [];
    foreach (relFaixas() as $f) $dist[] = ['faixa' => $f['rotulo'], 'id' => $f['id'], 'colaboradores' => $cont[$f['id']], 'pct' => count($comScore) ? round($cont[$f['id']] * 100 / count($comScore), 1) : 0];
    $rel['distribuicao'] = ['base' => count($comScore), 'faixas' => $dist];

    // ---- alertas ----
    $critico = array_values(array_filter($comScore, function ($p) { return $p['score'] < 30; }));
    $atencao = array_values(array_filter($comScore, function ($p) { return $p['score'] >= 30 && $p['score'] < 50; }));
    $pocos = array_values(array_filter($pessoas, function ($p) { return $p['dias'] < 5; }));
    usort($pocos, function ($x, $y) { return $x['dias'] <=> $y['dias'] ?: strcmp($x['nome'], $y['nome']); });
    $semRh = null;
    if ($temRh) {
        $lista = array_values(array_filter($pessoas, function ($p) { return !$p['rh']; }));
        usort($lista, function ($x, $y) { return $y['dias'] <=> $x['dias'] ?: strcmp($x['nome'], $y['nome']); });
        $regs = 0; foreach ($lista as $p) $regs += $p['dias'];
        $semRh = ['total' => count($lista), 'registros' => $regs, 'pct_registros' => $geral['dias_registro'] > 0 ? round($regs * 100 / $geral['dias_registro'], 1) : null, 'itens' => array_slice($lista, 0, 15)];
    }
    $menores = array_slice($ordenar($cinco, false), 0, 10);
    $melhores = array_slice($ordenar($cinco, true), 0, 10);
    $rel['alertas'] = ['critico' => array_slice($ordenar($critico, false), 0, 50), 'total_critico' => count($critico),
        'atencao' => array_slice($ordenar($atencao, false), 0, 50), 'total_atencao' => count($atencao),
        'acompanhamento' => $menores, 'poucos_dias' => ['total' => count($pocos), 'itens' => array_slice($pocos, 0, 30)], 'sem_rh' => $semRh];
    $rel['top10'] = $melhores;

    // ---- centros de custo ----
    $ccs = [];
    foreach ($g['cc'] as $nome => $a) { $f = apiAcumFinal($a); if ($f['score'] !== null) $ccs[] = ['centro_custo' => $nome, 'score' => $f['score'], 'tempo_ativo_medio_dia_seg' => $f['tempo_ativo_medio_dia_seg'], 'colaboradores' => $f['colaboradores']]; }
    if ($ccs) {
        $asc = $ccs; usort($asc, function ($x, $y) { return $x['score'] <=> $y['score'] ?: strcmp($x['centro_custo'], $y['centro_custo']); });
        $rel['centros_custo'] = ['menores' => array_slice($asc, 0, 10), 'melhores' => array_slice(array_reverse($asc), 0, 10), 'total' => count($ccs)];
    } else $rel['centros_custo'] = null;

    // ---- evolucao diaria ----
    $diario = []; ksort($g['dia']);
    foreach ($g['dia'] as $dia => $a) { $f = apiAcumFinal($a); $diario[] = ['dia' => $dia, 'score' => $f['score'], 'tempo_ativo_medio_dia_seg' => $f['tempo_ativo_medio_dia_seg'], 'registros' => $f['dias_registro']]; }
    $rel['diario'] = $diario;

    // ---- achados e recomendacoes (texto montado por regras, a partir dos numeros) ----
    $achados = [];
    if ($pPres && $pRem && $pPres['score'] !== null && $pRem['score'] !== null) {
        $dif = round($pPres['score'] - $pRem['score'], 1);
        $achados[] = 'Presencial vs. remoto: score médio presencial ' . relFmt($pPres['score']) . ' vs. remoto ' . relFmt($pRem['score']) . ' (diferença de ' . relFmt(abs($dif)) . ' ponto(s)). Cada dia vale pelo local onde o computador ficou mais tempo; ' . relFmt($rel['pct_registros_sem_local']) . '% dos registros ficaram sem local definido e ficam fora desta comparação.';
    }
    foreach ($cm as $c) if ($c['delta'] !== null && !$c['pouca_base'] && abs($c['delta']) >= 5) $achados[] = 'Cargo ' . $c['cargo'] . ': diferença de ' . relFmt($c['delta']) . ' ponto(s) entre presencial e remoto.';
    $achados[] = 'Faixa crítica (< 30): ' . count($critico) . ' colaborador(es). Faixa de atenção (30-50): ' . count($atencao) . ' colaborador(es).';
    if (count($dow) >= 2) {
        $ord = $dow; usort($ord, function ($x, $y) { return $y['score'] <=> $x['score']; });
        $melhorDia = $ord[0]; $piorDia = $ord[count($ord) - 1];
        $achados[] = 'Variação semanal: ' . $melhorDia['nome'] . ' apresenta o melhor desempenho (' . relFmt($melhorDia['score']) . '), enquanto ' . $piorDia['nome'] . ' tem o menor (' . relFmt($piorDia['score']) . ').';
    }
    if ($anterior && $anterior['score'] !== null && $geral['score'] !== null) {
        $d1 = round($geral['score'] - $anterior['score'], 1);
        $achados[] = 'Versus ' . ($tipo === 'semanal' ? 'a semana anterior (' . $anterior['rotulo'] . ')' : relMesNome($anterior['chave'])) . ': score ' . relFmt($geral['score']) . ' vs. ' . relFmt($anterior['score']) . ' (' . ($d1 >= 0 ? '+' : '-') . relFmt(abs($d1)) . '); tempo ativo ' . relHoras($geral['tempo_ativo_medio_dia_seg']) . ' vs. ' . relHoras($anterior['tempo_ativo_medio_dia_seg']) . ' por dia.';
    }
    $naoAtingidas = []; foreach ($rel['indicadores'] as $ind) if (!$ind['atingida']) $naoAtingidas[] = $ind['indicador'];
    $achados[] = count($naoAtingidas) === 0 ? 'Todas as metas do escritório foram atingidas no período.' : count($naoAtingidas) . ' de ' . count($rel['indicadores']) . ' metas do escritório não foram atingidas: ' . implode('; ', $naoAtingidas) . '.';
    if ($temRh && $semRh && $semRh['total'] > 0) $achados[] = 'VERIFICAR - qualidade de dados: ' . $semRh['total'] . ' login(s) sem vínculo com o cadastro do RH respondem por ' . relFmt($semRh['pct_registros']) . '% dos registros do período. Análises por cargo e centro de custo não cobrem esse grupo.';
    if (!$temRh) $achados[] = 'O cadastro do RH ainda não foi importado: as análises por cargo e centro de custo ficam indisponíveis até lá (Administração > Cadastro do RH).';
    $rel['achados'] = $achados;

    $rec = [];
    if (!$temRh) $rec[] = ['titulo' => 'Cadastro do RH', 'texto' => 'Importar o cadastro do RH (cargo, centro de custo e, se houver, jornada) em Administração para liberar o comparativo por cargo, a análise por centro de custo e a conferência de logins sem vínculo.'];
    elseif ($semRh && $semRh['total'] > 0) $rec[] = ['titulo' => 'Vínculo com o cadastro do RH', 'texto' => $semRh['total'] . ' login(s) (' . relFmt($semRh['pct_registros']) . '% dos registros) estão sem vínculo com o RH. Regularizar o vínculo e retirar contas de serviço da base para que as análises por pessoa, cargo e centro de custo cubram o escritório inteiro.'];
    if (count($pocos) > 0) $rec[] = ['titulo' => 'Poucos dias registrados', 'texto' => 'Validar com RH e coordenadores os ' . count($pocos) . ' caso(s) com menos de 5 dias (férias, afastamento, entrada ou saída, conta de serviço) antes de interpretar o score.'];
    if (count($critico) + count($atencao) > 0) $rec[] = ['titulo' => 'Faixas crítica e de atenção', 'texto' => count($critico) . ' colaborador(es) na faixa crítica e ' . count($atencao) . ' na de atenção. Verificar primeiro se há poucos dias registrados (ver acima) e, depois, conversar com os coordenadores sobre carga de trabalho, ferramentas e uso do equipamento.'];
    if (count($menores) > 0) $rec[] = ['titulo' => 'Acompanhamento dos menores scores', 'texto' => 'Conversa de alinhamento com os coordenadores dos ' . count($menores) . ' colaboradores da seção de alertas, verificando carga de trabalho, ferramentas e uso do equipamento.'];
    if ($pPres && $pRem && $pPres['score'] !== null && $pRem['score'] !== null) {
        $dif = round($pPres['score'] - $pRem['score'], 1);
        $rec[] = ['titulo' => 'Presencial e home', 'texto' => abs($dif) < 2 ? 'A diferença entre presencial e remoto é pequena (' . relFmt(abs($dif)) . ' ponto(s)). Não há base nestes dados para revisar a política de home office. O número mede uso do computador, não o resultado do trabalho.' : 'O score é ' . ($dif > 0 ? 'maior no presencial' : 'maior no remoto') . ' em ' . relFmt(abs($dif)) . ' ponto(s). Antes de agir, considerar que audiências, reuniões e atendimentos presenciais não aparecem no computador e que o resultado do trabalho não é medido aqui.'];
    }
    if (count($dow) >= 2) $rec[] = ['titulo' => 'Dia da semana', 'texto' => 'Observar se o padrão por dia da semana (' . $piorDia['nome'] . ' com o menor score) se repete nos próximos períodos antes de definir qualquer ação.'];
    if ($rel['centros_custo']) $rec[] = ['titulo' => 'Centros de custo', 'texto' => 'Analisar individualmente os centros da lista de menor score, descontando os de 1 ou 2 colaboradores (oscilam muito), e considerar carga de trabalho, complexidade das demandas e rotatividade.'];
    if (count($melhores) > 0) $rec[] = ['titulo' => 'Reconhecimento', 'texto' => 'Reconhecer os colaboradores do Top 10, servindo como referência para os demais.'];
    $rel['recomendacoes'] = $rec;
    return $rel;
}

function montarRelatorioMensal(PDO $db, $cfg, $mes, $agora) { return montarRelatorio($db, $cfg, 'mensal', $mes, null, null, $agora); }
