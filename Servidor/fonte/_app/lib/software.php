<?php
// Instalacao e desinstalacao de software nos PCs (menu Administracao > Politicas de Instalacao).
// Modelo de seguranca: o servidor NAO cria nem altera pacotes por conta propria. Cada pacote traz um "manifesto" (JSON) assinado com a
// chave privada do atualizador, que fica so no computador do administrador (a assinatura e feita no navegador, a chave nunca vem para ca).
// O agent confere a assinatura com a chave publica embutida e o SHA-256 do arquivo antes de executar qualquer coisa. Um banco ou um servidor
// invadido nao consegue criar um pacote que o agent aceite; no maximo repete (instala ou desinstala) pacotes que o administrador ja assinou.
// Manifesto v2 (assinado): nome, descricao, software, tipo (msi|exe|ps1|cmd|vbs|zip), arquivo, sha256, tamanho, args, executavel (dentro do zip),
// gatilho (se o arquivo ja existe, a instalacao e ignorada) e desinstalar (msi | nome do programa | script).
// A politica de aplicacao (automatica? para quais maquinas?) NAO e assinada: so decide QUANDO um pacote ja assinado e disparado.

const SOFTWARE_TIPOS = ['msi', 'exe', 'ps1', 'cmd', 'vbs', 'zip'];
const SOFTWARE_TIPOS_EXEC = ['msi', 'exe', 'ps1', 'cmd', 'vbs'];   // o que pode ser executado (dentro de um zip tambem)
const SOFTWARE_TENTATIVAS_AUTO = 3;          // politica automatica: ate 3 tentativas por maquina...
const SOFTWARE_INTERVALO_AUTO_MS = 21600000; // ...com 6 h entre elas
const SOFTWARE_ZIP_MAX_ARQUIVOS = 2000;
const SOFTWARE_ZIP_MAX_DESCOMPACTADO = 2147483648; // 2 GB (protecao contra zip bomba)
const SOFTWARE_TAREFA_VENCE_MS = 7200000;   // tarefa "executando" ha mais de 2 h (PC desligou no meio) volta a poder ser pega

function softwareMaxBytes($cfg)
{
    $mb = isset($cfg['software_max_mb']) ? (float)$cfg['software_max_mb'] : 200;
    return (int)max(1, $mb * 1048576);
}

function softwarePasta($cfg)
{
    return rtrim($cfg['dados_dir'], '/\\') . '/software';
}

function softwareCaminho($cfg, $pid)
{
    return softwarePasta($cfg) . '/' . $pid . '.bin';
}

function softwareHost($h)
{
    return strtoupper(trim(cortar(is_scalar($h) ? (string)$h : '', 100)));
}

// Tipo executavel pela extensao do nome (bat conta como cmd); '' se nao for executavel.
function softwareTipoDe($nome)
{
    $e = strtolower(pathinfo((string)$nome, PATHINFO_EXTENSION));
    if ($e === 'bat') return 'cmd';
    return in_array($e, SOFTWARE_TIPOS_EXEC, true) ? $e : '';
}

// Um trecho de caminho dentro do zip: letras, numeros, ponto, espaco, hifen, sublinhado, parenteses e colchetes; sem ponto/espaco no fim
// e sem nome reservado do Windows. O agent aplica a mesma regra ao extrair.
function softwareSegmentoSeguro($s)
{
    if (!is_string($s) || $s === '' || strlen($s) > 100) return false;
    if (!preg_match('/^[A-Za-z0-9._ ()\[\]-]+$/', $s)) return false;
    if ($s === '.' || $s === '..' || preg_match('/[. ]$/', $s)) return false;
    return !preg_match('/^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)/i', $s);
}

// Caminho relativo dentro do zip, com "/" (ate 8 niveis).
function softwareCaminhoRelValido($p)
{
    if (!is_string($p) || $p === '' || strlen($p) > 240) return false;
    $partes = explode('/', $p);
    if (count($partes) > 8) return false;
    foreach ($partes as $s) { if (!softwareSegmentoSeguro($s)) return false; }
    return true;
}

