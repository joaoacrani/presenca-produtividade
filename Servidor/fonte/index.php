<?php
// Servidor de presenca e produtividade em PHP para hospedagem compartilhada.
// Requer PHP >= 7.4 com PDO SQLite. Todas as requisicoes passam por este arquivo (.htaccess).
//   Agents (token):  POST /api/registros, POST /api/navegacao, GET /api/config/unidades
//   Painel (login):  pagina /login + sessao por cookie; demais rotas /api/* exigem sessao.

ini_set('display_errors', '0');
date_default_timezone_set('UTC');

const MAX_CORPO = 16384;        // registro de presenca
const MAX_CORPO_NAV = 262144;   // lote de navegacao
const MAX_CORPO_FOCO = 262144;  // lote de programas em foco
const MAX_CORPO_INV = 16384;     // inventario de uma maquina
const MAX_CORPO_IMPORT = 4194304; // CSV de importacao do inventario
const VERSAO = '2.0';

$appDir = __DIR__ . '/_app';
foreach (['util', 'classificacao', 'db', 'totp', 'auth', 'relatorios', 'xlsx', 'exportacao', 'exportacao_foco', 'exportacao_csv', 'resumos', 'inventario', 'remoto', 'sugestoes', 'batimento', 'comparativo', 'api_v1', 'rh', 'relatorio_mensal', 'backup', 'alertas', 'relatorio_individual', 'software'] as $m) require_once $appDir . '/lib/' . $m . '.php';

function cfgPadrao($appDir)
{
    return [
    'online_min' => 45, 'retencao_dias' => 90, 'retencao_nav_dias' => 30, 'retencao_foco_dias' => 60, 'retencao_agregados_dias' => 400,
    'fuso' => 'America/Sao_Paulo', 'sessao_horas' => 12,
    'presenca_min_leituras' => 3, 'presenca_pct_min' => 50, 'parcial_abaixo_leituras' => 12, 'feriados' => [],
    'dados_dir' => $appDir . '/dados', 'unidades_file' => $appDir . '/unidades.json',
    'public_dir' => $appDir . '/public',
    'agora_ms' => null,
    // seguranca do painel
    'ip_header' => '',               // atras de proxy/CDN: 'HTTP_X_FORWARDED_FOR'. Vazio = REMOTE_ADDR
    'exigir_2fa' => false,           // true = todo usuario precisa ativar o 2FA para usar o painel
    'exigir_2fa_admin' => true,      // administradores precisam do 2FA (false so se for indispensavel)
    'login_max_falhas_ip' => 20,     // falhas de login por IP em 15 min antes de bloquear o IP (0 = desligado)
    'retencao_auditoria_dias' => 365,
    'servidor_online_min' => 15,     // servidor sem batimento ha mais que isso = "fora do ar" (batimento a cada 5 min)
];
}

// ---------- roteamento ----------

$uri = parse_url(isset($_SERVER['REQUEST_URI']) ? $_SERVER['REQUEST_URI'] : '/', PHP_URL_PATH);
if (!is_string($uri) || $uri === '') $uri = '/';
$script = isset($_SERVER['SCRIPT_NAME']) ? str_replace('\\', '/', $_SERVER['SCRIPT_NAME']) : '/index.php';
// Pasta onde o index.php esta publicado (ex.: /presenca). So confia no SCRIPT_NAME se ele for mesmo o index.php.
$base = basename($script) === 'index.php' ? rtrim(str_replace('\\', '/', dirname($script)), '/') : '';   // no Windows dirname('/index.php') devolve '\'
$rota = ($base !== '' && strpos($uri, $base) === 0) ? substr($uri, strlen($base)) : $uri;
$rota = rawurldecode($rota);
if ($rota === '') {
    header('Location: ' . $base . '/', true, 301);
    exit;
}
if ($rota === '/index.php') $rota = '/';
$metodo = isset($_SERVER['REQUEST_METHOD']) ? $_SERVER['REQUEST_METHOD'] : 'GET';

$cfgFile = getenv('PRESENCA_CONFIG') ?: $appDir . '/config.php';
$cfg = is_file($cfgFile) ? include $cfgFile : null;
$sqliteOk = class_exists('PDO') && in_array('sqlite', PDO::getAvailableDrivers(), true);

// Diagnostico (sem login, sem dados): ajuda a conferir a hospedagem
if ($rota === '/health') {
    // Publico: so o minimo (o script de publicacao confere ok/sqlite/versao). O diagnostico completo exige o token do agent.
    $saude = ['ok' => true, 'versao' => VERSAO, 'sqlite' => $sqliteOk];
    if (is_array($cfg) && !empty($cfg['agent_token']) && tokenAgenteValido($cfg)) {
        $saude += [
            'openssl' => function_exists('openssl_encrypt') && in_array('aes-256-gcm', openssl_get_cipher_methods(), true),
            'configurado' => true,
            'auth_header' => cabecalhoAuth() !== '',
        ];
    }
    if (is_array($cfg) && $sqliteOk && !empty($cfg['agent_token'])) {
        $cfgH = array_merge(cfgPadrao($appDir), $cfg);
        if (!is_file($cfgH['dados_dir'] . '/presenca.sqlite')) responderJson(200, $saude);   // sem banco ainda: nada a verificar
        $agoraH = $cfgH['agora_ms'] !== null ? (int)$cfgH['agora_ms'] : (int)round(microtime(true) * 1000);
        register_shutdown_function(function () use ($cfgH, $agoraH) {
            if (function_exists('fastcgi_finish_request')) @fastcgi_finish_request();
            try { alertasSeDevido(abrirBanco($cfgH), $cfgH, $agoraH); } catch (Throwable $e) { /* o /health nunca falha por causa do alerta */ }
        });
    }
    responderJson(200, $saude);
}

if (!is_array($cfg) || empty($cfg['agent_token']) || strlen($cfg['agent_token']) < 16 || empty($cfg['painel_user']) || empty($cfg['painel_pass'])) {
    responderJson(500, ['erro' => 'servidor nao configurado (_app/config.php)']);
}
if (!$sqliteOk) responderJson(500, ['erro' => 'PDO SQLite indisponivel nesta hospedagem']);

$cfg = array_merge(cfgPadrao($appDir), $cfg);
$agora = $cfg['agora_ms'] !== null ? (int)$cfg['agora_ms'] : (int)round(microtime(true) * 1000);

function corpoJson($max)
{
    $c = lerCorpo($max);
    if ($c === null) responderJson(413, ['erro' => 'corpo grande demais']);
    $j = json_decode($c, true);
    if ($j === null) responderJson(400, ['erro' => 'json invalido']);
    return $j;
}

function servirArquivo($cfg, $nome, $tipo)
{
    $f = $cfg['public_dir'] . '/' . $nome;
    if (!is_file($f)) responderJson(404, ['erro' => 'nao encontrado']);
    cabecalhosBase();
    header('Content-Type: ' . $tipo);
    readfile($f);
    exit;
}

function tipoDe($ext)
{
    $t = ['js' => 'text/javascript; charset=utf-8', 'css' => 'text/css; charset=utf-8', 'html' => 'text/html; charset=utf-8'];
    return isset($t[$ext]) ? $t[$ext] : null;
}

