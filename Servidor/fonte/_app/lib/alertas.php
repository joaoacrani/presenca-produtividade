<?php
// Alertas por e-mail: (1) queda de envio dos agents em horario de expediente e (2) falhas de login em sequencia.
// O e-mail de destino e configurado no painel (Administracao > Alertas), nunca no codigo. Envio por mail() da hospedagem.
// 'alerta_arquivo' => caminho no config.php grava os alertas num arquivo em vez de enviar (testes e diagnostico).
// Cada tipo de alerta tem um intervalo minimo entre envios (nao vira spam). Nunca vai senha, codigo ou token no texto.

function alertaConfig(PDO $db)
{
    return ['email' => (string)metaGet($db, 'alerta_email'), 'ativo' => metaGet($db, 'alerta_ativo') === '1'];
}

function alertaEmailValido($e)
{
    return is_string($e) && strlen($e) <= 120 && !preg_match('/[\r\n,;<>]/', $e) && filter_var($e, FILTER_VALIDATE_EMAIL) !== false;
}

// $chave identifica o alerta para o intervalo minimo ($intervaloMs entre dois envios da mesma chave).
// Devolve true se enviou (ou gravou no arquivo de teste).
function enviarAlerta(PDO $db, $cfg, $agora, $chave, $intervaloMs, $assunto, $texto, $forcar = false)
{
    $c = alertaConfig($db);
    if (!$forcar && (!$c['ativo'] || !alertaEmailValido($c['email']))) return false;
    if ($forcar && !alertaEmailValido($c['email'])) return false;
    $k = 'alerta_envio_' . substr(hash('sha256', $chave), 0, 16);
    $ult = (int)metaGet($db, $k);
    if (!$forcar && $ult > 0 && $agora - $ult < $intervaloMs) return false;
    $vez = $db->prepare('INSERT OR REPLACE INTO meta (chave, valor) VALUES (?, ?)');
    $vez->execute([$k, (string)$agora]);
    $assuntoFull = '[Presença] ' . $assunto;
    $corpo = $texto . "\n\n--\nEnviado automaticamente pelo servidor de presença (" . gmdate('d/m/Y H:i', intdiv($agora, 1000)) . " UTC).\nPara parar de receber ou trocar o e-mail: Administração > Alertas por e-mail.\n";
    $ok = false;
    if (!empty($cfg['alerta_arquivo'])) {
        $ok = @file_put_contents($cfg['alerta_arquivo'], json_encode(['para' => $c['email'], 'assunto' => $assuntoFull, 'texto' => $corpo], JSON_UNESCAPED_UNICODE) . "\n", FILE_APPEND | LOCK_EX) !== false;
    } else {
        $host = isset($_SERVER['HTTP_HOST']) ? preg_replace('/[^a-z0-9.-]/i', '', (string)$_SERVER['HTTP_HOST']) : '';
        if ($host === '') $host = 'localhost';
        $hdr = "From: Presenca <alerta@" . $host . ">\r\nContent-Type: text/plain; charset=UTF-8\r\nMIME-Version: 1.0\r\nX-Mailer: presenca-pp";
        $ok = function_exists('mail') && @mail($c['email'], '=?UTF-8?B?' . base64_encode($assuntoFull) . '?=', $corpo, $hdr);
    }
    auditar($db, $agora, '', 'sistema', $ok ? 'alerta_enviado' : 'alerta_falhou', $assunto);
    return $ok;
}

// Falhas de login em sequencia (chamado quando a origem foi bloqueada): no maximo 1 aviso por hora para cada origem.
function alertaFalhasLogin(PDO $db, $cfg, $agora, $ip, $login)
{
    try {
        enviarAlerta($db, $cfg, $agora, 'login|' . $ip, 3600000, 'Várias tentativas de login erradas',
            "O painel bloqueou temporariamente uma origem por tentativas de login erradas em sequência.\n\nIP: " . $ip . "\nUsuário tentado: " . cortar($login, 60) . "\n\nSe não foi você ou alguém da equipe, confira Administração > Auditoria e considere trocar a senha.");
    } catch (Throwable $e) { /* alerta nunca derruba o login */ }
}

// Queda de envio: em horario de expediente (seg a sex, 9h as 18h no fuso do servidor), compara quantos PCs enviaram presenca nos
// ultimos 30 min com quantos enviaram nas 2,5 h anteriores. Se ha base (10+ PCs) e menos da metade continua enviando, avisa.
// Roda no maximo a cada 10 min (a disputa e feita como na limpeza) e e acionado pelos agents e por um verificador externo do /health.
function alertasSeDevido(PDO $db, $cfg, $agora)
{
    $c = alertaConfig($db);
    if (!$c['ativo'] || !alertaEmailValido($c['email'])) return;
    $ult = (string)metaGet($db, 'alerta_check_em');
    if ($ult === '') { $db->prepare('INSERT OR IGNORE INTO meta (chave, valor) VALUES (?, ?)')->execute(['alerta_check_em', '0']); $ult = '0'; }
    if ($agora - (int)$ult < 600000) return;
    $vez = $db->prepare('UPDATE meta SET valor = ? WHERE chave = ? AND valor = ?');
    $vez->execute([(string)$agora, 'alerta_check_em', $ult]);
    if ($vez->rowCount() === 0) return;
    try {
        $dt = (new DateTime('@' . intdiv($agora, 1000)))->setTimezone(fusoDe($cfg));
        $dow = (int)$dt->format('N'); $h = (int)$dt->format('G');
        if ($dow > 5 || $h < 9 || $h >= 18) return;
        $dia = $dt->format('Y-m-d');
        if (in_array($dia, isset($cfg['feriados']) && is_array($cfg['feriados']) ? $cfg['feriados'] : [], true)) return;
        $ate = $agora; $meio = $agora - 1800000; $de = $agora - 9000000;
        $st = $db->prepare('SELECT COUNT(DISTINCT host) FROM registros WHERE ts > ? AND ts <= ?');
        $st->execute([$meio, $ate]); $agoraN = (int)$st->fetchColumn();
        $st->execute([$de, $meio]); $antesN = (int)$st->fetchColumn();
        if ($antesN >= 10 && $agoraN * 2 < $antesN) {
            enviarAlerta($db, $cfg, $agora, 'queda-envio', 3 * 3600000, 'Queda no envio de presença dos PCs',
                "Em horário de expediente, só " . $agoraN . " PC(s) enviaram presença nos últimos 30 minutos, contra " . $antesN . " nas 2h30 anteriores.\n\nPode ser queda do servidor, da internet do escritório ou um problema no agent. Confira o painel (Presença agora) e a Administração > Segurança dos agents.");
        }
    } catch (Throwable $e) { /* o alerta nunca atrapalha o agent */ }
}
