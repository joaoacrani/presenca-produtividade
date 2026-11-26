<?php
// Exportacoes CSV em fluxo (streaming): sem limite de linhas e sem carregar tudo na memoria.
// Servem para o BI/analise do periodo completo quando uma aba do Excel passaria do limite.

function iniciarCsv($nomeArquivo, array $cabecalho)
{
    @set_time_limit(300);
    http_response_code(200);
    cabecalhosBase();
    header('Content-Type: text/csv; charset=utf-8');
    header('Content-Disposition: attachment; filename="' . preg_replace('/[^A-Za-z0-9._-]/', '_', $nomeArquivo) . '"');
    echo "\xEF\xBB\xBF" . implode(';', array_map('celulaCsv', $cabecalho)) . "\r\n";
}

function limitesMs($cfg, $de, $ate)
{
    $tz = fusoDe($cfg);
    return [(new DateTimeImmutable($de . ' 00:00:00', $tz))->getTimestamp() * 1000, (new DateTimeImmutable($ate . ' 23:59:59', $tz))->getTimestamp() * 1000, $tz];
}

function fmtDataHora($tsMs, DateTimeZone $tz)
{
    return (new DateTime('@' . intdiv((int)$tsMs, 1000)))->setTimezone($tz)->format('d/m/Y H:i:s');
}

function csvAcessos(PDO $db, $cfg, $de, $ate)
{
    list($ini, $fim, $tz) = limitesMs($cfg, $de, $ate);
    $regras = carregarRegras($db); $colabs = mapaColaboradores($db);
    iniciarCsv("acessos_{$de}_a_{$ate}.csv", ['Data/hora', 'Colaborador', 'Login', 'Computador', 'Navegador', 'Site', 'Tipo de uso', 'Endereco (sem parametros)', 'Titulo da pagina', 'Duracao (s)']);
    $st = $db->prepare('SELECT ts, host, login, dominio, url, titulo, navegador, duracao_seg FROM navegacao WHERE ts >= ? AND ts <= ? ORDER BY ts');
    $st->execute([$ini, $fim]);
    $n = 0;
    while ($v = $st->fetch()) {
        $i = identidade($v['login'], $colabs);
        echo implode(';', array_map('celulaCsv', [fmtDataHora($v['ts'], $tz), $i['colaborador'], $i['login'], $v['host'], $v['navegador'], $v['dominio'],
            rotuloCategoria(classificarDominio($v['dominio'], $regras)[0]), $v['url'], $v['titulo'], $v['duracao_seg']])) . "\r\n";
        if ((++$n % 2000) === 0) flush();
    }
    exit;
}

function csvFoco(PDO $db, $cfg, $de, $ate)
{
    list($ini, $fim, $tz) = limitesMs($cfg, $de, $ate);
    $regras = carregarRegras($db); $colabs = mapaColaboradores($db);
    iniciarCsv("foco_{$de}_a_{$ate}.csv", ['Data/hora', 'Colaborador', 'Login', 'Computador', 'Programa', 'Processo', 'Tipo de uso', 'Titulo da janela', 'Duracao (s)']);
    $st = $db->prepare('SELECT ts, host, login, processo, titulo, seg FROM foco WHERE ts >= ? AND ts <= ? ORDER BY ts');
    $st->execute([$ini, $fim]);
    $n = 0;
    while ($v = $st->fetch()) {
        $i = identidade($v['login'], $colabs);
        echo implode(';', array_map('celulaCsv', [fmtDataHora($v['ts'], $tz), $i['colaborador'], $i['login'], $v['host'], nomeProgramaAmigavel($v['processo']), $v['processo'],
            tipoUsoApp(classificarApp($v['processo'], $regras)[0]), $v['titulo'], $v['seg']])) . "\r\n";
        if ((++$n % 2000) === 0) flush();
    }
    exit;
}

// Todas as leituras de localizacao (cada leitura de 5 em 5 min), com IP de saida. Para auditoria/BI.
function csvLeituras(PDO $db, $cfg, $de, $ate)
{
    list($ini, $fim, $tz) = limitesMs($cfg, $de, $ate);
    $colabs = mapaColaboradores($db);
    $servidores = mapaServidores($db);
    iniciarCsv("leituras_{$de}_a_{$ate}.csv", ['Data/hora', 'Colaborador (servidor: ultimo usuario logado)', 'Login', 'Computador', 'Servidor', 'Local', 'Unidade', 'VPN', 'IP de saida', 'Confianca', 'Tela bloqueada', 'Ocioso (s)']);
    $st = $db->prepare('SELECT ts, host, login, resultado, unidade, vpn_ativa, ip_saida, confianca, bloqueada, ocioso_seg FROM registros WHERE ts >= ? AND ts <= ? ORDER BY ts');
    $st->execute([$ini, $fim]);
    $n = 0;
    while ($v = $st->fetch()) {
        $i = identidade($v['login'], $colabs);
        echo implode(';', array_map('celulaCsv', [fmtDataHora($v['ts'], $tz), $i['colaborador'], $i['login'], $v['host'], isset($servidores[strtoupper($v['host'])]) ? 'sim' : 'nao', $v['resultado'], $v['unidade'],
            $v['vpn_ativa'], $v['ip_saida'], $v['confianca'], $v['bloqueada'], $v['ocioso_seg']])) . "\r\n";
        if ((++$n % 2000) === 0) flush();
    }
    exit;
}

// Se uma aba do Excel bateu no teto de linhas, avisa na ultima linha (nada some em silencio).
function avisoTeto(array $aba)
{
    if (count($aba['linhas']) >= EXPORT_MAX_LINHAS) {
        $aba['linhas'][] = ['ATENÇÃO: aba limitada a ' . EXPORT_MAX_LINHAS . ' linhas. Para o período completo use a exportação CSV (Administração).'];
    }
    return $aba;
}
