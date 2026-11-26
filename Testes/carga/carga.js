'use strict';
// Teste de carga: simula a frota (padrao 430 maquinas) falando com o servidor PHP, enquanto um painel le os indicadores.
// Nao faz parte do "node --test": e uma medicao, rode quando quiser:
//   node Testes/carga/carga.js [--maquinas 430] [--rodadas 4] [--janela 40] [--leitores 1]
// Cada rodada equivale a 5 minutos reais de cada PC: 1 registro de presenca + 1 lote de programas em foco (40 itens)
// + 1 lote de navegacao (25 visitas). "janela" e em quantos segundos os PCs de uma rodada chegam (jitter): 40 s e MUITO mais
// apertado que o mundo real (5 min), entao os numeros abaixo sao pessimistas.
// Limite honesto: o servidor embutido do PHP atende uma requisicao por vez. Apache com varios processos le em paralelo, mas
// o SQLite so tem um escritor por vez, entao para gravacao o resultado e parecido; para leitura do painel e conservador.
const { spawn, spawnSync } = require('node:child_process');
const net = require('node:net');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const arg = (n, p) => { const i = process.argv.indexOf('--' + n); return i > 0 ? Number(process.argv[i + 1]) : p; };
const MAQ = arg('maquinas', 430), RODADAS = arg('rodadas', 4), JANELA = arg('janela', 40) * 1000, LEITORES = arg('leitores', 1);
const RAIZ = path.join(__dirname, '..', '..');
const WEB = path.join(RAIZ, 'Servidor', 'fonte');
const TOKEN = 'token-de-carga-1234567890', SENHA = 'senha-de-carga-12345';
const q = (s) => s.replace(/\\/g, '/');

