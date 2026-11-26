<?php
// Chamados do HelpDesk (exportados do TomTicket em .xlsx): importacao e relatorio.
// O painel le o .xlsx no navegador e envia so as linhas (como no cadastro do RH). Por privacidade, o texto da mensagem do chamado
// NAO e enviado nem guardado: ficam protocolo, assunto, departamento, atendentes, solicitante, categoria e as datas.
// Os relatorios do TomTicket se sobrepoem (a mesma semana aparece em mais de um arquivo), entao o protocolo e a chave:
// importar de novo atualiza em vez de duplicar, e um valor vazio nunca apaga um valor que ja existe.

const CHAMADOS_MAX_LINHAS = 2000;

function chamadosTexto($v, $max)
{
    $s = is_scalar($v) ? (string)$v : '';
    $t = preg_replace('/\s+/u', ' ', $s);
    if ($t === null) $t = preg_replace('/\s+/', ' ', $s);
    $t = trim((string)$t);
    return $t === '' ? '' : cortar($t, $max);
}

// "AAAA-MM-DD HH:MM:SS" (ou com T, ou so a data), no fuso do servidor, para milissegundos. null se invalida.
function chamadosDataMs($v, DateTimeZone $tz)
{
    if (!is_string($v)) return null;
    $v = trim($v);
    if (!preg_match('/^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?$/', $v, $m)) return null;
    if (!checkdate((int)$m[2], (int)$m[3], (int)$m[1]) || (int)$m[1] < 2000 || (int)$m[1] > 2100) return null;
    $h = isset($m[4]) ? (int)$m[4] : 0; $mi = isset($m[5]) ? (int)$m[5] : 0; $s = isset($m[6]) ? (int)$m[6] : 0;
    if ($h > 23 || $mi > 59 || $s > 59) return null;
    $d = new DateTime(sprintf('%04d-%02d-%02d %02d:%02d:%02d', $m[1], $m[2], $m[3], $h, $mi, $s), $tz);
    return $d->getTimestamp() * 1000;
}

function chamadosImportar(PDO $db, $cfg, array $linhas, $agora)
{
    $tz = fusoDe($cfg);
    $sel = $db->prepare('SELECT assunto, departamento, atendente, finalizador, cliente, categoria, criado_em, finalizado_em FROM chamados WHERE protocolo = ?');
    $ins = $db->prepare('INSERT INTO chamados (protocolo, assunto, departamento, atendente, finalizador, cliente, categoria, criado_em, finalizado_em, importado_em) VALUES (?,?,?,?,?,?,?,?,?,?)');
    $upd = $db->prepare('UPDATE chamados SET assunto = ?, departamento = ?, atendente = ?, finalizador = ?, cliente = ?, categoria = ?, criado_em = ?, finalizado_em = ?, importado_em = ? WHERE protocolo = ?');
    $novos = 0; $atualizados = 0; $iguais = 0; $invalidos = 0; $erros = [];
    $ignorados = max(0, count($linhas) - CHAMADOS_MAX_LINHAS);
    $db->beginTransaction();
    try {
        foreach (array_slice($linhas, 0, CHAMADOS_MAX_LINHAS) as $i => $l) {
            if (!is_array($l)) { $invalidos++; continue; }
            $p = isset($l['protocolo']) ? $l['protocolo'] : null;
            if (!((is_int($p) && $p > 0) || (is_string($p) && ctype_digit($p) && $p !== '' && strlen($p) <= 9 && (int)$p > 0)) || (int)$p > 999999999) {
                $invalidos++; if (count($erros) < 10) $erros[] = 'linha ' . ($i + 1) . ': protocolo invalido';
                continue;
            }
            $p = (int)$p;
            $cri = chamadosDataMs(isset($l['criado']) ? $l['criado'] : null, $tz);
            $fim = chamadosDataMs(isset($l['finalizado']) ? $l['finalizado'] : null, $tz);
            if ($cri !== null && $fim !== null && $fim < $cri) {
                $invalidos++; if (count($erros) < 10) $erros[] = 'protocolo ' . $p . ': finalizado antes de criado';
                continue;
            }
            $novo = [
                chamadosTexto(isset($l['assunto']) ? $l['assunto'] : '', 200), chamadosTexto(isset($l['departamento']) ? $l['departamento'] : '', 80),
                chamadosTexto(isset($l['atendente']) ? $l['atendente'] : '', 80), chamadosTexto(isset($l['finalizador']) ? $l['finalizador'] : '', 80),
                chamadosTexto(isset($l['cliente']) ? $l['cliente'] : '', 120), chamadosTexto(isset($l['categoria']) ? $l['categoria'] : '', 80), $cri, $fim,
            ];
            $sel->execute([$p]);
            $antigo = $sel->fetch(PDO::FETCH_NUM);
            if (!$antigo) {
                $ins->execute(array_merge([$p], $novo, [$agora]));
                $novos++;
                continue;
            }
            $final = [];
            foreach ($novo as $k => $v) {
                $vazio = ($v === '' || $v === null);
                $final[$k] = $vazio ? $antigo[$k] : $v;
            }
            $mudou = false;
            foreach ($final as $k => $v) { if ((string)$v !== (string)$antigo[$k]) { $mudou = true; break; } }
            if (!$mudou) { $iguais++; continue; }
            $upd->execute(array_merge($final, [$agora, $p]));
            $atualizados++;
        }
        $db->commit();
    } catch (Throwable $e) { $db->rollBack(); throw $e; }
    metaSet($db, 'chamados_ultimo_import', (string)$agora);
    return ['ok' => true, 'novos' => $novos, 'atualizados' => $atualizados, 'iguais' => $iguais, 'invalidos' => $invalidos, 'ignorados' => $ignorados, 'erros' => $erros];
}

