<?php
// Inventario de maquinas: dados coletados pelo agent (modelo, serie, SO, RAM, disco, IP) + campos de controle
// preenchidos por pessoas (status, responsavel, localizacao, comentarios). Importa/exporta no modelo do "Relatorio de Ativos".

const INV_STATUS = ['DISPONÍVEL', 'INDISPONÍVEL', 'REPARO', 'INUTILIZÁVEL'];
// campos coletados pelo agent que viram historico quando mudam (troca de memoria, disco, SO, placa...)
const INV_CAMPOS_HIST = ['modelo' => 'Modelo', 'serie' => 'Número de série', 'so_exibicao' => 'Versão do Windows', 'so' => 'Sistema operacional', 'ram_gb' => 'Memória (GB)',
    'disco_total_gb' => 'Armazenamento (GB)', 'tipo' => 'Tipo'];

function invUpper($s) { return function_exists('mb_strtoupper') ? mb_strtoupper(trim((string)$s), 'UTF-8') : strtoupper(trim((string)$s)); }

function invChave($s) { return invUpper($s); }

// "Dell Inc." -> "DELL"
function invFabricante($s)
{
    $s = trim((string)$s);
    $s = preg_replace('/[\s,]*\b(inc|corp|corporation|co|ltd|llc|gmbh)\b\.?$/i', '', $s);
    $s = preg_replace('/[\s,]*\b(inc|corp|corporation|co|ltd|llc|gmbh)\b\.?$/i', '', $s);
    return invUpper($s);
}

function invTexto($v, $max = 200) { return trim(cortar(is_scalar($v) ? (string)$v : '', $max)); }
function invInt($v) { return is_numeric($v) ? (int)round((float)$v) : 0; }

function invNomeAtivo($tipo, $fabricante)
{
    return trim(invUpper($tipo) . ' ' . invUpper($fabricante));
}

