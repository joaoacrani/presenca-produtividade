<?php
// Parte "programas em foco" do relatorio completo.

// Totais de programas em foco por colaborador no periodo (tempo ativo, navegador, e programas por tipo de uso).
function focoPorLogin(PDO $db, $de, $ate)
{
    $regras = carregarRegras($db);
    $st = $db->prepare('SELECT login, processo, SUM(segundos) AS seg FROM foco_dia WHERE dia >= ? AND dia <= ? GROUP BY login, processo');
    $st->execute([$de, $ate]);
    $out = [];
    foreach ($st->fetchAll() as $r) {
        $l = $r['login'];
        if (!isset($out[$l])) $out[$l] = ['ativo' => 0, 'navegador' => 0, 'produtivo' => 0, 'improdutivo' => 0, 'neutro' => 0];
        $seg = (int)$r['seg'];
        $out[$l]['ativo'] += $seg;
        $out[$l][classificarApp($r['processo'], $regras)[0]] += $seg;
    }
    return $out;
}

// Uma linha por colaborador x dia x programa (formato "longo", ideal para tabela dinamica e BI).
function abaProgramas(PDO $db, $cfg, $de, $ate)
{
    $regras = carregarRegras($db);
    $colabs = mapaColaboradores($db);
    $st = $db->prepare('SELECT login, dia, processo, segundos, trocas FROM foco_dia WHERE dia >= ? AND dia <= ? ORDER BY dia, login, segundos DESC LIMIT ' . EXPORT_MAX_LINHAS);
    $st->execute([$de, $ate]);
    $linhas = [];
    while ($r = $st->fetch()) {
        $i = identidade($r['login'], $colabs);
        $linhas[] = [xDia($r['dia']), $i['colaborador'], $i['login'], nomeProgramaAmigavel($r['processo']), $r['processo'],
            tipoUsoApp(classificarApp($r['processo'], $regras)[0]), xDur((int)$r['segundos']), (int)$r['trocas']];
    }
    usort($linhas, function ($a, $b) { return strcasecmp($a[1], $b[1]) ?: strcmp($a[0]['v'], $b[0]['v']) ?: ($b[6]['v'] <=> $a[6]['v']); });
    return ['nome' => 'Programas',
        'cabecalho' => ['Data', 'Colaborador', 'Login', 'Programa', 'Processo', 'Tipo de uso', 'Tempo em foco', 'Segmentos'],
        'larguras' => [12, 38, 16, 26, 22, 20, 13, 10],
        'linhas' => $linhas];
}

// Foco detalhado (so administradores): cada segmento de uso de um programa, com o titulo da janela.
function abaFocoDetalhado(PDO $db, $cfg, $de, $ate)
{
    $tz = fusoDe($cfg);
    $ini = (new DateTimeImmutable($de . ' 00:00:00', $tz))->getTimestamp() * 1000;
    $fim = (new DateTimeImmutable($ate . ' 23:59:59', $tz))->getTimestamp() * 1000;
    $regras = carregarRegras($db);
    $colabs = mapaColaboradores($db);
    $st = $db->prepare('SELECT ts, host, login, processo, titulo, seg FROM foco WHERE ts >= ? AND ts <= ? ORDER BY ts LIMIT ' . EXPORT_MAX_LINHAS);
    $st->execute([$ini, $fim]);
    $linhas = [];
    while ($v = $st->fetch()) {
        $i = identidade($v['login'], $colabs);
        $linhas[] = [xDt((int)$v['ts']), $i['colaborador'], $v['host'], nomeProgramaAmigavel($v['processo']), $v['processo'],
            tipoUsoApp(classificarApp($v['processo'], $regras)[0]), $v['titulo'], xDur((int)$v['seg'])];
    }
    return ['nome' => 'Foco detalhado',
        'cabecalho' => ['Data/hora', 'Colaborador', 'Computador', 'Programa', 'Processo', 'Tipo de uso', 'Título da janela', 'Duração'],
        'larguras' => [17, 38, 16, 22, 20, 20, 70, 10],
        'linhas' => $linhas];
}
