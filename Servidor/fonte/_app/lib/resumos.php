<?php
// Servidores nao entram nas contas por colaborador: lista, marcacao e recalculo dos resumos diarios.

// Verdadeiro se o host esta marcado como servidor (compara sem diferenciar maiusculas).
function ehServidor(PDO $db, $host)
{
    static $cache = [];
    $k = spl_object_id($db) . '|' . strtoupper((string)$host);
    if (!isset($cache[$k])) {
        $st = $db->prepare('SELECT 1 FROM servidores WHERE UPPER(host) = UPPER(?)');
        $st->execute([(string)$host]);
        $cache[$k] = $st->fetchColumn() !== false;
    }
    return $cache[$k];
}

function limparCacheServidores() { /* o cache e por requisicao; nada a fazer */ }

// Refaz presenca_dia, nav_dia e foco_dia a partir dos dados brutos, SEM as leituras de servidores.
// So refaz os dias completos que ainda tem dados brutos (a retencao dos brutos e menor que a dos resumos);
// dias mais antigos ficam como estao (nao ha como separar o que veio de servidor).
function reconstruirResumos(PDO $db, $cfg, $agora)
{
    $tz = fusoDe($cfg);
    $off = $tz->getOffset(new DateTime('@' . intdiv($agora, 1000)));
    $servs = array_keys(mapaServidores($db));
    $marcas = $servs ? implode(',', array_fill(0, count($servs), '?')) : "''";
    $filtroHost = $servs ? ' AND UPPER(host) NOT IN (' . $marcas . ')' : '';
    $res = [];

    $primeiroDiaCompleto = function ($tabela) use ($db, $tz) {
        $min = $db->query('SELECT MIN(ts) FROM ' . $tabela)->fetchColumn();
        if ($min === null || $min === false) return null;
        return (new DateTimeImmutable(diaLocal((int)$min, $tz), $tz))->modify('+1 day')->format('Y-m-d');
    };

    $db->beginTransaction();
    try {
        // presenca
        $d0 = $primeiroDiaCompleto('registros');
        $res['presenca_dia'] = ['a_partir_de' => $d0, 'linhas' => 0];
        if ($d0 !== null) {
            $db->prepare('DELETE FROM presenca_dia WHERE dia >= ?')->execute([$d0]);
            $ini = (new DateTimeImmutable($d0 . ' 00:00:00', $tz))->getTimestamp() * 1000;
            $st = $db->prepare('SELECT login, date((ts / 1000) + ?, \'unixepoch\') AS dia, resultado, unidade, COUNT(*) AS n
                FROM registros WHERE ts >= ?' . $filtroHost . ' GROUP BY login, dia, resultado, unidade');
            $st->execute(array_merge([$off, $ini], $servs));
            $acum = [];
            foreach ($st->fetchAll() as $r) {
                $login = $r['login'] !== null && $r['login'] !== '' ? $r['login'] : '';
                if ($login === '') continue;
                $un = ehPresencial($r['resultado']) ? (string)$r['unidade'] : '';
                $k = $login . '|' . $r['dia'] . '|' . $r['resultado'] . '|' . $un;
                $acum[$k] = (isset($acum[$k]) ? $acum[$k] : 0) + (int)$r['n'];
            }
            $ins = $db->prepare('INSERT INTO presenca_dia (login, dia, resultado, unidade, n) VALUES (?,?,?,?,?)');
            foreach ($acum as $k => $n) { list($l, $d, $rs, $un) = explode('|', $k, 4); $ins->execute([$l, $d, $rs, $un, $n]); $res['presenca_dia']['linhas']++; }
        }
        // sites
        $d0 = $primeiroDiaCompleto('navegacao');
        $res['nav_dia'] = ['a_partir_de' => $d0, 'linhas' => 0];
        if ($d0 !== null) {
            $db->prepare('DELETE FROM nav_dia WHERE dia >= ?')->execute([$d0]);
            $ini = (new DateTimeImmutable($d0 . ' 00:00:00', $tz))->getTimestamp() * 1000;
            $st = $db->prepare('INSERT INTO nav_dia (login, dia, dominio, visitas, segundos)
                SELECT login, date((ts / 1000) + ?, \'unixepoch\') AS dia, dominio, COUNT(*), SUM(duracao_seg)
                FROM navegacao WHERE ts >= ?' . $filtroHost . ' GROUP BY login, dia, dominio');
            $st->execute(array_merge([$off, $ini], $servs));
            $res['nav_dia']['linhas'] = $st->rowCount();
        }
        // programas
        $d0 = $primeiroDiaCompleto('foco');
        $res['foco_dia'] = ['a_partir_de' => $d0, 'linhas' => 0];
        if ($d0 !== null) {
            $db->prepare('DELETE FROM foco_dia WHERE dia >= ?')->execute([$d0]);
            $ini = (new DateTimeImmutable($d0 . ' 00:00:00', $tz))->getTimestamp() * 1000;
            $st = $db->prepare('SELECT login, date((ts / 1000) + ?, \'unixepoch\') AS dia, LOWER(processo) AS p, SUM(seg) AS s, COUNT(*) AS n
                FROM foco WHERE ts >= ?' . $filtroHost . ' GROUP BY login, dia, p');
            $st->execute(array_merge([$off, $ini], $servs));
            $ins = $db->prepare('INSERT INTO foco_dia (login, dia, processo, segundos, trocas) VALUES (?,?,?,?,?)');
            foreach ($st->fetchAll() as $r) { $ins->execute([$r['login'], $r['dia'], $r['p'], (int)$r['s'], (int)$r['n']]); $res['foco_dia']['linhas']++; }
        }
        $db->commit();
    } catch (Throwable $e) {
        $db->rollBack();
        throw $e;
    }
    return $res;
}
