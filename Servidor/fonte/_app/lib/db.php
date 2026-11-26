<?php
// Banco SQLite: criacao, migracao (bancos antigos continuam funcionando) e gravacao dos dados.

function abrirBanco($cfg)
{
    $dir = $cfg['dados_dir'];
    if (!is_dir($dir)) {
        @mkdir($dir, 0750, true);
        @file_put_contents($dir . '/.htaccess', "<IfModule mod_authz_core.c>\nRequire all denied\n</IfModule>\n<IfModule !mod_authz_core.c>\nDeny from all\n</IfModule>\n");
    }
    $pdo = new PDO('sqlite:' . $dir . '/presenca.sqlite');
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE, PDO::FETCH_ASSOC);
    // 430 agents gravam ao mesmo tempo: espera ate 15 s pela vez em vez de falhar com "database is locked"
    $pdo->exec('PRAGMA busy_timeout = 15000');
    ativarWal($pdo, $cfg);
    migrar($pdo, $cfg);
    aplicarResetAdmin($pdo, $cfg);
    return $pdo;
}

// Modo WAL: quem le (painel) nao trava quem grava (agents) e as gravacoes ficam bem mais rapidas.
// O modo fica gravado no arquivo, entao so e trocado na primeira vez. Se o disco da hospedagem nao
// suportar (alguns sistemas de arquivo de rede), o SQLite continua no modo antigo e nada quebra.
// Desligar: 'sqlite_wal' => false no config.php (depois rode PRAGMA journal_mode=DELETE ou apague os arquivos -wal/-shm com o sistema parado).
function ativarWal(PDO $db, $cfg)
{
    if (isset($cfg['sqlite_wal']) && $cfg['sqlite_wal'] === false) return;
    try {
        $atual = strtolower((string)$db->query('PRAGMA journal_mode')->fetchColumn());
        if ($atual !== 'wal') $atual = strtolower((string)$db->query('PRAGMA journal_mode = WAL')->fetchColumn());
        if ($atual === 'wal') $db->exec('PRAGMA synchronous = NORMAL');
    } catch (Throwable $e) {
        // outra conexao segurando o arquivo: tenta de novo na proxima requisicao
    }
}

function modoDiario(PDO $db)
{
    return strtolower((string)$db->query('PRAGMA journal_mode')->fetchColumn());
}

// Recuperacao de acesso: se o config.php tiver 'redefinir_senha_admin' => 'nova-senha' (min. 8), a senha do
// administrador 'painel_user' passa a ser essa (aplica uma vez por valor; depois remova a linha do config).
function aplicarResetAdmin(PDO $db, $cfg)
{
    $nova = isset($cfg['redefinir_senha_admin']) ? $cfg['redefinir_senha_admin'] : '';
    if (!is_string($nova) || strlen($nova) < 8 || empty($cfg['painel_user'])) return;
    $marca = hash('sha256', $nova);
    if (metaGet($db, 'reset_admin') === $marca) return;
    $login = strtolower($cfg['painel_user']);
    $hash = password_hash($nova, PASSWORD_DEFAULT);
    $up = $db->prepare('UPDATE usuarios SET senha_hash = ?, papel = \'admin\', ativo = 1, falhas = 0, bloqueado_ate = 0, totp_ativo = 0, totp_secret = NULL, totp_recuperacao = NULL WHERE login = ?');
    $up->execute([$hash, $login]);
    if ($up->rowCount() === 0) {
        $db->prepare('INSERT INTO usuarios (login, nome, senha_hash, papel, ativo, criado_em) VALUES (?,?,?,?,1,?)')
           ->execute([$login, 'Administrador', $hash, 'admin', (int)round(microtime(true) * 1000)]);
    }
    $db->prepare('DELETE FROM sessoes WHERE usuario_id IN (SELECT id FROM usuarios WHERE login = ?)')->execute([$login]);
    metaSet($db, 'reset_admin', $marca);
}

function colunaExiste(PDO $db, $tabela, $coluna)
{
    foreach ($db->query('PRAGMA table_info(' . $tabela . ')') as $c) {
        if ($c['name'] === $coluna) return true;
    }
    return false;
}

function metaGet(PDO $db, $k)
{
    $st = $db->prepare('SELECT valor FROM meta WHERE chave = ?');
    $st->execute([$k]);
    $v = $st->fetchColumn();
    return $v === false ? null : $v;
}

function metaSet(PDO $db, $k, $v)
{
    $db->prepare('INSERT OR REPLACE INTO meta (chave, valor) VALUES (?, ?)')->execute([$k, $v]);
}

const VERSAO_BANCO = 20;  // sobe a cada tabela/coluna nova: bancos que ja estao nesta versao pulam a migracao