// Gatilho: caminho absoluto local, com variaveis [programfiles] etc. O agent confere de novo antes de usar.
function softwareGatilhoValido($g)
{
    if (!is_string($g) || strlen($g) > 260) return false;
    if (preg_match('/[<>"|?*\x00-\x1f]/', $g)) return false;
    if (strpos($g, '..') !== false) return false;
    return (bool)preg_match('/^(\[(programfiles|programfiles\(x86\)|programfiles\(x64\)|programdata|windir|system32|systemdrive)\]|[A-Za-z]:)\\\\[^\\\\]/i', $g);
}

// Texto livre curto (sem caracteres de controle).
function softwareTextoOk($t, $max)
{
    return is_string($t) && mb_strlen($t) <= $max && !preg_match('/[\x00-\x08\x0b\x0c\x0e-\x1f]/', $t);
}

// Confere o formato do manifesto (a assinatura em si e conferida pelo agent). Devolve ['m' => array] ou ['erro' => texto].
function softwareValidarManifesto($manifesto, $cfg)
{
    if (!is_string($manifesto) || $manifesto === '' || strlen($manifesto) > 8192) return ['erro' => 'manifesto invalido'];
    $m = json_decode($manifesto, true);
    if (!is_array($m)) return ['erro' => 'manifesto invalido'];
    if (!isset($m['v']) || (int)$m['v'] !== 2) return ['erro' => 'versao do manifesto nao suportada'];
    if (!isset($m['pid']) || !is_string($m['pid']) || !preg_match('/^[0-9a-f]{32}$/', $m['pid'])) return ['erro' => 'identificador do pacote invalido'];
    if (!isset($m['nome']) || !is_string($m['nome']) || trim($m['nome']) === '' || mb_strlen($m['nome']) > 120) return ['erro' => 'nome invalido'];
    if (!isset($m['tipo']) || !in_array($m['tipo'], SOFTWARE_TIPOS, true)) return ['erro' => 'tipo invalido (use msi, exe, ps1, cmd, vbs ou zip)'];
    if (!isset($m['sha256']) || !is_string($m['sha256']) || !preg_match('/^[0-9a-f]{64}$/', $m['sha256'])) return ['erro' => 'hash invalido'];
    if (!isset($m['tamanho']) || !is_int($m['tamanho']) || $m['tamanho'] < 1) return ['erro' => 'tamanho invalido'];
    if ($m['tamanho'] > softwareMaxBytes($cfg)) return ['erro' => 'arquivo maior que o limite de ' . round(softwareMaxBytes($cfg) / 1048576) . ' MB'];
    if (!isset($m['args']) || !softwareTextoOk($m['args'], 1000)) return ['erro' => 'parametros invalidos'];
    if (!isset($m['arquivo']) || !is_string($m['arquivo']) || !preg_match('/^[A-Za-z0-9][A-Za-z0-9._ -]{0,100}$/', $m['arquivo'])) return ['erro' => 'nome do arquivo invalido'];
    if ($m['tipo'] === 'zip') {
        if (strtolower(pathinfo($m['arquivo'], PATHINFO_EXTENSION)) !== 'zip') return ['erro' => 'o arquivo de um pacote zip precisa terminar em .zip'];
        if (!isset($m['executavel']) || !softwareCaminhoRelValido($m['executavel']) || softwareTipoDe($m['executavel']) === '') return ['erro' => 'indique o arquivo a executar dentro do zip (.msi, .exe, .ps1, .cmd, .bat ou .vbs)'];
    } else {
        if (softwareTipoDe($m['arquivo']) !== $m['tipo']) return ['erro' => 'a extensao do arquivo nao combina com o tipo'];
        if (isset($m['executavel']) && $m['executavel'] !== '') return ['erro' => 'executavel so vale para pacote zip'];
    }
    if (isset($m['descricao']) && !softwareTextoOk($m['descricao'], 300)) return ['erro' => 'descricao invalida (ate 300 caracteres)'];
    if (isset($m['software']) && !softwareTextoOk($m['software'], 120)) return ['erro' => 'nome do software invalido'];
    if (isset($m['gatilho']) && $m['gatilho'] !== '' && !softwareGatilhoValido($m['gatilho'])) return ['erro' => 'arquivo gatilho invalido (use um caminho completo como [programfiles]\\Programa\\programa.exe, sem curingas)'];
    if (isset($m['desinstalar']) && $m['desinstalar'] !== null) {
        $d = $m['desinstalar'];
        if (!is_array($d) || !isset($d['modo'])) return ['erro' => 'desinstalacao invalida'];
        if (isset($d['args']) && !softwareTextoOk($d['args'], 500)) return ['erro' => 'parametros de desinstalacao invalidos'];
        if ($d['modo'] === 'msi') {
            if (!isset($d['codigo']) || !is_string($d['codigo']) || !preg_match('/^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$/', $d['codigo'])) return ['erro' => 'codigo do produto MSI invalido (formato {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX})'];
        } elseif ($d['modo'] === 'nome') {
            if (!isset($d['software']) || !is_string($d['software']) || trim($d['software']) === '' || !softwareTextoOk($d['software'], 120)) return ['erro' => 'informe o nome do programa como aparece em Programas e Recursos'];
        } elseif ($d['modo'] === 'script') {
            if ($m['tipo'] === 'zip') {
                if (!isset($d['arquivo']) || !softwareCaminhoRelValido($d['arquivo']) || !in_array(softwareTipoDe($d['arquivo']), ['ps1', 'cmd', 'vbs'], true)) return ['erro' => 'script de desinstalacao invalido (.ps1, .cmd, .bat ou .vbs dentro do zip)'];
            } elseif (!in_array($m['tipo'], ['ps1', 'cmd', 'vbs'], true)) return ['erro' => 'desinstalacao por script exige pacote .ps1, .cmd, .bat, .vbs ou zip'];
        } else return ['erro' => 'modo de desinstalacao invalido'];
    }
    return ['m' => $m];
}

