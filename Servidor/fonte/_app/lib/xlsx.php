<?php
// Gerador minimo de .xlsx, sem extensoes alem do PHP basico (usa gzdeflate se existir).
// Celulas: texto, numeros e valores tipados: xDur(segundos), xPct(0-100), xDt(ts em ms), xDia('Y-m-d').
// Cada aba: ['nome' => 'Resumo', 'cabecalho' => [...], 'linhas' => [[...], ...], 'larguras' => [20, 12, ...]]

const XLSX_ESTILO_PADRAO = 0, XLSX_ESTILO_CABECALHO = 1, XLSX_ESTILO_DURACAO = 2, XLSX_ESTILO_PCT = 3, XLSX_ESTILO_DATAHORA = 4, XLSX_ESTILO_DATA = 5;

function xDur($segundos) { return $segundos === null ? null : ['t' => 'dur', 'v' => $segundos]; }
function xPct($pct) { return $pct === null ? null : ['t' => 'pct', 'v' => $pct]; }
function xDt($tsMs) { return $tsMs === null ? null : ['t' => 'dt', 'v' => $tsMs]; }
function xDia($dia) { return $dia === null || $dia === '' ? null : ['t' => 'dia', 'v' => $dia]; }

function xlsxColuna($i)
{
    $s = '';
    $i++;
    while ($i > 0) { $m = ($i - 1) % 26; $s = chr(65 + $m) . $s; $i = intdiv($i - 1, 26); }
    return $s;
}

