'use strict';
// Leitor de .xlsx e do relatorio do TomTicket, sem bibliotecas: roda no navegador e nos testes (Node).
// Um .xlsx e um zip com XML dentro. Aqui: acha as entradas do zip, descompacta (deflate) e le a primeira planilha.
// Por privacidade, a coluna "Mensagem" do chamado e ignorada de proposito: ela nunca sai do navegador.

async function ccInflar(bytes) {
  const fluxo = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(fluxo).arrayBuffer());
}

// Entradas do zip pelo diretorio central. Zip64 nao e suportado (os relatorios sao pequenos).
function ccEntradasZip(buf) {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let i = buf.length - 22;
  const limite = Math.max(0, buf.length - 22 - 65535);
  while (i >= limite && dv.getUint32(i, true) !== 0x06054b50) i--;
  if (i < limite) throw new Error('Esse arquivo não é um .xlsx válido (zip não encontrado).');
  const total = dv.getUint16(i + 10, true), tam = dv.getUint32(i + 12, true), off = dv.getUint32(i + 16, true);
  if (total === 0xffff || tam === 0xffffffff || off === 0xffffffff) throw new Error('Arquivo grande demais (zip64 não é suportado).');
  const mapa = new Map();
  let p = off;
  for (let n = 0; n < total && p + 46 <= buf.length; n++) {
    if (dv.getUint32(p, true) !== 0x02014b50) throw new Error('O arquivo está corrompido.');
    const metodo = dv.getUint16(p + 10, true), comp = dv.getUint32(p + 20, true), nl = dv.getUint16(p + 28, true), el2 = dv.getUint16(p + 30, true), cl = dv.getUint16(p + 32, true);
    const local = dv.getUint32(p + 42, true);
    const nome = new TextDecoder('utf-8').decode(buf.subarray(p + 46, p + 46 + nl));
    mapa.set(nome, { metodo, comp, local });
    p += 46 + nl + el2 + cl;
  }
  return mapa;
}

async function ccLerEntrada(buf, e) {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  if (dv.getUint32(e.local, true) !== 0x04034b50) throw new Error('O arquivo está corrompido.');
  const ini = e.local + 30 + dv.getUint16(e.local + 26, true) + dv.getUint16(e.local + 28, true);
  const dados = buf.subarray(ini, ini + e.comp);
  if (e.metodo === 0) return dados;
  if (e.metodo === 8) return ccInflar(dados);
  throw new Error('Compactação do arquivo não suportada.');
}

function ccDecodificar(s) {
  return s.replace(/&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);/g, (m, e) => {
    if (e[0] === '#') return String.fromCodePoint(e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10));
    return { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" }[e];
  });
}

function ccStringsCompartilhadas(xml) {
  const out = [];
  const reSi = /<si(?:\s[^>]*)?>([\s\S]*?)<\/si>/g;
  let m;
  while ((m = reSi.exec(xml))) {
    let t = '';
    const reT = /<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g;
    let x;
    while ((x = reT.exec(m[1]))) t += x[1];
    out.push(ccDecodificar(t));
  }
  return out;
}

