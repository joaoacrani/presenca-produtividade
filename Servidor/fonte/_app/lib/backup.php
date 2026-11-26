<?php
// Instantaneo diario do banco para o backup. Fica UMA copia so em <dados_dir>/backup/presenca-snapshot.sqlite (a pasta dados e fechada
// ao navegador). O script do PC (Backup-Servidor.ps1) baixa essa copia, confere, comprime la e APAGA a copia do servidor: assim o disco da
// hospedagem so carrega uma copia a mais por poucas horas e nunca acumula historico.
// Protecoes para nao estourar o disco nem atrapalhar os agents:
//   - so roda uma vez a cada ~22 h (uma requisicao "vence" a disputa, como na limpeza) e depois de a resposta ter sido enviada;
//   - so copia se sobrar espaco: pelo menos 1,5 x o tamanho do banco livres (senao registra "sem espaco" e tenta no dia seguinte);
//   - nao copia se o banco passar de 'backup_max_mb' (padrao 4096): avisa na auditoria em vez de segurar a gravacao dos agents;
//   - copia o arquivo inteiro enquanto segura a vez de escrever (BEGIN IMMEDIATE), depois de esvaziar o WAL: copia consistente.
// Desligar: 'backup_snapshot' => false no config.php.

function backupPasta($cfg) { return rtrim((string)$cfg['dados_dir'], '/\\') . '/backup'; }

function backupInfo(PDO $db, $cfg)
{
    $arq = backupPasta($cfg) . '/presenca-snapshot.sqlite';
    $existe = is_file($arq);
    return [
        'ligado' => !isset($cfg['backup_snapshot']) || $cfg['backup_snapshot'] !== false,
        'existe' => $existe,
        'tamanho' => $existe ? (int)filesize($arq) : 0,
        'gerado_em' => (int)metaGet($db, 'snapshot_ok_em'),
        'ultimo_estado' => (string)metaGet($db, 'snapshot_estado'),
        'tamanho_banco' => is_file($cfg['dados_dir'] . '/presenca.sqlite') ? (int)filesize($cfg['dados_dir'] . '/presenca.sqlite') : 0,
    ];
}

// Chamada depois de gravar o que o agent mandou: decide se hoje e dia de snapshot e, se for, agenda o trabalho para depois da resposta.
function snapshotSeDevido(PDO $db, $cfg, $agora)
{
    if (isset($cfg['backup_snapshot']) && $cfg['backup_snapshot'] === false) return;
    $ult = (string)metaGet($db, 'snapshot_em');
    if ($ult === '') { $db->prepare('INSERT OR IGNORE INTO meta (chave, valor) VALUES (?, ?)')->execute(['snapshot_em', '0']); $ult = '0'; }
    if ($agora - (int)$ult < 79200000) return;   // 22 h
    $vez = $db->prepare('UPDATE meta SET valor = ? WHERE chave = ? AND valor = ?');
    $vez->execute([(string)$agora, 'snapshot_em', $ult]);
    if ($vez->rowCount() === 0) return;           // outra requisicao ja pegou a vez
    register_shutdown_function(function () use ($cfg, $agora) {
        if (function_exists('fastcgi_finish_request')) @fastcgi_finish_request();   // o agent ja recebeu a resposta
        try { $db2 = abrirBanco($cfg); gerarSnapshot($db2, $cfg, $agora); }
        catch (Throwable $e) { error_log('presenca: snapshot falhou: ' . $e->getMessage()); }
    });
}

// Gera a copia agora. Devolve ['ok'=>true,'tamanho'=>n,'ms'=>n] ou ['ok'=>false,'motivo'=>texto].
function gerarSnapshot(PDO $db, $cfg, $agora)
{
    $falha = function ($motivo, $refazer = false) use ($db, $agora) {
        metaSet($db, 'snapshot_estado', $motivo . ' (' . gmdate('Y-m-d H:i', intdiv($agora, 1000)) . ' UTC)');
        if ($refazer) metaSet($db, 'snapshot_em', '0');   // tenta de novo na proxima requisicao
        return ['ok' => false, 'motivo' => $motivo];
    };
    $origem = $cfg['dados_dir'] . '/presenca.sqlite';
    if (!is_file($origem)) return $falha('banco nao encontrado');
    $tam = (int)filesize($origem);
    $maxMb = isset($cfg['backup_max_mb']) ? (float)$cfg['backup_max_mb'] : 4096;
    if ($maxMb > 0 && $tam > $maxMb * 1048576) return $falha('banco maior que ' . $maxMb . ' MB: copia pulada (suba backup_max_mb ou use outro metodo)');
    $pasta = backupPasta($cfg);
    if (!is_dir($pasta) && !@mkdir($pasta, 0750, true)) return $falha('nao foi possivel criar a pasta do backup');
    $livre = @disk_free_space($pasta);
    // a copia antiga sera trocada: o que ela ocupa conta como espaco livre
    $antiga = is_file($pasta . '/presenca-snapshot.sqlite') ? (int)filesize($pasta . '/presenca-snapshot.sqlite') : 0;
    if ($livre !== false && ($livre + $antiga) < $tam * 1.5) return $falha('sem espaco livre para a copia (precisa de 1,5 x o banco)');

    $t0 = microtime(true);
    $tmp = $pasta . '/presenca-snapshot.sqlite.tmp';
    @unlink($tmp);
    $modo = strtolower((string)$db->query('PRAGMA journal_mode')->fetchColumn());
    if ($modo === 'wal') {
        $ck = $db->query('PRAGMA wal_checkpoint(TRUNCATE)')->fetch(PDO::FETCH_NUM);
        if ($ck && (int)$ck[0] !== 0) return $falha('banco ocupado: nao foi possivel esvaziar o WAL', true);
    }
    $db->exec('BEGIN IMMEDIATE');   // ninguem escreve enquanto o arquivo e copiado
    try {
        $ok = @copy($origem, $tmp);
    } finally { $db->exec('COMMIT'); }
    if (!$ok || (int)@filesize($tmp) !== $tam) { @unlink($tmp); return $falha('falha ao copiar o banco', true); }
    if (!@rename($tmp, $pasta . '/presenca-snapshot.sqlite')) { @unlink($tmp); return $falha('falha ao trocar a copia anterior', true); }
    @chmod($pasta . '/presenca-snapshot.sqlite', 0640);
    $ms = (int)round((microtime(true) - $t0) * 1000);
    metaSet($db, 'snapshot_ok_em', (string)$agora);
    metaSet($db, 'snapshot_estado', 'ok: ' . $tam . ' bytes em ' . $ms . ' ms');
    return ['ok' => true, 'tamanho' => $tam, 'ms' => $ms];
}