function flagsPhp() {
  const bin = spawnSync('php', ['-r', 'echo PHP_BINARY;']).stdout.toString();
  const ext = path.join(path.dirname(bin), 'ext'); const f = [];
  if (fs.existsSync(path.join(ext, 'php_pdo_sqlite.dll'))) f.push('-d', `extension_dir=${ext}`, '-d', 'extension=pdo_sqlite', '-d', 'extension=sqlite3', '-d', 'extension=mbstring', '-d', 'extension=openssl');
  return f;
}
const porta = () => new Promise((r) => { const s = net.createServer().listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => r(p)); }); });
const pct = (a, p) => { if (!a.length) return 0; const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor(p * s.length))]; };
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'carga-'));
  const dados = path.join(tmp, 'dados');
  const cfg = path.join(tmp, 'config.php');
  fs.writeFileSync(cfg, `<?php return ['agent_token' => '${TOKEN}', 'painel_user' => 'admin', 'painel_pass' => '${SENHA}', 'dados_dir' => '${q(dados)}',
    'unidades_file' => '${q(path.join(RAIZ, 'Config', 'unidades.json'))}', 'exigir_2fa_admin' => false, 'backup_snapshot' => false];`);
  const p = await porta();
  const proc = spawn('php', [...flagsPhp(), '-S', `127.0.0.1:${p}`, '-t', WEB, path.join(WEB, 'index.php')], { env: { ...process.env, PRESENCA_CONFIG: cfg }, stdio: 'ignore' });
  const base = `http://127.0.0.1:${p}`;
  for (let i = 0; i < 60; i++) { try { if ((await fetch(base + '/health')).ok) break; } catch { /* subindo */ } await dormir(100); }

  const lat = { registro: [], foco: [], navegacao: [], painel: [] }; let erros = 0, total = 0; const codigos = {};
  const H = { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}` };
  async function chamar(tipo, caminho, corpo, headers = H, metodo = 'POST') {
    const t0 = performance.now();
    try {
      const r = await fetch(base + caminho, { method: metodo, headers, body: corpo ? JSON.stringify(corpo) : undefined });
      await r.arrayBuffer();
      lat[tipo].push(performance.now() - t0); total++;
      if (!r.ok) { erros++; codigos[r.status] = (codigos[r.status] || 0) + 1; }
    } catch (e) { erros++; total++; codigos[e.code || 'erro'] = (codigos[e.code || 'erro'] || 0) + 1; }
  }
  const procs = ['chrome.exe', 'WINWORD.EXE', 'EXCEL.EXE', 'Teams.exe', 'OUTLOOK.EXE', 'AcroRd32.exe', 'explorer.exe'];
  const sites = ['https://mail.google.com/', 'https://www.legale.com.br/', 'https://pje.trt2.jus.br/', 'https://www.youtube.com/', 'https://teams.microsoft.com/', 'https://docs.google.com/', 'https://www.uol.com.br/'];
  const resultados = ['Presencial', 'Presencial', 'Presencial', 'Presencial via VPN', 'Remoto'];

  async function rodadaMaquina(m, r) {
    await dormir(Math.random() * JANELA);
    const host = 'PC' + String(m).padStart(4, '0'), usuario = 'DOM\\user' + String(m).padStart(4, '0'), nome = 'Colaborador ' + m;
    const agora = Date.now();
    await chamar('registro', '/api/registros', { data_hora: new Date(agora - 20000).toISOString(), host, usuario, nome_completo: nome, resultado: resultados[m % 5], unidade: m % 2 ? 'MTZ' : 'FL1',
      vpn_ativa: 'nao', vpn_adaptador: '', confianca: 'alta', mac_confere: 'sim', motivo: 'ok', sessao_remota: 'nao', bloqueada: 'nao', ocioso_seg: 12, versao_agente: '1.5.0' });
    const foco = Array.from({ length: 40 }, (_, i) => ({ ts: agora - 290000 + i * 7000 + m, seg: 5 + (i * 3) % 60, proc: procs[(m + i) % procs.length], titulo: 'Documento ' + ((m + i) % 50) }));
    await chamar('foco', '/api/foco', { host, usuario, nome_completo: nome, itens: foco });
    const nav = Array.from({ length: 25 }, (_, i) => ({ ts: agora - 280000 + i * 9000 + m, url: sites[(m + i) % sites.length] + 'p' + ((m + i) % 30), titulo: 'Pagina ' + i, navegador: 'chrome', duracao_seg: 10 + (i * 7) % 120 }));
    await chamar('navegacao', '/api/navegacao', { host, usuario, nome_completo: nome, visitas: nav });
  }

  // painel lendo enquanto a frota grava
  let leitura = true;
  const login = await fetch(base + '/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ login: 'admin', senha: SENHA }) });
  const cookie = login.headers.getSetCookie().map((c) => c.split(';')[0]).join('; ');
  const eu = await (await fetch(base + '/api/eu', { headers: { Cookie: cookie } })).json();
  const HP = { Cookie: cookie, 'X-CSRF-Token': eu.csrf };
  const leitores = Array.from({ length: LEITORES }, async () => {
    const rotas = ['/api/estado', '/api/bi?preset=30', '/api/produtividade', '/api/resumo'];
    let i = 0;
    while (leitura) { await chamar('painel', rotas[i++ % rotas.length], null, HP, 'GET'); await dormir(2000); }
  });

  console.log(`Carga: ${MAQ} maquinas x ${RODADAS} rodadas (${MAQ * RODADAS * 3} requisicoes de agents), chegada em ${JANELA / 1000} s por rodada, ${LEITORES} leitor(es) do painel`);
  const t0 = Date.now();
  for (let r = 1; r <= RODADAS; r++) {
    const r0 = Date.now();
    await Promise.all(Array.from({ length: MAQ }, (_, m) => rodadaMaquina(m + 1, r)));
    const tam = fs.statSync(path.join(dados, 'presenca.sqlite')).size;
    console.log(`  rodada ${r}/${RODADAS}: ${((Date.now() - r0) / 1000).toFixed(1)} s, banco ${(tam / 1048576).toFixed(1)} MB, erros acumulados ${erros}`);
  }
  leitura = false; await Promise.all(leitores);
  const seg = (Date.now() - t0) / 1000;

  const wal = path.join(dados, 'presenca.sqlite-wal');
  const tamDb = fs.statSync(path.join(dados, 'presenca.sqlite')).size + (fs.existsSync(wal) ? fs.statSync(wal).size : 0);
  // snapshot (o painel gera sob demanda)
  await fetch(base + '/api/reautenticar', { method: 'POST', headers: { ...HP, 'Content-Type': 'application/json' }, body: JSON.stringify({ senha: SENHA }) });
  const t1 = Date.now();
  const sn = await (await fetch(base + '/api/backup/gerar', { method: 'POST', headers: { ...HP, 'Content-Type': 'application/json' }, body: '{}' })).json();
  const msSnap = Date.now() - t1;

  console.log('\nLatencia por tipo (ms)          n     p50    p95    p99    max');
  for (const [k, v] of Object.entries(lat)) console.log(`  ${k.padEnd(26)} ${String(v.length).padStart(5)} ${pct(v, .5).toFixed(0).padStart(6)} ${pct(v, .95).toFixed(0).padStart(6)} ${pct(v, .99).toFixed(0).padStart(6)} ${Math.max(0, ...v).toFixed(0).padStart(6)}`);
  const porRodada = tamDb / RODADAS;
  console.log(`\nRequisicoes: ${total} em ${seg.toFixed(0)} s (${(total / seg).toFixed(1)}/s). Erros: ${erros}${erros ? ' ' + JSON.stringify(codigos) : ''}`);
  console.log(`Banco: ${(tamDb / 1048576).toFixed(1)} MB para ${RODADAS} rodadas => ~${(porRodada / 1048576).toFixed(2)} MB por rodada de ${MAQ} PCs`);
  console.log(`Projecao (120 rodadas/dia de 10 h): ~${(porRodada * 120 / 1048576).toFixed(0)} MB/dia, ~${(porRodada * 120 * 30 / 1073741824).toFixed(1)} GB/mes de dados brutos (antes da retencao)`);
  console.log(`Snapshot: ${sn.ok ? 'ok' : 'FALHOU ' + sn.motivo}, ${(msSnap / 1000).toFixed(2)} s para copiar ${(tamDb / 1048576).toFixed(1)} MB (ninguem grava durante a copia)`);
  proc.kill();
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* arquivo em uso */ }
  process.exit(erros ? 1 : 0);
})();
