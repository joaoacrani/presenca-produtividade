<?php
// Acesso remoto (RustDesk): o agent gera uma senha aleatoria propria, aplica no cliente RustDesk e envia ID + senha.
// A senha fica cifrada (AES-256-GCM) com uma chave que mora em arquivo separado do banco (<dados_dir>/remoto.key).
// So administradores veem a senha, uma maquina por vez, e cada visualizacao vai para a auditoria.
// Politica de liberacao (meta): remoto_modo = desligado | lista | todas; remoto_lista = maquinas (uma por linha).

const REMOTO_MODOS = ['desligado', 'lista', 'todas'];

function remotoChave($cfg)
{
    $dir = rtrim((string)$cfg['dados_dir'], '/\\');
    $f = $dir . '/remoto.key';
    if (is_file($f)) {
        $k = trim((string)file_get_contents($f));
        if (strlen($k) === 64 && ctype_xdigit($k)) return hex2bin($k);
    }
    if (!is_dir($dir)) @mkdir($dir, 0700, true);
    $k = bin2hex(random_bytes(32));
    if (@file_put_contents($f, $k, LOCK_EX) === false) throw new RuntimeException('nao foi possivel gravar a chave do acesso remoto');
    @chmod($f, 0600);
    return hex2bin($k);
}

function remotoCifrar($cfg, $texto)
{
    if (!function_exists('openssl_encrypt')) throw new RuntimeException('OpenSSL indisponivel nesta hospedagem');
    $iv = random_bytes(12);
    $tag = '';
    $ct = openssl_encrypt((string)$texto, 'aes-256-gcm', remotoChave($cfg), OPENSSL_RAW_DATA, $iv, $tag, '', 16);
    if ($ct === false) throw new RuntimeException('falha ao cifrar');
    return base64_encode($iv . $tag . $ct);
}

function remotoDecifrar($cfg, $b64)
{
    $raw = base64_decode((string)$b64, true);
    if ($raw === false || strlen($raw) < 29) return null;
    $iv = substr($raw, 0, 12); $tag = substr($raw, 12, 16); $ct = substr($raw, 28);
    $t = openssl_decrypt($ct, 'aes-256-gcm', remotoChave($cfg), OPENSSL_RAW_DATA, $iv, $tag);
    return $t === false ? null : $t;
}

function remotoHost($v) { return strtoupper(trim(cortar(is_scalar($v) ? (string)$v : '', 100))); }

