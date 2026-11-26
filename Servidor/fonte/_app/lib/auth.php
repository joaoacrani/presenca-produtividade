<?php
// Login do painel: usuarios no banco, senha com password_hash, sessao por cookie (guardada como hash no banco),
// token CSRF para escritas, bloqueio temporario apos tentativas erradas.

const COOKIE_SESSAO = 'presenca_sessao';
const MAX_FALHAS = 5;
const BLOQUEIO_MS = 15 * 60000;
const MAX_FALHAS_CONTA = 30;     // falhas de qualquer origem que bloqueiam a conta (defesa contra ataque distribuido)
const REAUTH_MS = 5 * 60000;     // quanto tempo vale a reconfirmacao de senha para acoes sensiveis

function tokenAgenteValido($cfg)
{
    $h = cabecalhoAuth();
    return strncmp($h, 'Bearer ', 7) === 0 && iguais(substr($h, 7), $cfg['agent_token']);
}

function cookieOpcoes($base, $expiraSeg)
{
    return ['expires' => $expiraSeg, 'path' => ($base === '' ? '/' : $base . '/'), 'secure' => ehHttps(), 'httponly' => true, 'samesite' => 'Strict'];
}

function iniciarSessao(PDO $db, $cfg, $usuarioId, $agora, $base)
{
    $tok = bin2hex(random_bytes(32));
    $expira = $agora + (int)($cfg['sessao_horas'] * 3600000);
    $db->prepare('INSERT INTO sessoes (hash, usuario_id, csrf, expira, criado_em) VALUES (?,?,?,?,?)')
       ->execute([hash('sha256', $tok), $usuarioId, bin2hex(random_bytes(16)), $expira, $agora]);
    setcookie(COOKIE_SESSAO, $tok, cookieOpcoes($base, intdiv($expira, 1000)));
}

function encerrarSessao(PDO $db, $base)
{
    if (!empty($_COOKIE[COOKIE_SESSAO]) && is_string($_COOKIE[COOKIE_SESSAO])) {
        $db->prepare('DELETE FROM sessoes WHERE hash = ?')->execute([hash('sha256', $_COOKIE[COOKIE_SESSAO])]);
    }
    setcookie(COOKIE_SESSAO, '', cookieOpcoes($base, 1));
}

