<?php
// Utilidades comuns. Compativel com PHP >= 7.4.

function cabecalhosBase()
{
    header('X-Content-Type-Options: nosniff');
    header('Referrer-Policy: no-referrer');
    header('Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()');
    header('Cross-Origin-Opener-Policy: same-origin');
    header('Cross-Origin-Resource-Policy: same-origin');
    header('Cache-Control: no-store');
    if (ehHttps()) header('Strict-Transport-Security: max-age=31536000'); // so HTTPS; sem includeSubDomains (o dominio tem outros sites)
    header("Content-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'");
}

function responderJson($status, $dados)
{
    http_response_code($status);
    cabecalhosBase();
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($dados, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

function cortar($v, $max)
{
    if ($v === null || is_array($v) || is_object($v)) return '';
    $s = (string)$v;
    if (function_exists('mb_substr')) return mb_substr($s, 0, $max, 'UTF-8');
    return preg_match('/^.{0,' . (int)$max . '}/su', $s, $m) ? $m[0] : '';
}

function iguais($a, $b)
{
    return hash_equals(hash('sha256', (string)$a, true), hash('sha256', (string)$b, true));
}

function cabecalhoAuth()
{
    foreach (['HTTP_AUTHORIZATION', 'REDIRECT_HTTP_AUTHORIZATION'] as $k) {
        if (!empty($_SERVER[$k])) return $_SERVER[$k];
    }
    if (function_exists('getallheaders')) {
        foreach (getallheaders() as $k => $v) {
            if (strcasecmp($k, 'Authorization') === 0 && $v !== '') return $v;
        }
    }
    return '';
}

function cabecalhoReq($nome)
{
    $k = strtoupper(str_replace('-', '_', $nome));
    // Content-Type e Content-Length chegam sem o prefixo HTTP_ em Apache/CGI/FastCGI
    foreach (['HTTP_' . $k, $k] as $chave) {
        if (!empty($_SERVER[$chave])) return (string)$_SERVER[$chave];
    }
    return '';
}

function lerCorpo($max)
{
    $c = file_get_contents('php://input', false, null, 0, $max + 1);
    if ($c === false || strlen($c) > $max) return null;
    return $c;
}

function ehHttps()
{
    if (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') return true;
    return strtolower(cabecalhoReq('X-Forwarded-Proto')) === 'https';
}

// "DOMINIO\Ana.Silva" / "ana@x.com" -> "ana.silva" / "ana"
function loginDe($usuario)
{
    $u = trim((string)$usuario);
    if ($u === '') return '';
    $i = strrpos($u, '\\');
    if ($i !== false) $u = substr($u, $i + 1);
    $i = strpos($u, '@');
    if ($i !== false && $i > 0) $u = substr($u, 0, $i);
    return function_exists('mb_strtolower') ? mb_strtolower(trim($u), 'UTF-8') : strtolower(trim($u));
}

// "Maria Souza - msouza"
function nomeExibicao($login, $nome)
{
    $nome = trim((string)$nome);
    return $nome !== '' ? $nome . ' - ' . $login : (string)$login;
}

function fusoDe($cfg)
{
    try { return new DateTimeZone($cfg['fuso']); } catch (Exception $e) { return new DateTimeZone('UTC'); }
}

function diaLocal($tsMs, DateTimeZone $tz)
{
    return (new DateTime('@' . intdiv((int)$tsMs, 1000)))->setTimezone($tz)->format('Y-m-d');
}

function dataValida($s)
{
    if (!is_string($s) || !preg_match('/^(\d{4})-(\d{2})-(\d{2})$/', $s, $m)) return false;
    return checkdate((int)$m[2], (int)$m[3], (int)$m[1]);
}

function ehPresencial($r)
{
    return $r === 'Presencial' || $r === 'Presencial via VPN';
}

// IP do cliente. Atras de proxy/CDN, informe em config 'ip_header' (ex.: 'HTTP_X_FORWARDED_FOR'); senao usa REMOTE_ADDR
// (cabecalhos de proxy podem ser forjados, por isso so sao usados quando o administrador pede).
function ipCliente($cfg)
{
    $h = isset($cfg['ip_header']) ? (string)$cfg['ip_header'] : '';
    if ($h !== '' && !empty($_SERVER[$h])) {
        $ip = trim(explode(',', (string)$_SERVER[$h])[0]);
        if (filter_var($ip, FILTER_VALIDATE_IP)) return $ip;
    }
    return isset($_SERVER['REMOTE_ADDR']) ? (string)$_SERVER['REMOTE_ADDR'] : '';
}