function migrar(PDO $db, $cfg)
{
    if ((int)$db->query('PRAGMA user_version')->fetchColumn() >= VERSAO_BANCO) return;
    $db->exec('CREATE TABLE IF NOT EXISTS registros (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL,
        data_hora TEXT NOT NULL,
        recebido_em INTEGER NOT NULL,
        host TEXT NOT NULL,
        usuario TEXT,
        resultado TEXT NOT NULL,
        unidade TEXT,
        vpn_ativa TEXT,
        vpn_adaptador TEXT,
        confianca TEXT,
        mac_confere TEXT,
        motivo TEXT,
        sessao_remota TEXT,
        bloqueada TEXT,
        ocioso_seg INTEGER,
        UNIQUE (host, ts)
    )');
    $db->exec('CREATE INDEX IF NOT EXISTS idx_registros_ts ON registros (ts)');
    $db->exec('CREATE TABLE IF NOT EXISTS meta (chave TEXT PRIMARY KEY, valor TEXT)');

    if (!colunaExiste($db, 'registros', 'nome'))  $db->exec('ALTER TABLE registros ADD COLUMN nome TEXT');
    if (!colunaExiste($db, 'registros', 'login')) $db->exec('ALTER TABLE registros ADD COLUMN login TEXT');
    // IP publico de saida do PC (o que o servidor enxerga na conexao do agent): ajuda a provar onde o PC estava
    if (!colunaExiste($db, 'registros', 'ip_saida')) $db->exec('ALTER TABLE registros ADD COLUMN ip_saida TEXT');
    $db->exec('CREATE INDEX IF NOT EXISTS idx_registros_login ON registros (login, ts)');

    $db->exec('CREATE TABLE IF NOT EXISTS colaboradores (
        login TEXT PRIMARY KEY,
        nome TEXT,
        nome_manual INTEGER NOT NULL DEFAULT 0,
        setor TEXT,
        ativo INTEGER NOT NULL DEFAULT 1,
        atualizado_em INTEGER
    )');
    // cadastro do RH: cargo e centro de custo (digitados na Administracao ou importados de CSV). rh = 1 quando a pessoa tem vinculo com o RH.
    foreach (['cargo TEXT', 'centro_custo TEXT', 'rh INTEGER NOT NULL DEFAULT 0', 'rh_em INTEGER', 'jornada_horas REAL'] as $col) {
        if (!colunaExiste($db, 'colaboradores', explode(' ', $col)[0])) $db->exec('ALTER TABLE colaboradores ADD COLUMN ' . $col);
    }
    // resumo por dia (sobrevive a retencao dos registros brutos): base dos relatorios de localizacao
    $db->exec('CREATE TABLE IF NOT EXISTS presenca_dia (
        login TEXT NOT NULL, dia TEXT NOT NULL, resultado TEXT NOT NULL, unidade TEXT NOT NULL DEFAULT \'\',
        n INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (login, dia, resultado, unidade)
    )');
    $db->exec('CREATE TABLE IF NOT EXISTS navegacao (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL, host TEXT NOT NULL, login TEXT NOT NULL, dominio TEXT NOT NULL,
        url TEXT, titulo TEXT, navegador TEXT, duracao_seg INTEGER NOT NULL DEFAULT 0,
        UNIQUE (host, login, ts, url)
    )');
    $db->exec('CREATE INDEX IF NOT EXISTS idx_nav_login_ts ON navegacao (login, ts)');
    // programas em foco (tempo na frente de cada programa): acessos brutos (retencao_foco_dias) e resumo por dia (400 dias)
    $db->exec('CREATE TABLE IF NOT EXISTS foco (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL, host TEXT NOT NULL, login TEXT NOT NULL, processo TEXT NOT NULL, titulo TEXT, seg INTEGER NOT NULL DEFAULT 0,
        UNIQUE (host, login, ts, processo)
    )');
    $db->exec('CREATE INDEX IF NOT EXISTS idx_foco_login_ts ON foco (login, ts)');
    $db->exec('CREATE TABLE IF NOT EXISTS foco_dia (
        login TEXT NOT NULL, dia TEXT NOT NULL, processo TEXT NOT NULL,
        segundos INTEGER NOT NULL DEFAULT 0, trocas INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (login, dia, processo)
    )');
    $db->exec('CREATE TABLE IF NOT EXISTS nav_dia (
        login TEXT NOT NULL, dia TEXT NOT NULL, dominio TEXT NOT NULL,
        visitas INTEGER NOT NULL DEFAULT 0, segundos INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (login, dia, dominio)
    )');
    $db->exec('CREATE TABLE IF NOT EXISTS regras (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        padrao TEXT NOT NULL UNIQUE, categoria TEXT NOT NULL, criado_por TEXT, criado_em INTEGER
    )');
    $db->exec('CREATE TABLE IF NOT EXISTS usuarios (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        login TEXT NOT NULL UNIQUE, nome TEXT, senha_hash TEXT NOT NULL, papel TEXT NOT NULL DEFAULT \'gestor\',
        ativo INTEGER NOT NULL DEFAULT 1, criado_em INTEGER, ultimo_login INTEGER,
        falhas INTEGER NOT NULL DEFAULT 0, bloqueado_ate INTEGER NOT NULL DEFAULT 0
    )');
    foreach (['totp_secret TEXT', 'totp_ativo INTEGER NOT NULL DEFAULT 0', 'totp_passo INTEGER NOT NULL DEFAULT 0', 'totp_recuperacao TEXT'] as $col) {
        if (!colunaExiste($db, 'usuarios', explode(' ', $col)[0])) $db->exec('ALTER TABLE usuarios ADD COLUMN ' . $col);
    }
    $db->exec('CREATE TABLE IF NOT EXISTS auditoria (
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, ip TEXT, login TEXT, evento TEXT NOT NULL, detalhe TEXT
    )');
    $db->exec('CREATE TABLE IF NOT EXISTS maquinas_ocultas (host TEXT PRIMARY KEY, ocultado_em INTEGER NOT NULL, por TEXT)');
    // inventario de maquinas: o que o agent coleta + campos de controle preenchidos por pessoas
    $db->exec('CREATE TABLE IF NOT EXISTS inventario (
        chave TEXT PRIMARY KEY, num_inventario TEXT, host TEXT, nome_ativo TEXT,
        status TEXT, fabricante TEXT, serie TEXT, tipo TEXT, modelo TEXT, responsavel TEXT, localizacao TEXT, comentarios TEXT,
        so TEXT, so_versao TEXT, so_exibicao TEXT, so_arquitetura TEXT, so_instalado_em TEXT, cpu TEXT, ram_gb INTEGER,
        discos TEXT, disco_total_gb INTEGER, disco_c_total_gb INTEGER, disco_c_livre_gb INTEGER,
        ips TEXT, mac TEXT, dominio TEXT, bios_versao TEXT, ultimo_boot TEXT,
        coletado_em INTEGER, origem TEXT, criado_em INTEGER, atualizado_em INTEGER
    )');
    $db->exec('CREATE TABLE IF NOT EXISTS inventario_hist (
        id INTEGER PRIMARY KEY AUTOINCREMENT, chave TEXT NOT NULL, ts INTEGER NOT NULL, campo TEXT, antigo TEXT, novo TEXT
    )');
    $db->exec('CREATE INDEX IF NOT EXISTS idx_inv_hist ON inventario_hist (chave, ts)');
    // servidores: maquinas sem dono fixo; o painel mostra o "ultimo usuario logado" no lugar do colaborador
    $db->exec('CREATE TABLE IF NOT EXISTS servidores (host TEXT PRIMARY KEY, criado_em INTEGER NOT NULL, por TEXT)');
    $db->exec('CREATE TABLE IF NOT EXISTS agentes (host TEXT PRIMARY KEY, versao TEXT, visto_em INTEGER NOT NULL)');
    // acesso remoto (RustDesk): ID da maquina e senha de acesso permanente, cifrada (ver lib/remoto.php)
    $db->exec('CREATE TABLE IF NOT EXISTS remoto (host TEXT PRIMARY KEY, rd_id TEXT NOT NULL, senha_cifrada TEXT NOT NULL, atualizado_em INTEGER NOT NULL)');
    // etapa em que o agent esta (baixando, instalando, registrado, falha...), para o painel mostrar o andamento
    $db->exec('CREATE TABLE IF NOT EXISTS remoto_status (host TEXT PRIMARY KEY, estado TEXT NOT NULL, detalhe TEXT, atualizado_em INTEGER NOT NULL)');
    // primeiro e ultimo "clique" do dia por colaborador (inicio do primeiro e fim do ultimo segmento de programa em foco): jornada e ociosidade
    $db->exec('CREATE TABLE IF NOT EXISTS atividade_dia (login TEXT NOT NULL, dia TEXT NOT NULL, primeiro INTEGER NOT NULL, ultimo INTEGER NOT NULL, PRIMARY KEY (login, dia))');
    if (metaGet($db, 'atividade_dia_v1') === null) {
        // preenche os dias que ainda tem segmentos brutos (ate retencao_foco_dias), sem servidores
        $srvs = [];
        foreach ($db->query('SELECT UPPER(host) FROM servidores') as $r) $srvs[$r[0]] = true;
        $tzb = fusoDe($cfg); $tmp = [];
        foreach ($db->query('SELECT login, host, ts, seg FROM foco') as $r) {
            if (isset($srvs[strtoupper($r['host'])])) continue;
            $dia = diaLocal((int)$r['ts'], $tzb); $fim = (int)$r['ts'] + (int)$r['seg'] * 1000;
            if (!isset($tmp[$r['login']][$dia])) $tmp[$r['login']][$dia] = [(int)$r['ts'], $fim];
            else { if ((int)$r['ts'] < $tmp[$r['login']][$dia][0]) $tmp[$r['login']][$dia][0] = (int)$r['ts']; if ($fim > $tmp[$r['login']][$dia][1]) $tmp[$r['login']][$dia][1] = $fim; }
        }
        $ia = $db->prepare('INSERT OR REPLACE INTO atividade_dia (login, dia, primeiro, ultimo) VALUES (?,?,?,?)');
        foreach ($tmp as $l => $dias) foreach ($dias as $dia => $v) $ia->execute([$l, $dia, $v[0], $v[1]]);
        metaSet($db, 'atividade_dia_v1', '1');
    }
    // tokens da API de dados (so o hash do token fica guardado; ver lib/api_v1.php)
    $db->exec('CREATE TABLE IF NOT EXISTS api_tokens (
        id INTEGER PRIMARY KEY AUTOINCREMENT, nome TEXT NOT NULL, hash TEXT NOT NULL UNIQUE, prefixo TEXT NOT NULL,
        criado_em INTEGER NOT NULL, criado_por TEXT, expira_em INTEGER, ultimo_uso INTEGER, revogado_em INTEGER,
        anonimizar INTEGER NOT NULL DEFAULT 0, usos INTEGER NOT NULL DEFAULT 0
    )');
    // batimento dos servidores (uma linha por servidor): ver lib/batimento.php
    $db->exec('CREATE TABLE IF NOT EXISTS batimento (host TEXT PRIMARY KEY, visto_em INTEGER NOT NULL, boot_em INTEGER)');
    // indices so por data: a limpeza dos acessos antigos nao precisa varrer a tabela inteira (milhoes de linhas)
    $db->exec('CREATE INDEX IF NOT EXISTS idx_nav_ts ON navegacao (ts)');
    $db->exec('CREATE INDEX IF NOT EXISTS idx_foco_ts ON foco (ts)');
    $db->exec('CREATE INDEX IF NOT EXISTS idx_auditoria_ts ON auditoria (ts)');
    $db->exec('CREATE INDEX IF NOT EXISTS idx_auditoria_ip ON auditoria (ip, evento, ts)');
    $db->exec('CREATE TABLE IF NOT EXISTS sessoes (
        hash TEXT PRIMARY KEY, usuario_id INTEGER NOT NULL, csrf TEXT NOT NULL, expira INTEGER NOT NULL, criado_em INTEGER NOT NULL
    )');

    if (!colunaExiste($db, 'sessoes', 'reauth_ate')) $db->exec('ALTER TABLE sessoes ADD COLUMN reauth_ate INTEGER NOT NULL DEFAULT 0'); // ate quando a senha foi reconfirmada

    $db->exec('CREATE TABLE IF NOT EXISTS agente_tokens (host TEXT PRIMARY KEY, hash TEXT NOT NULL UNIQUE, criado_em INTEGER NOT NULL)');
    // Instalacao de software: pacotes assinados e uma tarefa por maquina (estado: pendente, executando, ok, falhou, cancelada)
    $db->exec('CREATE TABLE IF NOT EXISTS pacotes (
        pid TEXT PRIMARY KEY, nome TEXT NOT NULL, tipo TEXT NOT NULL, manifesto TEXT NOT NULL, assinatura TEXT NOT NULL,
        sha256 TEXT NOT NULL, tamanho INTEGER NOT NULL, arquivo_ok INTEGER NOT NULL DEFAULT 0, criado_em INTEGER NOT NULL, criado_por TEXT NOT NULL
    )');
    $db->exec('CREATE TABLE IF NOT EXISTS tarefas (
        id INTEGER PRIMARY KEY AUTOINCREMENT, pid TEXT NOT NULL, host TEXT NOT NULL, estado TEXT NOT NULL,
        criado_em INTEGER NOT NULL, criado_por TEXT NOT NULL DEFAULT \'\', inicio_em INTEGER NOT NULL DEFAULT 0, fim_em INTEGER NOT NULL DEFAULT 0,
        codigo INTEGER, saida TEXT NOT NULL DEFAULT \'\'
    )');
    // v20: politica de aplicacao do pacote (auto = instala sozinho nas maquinas do alvo) e acao da tarefa (instalar | desinstalar)
    if (!colunaExiste($db, 'pacotes', 'auto')) $db->exec('ALTER TABLE pacotes ADD COLUMN auto INTEGER NOT NULL DEFAULT 0');
    if (!colunaExiste($db, 'pacotes', 'alvo')) $db->exec('ALTER TABLE pacotes ADD COLUMN alvo TEXT NOT NULL DEFAULT \'\'');
    if (!colunaExiste($db, 'tarefas', 'acao')) $db->exec('ALTER TABLE tarefas ADD COLUMN acao TEXT NOT NULL DEFAULT \'instalar\'');
    $db->exec('CREATE INDEX IF NOT EXISTS idx_tarefas_host ON tarefas (host, estado)');
    $db->exec('CREATE INDEX IF NOT EXISTS idx_tarefas_pid ON tarefas (pid, estado)');
    // segredo do 2FA passa a ficar cifrado (mesma chave do acesso remoto); o que ja estava em texto e cifrado agora
    if (function_exists('openssl_encrypt')) {
        $cif = $db->prepare('UPDATE usuarios SET totp_secret = ? WHERE id = ?');
        foreach ($db->query("SELECT id, totp_secret FROM usuarios WHERE totp_secret IS NOT NULL AND totp_secret <> '' AND totp_secret NOT LIKE 'e1:%'")->fetchAll() as $u) $cif->execute([totpSegredoGuardar($cfg, $u['totp_secret']), $u['id']]);
    }

    $agora = isset($cfg['agora_ms']) && $cfg['agora_ms'] !== null ? (int)$cfg['agora_ms'] : (int)round(microtime(true) * 1000);
    semearRegras($db, $agora);
    semearRegrasApp($db, $agora);
    if (metaGet($db, 'servidores_v1') === null) {
        $sv = $db->prepare('INSERT OR IGNORE INTO servidores (host, criado_em, por) VALUES (?,?,?)');
        foreach (['SRV-B', 'SRV-A'] as $h) $sv->execute([$h, $agora, 'padrao']);
        metaSet($db, 'servidores_v1', '1');
    }
    semearAdmin($db, $cfg, $agora);

    // Preenche login e resumo diario a partir dos registros anteriores (so na primeira vez)
    if (metaGet($db, 'backfill_v2') === null) {
        $db->beginTransaction();
        try {
            $tz = fusoDe($cfg);
            foreach ($db->query('SELECT id, ts, host, usuario, resultado, unidade FROM registros')->fetchAll() as $r) {
                $login = loginDe($r['usuario']);
                if ($login === '') $login = strtolower($r['host']);
                $db->prepare('UPDATE registros SET login = ? WHERE id = ?')->execute([$login, $r['id']]);
                somarPresencaDia($db, $login, diaLocal($r['ts'], $tz), $r['resultado'], (string)$r['unidade']);
                garantirColaborador($db, $login, '');
            }
            metaSet($db, 'backfill_v2', '1');
            $db->commit();
        } catch (Throwable $e) {
            $db->rollBack();
            throw $e;
        }
    }
    $db->exec('PRAGMA user_version = ' . VERSAO_BANCO);
}