function chamadosResumoBanco(PDO $db)
{
    $r = $db->query('SELECT COUNT(*) n, MIN(COALESCE(finalizado_em, criado_em)) de, MAX(COALESCE(finalizado_em, criado_em)) ate FROM chamados')->fetch();
    $u = metaGet($db, 'chamados_ultimo_import');
    return ['total' => (int)$r['n'], 'primeiro_ms' => $r['de'] === null ? null : (int)$r['de'], 'ultimo_ms' => $r['ate'] === null ? null : (int)$r['ate'],
        'ultimo_import' => $u === null ? null : (int)$u];
}

function chamadosFaixaMs($de, $ate, DateTimeZone $tz)
{
    $ini = (new DateTime($de . ' 00:00:00', $tz))->getTimestamp() * 1000;
    $fim = (new DateTime($ate . ' 00:00:00', $tz))->modify('+1 day')->getTimestamp() * 1000;
    return [$ini, $fim];
}

// Chamados do periodo. $base: 'finalizacao' (o chamado conta no dia em que foi finalizado) ou 'criacao'.
function chamadosDoPeriodo(PDO $db, $cfg, $de, $ate, $base)
{
    $col = $base === 'criacao' ? 'criado_em' : 'finalizado_em';
    list($ini, $fim) = chamadosFaixaMs($de, $ate, fusoDe($cfg));
    $st = $db->prepare("SELECT protocolo, assunto, departamento, atendente, finalizador, cliente, categoria, criado_em, finalizado_em FROM chamados
        WHERE $col IS NOT NULL AND $col >= ? AND $col < ? ORDER BY $col, protocolo");
    $st->execute([$ini, $fim]);
    return $st->fetchAll();
}

function chamadosMediana(array $v)
{
    $n = count($v);
    if ($n === 0) return null;
    sort($v);
    return $n % 2 ? $v[intdiv($n, 2)] : ($v[$n / 2 - 1] + $v[$n / 2]) / 2;
}

function chamadosKpis(array $linhas)
{
    $tempos = [];
    $final = 0;
    foreach ($linhas as $l) {
        if ($l['finalizado_em'] !== null) $final++;
        if ($l['criado_em'] !== null && $l['finalizado_em'] !== null) $tempos[] = ((int)$l['finalizado_em'] - (int)$l['criado_em']) / 3600000;
    }
    $n = count($tempos);
    return ['total' => count($linhas), 'finalizados' => $final, 'com_tempo' => $n,
        'tempo_medio_h' => $n ? round(array_sum($tempos) / $n, 1) : null,
        'tempo_mediano_h' => $n ? round(chamadosMediana($tempos), 1) : null,
        'pct_ate_24h' => $n ? round(count(array_filter($tempos, function ($t) { return $t <= 24; })) * 100 / $n, 1) : null,
        'pct_ate_72h' => $n ? round(count(array_filter($tempos, function ($t) { return $t <= 72; })) * 100 / $n, 1) : null];
}

// Agrupa por uma chave e devolve [{nome, total, pct, tempo_medio_h}] do maior para o menor.
function chamadosAgrupar(array $linhas, callable $chave, $limite = 0)
{
    $g = [];
    foreach ($linhas as $l) {
        $k = $chave($l);
        if (!isset($g[$k])) $g[$k] = ['n' => 0, 't' => [], ];
        $g[$k]['n']++;
        if ($l['criado_em'] !== null && $l['finalizado_em'] !== null) $g[$k]['t'][] = ((int)$l['finalizado_em'] - (int)$l['criado_em']) / 3600000;
    }
    $total = count($linhas);
    $res = [];
    foreach ($g as $nome => $v) {
        $res[] = ['nome' => (string)$nome, 'total' => $v['n'], 'pct' => $total ? round($v['n'] * 100 / $total, 1) : 0,
            'tempo_medio_h' => $v['t'] ? round(array_sum($v['t']) / count($v['t']), 1) : null];
    }
    usort($res, function ($a, $b) { return $b['total'] <=> $a['total'] ?: strcmp($a['nome'], $b['nome']); });
    return $limite > 0 ? array_slice($res, 0, $limite) : $res;
}

function chamadosRelatorio(PDO $db, $cfg, $de, $ate, $base, $agora)
{
    $tz = fusoDe($cfg);
    $col = $base === 'criacao' ? 'criado_em' : 'finalizado_em';
    $linhas = chamadosDoPeriodo($db, $cfg, $de, $ate, $base);
    $dias = (int)(new DateTime($de))->diff(new DateTime($ate))->days + 1;
    $kpi = chamadosKpis($linhas);
    $kpi['abertos'] = count(array_filter($linhas, function ($l) { return $l['finalizado_em'] === null; }));
    $kpi['sem_categoria'] = count(array_filter($linhas, function ($l) { return $l['categoria'] === ''; }));
    $kpi['por_dia_util'] = $dias > 0 ? round(count($linhas) / max(1, chamadosDiasUteis($de, $ate)), 1) : null;

    // periodo anterior, do mesmo tamanho, para comparar
    $deAnt = (new DateTimeImmutable($de))->modify('-' . $dias . ' days')->format('Y-m-d');
    $ateAnt = (new DateTimeImmutable($de))->modify('-1 day')->format('Y-m-d');
    $ant = chamadosKpis(chamadosDoPeriodo($db, $cfg, $deAnt, $ateAnt, $base));
    $var = $ant['total'] > 0 ? round(($kpi['total'] - $ant['total']) * 100 / $ant['total'], 1) : null;

    $semana = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];
    $porSemana = array_fill(0, 7, 0);
    $serie = [];
    $gran = $dias <= 45 ? 'dia' : ($dias <= 200 ? 'semana' : 'mes');
    foreach ($linhas as $l) {
        $dia = diaLocal((int)$l[$col], $tz);
        $porSemana[(int)(new DateTime($dia))->format('N') - 1]++;
        if ($gran === 'dia') $rot = $dia;
        elseif ($gran === 'mes') $rot = substr($dia, 0, 7);
        else $rot = (new DateTimeImmutable($dia))->modify('monday this week')->format('Y-m-d');
        if (!isset($serie[$rot])) $serie[$rot] = ['rotulo' => $rot, 'total' => 0, 't' => []];
        $serie[$rot]['total']++;
        if ($l['criado_em'] !== null && $l['finalizado_em'] !== null) $serie[$rot]['t'][] = ((int)$l['finalizado_em'] - (int)$l['criado_em']) / 3600000;
    }
    ksort($serie);
    $evolucao = [];
    foreach ($serie as $s) $evolucao[] = ['rotulo' => $s['rotulo'], 'total' => $s['total'], 'tempo_medio_h' => $s['t'] ? round(array_sum($s['t']) / count($s['t']), 1) : null];
    $dow = [];
    foreach ($porSemana as $i => $n) $dow[] = ['dia' => $semana[$i], 'total' => $n];

    return [
        'periodo' => ['de' => $de, 'ate' => $ate, 'base' => $base === 'criacao' ? 'criacao' : 'finalizacao', 'dias' => $dias],
        'resumo' => $kpi,
        'anterior' => ['de' => $deAnt, 'ate' => $ateAnt, 'total' => $ant['total'], 'tempo_medio_h' => $ant['tempo_medio_h'], 'variacao_total_pct' => $var],
        'por_categoria' => chamadosAgrupar($linhas, function ($l) { return $l['categoria'] === '' ? 'Sem categoria' : $l['categoria']; }),
        'por_atendente' => chamadosAgrupar($linhas, function ($l) { $a = $l['finalizador'] !== '' ? $l['finalizador'] : $l['atendente']; return $a === '' ? 'Sem atendente' : $a; }),
        'top_solicitantes' => chamadosAgrupar($linhas, function ($l) { return $l['cliente'] === '' ? 'Sem solicitante' : $l['cliente']; }, 15),
        'por_dia_semana' => $dow,
        'evolucao' => ['granularidade' => $gran, 'serie' => $evolucao],
        'cobertura' => chamadosResumoBanco($db),
        'gerado_em' => (int)$agora,
    ];
}