// Se a extensao zip do PHP existir, confere o zip recebido (nomes seguros, limites e arquivos que serao executados). O agent confere de novo.
function softwareConferirZip($caminho, $m)
{
    if (!class_exists('ZipArchive')) return null;
    $z = new ZipArchive();
    if ($z->open($caminho) !== true) return 'o arquivo nao e um zip valido';
    $erro = null; $total = 0; $nomes = [];
    if ($z->numFiles < 1 || $z->numFiles > SOFTWARE_ZIP_MAX_ARQUIVOS) $erro = 'o zip tem arquivos demais (maximo ' . SOFTWARE_ZIP_MAX_ARQUIVOS . ')';
    for ($i = 0; $erro === null && $i < $z->numFiles; $i++) {
        $s = $z->statIndex($i);
        $n = rtrim((string)$s['name'], '/');
        $total += (int)$s['size'];
        if ($n === '' || !softwareCaminhoRelValido($n)) { $erro = 'o zip tem um nome de arquivo nao permitido: ' . cortar($n, 60); break; }
        if (substr((string)$s['name'], -1) !== '/') $nomes[strtolower($n)] = true;
    }
    if ($erro === null && $total > SOFTWARE_ZIP_MAX_DESCOMPACTADO) $erro = 'o zip descompactado passa de 2 GB';
    $z->close();
    if ($erro !== null) return $erro;
    $precisa = [$m['executavel']];
    if (isset($m['desinstalar']['modo']) && $m['desinstalar']['modo'] === 'script' && isset($m['desinstalar']['arquivo'])) $precisa[] = $m['desinstalar']['arquivo'];
    foreach ($precisa as $p) { if (!isset($nomes[strtolower($p)])) return 'o arquivo "' . $p . '" nao existe dentro do zip'; }
    return null;
}