function semearAdmin(PDO $db, $cfg, $agora)
{
    if ((int)$db->query('SELECT COUNT(*) FROM usuarios')->fetchColumn() > 0) return;
    if (empty($cfg['painel_user']) || empty($cfg['painel_pass'])) return;
    $db->prepare('INSERT INTO usuarios (login, nome, senha_hash, papel, ativo, criado_em) VALUES (?,?,?,?,1,?)')
       ->execute([strtolower($cfg['painel_user']), 'Administrador', password_hash($cfg['painel_pass'], PASSWORD_DEFAULT), 'admin', $agora]);
}

function garantirColaborador(PDO $db, $login, $nome)
{
    $st = $db->prepare('INSERT OR IGNORE INTO colaboradores (login, nome, atualizado_em) VALUES (?, ?, ?)');
    $st->execute([$login, $nome, (int)round(microtime(true) * 1000)]);
    if ($nome !== '') {
        $db->prepare('UPDATE colaboradores SET nome = ? WHERE login = ? AND nome_manual = 0 AND (nome IS NULL OR nome <> ?)')
           ->execute([$nome, $login, $nome]);
    }
}

function somarPresencaDia(PDO $db, $login, $dia, $resultado, $unidade)
{
    $up = $db->prepare('UPDATE presenca_dia SET n = n + 1 WHERE login = ? AND dia = ? AND resultado = ? AND unidade = ?');
    $up->execute([$login, $dia, $resultado, $unidade]);
    if ($up->rowCount() === 0) {
        $db->prepare('INSERT INTO presenca_dia (login, dia, resultado, unidade, n) VALUES (?,?,?,?,1)')
           ->execute([$login, $dia, $resultado, $unidade]);
    }
}