// POST /api/remoto (agent): {host, id, senha}. Devolve se e a primeira vez ou se o ID mudou.
function gravarRemoto(PDO $db, $cfg, $j, $agora)
{
    if (!is_array($j)) return ['erro' => 'corpo invalido'];
    $host = remotoHost(isset($j['host']) ? $j['host'] : '');
    $id = isset($j['id']) ? trim((string)$j['id']) : '';
    $senha = isset($j['senha']) ? (string)$j['senha'] : '';
    if ($host === '') return ['erro' => 'host obrigatorio'];
    if (!preg_match('/^\d{6,12}$/', $id)) return ['erro' => 'id invalido'];
    if (!preg_match('/^[A-Za-z0-9]{12,64}$/', $senha)) return ['erro' => 'senha invalida'];
    $st = $db->prepare('SELECT rd_id FROM remoto WHERE host = ?');
    $st->execute([$host]);
    $antes = $st->fetchColumn();
    $db->prepare('INSERT INTO remoto (host, rd_id, senha_cifrada, atualizado_em) VALUES (?,?,?,?)
        ON CONFLICT(host) DO UPDATE SET rd_id = excluded.rd_id, senha_cifrada = excluded.senha_cifrada, atualizado_em = excluded.atualizado_em')
       ->execute([$host, $id, remotoCifrar($cfg, $senha), $agora]);
    return ['ok' => true, 'novo' => $antes === false, 'mudou' => $antes !== false && (string)$antes !== $id, 'host' => $host, 'id' => $id];
}

// Etapas que o agent informa (POST /api/remoto/status): so valores desta lista sao aceitos.
const REMOTO_ESTADOS = ['baixando', 'instalando', 'configurando', 'registrado', 'ok', 'sem-relay',
    'falha-instalacao', 'falha-servico', 'falha-config', 'sem-id', 'falha-senha', 'aguardando-sessao', 'prazo-esgotado', 'falha-envio'];

function gravarRemotoStatus(PDO $db, $j, $agora)
{
    if (!is_array($j)) return ['erro' => 'corpo invalido'];
    $host = remotoHost(isset($j['host']) ? $j['host'] : '');
    $estado = isset($j['estado']) ? (string)$j['estado'] : '';
    if ($host === '') return ['erro' => 'host obrigatorio'];
    if (!in_array($estado, REMOTO_ESTADOS, true)) return ['erro' => 'estado invalido'];
    $detalhe = trim(cortar(isset($j['detalhe']) && is_scalar($j['detalhe']) ? (string)$j['detalhe'] : '', 200));
    $db->prepare('INSERT OR REPLACE INTO remoto_status (host, estado, detalhe, atualizado_em) VALUES (?,?,?,?)')->execute([$host, $estado, $detalhe, $agora]);
    return ['ok' => true];
}

function remotoEstados(PDO $db)
{
    $m = [];
    foreach ($db->query('SELECT host, estado, detalhe, atualizado_em FROM remoto_status') as $r) {
        $m[invChave($r['host'])] = ['estado' => (string)$r['estado'], 'detalhe' => (string)$r['detalhe'], 'em' => (int)$r['atualizado_em']];
    }
    return $m;
}

// Quantas maquinas estao em cada etapa (resumo da Administracao).
function remotoResumoEstados(PDO $db)
{
    $r = [];
    foreach ($db->query('SELECT estado, COUNT(*) AS n FROM remoto_status GROUP BY estado') as $x) $r[(string)$x['estado']] = (int)$x['n'];
    return $r;
}

function remotoMeta(PDO $db, $chave, $padrao = '')
{
    $st = $db->prepare('SELECT valor FROM meta WHERE chave = ?');
    $st->execute([$chave]);
    $v = $st->fetchColumn();
    return $v === false ? $padrao : (string)$v;
}

function remotoPolitica(PDO $db)
{
    $modo = remotoMeta($db, 'remoto_modo', 'desligado');
    if (!in_array($modo, REMOTO_MODOS, true)) $modo = 'desligado';
    $lista = [];
    foreach (preg_split('/[\r\n,;]+/', remotoMeta($db, 'remoto_lista', '')) as $h) { $h = remotoHost($h); if ($h !== '') $lista[$h] = true; }
    return ['modo' => $modo, 'lista' => array_keys($lista)];
}

// GET /api/remoto/politica?host= (agent): o agent so instala/configura o RustDesk se isto for true.
function remotoAtivoPara(PDO $db, $host)
{
    $p = remotoPolitica($db);
    if ($p['modo'] === 'todas') return true;
    if ($p['modo'] === 'lista') return in_array(remotoHost($host), $p['lista'], true);
    return false;
}

function salvarRemotoConfig(PDO $db, $j)
{
    $modo = isset($j['modo']) ? (string)$j['modo'] : '';
    if (!in_array($modo, REMOTO_MODOS, true)) return ['erro' => 'modo invalido'];
    $lista = [];
    foreach (preg_split('/[\r\n,;]+/', isset($j['lista']) ? (string)$j['lista'] : '') as $h) { $h = remotoHost($h); if ($h !== '') $lista[$h] = true; }
    $lista = array_slice(array_keys($lista), 0, 500);
    $ins = $db->prepare('INSERT OR REPLACE INTO meta (chave, valor) VALUES (?, ?)');
    $ins->execute(['remoto_modo', $modo]);
    $ins->execute(['remoto_lista', implode("\n", $lista)]);
    return ['ok' => true, 'modo' => $modo, 'lista' => $lista];
}

// ID por maquina (sem a senha), para o inventario mostrar o botao.
function remotoIds(PDO $db)
{
    $m = [];
    foreach ($db->query('SELECT host, rd_id, atualizado_em FROM remoto') as $r) $m[invChave($r['host'])] = ['id' => (string)$r['rd_id'], 'em' => (int)$r['atualizado_em']];
    return $m;
}

// POST /api/remoto/acesso (admin): devolve ID e senha de UMA maquina.
function remotoAcesso(PDO $db, $cfg, $host)
{
    $st = $db->prepare('SELECT rd_id, senha_cifrada FROM remoto WHERE host = ?');
    $st->execute([remotoHost($host)]);
    $r = $st->fetch();
    if (!$r) return ['erro' => 'esta maquina ainda nao registrou o acesso remoto'];
    $senha = remotoDecifrar($cfg, $r['senha_cifrada']);
    if ($senha === null) return ['erro' => 'nao foi possivel decifrar a senha (chave do servidor mudou?)'];
    return ['ok' => true, 'id' => (string)$r['rd_id'], 'senha' => $senha];
}