function softwareCriar(PDO $db, $cfg, $agora, $login, $manifesto, $assinatura)
{
    $v = softwareValidarManifesto($manifesto, $cfg);
    if (isset($v['erro'])) return ['erro' => $v['erro'], 'status' => 400];
    if (!is_string($assinatura) || !preg_match('#^[A-Za-z0-9+/=\s]{100,1000}$#', $assinatura)) return ['erro' => 'assinatura ausente ou invalida', 'status' => 400];
    $m = $v['m'];
    $st = $db->prepare('SELECT 1 FROM pacotes WHERE pid = ?'); $st->execute([$m['pid']]);
    if ($st->fetchColumn()) return ['erro' => 'pacote ja cadastrado', 'status' => 409];
    $db->prepare('INSERT INTO pacotes (pid, nome, tipo, manifesto, assinatura, sha256, tamanho, arquivo_ok, criado_em, criado_por) VALUES (?,?,?,?,?,?,?,0,?,?)')
        ->execute([$m['pid'], trim($m['nome']), $m['tipo'], $manifesto, preg_replace('/\s+/', '', $assinatura), $m['sha256'], $m['tamanho'], $agora, $login]);
    return ['ok' => true, 'pid' => $m['pid']];
}

// Recebe o arquivo (corpo cru da requisicao) e so aceita se tamanho e SHA-256 batem com o manifesto assinado.
function softwareReceberArquivo(PDO $db, $cfg, $pid)
{
    if (!preg_match('/^[0-9a-f]{32}$/', (string)$pid)) return ['erro' => 'pacote invalido', 'status' => 400];
    $st = $db->prepare('SELECT sha256, tamanho, manifesto, tipo FROM pacotes WHERE pid = ?'); $st->execute([$pid]);
    $p = $st->fetch();
    if (!$p) return ['erro' => 'pacote nao encontrado', 'status' => 404];
    $pasta = softwarePasta($cfg);
    if (!is_dir($pasta) && !@mkdir($pasta, 0750, true) && !is_dir($pasta)) return ['erro' => 'nao foi possivel criar a pasta de pacotes', 'status' => 500];
    $tmp = softwareCaminho($cfg, $pid) . '.parcial';
    $in = fopen('php://input', 'rb'); $out = fopen($tmp, 'wb');
    if (!$in || !$out) return ['erro' => 'falha ao gravar o arquivo', 'status' => 500];
    $limite = (int)$p['tamanho'];
    $total = 0; $ctx = hash_init('sha256');
    while (!feof($in)) {
        $b = fread($in, 262144);
        if ($b === false || $b === '') break;
        $total += strlen($b);
        if ($total > $limite) { fclose($in); fclose($out); @unlink($tmp); return ['erro' => 'arquivo maior que o declarado no manifesto', 'status' => 400]; }
        hash_update($ctx, $b); fwrite($out, $b);
    }
    fclose($in); fclose($out);
    if ($total !== $limite || !hash_equals((string)$p['sha256'], hash_final($ctx))) {
        @unlink($tmp);
        return ['erro' => 'o arquivo recebido nao confere com o tamanho/hash assinados (envio incompleto ou arquivo trocado)', 'status' => 400];
    }
    if ($p['tipo'] === 'zip') {
        $e = softwareConferirZip($tmp, json_decode($p['manifesto'], true));
        if ($e !== null) { @unlink($tmp); return ['erro' => $e, 'status' => 400]; }
    }
    if (!@rename($tmp, softwareCaminho($cfg, $pid))) { @unlink($tmp); return ['erro' => 'falha ao gravar o arquivo', 'status' => 500]; }
    $db->prepare('UPDATE pacotes SET arquivo_ok = 1 WHERE pid = ?')->execute([$pid]);
    return ['ok' => true, 'bytes' => $total];
}

function softwareListar(PDO $db)
{
    $pacotes = $db->query('SELECT pid, nome, tipo, sha256, tamanho, arquivo_ok, criado_em, criado_por, manifesto, auto, alvo FROM pacotes ORDER BY criado_em DESC')->fetchAll();
    $cont = [];
    foreach ($db->query('SELECT pid, acao, estado, COUNT(*) n FROM tarefas GROUP BY pid, acao, estado') as $r) {
        $k = $r['acao'] === 'desinstalar' ? 'desinstalar_' . $r['estado'] : $r['estado'];
        $cont[$r['pid']][$k] = (int)$r['n'];
    }
    $res = [];
    foreach ($pacotes as $p) {
        $m = json_decode($p['manifesto'], true);
        if (!is_array($m)) $m = [];
        $res[] = ['pid' => $p['pid'], 'nome' => $p['nome'], 'tipo' => $p['tipo'], 'tamanho' => (int)$p['tamanho'], 'sha256' => $p['sha256'],
            'args' => isset($m['args']) ? (string)$m['args'] : '', 'descricao' => isset($m['descricao']) ? (string)$m['descricao'] : '',
            'software' => isset($m['software']) ? (string)$m['software'] : '', 'executavel' => isset($m['executavel']) ? (string)$m['executavel'] : '',
            'gatilho' => isset($m['gatilho']) ? (string)$m['gatilho'] : '', 'desinstalar' => isset($m['desinstalar']['modo']) ? (string)$m['desinstalar']['modo'] : '',
            'auto' => (int)$p['auto'] === 1, 'alvo' => (string)$p['alvo'], 'arquivo_ok' => (int)$p['arquivo_ok'] === 1,
            'criado_em' => (int)$p['criado_em'], 'criado_por' => $p['criado_por'], 'tarefas' => isset($cont[$p['pid']]) ? $cont[$p['pid']] : new stdClass()];
    }
    return $res;
}