function somarNavDia(PDO $db, $login, $dia, $dominio, $seg)
{
    $up = $db->prepare('UPDATE nav_dia SET visitas = visitas + 1, segundos = segundos + ? WHERE login = ? AND dia = ? AND dominio = ?');
    $up->execute([$seg, $login, $dia, $dominio]);
    if ($up->rowCount() === 0) {
        $db->prepare('INSERT INTO nav_dia (login, dia, dominio, visitas, segundos) VALUES (?,?,?,1,?)')
           ->execute([$login, $dia, $dominio, $seg]);
    }
}

// Guarda o primeiro e o ultimo instante de atividade do dia (o menor inicio e o maior fim dos segmentos).
function registrarAtividade(PDO $db, $login, $dia, $ini, $fim)
{
    $db->prepare('INSERT OR IGNORE INTO atividade_dia (login, dia, primeiro, ultimo) VALUES (?,?,?,?)')->execute([$login, $dia, $ini, $fim]);
    $db->prepare('UPDATE atividade_dia SET primeiro = MIN(primeiro, ?), ultimo = MAX(ultimo, ?) WHERE login = ? AND dia = ?')->execute([$ini, $fim, $login, $dia]);
}

function somarFocoDia(PDO $db, $login, $dia, $processo, $seg)
{
    $up = $db->prepare('UPDATE foco_dia SET segundos = segundos + ?, trocas = trocas + 1 WHERE login = ? AND dia = ? AND processo = ?');
    $up->execute([$seg, $login, $dia, $processo]);
    if ($up->rowCount() === 0) {
        $db->prepare('INSERT INTO foco_dia (login, dia, processo, segundos, trocas) VALUES (?,?,?,?,1)')
           ->execute([$login, $dia, $processo, $seg]);
    }
}