// Corpo do agent (POST /api/inventario). Mantem os campos de controle (status etc.) intactos.
function gravarInventario(PDO $db, $b, $agora)
{
    if (!is_array($b)) return ['erro' => 'corpo invalido'];
    $host = invTexto(isset($b['host']) ? $b['host'] : '', 100);
    if ($host === '') return ['erro' => 'host obrigatorio'];
    $chave = invChave($host);
    $discos = [];
    if (isset($b['discos']) && is_array($b['discos'])) {
        foreach (array_slice($b['discos'], 0, 8) as $d) {
            if (is_array($d)) $discos[] = ['modelo' => invTexto(isset($d['modelo']) ? $d['modelo'] : '', 80), 'tipo' => invTexto(isset($d['tipo']) ? $d['tipo'] : '', 20), 'gb' => invInt(isset($d['gb']) ? $d['gb'] : 0)];
        }
    }
    $ips = [];
    if (isset($b['ips']) && is_array($b['ips'])) foreach (array_slice($b['ips'], 0, 6) as $ip) if (is_string($ip) && filter_var($ip, FILTER_VALIDATE_IP)) $ips[] = $ip;
    $novo = [
        'host' => $host,
        'fabricante' => invFabricante(isset($b['fabricante']) ? $b['fabricante'] : ''),
        'modelo' => invUpper(invTexto(isset($b['modelo']) ? $b['modelo'] : '', 100)),
        'serie' => invUpper(invTexto(isset($b['serie']) ? $b['serie'] : '', 60)),
        'tipo' => invUpper(invTexto(isset($b['tipo']) ? $b['tipo'] : '', 20)),
        'so' => invTexto(isset($b['so']) ? $b['so'] : '', 80),
        'so_versao' => invTexto(isset($b['so_versao']) ? $b['so_versao'] : '', 30),
        'so_exibicao' => invTexto(isset($b['so_exibicao']) ? $b['so_exibicao'] : '', 20),
        'so_arquitetura' => invTexto(isset($b['so_arquitetura']) ? $b['so_arquitetura'] : '', 20),
        'so_instalado_em' => invTexto(isset($b['so_instalado_em']) ? $b['so_instalado_em'] : '', 12),
        'cpu' => invTexto(isset($b['cpu']) ? $b['cpu'] : '', 100),
        'ram_gb' => invInt(isset($b['ram_gb']) ? $b['ram_gb'] : 0),
        'discos' => json_encode($discos, JSON_UNESCAPED_UNICODE),
        'disco_total_gb' => invInt(isset($b['disco_total_gb']) ? $b['disco_total_gb'] : 0),
        'disco_c_total_gb' => invInt(isset($b['disco_c_total_gb']) ? $b['disco_c_total_gb'] : 0),
        'disco_c_livre_gb' => invInt(isset($b['disco_c_livre_gb']) ? $b['disco_c_livre_gb'] : 0),
        'ips' => implode(', ', $ips),
        'mac' => invTexto(isset($b['mac']) ? $b['mac'] : '', 30),
        'dominio' => invTexto(isset($b['dominio']) ? $b['dominio'] : '', 80),
        'bios_versao' => invTexto(isset($b['bios_versao']) ? $b['bios_versao'] : '', 40),
        'ultimo_boot' => invTexto(isset($b['ultimo_boot']) ? $b['ultimo_boot'] : '', 40),
    ];
    $st = $db->prepare('SELECT * FROM inventario WHERE chave = ?');
    $st->execute([$chave]);
    $atual = $st->fetch();
    $db->beginTransaction();
    try {
        if (!$atual) {
            $cols = array_keys($novo);
            $ins = $db->prepare('INSERT INTO inventario (chave, num_inventario, nome_ativo, status, responsavel, localizacao, comentarios, coletado_em, origem, criado_em, atualizado_em, '
                . implode(', ', $cols) . ') VALUES (?,?,?,?,?,?,?,?,?,?,?,' . implode(',', array_fill(0, count($cols), '?')) . ')');
            $ins->execute(array_merge([$chave, $host, invNomeAtivo($novo['tipo'], $novo['fabricante']), '', '', '', '', $agora, 'agente', $agora, $agora], array_values($novo)));
            $alterados = 0;
        } else {
            $alterados = 0;
            $h = $db->prepare('INSERT INTO inventario_hist (chave, ts, campo, antigo, novo) VALUES (?,?,?,?,?)');
            foreach (INV_CAMPOS_HIST as $campo => $rotulo) {
                $velho = (string)$atual[$campo]; $nv = (string)$novo[$campo];
                if ($velho !== '' && $velho !== '0' && $nv !== '' && $nv !== '0' && $velho !== $nv) { $h->execute([$chave, $agora, $rotulo, $velho, $nv]); $alterados++; }
            }
            // dados do agent sempre valem (e preenchem o que a importacao deixou em branco); campos de controle nao mudam
            $sets = []; $args = [];
            foreach ($novo as $c => $v) {
                // nao apaga um dado bom por causa de uma coleta que falhou em um campo
                if (($v === '' || $v === 0 || $v === '[]') && $atual[$c] !== null && $atual[$c] !== '' && $atual[$c] !== '0') continue;
                $sets[] = $c . ' = ?'; $args[] = $v;
            }
            $sets[] = 'coletado_em = ?'; $args[] = $agora;
            $sets[] = 'atualizado_em = ?'; $args[] = $agora;
            $sets[] = "origem = CASE WHEN origem = 'importacao' THEN 'ambos' ELSE origem END";
            if ($atual['nome_ativo'] === null || $atual['nome_ativo'] === '') { $sets[] = 'nome_ativo = ?'; $args[] = invNomeAtivo($novo['tipo'], $novo['fabricante']); }
            $args[] = $chave;
            $db->prepare('UPDATE inventario SET ' . implode(', ', $sets) . ' WHERE chave = ?')->execute($args);
        }
        $db->commit();
    } catch (Throwable $e) { $db->rollBack(); throw $e; }
    return ['ok' => true, 'novo' => !$atual, 'alteracoes' => $alterados];
}