try {
    // --- endpoints do agent (token) ---
    if ($rota === '/api/registros' && $metodo === 'POST') {
        $ag = exigirAgente($cfg, $agora);
        $json = corpoJson(MAX_CORPO);
        agenteHostDe($ag, $json);
        $v = validarRegistro($json, $agora);
        if (isset($v['erro'])) responderJson(400, ['erro' => $v['erro']]);
        $db = abrirBanco($cfg);
        $ipSaida = ipCliente($cfg);
        $v['reg']['ip_saida'] = filter_var($ipSaida, FILTER_VALIDATE_IP) ? $ipSaida : '';
        $dup = gravarRegistro($db, $cfg, $v['reg'], $agora);
        limparAntigosSeDevido($db, $cfg, $agora);
        snapshotSeDevido($db, $cfg, $agora);
        alertasSeDevido($db, $cfg, $agora);
        responderJson(200, ['ok' => true, 'duplicado' => $dup]);
    }
    if ($rota === '/api/navegacao' && $metodo === 'POST') {
        $ag = exigirAgente($cfg, $agora);
        $json = corpoJson(MAX_CORPO_NAV);
        agenteHostDe($ag, $json);
        $db = abrirBanco($cfg);
        $r = gravarNavegacao($db, $cfg, $json, $agora);
        if (isset($r['erro'])) responderJson(400, ['erro' => $r['erro']]);
        limparAntigosSeDevido($db, $cfg, $agora);
        responderJson(200, $r);
    }
    if ($rota === '/api/inventario' && $metodo === 'POST') {
        $ag = exigirAgente($cfg, $agora);
        $json = corpoJson(MAX_CORPO_INV);
        agenteHostDe($ag, $json);
        $db = abrirBanco($cfg);
        $r = gravarInventario($db, $json, $agora);
        if (isset($r['erro'])) responderJson(400, ['erro' => $r['erro']]);
        responderJson(200, $r);
    }
    if ($rota === '/api/foco' && $metodo === 'POST') {
        $ag = exigirAgente($cfg, $agora);
        $json = corpoJson(MAX_CORPO_FOCO);
        agenteHostDe($ag, $json);
        $db = abrirBanco($cfg);
        $r = gravarFoco($db, $cfg, $json, $agora);
        if (isset($r['erro'])) responderJson(400, ['erro' => $r['erro']]);
        limparAntigosSeDevido($db, $cfg, $agora);
        responderJson(200, $r);
    }
    if ($rota === '/api/config/unidades' && $metodo === 'GET') {
        $ag = exigirAgente($cfg, $agora);
        $txt = is_file($cfg['unidades_file']) ? file_get_contents($cfg['unidades_file']) : false;
        $obj = $txt !== false ? json_decode($txt, true) : null;
        if (!is_array($obj)) responderJson(500, ['erro' => 'unidades.json indisponivel']);
        responderJson(200, $obj);
    }

    // Batimento dos servidores: a tarefa SYSTEM do agent (so nos servidores marcados no painel) avisa que a maquina esta no ar.
    if ($rota === '/api/batimento/politica' && $metodo === 'GET') {
        $ag = exigirAgente($cfg, $agora);
        $db = abrirBanco($cfg);
        agenteHostDe($ag, $_GET);
        responderJson(200, ['ativo' => ehServidor($db, isset($_GET['host']) ? (string)$_GET['host'] : '')]);
    }
    if ($rota === '/api/batimento' && $metodo === 'POST') {
        $ag = exigirAgente($cfg, $agora);
        $j = corpoJson(2048);
        agenteHostDe($ag, $j);
        $db = abrirBanco($cfg);
        $r = gravarBatimento($db, isset($j['host']) ? $j['host'] : '', isset($j['boot']) ? $j['boot'] : 0, $agora);
        if (isset($r['erro'])) responderJson(400, ['erro' => $r['erro']]);
        responderJson(200, $r);
    }

    // Acesso remoto (RustDesk). O agent so configura o cliente quando a politica libera a maquina, e envia ID + senha propria.
    if ($rota === '/api/remoto/politica' && $metodo === 'GET') {
        $ag = exigirAgente($cfg, $agora);
        $db = abrirBanco($cfg);
        agenteHostDe($ag, $_GET);
        responderJson(200, ['ativo' => remotoAtivoPara($db, isset($_GET['host']) ? (string)$_GET['host'] : '')]);
    }
    if ($rota === '/api/remoto/status' && $metodo === 'POST') {
        $ag = exigirAgente($cfg, $agora);
        $db = abrirBanco($cfg);
        $jst = corpoJson(1024);
        agenteHostDe($ag, $jst);
        $r = gravarRemotoStatus($db, $jst, $agora);
        if (isset($r['erro'])) responderJson(400, ['erro' => $r['erro']]);
        responderJson(200, ['ok' => true]);
    }
    if ($rota === '/api/remoto' && $metodo === 'POST') {
        $ag = exigirAgente($cfg, $agora);
        $json = corpoJson(2048);
        agenteHostDe($ag, $json);
        $db = abrirBanco($cfg);
        if (!remotoAtivoPara($db, isset($json['host']) ? (string)$json['host'] : '')) responderJson(403, ['erro' => 'acesso remoto nao liberado para esta maquina']);
        $r = gravarRemoto($db, $cfg, $json, $agora);
        if (isset($r['erro'])) responderJson(400, ['erro' => $r['erro']]);
        if ($r['novo'] || $r['mudou']) auditar($db, $agora, ipCliente($cfg), $r['host'], 'remoto_registrado', ($r['novo'] ? 'primeiro registro' : 'ID alterado') . ' · ID ' . $r['id']);
        responderJson(200, ['ok' => true]);
    }

    // Token proprio por maquina: o agent (ja instalado, com o token de cadastro) troca por um token que so vale para este host.
    if ($rota === '/api/agente/registrar' && $metodo === 'POST') {
        $ag = exigirAgente($cfg, $agora, 'cadastro');
        $j = corpoJson(1024);
        $db = abrirBanco($cfg);
        $r = registrarAgente($db, $cfg, isset($j['host']) ? $j['host'] : '', $agora, ipCliente($cfg));
        if (isset($r['erro'])) responderJson($r['status'], ['erro' => $r['erro']]);
        responderJson(200, $r);
    }

    // Atualizacao do agent: arquivos assinados ficam em <dados_dir>/agente/ (manifest.json + pacote.zip).
    // O servidor so entrega; quem decide instalar e o agent, verificando a assinatura com a chave publica embutida.
    if (($rota === '/api/agente/versao' || $rota === '/api/agente/pacote') && $metodo === 'GET') {
        $ag = exigirAgente($cfg, $agora, 'leitura');
        $pasta = rtrim($cfg['dados_dir'], '/\\') . '/agente';
        if ($rota === '/api/agente/versao') {
            $txt = is_file($pasta . '/manifest.json') ? file_get_contents($pasta . '/manifest.json') : false;
            $m = $txt !== false ? json_decode(ltrim($txt, "\xEF\xBB\xBF"), true) : null;
            if (!is_array($m) || empty($m['versao']) || empty($m['sha256']) || empty($m['assinatura'])) responderJson(404, ['erro' => 'sem atualizacao publicada']);
            responderJson(200, ['versao' => (string)$m['versao'], 'sha256' => (string)$m['sha256'],
                'tamanho' => isset($m['tamanho']) ? (int)$m['tamanho'] : 0, 'assinatura' => (string)$m['assinatura']]);
        }
        $zip = $pasta . '/pacote.zip';
        if (!is_file($zip)) responderJson(404, ['erro' => 'sem atualizacao publicada']);
        cabecalhosBase();
        header('Content-Type: application/zip');
        header('Content-Length: ' . filesize($zip));
        readfile($zip);
        exit;
    }

    // Instalacao de software (agent): so token de MAQUINA (o de cadastro nao executa nada). Tarefas, arquivo e resultado ficam presos ao host.
    if (strncmp($rota, '/api/agente/tarefas', 19) === 0 || $rota === '/api/agente/software') {
        $ag = exigirAgente($cfg, $agora);
        if ($ag['host'] === null) responderJson(403, ['erro' => 'instalacao de software exige o token proprio da maquina']);
        $db = abrirBanco($cfg);
        if ($rota === '/api/agente/tarefas' && $metodo === 'GET') {
            agenteHostDe($ag, $_GET);
            responderJson(200, ['tarefas' => softwareTarefasPara($db, $ag['host'], $agora)]);
        }
        if ($rota === '/api/agente/tarefas/resultado' && $metodo === 'POST') {
            $j = corpoJson(8192);
            agenteHostDe($ag, $j);
            $r = softwareResultado($db, $agora, $ag['host'], isset($j['id']) ? $j['id'] : 0, isset($j['estado']) ? $j['estado'] : '', isset($j['codigo']) ? $j['codigo'] : null, isset($j['saida']) ? $j['saida'] : '');
            if (isset($r['erro'])) responderJson($r['status'], ['erro' => $r['erro']]);
            responderJson(200, $r);
        }
        if ($rota === '/api/agente/software' && $metodo === 'GET') {
            agenteHostDe($ag, $_GET);
            $f = softwareArquivoPara($db, $cfg, $ag['host'], isset($_GET['pid']) ? (string)$_GET['pid'] : '');
            if ($f === null) responderJson(404, ['erro' => 'sem tarefa em aberto para este pacote']);
            cabecalhosBase();
            header('Content-Type: application/octet-stream');
            header('Content-Length: ' . filesize($f));
            readfile($f);
            exit;
        }
        responderJson(404, ['erro' => 'nao encontrado']);
    }

    // API de dados (somente leitura, token proprio): fica antes do login do painel e nao usa sessao nem cookie
    if (strncmp($rota, '/api/v1/', 8) === 0) tratarApiV1($cfg, $rota, $metodo, $agora);

    $ip = ipCliente($cfg); // usado na auditoria e no limite de falhas de login

    $db = abrirBanco($cfg);
    $sessao = sessaoAtual($db, $agora);

    // --- login (sem sessao) ---
    if ($rota === '/api/login' && $metodo === 'POST') {
        if (stripos(cabecalhoReq('Content-Type'), 'application/json') === false) responderJson(415, ['erro' => 'use application/json']);
        $j = corpoJson(2048);
        $r = tentarLogin($db, $cfg, isset($j['login']) ? $j['login'] : '', isset($j['senha']) ? $j['senha'] : '',
            isset($j['codigo']) ? $j['codigo'] : null, $agora, $base, $ip);
        if (isset($r['erro'])) responderJson($r['status'], ['erro' => $r['erro']]);
        if (isset($r['precisa_2fa'])) responderJson(200, ['precisa_2fa' => true]);
        responderJson(200, ['ok' => true]);
    }
    if (($rota === '/login' || $rota === '/login.html') && $metodo === 'GET') {
        if ($sessao) { header('Location: ' . $base . '/', true, 302); exit; }
        servirArquivo($cfg, 'login.html', 'text/html; charset=utf-8');
    }
    if ($metodo === 'GET' && ($rota === '/logo.png' || $rota === '/logo-claro.png')) servirArquivo($cfg, substr($rota, 1), 'image/png');
    if ($metodo === 'GET' && ($rota === '/login.js' || $rota === '/style.css')) {
        servirArquivo($cfg, substr($rota, 1), tipoDe(substr($rota, -2) === 'js' ? 'js' : 'css'));
    }

    // --- a partir daqui, so com sessao ---
    if (!$sessao) {
        if (strncmp($rota, '/api/', 5) === 0) responderJson(401, ['erro' => 'login necessario']);
        if ($metodo === 'GET' && ($rota === '/' || $rota === '/index.html')) { header('Location: ' . $base . '/login', true, 302); exit; }
        responderJson(404, ['erro' => 'nao encontrado']);
    }
    $ehAdmin = $sessao['papel'] === 'admin';
    if ($metodo !== 'GET' && $metodo !== 'HEAD' && !iguais(cabecalhoReq('X-CSRF-Token'), $sessao['csrf'])) {
        responderJson(403, ['erro' => 'token CSRF invalido']);
    }
    $exigirAdmin = function () use ($ehAdmin) { if (!$ehAdmin) responderJson(403, ['erro' => 'apenas administradores']); };

    $totpAtivo = (int)$sessao['totp_ativo'] === 1;
    // exigir_2fa = todos; exigir_2fa_admin = so administradores
    $exige2fa = !empty($cfg['exigir_2fa']) || (!empty($cfg['exigir_2fa_admin']) && $ehAdmin);
    $precisa2fa = $exige2fa && !$totpAtivo;
    // Acoes sensiveis (apagar dados, criar token/usuario, ver senha remota): pedem a senha de novo (e o codigo 2FA), valida por 5 min
    $exigirReauth = function () use ($sessao, $agora, $totpAtivo) {
        if ((int)$sessao['reauth_ate'] <= $agora) {
            responderJson(403, ['erro' => 'Confirme sua senha para continuar.', 'precisa_reautenticar' => true, 'pede_codigo' => $totpAtivo]);
        }
    };
    if ($rota === '/api/reautenticar' && $metodo === 'POST') {
        $j = corpoJson(1024);
        $r = reautenticar($db, $cfg, $sessao, isset($j['senha']) ? $j['senha'] : '', isset($j['codigo']) ? $j['codigo'] : '', $agora, $ip);
        if (isset($r['erro'])) responderJson($r['status'], ['erro' => $r['erro']]);
        responderJson(200, ['ok' => true, 'valido_ms' => REAUTH_MS]);
    }
    if ($rota === '/api/eu' && $metodo === 'GET') {
        responderJson(200, ['login' => $sessao['login'], 'nome' => $sessao['nome'], 'papel' => $sessao['papel'], 'csrf' => $sessao['csrf'],
            'totp_ativo' => $totpAtivo, 'precisa_configurar_2fa' => $precisa2fa, 'ip' => $ip,
            'online_min' => (int)$cfg['online_min'], 'fuso' => $cfg['fuso'], 'presenca' => ['min_leituras' => (int)$cfg['presenca_min_leituras'], 'pct_min' => (float)$cfg['presenca_pct_min']]]);
    }
    if ($rota === '/api/logout' && $metodo === 'POST') {
        auditar($db, $agora, $ip, $sessao['login'], 'logout');
        encerrarSessao($db, $base);
        responderJson(200, ['ok' => true]);
    }
    // com 'exigir_2fa', quem ainda nao ativou o 2FA so alcanca as rotas de configuracao dele
    if ($precisa2fa && !in_array($rota, ['/', '/index.html'], true) && strncmp($rota, '/api/2fa/', 9) !== 0 && $rota !== '/api/senha' && !preg_match('#\.(js|css)$#', $rota)) {
        responderJson(403, ['erro' => 'Ative a verificacao em duas etapas para continuar.', 'precisa_configurar_2fa' => true]);
    }

    // --- 2FA (TOTP) do proprio usuario ---
    if ($rota === '/api/2fa/iniciar' && $metodo === 'POST') {
        if ($totpAtivo) responderJson(400, ['erro' => 'A verificação em duas etapas já está ativa.']);
        $seg = totpNovoSegredo();
        $db->prepare('UPDATE usuarios SET totp_secret = ?, totp_ativo = 0, totp_passo = 0 WHERE id = ?')->execute([totpSegredoGuardar($cfg, $seg), $sessao['id']]);
        responderJson(200, ['segredo' => $seg, 'uri' => totpUri($seg, $sessao['login'])]);
    }
    if ($rota === '/api/2fa/ativar' && $metodo === 'POST') {
        $j = corpoJson(1024);
        $st = $db->prepare('SELECT totp_secret FROM usuarios WHERE id = ?'); $st->execute([$sessao['id']]);
        $seg = totpSegredoLer($cfg, $st->fetchColumn());
        $passo = $totpAtivo ? null : totpVerificar($seg, isset($j['codigo']) ? $j['codigo'] : '', $agora, 0);
        if ($passo === null) { usleep(400000); responderJson(400, ['erro' => 'Código inválido. Confira o horário do celular e tente de novo.']); }
        list($claros, $hashes) = gerarCodigosRecuperacao();
        $db->prepare('UPDATE usuarios SET totp_ativo = 1, totp_passo = ?, totp_recuperacao = ? WHERE id = ?')->execute([$passo, json_encode($hashes), $sessao['id']]);
        auditar($db, $agora, $ip, $sessao['login'], '2fa_ativado');
        responderJson(200, ['ok' => true, 'codigos_recuperacao' => $claros]);
    }
    if ($rota === '/api/2fa/desativar' && $metodo === 'POST') {
        $j = corpoJson(1024);
        $st = $db->prepare('SELECT senha_hash, totp_secret, totp_passo FROM usuarios WHERE id = ?'); $st->execute([$sessao['id']]);
        $u = $st->fetch();
        $okSenha = password_verify(isset($j['senha']) ? (string)$j['senha'] : '', (string)$u['senha_hash']);
        $okCod = $totpAtivo && totpVerificar(totpSegredoLer($cfg, $u['totp_secret']), isset($j['codigo']) ? $j['codigo'] : '', $agora, (int)$u['totp_passo']) !== null;
        if (!$okSenha || !$okCod) { usleep(500000); responderJson(400, ['erro' => 'Senha ou código incorretos.']); }
        if ($exige2fa) responderJson(400, ['erro' => 'O 2FA é obrigatório neste servidor.']);
        $db->prepare('UPDATE usuarios SET totp_ativo = 0, totp_secret = NULL, totp_recuperacao = NULL, totp_passo = 0 WHERE id = ?')->execute([$sessao['id']]);
        auditar($db, $agora, $ip, $sessao['login'], '2fa_desativado');
        responderJson(200, ['ok' => true]);
    }
    if ($rota === '/api/senha' && $metodo === 'POST') {
        $j = corpoJson(2048);
        $st = $db->prepare('SELECT senha_hash FROM usuarios WHERE id = ?');
        $st->execute([$sessao['id']]);
        $h = $st->fetchColumn();
        if (!password_verify(isset($j['atual']) ? (string)$j['atual'] : '', (string)$h)) { usleep(500000); responderJson(400, ['erro' => 'Senha atual incorreta.']); }
        if (($pb = senhaProblema(isset($j['nova']) ? $j['nova'] : null, $sessao['login'])) !== null) responderJson(400, ['erro' => $pb]);
        $db->prepare('UPDATE usuarios SET senha_hash = ? WHERE id = ?')->execute([password_hash($j['nova'], PASSWORD_DEFAULT), $sessao['id']]);
        $db->prepare('DELETE FROM sessoes WHERE usuario_id = ? AND hash <> ?')->execute([$sessao['id'], sessaoHash()]); // derruba as outras sessoes
        auditar($db, $agora, $ip, $sessao['login'], 'senha_alterada');
        responderJson(200, ['ok' => true]);
    }

    // --- presenca ---
    if ($rota === '/api/estado' && $metodo === 'GET') {
        $st = $db->prepare('SELECT r.*, c.nome AS cnome, ag.versao AS versao_agente FROM registros r
            JOIN (SELECT host, MAX(ts) AS mts FROM registros WHERE ts > ? GROUP BY host) m
              ON r.host = m.host AND r.ts = m.mts
            LEFT JOIN colaboradores c ON c.login = r.login
            LEFT JOIN maquinas_ocultas o ON o.host = r.host
            LEFT JOIN agentes ag ON ag.host = r.host
            WHERE o.host IS NULL OR r.ts > o.ocultado_em
            ORDER BY COALESCE(NULLIF(c.nome, \'\'), r.usuario) COLLATE NOCASE, r.host');
        $st->execute([$agora - 30 * 86400000]);
        $servidores = mapaServidores($db);
        $batimentos = mapaBatimentos($db);
        $itens = [];
        foreach ($st->fetchAll() as $r) {
            $idade = max(0, (int)round(($agora - (int)$r['ts']) / 60000));
            $chaveHost = strtoupper($r['host']);
            $ehSrv = isset($servidores[$chaveHost]);
            $bat = $ehSrv && isset($batimentos[$chaveHost]) ? $batimentos[$chaveHost] : null;
            // servidor com batimento: o sinal de vida e o mais recente entre o batimento e a ultima leitura de usuario
            $limiteMin = (int)$cfg['online_min'];
            if ($bat) { $idade = max(0, (int)round(($agora - max((int)$r['ts'], $bat['visto'])) / 60000)); $limiteMin = servidorOnlineMin($cfg); }
            $login = $r['login'] !== null && $r['login'] !== '' ? $r['login'] : loginDe($r['usuario']);
            $nome = $r['cnome'] !== null && $r['cnome'] !== '' ? $r['cnome'] : (string)$r['nome'];
            $itens[] = [
                'host' => $r['host'], 'usuario' => $r['usuario'], 'login' => $login, 'nome' => $nome,
                'colaborador' => nomeExibicao($login, $nome),
                'resultado' => $r['resultado'], 'unidade' => $r['unidade'],
                'vpn_ativa' => $r['vpn_ativa'], 'confianca' => $r['confianca'], 'sessao_remota' => $r['sessao_remota'],
                'bloqueada' => $r['bloqueada'], 'ocioso_seg' => $r['ocioso_seg'] === null ? null : (int)$r['ocioso_seg'],
                'motivo' => $r['motivo'], 'ts' => (int)$r['ts'], 'idade_min' => $idade,
                'versao_agente' => (string)$r['versao_agente'], 'servidor' => $ehSrv, 'batimento' => $bat !== null, 'boot_em' => $bat ? $bat['boot'] : null,
                'ativo' => $idade <= $limiteMin,
            ];
        }
        responderJson(200, ['agora' => $agora, 'online_min' => (int)$cfg['online_min'], 'itens' => $itens]);
    }

    // --- limpeza de maquinas antigas (admin): ocultar (reversivel) ou excluir as leituras ---
    // Ocultar tira a maquina do painel; ela volta sozinha se voltar a enviar dados depois de ocultada.
    if ($rota === '/api/maquinas/ocultas' && $metodo === 'GET') {
        $exigirAdmin();
        $itens = $db->query('SELECT host, ocultado_em, por FROM maquinas_ocultas ORDER BY host COLLATE NOCASE')->fetchAll();
        foreach ($itens as &$x) $x['ocultado_em'] = (int)$x['ocultado_em'];
        unset($x);
        responderJson(200, ['itens' => $itens]);
    }
    if (($rota === '/api/maquinas/ocultar' || $rota === '/api/maquinas/restaurar') && $metodo === 'POST') {
        $exigirAdmin();
        $j = corpoJson(1024);
        $host = trim(cortar(isset($j['host']) ? $j['host'] : '', 100));
        if ($host === '') responderJson(400, ['erro' => 'host obrigatorio']);
        if ($rota === '/api/maquinas/ocultar') {
            $db->prepare('INSERT OR REPLACE INTO maquinas_ocultas (host, ocultado_em, por) VALUES (?,?,?)')->execute([$host, $agora, $sessao['login']]);
            auditar($db, $agora, $ip, $sessao['login'], 'maquina_ocultada', $host);
        } else {
            $db->prepare('DELETE FROM maquinas_ocultas WHERE host = ?')->execute([$host]);
            auditar($db, $agora, $ip, $sessao['login'], 'maquina_restaurada', $host);
        }
        responderJson(200, ['ok' => true]);
    }
    if ($rota === '/api/servidores' && $metodo === 'GET') {
        $exigirAdmin();
        $itens = $db->query('SELECT host, criado_em, por FROM servidores ORDER BY host')->fetchAll();
        responderJson(200, ['itens' => $itens]);
    }
    if ($rota === '/api/resumos/reconstruir' && $metodo === 'POST') {
        $exigirAdmin();
        @set_time_limit(300);
        $r = reconstruirResumos($db, $cfg, $agora);
        auditar($db, $agora, $ip, $sessao['login'], 'resumos_reconstruidos', json_encode($r));
        responderJson(200, ['ok' => true, 'resultado' => $r]);
    }
    // --- inventario de maquinas ---
    if ($rota === '/api/inventario' && $metodo === 'GET') {
        responderJson(200, ['itens' => listarInventario($db, $agora), 'status' => INV_STATUS, 'agora' => $agora]);
    }
    if ($rota === '/api/inventario' && $metodo === 'PUT') {
        $exigirAdmin();
        $j = corpoJson(8192);
        $r = salvarInventarioManual($db, $j, $agora);
        if (isset($r['erro'])) responderJson(400, ['erro' => $r['erro']]);
        auditar($db, $agora, $ip, $sessao['login'], $r['novo'] ? 'inventario_criado' : 'inventario_alterado', $r['chave']);
        responderJson(200, $r);
    }
    if ($rota === '/api/inventario' && $metodo === 'DELETE') {
        $exigirAdmin();
        $chave = invChave(isset($_GET['chave']) ? (string)$_GET['chave'] : '');
        if ($chave === '') responderJson(400, ['erro' => 'chave obrigatoria']);
        $db->prepare('DELETE FROM inventario WHERE chave = ?')->execute([$chave]);
        $db->prepare('DELETE FROM inventario_hist WHERE chave = ?')->execute([$chave]);
        auditar($db, $agora, $ip, $sessao['login'], 'inventario_excluido', $chave);
        responderJson(200, ['ok' => true]);
    }
    if ($rota === '/api/inventario/historico' && $metodo === 'GET') {
        $chave = invChave(isset($_GET['chave']) ? (string)$_GET['chave'] : '');
        $st = $db->prepare('SELECT ts, campo, antigo, novo FROM inventario_hist WHERE chave = ? ORDER BY ts DESC LIMIT 200');
        $st->execute([$chave]);
        responderJson(200, ['itens' => $st->fetchAll()]);
    }
    if ($rota === '/api/inventario/importar' && $metodo === 'POST') {
        $exigirAdmin();
        $j = corpoJson(MAX_CORPO_IMPORT);
        $r = importarInventarioCsv($db, isset($j['csv']) ? $j['csv'] : '', $agora, !empty($j['sobrescrever']));
        if (isset($r['erro'])) responderJson(400, ['erro' => $r['erro']]);
        auditar($db, $agora, $ip, $sessao['login'], 'inventario_importado', json_encode($r) . (!empty($j['sobrescrever']) ? ' sobrescrevendo' : ''));
        responderJson(200, $r);
    }
    // --- acesso remoto (admin): politica de liberacao e senha de uma maquina (cada consulta e auditada) ---
    if ($rota === '/api/remoto/config' && $metodo === 'GET') {
        $exigirAdmin();
        responderJson(200, remotoPolitica($db) + ['registradas' => (int)$db->query('SELECT COUNT(*) FROM remoto')->fetchColumn(), 'estados' => remotoResumoEstados($db)]);
    }
    if ($rota === '/api/remoto/config' && $metodo === 'PUT') {
        $exigirAdmin();
        $r = salvarRemotoConfig($db, corpoJson(16384));
        if (isset($r['erro'])) responderJson(400, ['erro' => $r['erro']]);
        auditar($db, $agora, $ip, $sessao['login'], 'remoto_config', $r['modo'] . ($r['modo'] === 'lista' ? ' · ' . count($r['lista']) . ' maquina(s)' : ''));
        responderJson(200, $r);
    }
    if ($rota === '/api/remoto/acesso' && $metodo === 'POST') {
        $exigirAdmin();
        $exigirReauth();
        $j = corpoJson(1024);
        $host = remotoHost(isset($j['host']) ? $j['host'] : '');
        if ($host === '') responderJson(400, ['erro' => 'host obrigatorio']);
        $r = remotoAcesso($db, $cfg, $host);
        if (isset($r['erro'])) responderJson(404, ['erro' => $r['erro']]);
        auditar($db, $agora, $ip, $sessao['login'], 'acesso_remoto', $host);
        header('Cache-Control: no-store');
        responderJson(200, $r);
    }
    // Alertas por e-mail (admin): ver, salvar o destino e mandar um teste
    if ($rota === '/api/alertas' && $metodo === 'GET') {
        $exigirAdmin();
        responderJson(200, alertaConfig($db));
    }
    if ($rota === '/api/alertas' && $metodo === 'PUT') {
        $exigirAdmin(); $exigirReauth();
        $j = corpoJson(1024);
        $email = trim(isset($j['email']) ? (string)$j['email'] : '');
        $ativo = !empty($j['ativo']);
        if ($email !== '' && !alertaEmailValido($email)) responderJson(400, ['erro' => 'e-mail invalido']);
        if ($ativo && $email === '') responderJson(400, ['erro' => 'informe um e-mail para ligar os alertas']);
        $ins = $db->prepare('INSERT OR REPLACE INTO meta (chave, valor) VALUES (?, ?)');
        $ins->execute(['alerta_email', $email]); $ins->execute(['alerta_ativo', $ativo ? '1' : '0']);
        auditar($db, $agora, $ip, $sessao['login'], 'alertas_config', $ativo ? 'ligados' : 'desligados');
        responderJson(200, alertaConfig($db));
    }
    if ($rota === '/api/alertas/teste' && $metodo === 'POST') {
        $exigirAdmin();
        $ok = enviarAlerta($db, $cfg, $agora, 'teste', 0, 'Teste de alerta', "Se você recebeu esta mensagem, os alertas por e-mail do painel estão funcionando.\n\nOlhe também a caixa de spam na primeira vez.", true);
        responderJson($ok ? 200 : 500, ['ok' => $ok, 'erro' => $ok ? null : 'nao foi possivel enviar: confira o e-mail salvo (e se a hospedagem permite enviar e-mail)']);
    }
    // Backup do banco (admin): situacao do instantaneo diario e geracao imediata (o script do PC baixa e apaga a copia do servidor)
    if ($rota === '/api/backup' && $metodo === 'GET') {
        $exigirAdmin();
        responderJson(200, backupInfo($db, $cfg));
    }
    if ($rota === '/api/backup/gerar' && $metodo === 'POST') {
        $exigirAdmin(); $exigirReauth();
        @set_time_limit(300);
        $r = gerarSnapshot($db, $cfg, $agora);
        auditar($db, $agora, $ip, $sessao['login'], 'backup_gerado', $r['ok'] ? $r['tamanho'] . ' bytes' : 'falhou: ' . $r['motivo']);
        responderJson($r['ok'] ? 200 : 500, $r + backupInfo($db, $cfg));
    }
    // Tokens por maquina (admin): resumo, liberar novo cadastro de uma maquina e desligar o token de cadastro para envio
    if ($rota === '/api/agentes/tokens' && $metodo === 'GET') {
        $exigirAdmin();
        responderJson(200, resumoTokensAgentes($db, $agora));
    }
    if ($rota === '/api/agentes/tokens' && $metodo === 'DELETE') {
        $exigirAdmin(); $exigirReauth();
        $host = strtoupper(trim(cortar(isset($_GET['host']) ? $_GET['host'] : '', 100)));
        if ($host === '') responderJson(400, ['erro' => 'host obrigatorio']);
        $st = $db->prepare('DELETE FROM agente_tokens WHERE host = ?'); $st->execute([$host]);
        auditar($db, $agora, $ip, $sessao['login'], 'agente_token_liberado', $host);
        responderJson(200, ['ok' => true, 'removidos' => $st->rowCount()]);
    }
    if ($rota === '/api/agentes/tokens/cadastro' && $metodo === 'PUT') {
        $exigirAdmin(); $exigirReauth();
        $j = corpoJson(256);
        $perm = !empty($j['permitir']);
        $db->prepare('INSERT OR REPLACE INTO meta (chave, valor) VALUES (?, ?)')->execute(['agente_token_legado', $perm ? '1' : '0']);
        auditar($db, $agora, $ip, $sessao['login'], 'agente_cadastro_config', $perm ? 'token de cadastro volta a valer para envio' : 'token de cadastro so cadastra; envio exige token da maquina');
        responderJson(200, ['ok' => true, 'cadastro_permitido' => $perm]);
    }
    // Software (admin): catalogo de pacotes assinados no navegador, envio do arquivo, disparo por maquina e resultado
    if ($rota === '/api/software' && $metodo === 'GET') {
        $exigirAdmin();
        $tok = [];
        foreach ($db->query('SELECT host FROM agente_tokens') as $r) $tok[strtoupper($r['host'])] = true;
        $maq = [];
        foreach ($db->query('SELECT host, versao, visto_em FROM agentes ORDER BY host COLLATE NOCASE') as $r) {
            if ((int)$r['visto_em'] > $agora - 60 * 86400000) $maq[] = ['host' => $r['host'], 'versao' => (string)$r['versao'], 'visto_em' => (int)$r['visto_em'], 'token_proprio' => isset($tok[strtoupper($r['host'])])];
        }
        responderJson(200, ['pacotes' => softwareListar($db), 'maquinas' => $maq, 'limite_mb' => round(softwareMaxBytes($cfg) / 1048576)]);
    }
    if ($rota === '/api/software/tarefas' && $metodo === 'GET') {
        $exigirAdmin();
        $pid = isset($_GET['pid']) ? (string)$_GET['pid'] : '';
        if ($pid !== '' && !preg_match('/^[0-9a-f]{32}$/', $pid)) responderJson(400, ['erro' => 'pacote invalido']);
        responderJson(200, ['tarefas' => softwareTarefas($db, $pid)]);
    }
    if ($rota === '/api/software' && $metodo === 'POST') {
        $exigirAdmin(); $exigirReauth();
        $j = corpoJson(16384);
        $r = softwareCriar($db, $cfg, $agora, $sessao['login'], isset($j['manifesto']) ? $j['manifesto'] : '', isset($j['assinatura']) ? $j['assinatura'] : '');
        if (isset($r['erro'])) responderJson($r['status'], ['erro' => $r['erro']]);
        $m = json_decode($j['manifesto'], true);
        auditar($db, $agora, $ip, $sessao['login'], 'software_cadastrado', $m['nome'] . ' (' . $m['tipo'] . ', ' . $m['tamanho'] . ' bytes)');
        responderJson(200, $r);
    }
    if ($rota === '/api/software/arquivo' && $metodo === 'PUT') {
        $exigirAdmin();
        @set_time_limit(600);
        $r = softwareReceberArquivo($db, $cfg, isset($_GET['pid']) ? (string)$_GET['pid'] : '');
        if (isset($r['erro'])) responderJson($r['status'], ['erro' => $r['erro']]);
        auditar($db, $agora, $ip, $sessao['login'], 'software_arquivo', (string)$_GET['pid'] . ' ' . $r['bytes'] . ' bytes');
        responderJson(200, $r);
    }
    if ($rota === '/api/software' && $metodo === 'DELETE') {
        $exigirAdmin(); $exigirReauth();
        $pid = isset($_GET['pid']) ? (string)$_GET['pid'] : '';
        $r = softwareExcluir($db, $cfg, $pid);
        if (isset($r['erro'])) responderJson($r['status'], ['erro' => $r['erro']]);
        auditar($db, $agora, $ip, $sessao['login'], 'software_excluido', $pid);
        responderJson(200, $r);
    }
    if ($rota === '/api/software/instalar' && $metodo === 'POST') {
        $exigirAdmin(); $exigirReauth();
        $j = corpoJson(65536);
        $pid = isset($j['pid']) ? (string)$j['pid'] : '';
        $acao = isset($j['acao']) ? (string)$j['acao'] : 'instalar';
        $r = softwareInstalar($db, $agora, $sessao['login'], $pid, isset($j['hosts']) ? $j['hosts'] : null, $acao);
        if (isset($r['erro'])) responderJson($r['status'], ['erro' => $r['erro']]);
        auditar($db, $agora, $ip, $sessao['login'], $acao === 'desinstalar' ? 'software_desinstalar' : 'software_instalar', $pid . ' em ' . $r['criadas'] . ' maquina(s)');
        responderJson(200, $r);
    }
    if ($rota === '/api/software/politica' && $metodo === 'POST') {
        $exigirAdmin(); $exigirReauth();
        $j = corpoJson(2048);
        $pid = isset($j['pid']) ? (string)$j['pid'] : '';
        $r = softwarePolitica($db, $pid, !empty($j['auto']), isset($j['alvo']) ? $j['alvo'] : '');
        if (isset($r['erro'])) responderJson($r['status'], ['erro' => $r['erro']]);
        auditar($db, $agora, $ip, $sessao['login'], 'software_politica', $pid . ' auto=' . ($r['auto'] ? 'sim' : 'nao') . ' alvo=' . ($r['alvo'] === '' ? 'todas' : $r['alvo']));
        responderJson(200, $r);
    }
    if (($rota === '/api/software/tarefas/cancelar' || $rota === '/api/software/tarefas/repetir') && $metodo === 'POST') {
        $exigirAdmin(); $exigirReauth();
        $j = corpoJson(1024);
        $id = isset($j['id']) ? (int)$j['id'] : 0;
        $rep = $rota === '/api/software/tarefas/repetir';
        $r = $rep ? softwareRepetirTarefa($db, $agora, $sessao['login'], $id) : softwareCancelarTarefa($db, $id);
        if (isset($r['erro'])) responderJson($r['status'], ['erro' => $r['erro']]);
        auditar($db, $agora, $ip, $sessao['login'], $rep ? 'software_repetir' : 'software_cancelar', 'tarefa ' . $id);
        responderJson(200, $r);
    }
    // Marca/desmarca uma maquina como servidor (admin): no painel aparece "ultimo usuario logado" em vez do colaborador.
    if ($rota === '/api/servidores' && $metodo === 'POST') {
        $exigirAdmin();
        $j = corpoJson(1024);
        $host = strtoupper(trim(cortar(isset($j['host']) ? $j['host'] : '', 100)));
        if ($host === '') responderJson(400, ['erro' => 'host obrigatorio']);
        if (!empty($j['servidor'])) {
            $db->prepare('INSERT OR IGNORE INTO servidores (host, criado_em, por) VALUES (?,?,?)')->execute([$host, $agora, $sessao['login']]);
            auditar($db, $agora, $ip, $sessao['login'], 'servidor_marcado', $host);
        } else {
            $db->prepare('DELETE FROM servidores WHERE host = ?')->execute([$host]);
            auditar($db, $agora, $ip, $sessao['login'], 'servidor_desmarcado', $host);
        }
        responderJson(200, ['ok' => true]);
    }
    if ($rota === '/api/maquinas' && $metodo === 'DELETE') {
        $exigirAdmin();
        $host = trim(cortar(isset($_GET['host']) ? $_GET['host'] : '', 100));
        if ($host === '') responderJson(400, ['erro' => 'host obrigatorio']);
        $st = $db->prepare('DELETE FROM registros WHERE host = ?'); $st->execute([$host]);
        $n = $st->rowCount();
        $db->prepare('DELETE FROM maquinas_ocultas WHERE host = ?')->execute([$host]);
        auditar($db, $agora, $ip, $sessao['login'], 'maquina_excluida', $host . ' (' . $n . ' leituras)');
        responderJson(200, ['ok' => true, 'leituras_removidas' => $n]);
    }
    // Recomeca as leituras do zero (admin). Mantem usuarios do painel, regras de classificacao e, por padrao, o cadastro
    // de colaboradores (nomes/setores). Exige digitar ZERAR; fica na auditoria.
    if ($rota === '/api/leituras/zerar' && $metodo === 'POST') {
        $exigirAdmin();
        $exigirReauth();
        $j = corpoJson(MAX_CORPO);
        if (!is_array($j) || !isset($j['confirmacao']) || $j['confirmacao'] !== 'ZERAR') responderJson(400, ['erro' => 'confirmacao invalida: digite ZERAR']);
        $tabelas = ['registros', 'presenca_dia', 'navegacao', 'nav_dia', 'agentes', 'maquinas_ocultas'];
        if (!empty($j['colaboradores'])) $tabelas[] = 'colaboradores';
        $tot = [];
        $db->beginTransaction();
        try {
            foreach ($tabelas as $t) $tot[$t] = (int)$db->exec('DELETE FROM ' . $t);
            $db->commit();
        } catch (Throwable $e) { $db->rollBack(); throw $e; }
        try { $db->exec('VACUUM'); } catch (Throwable $e) { /* so reduz o arquivo */ }
        auditar($db, $agora, $ip, $sessao['login'], 'leituras_zeradas', json_encode($tot));
        responderJson(200, ['ok' => true, 'removidos' => $tot]);
    }

    if ($rota === '/api/historico' && $metodo === 'GET') {
        $host = isset($_GET['host']) ? (string)$_GET['host'] : '';
        if ($host === '') responderJson(400, ['erro' => 'host obrigatorio']);
        $horas = isset($_GET['horas']) && is_numeric($_GET['horas']) ? (float)$_GET['horas'] : 48;
        if ($horas <= 0) $horas = 48;
        $horas = min(max($horas, 1), 24 * 30);
        $st = $db->prepare('SELECT ts, data_hora, resultado, unidade, vpn_ativa, confianca, sessao_remota, bloqueada, ocioso_seg, motivo
            FROM registros WHERE host = ? AND ts > ? ORDER BY ts DESC LIMIT 500');
        $st->execute([$host, $agora - (int)($horas * 3600000)]);
        $itens = $st->fetchAll();
        foreach ($itens as &$it) {
            $it['ts'] = (int)$it['ts'];
            $it['ocioso_seg'] = $it['ocioso_seg'] === null ? null : (int)$it['ocioso_seg'];
        }
        unset($it);
        responderJson(200, ['host' => $host, 'itens' => $itens]);
    }

    if ($rota === '/api/resumo' && $metodo === 'GET') {
        $dias = isset($_GET['dias']) && is_numeric($_GET['dias']) ? (int)$_GET['dias'] : 14;
        if ($dias <= 0) $dias = 14;
        $dias = min(max($dias, 1), 90);
        $st = $db->prepare('SELECT host, ts, resultado, unidade FROM registros WHERE ts > ?');
        $st->execute([$agora - $dias * 86400000]);
        $tz = fusoDe($cfg);
        $porDiaHost = [];
        while ($l = $st->fetch()) {
            $dia = diaLocal($l['ts'], $tz);
            $chave = $dia . '|' . $l['host'];
            if (!isset($porDiaHost[$chave])) $porDiaHost[$chave] = ['res' => [], 'uni' => []];
            $porDiaHost[$chave]['res'][$l['resultado']] = (isset($porDiaHost[$chave]['res'][$l['resultado']]) ? $porDiaHost[$chave]['res'][$l['resultado']] : 0) + 1;
            if (ehPresencial($l['resultado']) && $l['unidade'] !== '' && $l['unidade'] !== null) {
                $porDiaHost[$chave]['uni'][$l['unidade']] = (isset($porDiaHost[$chave]['uni'][$l['unidade']]) ? $porDiaHost[$chave]['uni'][$l['unidade']] : 0) + 1;
            }
        }
        $dias_ = [];
        foreach ($porDiaHost as $chave => $e) {
            $dia = explode('|', $chave, 2)[0];
            if (!isset($dias_[$dia])) $dias_[$dia] = ['dia' => $dia, 'total' => 0, 'resultados' => [], 'unidades' => []];
            arsort($e['res']); $r = array_keys($e['res'])[0];
            $dias_[$dia]['total']++;
            $dias_[$dia]['resultados'][$r] = (isset($dias_[$dia]['resultados'][$r]) ? $dias_[$dia]['resultados'][$r] : 0) + 1;
            if (ehPresencial($r)) {
                $u = '?';
                if ($e['uni']) { arsort($e['uni']); $u = array_keys($e['uni'])[0]; }
                $dias_[$dia]['unidades'][$u] = (isset($dias_[$dia]['unidades'][$u]) ? $dias_[$dia]['unidades'][$u] : 0) + 1;
            }
        }
        ksort($dias_);
        $out = [];
        foreach ($dias_ as $d) {
            $d['resultados'] = (object)$d['resultados'];
            $d['unidades'] = (object)$d['unidades'];
            $out[] = $d;
        }
        responderJson(200, ['itens' => $out]);
    }

    // --- produtividade e BI ---
    if ($rota === '/api/produtividade' && $metodo === 'GET') {
        list($de, $ate) = periodoDe($_GET, $cfg, $agora);
        responderJson(200, relatorioProdutividade($db, $cfg, $de, $ate));
    }
    if ($rota === '/api/bi' && $metodo === 'GET') {
        list($de, $ate) = periodoDe($_GET, $cfg, $agora, 30);
        // ?logins=a,b filtra todos os indicadores, graficos e listas para esses colaboradores (busca do painel)
        responderJson(200, relatorioBI($db, $cfg, $de, $ate, $agora, true, loginsDaConsulta($_GET)));
    }
    // Relatorio de produtividade (so admin: tem nomes de pessoas): mensal (?tipo=mensal&mes=AAAA-MM), semanal (?tipo=semanal&data=AAAA-MM-DD,
    // a semana de segunda a domingo que contem a data) ou periodo livre (?tipo=personalizado&de=...&ate=..., ate 92 dias). Calcula na hora.
    if ($rota === '/api/relatorio' && $metodo === 'GET') {
        $exigirAdmin();
        $tipo = isset($_GET['tipo']) ? (string)$_GET['tipo'] : 'mensal';
        $hojeRel = diaLocal($agora, fusoDe($cfg));
        $ref = ''; $deL = null; $ateL = null;
        if ($tipo === 'mensal') {
            $ref = isset($_GET['mes']) ? (string)$_GET['mes'] : '';
            if (!preg_match('/^(\d{4})-(0[1-9]|1[0-2])$/', $ref)) responderJson(400, ['erro' => 'mes obrigatorio no formato AAAA-MM']);
            if ($ref . '-01' > $hojeRel) responderJson(400, ['erro' => 'mes no futuro']);
        } elseif ($tipo === 'semanal') {
            $ref = isset($_GET['data']) ? (string)$_GET['data'] : $hojeRel;
            if (!dataValida($ref)) responderJson(400, ['erro' => 'data invalida (AAAA-MM-DD)']);
            if ($ref > $hojeRel) responderJson(400, ['erro' => 'data no futuro']);
        } elseif ($tipo === 'personalizado') {
            $deL = isset($_GET['de']) ? (string)$_GET['de'] : ''; $ateL = isset($_GET['ate']) ? (string)$_GET['ate'] : '';
            if (!dataValida($deL) || !dataValida($ateL)) responderJson(400, ['erro' => 'de e ate obrigatorios (AAAA-MM-DD)']);
            if ($deL > $ateL) responderJson(400, ['erro' => 'a data inicial e depois da final']);
            if ($ateL > $hojeRel) $ateL = $hojeRel;
            if ($deL > $hojeRel) responderJson(400, ['erro' => 'periodo no futuro']);
            if ((strtotime($ateL) - strtotime($deL)) / 86400 + 1 > 92) responderJson(400, ['erro' => 'periodo de ate 92 dias']);
            $ref = $deL . '_' . $ateL;
        } else responderJson(400, ['erro' => 'tipo deve ser mensal, semanal ou personalizado']);
        // com ?login=...: relatorio INDIVIDUAL da pessoa, no mesmo modelo
        $loginRel = isset($_GET['login']) ? loginDe((string)$_GET['login']) : '';
        if ($loginRel !== '') {
            if (!relIndividualExiste($db, $loginRel, mapaColaboradores($db))) responderJson(404, ['erro' => 'colaborador nao encontrado']);
            auditar($db, $agora, $ip, $sessao['login'], 'relatorio', $tipo . ' ' . $ref . ' individual ' . $loginRel);
            responderJson(200, montarRelatorioIndividual($db, $cfg, $loginRel, $tipo, $ref, $deL, $ateL, $agora));
        }
        auditar($db, $agora, $ip, $sessao['login'], 'relatorio', $tipo . ' ' . $ref);
        responderJson(200, montarRelatorio($db, $cfg, $tipo, $ref, $deL, $ateL, $agora));
    }

    // Tokens da API de dados (admin): criar (o valor aparece uma unica vez), listar e revogar
    if ($rota === '/api/api-tokens' && $metodo === 'GET') {
        $exigirAdmin();
        responderJson(200, ['itens' => listarApiTokens($db, $agora)]);
    }
    if ($rota === '/api/api-tokens' && $metodo === 'POST') {
        $exigirAdmin();
        $exigirReauth();
        $j = corpoJson(2048);
        $r = criarApiToken($db, $agora, isset($j['nome']) ? $j['nome'] : '', isset($j['validade_dias']) ? $j['validade_dias'] : 90, !empty($j['anonimizar']), $sessao['login']);
        if (isset($r['erro'])) responderJson(400, ['erro' => $r['erro']]);
        auditar($db, $agora, $ip, $sessao['login'], 'api_token_criado', $r['nome'] . ' (' . $r['prefixo'] . ')' . ($r['anonimizar'] ? ' pseudonimizado' : ''));
        responderJson(201, $r);
    }
    if ($rota === '/api/api-tokens' && $metodo === 'DELETE') {
        $exigirAdmin();
        $id = isset($_GET['id']) && ctype_digit((string)$_GET['id']) ? (int)$_GET['id'] : 0;
        if ($id <= 0 || !revogarApiToken($db, $id, $agora)) responderJson(404, ['erro' => 'token nao encontrado ou ja revogado']);
        auditar($db, $agora, $ip, $sessao['login'], 'api_token_revogado', '#' . $id);
        responderJson(200, ['ok' => true]);
    }

    // Comparativo Home x Presencial: dado sensivel, so administradores (?logins=a,b acompanha a busca do painel)
    if ($rota === '/api/comparativo' && $metodo === 'GET') {
        $exigirAdmin();
        list($de, $ate) = periodoDe($_GET, $cfg, $agora, 30);
        responderJson(200, relatorioComparativo($db, cfgComparativo($cfg, $_GET), $de, $ate, $agora, loginsDaConsulta($_GET)));
    }
    if ($rota === '/api/colaborador' && $metodo === 'GET') {
        $login = loginDe(isset($_GET['login']) ? $_GET['login'] : '');
        if ($login === '') responderJson(400, ['erro' => 'login obrigatorio']);
        list($de, $ate) = periodoDe($_GET, $cfg, $agora, 30);
        responderJson(200, detalheColaborador($db, $cfg, $login, $de, $ate, $agora));
    }

    // --- exportacoes CSV ---
    if (strncmp($rota, '/api/export/', 12) === 0 && $metodo === 'GET') {
        $tipo = substr($rota, 12);
        // Inventario no modelo do "Relatorio de Ativos" (CSV) ou em Excel (com o historico de alteracoes de hardware)
        if ($tipo === 'inventario.csv' || $tipo === 'inventario.xlsx') {
            auditar($db, $agora, $ip, $sessao['login'], 'exportacao', $tipo);
            $dia = (new DateTime('@' . intdiv($agora, 1000)))->setTimezone(fusoDe($cfg))->format('d.m.Y');
            if ($tipo === 'inventario.csv') {
                $tz = fusoDe($cfg);
                $linhas = [];
                foreach (listarInventario($db, $agora) as $a) $linhas[] = invLinhaRelatorio($a, $tz, false);
                enviarCsv('Relatorio de Ativos - ' . $dia . '.csv', invColunasRelatorio(), $linhas);
            }
            $bin = gerarXlsx([abaInventario($db, $cfg, $agora), abaInventarioHistorico($db, $cfg)], fusoDe($cfg)->getOffset(new DateTime('@' . intdiv($agora, 1000))));
            http_response_code(200);
            cabecalhosBase();
            header('Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
            header('Content-Disposition: attachment; filename="Relatorio_de_Ativos_' . $dia . '.xlsx"');
            header('Content-Length: ' . strlen($bin));
            echo $bin;
            exit;
        }
        // Relatorio completo em Excel: varias abas num arquivo so (acessos detalhados so para administradores)
        if ($tipo === 'relatorio.xlsx') {
            list($de, $ate) = periodoDe($_GET, $cfg, $agora, 30);
            $comAcessos = $ehAdmin && isset($_GET['acessos']) && $_GET['acessos'] === '1';
            auditar($db, $agora, $ip, $sessao['login'], 'exportacao', 'relatorio.xlsx ' . $de . ' a ' . $ate . ($comAcessos ? ' +acessos' : ''));
            @set_time_limit(120);
            $abas = [abaResumo($db, $cfg, $de, $ate, $agora), abaDiaADia($db, $cfg, $de, $ate, $agora), avisoTeto(abaProgramas($db, $cfg, $de, $ate)),
                avisoTeto(abaLocalizacao($db, $cfg, $de, $ate))];
            if ($comAcessos) { $abas[] = avisoTeto(abaAcessos($db, $cfg, $de, $ate)); $abas[] = avisoTeto(abaFocoDetalhado($db, $cfg, $de, $ate)); }
            $bin = gerarXlsx($abas, fusoDe($cfg)->getOffset(new DateTime('@' . intdiv($agora, 1000))));
            http_response_code(200);
            cabecalhosBase();
            header('Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
            header('Content-Disposition: attachment; filename="relatorio_' . $de . '_a_' . $ate . '.xlsx"');
            header('Content-Length: ' . strlen($bin));
            echo $bin;
            exit;
        }
        if (in_array($tipo, ['produtividade.csv', 'presenca.csv', 'navegacao.csv', 'acessos.csv', 'foco.csv', 'leituras.csv'], true)) {
            $per = (isset($_GET['de']) ? preg_replace('/[^0-9-]/', '', (string)$_GET['de']) : '') . ' a ' . (isset($_GET['ate']) ? preg_replace('/[^0-9-]/', '', (string)$_GET['ate']) : '');
            auditar($db, $agora, $ip, $sessao['login'], 'exportacao', $tipo . ' ' . $per);
        }
        if ($tipo === 'comparativo.csv') {
            $exigirAdmin();
            list($de, $ate) = periodoDe($_GET, $cfg, $agora, 30);
            auditar($db, $agora, $ip, $sessao['login'], 'exportacao', 'comparativo.csv ' . $de . ' a ' . $ate);
            $r = relatorioComparativo($db, cfgComparativo($cfg, $_GET), $de, $ate, $agora, loginsDaConsulta($_GET));
            $linhas = [];
            $min = function ($s) { return $s === null ? '' : horasMin($s); };
            foreach ($r['colaboradores'] as $c) {
                $p = $c['presencial']; $m = $c['remoto'];
                $linhas[] = [$c['colaborador'], $c['nome'], $c['login'], $c['setor'],
                    $p['dias'], $m['dias'], $p['pct_produtivo'], $m['pct_produtivo'], $c['dif_pct'],
                    $min($p['prod_seg_dia']), $min($m['prod_seg_dia']),
                    $min($p['total_seg_dia']), $min($m['total_seg_dia'])];
            }
            enviarCsv("home_x_presencial_{$de}_a_{$ate}.csv",
                ['Colaborador', 'Nome', 'Login', 'Setor', 'Dias presenciais', 'Dias remotos', '% produtivo presencial', '% produtivo remoto', 'Diferenca (remoto - presencial, pontos)',
                 'Min produtivos por dia (presencial)', 'Min produtivos por dia (remoto)', 'Min de uso por dia (presencial)', 'Min de uso por dia (remoto)'], $linhas);
        }
        if ($tipo === 'produtividade.csv') {
            list($de, $ate) = periodoDe($_GET, $cfg, $agora);
            $r = relatorioProdutividade($db, $cfg, $de, $ate);
            $linhas = [];
            foreach ($r['colaboradores'] as $c) {
                $linhas[] = [$c['colaborador'], $c['nome'], $c['login'], $c['setor'],
                    horasMin($c['segundos']['produtivo']), horasMin($c['segundos']['improdutivo']), horasMin($c['segundos']['neutro']), horasMin($c['total_seg']),
                    $c['visitas']['produtivo'], $c['visitas']['improdutivo'], $c['visitas']['neutro'],
                    $c['pct_produtivo'], $c['pct_improdutivo']];
            }
            enviarCsv("produtividade_{$de}_a_{$ate}.csv",
                ['Colaborador', 'Nome', 'Login', 'Setor', 'Min produtivo', 'Min improdutivo', 'Min neutro', 'Min total',
                 'Acessos produtivos', 'Acessos improdutivos', 'Acessos neutros', '% produtivo (prod/(prod+improd))', '% improdutivo'], $linhas);
        }
        if ($tipo === 'presenca.csv') {
            list($de, $ate, $hoje) = periodoDe($_GET, $cfg, $agora, 30);
            $colabs = mapaColaboradores($db);
            $porDia = presencaPorDia($db, $de, $ate);
            $dias = diasUteis($de, $ate, $cfg);
            $inicios = primeiroDiaPorLogin($db);
            $linhas = [];
            foreach ($porDia as $l => $dd) {
                $res = resumoPresenca($dias, $dd, $cfg, $hoje, isset($inicios[$l]) ? $inicios[$l] : '');
                $i = identidade($l, $colabs);
                foreach ($res['detalhe'] as $d) $linhas[] = [$i['colaborador'], $i['login'], $d['dia'], $d['status'], $d['unidade'], $d['leituras_presenciais'], $d['leituras_total']];
            }
            usort($linhas, function ($a, $b) { return strcasecmp($a[0] . $a[2], $b[0] . $b[2]); });
            enviarCsv("presenca_{$de}_a_{$ate}.csv", ['Colaborador', 'Login', 'Dia', 'Situacao do dia', 'Unidade', 'Leituras presenciais', 'Leituras com rede'], $linhas);
        }
        // CSVs completos em fluxo (sem limite de linhas), so administradores: para o BI / periodo inteiro
        if (in_array($tipo, ['navegacao.csv', 'acessos.csv', 'foco.csv', 'leituras.csv'], true)) {
            $exigirAdmin();
            list($de, $ate) = periodoDe($_GET, $cfg, $agora);
            if ($tipo === 'foco.csv') csvFoco($db, $cfg, $de, $ate);
            if ($tipo === 'leituras.csv') csvLeituras($db, $cfg, $de, $ate);
            csvAcessos($db, $cfg, $de, $ate);
        }
        responderJson(404, ['erro' => 'nao encontrado']);
    }

    // --- colaboradores ---
    // Importa o cadastro do RH (cargo e centro de custo): o painel le o CSV e manda as linhas (login e/ou nome, cargo, centro_custo)
    if ($rota === '/api/colaboradores/importar-rh' && $metodo === 'POST') {
        $exigirAdmin();
        $j = corpoJson(2097152);
        if (!isset($j['linhas']) || !is_array($j['linhas'])) responderJson(400, ['erro' => 'linhas obrigatorias']);
        $res = importarRh($db, $j['linhas'], $agora);
        auditar($db, $agora, $ip, $sessao['login'], 'rh_importado', $res['atualizados'] . ' atualizados, ' . $res['total_nao_encontrados'] . ' nao encontrados');
        responderJson(200, $res);
    }
    if ($rota === '/api/colaboradores' && $metodo === 'GET') {
        $colabs = mapaColaboradores($db);
        $out = [];
        // dados do RH (cargo, centro de custo, jornada) so para administradores
        foreach ($colabs as $l => $c) $out[] = identidade($l, $colabs) + ['ativo' => $c['ativo']]
            + ($ehAdmin ? ['cargo' => $c['cargo'], 'centro_custo' => $c['centro_custo'], 'rh' => $c['rh'], 'jornada_horas' => $c['jornada_horas']] : []);
        usort($out, function ($a, $b) { return strcasecmp($a['colaborador'], $b['colaborador']); });
        responderJson(200, ['itens' => $out]);
    }
    if ($rota === '/api/colaboradores' && $metodo === 'PUT') {
        $exigirAdmin();
        $j = corpoJson(4096);
        $login = loginDe(isset($j['login']) ? $j['login'] : '');
        if ($login === '') responderJson(400, ['erro' => 'login obrigatorio']);
        $st = $db->prepare('SELECT * FROM colaboradores WHERE login = ?'); $st->execute([$login]);
        $c = $st->fetch();
        if (!$c) responderJson(404, ['erro' => 'colaborador nao encontrado']);
        $nome = $c['nome']; $manual = (int)$c['nome_manual'];
        if (array_key_exists('nome', $j)) { $nome = trim(cortar($j['nome'], 150)); $manual = $nome === '' ? 0 : 1; }
        $setor = array_key_exists('setor', $j) ? trim(cortar($j['setor'], 60)) : $c['setor'];
        $ativo = array_key_exists('ativo', $j) ? ($j['ativo'] ? 1 : 0) : (int)$c['ativo'];
        $cargo = array_key_exists('cargo', $j) ? trim(cortar($j['cargo'], 80)) : (string)$c['cargo'];
        $cc = array_key_exists('centro_custo', $j) ? trim(cortar($j['centro_custo'], 120)) : (string)$c['centro_custo'];
        $jornada = array_key_exists('jornada_horas', $j) ? jornadaDeTexto($j['jornada_horas']) : ($c['jornada_horas'] === null ? null : (float)$c['jornada_horas']);
        $rh = ($cargo !== '' || $cc !== '') ? 1 : 0;   // com cargo ou centro de custo preenchido, a pessoa tem vinculo com o RH
        auditar($db, $agora, $ip, $sessao['login'], 'colaborador_alterado', $login);
        $db->prepare('UPDATE colaboradores SET nome = ?, nome_manual = ?, setor = ?, ativo = ?, cargo = ?, centro_custo = ?, jornada_horas = ?, rh = ?, rh_em = CASE WHEN ? = 1 THEN COALESCE(rh_em, ?) ELSE NULL END, atualizado_em = ? WHERE login = ?')
           ->execute([$nome, $manual, $setor, $ativo, $cargo, $cc, $jornada, $rh, $rh, $agora, $agora, $login]);
        responderJson(200, ['ok' => true]);
    }
    // Exclusao definitiva de um colaborador (admin): leituras de presenca, resumo diario, sites acessados e cadastro.
    // Se o PC dele continuar com o agent instalado e enviando dados, ele volta a aparecer.
    if ($rota === '/api/colaboradores' && $metodo === 'DELETE') {
        $exigirAdmin();
        $exigirReauth();
        $login = loginDe(isset($_GET['login']) ? (string)$_GET['login'] : '');
        if ($login === '') responderJson(400, ['erro' => 'login obrigatorio']);
        $st = $db->prepare('SELECT COUNT(*) FROM colaboradores WHERE login = ?'); $st->execute([$login]);
        $existe = (int)$st->fetchColumn() > 0;
        $st = $db->prepare('SELECT COUNT(*) FROM registros WHERE login = ?'); $st->execute([$login]);
        if (!$existe && (int)$st->fetchColumn() === 0) responderJson(404, ['erro' => 'colaborador nao encontrado']);
        $tot = [];
        $db->beginTransaction();
        try {
            $st = $db->prepare('SELECT DISTINCT host FROM registros WHERE login = ?'); $st->execute([$login]);
            $hosts = $st->fetchAll(PDO::FETCH_COLUMN);
            foreach (['registros', 'presenca_dia', 'navegacao', 'nav_dia', 'foco', 'foco_dia', 'atividade_dia', 'colaboradores'] as $t) {
                $d = $db->prepare('DELETE FROM ' . $t . ' WHERE login = ?'); $d->execute([$login]);
                $tot[$t] = $d->rowCount();
            }
            // maquinas que ficaram sem nenhuma leitura de outra pessoa saem da lista de versoes/ocultas
            foreach ($hosts as $h) {
                $c = $db->prepare('SELECT COUNT(*) FROM registros WHERE host = ?'); $c->execute([$h]);
                if ((int)$c->fetchColumn() === 0) {
                    $db->prepare('DELETE FROM agentes WHERE host = ?')->execute([$h]);
                    $db->prepare('DELETE FROM maquinas_ocultas WHERE host = ?')->execute([$h]);
                }
            }
            $db->commit();
        } catch (Throwable $e) { $db->rollBack(); throw $e; }
        auditar($db, $agora, $ip, $sessao['login'], 'colaborador_excluido', $login . ' ' . json_encode($tot));
        responderJson(200, ['ok' => true, 'removidos' => $tot]);
    }

    // --- regras de classificacao (admin escreve) ---
    if ($rota === '/api/regras' && $metodo === 'GET') {
        $itens = $db->query('SELECT id, padrao, categoria, criado_por FROM regras ORDER BY categoria, padrao')->fetchAll();
        responderJson(200, ['itens' => $itens, 'auto_ativo' => classificacaoAutomaticaAtiva($db)]);
    }
    // Classificacao automatica (admin): aplica o catalogo/regras por padrao aos sites e programas sem regra do periodo.
    // As regras criadas ficam marcadas como 'auto' (visiveis, editaveis e removiveis); o que nao tem sugestao continua na lista.
    if ($rota === '/api/regras/auto' && $metodo === 'POST') {
        $exigirAdmin();
        list($de, $ate) = periodoDe($_GET, $cfg, $agora, 30);
        $stD = $db->prepare('SELECT DISTINCT dominio FROM nav_dia WHERE dia >= ? AND dia <= ?');
        $stD->execute([$de, $ate]);
        $stP = $db->prepare('SELECT DISTINCT processo FROM foco_dia WHERE dia >= ? AND dia <= ?');
        $stP->execute([$de, $ate]);
        $db->beginTransaction();
        try { $r = aplicarSugestoes($db, $agora, $stD->fetchAll(PDO::FETCH_COLUMN), $stP->fetchAll(PDO::FETCH_COLUMN)); $db->commit(); }
        catch (Throwable $e) { $db->rollBack(); throw $e; }
        $r['restantes'] = contarSemRegra($db, $de, $ate);
        auditar($db, $agora, $ip, $sessao['login'], 'regras_automaticas', $r['aplicadas'] . ' regra(s): ' . json_encode($r['por_categoria']) . '; restam ' . $r['restantes']['sites'] . ' site(s) e ' . $r['restantes']['programas'] . ' programa(s)');
        responderJson(200, $r);
    }
    if ($rota === '/api/regras/auto' && $metodo === 'DELETE') {
        $exigirAdmin();
        $st = $db->prepare("DELETE FROM regras WHERE criado_por = 'auto'");
        $st->execute();
        auditar($db, $agora, $ip, $sessao['login'], 'regras_automaticas_desfeitas', $st->rowCount() . ' regra(s)');
        responderJson(200, ['ok' => true, 'removidas' => $st->rowCount()]);
    }
    if ($rota === '/api/regras/auto-config' && $metodo === 'PUT') {
        $exigirAdmin();
        $j = corpoJson(512);
        $ativo = !empty($j['ativo']);
        metaSet($db, 'classificar_auto', $ativo ? '1' : '0');
        auditar($db, $agora, $ip, $sessao['login'], 'classificacao_auto_config', $ativo ? 'ligada' : 'desligada');
        responderJson(200, ['ok' => true, 'auto_ativo' => $ativo]);
    }
    if ($rota === '/api/regras' && $metodo === 'POST') {
        $exigirAdmin();
        $j = corpoJson(2048);
        $praw = isset($j['padrao']) ? $j['padrao'] : '';
        $p = strncasecmp(trim((string)$praw), 'app:', 4) === 0 ? normalizarPadraoApp($praw) : normalizarPadrao($praw);
        $cat = isset($j['categoria']) ? $j['categoria'] : '';
        if ($p === null) responderJson(400, ['erro' => 'padrao invalido (ex.: youtube.com ou app:winword)']);
        if (!in_array($cat, CATEGORIAS, true)) responderJson(400, ['erro' => 'categoria invalida']);
        $up = $db->prepare('UPDATE regras SET categoria = ?, criado_por = ? WHERE padrao = ?');
        $up->execute([$cat, $sessao['login'], $p]);
        if ($up->rowCount() === 0) {
            $db->prepare('INSERT INTO regras (padrao, categoria, criado_por, criado_em) VALUES (?,?,?,?)')->execute([$p, $cat, $sessao['login'], $agora]);
        }
        auditar($db, $agora, $ip, $sessao['login'], 'regra_salva', $p . ' = ' . $cat);
        responderJson(200, ['ok' => true, 'padrao' => $p]);
    }
    if ($rota === '/api/regras' && $metodo === 'DELETE') {
        $exigirAdmin();
        $id = isset($_GET['id']) && ctype_digit((string)$_GET['id']) ? (int)$_GET['id'] : 0;
        if ($id <= 0) responderJson(400, ['erro' => 'id invalido']);
        auditar($db, $agora, $ip, $sessao['login'], 'regra_removida', 'id ' . $id);
        $db->prepare('DELETE FROM regras WHERE id = ?')->execute([$id]);
        responderJson(200, ['ok' => true]);
    }
    if ($rota === '/api/dominio' && $metodo === 'GET') {
        $dom = strtolower(trim(cortar(isset($_GET['dominio']) ? $_GET['dominio'] : '', 255)));
        if ($dom === '') responderJson(400, ['erro' => 'dominio obrigatorio']);
        list($de, $ate) = periodoDe($_GET, $cfg, $agora, 30);
        responderJson(200, detalheDominio($db, $cfg, $dom, $de, $ate));
    }
    if ($rota === '/api/programas-sem-regra' && $metodo === 'GET') {
        list($de, $ate) = periodoDe($_GET, $cfg, $agora, 30);
        responderJson(200, ['itens' => programasSemRegra($db, $de, $ate)]);
    }
    if ($rota === '/api/dominios-sem-regra' && $metodo === 'GET') {
        list($de, $ate) = periodoDe($_GET, $cfg, $agora, 30);
        responderJson(200, ['itens' => dominiosSemRegra($db, $de, $ate)]);
    }

    // --- auditoria (admin): quem entrou, de onde, quem exportou/alterou ---
    if ($rota === '/api/auditoria' && $metodo === 'GET') {
        $exigirAdmin();
        $lim = isset($_GET['limite']) && ctype_digit((string)$_GET['limite']) ? min(1000, max(1, (int)$_GET['limite'])) : 200;
        $ev = isset($_GET['evento']) ? preg_replace('/[^a-z0-9_]/', '', strtolower((string)$_GET['evento'])) : '';
        $st = $db->prepare('SELECT id, ts, ip, login, evento, detalhe FROM auditoria' . ($ev !== '' ? ' WHERE evento = ?' : '') . ' ORDER BY id DESC LIMIT ' . $lim);
        $st->execute($ev !== '' ? [$ev] : []);
        $itens = $st->fetchAll();
        foreach ($itens as &$x) { $x['id'] = (int)$x['id']; $x['ts'] = (int)$x['ts']; }
        unset($x);
        responderJson(200, ['itens' => $itens]);
    }

    // --- usuarios do painel (admin) ---
    if ($rota === '/api/usuarios') {
        $exigirAdmin();
        if ($metodo === 'GET') {
            $itens = $db->query('SELECT id, login, nome, papel, ativo, ultimo_login, totp_ativo FROM usuarios ORDER BY login')->fetchAll();
            foreach ($itens as &$u) { $u['totp_ativo'] = (int)$u['totp_ativo'] === 1; $u['id'] = (int)$u['id']; $u['ativo'] = (int)$u['ativo'] === 1; $u['ultimo_login'] = $u['ultimo_login'] === null ? null : (int)$u['ultimo_login']; }
            unset($u);
            responderJson(200, ['itens' => $itens]);
        }
        $exigirReauth();
        $j = corpoJson(4096);
        if ($metodo === 'POST') {
            $login = strtolower(trim(isset($j['login']) ? (string)$j['login'] : ''));
            if (!preg_match('/^[a-z0-9._-]{3,40}$/', $login)) responderJson(400, ['erro' => 'login invalido (3 a 40 letras minusculas, numeros, . _ -)']);
            if (($pb = senhaProblema(isset($j['senha']) ? $j['senha'] : null, $login)) !== null) responderJson(400, ['erro' => $pb]);
            $papel = isset($j['papel']) && $j['papel'] === 'admin' ? 'admin' : 'gestor';
            $ex = $db->prepare('SELECT 1 FROM usuarios WHERE login = ?'); $ex->execute([$login]);
            if ($ex->fetchColumn()) responderJson(409, ['erro' => 'ja existe um usuario com esse login']);
            $db->prepare('INSERT INTO usuarios (login, nome, senha_hash, papel, ativo, criado_em) VALUES (?,?,?,?,1,?)')
               ->execute([$login, trim(cortar(isset($j['nome']) ? $j['nome'] : '', 100)), password_hash($j['senha'], PASSWORD_DEFAULT), $papel, $agora]);
            auditar($db, $agora, $ip, $sessao['login'], 'usuario_criado', $login . ' (' . $papel . ')');
            responderJson(200, ['ok' => true]);
        }
        if ($metodo === 'PUT') {
            $id = isset($j['id']) && is_numeric($j['id']) ? (int)$j['id'] : 0;
            $st = $db->prepare('SELECT * FROM usuarios WHERE id = ?'); $st->execute([$id]);
            $u = $st->fetch();
            if (!$u) responderJson(404, ['erro' => 'usuario nao encontrado']);
            $papel = array_key_exists('papel', $j) ? ($j['papel'] === 'admin' ? 'admin' : 'gestor') : $u['papel'];
            $ativo = array_key_exists('ativo', $j) ? ($j['ativo'] ? 1 : 0) : (int)$u['ativo'];
            $nome = array_key_exists('nome', $j) ? trim(cortar($j['nome'], 100)) : $u['nome'];
            if ((int)$u['id'] === (int)$sessao['id'] && ($papel !== 'admin' || $ativo !== 1)) responderJson(400, ['erro' => 'voce nao pode remover o proprio acesso de administrador']);
            if (array_key_exists('senha', $j) && $j['senha'] !== '' ) {
                if (($pb = senhaProblema($j['senha'], $u['login'])) !== null) responderJson(400, ['erro' => $pb]);
                $db->prepare('UPDATE usuarios SET senha_hash = ?, falhas = 0, bloqueado_ate = 0 WHERE id = ?')->execute([password_hash($j['senha'], PASSWORD_DEFAULT), $id]);
                $db->prepare('DELETE FROM sessoes WHERE usuario_id = ?')->execute([$id]);
            }
            $db->prepare('UPDATE usuarios SET nome = ?, papel = ?, ativo = ?, bloqueado_ate = CASE WHEN ? = 1 THEN bloqueado_ate ELSE 0 END WHERE id = ?')->execute([$nome, $papel, $ativo, $ativo, $id]);
            if ($ativo !== 1) $db->prepare('DELETE FROM sessoes WHERE usuario_id = ?')->execute([$id]);
            if (!empty($j['reset_2fa'])) {
                $db->prepare('UPDATE usuarios SET totp_ativo = 0, totp_secret = NULL, totp_recuperacao = NULL, totp_passo = 0 WHERE id = ?')->execute([$id]);
                auditar($db, $agora, $ip, $sessao['login'], '2fa_resetado', $u['login']);
            }
            $mud = [];
            if ($papel !== $u['papel']) $mud[] = 'papel ' . $u['papel'] . '->' . $papel;
            if ($ativo !== (int)$u['ativo']) $mud[] = $ativo ? 'ativado' : 'desativado';
            if (array_key_exists('senha', $j) && $j['senha'] !== '') $mud[] = 'senha redefinida';
            if ($nome !== $u['nome']) $mud[] = 'nome';
            if ($mud) auditar($db, $agora, $ip, $sessao['login'], 'usuario_alterado', $u['login'] . ': ' . implode(', ', $mud));
            responderJson(200, ['ok' => true]);
        }
    }

    // --- arquivos do painel (somente .js/.css/.html da pasta public) ---
    if ($metodo === 'GET') {
        if ($rota === '/' || $rota === '/index.html') servirArquivo($cfg, 'index.html', 'text/html; charset=utf-8');
        if (preg_match('#^/([a-z0-9_-]+)\.(js|css)$#', $rota, $m)) {
            if (is_file($cfg['public_dir'] . '/' . $m[1] . '.' . $m[2])) servirArquivo($cfg, $m[1] . '.' . $m[2], tipoDe($m[2]));
        }
    }
    responderJson(404, ['erro' => 'nao encontrado']);
} catch (Throwable $e) {
    error_log('presenca: ' . $e->getMessage());
    responderJson(500, ['erro' => 'erro interno']);
}