// Linhas da planilha como objetos { A: 'texto', B: 'texto' } (so as celulas que existem).
function ccLinhasDaPlanilha(xml, strs) {
  const linhas = [];
  const reRow = /<row(?:\s[^>]*?)?(?:\/>|>([\s\S]*?)<\/row>)/g;
  let r;
  while ((r = reRow.exec(xml))) {
    const cel = {};
    const reC = /<c\s([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g;
    let c;
    while ((c = reC.exec(r[1] || ''))) {
      const ref = /\br="([A-Z]+)\d+"/.exec(c[1]);
      if (!ref) continue;
      const tipo = (/\bt="(\w+)"/.exec(c[1]) || [])[1];
      const corpo = c[2] || '';
      let valor = '';
      if (tipo === 'inlineStr') valor = ccDecodificar([...corpo.matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)].map((x) => x[1]).join(''));
      else {
        const v = /<v(?:\s[^>]*)?>([\s\S]*?)<\/v>/.exec(corpo);
        if (v) valor = tipo === 's' ? (strs[parseInt(v[1], 10)] || '') : ccDecodificar(v[1]);
      }
      cel[ref[1]] = valor;
    }
    linhas.push(cel);
  }
  return linhas;
}

// Le um .xlsx (ArrayBuffer ou Uint8Array) e devolve as linhas da primeira planilha.
async function ccLerXlsx(entrada) {
  const buf = entrada instanceof Uint8Array ? entrada : new Uint8Array(entrada);
  const ent = ccEntradasZip(buf);
  const planilhas = [...ent.keys()].filter((n) => /^xl\/worksheets\/sheet\d+\.xml$/.test(n)).sort((a, b) => parseInt(a.match(/\d+/)[0], 10) - parseInt(b.match(/\d+/)[0], 10));
  if (!planilhas.length) throw new Error('Esse arquivo não tem nenhuma planilha.');
  const texto = async (nome) => (ent.has(nome) ? new TextDecoder('utf-8').decode(await ccLerEntrada(buf, ent.get(nome))) : '');
  const strs = ccStringsCompartilhadas(await texto('xl/sharedStrings.xml'));
  return ccLinhasDaPlanilha(await texto(planilhas[0]), strs);
}

const ccSemAcento = (s) => String(s === undefined || s === null ? '' : s).normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ').trim().toLowerCase();

// Data do Excel (numero de dias, ou texto dd/mm/aaaa hh:mm:ss, ou ja em AAAA-MM-DD) para "AAAA-MM-DD HH:MM:SS" (horario local, sem fuso).
function ccDataTexto(v) {
  const t = String(v === undefined || v === null ? '' : v).trim();
  if (!t) return '';
  const dois = (n) => String(n).padStart(2, '0');
  if (/^\d+([.,]\d+)?$/.test(t)) {
    const n = parseFloat(t.replace(',', '.'));
    if (n < 30000 || n > 80000) return '';
    const d = new Date(Math.round((n - 25569) * 86400) * 1000);
    return `${d.getUTCFullYear()}-${dois(d.getUTCMonth() + 1)}-${dois(d.getUTCDate())} ${dois(d.getUTCHours())}:${dois(d.getUTCMinutes())}:${dois(d.getUTCSeconds())}`;
  }
  let m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?$/.exec(t);
  if (m) return `${m[3]}-${dois(m[2])}-${dois(m[1])} ${dois(m[4] || 0)}:${m[5] || '00'}:${m[6] || '00'}`;
  m = /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?/.exec(t);
  if (m) return `${m[1]}-${m[2]}-${m[3]} ${m[4] || '00'}:${m[5] || '00'}:${m[6] || '00'}`;
  return '';
}

// Acha o cabecalho do relatorio do TomTicket pelos NOMES das colunas (a posicao muda de um arquivo para outro: alguns
// trazem "Data de Criação", outros "Data de Finalização", outros os dois) e devolve os chamados.
function ccParseTomTicket(linhas) {
  const campos = { protocolo: 'protocolo', assunto: 'assunto', departamento: 'departamento', atendente: 'atendente', 'atendente finalizador': 'finalizador',
    cliente: 'cliente', 'data de criacao': 'criado', 'data de finalizacao': 'finalizado' };
  let h = -1; let mapa = {};
  for (let i = 0; i < Math.min(linhas.length, 25) && h < 0; i++) {
    const m = {};
    for (const [col, valor] of Object.entries(linhas[i])) {
      const nome = ccSemAcento(valor);
      if (campos[nome]) m[campos[nome]] = col;
      else if (nome.startsWith('categoria')) m.categoria = col;
    }
    if (m.protocolo && m.assunto) { h = i; mapa = m; }
  }
  if (h < 0) return { erro: 'Não achei o cabeçalho do relatório do TomTicket (colunas Protocolo e Assunto).', linhas: [] };
  const get = (l, k) => (mapa[k] ? String(l[mapa[k]] === undefined ? '' : l[mapa[k]]).trim() : '');
  const out = []; let ignoradas = 0;
  for (const l of linhas.slice(h + 1)) {
    const p = get(l, 'protocolo');
    if (!/^\d+$/.test(p)) { if (Object.keys(l).length) ignoradas++; continue; }
    out.push({ protocolo: Number(p), assunto: get(l, 'assunto'), departamento: get(l, 'departamento'), atendente: get(l, 'atendente'), finalizador: get(l, 'finalizador'),
      cliente: get(l, 'cliente'), categoria: get(l, 'categoria'), criado: ccDataTexto(get(l, 'criado')), finalizado: ccDataTexto(get(l, 'finalizado')) });
  }
  return { linhas: out, ignoradas, colunas: { criacao: !!mapa.criado, finalizacao: !!mapa.finalizado, categoria: !!mapa.categoria } };
}