const MAX_FOCO = 500;

// Corpo: { host, usuario, nome_completo, itens: [ { ts (ms), seg, proc, titulo } ] }
function gravarFoco(PDO $db, $cfg, $b, $agora)
{
    if (!is_array($b) || !isset($b['itens']) || !is_array($b['itens'])) return ['erro' => 'corpo invalido'];
    $host = trim(cortar(isset($b['host']) ? $b['host'] : '', 100));
    if ($host === '') return ['erro' => 'host obrigatorio'];
    $usuario = cortar(isset($b['usuario']) ? $b['usuario'] : '', 150);
    $login = loginDe($usuario);
    if ($login === '') $login = strtolower($host);
    $nome = trim(cortar(isset($b['nome_completo']) ? $b['nome_completo'] : '', 150));
    if (count($b['itens']) > MAX_FOCO) return ['erro' => 'itens demais'];

    $tz = fusoDe($cfg);
    $srv = ehServidor($db, $host);
    $recebidas = 0; $gravadas = 0;
    $db->beginTransaction();
    try {
        $ins = $db->prepare('INSERT OR IGNORE INTO foco (ts, host, login, processo, titulo, seg) VALUES (?,?,?,?,?,?)');
        $procsVistos = [];
        foreach ($b['itens'] as $v) {
            if (!is_array($v)) continue;
            $recebidas++;
            if (!isset($v['ts']) || !is_numeric($v['ts']) || !isset($v['seg']) || !is_numeric($v['seg'])) continue;
            $ts = (int)$v['ts'];
            if ($ts > $agora + 3600000 || $ts < $agora - 10 * 86400000) continue;
            $proc = trim((string)preg_replace('/[^\p{L}\p{N} ._()+-]/u', '', cortar(isset($v['proc']) ? $v['proc'] : '', 60)));
            if ($proc === '') continue;
            $seg = (int)max(1, min(900, round((float)$v['seg'])));
            $ins->execute([$ts, $host, $login, $proc, cortar(isset($v['titulo']) ? $v['titulo'] : '', 150), $seg]);
            if ($ins->rowCount() > 0) {
                $gravadas++;
                $procsVistos[mb_strtolower($proc, 'UTF-8')] = true;
                if (!$srv) { somarFocoDia($db, $login, diaLocal($ts, $tz), mb_strtolower($proc, 'UTF-8'), $seg); registrarAtividade($db, $login, diaLocal($ts, $tz), $ts, $ts + $seg * 1000); }
            }
        }
        if ($recebidas > 0 && !$srv) garantirColaborador($db, $login, $nome);
        if ($procsVistos && classificacaoAutomaticaAtiva($db)) aplicarSugestoes($db, $agora, [], array_keys($procsVistos));
        $db->commit();
    } catch (Throwable $e) {
        $db->rollBack();
        throw $e;
    }
    return ['ok' => true, 'recebidas' => $recebidas, 'gravadas' => $gravadas];
}