// Devolve o usuario logado (com 'csrf') ou null.
function sessaoAtual(PDO $db, $agora)
{
    $tok = isset($_COOKIE[COOKIE_SESSAO]) && is_string($_COOKIE[COOKIE_SESSAO]) ? $_COOKIE[COOKIE_SESSAO] : '';
    if (!preg_match('/^[0-9a-f]{64}$/', $tok)) return null;
    $st = $db->prepare('SELECT u.id, u.login, u.nome, u.papel, u.totp_ativo, s.csrf, s.reauth_ate FROM sessoes s JOIN usuarios u ON u.id = s.usuario_id
                        WHERE s.hash = ? AND s.expira > ? AND u.ativo = 1');
    $st->execute([hash('sha256', $tok), $agora]);
    $u = $st->fetch();
    return $u ?: null;
}

// Retorna ['ok'=>true] | ['precisa_2fa'=>true] | ['erro'=>msg, 'status'=>int]
// Ordem: limite por IP -> usuario/senha -> codigo 2FA (se ativo). Tudo que falha conta para o IP e para a conta.
function tentarLogin(PDO $db, $cfg, $login, $senha, $codigo, $agora, $base, $ip)
{
    $login = strtolower(trim((string)$login));
    $janela = 15 * 60000;
    $maxIp = (int)$cfg['login_max_falhas_ip'];
    $st = $db->prepare("SELECT COUNT(*) FROM auditoria WHERE ip = ? AND evento = 'login_falha' AND ts > ?");
    $st->execute([$ip, $agora - $janela]);
    $falhasIp = (int)$st->fetchColumn();
    if ($maxIp > 0 && $falhasIp >= $maxIp) {
        if ($falhasIp === $maxIp) { auditar($db, $agora, $ip, $login, 'login_bloqueado_ip', 'excedeu ' . $maxIp . ' falhas em 15 min'); alertaFalhasLogin($db, $cfg, $agora, $ip, $login); $db->prepare("INSERT INTO auditoria (ts, ip, login, evento, detalhe) VALUES (?,?,?,?,?)")->execute([$agora, $ip, $login, 'login_falha', 'marca de bloqueio']); }
        usleep(400000);
        return ['erro' => 'Muitas tentativas a partir deste endereço. Aguarde alguns minutos.', 'status' => 429];
    }

    // Bloqueio por par IP + login: quem erra a senha de um usuario so tranca a propria origem, nao o dono da conta.
    $st = $db->prepare("SELECT COUNT(*) FROM auditoria WHERE ip = ? AND login = ? AND evento = 'login_falha' AND ts > ?");
    $st->execute([$ip, $login, $agora - $janela]);
    if ((int)$st->fetchColumn() >= MAX_FALHAS) {
        auditar($db, $agora, $ip, $login, 'login_bloqueado', 'muitas falhas desta origem para este usuario');
        alertaFalhasLogin($db, $cfg, $agora, $ip, $login);
        usleep(400000);
        return ['erro' => 'Acesso bloqueado por tentativas erradas. Tente novamente em alguns minutos.', 'status' => 429];
    }

    $st = $db->prepare('SELECT * FROM usuarios WHERE login = ?');
    $st->execute([$login]);
    $u = $st->fetch();
    if ($u && (int)$u['bloqueado_ate'] > $agora) {
        auditar($db, $agora, $ip, $login, 'login_bloqueado', 'conta bloqueada temporariamente');
        usleep(400000);
        return ['erro' => 'Acesso bloqueado por tentativas erradas. Tente novamente em alguns minutos.', 'status' => 429];
    }
    $falhar = function ($motivo) use ($db, $u, $agora, $ip, $login) {
        if ($u) {
            $falhas = (int)$u['falhas'] + 1;
            $bloq = 0;
            if ($falhas >= MAX_FALHAS_CONTA) { $bloq = $agora + BLOQUEIO_MS; $falhas = 0; }
            $db->prepare('UPDATE usuarios SET falhas = ?, bloqueado_ate = ? WHERE id = ?')->execute([$falhas, $bloq, $u['id']]);
        }
        auditar($db, $agora, $ip, $login, 'login_falha', $motivo);
        usleep(500000);
        return ['erro' => 'Usuário ou senha inválidos.', 'status' => 401];
    };

    if ($u) {
        $ok = password_verify((string)$senha, $u['senha_hash']) && (int)$u['ativo'] === 1;
    } else {
        password_hash((string)$senha, PASSWORD_DEFAULT); // mesmo custo de tempo para usuario inexistente
        $ok = false;
    }
    if (!$ok) return $falhar($u ? 'senha incorreta' : 'usuario inexistente');

    $detalhe = '';
    if ((int)$u['totp_ativo'] === 1) {
        if ($codigo === null || trim((string)$codigo) === '') return ['precisa_2fa' => true]; // senha certa; falta o codigo
        $passo = totpVerificar(totpSegredoLer($cfg, $u['totp_secret']), $codigo, $agora, (int)$u['totp_passo']);
        if ($passo !== null) {
            $db->prepare('UPDATE usuarios SET totp_passo = ? WHERE id = ?')->execute([$passo, $u['id']]);
        } else {
            $resta = consumirRecuperacao($u['totp_recuperacao'], $codigo);
            if ($resta === null) {
                $r = $falhar('codigo 2FA invalido');
                $r['erro'] = 'Código de verificação inválido.';
                return $r;
            }
            $db->prepare('UPDATE usuarios SET totp_recuperacao = ? WHERE id = ?')->execute([json_encode($resta), $u['id']]);
            $detalhe = 'codigo de recuperacao usado (' . count($resta) . ' restantes)';
        }
    }
    $db->prepare('UPDATE usuarios SET falhas = 0, bloqueado_ate = 0, ultimo_login = ? WHERE id = ?')->execute([$agora, $u['id']]);
    if (password_needs_rehash($u['senha_hash'], PASSWORD_DEFAULT)) {
        $db->prepare('UPDATE usuarios SET senha_hash = ? WHERE id = ?')->execute([password_hash((string)$senha, PASSWORD_DEFAULT), $u['id']]);
    }
    iniciarSessao($db, $cfg, (int)$u['id'], $agora, $base);
    auditar($db, $agora, $ip, $login, 'login_ok', $detalhe);
    return ['ok' => true];
}
const SENHA_MIN = 12;
const SENHAS_COMUNS = ['123456789012', 'qwertyuiopas', 'password1234', 'senha1234567', 'senha12345678', 'mudar1234567', 'administrador', 'admin1234567', 'admin12345678',
    'abcdefghijkl', 'abc123456789', '111111111111', '000000000000', 'empresa12345', 'senha12345678', 'presenca12345', 'brasil123456', 'qwerty123456', 'q1w2e3r4t5y6', '1q2w3e4r5t6y'];

// Politica de senha (usuarios do painel): minimo de 12 caracteres, sem o proprio login, sem repeticao de um caractere so,
// sem as senhas mais comuns. Devolve a mensagem do problema ou null se a senha serve.
function senhaProblema($s, $login = '')
{
    if (!is_string($s) || strlen($s) > 200) return 'Senha inválida.';
    if (mb_strlen($s, 'UTF-8') < SENHA_MIN) return 'A senha deve ter pelo menos ' . SENHA_MIN . ' caracteres.';
    $min = mb_strtolower($s, 'UTF-8');
    if (count(array_unique(preg_split('//u', $s, -1, PREG_SPLIT_NO_EMPTY))) < 4) return 'A senha é repetitiva demais: misture mais caracteres.';
    if (in_array($min, SENHAS_COMUNS, true)) return 'Essa senha é muito comum. Escolha outra.';
    $login = mb_strtolower((string)$login, 'UTF-8');
    if (strlen($login) >= 3 && strpos($min, $login) !== false) return 'A senha não pode conter o nome de usuário.';
    return null;
}

function senhaForte($s, $login = '')
{
    return senhaProblema($s, $login) === null;
}

function sessaoHash()
{
    return isset($_COOKIE[COOKIE_SESSAO]) && is_string($_COOKIE[COOKIE_SESSAO]) ? hash('sha256', $_COOKIE[COOKIE_SESSAO]) : '';
}

// POST /api/reautenticar: confirma a senha (e o codigo 2FA, se ativo) e libera acoes sensiveis por REAUTH_MS nesta sessao.
function reautenticar(PDO $db, $cfg, $sessao, $senha, $codigo, $agora, $ip)
{
    $janela = 15 * 60000;
    $st = $db->prepare("SELECT COUNT(*) FROM auditoria WHERE login = ? AND evento = 'reauth_falha' AND ts > ?");
    $st->execute([$sessao['login'], $agora - $janela]);
    if ((int)$st->fetchColumn() >= MAX_FALHAS) { usleep(400000); return ['erro' => 'Muitas tentativas. Aguarde alguns minutos.', 'status' => 429]; }
    $st = $db->prepare('SELECT senha_hash, totp_secret, totp_passo FROM usuarios WHERE id = ?');
    $st->execute([$sessao['id']]);
    $u = $st->fetch();
    $ok = $u && password_verify((string)$senha, (string)$u['senha_hash']);
    $passo = null;
    if ($ok && (int)$sessao['totp_ativo'] === 1) {
        $passo = totpVerificar(totpSegredoLer($cfg, $u['totp_secret']), $codigo, $agora, (int)$u['totp_passo']);
        $ok = $passo !== null;
    }
    if (!$ok) {
        auditar($db, $agora, $ip, $sessao['login'], 'reauth_falha');
        usleep(500000);
        return ['erro' => (int)$sessao['totp_ativo'] === 1 ? 'Senha ou código incorretos.' : 'Senha incorreta.', 'status' => 400];
    }
    if ($passo !== null) $db->prepare('UPDATE usuarios SET totp_passo = ? WHERE id = ?')->execute([$passo, $sessao['id']]);
    $db->prepare('UPDATE sessoes SET reauth_ate = ? WHERE hash = ?')->execute([$agora + REAUTH_MS, sessaoHash()]);
    return ['ok' => true];
}

// ---------- tokens dos agents ----------
// Token de cadastro (config 'agent_token'): vai no instalador. Cada maquina troca esse token, uma vez, por um token proprio
// (ppm_...) que so vale para o host dela. Assim, quem le o agente.json de um PC nao consegue falar em nome de outro.
// Enquanto o painel permitir o "token de cadastro", ele ainda vale para envio (agents antigos nao ficam sem sinal).
// modo: 'envio' (rotas de dados), 'leitura' (versao/pacote do agent: o cadastro sempre vale, para maquinas antigas se recuperarem)
//       ou 'cadastro' (so o token de cadastro).

function agenteCadastroPermitido(PDO $db)
{
    $st = $db->prepare("SELECT valor FROM meta WHERE chave = 'agente_token_legado'");
    $st->execute();
    $v = $st->fetchColumn();
    return $v === false || $v === '1';
}

function exigirAgente($cfg, $agora, $modo = 'envio')
{
    $h = cabecalhoAuth();
    if (strncmp($h, 'Bearer ', 7) !== 0 || strlen($h) > 120) responderJson(401, ['erro' => 'token invalido']);
    $t = substr($h, 7);
    if (iguais($t, $cfg['agent_token'])) {
        if ($modo !== 'envio') return ['tipo' => 'cadastro', 'host' => null];
        if (agenteCadastroPermitido(abrirBanco($cfg))) return ['tipo' => 'cadastro', 'host' => null];
        responderJson(401, ['erro' => 'token de cadastro nao vale mais para envio: o agent precisa ser atualizado']);
    }
    if ($modo !== 'cadastro' && strncmp($t, 'ppm_', 4) === 0) {
        $st = abrirBanco($cfg)->prepare('SELECT host FROM agente_tokens WHERE hash = ?');
        $st->execute([hash('sha256', $t)]);
        $host = $st->fetchColumn();
        if ($host !== false) return ['tipo' => 'maquina', 'host' => (string)$host];
    }
    responderJson(401, ['erro' => 'token invalido']);
}

// Token de maquina: o host informado no corpo (ou na consulta) tem de ser o dela.
function agenteHostDe($ag, $dados)
{
    if ($ag['host'] === null) return;
    $h = is_array($dados) && isset($dados['host']) && is_scalar($dados['host']) ? strtoupper(trim((string)$dados['host'])) : '';
    if ($h !== $ag['host']) responderJson(403, ['erro' => 'este token pertence a outra maquina']);
}

function registrarAgente(PDO $db, $cfg, $host, $agora, $ip)
{
    $host = strtoupper(trim(cortar(is_scalar($host) ? (string)$host : '', 100)));
    if ($host === '') return ['erro' => 'host obrigatorio', 'status' => 400];
    $st = $db->prepare('SELECT 1 FROM agente_tokens WHERE host = ?');
    $st->execute([$host]);
    $existe = (bool)$st->fetchColumn();
    if ($existe && !agenteCadastroPermitido($db)) {
        return ['erro' => 'esta maquina ja tem token proprio; um administrador precisa liberar um novo cadastro', 'status' => 409];
    }
    $token = 'ppm_' . bin2hex(random_bytes(24));
    $db->beginTransaction();
    try {
        $db->prepare('DELETE FROM agente_tokens WHERE host = ?')->execute([$host]);
        $db->prepare('INSERT INTO agente_tokens (host, hash, criado_em) VALUES (?,?,?)')->execute([$host, hash('sha256', $token), $agora]);
        $db->commit();
    } catch (Throwable $e) { $db->rollBack(); throw $e; }
    auditar($db, $agora, $ip, $host, $existe ? 'agente_token_reemitido' : 'agente_token_emitido', '');
    return ['ok' => true, 'token' => $token];
}

// Resumo para a Administracao: quantas maquinas ja tem token proprio e quais ainda usam o de cadastro.
function resumoTokensAgentes(PDO $db, $agora)
{
    $reg = [];
    foreach ($db->query('SELECT host FROM agente_tokens') as $r) $reg[strtoupper($r['host'])] = true;
    $sem = [];
    foreach ($db->query('SELECT host, versao, visto_em FROM agentes ORDER BY host COLLATE NOCASE') as $r) {
        if (!isset($reg[strtoupper($r['host'])]) && (int)$r['visto_em'] > $agora - 30 * 86400000) $sem[] = ['host' => $r['host'], 'versao' => (string)$r['versao'], 'visto_em' => (int)$r['visto_em']];
    }
    return ['registradas' => count($reg), 'sem_token' => $sem, 'cadastro_permitido' => agenteCadastroPermitido($db)];
}