// Dias de segunda a sexta entre duas datas (inclusive), para a media por dia util.
function chamadosDiasUteis($de, $ate)
{
    $n = 0;
    $d = new DateTimeImmutable($de);
    $fim = new DateTimeImmutable($ate);
    while ($d <= $fim) { if ((int)$d->format('N') <= 5) $n++; $d = $d->modify('+1 day'); }
    return $n;
}

// Abas do Excel: indicadores, por categoria, por atendente e a lista de chamados do periodo.
function chamadosAbasXlsx(PDO $db, $cfg, $de, $ate, $base, $agora)
{
    $r = chamadosRelatorio($db, $cfg, $de, $ate, $base, $agora);
    $k = $r['resumo'];
    $res = [
        ['Período', relDiaBR($de) . ' a ' . relDiaBR($ate)], ['Base da contagem', $r['periodo']['base'] === 'criacao' ? 'Data de criação' : 'Data de finalização'],
        ['Chamados', $k['total']], ['Finalizados', $k['finalizados']], ['Sem finalização', $k['abertos']], ['Sem categoria', $k['sem_categoria']],
        ['Média por dia útil', $k['por_dia_util']], ['Tempo médio até finalizar (h)', $k['tempo_medio_h']], ['Tempo mediano (h)', $k['tempo_mediano_h']],
        ['Finalizados em até 24 h (%)', $k['pct_ate_24h']], ['Finalizados em até 72 h (%)', $k['pct_ate_72h']],
        ['Chamados no período anterior', $r['anterior']['total']], ['Variação (%)', $r['anterior']['variacao_total_pct']],
    ];
    $grupo = function ($nome, $lista, $rotulo) {
        $linhas = [];
        foreach ($lista as $g) $linhas[] = [$g['nome'], $g['total'], $g['pct'], $g['tempo_medio_h']];
        return ['nome' => $nome, 'cabecalho' => [$rotulo, 'Chamados', '% do total', 'Tempo médio (h)'], 'larguras' => [42, 11, 11, 15], 'linhas' => $linhas];
    };
    $lista = [];
    foreach (chamadosDoPeriodo($db, $cfg, $de, $ate, $base) as $l) {
        $seg = ($l['criado_em'] !== null && $l['finalizado_em'] !== null) ? intdiv((int)$l['finalizado_em'] - (int)$l['criado_em'], 1000) : null;
        $lista[] = [(int)$l['protocolo'], $l['assunto'], $l['cliente'], $l['atendente'], $l['finalizador'], $l['categoria'],
            xDt($l['criado_em'] === null ? null : (int)$l['criado_em']), xDt($l['finalizado_em'] === null ? null : (int)$l['finalizado_em']), xDur($seg)];
    }
    return [
        ['nome' => 'Indicadores', 'cabecalho' => ['Indicador', 'Valor'], 'larguras' => [38, 26], 'linhas' => $res],
        $grupo('Por categoria', $r['por_categoria'], 'Categoria'), $grupo('Por atendente', $r['por_atendente'], 'Atendente'),
        $grupo('Quem mais abriu', $r['top_solicitantes'], 'Solicitante'),
        ['nome' => 'Chamados', 'cabecalho' => ['Protocolo', 'Assunto', 'Solicitante', 'Atendente', 'Finalizador', 'Categoria', 'Criado em', 'Finalizado em', 'Tempo até finalizar'],
            'larguras' => [11, 60, 30, 26, 26, 30, 18, 18, 16], 'linhas' => $lista],
    ];
}
