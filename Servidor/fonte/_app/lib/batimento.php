<?php
// Batimento dos servidores: o servidor Windows fica ligado sem ninguem logado, entao a tarefa do usuario (que gera as leituras
// de presenca) nao roda. Para os servidores marcados no painel, o agent cria uma tarefa SYSTEM que so avisa "estou no ar"
// a cada 5 minutos (nao depende de usuario) e o painel mostra "No ar" / "Fora do ar" em vez de "Sem sinal".

// Um batimento so e aceito de maquina marcada como servidor (evita lixo e o agent so cria a tarefa nelas).
function gravarBatimento(PDO $db, $host, $bootMs, $agora)
{
    $host = trim(cortar((string)$host, 100));
    if ($host === '') return ['erro' => 'host obrigatorio'];
    if (!ehServidor($db, $host)) return ['ok' => true, 'ignorado' => true];
    // boot plausivel: no passado, ate 10 anos atras (senao, guarda vazio)
    $boot = (int)$bootMs;
    if ($boot <= 0 || $boot > $agora + 60000 || $boot < $agora - 3650 * 86400000) $boot = null;
    $h = strtoupper($host);
    $db->prepare('INSERT OR IGNORE INTO batimento (host, visto_em, boot_em) VALUES (?,?,?)')->execute([$h, $agora, $boot]);
    $db->prepare('UPDATE batimento SET visto_em = ?, boot_em = ? WHERE host = ?')->execute([$agora, $boot, $h]);
    return ['ok' => true];
}

// ['HOST' => ['visto' => ms, 'boot' => ms|null]]
function mapaBatimentos(PDO $db)
{
    $m = [];
    foreach ($db->query('SELECT host, visto_em, boot_em FROM batimento') as $r) {
        $m[strtoupper($r['host'])] = ['visto' => (int)$r['visto_em'], 'boot' => $r['boot_em'] === null ? null : (int)$r['boot_em']];
    }
    return $m;
}

// Quanto tempo sem sinal ate dizer "fora do ar": com batimento a cada 5 min, 15 min (3 batimentos perdidos).
function servidorOnlineMin($cfg)
{
    $v = isset($cfg['servidor_online_min']) ? (int)$cfg['servidor_online_min'] : 15;
    return $v >= 5 ? $v : 15;
}