// Linhas do inventario com o que o servidor sabe da maquina (ultimo contato, IP de saida, ultimo usuario, unidade).
function listarInventario(PDO $db, $agora)
{
    $rows = $db->query('SELECT * FROM inventario ORDER BY chave')->fetchAll();
    $visto = [];
    foreach ($db->query('SELECT host, versao, visto_em FROM agentes') as $r) $visto[invChave($r['host'])] = $r;
    $ult = [];
    $q = 'SELECT r.host, r.ip_saida, r.login, r.nome, r.unidade, r.resultado, r.ts FROM registros r
        JOIN (SELECT host, MAX(ts) AS mts FROM registros GROUP BY host) m ON m.host = r.host AND m.mts = r.ts';
    foreach ($db->query($q) as $r) $ult[invChave($r['host'])] = $r;
    $servidores = mapaServidores($db);
    $bats = [];
    foreach (mapaBatimentos($db) as $h => $b) $bats[invChave($h)] = $b;
    $remotos = remotoIds($db);
    $remotoEst = remotoEstados($db);
    $out = [];
    foreach ($rows as $r) {
        $k = $r['chave'];
        $u = isset($ult[$k]) ? $ult[$k] : null;
        $v = isset($visto[$k]) ? $visto[$k] : null;
        $contato = $u ? (int)$u['ts'] : null;
        // servidor: o batimento (tarefa SYSTEM) conta como contato mesmo sem ninguem logado
        if (isset($bats[$k]) && isset($servidores[$k])) $contato = max((int)$contato, $bats[$k]['visto']);
        $discos = json_decode((string)$r['discos'], true);
        $out[] = [
            'chave' => $k, 'num_inventario' => (string)$r['num_inventario'], 'host' => (string)$r['host'], 'nome_ativo' => (string)$r['nome_ativo'],
            'status' => (string)$r['status'], 'fabricante' => (string)$r['fabricante'], 'serie' => (string)$r['serie'], 'tipo' => (string)$r['tipo'], 'modelo' => (string)$r['modelo'],
            'responsavel' => (string)$r['responsavel'], 'localizacao' => (string)$r['localizacao'], 'comentarios' => (string)$r['comentarios'],
            'so' => (string)$r['so'], 'so_versao' => (string)$r['so_versao'], 'so_exibicao' => (string)$r['so_exibicao'], 'so_arquitetura' => (string)$r['so_arquitetura'], 'so_instalado_em' => (string)$r['so_instalado_em'],
            'cpu' => (string)$r['cpu'], 'ram_gb' => (int)$r['ram_gb'], 'discos' => is_array($discos) ? $discos : [], 'disco_total_gb' => (int)$r['disco_total_gb'],
            'disco_c_total_gb' => (int)$r['disco_c_total_gb'], 'disco_c_livre_gb' => (int)$r['disco_c_livre_gb'],
            'ips' => (string)$r['ips'], 'mac' => (string)$r['mac'], 'dominio' => (string)$r['dominio'], 'bios_versao' => (string)$r['bios_versao'], 'ultimo_boot' => (string)$r['ultimo_boot'],
            'coletado_em' => $r['coletado_em'] === null ? null : (int)$r['coletado_em'], 'origem' => (string)$r['origem'],
            'tem_agente' => $contato !== null || $v !== null || in_array((string)$r['origem'], ['agente', 'ambos'], true),
            'agente_versao' => $v ? (string)$v['versao'] : '',
            'ultimo_contato' => $contato, 'ip_saida' => $u ? (string)$u['ip_saida'] : '', 'unidade' => $u ? (string)$u['unidade'] : '',
            'ultimo_usuario' => $u ? nomeExibicao((string)$u['login'], (string)$u['nome']) : '',
            'servidor' => isset($servidores[$k]),
            'remoto_id' => isset($remotos[$k]) ? $remotos[$k]['id'] : '',
            'remoto_estado' => isset($remotoEst[$k]) ? $remotoEst[$k]['estado'] : '',
            'remoto_estado_detalhe' => isset($remotoEst[$k]) ? $remotoEst[$k]['detalhe'] : '',
            'remoto_estado_em' => isset($remotoEst[$k]) ? $remotoEst[$k]['em'] : null,
        ];
    }
    return $out;
}

// Campos de controle (admin). Cria o ativo se nao existir (ex.: equipamento novo em estoque, ainda sem agent).
function salvarInventarioManual(PDO $db, $j, $agora)
{
    $chave = invChave(isset($j['chave']) ? $j['chave'] : (isset($j['num_inventario']) ? $j['num_inventario'] : ''));
    if ($chave === '' || strlen($chave) > 60) return ['erro' => 'numero de inventario obrigatorio'];
    $campos = ['status' => 40, 'responsavel' => 150, 'localizacao' => 80, 'comentarios' => 1000, 'nome_ativo' => 120, 'fabricante' => 60, 'modelo' => 100, 'serie' => 60, 'tipo' => 20];
    $st = $db->prepare('SELECT chave FROM inventario WHERE chave = ?');
    $st->execute([$chave]);
    $existe = $st->fetchColumn() !== false;
    $vals = [];
    foreach ($campos as $c => $max) {
        if (!array_key_exists($c, $j)) continue;
        $v = invTexto($j[$c], $max);
        if (in_array($c, ['status', 'fabricante', 'modelo', 'serie', 'tipo'], true)) $v = invUpper($v);
        $vals[$c] = $v;
    }
    if (isset($vals['status']) && $vals['status'] !== '' && !in_array($vals['status'], INV_STATUS, true)) return ['erro' => 'status invalido (' . implode(', ', INV_STATUS) . ')'];
    if (!$existe) {
        $db->prepare('INSERT INTO inventario (chave, num_inventario, origem, criado_em, atualizado_em) VALUES (?,?,?,?,?)')->execute([$chave, $chave, 'manual', $agora, $agora]);
    }
    if ($vals) {
        $sets = []; $args = [];
        foreach ($vals as $c => $v) { $sets[] = $c . ' = ?'; $args[] = $v; }
        $sets[] = 'atualizado_em = ?'; $args[] = $agora; $args[] = $chave;
        $db->prepare('UPDATE inventario SET ' . implode(', ', $sets) . ' WHERE chave = ?')->execute($args);
    }
    return ['ok' => true, 'chave' => $chave, 'novo' => !$existe];
}

