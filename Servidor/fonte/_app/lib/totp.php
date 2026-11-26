<?php
// Autenticacao em dois fatores (TOTP, RFC 6238): compativel com Microsoft Authenticator, Google Authenticator, Authy etc.

function base32Codificar($bin)
{
    $alf = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    $bits = '';
    foreach (str_split($bin) as $c) $bits .= str_pad(decbin(ord($c)), 8, '0', STR_PAD_LEFT);
    $out = '';
    foreach (str_split($bits, 5) as $grupo) $out .= $alf[bindec(str_pad($grupo, 5, '0', STR_PAD_RIGHT))];
    return $out;
}

function base32Decodificar($txt)
{
    $alf = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    $txt = strtoupper(preg_replace('/[\s=-]/', '', (string)$txt));
    $bits = '';
    foreach (str_split($txt) as $c) {
        $p = strpos($alf, $c);
        if ($p === false) return '';
        $bits .= str_pad(decbin($p), 5, '0', STR_PAD_LEFT);
    }
    $out = '';
    foreach (str_split($bits, 8) as $byte) if (strlen($byte) === 8) $out .= chr(bindec($byte));
    return $out;
}

function totpNovoSegredo()
{
    return base32Codificar(random_bytes(20)); // 160 bits, 32 caracteres
}

function totpCodigo($segredoB32, $passo)
{
    $chave = base32Decodificar($segredoB32);
    $h = hash_hmac('sha1', pack('N2', ($passo >> 32) & 0xFFFFFFFF, $passo & 0xFFFFFFFF), $chave, true);
    $o = ord($h[19]) & 0x0F;
    $n = ((ord($h[$o]) & 0x7F) << 24) | (ord($h[$o + 1]) << 16) | (ord($h[$o + 2]) << 8) | ord($h[$o + 3]);
    return str_pad((string)($n % 1000000), 6, '0', STR_PAD_LEFT);
}

// Devolve o passo (periodo de 30 s) em que o codigo bateu, ou null. Aceita 1 periodo antes/depois (relogios).
// $ultimoPasso impede reutilizar um codigo ja usado (replay).
function totpVerificar($segredoB32, $codigo, $agoraMs, $ultimoPasso = 0)
{
    $codigo = preg_replace('/\s/', '', (string)$codigo);
    if (!preg_match('/^\d{6}$/', $codigo) || $segredoB32 === '' || $segredoB32 === null) return null;
    $atual = intdiv(intdiv($agoraMs, 1000), 30);
    for ($d = -1; $d <= 1; $d++) {
        $passo = $atual + $d;
        if ($passo <= $ultimoPasso) continue;
        if (hash_equals(totpCodigo($segredoB32, $passo), $codigo)) return $passo;
    }
    return null;
}

function totpUri($segredo, $login, $emissor = 'Presenca')
{
    return 'otpauth://totp/' . rawurlencode($emissor . ':' . $login) . '?secret=' . $segredo . '&issuer=' . rawurlencode($emissor) . '&algorithm=SHA1&digits=6&period=30';
}

// Codigos de recuperacao (uso unico). Guarda so o hash.
function gerarCodigosRecuperacao($n = 8)
{
    $claros = []; $hashes = [];
    for ($i = 0; $i < $n; $i++) {
        $c = strtolower(bin2hex(random_bytes(2)) . '-' . bin2hex(random_bytes(2)));
        $claros[] = $c; $hashes[] = hash('sha256', $c);
    }
    return [$claros, $hashes];
}

// Se $codigo for um codigo de recuperacao valido, devolve a lista de hashes restantes (sem ele); senao null.
function consumirRecuperacao($jsonHashes, $codigo)
{
    $lista = json_decode((string)$jsonHashes, true);
    if (!is_array($lista)) return null;
    $h = hash('sha256', strtolower(trim((string)$codigo)));
    foreach ($lista as $i => $x) {
        if (hash_equals($x, $h)) { unset($lista[$i]); return array_values($lista); }
    }
    return null;
}

// Segredo do 2FA no banco: cifrado (AES-256-GCM, chave do acesso remoto) com prefixo 'e1:'. Sem OpenSSL ou sem prefixo, fica/le-se em texto.
function totpSegredoGuardar($cfg, $segredo)
{
    if ($segredo === null || $segredo === '' || !function_exists('openssl_encrypt')) return $segredo;
    return 'e1:' . remotoCifrar($cfg, $segredo);
}

function totpSegredoLer($cfg, $guardado)
{
    $g = (string)$guardado;
    if (strncmp($g, 'e1:', 3) !== 0) return $g;
    $t = remotoDecifrar($cfg, substr($g, 3));
    return $t === null ? '' : $t;
}