// Apaga em lotes pequenos (cada lote e uma transacao curta): os agents continuam gravando entre um lote e outro.
// Devolve false se o tempo acabou antes de terminar (o restante sai na proxima chamada).
function apagarEmLotes(PDO $db, $tabela, $coluna, $corte, $limiteTempo, $lote = 5000)
{
    $st = $db->prepare("DELETE FROM $tabela WHERE rowid IN (SELECT rowid FROM $tabela WHERE $coluna < ? LIMIT $lote)");
    do {
        $st->execute([$corte]);
        $n = $st->rowCount();
        if ($n >= $lote && microtime(true) > $limiteTempo) return false;
    } while ($n >= $lote);
    return true;
}

// Retorna true quando terminou tudo. $segTempo limita o tempo gasto numa unica requisicao.
function limparAntigos(PDO $db, $cfg, $agora, $segTempo = 8)
{
    $d = 86400000;
    $limite = microtime(true) + $segTempo;
    $corte = (new DateTime('@' . intdiv($agora - $cfg['retencao_agregados_dias'] * $d, 1000)))->format('Y-m-d');
    $ok = true;
    $ok = apagarEmLotes($db, 'foco', 'ts', $agora - (isset($cfg['retencao_foco_dias']) ? $cfg['retencao_foco_dias'] : 60) * $d, $limite) && $ok;
    $ok = apagarEmLotes($db, 'registros', 'ts', $agora - $cfg['retencao_dias'] * $d, $limite) && $ok;
    $ok = apagarEmLotes($db, 'navegacao', 'ts', $agora - $cfg['retencao_nav_dias'] * $d, $limite) && $ok;
    $ok = apagarEmLotes($db, 'presenca_dia', 'dia', $corte, $limite) && $ok;
    $ok = apagarEmLotes($db, 'nav_dia', 'dia', $corte, $limite) && $ok;
    $ok = apagarEmLotes($db, 'foco_dia', 'dia', $corte, $limite) && $ok;
    $ok = apagarEmLotes($db, 'atividade_dia', 'dia', $corte, $limite) && $ok;
    $db->prepare('DELETE FROM sessoes WHERE expira < ?')->execute([$agora]);
    $ok = apagarEmLotes($db, 'auditoria', 'ts', $agora - $cfg['retencao_auditoria_dias'] * $d, $limite) && $ok;
    return $ok;
}