function invSemAcento($s)
{
    $s = invUpper($s);
    return strtr($s, ['Á' => 'A', 'À' => 'A', 'Â' => 'A', 'Ã' => 'A', 'É' => 'E', 'Ê' => 'E', 'Í' => 'I', 'Ó' => 'O', 'Ô' => 'O', 'Õ' => 'O', 'Ú' => 'U', 'Ç' => 'C']);
}

// Importa um CSV no modelo do "Relatorio de Ativos" (Nome; Status; Fabricante; Numero de serie; Tipo; Modelo;
// Nome alternativo do usuario; Numero de inventario; Localizacao; Comentarios).
// $sobrescrever=false: so preenche o que esta vazio; true: o CSV manda nos campos de controle.
function importarInventarioCsv(PDO $db, $texto, $agora, $sobrescrever)
{
    $texto = preg_replace('/^\xEF\xBB\xBF/', '', (string)$texto);
    $fp = fopen('php://memory', 'r+');
    fwrite($fp, $texto);
    rewind($fp);
    $primeira = fgets($fp);
    if ($primeira === false) { fclose($fp); return ['erro' => 'arquivo vazio']; }
    $delim = substr_count($primeira, ';') >= substr_count($primeira, ',') ? ';' : ',';
    rewind($fp);
    $cab = fgetcsv($fp, 0, $delim);
    $mapa = [];
    $alias = ['NOME' => 'nome_ativo', 'STATUS' => 'status', 'FABRICANTE' => 'fabricante', 'NUMERO DE SERIE' => 'serie', 'TIPO' => 'tipo', 'MODELO' => 'modelo',
        'NOME ALTERNATIVO DO USUARIO' => 'responsavel', 'NUMERO DE INVENTARIO' => 'num_inventario', 'LOCALIZACAO' => 'localizacao', 'COMENTARIOS' => 'comentarios'];
    foreach ((array)$cab as $i => $nome) { $k = invSemAcento($nome); if (isset($alias[$k])) $mapa[$alias[$k]] = $i; }
    if (!isset($mapa['num_inventario'])) { fclose($fp); return ['erro' => 'coluna "Número de inventário" não encontrada']; }
    $r = ['novos' => 0, 'atualizados' => 0, 'iguais' => 0, 'ignorados' => 0, 'status_invalidos' => 0];
    $st = $db->prepare('SELECT * FROM inventario WHERE chave = ?');
    $db->beginTransaction();
    try {
        while (($lin = fgetcsv($fp, 0, $delim)) !== false) {
            if (count($lin) === 1 && trim((string)$lin[0]) === '') continue;
            $num = invTexto(isset($lin[$mapa['num_inventario']]) ? $lin[$mapa['num_inventario']] : '', 60);
            if ($num === '') { $r['ignorados']++; continue; }
            $chave = invChave($num);
            $v = [];
            foreach ($mapa as $c => $i) {
                if ($c === 'num_inventario') continue;
                $max = ['comentarios' => 1000, 'responsavel' => 150, 'nome_ativo' => 120, 'modelo' => 100][$c] ?? 80;
                $x = invTexto(isset($lin[$i]) ? $lin[$i] : '', $max);
                if (in_array($c, ['status', 'fabricante', 'modelo', 'serie', 'tipo'], true)) $x = invUpper($x);
                $v[$c] = $x;
            }
            if (isset($v['status']) && $v['status'] !== '' && !in_array($v['status'], INV_STATUS, true)) { $r['status_invalidos']++; $v['status'] = ''; }
            $st->execute([$chave]);
            $atual = $st->fetch();
            if (!$atual) {
                $cols = array_keys($v);
                $db->prepare('INSERT INTO inventario (chave, num_inventario, origem, criado_em, atualizado_em, ' . implode(', ', $cols) . ') VALUES (?,?,?,?,?,' . implode(',', array_fill(0, count($cols), '?')) . ')')
                   ->execute(array_merge([$chave, $num, 'importacao', $agora, $agora], array_values($v)));
                $r['novos']++;
                continue;
            }
            $sets = []; $args = [];
            foreach ($v as $c => $x) {
                if ($x === '') continue; // nunca apaga com campo vazio do CSV
                $ant = (string)$atual[$c];
                $dadoDoAgent = in_array($c, ['fabricante', 'modelo', 'serie', 'tipo'], true); // o que o agent coletou vale mais que o CSV
                if ($ant === $x) continue;
                if ($ant !== '' && ($dadoDoAgent || !$sobrescrever)) continue;
                $sets[] = $c . ' = ?'; $args[] = $x;
            }
            if (!$sets) { $r['iguais']++; continue; }
            $sets[] = 'atualizado_em = ?'; $args[] = $agora; $args[] = $chave;
            $db->prepare('UPDATE inventario SET ' . implode(', ', $sets) . ' WHERE chave = ?')->execute($args);
            $r['atualizados']++;
        }
        $db->commit();
    } catch (Throwable $e) { $db->rollBack(); fclose($fp); throw $e; }
    fclose($fp);
    return ['ok' => true] + $r;
}

