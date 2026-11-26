<?php
// Cadastro do RH: cargo e centro de custo por colaborador, digitados na Administracao ou importados de um CSV.
// Casa pelo login (preferido) ou pelo nome completo sem acento e sem diferenca de maiusculas.

function normalizarNomeRh($s)
{
    $s = trim(preg_replace('/\s+/', ' ', (string)$s));
    $s = function_exists('mb_strtolower') ? mb_strtolower($s, 'UTF-8') : strtolower($s);
    return strtr($s, ['á' => 'a', 'à' => 'a', 'â' => 'a', 'ã' => 'a', 'ä' => 'a', 'é' => 'e', 'è' => 'e', 'ê' => 'e', 'ë' => 'e', 'í' => 'i', 'ì' => 'i', 'î' => 'i', 'ï' => 'i',
        'ó' => 'o', 'ò' => 'o', 'ô' => 'o', 'õ' => 'o', 'ö' => 'o', 'ú' => 'u', 'ù' => 'u', 'û' => 'u', 'ü' => 'u', 'ç' => 'c', 'ñ' => 'n']);
}

// Jornada contratual em horas por dia: "8", "8,5", "8:30" ou semanal ("44" vira 8,8 h/dia: acima de 12 e tratado como horas por semana, 5 dias).
function jornadaDeTexto($v)
{
    $s = trim((string)$v);
    if ($s === '') return null;
    if (preg_match('/^(\d{1,2}):(\d{2})$/', $s, $m)) $h = (int)$m[1] + (int)$m[2] / 60;
    else { $s = str_replace(',', '.', $s); if (!is_numeric($s)) return null; $h = (float)$s; }
    if ($h > 12) $h = $h / 5;
    return ($h >= 1 && $h <= 12) ? round($h, 2) : null;
}

// $linhas: [{login?, nome?, cargo?, centro_custo?, jornada?}]. Linha sem cargo, sem centro de custo e sem jornada e ignorada.
function importarRh(PDO $db, array $linhas, $agora)
{
    $porLogin = []; $porNome = [];
    foreach ($db->query('SELECT login, nome FROM colaboradores') as $c) {
        $porLogin[$c['login']] = true;
        $k = normalizarNomeRh($c['nome']);
        if ($k !== '') $porNome[$k][] = $c['login'];
    }
    $atualizados = 0; $ignoradas = 0; $naoAchou = []; $ambiguos = [];
    $up = $db->prepare('UPDATE colaboradores SET cargo = ?, centro_custo = ?, jornada_horas = COALESCE(?, jornada_horas), rh = 1, rh_em = ? WHERE login = ?');
    $db->beginTransaction();
    try {
        foreach (array_slice($linhas, 0, 5000) as $l) {
            if (!is_array($l)) { $ignoradas++; continue; }
            $login = loginDe(isset($l['login']) ? $l['login'] : '');
            $nome = isset($l['nome']) ? (string)$l['nome'] : '';
            $cargo = trim(cortar(isset($l['cargo']) ? (string)$l['cargo'] : '', 80));
            $cc = trim(cortar(isset($l['centro_custo']) ? (string)$l['centro_custo'] : '', 120));
            $jor = jornadaDeTexto(isset($l['jornada']) ? $l['jornada'] : '');
            if ($cargo === '' && $cc === '' && $jor === null) { $ignoradas++; continue; }
            $alvo = null;
            if ($login !== '' && isset($porLogin[$login])) $alvo = $login;
            elseif ($nome !== '') {
                $k = normalizarNomeRh($nome);
                if (isset($porNome[$k])) { if (count($porNome[$k]) === 1) $alvo = $porNome[$k][0]; else { $ambiguos[] = cortar($nome, 80); continue; } }
            }
            if ($alvo === null) { $naoAchou[] = cortar($nome !== '' ? $nome : $login, 80); continue; }
            $up->execute([$cargo, $cc, $jor, $agora, $alvo]);
            $atualizados++;
        }
        $db->commit();
    } catch (Throwable $e) { $db->rollBack(); throw $e; }
    return ['atualizados' => $atualizados, 'ignoradas' => $ignoradas,
        'nao_encontrados' => array_slice($naoAchou, 0, 30), 'total_nao_encontrados' => count($naoAchou),
        'ambiguos' => array_slice($ambiguos, 0, 30), 'total_ambiguos' => count($ambiguos)];
}