// A limpeza roda no maximo 1 vez por dia (a cada ~20 h) e por uma requisicao so: quem "ganha" a vez grava o horario
// com um UPDATE condicional, as demais seguem sem esperar. Se nao terminar no tempo, libera para a proxima requisicao continuar.
function limparAntigosSeDevido(PDO $db, $cfg, $agora)
{
    $ult = (string)metaGet($db, 'limpeza_em');
    if ($ult === '') { $db->prepare('INSERT OR IGNORE INTO meta (chave, valor) VALUES (?, ?)')->execute(['limpeza_em', '0']); $ult = '0'; }
    if ($agora - (int)$ult < 72000000) return;
    $vez = $db->prepare('UPDATE meta SET valor = ? WHERE chave = ? AND valor = ?');
    $vez->execute([(string)$agora, 'limpeza_em', $ult]);
    if ($vez->rowCount() === 0) return;
    try {
        if (!limparAntigos($db, $cfg, $agora)) metaSet($db, 'limpeza_em', '0');
    } catch (Throwable $e) {
        // a gravacao do agent ja foi confirmada: falha na limpeza nao pode virar erro para ele (tenta de novo na proxima)
        try { metaSet($db, 'limpeza_em', '0'); } catch (Throwable $e2) { /* banco ocupado */ }
    }
}

// ---------- gravacao vinda dos agents ----------

const RESULTADOS = ['Presencial', 'Presencial via VPN', 'Remoto via VPN', 'Remoto', 'Sem rede'];