function invResumoDisco(array $a)
{
    $p = [];
    foreach ($a['discos'] as $d) $p[] = trim($d['tipo'] . ' ' . $d['gb'] . ' GB');
    return implode(' + ', $p);
}

// Colunas do relatorio: as 10 primeiras sao exatamente as do modelo "Relatorio de Ativos"; depois, o que o agent coleta.
function invColunasRelatorio()
{
    return ['Nome', 'Status', 'Fabricante', 'Número de série', 'Tipo', 'Modelo', 'Nome alternativo do usuário', 'Número de inventário', 'Localização', 'Comentários',
        'Sistema operacional', 'Versão do Windows', 'Processador', 'Memória (GB)', 'Armazenamento', 'Livre em C: (GB)', 'IP local', 'IP de saída', 'MAC', 'Domínio',
        'Unidade (agente)', 'Último usuário logado', 'Último contato', 'Versão do agente'];
}

function invLinhaRelatorio(array $a, DateTimeZone $tz, $comoXlsx)
{
    $dt = function ($ts) use ($tz, $comoXlsx) {
        if ($ts === null) return $comoXlsx ? null : '';
        return $comoXlsx ? xDt($ts) : (new DateTime('@' . intdiv($ts, 1000)))->setTimezone($tz)->format('d/m/Y H:i');
    };
    return [$a['nome_ativo'], $a['status'], $a['fabricante'], $a['serie'], $a['tipo'], $a['modelo'], $a['responsavel'], $a['num_inventario'] !== '' ? $a['num_inventario'] : $a['chave'], $a['localizacao'], $a['comentarios'],
        trim($a['so'] . ($a['so_exibicao'] !== '' ? ' ' . $a['so_exibicao'] : '')), $a['so_versao'], $a['cpu'], $a['ram_gb'] ?: ($comoXlsx ? null : ''), invResumoDisco($a),
        $a['disco_c_total_gb'] ? $a['disco_c_livre_gb'] : ($comoXlsx ? null : ''), $a['ips'], $a['ip_saida'], $a['mac'], $a['dominio'],
        $a['unidade'], $a['ultimo_usuario'], $dt($a['ultimo_contato']), $a['agente_versao']];
}

function abaInventario(PDO $db, $cfg, $agora)
{
    $tz = fusoDe($cfg);
    $linhas = [];
    foreach (listarInventario($db, $agora) as $a) $linhas[] = invLinhaRelatorio($a, $tz, true);
    return ['nome' => 'Ativos', 'cabecalho' => invColunasRelatorio(),
        'larguras' => [30, 14, 12, 16, 12, 24, 36, 16, 16, 40, 24, 14, 32, 10, 26, 10, 18, 16, 18, 20, 10, 36, 17, 10],
        'linhas' => $linhas];
}

function abaInventarioHistorico(PDO $db, $cfg)
{
    $tz = fusoDe($cfg);
    $linhas = [];
    foreach ($db->query('SELECT chave, ts, campo, antigo, novo FROM inventario_hist ORDER BY ts DESC LIMIT 20000') as $r) {
        $linhas[] = [xDt((int)$r['ts']), $r['chave'], $r['campo'], $r['antigo'], $r['novo']];
    }
    return ['nome' => 'Alterações de hardware', 'cabecalho' => ['Quando', 'Máquina', 'Campo', 'Antes', 'Depois'], 'larguras' => [17, 16, 24, 30, 30], 'linhas' => $linhas];
}