function softwareTarefas(PDO $db, $pid = '', $limite = 300)
{
    $sql = 'SELECT t.id, t.pid, p.nome, t.host, t.acao, t.estado, t.criado_em, t.criado_por, t.inicio_em, t.fim_em, t.codigo, t.saida
            FROM tarefas t LEFT JOIN pacotes p ON p.pid = t.pid' . ($pid !== '' ? ' WHERE t.pid = ?' : '') . ' ORDER BY t.id DESC LIMIT ' . (int)$limite;
    $st = $db->prepare($sql); $st->execute($pid !== '' ? [$pid] : []);
    return $st->fetchAll();
}

// Cria uma tarefa por maquina (pula as que ja tem uma pendente ou em execucao do mesmo pacote e da mesma acao). $acao: instalar | desinstalar.
function softwareInstalar(PDO $db, $agora, $login, $pid, $hosts, $acao = 'instalar')
{
    if (!in_array($acao, ['instalar', 'desinstalar'], true)) return ['erro' => 'acao invalida', 'status' => 400];
    $st = $db->prepare('SELECT arquivo_ok, manifesto FROM pacotes WHERE pid = ?'); $st->execute([(string)$pid]);
    $p = $st->fetch();
    if (!$p) return ['erro' => 'pacote nao encontrado', 'status' => 404];
    if ((int)$p['arquivo_ok'] !== 1) return ['erro' => 'o arquivo do pacote ainda nao foi enviado', 'status' => 409];
    if ($acao === 'desinstalar') {
        $m = json_decode($p['manifesto'], true);
        if (!is_array($m) || empty($m['desinstalar'])) return ['erro' => 'este pacote nao tem desinstalacao definida (ela e assinada junto com o pacote; cadastre outro pacote com a desinstalacao)', 'status' => 409];
    }
    if (!is_array($hosts) || count($hosts) < 1) return ['erro' => 'escolha ao menos uma maquina', 'status' => 400];
    if (count($hosts) > 1000) return ['erro' => 'maquinas demais de uma vez (maximo 1000)', 'status' => 400];
    $criadas = 0; $ignoradas = 0; $vistos = [];
    $busca = $db->prepare("SELECT 1 FROM tarefas WHERE pid = ? AND host = ? AND acao = ? AND estado IN ('pendente','executando')");
    $ins = $db->prepare("INSERT INTO tarefas (pid, host, acao, estado, criado_em, criado_por) VALUES (?,?,?,'pendente',?,?)");
    $db->beginTransaction();
    try {
        foreach ($hosts as $h) {
            $h = softwareHost($h);
            if ($h === '' || isset($vistos[$h])) continue;
            $vistos[$h] = true;
            $busca->execute([$pid, $h, $acao]);
            if ($busca->fetchColumn()) { $ignoradas++; continue; }
            $ins->execute([$pid, $h, $acao, $agora, $login]);
            $criadas++;
        }
        $db->prepare("DELETE FROM tarefas WHERE estado IN ('ok','falhou','cancelada') AND criado_em < ?")->execute([$agora - 365 * 86400000]);
        $db->commit();
    } catch (Throwable $e) { $db->rollBack(); throw $e; }
    return ['ok' => true, 'criadas' => $criadas, 'ignoradas' => $ignoradas];
}