function validarRegistro($b, $agoraMs)
{
    if (!is_array($b) || (count($b) > 0 && array_keys($b) === range(0, count($b) - 1))) return ['erro' => 'corpo invalido'];
    $host = trim(cortar(isset($b['host']) ? $b['host'] : '', 100));
    if ($host === '') return ['erro' => 'host obrigatorio'];
    $resultado = isset($b['resultado']) ? $b['resultado'] : null;
    if (!is_string($resultado) || !in_array($resultado, RESULTADOS, true)) return ['erro' => 'resultado invalido'];
    $dh = isset($b['data_hora']) && is_string($b['data_hora']) ? $b['data_hora'] : '';
    if (!preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/', $dh)) return ['erro' => 'data_hora invalida'];
    try {
        $dt = new DateTimeImmutable($dh);
    } catch (Exception $e) {
        return ['erro' => 'data_hora invalida'];
    }
    $ts = $dt->getTimestamp() * 1000;
    if ($ts > $agoraMs + 24 * 3600 * 1000) return ['erro' => 'data_hora no futuro'];
    $ocioso = null;
    if (isset($b['ocioso_seg']) && $b['ocioso_seg'] !== '' && is_numeric($b['ocioso_seg']) && $b['ocioso_seg'] >= 0) {
        $ocioso = (int)round((float)$b['ocioso_seg']);
    }
    $g = function ($k, $n) use ($b) { return cortar(isset($b[$k]) ? $b[$k] : '', $n); };
    // agents antigos mandam "Presencial" + vpn_ativa "sim": normaliza para "Presencial via VPN"
    if ($resultado === 'Presencial' && $g('vpn_ativa', 3) === 'sim') $resultado = 'Presencial via VPN';
    $usuario = $g('usuario', 150);
    $login = loginDe($usuario);
    if ($login === '') $login = strtolower($host);
    return ['reg' => [
        'ts' => $ts, 'data_hora' => cortar($dh, 40), 'host' => $host, 'usuario' => $usuario,
        'nome' => trim($g('nome_completo', 150)), 'login' => $login,
        'resultado' => $resultado, 'unidade' => $g('unidade', 40), 'vpn_ativa' => $g('vpn_ativa', 3),
        'vpn_adaptador' => $g('vpn_adaptador', 200), 'confianca' => $g('confianca', 10),
        'mac_confere' => $g('mac_confere', 20), 'motivo' => $g('motivo', 300),
        'sessao_remota' => $g('sessao_remota', 3), 'bloqueada' => $g('bloqueada', 3), 'ocioso_seg' => $ocioso,
        'versao_agente' => preg_match('/^\d{1,4}(\.\d{1,4}){1,3}$/', $g('versao_agente', 20)) ? $g('versao_agente', 20) : '',
    ]];
}

function gravarRegistro(PDO $db, $cfg, $r, $agora)
{
    $db->beginTransaction();
    try {
        $st = $db->prepare('INSERT OR IGNORE INTO registros
            (ts, data_hora, recebido_em, host, usuario, nome, login, resultado, unidade, vpn_ativa, vpn_adaptador,
             confianca, mac_confere, motivo, sessao_remota, bloqueada, ocioso_seg, ip_saida)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)');
        $st->execute([$r['ts'], $r['data_hora'], $agora, $r['host'], $r['usuario'], $r['nome'], $r['login'], $r['resultado'],
            $r['unidade'], $r['vpn_ativa'], $r['vpn_adaptador'], $r['confianca'], $r['mac_confere'], $r['motivo'],
            $r['sessao_remota'], $r['bloqueada'], $r['ocioso_seg'], isset($r['ip_saida']) ? $r['ip_saida'] : '']);
        $novo = $st->rowCount() > 0;
        if ($r['versao_agente'] !== '') {
            // historico: registra na auditoria quando a versao de uma maquina muda (ou na 1a vez que ela aparece)
            $ant = $db->prepare('SELECT versao FROM agentes WHERE host = ?');
            $ant->execute([$r['host']]);
            $antes = $ant->fetchColumn();
            if ($antes === false || (string)$antes !== $r['versao_agente']) {
                auditar($db, $agora, ipCliente($cfg), $r['host'], 'agente_atualizado',
                    ($antes === false || (string)$antes === '') ? 'primeira leitura com versão ' . $r['versao_agente'] : $antes . ' -> ' . $r['versao_agente']);
            }
            $db->prepare('INSERT INTO agentes (host, versao, visto_em) VALUES (?,?,?)
                ON CONFLICT(host) DO UPDATE SET versao = excluded.versao, visto_em = excluded.visto_em')
               ->execute([$r['host'], $r['versao_agente'], $agora]);
        }
        // servidores nao entram nas contas por colaborador (o registro bruto fica, para o painel e a localizacao)
        if ($novo && !ehServidor($db, $r['host'])) {
            somarPresencaDia($db, $r['login'], diaLocal($r['ts'], fusoDe($cfg)), $r['resultado'], ehPresencial($r['resultado']) ? $r['unidade'] : '');
            garantirColaborador($db, $r['login'], $r['nome']);
        }
        $db->commit();
        return !$novo; // duplicado?
    } catch (Throwable $e) {
        $db->rollBack();
        throw $e;
    }
}

const MAX_VISITAS = 500;

// Corpo: { host, usuario, nome_completo, visitas: [ { ts (ms), url, titulo, navegador, duracao_seg } ] }
function gravarNavegacao(PDO $db, $cfg, $b, $agora)
{
    if (!is_array($b) || !isset($b['visitas']) || !is_array($b['visitas'])) return ['erro' => 'corpo invalido'];
    $host = trim(cortar(isset($b['host']) ? $b['host'] : '', 100));
    if ($host === '') return ['erro' => 'host obrigatorio'];
    $usuario = cortar(isset($b['usuario']) ? $b['usuario'] : '', 150);
    $login = loginDe($usuario);
    if ($login === '') $login = strtolower($host);
    $nome = trim(cortar(isset($b['nome_completo']) ? $b['nome_completo'] : '', 150));
    if (count($b['visitas']) > MAX_VISITAS) return ['erro' => 'visitas demais'];

    $tz = fusoDe($cfg);
    $srv = ehServidor($db, $host);
    $recebidas = 0; $gravadas = 0;
    $vistos = [];   // dominios deste lote (para a classificacao automatica)
    $db->beginTransaction();
    try {
        $ins = $db->prepare('INSERT OR IGNORE INTO navegacao (ts, host, login, dominio, url, titulo, navegador, duracao_seg) VALUES (?,?,?,?,?,?,?,?)');
        foreach ($b['visitas'] as $v) {
            if (!is_array($v)) continue;
            $recebidas++;
            if (!isset($v['ts']) || !is_numeric($v['ts'])) continue;
            $ts = (int)$v['ts'];
            if ($ts > $agora + 3600000 || $ts < $agora - 10 * 86400000) continue;
            $url = urlSemConsulta(isset($v['url']) ? $v['url'] : '');
            $dom = $url === null ? null : dominioDeUrl($url);
            if ($dom === null) continue;
            $dur = isset($v['duracao_seg']) && is_numeric($v['duracao_seg']) ? (int)max(0, min(1800, round((float)$v['duracao_seg']))) : 0;
            $ins->execute([$ts, $host, $login, $dom, $url, cortar(isset($v['titulo']) ? $v['titulo'] : '', 150),
                cortar(isset($v['navegador']) ? $v['navegador'] : '', 20), $dur]);
            if ($ins->rowCount() > 0) {
                $gravadas++;
                $vistos[$dom] = true;
                if (!$srv) somarNavDia($db, $login, diaLocal($ts, $tz), $dom, $dur);
            }
        }
        if ($recebidas > 0 && !$srv) garantirColaborador($db, $login, $nome);
        // classificacao automatica dos sites novos (se estiver ligada): so cria regra quando ha sugestao
        if ($vistos && classificacaoAutomaticaAtiva($db)) aplicarSugestoes($db, $agora, array_keys($vistos));
        $db->commit();
    } catch (Throwable $e) {
        $db->rollBack();
        throw $e;
    }
    return ['ok' => true, 'recebidas' => $recebidas, 'gravadas' => $gravadas];
}

// ---------- auditoria ----------

// Registra um evento de seguranca/uso. Nunca grava senhas, codigos ou segredos.
function auditar(PDO $db, $agora, $ip, $login, $evento, $detalhe = '')
{
    $db->prepare('INSERT INTO auditoria (ts, ip, login, evento, detalhe) VALUES (?,?,?,?,?)')
       ->execute([$agora, cortar($ip, 45), cortar($login, 60), cortar($evento, 40), cortar($detalhe, 300)]);
}