function xlsxTexto($s)
{
    $s = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F]/', '', (string)$s);
    return htmlspecialchars($s, ENT_XML1 | ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function xlsxNumero($n)
{
    $s = rtrim(rtrim(sprintf('%.10F', (float)$n), '0'), '.');
    return $s === '' || $s === '-' ? '0' : $s;
}

// $offsetSeg: diferenca do fuso local para UTC (datas/horas aparecem no horario local, como no painel).
function xlsxCelula($ref, $v, $offsetSeg, $estilo = XLSX_ESTILO_PADRAO)
{
    if ($v === null || $v === '') return '';
    if (is_array($v)) {
        switch ($v['t']) {
            case 'dur': return '<c r="' . $ref . '" s="' . XLSX_ESTILO_DURACAO . '"><v>' . xlsxNumero($v['v'] / 86400) . '</v></c>';
            case 'pct': return '<c r="' . $ref . '" s="' . XLSX_ESTILO_PCT . '"><v>' . xlsxNumero($v['v'] / 100) . '</v></c>';
            case 'dt':  return '<c r="' . $ref . '" s="' . XLSX_ESTILO_DATAHORA . '"><v>' . xlsxNumero(($v['v'] / 1000 + $offsetSeg) / 86400 + 25569) . '</v></c>';
            case 'dia':
                $d = DateTimeImmutable::createFromFormat('!Y-m-d', $v['v'], new DateTimeZone('UTC'));
                if (!$d) return '';
                return '<c r="' . $ref . '" s="' . XLSX_ESTILO_DATA . '"><v>' . xlsxNumero($d->getTimestamp() / 86400 + 25569) . '</v></c>';
        }
        return '';
    }
    if (is_int($v) || is_float($v)) return '<c r="' . $ref . '" s="' . $estilo . '"><v>' . xlsxNumero($v) . '</v></c>';
    return '<c r="' . $ref . '" t="inlineStr" s="' . $estilo . '"><is><t xml:space="preserve">' . xlsxTexto($v) . '</t></is></c>';
}

function xlsxAba(array $aba, $offsetSeg)
{
    $cab = $aba['cabecalho'];
    $nCol = count($cab);
    $xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        . '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        . '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
        . '<sheetFormatPr defaultRowHeight="15"/><cols>';
    for ($i = 0; $i < $nCol; $i++) {
        $w = isset($aba['larguras'][$i]) ? $aba['larguras'][$i] : 16;
        $xml .= '<col min="' . ($i + 1) . '" max="' . ($i + 1) . '" width="' . $w . '" customWidth="1"/>';
    }
    $xml .= '</cols><sheetData><row r="1">';
    foreach ($cab as $i => $t) $xml .= xlsxCelula(xlsxColuna($i) . '1', (string)$t, $offsetSeg, XLSX_ESTILO_CABECALHO);
    $xml .= '</row>';
    $r = 1;
    foreach ($aba['linhas'] as $linha) {
        $r++;
        $xml .= '<row r="' . $r . '">';
        foreach ($linha as $i => $v) $xml .= xlsxCelula(xlsxColuna($i) . $r, $v, $offsetSeg);
        $xml .= '</row>';
    }
    $xml .= '</sheetData>';
    if ($nCol > 0) $xml .= '<autoFilter ref="A1:' . xlsxColuna($nCol - 1) . max(1, $r) . '"/>';
    return $xml . '</worksheet>';
}

function xlsxEstilos()
{
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        . '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        . '<numFmts count="3"><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/><numFmt numFmtId="165" formatCode="dd/mm/yyyy hh:mm"/><numFmt numFmtId="166" formatCode="0.0%"/></numFmts>'
        . '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font></fonts>'
        . '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
        . '<fill><patternFill patternType="solid"><fgColor rgb="FF1F3A5F"/><bgColor indexed="64"/></patternFill></fill></fills>'
        . '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        . '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        . '<cellXfs count="6">'
        . '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        . '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>'
        . '<xf numFmtId="46" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
        . '<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
        . '<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
        . '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
        . '</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>';
}

function xlsxNomeAba($nome)
{
    $n = preg_replace('/[\[\]:*?\/\\\\]/', ' ', $nome);
    $n = trim($n);
    if (function_exists('mb_substr')) return mb_substr($n, 0, 31, 'UTF-8');
    return preg_match('/^.{0,31}/su', $n, $m) ? $m[0] : substr($n, 0, 31);
}

// Devolve o conteudo binario do .xlsx.
function gerarXlsx(array $abas, $offsetSeg = 0)
{
    $arq = [];
    $ct = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        . '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
        . '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        . '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>';
    $wb = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>';
    $rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">';
    $i = 0;
    foreach ($abas as $aba) {
        $i++;
        $ct .= '<Override PartName="/xl/worksheets/sheet' . $i . '.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>';
        $wb .= '<sheet name="' . xlsxTexto(xlsxNomeAba($aba['nome'])) . '" sheetId="' . $i . '" r:id="rId' . $i . '"/>';
        $rels .= '<Relationship Id="rId' . $i . '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet' . $i . '.xml"/>';
        $arq['xl/worksheets/sheet' . $i . '.xml'] = xlsxAba($aba, $offsetSeg);
    }
    $rels .= '<Relationship Id="rId' . ($i + 1) . '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>';
    $arq['[Content_Types].xml'] = $ct . '</Types>';
    $arq['_rels/.rels'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>';
    $arq['xl/workbook.xml'] = $wb . '</sheets></workbook>';
    $arq['xl/_rels/workbook.xml.rels'] = $rels;
    $arq['xl/styles.xml'] = xlsxEstilos();
    return zipMinimo($arq);
}

// Zip simples (deflate quando disponivel, senao armazenado).
function zipMinimo(array $arquivos)
{
    $dados = ''; $central = ''; $n = 0; $off = 0;
    $agora = getdate();
    $hora = ($agora['hours'] << 11) | ($agora['minutes'] << 5) | intdiv($agora['seconds'], 2);
    $data = ((max(1980, $agora['year']) - 1980) << 9) | ($agora['mon'] << 5) | $agora['mday'];
    foreach ($arquivos as $nome => $conteudo) {
        $crc = crc32($conteudo) & 0xFFFFFFFF;
        $tam = strlen($conteudo);
        $comp = function_exists('gzdeflate') ? gzdeflate($conteudo, 6) : false;
        if ($comp !== false && strlen($comp) < $tam) { $metodo = 8; $bin = $comp; } else { $metodo = 0; $bin = $conteudo; }
        $local = pack('VvvvvvVVVvv', 0x04034b50, 20, 0x0800, $metodo, $hora, $data, $crc, strlen($bin), $tam, strlen($nome), 0) . $nome . $bin;
        $central .= pack('VvvvvvvVVVvvvvvVV', 0x02014b50, 20, 20, 0x0800, $metodo, $hora, $data, $crc, strlen($bin), $tam, strlen($nome), 0, 0, 0, 0, 0, $off) . $nome;
        $dados .= $local;
        $off += strlen($local);
        $n++;
    }
    return $dados . $central . pack('VvvvvVVv', 0x06054b50, 0, 0, $n, $n, strlen($central), strlen($dados), 0);
}