// Politica de aplicacao (nao assinada): auto = instala sozinho em todas as maquinas (as novas inclusive) que combinem com o alvo.
// alvo: lista de nomes de maquina com * e ? (ex.: MTZ*, NOTE-?), separados por virgula; vazio = todas. Servidores marcados ficam de fora.
function softwarePolitica(PDO $db, $pid, $auto, $alvo)
{
    if (!preg_match('/^[0-9a-f]{32}$/', (string)$pid)) return ['erro' => 'pacote invalido', 'status' => 400];
    $alvo = trim(is_scalar($alvo) ? (string)$alvo : '');
    if (!preg_match('/^[A-Za-z0-9*?_,; -]{0,200}$/', $alvo)) return ['erro' => 'alvo invalido (use nomes de maquina, com * e ?, separados por virgula)', 'status' => 400];
    $st = $db->prepare('SELECT arquivo_ok FROM pacotes WHERE pid = ?'); $st->execute([$pid]);
    $ok = $st->fetchColumn();
    if ($ok === false) return ['erro' => 'pacote nao encontrado', 'status' => 404];
    if ($auto && (int)$ok !== 1) return ['erro' => 'o arquivo do pacote ainda nao foi enviado', 'status' => 409];
    $db->prepare('UPDATE pacotes SET auto = ?, alvo = ? WHERE pid = ?')->execute([$auto ? 1 : 0, $alvo, $pid]);
    return ['ok' => true, 'auto' => (bool)$auto, 'alvo' => $alvo];
}

function softwareAlvoCombina($alvo, $host)
{
    $alvo = trim((string)$alvo);
    if ($alvo === '') return true;
    foreach (preg_split('/[,;\s]+/', $alvo, -1, PREG_SPLIT_NO_EMPTY) as $p) {
        $re = '/^' . str_replace(['\*', '\?'], ['.*', '.'], preg_quote($p, '/')) . '$/i';
        if (preg_match($re, $host)) return true;
    }
    return false;
}

// Politicas automaticas: cria a tarefa de instalacao para esta maquina quando ainda nao existe (ou refaz as que falharam, com limite).
function softwareAutomaticas(PDO $db, $host, $agora)
{
    $host = softwareHost($host);
    if ($host === '') return;
    $sv = $db->prepare('SELECT 1 FROM servidores WHERE host = ? COLLATE NOCASE'); $sv->execute([$host]);
    if ($sv->fetchColumn()) return;
    $pacotes = $db->query('SELECT pid, alvo FROM pacotes WHERE auto = 1 AND arquivo_ok = 1')->fetchAll();
    if (!$pacotes) return;
    $q = $db->prepare("SELECT estado, MAX(CASE WHEN fim_em > 0 THEN fim_em ELSE criado_em END) ult, COUNT(*) n FROM tarefas WHERE pid = ? AND host = ? AND acao = 'instalar' GROUP BY estado");
    $ins = $db->prepare("INSERT INTO tarefas (pid, host, acao, estado, criado_em, criado_por) VALUES (?,?,'instalar','pendente',?,'automatico')");
    foreach ($pacotes as $p) {
        if (!softwareAlvoCombina($p['alvo'], $host)) continue;
        $q->execute([$p['pid'], $host]);
        $est = [];
        foreach ($q->fetchAll() as $r) $est[$r['estado']] = ['n' => (int)$r['n'], 'ult' => (int)$r['ult']];
        if (isset($est['pendente']) || isset($est['executando']) || isset($est['ok']) || isset($est['cancelada'])) continue;
        if (isset($est['falhou']) && ($est['falhou']['n'] >= SOFTWARE_TENTATIVAS_AUTO || $est['falhou']['ult'] > $agora - SOFTWARE_INTERVALO_AUTO_MS)) continue;
        $ins->execute([$p['pid'], $host, $agora]);
    }
}

function softwareExcluir(PDO $db, $cfg, $pid)
{
    if (!preg_match('/^[0-9a-f]{32}$/', (string)$pid)) return ['erro' => 'pacote invalido', 'status' => 400];
    $st = $db->prepare('DELETE FROM pacotes WHERE pid = ?'); $st->execute([$pid]);
    if ($st->rowCount() < 1) return ['erro' => 'pacote nao encontrado', 'status' => 404];
    $db->prepare('DELETE FROM tarefas WHERE pid = ?')->execute([$pid]);
    foreach ([softwareCaminho($cfg, $pid), softwareCaminho($cfg, $pid) . '.parcial'] as $f) { if (is_file($f)) @unlink($f); }
    return ['ok' => true];
}

function softwareCancelarTarefa(PDO $db, $id)
{
    $st = $db->prepare("UPDATE tarefas SET estado = 'cancelada', fim_em = 0 WHERE id = ? AND estado = 'pendente'"); $st->execute([(int)$id]);
    return $st->rowCount() > 0 ? ['ok' => true] : ['erro' => 'so tarefas pendentes podem ser canceladas', 'status' => 409];
}

function softwareRepetirTarefa(PDO $db, $agora, $login, $id)
{
    $st = $db->prepare("UPDATE tarefas SET estado = 'pendente', criado_em = ?, criado_por = ?, inicio_em = 0, fim_em = 0, codigo = NULL, saida = '' WHERE id = ? AND estado IN ('falhou','cancelada')");
    $st->execute([$agora, $login, (int)$id]);
    return $st->rowCount() > 0 ? ['ok' => true] : ['erro' => 'so tarefas que falharam ou foram canceladas podem ser repetidas', 'status' => 409];
}

// ---- lado do agent ----

function softwareTarefasPara(PDO $db, $host, $agora)
{
    softwareAutomaticas($db, $host, $agora);
    $st = $db->prepare("SELECT t.id, t.pid, t.acao, p.manifesto, p.assinatura FROM tarefas t JOIN pacotes p ON p.pid = t.pid
        WHERE t.host = ? AND p.arquivo_ok = 1 AND (t.estado = 'pendente' OR (t.estado = 'executando' AND t.inicio_em < ?)) ORDER BY t.id LIMIT 5");
    $st->execute([softwareHost($host), $agora - SOFTWARE_TAREFA_VENCE_MS]);
    return $st->fetchAll();
}

// Caminho do arquivo so para a maquina que tem tarefa em aberto deste pacote.
function softwareArquivoPara(PDO $db, $cfg, $host, $pid)
{
    if (!preg_match('/^[0-9a-f]{32}$/', (string)$pid)) return null;
    $st = $db->prepare("SELECT 1 FROM tarefas WHERE host = ? AND pid = ? AND estado IN ('pendente','executando')");
    $st->execute([softwareHost($host), $pid]);
    if (!$st->fetchColumn()) return null;
    $f = softwareCaminho($cfg, $pid);
    return is_file($f) ? $f : null;
}

// estado: 'executando' (reserva a tarefa; so uma vez) | 'ok' | 'falhou'
function softwareResultado(PDO $db, $agora, $host, $id, $estado, $codigo, $saida)
{
    $host = softwareHost($host); $id = (int)$id;
    if (!in_array($estado, ['executando', 'ok', 'falhou'], true)) return ['erro' => 'estado invalido', 'status' => 400];
    if ($estado === 'executando') {
        $st = $db->prepare("UPDATE tarefas SET estado = 'executando', inicio_em = ? WHERE id = ? AND host = ? AND (estado = 'pendente' OR (estado = 'executando' AND inicio_em < ?))");
        $st->execute([$agora, $id, $host, $agora - SOFTWARE_TAREFA_VENCE_MS]);
        return $st->rowCount() > 0 ? ['ok' => true] : ['erro' => 'tarefa indisponivel', 'status' => 409];
    }
    $st = $db->prepare("UPDATE tarefas SET estado = ?, fim_em = ?, codigo = ?, saida = ? WHERE id = ? AND host = ? AND estado = 'executando'");
    $st->execute([$estado, $agora, is_numeric($codigo) ? (int)$codigo : null, cortar(is_scalar($saida) ? (string)$saida : '', 4000), $id, $host]);
    return $st->rowCount() > 0 ? ['ok' => true] : ['erro' => 'tarefa nao esta em execucao', 'status' => 409];
}
