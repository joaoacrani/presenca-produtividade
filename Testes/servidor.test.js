'use strict';
// Testa o servidor PHP (Servidor\fonte\index.php) com o servidor embutido do PHP.
// Rodar:  node --test tests/
// Se o php nao estiver instalado, os testes sao pulados.
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const net = require('node:net');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const RAIZ = path.join(__dirname, '..');
const WEB = path.join(RAIZ, 'Servidor', 'fonte');
const TOKEN = 'token-de-teste-1234567890';
const AUTH_AGENTE = { Authorization: `Bearer ${TOKEN}` };
const SENHA = 'senha-forte-1';

const temPhp = spawnSync('php', ['-v']).status === 0;

function flagsPhp() {
  const bin = spawnSync('php', ['-r', 'echo PHP_BINARY;']).stdout.toString();
  const ext = path.join(path.dirname(bin), 'ext');
  const f = [];
  if (fs.existsSync(path.join(ext, 'php_pdo_sqlite.dll'))) f.push('-d', `extension_dir=${ext}`, '-d', 'extension=pdo_sqlite', '-d', 'extension=sqlite3', '-d', 'extension=mbstring');
  if (fs.existsSync(path.join(ext, 'php_openssl.dll'))) f.push('-d', `extension_dir=${ext}`, '-d', 'extension=openssl');
  return f;
}
function portaLivre() {
  return new Promise((res) => { const s = net.createServer().listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => res(p)); }); });
}
const q = (s) => s.replace(/\\/g, '/');

// opts.agora (ms) congela o relogio do servidor; opts.preparar(dadosDir) cria um banco antigo antes de subir
async function subir(opts = {}) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'presenca-php-'));
  const cfg = path.join(tmp, 'config.php');
  const dados = path.join(tmp, 'dados');
  if (opts.preparar) opts.preparar(dados);
  fs.writeFileSync(cfg, `<?php return [
    'agent_token' => '${TOKEN}', 'painel_user' => 'admin', 'painel_pass' => '${SENHA}',
    'dados_dir' => '${q(dados)}', 'unidades_file' => '${q(path.join(RAIZ, 'Config', 'unidades.json'))}',
    'online_min' => 45, 'retencao_dias' => 90, 'fuso' => 'America/Sao_Paulo',
    ${opts.agora ? `'agora_ms' => ${opts.agora},` : ''}
    ${opts.padrao2fa ? '' : "'exigir_2fa_admin' => false,"}
    ${opts.extra || ''}
];`);
  const porta = await portaLivre();
  const proc = spawn('php', [...flagsPhp(), '-S', `127.0.0.1:${porta}`, '-t', WEB, path.join(WEB, 'index.php')],
    { env: { ...process.env, PRESENCA_CONFIG: cfg }, stdio: 'ignore' });
  const base = `http://127.0.0.1:${porta}`;
  for (let i = 0; i < 50; i++) {
    try { if ((await fetch(base + '/health')).ok) break; } catch { /* ainda subindo */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  const req = (p, { metodo = 'GET', headers = {}, corpo, redirect = 'manual' } = {}) =>
    fetch(base + p, { method: metodo, redirect, headers: { 'Content-Type': 'application/json', ...headers }, body: corpo === undefined ? undefined : ((typeof corpo === 'string' || Buffer.isBuffer(corpo)) ? corpo : JSON.stringify(corpo)) });
  const s = { req, base, dados, fechar: () => { proc.kill(); try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* arquivo em uso no Windows */ } } };
  // sessao: devolve helpers que ja mandam cookie e csrf
  s.entrar = async (login = 'admin', senha = SENHA, semReauth = false) => {
    const r = await req('/api/login', { metodo: 'POST', corpo: { login, senha } });
    if (r.status !== 200) throw new Error('login falhou: ' + r.status);
    const cookie = r.headers.getSetCookie().map((c) => c.split(';')[0]).join('; ');
    const eu = await (await req('/api/eu', { headers: { Cookie: cookie } })).json();
    const h = { Cookie: cookie, 'X-CSRF-Token': eu.csrf };
    // acoes sensiveis exigem reconfirmar a senha; os testes ja entram reconfirmados (exceto com semReauth)
    if (!semReauth && !eu.totp_ativo) await req('/api/reautenticar', { metodo: 'POST', headers: h, corpo: { senha } });
    return {
      eu, cookie,
      get: (p) => req(p, { headers: h }),
      json: async (p) => (await req(p, { headers: h })).json(),
      enviar: (p, metodo, corpo) => req(p, { metodo, headers: h, corpo }),
    };
  };
  return s;
}

const iso = (msAtras) => new Date(Date.now() - msAtras).toISOString();
const reg = (o = {}) => ({
  data_hora: iso(10 * 60000), host: 'MTZ1546', usuario: 'DOM\\ana', resultado: 'Presencial', unidade: 'MTZ',
  vpn_ativa: 'nao', vpn_adaptador: '', confianca: 'alta', mac_confere: 'sim', motivo: 'ok',
  sessao_remota: 'nao', bloqueada: 'nao', ocioso_seg: 12, ...o,
});
const post = (s, o, headers = AUTH_AGENTE) => s.req('/api/registros', { metodo: 'POST', headers, corpo: reg(o) });
// fetch().text() descarta o BOM: le os bytes para conferir que o CSV abre certo no Excel
async function csv(r) {
  assert.equal(r.status, 200);
  const b = Buffer.from(await r.arrayBuffer());
  assert.deepEqual([...b.subarray(0, 3)], [0xEF, 0xBB, 0xBF], 'CSV sem BOM UTF-8');
  return b.subarray(3).toString('utf8');
}
const opt = { skip: !temPhp && 'php nao instalado' };

// ---------- infraestrutura e agent ----------

test('PHP: /health sem login informa sqlite e configuracao', opt, async () => {
  const s = await subir();
  try {
    const j = await (await s.req('/health')).json();
    assert.equal(j.ok, true); assert.equal(j.sqlite, true);
    assert.equal(j.configurado, undefined); assert.equal(j.openssl, undefined); assert.equal(j.auth_header, undefined); // publico: so o minimo
    const d = await (await s.req('/health', { headers: AUTH_AGENTE })).json();
    assert.equal(d.auth_header, true); assert.equal(d.configurado, true); assert.equal(d.openssl, true);
  } finally { s.fechar(); }
});

test('PHP: POST /api/registros exige token do agent e valida entradas', opt, async () => {
  const s = await subir();
  try {
    assert.equal((await post(s, {}, {})).status, 401);
    assert.equal((await post(s, {}, { Authorization: 'Bearer errado' })).status, 401);
    const fixo = { data_hora: iso(10 * 60000) };
    const ok = await post(s, fixo);
    assert.deepEqual(await ok.json(), { ok: true, duplicado: false });
    assert.deepEqual(await (await post(s, fixo)).json(), { ok: true, duplicado: true });
    assert.equal((await s.req('/api/registros', { metodo: 'POST', headers: AUTH_AGENTE, corpo: '{nao e json' })).status, 400);
    assert.equal((await post(s, { host: '' })).status, 400);
    assert.equal((await post(s, { resultado: 'Outro' })).status, 400);
    assert.equal((await post(s, { data_hora: 'ontem' })).status, 400);
    assert.equal((await post(s, { data_hora: '2099-01-01T00:00:00-03:00' })).status, 400);
    assert.equal((await s.req('/api/registros', { metodo: 'POST', headers: AUTH_AGENTE, corpo: '[]' })).status, 400);
    assert.equal((await post(s, { motivo: 'a'.repeat(40000) })).status, 413);
  } finally { s.fechar(); }
});

test('PHP: /api/config/unidades entrega o unidades.json so com token', opt, async () => {
  const s = await subir();
  try {
    assert.equal((await s.req('/api/config/unidades')).status, 401);
    const cfg = await (await s.req('/api/config/unidades', { headers: AUTH_AGENTE })).json();
    assert.ok(Array.isArray(cfg.unidades) && cfg.unidades.length > 0);
  } finally { s.fechar(); }
});

// ---------- login ----------

test('PHP login: sem sessao so a pagina de login, com sessao o painel', opt, async () => {
  const s = await subir();
  try {
    assert.equal((await s.req('/api/estado')).status, 401);
    assert.equal((await s.req('/api/produtividade')).status, 401);
    const r = await s.req('/');
    assert.equal(r.status, 302); assert.match(r.headers.get('location'), /\/login$/);
    const l = await s.req('/login');
    assert.equal(l.status, 200); assert.match(await l.text(), /<form/);
    assert.equal((await s.req('/login.js')).status, 200);
    const logo = await s.req('/logo.png'); // o logo aparece na tela de login, antes de entrar
    assert.equal(logo.status, 200); assert.equal(logo.headers.get('content-type'), 'image/png');
    assert.equal((await s.req('/logo-claro.png')).status, 200);
    assert.match(await (await s.req('/login')).text(), /Produtividade/);
    assert.equal((await s.req('/app.js')).status, 404); // js do painel nao e servido sem sessao
    assert.equal((await s.req('/api/estado', { headers: AUTH_AGENTE })).status, 401); // token do agent nao abre o painel
    const a = await s.entrar();
    assert.equal(a.eu.login, 'admin'); assert.equal(a.eu.papel, 'admin');
    assert.equal((await a.get('/api/estado')).status, 200);
    for (const p of ['/', '/app.js']) { const x = await a.get(p); assert.equal(x.status, 200); await x.text(); } // le o corpo (servidor de teste: 1 requisicao por vez)
    assert.equal((await s.req('/qrcode.js')).status, 404);     // biblioteca do QR so depois do login
    const qrjs = await a.get('/qrcode.js');
    assert.equal(qrjs.status, 200); assert.match(await qrjs.text(), /qrcode-generator/); // le o corpo: o servidor de teste atende uma requisicao por vez
    assert.equal((await s.req('/login', { headers: { Cookie: a.cookie } })).status, 302); // ja logado
  } finally { s.fechar(); }
});

test('PHP login: cookie HttpOnly + SameSite, senha errada, bloqueio apos 5 erros', opt, async () => {
  const s = await subir();
  try {
    const ok = await s.req('/api/login', { metodo: 'POST', corpo: { login: 'admin', senha: SENHA } });
    const c = ok.headers.getSetCookie().join(' ');
    assert.match(c, /HttpOnly/i); assert.match(c, /SameSite=Strict/i);
    assert.equal((await s.req('/api/login', { metodo: 'POST', corpo: { login: 'admin', senha: 'x' } })).status, 401);
    assert.equal((await s.req('/api/login', { metodo: 'POST', corpo: { login: 'ninguem', senha: 'x' } })).status, 401);
    assert.equal((await s.req('/api/login', { metodo: 'POST', headers: { 'Content-Type': 'text/plain' }, corpo: '{}' })).status, 415);
    for (let i = 0; i < 4; i++) await s.req('/api/login', { metodo: 'POST', corpo: { login: 'admin', senha: 'errada' } });
    const bloq = await s.req('/api/login', { metodo: 'POST', corpo: { login: 'admin', senha: SENHA } });
    assert.equal(bloq.status, 429); // mesmo com a senha certa, fica bloqueado
  } finally { s.fechar(); }
});

test('PHP login: escrita exige token CSRF; logout encerra a sessao', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    const semCsrf = await s.req('/api/regras', { metodo: 'POST', headers: { Cookie: a.cookie }, corpo: { padrao: 'x.com', categoria: 'neutro' } });
    assert.equal(semCsrf.status, 403);
    assert.equal((await a.enviar('/api/regras', 'POST', { padrao: 'x.com', categoria: 'neutro' })).status, 200);
    assert.equal((await a.enviar('/api/logout', 'POST', {})).status, 200);
    assert.equal((await a.get('/api/estado')).status, 401);
  } finally { s.fechar(); }
});

test('PHP login: trocar a propria senha', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    assert.equal((await a.enviar('/api/senha', 'POST', { atual: 'errada', nova: 'nova-senha-123' })).status, 400);
    assert.equal((await a.enviar('/api/senha', 'POST', { atual: SENHA, nova: 'curta' })).status, 400);
    assert.equal((await a.enviar('/api/senha', 'POST', { atual: SENHA, nova: 'nova-senha-123' })).status, 200);
    assert.equal((await s.req('/api/login', { metodo: 'POST', corpo: { login: 'admin', senha: SENHA } })).status, 401);
    await s.entrar('admin', 'nova-senha-123');
  } finally { s.fechar(); }
});

test('PHP usuarios: admin cria gestor; gestor le relatorios mas nao administra', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    assert.equal((await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'Gestora', senha: 'abc12345-xyz', papel: 'gestor' })).status, 200);
    assert.equal((await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', senha: 'abc12345-xyz' })).status, 409);
    assert.equal((await a.enviar('/api/usuarios', 'POST', { login: 'x', senha: 'abc12345-xyz' })).status, 400);
    const g = await s.entrar('gestor1', 'abc12345-xyz');
    assert.equal((await g.get('/api/produtividade')).status, 200);
    assert.equal((await g.get('/api/usuarios')).status, 403);
    assert.equal((await g.enviar('/api/regras', 'POST', { padrao: 'x.com', categoria: 'produtivo' })).status, 403);
    assert.equal((await g.get('/api/export/navegacao.csv')).status, 403);
    assert.equal((await g.get('/api/export/produtividade.csv')).status, 200);
    // admin nao pode se rebaixar; desativar o gestor derruba a sessao dele
    const lista = (await a.json('/api/usuarios')).itens;
    const eu = lista.find((u) => u.login === 'admin'), ges = lista.find((u) => u.login === 'gestor1');
    assert.equal((await a.enviar('/api/usuarios', 'PUT', { id: eu.id, papel: 'gestor' })).status, 400);
    assert.equal((await a.enviar('/api/usuarios', 'PUT', { id: ges.id, ativo: false })).status, 200);
    assert.equal((await g.get('/api/estado')).status, 401);
  } finally { s.fechar(); }
});

// ---------- presenca ----------

test('PHP: /api/estado mostra "Nome Completo - login" e respeita o nome manual', opt, async () => {
  const s = await subir();
  try {
    await post(s, { host: 'A', usuario: 'CORP\\msouza', nome_completo: 'Maria Souza' });
    await post(s, { host: 'B', usuario: 'CORP\\semnome' });
    const a = await s.entrar();
    let est = (await a.json('/api/estado')).itens;
    assert.equal(est.find((i) => i.host === 'A').colaborador, 'Maria Souza - msouza');
    assert.equal(est.find((i) => i.host === 'B').colaborador, 'semnome');
    assert.equal(est.find((i) => i.host === 'A').usuario, 'CORP\\msouza');
    // correcao manual vale mesmo que o agent mande outro nome depois
    assert.equal((await a.enviar('/api/colaboradores', 'PUT', { login: 'msouza', nome: 'Maria S.' })).status, 200);
    await post(s, { host: 'A', usuario: 'CORP\\msouza', nome_completo: 'Outro Nome', data_hora: iso(2 * 60000) });
    est = (await a.json('/api/estado')).itens;
    assert.equal(est.find((i) => i.host === 'A').colaborador, 'Maria S. - msouza');
  } finally { s.fechar(); }
});

test('PHP: estado, historico e resumo continuam funcionando', opt, async () => {
  const s = await subir();
  try {
    await post(s, { host: 'A', data_hora: iso(120 * 60000), resultado: 'Presencial' });
    await post(s, { host: 'A', data_hora: iso(5 * 60000), resultado: 'Remoto via VPN', unidade: '' });
    await post(s, { host: 'B', data_hora: iso(180 * 60000), resultado: 'Remoto', unidade: '', ocioso_seg: null });
    await post(s, { host: 'C', resultado: 'Presencial', vpn_ativa: 'sim' }); // agent antigo
    const a = await s.entrar();
    const est = (await a.json('/api/estado')).itens;
    const A = est.find((i) => i.host === 'A'), B = est.find((i) => i.host === 'B'), C = est.find((i) => i.host === 'C');
    assert.equal(A.resultado, 'Remoto via VPN'); assert.equal(A.ativo, true); assert.equal(A.idade_min, 5);
    assert.equal(B.ativo, false); assert.equal(B.ocioso_seg, null);
    assert.equal(C.resultado, 'Presencial via VPN');
    const h = await a.json('/api/historico?host=A&horas=24');
    assert.equal(h.itens.length, 2); assert.ok(h.itens[0].ts > h.itens[1].ts);
    assert.equal((await a.get('/api/historico')).status, 400);
    const r = await a.json('/api/resumo?dias=7');
    assert.equal(r.itens.reduce((n, d) => n + d.total, 0), 3);
  } finally { s.fechar(); }
});

test('PHP: texto com acento e emoji passa e volta intacto', opt, async () => {
  const s = await subir();
  try {
    await post(s, { usuario: 'DOM\\José Açaí 😀', motivo: 'Rede física de São Paulo' });
    const est = (await (await s.entrar()).json('/api/estado')).itens;
    assert.equal(est[0].usuario, 'DOM\\José Açaí 😀');
    assert.equal(est[0].motivo, 'Rede física de São Paulo');
  } finally { s.fechar(); }
});

test('PHP: serve o painel, bloqueia caminhos internos e traversal', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    assert.match(await (await a.get('/')).text(), /Presen/);
    for (const p of ['/_app/config.php', '/_app/dados/presenca.sqlite', '/..%2Findex.php', '/..%2F..%2Funidades.json', '/_app/public/app.js', '/.htaccess', '/unidades.json', '/_app/lib/db.php']) {
      assert.equal((await a.get(p)).status, 404, p);
    }
  } finally { s.fechar(); }
});

// ---------- navegacao e produtividade ----------

const visita = (url, minAtras, extra = {}) => ({ ts: Date.now() - minAtras * 60000, url, titulo: 'T', navegador: 'Chrome', duracao_seg: 60, ...extra });
const nav = (s, visitas, o = {}, headers = AUTH_AGENTE) =>
  s.req('/api/navegacao', { metodo: 'POST', headers, corpo: { host: 'MTZ1546', usuario: 'CORP\\ana', nome_completo: 'Ana Souza', visitas, ...o } });

test('PHP navegacao: exige token, remove consulta da URL, ignora esquemas estranhos e duplicados', opt, async () => {
  const s = await subir();
  try {
    assert.equal((await nav(s, [], {}, {})).status, 401);
    assert.equal((await s.req('/api/navegacao', { metodo: 'POST', headers: AUTH_AGENTE, corpo: '{ruim' })).status, 400);
    assert.equal((await s.req('/api/navegacao', { metodo: 'POST', headers: AUTH_AGENTE, corpo: { host: 'X' } })).status, 400);
    const v = [
      visita('https://www.YouTube.com/watch?v=abc&token=SEGREDO#t=1', 5),
      visita('file:///C:/segredo.txt', 4), visita('chrome://settings', 3), visita('javascript:alert(1)', 2),
      visita('https://example.com/painel', 1),
    ];
    const r = await (await nav(s, v)).json();
    assert.equal(r.recebidas, 5); assert.equal(r.gravadas, 2);
    assert.equal((await (await nav(s, v)).json()).gravadas, 0); // reenvio nao duplica
    const a = await s.entrar();
    const det = await a.json('/api/colaborador?login=ana');
    assert.equal(det.visitas.length, 2);
    const yt = det.visitas.find((x) => x.dominio === 'youtube.com');
    assert.equal(yt.url, 'https://www.youtube.com/watch'); // sem ?v=..&token=.. e sem #
    assert.equal(det.colaborador.colaborador, 'Ana Souza - ana');
    assert.equal((await s.req('/api/navegacao', { metodo: 'POST', headers: AUTH_AGENTE, corpo: { host: 'X', visitas: new Array(501).fill({}) } })).status, 400);
  } finally { s.fechar(); }
});

test('PHP produtividade: classifica por regra, % produtivo e reclassificacao retroativa', opt, async () => {
  const s = await subir();
  try {
    await nav(s, [
      visita('https://pje.trt15.jus.br/x', 50, { duracao_seg: 600 }),   // produtivo (jus.br)
      visita('https://m.youtube.com/watch', 40, { duracao_seg: 200 }),  // improdutivo (subdominio)
      visita('https://site-novo-qualquer.com/a', 30, { duracao_seg: 100 }), // sem regra -> neutro
    ]);
    const a = await s.entrar();
    let r = await a.json('/api/produtividade');
    assert.equal(r.colaboradores.length, 1);
    const c = r.colaboradores[0];
    assert.equal(c.colaborador, 'Ana Souza - ana');
    assert.equal(c.segundos.produtivo, 600); assert.equal(c.segundos.improdutivo, 200); assert.equal(c.segundos.neutro, 100);
    assert.equal(c.pct_produtivo, 75);
    assert.deepEqual(r.sem_regra.map((x) => x.dominio), ['site-novo-qualquer.com']);
    assert.equal((await (await a.json('/api/dominios-sem-regra')).itens)[0].dominio, 'site-novo-qualquer.com');
    // o admin classifica o dominio novo como improdutivo: relatorio muda para o historico inteiro
    assert.equal((await a.enviar('/api/regras', 'POST', { padrao: 'https://www.Site-Novo-Qualquer.com/a', categoria: 'improdutivo' })).status, 200);
    r = await a.json('/api/produtividade');
    assert.equal(r.colaboradores[0].segundos.improdutivo, 300);
    assert.equal(r.colaboradores[0].pct_produtivo, 66.7);
    assert.equal(r.sem_regra.length, 0);
    assert.equal((await a.enviar('/api/regras', 'POST', { padrao: 'nao e dominio', categoria: 'produtivo' })).status, 400);
    assert.equal((await a.enviar('/api/regras', 'POST', { padrao: 'a.com', categoria: 'qualquer' })).status, 400);
    const id = (await a.json('/api/regras')).itens.find((x) => x.padrao === 'site-novo-qualquer.com').id;
    assert.equal((await a.enviar(`/api/regras?id=${id}`, 'DELETE')).status, 200);
    assert.equal((await a.json('/api/produtividade')).colaboradores[0].segundos.improdutivo, 200);
  } finally { s.fechar(); }
});

test('PHP produtividade: a regra mais especifica (subdominio) vence a do dominio', opt, async () => {
  const s = await subir();
  try {
    await nav(s, [visita('https://drive.google.com/a', 20, { duracao_seg: 100 }), visita('https://www.google.com/search', 10, { duracao_seg: 100 })]);
    const a = await s.entrar();
    const c = (await a.json('/api/produtividade')).colaboradores[0];
    assert.equal(c.segundos.produtivo, 100); // drive.google.com = produtivo
    assert.equal(c.segundos.neutro, 100);    // google.com = neutro
  } finally { s.fechar(); }
});

// ---------- localizacao por dia (relogio congelado em sex 06/03/2026 12:00, Sao Paulo) ----------

const AGORA = Date.parse('2026-03-06T15:00:00Z');
const leitura = (dia, hora, o = {}) => reg({ data_hora: `${dia}T${hora}:00-03:00`, host: 'NOTE-ANA', usuario: 'CORP\\ana', nome_completo: 'Ana Souza', ...o });
async function enviarLeituras(s, lista) {
  for (const l of lista) assert.equal((await s.req('/api/registros', { metodo: 'POST', headers: AUTH_AGENTE, corpo: l })).status, 200);
}

const loc = async (a, login, de = '2026-03-02', ate = '2026-03-06') => (await a.json(`/api/colaborador?login=${login}&de=${de}&ate=${ate}`)).presenca;

test('PHP localizacao: dia presencial, remoto (home, dia curto) e sem registro', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    const rem = { resultado: 'Remoto', unidade: '' };
    await enviarLeituras(s, [
      ...['09:00', '09:05', '09:10', '09:15'].map((h) => leitura('2026-03-02', h)),            // seg: presencial MTZ
      ...['09:00','09:05','09:10','09:15','09:20','09:25','09:30','09:35','09:40','09:45','09:50','09:55'].map((h) => leitura('2026-03-03', h, rem)), // ter: home (12 leituras = dia completo)
      ...['09:00', '09:05'].map((h) => leitura('2026-03-04', h)),                              // qua: so 2 leituras presenciais (< minimo): dia Parcial, nao Remoto
      ...['09:00', '09:05', '09:10'].map((h) => leitura('2026-03-05', h, { resultado: 'Presencial via VPN', vpn_ativa: 'sim' })), // qui: presencial via VPN conta
      // sex 06/03: sem registro
      ...['09:00', '09:05', '09:10', '09:15', '09:20', '09:25'].map((h) => leitura('2026-03-07', h)), // sabado: nao e dia util
    ]);
    const a = await s.entrar();
    const c = await loc(a, 'ana');
    assert.equal(c.dias_uteis, 5);          // 02..06/03
    assert.equal(c.presenciais, 2);         // seg + qui
    assert.equal(c.remotos, 1);             // ter
    assert.equal(c.parciais, 1);            // qua (poucas leituras)
    assert.equal(c.sem_registro, 1);        // sex
    assert.equal(c.por_unidade.MTZ, 2);
    assert.deepEqual(c.detalhe.map((d) => d.status), ['Presencial', 'Remoto', 'Parcial', 'Presencial', 'Sem registro']);
    const texto = await csv(await a.get('/api/export/presenca.csv?de=2026-03-02&ate=2026-03-06'));
    assert.match(texto, /Ana Souza - ana;ana;2026-03-02;Presencial;MTZ;4;4/);
    assert.match(texto, /Ana Souza - ana;ana;2026-03-03;Remoto;;0;12/);
    assert.equal((await a.get('/api/vale-transporte')).status, 404); // recurso removido
  } finally { s.fechar(); }
});
test('PHP localizacao: dias antes do primeiro registro do colaborador nao contam como "sem registro"', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    await enviarLeituras(s, ['09:00', '09:05', '09:10'].map((h) => leitura('2026-03-05', h))); // so a partir de quinta
    const a = await s.entrar();
    const c = await loc(a, 'ana'); // periodo 02..06/03
    assert.equal(c.dias_uteis, 2);       // qui e sex; seg a qua sao anteriores ao monitoramento
    assert.equal(c.presenciais, 1);
    assert.equal(c.sem_registro, 1);     // sexta
    const bi = await a.json('/api/bi?de=2026-03-02&ate=2026-03-06');
    assert.equal(bi.kpis.dias_sem_registro, 1);
  } finally { s.fechar(); }
});
test('PHP localizacao: o resumo diario sobrevive a limpeza dos registros brutos', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    await enviarLeituras(s, ['09:00', '09:05', '09:10'].map((h) => leitura('2026-03-02', h)));
    const a = await s.entrar();
    const antes = (await loc(a, 'ana')).presenciais;
    // apaga os registros brutos: o resumo diario (presenca_dia) continua
    const phpSrc = `$d=new PDO('sqlite:${q(path.join(s.dados, 'presenca.sqlite'))}'); $d->exec('DELETE FROM registros');`;
    const rr = spawnSync('php', [...flagsPhp(), '-r', phpSrc]);
    assert.equal(rr.status, 0, String(rr.stderr));
    assert.equal((await loc(a, 'ana')).presenciais, antes);
    assert.equal(antes, 1);
  } finally { s.fechar(); }
});

test('PHP migracao: banco antigo (sem login/nome) e preenchido sozinho', opt, async () => {
  const s = await subir({
    agora: AGORA,
    preparar: (dados) => {
      fs.mkdirSync(dados, { recursive: true });
      const ts = Date.parse('2026-03-02T12:00:00Z');
      const src = `$d=new PDO('sqlite:${q(path.join(dados, 'presenca.sqlite'))}');
        $d->exec("CREATE TABLE registros (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, data_hora TEXT NOT NULL, recebido_em INTEGER NOT NULL, host TEXT NOT NULL, usuario TEXT, resultado TEXT NOT NULL, unidade TEXT, vpn_ativa TEXT, vpn_adaptador TEXT, confianca TEXT, mac_confere TEXT, motivo TEXT, sessao_remota TEXT, bloqueada TEXT, ocioso_seg INTEGER, UNIQUE (host, ts))");
        for ($i=0;$i<3;$i++) $d->exec("INSERT INTO registros (ts,data_hora,recebido_em,host,usuario,resultado,unidade) VALUES (" . (${ts} + $i*300000) . ",'x',1,'PC-VELHO','OLD\\\\Carlos','Presencial','FL1')");`;
      const r = spawnSync('php', [...flagsPhp(), '-r', src]);
      assert.equal(r.status, 0, String(r.stderr));
    },
  });
  try {
    const a = await s.entrar();
    const est = (await a.json('/api/estado')).itens;
    assert.equal(est.length, 1);
    assert.equal(est[0].login, 'carlos'); assert.equal(est[0].colaborador, 'carlos');
    const c = await loc(a, 'carlos');
    assert.equal(c.presenciais, 1); assert.equal(c.por_unidade.FL1, 1);
  } finally { s.fechar(); }
});

test('PHP migracao: banco ja na versao anterior (9) ganha a tabela do acesso remoto e o inventario continua abrindo', opt, async () => {
  const s = await subir({
    preparar: (dados) => {
      fs.mkdirSync(dados, { recursive: true });
      const src = `$d=new PDO('sqlite:${q(path.join(dados, 'presenca.sqlite'))}'); $d->exec("PRAGMA user_version = 9");`;
      const r = spawnSync('php', [...flagsPhp(), '-r', src]);
      assert.equal(r.status, 0, String(r.stderr));
    },
  });
  try {
    const a = await s.entrar();
    const r = await a.get('/api/inventario');
    assert.equal(r.status, 200, 'inventario nao pode dar erro interno em banco antigo');
    assert.equal((await a.get('/api/remoto/config')).status, 200);
  } finally { s.fechar(); }
});

// ---------- escala (430 maquinas) ----------

function phpEscala(codigo) {
  const r = spawnSync('php', [...flagsPhp(), '-r', codigo], { encoding: 'utf8' });
  assert.equal(r.status, 0, String(r.stderr) + String(r.stdout));
  return r.stdout.trim();
}
const PHP_ESCALA_BASE = (dir, extra = '') => `
  foreach (['util','classificacao','db','totp','auth','relatorios','resumos','inventario','remoto','sugestoes'] as $m) require_once '${q(path.join(WEB, '_app', 'lib'))}/' . $m . '.php';
  $cfg = ['dados_dir' => '${q(dir)}', 'fuso' => 'America/Sao_Paulo', 'agora_ms' => null, 'retencao_dias' => 90, 'retencao_nav_dias' => 30,
          'retencao_foco_dias' => 60, 'retencao_agregados_dias' => 400, 'retencao_auditoria_dias' => 365, 'painel_user' => 'admin', 'painel_pass' => 'senha-forte-1' ${extra}];
`;

test('escala: o banco usa WAL, tem os indices de data e da para desligar o WAL pelo config', opt, () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'escala-'));
  const a = phpEscala(PHP_ESCALA_BASE(path.join(tmp, 'a')) + `
    $db = abrirBanco($cfg);
    $idx = $db->query("SELECT name FROM sqlite_master WHERE type='index'")->fetchAll(PDO::FETCH_COLUMN);
    echo modoDiario($db), '|', (int)$db->query('PRAGMA user_version')->fetchColumn(), '|', in_array('idx_nav_ts', $idx) ? 'nav' : '-', '|', in_array('idx_foco_ts', $idx) ? 'foco' : '-';`);
  assert.equal(a, 'wal|20|nav|foco');
  const b = phpEscala(PHP_ESCALA_BASE(path.join(tmp, 'b'), ", 'sqlite_wal' => false") + `$db = abrirBanco($cfg); echo modoDiario($db);`);
  assert.equal(b, 'delete');
});

test('escala: a limpeza apaga so o que venceu, em lotes, e a consulta usa o indice de data', opt, () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'escala-'));
  const r = phpEscala(PHP_ESCALA_BASE(path.join(tmp, 'd')) + `
    $db = abrirBanco($cfg);
    $agora = 1800000000000; $dia = 86400000;
    $db->beginTransaction();
    $f = $db->prepare('INSERT INTO foco (ts,host,login,processo,titulo,seg) VALUES (?,?,?,?,?,?)');
    for ($i = 0; $i < 12000; $i++) $f->execute([$agora - 70 * $dia + $i, 'H', 'ana', 'p' . $i, '', 5]);
    for ($i = 0; $i < 5; $i++) $f->execute([$agora - 1 * $dia + $i, 'H', 'ana', 'novo' . $i, '', 5]);
    $n = $db->prepare('INSERT INTO navegacao (ts,host,login,dominio,url,titulo,navegador,duracao_seg) VALUES (?,?,?,?,?,?,?,?)');
    for ($i = 0; $i < 7000; $i++) $n->execute([$agora - 40 * $dia + $i, 'H', 'ana', 'a.com', 'https://a.com/' . $i, '', 'c', 1]);
    $n->execute([$agora - $dia, 'H', 'ana', 'a.com', 'https://a.com/novo', '', 'c', 1]);
    $db->exec("INSERT INTO nav_dia VALUES ('ana','2020-01-01','a.com',1,1), ('ana','2026-12-01','a.com',1,1)");
    $db->commit();
    $plano = $db->query('EXPLAIN QUERY PLAN SELECT id FROM foco WHERE ts < 1')->fetchAll(PDO::FETCH_COLUMN, 3)[0];
    $ok = limparAntigos($db, $cfg, $agora);
    $c = fn($t) => (int)$db->query("SELECT COUNT(*) FROM $t")->fetchColumn();
    echo json_encode(['ok' => $ok, 'foco' => $c('foco'), 'nav' => $c('navegacao'), 'nav_dia' => $c('nav_dia'), 'indice' => strpos($plano, 'idx_foco_ts') !== false]);`);
  assert.deepEqual(JSON.parse(r), { ok: true, foco: 5, nav: 1, nav_dia: 1, indice: true });
});

test('escala: sem tempo a limpeza para entre lotes e termina na chamada seguinte', opt, () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'escala-'));
  const r = phpEscala(PHP_ESCALA_BASE(path.join(tmp, 'l')) + `
    $db = abrirBanco($cfg);
    $agora = 1800000000000; $dia = 86400000;
    $db->beginTransaction();
    $f = $db->prepare('INSERT INTO foco (ts,host,login,processo,titulo,seg) VALUES (?,?,?,?,?,?)');
    for ($i = 0; $i < 12000; $i++) $f->execute([$agora - 70 * $dia + $i, 'H', 'ana', 'p' . $i, '', 5]);
    $db->commit();
    $c = fn() => (int)$db->query('SELECT COUNT(*) FROM foco')->fetchColumn();
    $a = limparAntigos($db, $cfg, $agora, -1);   // tempo ja esgotado: apaga 1 lote e para
    $depoisA = $c();
    $b = limparAntigos($db, $cfg, $agora, 30);
    echo json_encode(['a' => $a, 'depoisA' => $depoisA, 'b' => $b, 'depoisB' => $c()]);`);
  assert.deepEqual(JSON.parse(r), { a: false, depoisA: 7000, b: true, depoisB: 0 });
});

test('escala: a limpeza roda no maximo 1 vez por dia e continua no dia seguinte', opt, () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'escala-'));
  const r = phpEscala(PHP_ESCALA_BASE(path.join(tmp, 'u')) + `
    $db = abrirBanco($cfg);
    $agora = 1800000000000; $dia = 86400000;
    $ins = function ($ts) use ($db) { $db->prepare('INSERT INTO foco (ts,host,login,processo,titulo,seg) VALUES (?,?,?,?,?,?)')->execute([$ts, 'H', 'ana', 'p' . $ts, '', 5]); };
    $c = fn() => (int)$db->query('SELECT COUNT(*) FROM foco')->fetchColumn();
    $ins($agora - 70 * $dia);
    limparAntigosSeDevido($db, $cfg, $agora);               // 1a vez: limpa
    $r1 = $c();
    $ins($agora - 70 * $dia + 1);
    limparAntigosSeDevido($db, $cfg, $agora + 3600000);     // 1 h depois: nao roda
    $r2 = $c();
    limparAntigosSeDevido($db, $cfg, $agora + 21 * 3600000); // 21 h depois: roda
    echo json_encode([$r1, $r2, $c()]);`);
  assert.deepEqual(JSON.parse(r), [0, 1, 0]);
});

test('escala: o envio dos agents dispara a limpeza diaria e o banco fica em WAL', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    await enviarLeituras(s, [leitura('2026-03-02', '09:00')]);
    const r = phpEscala(`$d = new PDO('sqlite:${q(path.join(s.dados, 'presenca.sqlite'))}');
      echo $d->query('PRAGMA journal_mode')->fetchColumn(), '|', $d->query("SELECT valor FROM meta WHERE chave='limpeza_em'")->fetchColumn();`);
    assert.equal(r, `wal|${AGORA}`);
  } finally { s.fechar(); }
});

test('PHP batimento: servidor sem usuario logado aparece "no ar" pelo batimento SYSTEM, so servidores contam e passa de 15 min vira "fora do ar"', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    const AG = AUTH_AGENTE;
    await enviarLeituras(s, [leitura('2026-03-06', '09:00', { host: 'SRV-A', usuario: 'CORP\\msouza', nome_completo: 'Maria' })]);
    const a = await s.entrar();
    const srv = async () => (await a.json('/api/estado')).itens.find((i) => i.host === 'SRV-A');
    // sem batimento: regra antiga (ultima leitura de usuario ha horas = sem sinal)
    let i = await srv();
    assert.equal(i.servidor, true); assert.equal(i.batimento, false); assert.equal(i.ativo, false);

    // politica: so servidores marcados, e exige token
    const pol = async (h, headers) => s.req('/api/batimento/politica?host=' + h, { headers });
    assert.equal((await pol('srv-a')).status, 401);
    assert.equal((await (await pol('srv-a', AG)).json()).ativo, true, 'sem diferenciar maiusculas');
    assert.equal((await (await pol('RP9', AG)).json()).ativo, false);

    // POST: exige token, valida host e ignora maquina que nao e servidor
    const bater = (corpo, headers = AG) => s.req('/api/batimento', { metodo: 'POST', headers, corpo });
    assert.equal((await bater({ host: 'SRV-A' }, {})).status, 401);
    assert.equal((await bater({ host: '' })).status, 400);
    assert.equal((await (await bater({ host: 'RP9', boot: AGORA - 86400000 })).json()).ignorado, true);
    const bootOk = AGORA - 3 * 86400000;
    assert.equal((await bater({ host: 'SRV-A', boot: bootOk })).status, 200);
    i = await srv();
    assert.equal(i.batimento, true); assert.equal(i.ativo, true); assert.equal(i.idade_min, 0); assert.equal(i.boot_em, bootOk);
    assert.equal(i.colaborador, 'Maria - msouza', 'o ultimo usuario continua nos dados');

    // boot absurdo (futuro) e ignorado, o batimento vale
    await bater({ host: 'SRV-A', boot: AGORA + 86400000 });
    assert.equal((await srv()).boot_em, null);

    // o contato no inventario tambem conta o batimento
    await s.req('/api/inventario', { metodo: 'POST', headers: AG, corpo: { host: 'SRV-A', tipo: 'SERVIDOR' } });
    assert.equal((await a.json('/api/inventario')).itens.find((x) => x.host === 'SRV-A').ultimo_contato, AGORA);

    // 10 min sem batimento = ainda no ar, 30 min = fora do ar
    const grava = (min) => phpEscala(`$d = new PDO('sqlite:${q(path.join(s.dados, 'presenca.sqlite'))}'); $d->exec('UPDATE batimento SET visto_em = ${AGORA} - ${min} * 60000');`);
    grava(10); i = await srv(); assert.equal(i.ativo, true); assert.equal(i.idade_min, 10);
    grava(30); i = await srv(); assert.equal(i.ativo, false); assert.equal(i.idade_min, 30);

    // desmarcar como servidor: o batimento antigo deixa de valer (volta para a regra dos 45 min com leitura de usuario)
    await a.enviar('/api/servidores', 'POST', { host: 'SRV-A', servidor: false });
    i = await srv(); assert.equal(i.servidor, false); assert.equal(i.batimento, false);
  } finally { s.fechar(); }
});

test('PHP relatorio: metricas validadas (score, metas, cliques, ocioso), cadastro do RH, mensal/semanal/periodo e recomendacoes, so admin', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    const horas = (n) => Array.from({ length: n }, (_, i) => `${String(9 + Math.floor(i * 5 / 60)).padStart(2, '0')}:${String(i * 5 % 60).padStart(2, '0')}`);
    const dia = async (login, nome, data, remoto, github, youtube, comFoco = true) => {
      const base = { host: 'PC-' + login.toUpperCase(), usuario: 'CORP\\' + login, nome_completo: nome };
      await enviarLeituras(s, horas(14).map((hh) => leitura(data, hh, { ...base, ...(remoto ? { resultado: 'Remoto', unidade: '' } : {}) })));
      const ts = Date.parse(`${data}T12:00:00-03:00`);
      await nav(s, [visita('https://github.com/x', 0, { ts, duracao_seg: github }), visita('https://www.youtube.com/w', 0, { ts: ts + 1000, duracao_seg: youtube })], base);
      if (comFoco) await foco(s, [seg(ts, 'WINWORD', 900), seg(ts + 900000, 'steam', 300), seg(ts + 1200000, 'chrome', 600)], base);
    };
    // semana de 02 a 06/03/2026: Ana 3 dias no escritorio e 2 em casa, Bruno 5 no escritorio (46,4), Carla so 2 dias.
    // Cada dia: produtivo 2100 s (Word 900 + GitHub 1200) e improdutivo 700 s (Steam 300 + YouTube 400) = score 75. Bruno: 1300 produtivo e 1500 improdutivo = 46,4
    for (const d of ['2026-03-02', '2026-03-03', '2026-03-04']) await dia('ana', 'Ana Souza', d, false, 1200, 400);
    for (const d of ['2026-03-05', '2026-03-06']) await dia('ana', 'Ana Souza', d, true, 1200, 400);
    for (const d of ['2026-03-02', '2026-03-03', '2026-03-04', '2026-03-05', '2026-03-06']) await dia('bruno', 'Bruno Lima', d, false, 400, 1200);
    for (const d of ['2026-03-02', '2026-03-03']) await dia('carla', 'Carla Dias', d, false, 1200, 400);
    await dia('ana', 'Ana Souza', '2026-02-27', false, 1200, 400);   // mes anterior (sexta, 7 dias antes: o servidor so aceita sites e programas recentes)

    const a = await s.entrar();
    const rel = async (q) => a.json('/api/relatorio?' + q);
    const mensal = (mes) => rel('tipo=mensal&mes=' + mes);
    // sem cadastro do RH: cargo e centro de custo ficam vazios e o relatorio avisa
    let r = await mensal('2026-03');
    assert.equal(r.tem_rh, false); assert.equal(r.cargo_modalidade, null); assert.equal(r.centros_custo, null); assert.equal(r.alertas.sem_rh, null);
    assert.ok(r.achados.some((x) => x.includes('cadastro do RH ainda não foi importado')));
    assert.ok(r.recomendacoes.some((x) => x.titulo === 'Cadastro do RH'));

    // cadastro do RH: Ana pelo login, Bruno pelo nome (sem login na planilha), uma pessoa que nao existe e a jornada em varios formatos
    const imp = await (await a.enviar('/api/colaboradores/importar-rh', 'POST', { linhas: [
      { login: 'ANA', cargo: 'ADVOGADO', centro_custo: 'BANCO PAN', jornada: '6:00' }, { nome: 'bruno  LIMA', cargo: 'ADMINISTRATIVO', centro_custo: 'SUPORTE', jornada: '44' },
      { nome: 'Fulano Inexistente', cargo: 'SOCIO', centro_custo: 'X' }, { login: 'carla' }] })).json();
    assert.equal(imp.atualizados, 2); assert.equal(imp.ignoradas, 1); assert.deepEqual(imp.nao_encontrados, ['Fulano Inexistente']);
    assert.equal((await a.enviar('/api/colaboradores/importar-rh', 'POST', { linhas: 'x' })).status, 400);
    const lc = (await a.json('/api/colaboradores')).itens;
    assert.equal(lc.find((x) => x.login === 'ana').cargo, 'ADVOGADO'); assert.equal(lc.find((x) => x.login === 'carla').rh, false);
    assert.equal(lc.find((x) => x.login === 'ana').jornada_horas, 6); assert.equal(lc.find((x) => x.login === 'bruno').jornada_horas, 8.8, '44 h por semana = 8,8 h por dia');
    await a.enviar('/api/colaboradores', 'PUT', { login: 'carla', cargo: 'ESTAGIARIO', centro_custo: 'SUPORTE' });
    assert.equal((await a.json('/api/colaboradores')).itens.find((x) => x.login === 'carla').rh, true, 'edicao manual tambem vale');
    await a.enviar('/api/colaboradores', 'PUT', { login: 'carla', cargo: '', centro_custo: '' });
    assert.equal((await a.json('/api/colaboradores')).itens.find((x) => x.login === 'carla').rh, false, 'limpar cargo e centro tira o vinculo');

    r = await mensal('2026-03');
    assert.equal(r.titulo, 'RELATÓRIO MENSAL DE PRODUTIVIDADE'); assert.match(r.subtitulo, /Março\/2026/);
    assert.deepEqual(r.periodo, { de: '2026-03-01', ate: '2026-03-06', dias_uteis: 5, feriados_excluidos: [], parcial: true });
    assert.equal(r.kpis.colaboradores, 3); assert.equal(r.kpis.registros, 12);
    assert.equal(r.kpis.score, 63.1, '(produtivo x 1 + neutro x 0,5) / total x 100'); assert.equal(r.kpis.pct_tempo_produtivo, 63.1); assert.equal(r.kpis.tempo_ativo_medio_dia_seg, 1800);
    assert.equal(r.classificacao.faixa, 'REGULAR'); assert.equal(r.classificacao.acima_da_meta, false);
    // metas validadas: tela ativa >= 6 h, disponibilidade >= 75%, ocioso < 90 min, produtivo >= 70%, neutro <= 20%, improdutivo < 10%, score >= 80
    assert.deepEqual(r.indicadores.map((x) => x.atingida), [false, false, true, false, true, false, false]);
    assert.deepEqual(r.indicadores.map((x) => x.meta), ['≥ 6 h', '≥ 75%', '< 90 min', '≥ 70%', '≤ 20%', '< 10%', '≥ 80 pontos']);
    assert.equal(r.indicadores[0].valor, '0,5 h');
    assert.deepEqual(r.cliques, { primeiro_medio: '12:00', ultimo_medio: '12:30' });
    assert.deepEqual(r.modalidade.map((x) => [x.modalidade, x.registros, x.score]), [['Presencial', 10, 60.7], ['Remoto (home)', 2, 75]]);
    assert.deepEqual(r.cargo_modalidade, [
      { cargo: 'ADMINISTRATIVO', presencial: { score: 46.4, registros: 5 }, remoto: null, delta: null, pouca_base: true },
      { cargo: 'ADVOGADO', presencial: { score: 75, registros: 3 }, remoto: { score: 75, registros: 2 }, delta: 0, pouca_base: true }]);
    assert.equal(r.dia_semana.length, 5); assert.equal(r.dia_semana[0].nome, 'Segunda');
    assert.deepEqual(r.distribuicao.faixas.map((x) => x.colaboradores), [0, 1, 0, 2, 0], 'Bruno em atencao, Ana e Carla em bom');
    assert.deepEqual(r.alertas.atencao.map((x) => x.nome), ['BRUNO LIMA']); assert.equal(r.alertas.total_critico, 0);
    assert.deepEqual(r.alertas.acompanhamento.map((x) => x.login), ['bruno', 'ana'], 'so quem tem 5+ dias, do menor score para o maior');
    assert.deepEqual(r.alertas.poucos_dias.itens.map((x) => [x.login, x.dias]), [['carla', 2]]);
    assert.equal(r.alertas.sem_rh.total, 1); assert.equal(r.alertas.sem_rh.itens[0].nome, 'CARLA DIAS'); assert.equal(r.alertas.sem_rh.pct_registros, 16.7);
    assert.deepEqual(r.top10.map((x) => [x.login, x.cargo]), [['ana', 'ADVOGADO'], ['bruno', 'ADMINISTRATIVO']]);
    assert.deepEqual(r.centros_custo.menores.map((x) => x.centro_custo), ['SUPORTE', 'BANCO PAN']);
    assert.equal(r.diario.length, 5);
    assert.deepEqual(r.evolucao.map((x) => [x.rotulo, x.colaboradores, x.pct_sem_rh]), [['Fev/2026', 1, 0], ['Mar/2026', 3, 16.7]]);
    assert.ok(r.achados.some((x) => x.startsWith('Presencial vs. remoto')) && r.achados.some((x) => x.startsWith('Versus Fevereiro/2026')));
    assert.ok(r.achados.some((x) => x.includes('de 7 metas do escritório não foram atingidas')));
    assert.deepEqual(r.recomendacoes.map((x) => x.titulo).slice(0, 3), ['Vínculo com o cadastro do RH', 'Poucos dias registrados', 'Faixas crítica e de atenção']);

    // semanal (segunda a domingo da data pedida) e periodo livre: calculam na hora, sem extracao
    const sem = await rel('tipo=semanal&data=2026-03-04');
    assert.equal(sem.titulo, 'RELATÓRIO SEMANAL DE PRODUTIVIDADE'); assert.equal(sem.periodo.de, '2026-03-02'); assert.equal(sem.periodo.ate, '2026-03-06'); assert.equal(sem.periodo.parcial, true);
    assert.match(sem.subtitulo, /semana de 02\/03\/2026 a 08\/03\/2026/); assert.equal(sem.kpis.registros, 12); assert.deepEqual(sem.evolucao.map((x) => x.colaboradores), [1, 3], 'semana anterior (23/02 a 01/03, com o dia 27/02 da Ana) e a atual');
    const per = await rel('tipo=personalizado&de=2026-03-02&ate=2026-03-03');
    assert.equal(per.kpis.registros, 6); assert.equal(per.evolucao.length, 0);
    assert.equal((await a.get('/api/relatorio?tipo=personalizado&de=2025-01-01&ate=2026-03-03')).status, 400, 'ate 92 dias');
    assert.equal((await a.get('/api/relatorio?tipo=personalizado&de=2026-03-03&ate=2026-03-02')).status, 400);
    assert.equal((await a.get('/api/relatorio?tipo=anual')).status, 400);
    assert.equal((await rel('tipo=mensal&mes=2026-02')).kpis.colaboradores, 1);
    assert.equal((await mensal('2025-06')).sem_dados, true, 'mes sem dados volta vazio, nao erro');

    // validacao, permissao e auditoria
    assert.equal((await a.get('/api/relatorio?tipo=mensal&mes=2026-13')).status, 400); assert.equal((await a.get('/api/relatorio?tipo=mensal')).status, 400);
    assert.equal((await a.get('/api/relatorio?tipo=mensal&mes=2026-04')).status, 400, 'mes no futuro');
    assert.equal((await a.get('/api/relatorio?tipo=semanal&data=2026-03-20')).status, 400);
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'G', senha: 'senha-gestor-1', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senha-gestor-1');
    assert.equal((await g.get('/api/relatorio?tipo=mensal&mes=2026-03')).status, 403); assert.equal((await g.enviar('/api/colaboradores/importar-rh', 'POST', { linhas: [] })).status, 403);
    const aud = JSON.stringify(await a.json('/api/auditoria'));
    assert.ok(aud.includes('"evento":"relatorio"') && aud.includes('rh_importado'));
  } finally { s.fechar(); }
});

test('PHP API v1: token proprio (hash, validade, revogacao, auditoria), dados por colaborador e dia, resumos, mensal e pseudonimos', opt, async () => {
  const s = await subir({ agora: AGORA, extra: "'feriados' => ['2026-03-04']," });
  try {
    const horas = (n) => Array.from({ length: n }, (_, i) => `${String(9 + Math.floor(i * 5 / 60)).padStart(2, '0')}:${String(i * 5 % 60).padStart(2, '0')}`);
    // cada dia: 14 leituras, sites (github produtivo, youtube improdutivo) e programas (Word produtivo, Steam improdutivo, Chrome so conta como tempo ativo)
    const dia = async (login, nome, data, remoto, github, youtube) => {
      const base = { host: 'PC-' + login.toUpperCase(), usuario: 'CORP\\' + login, nome_completo: nome };
      await enviarLeituras(s, horas(14).map((hh) => leitura(data, hh, { ...base, ...(remoto ? { resultado: 'Remoto', unidade: '' } : {}) })));
      const ts = Date.parse(`${data}T12:00:00-03:00`);
      await nav(s, [visita('https://github.com/x', 0, { ts, duracao_seg: github }), visita('https://www.youtube.com/w', 0, { ts: ts + 1000, duracao_seg: youtube })], base);
      await foco(s, [seg(ts, 'WINWORD', 900), seg(ts + 900000, 'steam', 300), seg(ts + 1200000, 'chrome', 600)], base);
    };
    await dia('ana', 'Ana Souza', '2026-02-28', false, 1200, 400);   // sabado
    await dia('ana', 'Ana Souza', '2026-03-02', false, 1200, 400);   // seg
    await dia('ana', 'Ana Souza', '2026-03-03', true, 1200, 400);    // ter (home)
    await dia('ana', 'Ana Souza', '2026-03-04', false, 1200, 400);   // qua (feriado no config)
    await dia('ana', 'Ana Souza', '2026-03-05', true, 1200, 400);    // qui (home)
    await dia('bruno', 'Bruno Lima', '2026-03-02', false, 400, 1200);

    const a = await s.entrar();
    // ---- tokens (admin) ----
    const jt = async (corpo) => (await a.enviar('/api/api-tokens', 'POST', corpo));
    assert.equal((await s.req('/api/v1/saude')).status, 401, 'sem token');
    assert.equal((await s.req('/api/v1/saude', { headers: AUTH_AGENTE })).status, 401, 'o token dos agents nao serve');
    assert.equal((await a.get('/api/v1/saude')).status, 401, 'a sessao do painel nao serve');
    assert.equal((await jt({ nome: '', validade_dias: 30 })).status, 400);
    assert.equal((await jt({ nome: 'x', validade_dias: 99999 })).status, 400);
    const criado = await jt({ nome: 'Analista', validade_dias: 30 });
    assert.equal(criado.status, 201);
    const tk = await criado.json();
    assert.match(tk.token, /^ppa_[0-9a-f]{40}$/);
    const lista = await a.json('/api/api-tokens');
    assert.equal(lista.itens.length, 1); assert.equal(lista.itens[0].prefixo, tk.token.slice(0, 8)); assert.equal(lista.itens[0].estado, 'ativo');
    assert.ok(!JSON.stringify(lista).includes(tk.token), 'a lista nunca devolve o token');
    assert.ok(!fs.readFileSync(path.join(s.dados, 'presenca.sqlite')).toString('latin1').includes(tk.token), 'no banco so o hash');
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'G', senha: 'senha-gestor-1', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senha-gestor-1');
    assert.equal((await g.get('/api/api-tokens')).status, 403); assert.equal((await g.enviar('/api/api-tokens', 'POST', { nome: 'x' })).status, 403);
    const H = { Authorization: 'Bearer ' + tk.token };
    const v1 = async (rota, headers = H) => s.req('/api/v1/' + rota, { headers });
    const j1 = async (rota, headers = H) => (await v1(rota, headers)).json();
    const saude = await j1('saude'); assert.equal(saude.ok, true); assert.equal(saude.token.nome, 'Analista'); assert.equal(saude.token.pseudonimizado, false);
    assert.equal((await s.req('/api/v1/saude', { metodo: 'POST', headers: H, corpo: {} })).status, 405, 'somente leitura');
    assert.equal((await v1('nada')).status, 404);
    assert.equal((await v1('saude', { Authorization: 'Bearer ppa_' + '0'.repeat(40) })).status, 401);

    // ---- /dias ----
    const dias = await j1('dias?de=2026-02-28&ate=2026-03-05');
    assert.equal(dias.total, 6);
    const ana02 = dias.itens.find((x) => x.login === 'ana' && x.dia === '2026-03-02');
    assert.deepEqual({ ...ana02, unidade: undefined }, { login: 'ana', nome: 'Ana Souza', dia: '2026-03-02', dia_semana: 1, modalidade: 'presencial', leituras_presencial: 14, leituras_remoto: 0, leituras_sem_rede: 0, unidade: undefined,
      tempo_ativo_seg: 1800, navegacao_seg: 1600, produtivo_seg: 2100, improdutivo_seg: 700, neutro_seg: 0, pct_produtivo: 75, score: 75,
      primeiro_click: '12:00', ultimo_click: '12:30', ocioso_seg: 0, jornada_horas: 8 });
    assert.equal(dias.itens.find((x) => x.dia === '2026-03-03' && x.login === 'ana').modalidade, 'remoto');
    assert.equal(dias.itens.find((x) => x.dia === '2026-02-28').dia_semana, 6);
    assert.equal((await j1('dias?de=2026-02-28&ate=2026-03-05&dias=uteis')).total, 4, 'sem sabado e sem o feriado do config');
    const p2 = await j1('dias?de=2026-02-28&ate=2026-03-05&limite=2&pagina=2');
    assert.equal(p2.itens.length, 2); assert.equal(p2.paginas, 3); assert.equal(p2.total, 6);
    assert.equal((await j1('dias?de=2026-02-28&ate=2026-03-05&logins=bruno')).total, 1);
    const csv = await (await v1('dias?de=2026-03-02&ate=2026-03-02&formato=csv')).text();
    assert.match(csv, /^login,nome,dia,dia_semana,modalidade,/); assert.match(csv, /ana,Ana Souza,2026-03-02,1,presencial,14,0,0,MTZ,1800,1600,2100,700,0,75,75,12:00,12:30,0,8\r\n/); assert.match(csv, /bruno,Bruno Lima,2026-03-02,1,presencial,14,0,0,MTZ,1800,1600,1300,1500,0,46\.4,46\.4,12:00,12:30,0,8\r\n/, 'virgula e ponto decimal');
    assert.equal((await v1('dias?de=2025-01-01&ate=2026-03-05')).status, 400, 'periodo longo demais para /dias');
    assert.equal((await v1('dias?de=2026-13-01')).status, 400); assert.equal((await v1('dias?de=2026-03-05&ate=2026-03-01')).status, 400);

    // ---- /resumo ----
    const sem = await j1('resumo?agrupar=dia_semana&de=2026-02-23&ate=2026-03-05');
    assert.deepEqual(sem.itens.map((x) => [x.grupo, x.colaboradores, x.dias_registro]), [[1, 2, 2], [2, 1, 1], [4, 1, 1]], 'so dias uteis: sem sabado e sem quarta (feriado)');
    assert.equal(sem.itens[0].nome, 'segunda'); assert.equal(sem.itens[0].pct_produtivo, 60.7); assert.equal(sem.itens[1].pct_produtivo, 75);
    assert.equal(sem.geral.dias_registro, 4); assert.equal(sem.dias_uteis_no_periodo, 8, '9 dias de semana menos o feriado do config');
    const mod = await j1('resumo?agrupar=modalidade&dias=todos&de=2026-02-23&ate=2026-03-05');
    assert.deepEqual(mod.itens.map((x) => [x.grupo, x.dias_registro]), [['presencial', 4], ['remoto', 2]]);
    const col = await j1('resumo?agrupar=colaborador&de=2026-02-23&ate=2026-03-05');
    assert.deepEqual(col.itens.map((x) => x.grupo), ['ana', 'bruno']); assert.equal(col.itens[0].tempo_ativo_medio_dia_seg, 1800);
    assert.equal((await v1('resumo?agrupar=xx')).status, 400); assert.equal((await v1('resumo?dias=xx')).status, 400);

    // ---- /mensal: o mesmo relatorio da aba Relatorio ----
    const mes = await j1('mensal?mes=2026-03');
    assert.deepEqual(mes.periodo, { de: '2026-03-01', ate: '2026-03-06', dias_uteis: 4, feriados_excluidos: ['2026-03-04'], parcial: true });
    assert.equal(mes.kpis.colaboradores, 2); assert.equal(mes.kpis.score, 67.9, '7600 produtivo / 11200 total');
    assert.deepEqual(mes.diario.map((x) => x.dia), ['2026-03-02', '2026-03-03', '2026-03-05']);
    assert.deepEqual(mes.modalidade.map((x) => [x.modalidade, x.registros]), [['Presencial', 2], ['Remoto (home)', 2]]);
    assert.equal(mes.alertas.poucos_dias.total, 2); assert.equal(mes.top10.length, 0, 'ninguem tem 5+ dias');
    assert.deepEqual(mes.evolucao.map((x) => x.rotulo), ['Mar/2026']);
    assert.equal(mes.indicadores.length, 7);
    assert.equal((await v1('mensal')).status, 400); assert.equal((await v1('mensal?mes=2026-04')).status, 400, 'mes no futuro');

    // ---- colaboradores e openapi ----
    const cs = await j1('colaboradores');
    assert.deepEqual(cs.itens.map((x) => x.login), ['ana', 'bruno']);
    assert.deepEqual(cs.itens[0], { login: 'ana', nome: 'Ana Souza', setor: '', ativo: true, primeiro_dia: '2026-02-28', ultimo_dia: '2026-03-05', cargo: null, centro_custo: null, vinculo_rh: false });
    assert.ok((await j1('openapi.json')).paths['/api/v1/dias']); assert.equal((await s.req('/api/v1/openapi.json')).status, 401);

    // ---- pseudonimos: o analista nao ve login nem nome ----
    const tp = await (await jt({ nome: 'Externo', validade_dias: 0, anonimizar: true })).json();
    const HP = { Authorization: 'Bearer ' + tp.token };
    const pd = await j1('dias?de=2026-03-02&ate=2026-03-03', HP);
    assert.ok(pd.itens.every((x) => /^p[0-9a-f]{12}$/.test(x.login) && x.nome === null));
    assert.ok(!JSON.stringify(pd).includes('Ana') && !JSON.stringify(pd).includes('"ana"'));
    const codAna = pd.itens.find((x) => x.modalidade === 'remoto').login;
    assert.equal((await j1('dias?de=2026-03-02&ate=2026-03-03', HP)).itens.find((x) => x.modalidade === 'remoto').login, codAna, 'o codigo e estavel');
    assert.equal((await j1(`dias?de=2026-03-02&ate=2026-03-05&logins=${codAna}`, HP)).total, 4, 'filtra pelo codigo: os 4 dias da Ana (sem filtro de dias uteis)');
    assert.equal((await j1('dias?de=2026-03-02&ate=2026-03-05&logins=ana', HP)).total, 0, 'login real nao filtra com token pseudonimizado');
    assert.ok(!JSON.stringify(await j1('colaboradores', HP)).includes('Ana Souza'));
    assert.ok((await j1('resumo?agrupar=colaborador&de=2026-03-02&ate=2026-03-03', HP)).itens.every((x) => /^p[0-9a-f]{12}$/.test(x.grupo)));
    assert.equal((await j1('saude', HP)).token.pseudonimizado, true);

    // ---- revogar, expirar, auditoria ----
    assert.equal((await a.enviar('/api/api-tokens?id=' + tk.id, 'DELETE')).status, 200);
    assert.equal((await v1('saude')).status, 401, 'revogado');
    assert.equal((await a.enviar('/api/api-tokens?id=' + tk.id, 'DELETE')).status, 404);
    phpEscala(`$d = new PDO('sqlite:${q(path.join(s.dados, 'presenca.sqlite'))}'); $d->exec('UPDATE api_tokens SET expira_em = 1 WHERE id = ${tp.id}');`);
    assert.equal((await v1('saude', HP)).status, 401, 'expirado');
    const estados = (await a.json('/api/api-tokens')).itens.map((x) => [x.nome, x.estado]);
    assert.deepEqual(estados, [['Externo', 'expirado'], ['Analista', 'revogado']]);
    const aud = JSON.stringify(await a.json('/api/auditoria'));
    for (const ev of ['api_token_criado', 'api_token_revogado', 'api_acesso']) assert.ok(aud.includes(ev), 'auditoria ' + ev);
    assert.ok(aud.includes('api:Analista'));
  } finally { s.fechar(); }
});

test('PHP comparativo Home x Presencial: dia vale pelo local onde ficou mais tempo, so quem tem dias nos dois modos entra e so admin ve', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    const horas = (n) => Array.from({ length: n }, (_, i) => `${String(9 + Math.floor(i * 5 / 60)).padStart(2, '0')}:${String(i * 5 % 60).padStart(2, '0')}`);
    const dia = async (login, nome, data, nPres, nRem, github, youtube) => {
      const h = horas(nPres + nRem);
      const base = { host: 'PC-' + login.toUpperCase(), usuario: 'CORP\\' + login, nome_completo: nome };
      await enviarLeituras(s, h.map((hh, i) => leitura(data, hh, { ...base, ...(i < nRem ? { resultado: 'Remoto', unidade: '' } : {}) })));
      const ts = Date.parse(`${data}T12:00:00-03:00`);
      await nav(s, [visita('https://github.com/x', 0, { ts, duracao_seg: github }), visita('https://www.youtube.com/w', 0, { ts: ts + 1000, duracao_seg: youtube })], base);
    };
    // Ana: 3 dias presenciais (75% produtivo) e 4 de home (50%), um deles misto: 8 leituras de home e 6 no escritorio = 57% home = dia de home
    for (const d of ['2026-03-02', '2026-03-03', '2026-03-04']) await dia('ana', 'Ana Souza', d, 14, 0, 1800, 600);
    await dia('ana', 'Ana Souza', '2026-02-26', 6, 8, 900, 900);   // misto: vale home
    for (const d of ['2026-02-27', '2026-03-05', '2026-03-06']) await dia('ana', 'Ana Souza', d, 0, 14, 900, 900);
    await dia('ana', 'Ana Souza', '2026-02-25', 5, 0, 9999, 0);      // dia curto (5 leituras): fora, mesmo com muito uso
    // Bruno: so escritorio. Carla: 2 dias de escritorio e 3 de home (abaixo do minimo de 3 em um dos lados)
    for (const d of ['2026-03-02', '2026-03-03', '2026-03-04', '2026-03-05']) await dia('bruno', 'Bruno Lima', d, 14, 0, 100, 100);
    for (const d of ['2026-03-02', '2026-03-03']) await dia('carla', 'Carla Dias', d, 14, 0, 100, 100);
    for (const d of ['2026-03-04', '2026-03-05', '2026-03-06']) await dia('carla', 'Carla Dias', d, 0, 14, 100, 100);

    const a = await s.entrar();
    const q = 'de=2026-02-23&ate=2026-03-06';
    const c = await a.json('/api/comparativo?' + q);
    assert.equal(c.min_dias, 3);
    assert.deepEqual(c.colaboradores.map((x) => x.login), ['ana'], 'so quem tem 3+ dias nos dois modos');
    const ana = c.colaboradores[0];
    assert.equal(ana.presencial.dias, 3); assert.equal(ana.remoto.dias, 4, 'o dia misto (57% home) e dia de home; o de 5 leituras nao conta');
    assert.equal(ana.presencial.pct_produtivo, 75); assert.equal(ana.remoto.pct_produtivo, 50);
    assert.equal(ana.dif_pct, -25);
    assert.equal(ana.presencial.prod_seg_dia, 1800); assert.equal(ana.remoto.prod_seg_dia, 900);
    assert.equal(ana.dif_prod_seg_dia, -900);
    assert.equal(ana.dias, undefined, 'dia a dia so quando a busca traz um colaborador');
    assert.deepEqual(c.fora.map((x) => [x.login, x.dias_presencial, x.dias_remoto]), [['carla', 2, 3], ['bruno', 4, 0]], 'quem esta mais perto de entrar vem primeiro');
    // seletor de minimo (?min=): com 2 dias a Carla entra, o Bruno nunca (nao tem nenhum dia de home), e valor invalido e ignorado
    const min2 = await a.json('/api/comparativo?' + q + '&min=2');
    assert.equal(min2.min_dias, 2); assert.deepEqual(min2.colaboradores.map((x) => x.login), ['ana', 'carla']); assert.deepEqual(min2.fora.map((x) => x.login), ['bruno']);
    assert.equal((await a.json('/api/comparativo?' + q + '&min=1')).colaboradores.length, 2);
    assert.equal((await a.json('/api/comparativo?' + q + '&min=abc')).min_dias, 3);
    assert.equal((await a.json('/api/comparativo?' + q + '&min=999')).min_dias, 30, 'limite de 30');
    assert.equal(c.geral.colaboradores, 1); assert.equal(c.geral.dif_pct, -25);

    // busca de um colaborador: so ele e com o dia a dia
    const so = await a.json('/api/comparativo?' + q + '&logins=ana');
    assert.equal(so.colaboradores.length, 1); assert.equal(so.fora.length, 0);
    const misto = so.colaboradores[0].dias.find((d) => d.dia === '2026-02-26');
    assert.equal(misto.modo, 'remoto'); assert.equal(misto.leituras_remoto, 8); assert.equal(misto.leituras_presencial, 6);
    assert.equal(so.colaboradores[0].dias.find((d) => d.dia === '2026-02-25'), undefined);
    assert.equal((await a.json('/api/comparativo?' + q + '&logins=bruno')).colaboradores.length, 0);

    // o BI normal nao carrega o dia a dia por colaborador (JSON leve)
    assert.ok(!JSON.stringify(await a.json('/api/bi?' + q)).includes('por_login_dia'));

    // CSV (admin) com auditoria; gestor nao ve nada
    const csv = await (await a.get('/api/export/comparativo.csv?' + q)).text();
    assert.match(csv, /Dias presenciais;Dias remotos;% produtivo presencial/); assert.match(csv, /ana;;3;4;75;50;-25;30;15;40;30/);
    assert.ok(JSON.stringify(await a.json('/api/auditoria')).includes('comparativo.csv'));
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'G', senha: 'senha-gestor-1', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senha-gestor-1');
    assert.equal((await g.get('/api/comparativo?' + q)).status, 403);
    assert.equal((await g.get('/api/export/comparativo.csv?' + q)).status, 403);
    assert.equal((await g.get('/api/bi?' + q)).status, 200, 'o BI continua liberado para o gestor');
  } finally { s.fechar(); }
});

test('painel BI: a secao Home x Presencial e o CSV so aparecem para administrador (data-admin) e acompanham a busca', () => {
  const pub = path.join(WEB, '_app', 'public');
  const html = fs.readFileSync(path.join(pub, 'index.html'), 'utf8');
  const bi = fs.readFileSync(path.join(pub, 'bi.js'), 'utf8');
  assert.match(html, /id="bi-home" data-admin hidden/);
  assert.match(html, /id="bi-csv-comparativo" href="#" download data-admin hidden/);
  for (const id of ['bi-home-sub', 'bi-home-geral', 'bi-home-vazio', 'bi-home-tabela', 'bi-home-fora', 'bi-home-detalhe', 'bi-home-nota']) assert.ok(html.includes('id="' + id + '"'), 'falta #' + id);
  assert.ok(bi.includes("P.eu.papel !== 'admin'"), 'gestor nem chama a rota');
  assert.ok(bi.includes('carregarComparativo();') && bi.includes('api/comparativo?'), 'redesenha com o periodo e a busca');
});

test('PHP BI: ?logins= refaz cartoes, graficos por dia e listas so para os colaboradores pedidos', opt, async () => {
  const s = await subir();
  try {
    const dia = (login, host, nome, url) => nav(s, [visita(url, 5)], { host, usuario: 'CORP\\' + login, nome_completo: nome });
    await dia('ana', 'PC-ANA', 'Ana Souza', 'https://github.com/x');             // produtivo (60 s)
    await dia('bruno', 'PC-BRUNO', 'Bruno Lima', 'https://www.youtube.com/watch'); // improdutivo (60 s)
    await dia('carla', 'PC-CARLA', 'Carla Dias', 'https://site-desconhecido.example/a'); // sem regra
    const a = await s.entrar();
    const bi = async (q = '') => a.json('/api/bi?x=1' + q);
    const todos = await bi();
    assert.equal(todos.kpis.colaboradores, 3);
    assert.equal(todos.kpis.pct_produtivo, 50);
    assert.equal(todos.top.produtivo.length + todos.top.improdutivo.length, 2);
    assert.equal(todos.sem_regra.length, 1);

    const ana = await bi('&logins=ana');
    assert.equal(ana.kpis.colaboradores, 1); assert.equal(ana.colaboradores[0].login, 'ana');
    assert.equal(ana.kpis.pct_produtivo, 100);
    assert.equal(ana.kpis.tempo_total_seg, 60, 'tempo so da Ana');
    assert.deepEqual(ana.top.produtivo.map((x) => x.dominio), ['github.com']);
    assert.equal(ana.top.improdutivo.length, 0, 'sites do Bruno nao aparecem');
    assert.equal(ana.sem_regra.length, 0, 'site sem regra da Carla nao aparece');
    assert.equal(ana.dias_produtividade.reduce((t, d) => t + d.produtivo + d.improdutivo + d.neutro, 0), 60);

    const bruno = await bi('&logins=BRUNO');   // maiusculas e usuario com dominio tambem valem
    assert.equal(bruno.kpis.pct_produtivo, 0); assert.equal(bruno.kpis.colaboradores, 1);
    assert.equal((await bi('&logins=' + encodeURIComponent('CORP\\bruno'))).kpis.colaboradores, 1);

    const dois = await bi('&logins=ana,bruno');
    assert.equal(dois.kpis.colaboradores, 2); assert.equal(dois.kpis.pct_produtivo, 50);
    // carla so aparece como "sem regra" quando ela esta no filtro
    assert.equal((await bi('&logins=carla')).sem_regra[0].quem[0].login, 'carla');

    assert.equal((await bi('&logins=')).kpis.colaboradores, 0, 'busca sem resultado = ninguem');
    assert.equal((await bi('&logins=ninguem')).kpis.colaboradores, 0);
    assert.equal((await bi('&logins=a%27%20OR%201%3D1--')).kpis.colaboradores, 0, 'texto estranho nao vira SQL');
    assert.equal((await bi()).kpis.colaboradores, 3, 'sem o parametro, continua todos');
  } finally { s.fechar(); }
});

test('painel BI: a busca tem lista de sugestoes e os numeros gerais acompanham o filtro', () => {
  const pub = path.join(WEB, '_app', 'public');
  const html = fs.readFileSync(path.join(pub, 'index.html'), 'utf8');
  const bi = fs.readFileSync(path.join(pub, 'bi.js'), 'utf8');
  assert.ok(html.includes('id="bi-sugestoes"') && html.includes('role="listbox"') && html.includes('role="combobox"'));
  for (const trecho of ['mostrarSugestoes', 'escolherSugestao', 'aplicarFiltroBI', '&logins=', 'ArrowDown', 'Escape']) assert.ok(bi.includes(trecho), 'falta ' + trecho);
});

test('painel BI: filtros de periodo em botoes (com Personalizado), busca com resumo e menu Exportar mantendo os links', () => {
  const pub = path.join(WEB, '_app', 'public');
  const html = fs.readFileSync(path.join(pub, 'index.html'), 'utf8');
  const app = fs.readFileSync(path.join(pub, 'app.js'), 'utf8');
  const bi = fs.readFileSync(path.join(pub, 'bi.js'), 'utf8');
  for (const id of ['bi-periodo', 'bi-busca', 'bi-limpar', 'bi-resumo', 'bi-exportar', 'bi-xlsx', 'bi-csv-presenca', 'bi-csv-prod', 'bi-imprimir']) {
    assert.ok(html.includes('id="' + id + '"'), 'falta #' + id);
  }
  const menu = html.slice(html.indexOf('<details id="bi-exportar"'), html.indexOf('</details>', html.indexOf('<details id="bi-exportar"')));
  for (const id of ['bi-xlsx', 'bi-csv-presenca', 'bi-csv-prod', 'bi-imprimir']) assert.ok(menu.includes('id="' + id + '"'), '#' + id + ' fica dentro do menu Exportar');
  for (const rot of ['7 dias', '30 dias', '90 dias', 'Este mês', 'Mês passado', 'Personalizado']) assert.ok(app.includes("'" + rot + "'"), 'botao ' + rot);
  assert.ok(bi.includes('atualizarResumoBI') && bi.includes('Indicadores de'), 'resumo da busca');
});

// ---------- BI e exportacoes ----------

test('PHP BI: junta produtividade e localizacao por colaborador', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    await enviarLeituras(s, ['09:00', '09:05', '09:10'].map((h) => leitura('2026-03-05', h)));
    await s.req('/api/navegacao', { metodo: 'POST', headers: AUTH_AGENTE, corpo: { host: 'NOTE-ANA', usuario: 'CORP\\ana', nome_completo: 'Ana Souza', visitas: [
      { ts: Date.parse('2026-03-05T13:00:00Z'), url: 'https://tjsp.jus.br/a', duracao_seg: 300 },
      { ts: Date.parse('2026-03-05T14:00:00Z'), url: 'https://youtube.com/watch', duracao_seg: 100 },
    ] } });
    const a = await s.entrar();
    const bi = await a.json('/api/bi?de=2026-03-02&ate=2026-03-06');
    assert.equal(bi.kpis.colaboradores, 1);
    assert.equal(bi.kpis.pct_produtivo, 75);
    assert.equal(bi.kpis.dias_presenciais, 1);
    assert.equal(bi.kpis.pct_presencial, 100);
    const c = bi.colaboradores[0];
    assert.equal(c.colaborador, 'Ana Souza - ana'); assert.equal(c.pct_produtivo, 75); assert.equal(c.dias_presenciais, 1);
    assert.equal(bi.unidades.MTZ, 1);
    assert.equal(bi.dias_produtividade[0].dia, '2026-03-05');
    assert.ok(bi.top.improdutivo.some((d) => d.dominio === 'youtube.com'));
  } finally { s.fechar(); }
});

test('PHP CSV: protege contra formulas e exporta produtividade/presenca/navegacao', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    await s.req('/api/navegacao', { metodo: 'POST', headers: AUTH_AGENTE, corpo: { host: 'H', usuario: 'CORP\\ana', nome_completo: '=HYPERLINK("http://x")', visitas: [
      { ts: Date.parse('2026-03-05T13:00:00Z'), url: 'https://youtube.com/watch', titulo: '=1+1', duracao_seg: 120 }] } });
    await enviarLeituras(s, ['09:00', '09:05', '09:10'].map((h) => leitura('2026-03-05', h, { nome_completo: '=HYPERLINK("http://x")' })));
    const a = await s.entrar();
    const prod = await csv(await a.get('/api/export/produtividade.csv?de=2026-03-02&ate=2026-03-06'));
    assert.ok(!/(^|;)=HYPERLINK/m.test(prod), 'formula nao pode comecar a celula');
    assert.match(prod, /'=HYPERLINK/);
    assert.match(await csv(await a.get('/api/export/presenca.csv?de=2026-03-02&ate=2026-03-06')), /2026-03-05;Presencial;MTZ;3;3/);
    const navCsv = await csv(await a.get('/api/export/navegacao.csv?de=2026-03-02&ate=2026-03-06'));
    assert.match(navCsv, /youtube\.com;Improdutivo;https:\/\/youtube\.com\/watch;'=1\+1;120/);
    assert.equal((await a.get('/api/export/inexistente.csv')).status, 404);
  } finally { s.fechar(); }
});

test('PHP recuperacao: redefinir_senha_admin no config devolve o acesso do administrador', opt, async () => {
  const s = await subir({ extra: "'redefinir_senha_admin' => 'recuperada-123'," });
  try {
    assert.equal((await s.req('/api/login', { metodo: 'POST', corpo: { login: 'admin', senha: SENHA } })).status, 401);
    const a = await s.entrar('admin', 'recuperada-123');
    assert.equal(a.eu.papel, 'admin');
    // aplica uma vez: trocar a senha pelo painel nao e desfeito a cada requisicao
    assert.equal((await a.enviar('/api/senha', 'POST', { atual: 'recuperada-123', nova: 'outra-senha-456' })).status, 200);
    await s.entrar('admin', 'outra-senha-456');
  } finally { s.fechar(); }
});


// ---------- protecoes: 2FA, limite por IP, auditoria ----------

function b32dec(s) {
  const alf = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; let bits = '';
  for (const c of s.replace(/=/g, '')) bits += alf.indexOf(c).toString(2).padStart(5, '0');
  const out = []; for (let i = 0; i + 8 <= bits.length; i += 8) out.push(parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(out);
}
function totp(segredo, off = 0, ms = Date.now()) {
  const crypto = require('node:crypto');
  const buf = Buffer.alloc(8); buf.writeBigUInt64BE(BigInt(Math.floor(ms / 30000) + off));
  const h = crypto.createHmac('sha1', b32dec(segredo)).update(buf).digest();
  const o = h[19] & 15;
  const n = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return String(n % 1000000).padStart(6, '0');
}
const loginRaw = (s, login, senha, codigo) => s.req('/api/login', { metodo: 'POST', corpo: { login, senha, ...(codigo ? { codigo } : {}) } });

test('PHP limite por IP: bloqueia mesmo com a senha certa (sem afetar agents)', opt, async () => {
  const s = await subir({ extra: "'login_max_falhas_ip' => 3," });
  try {
    for (const l of ['a1', 'a2', 'a3']) assert.equal((await loginRaw(s, l, 'x')).status, 401);
    assert.equal((await loginRaw(s, 'admin', SENHA)).status, 429);
    assert.equal((await loginRaw(s, 'admin', SENHA)).status, 429);
    assert.equal((await post(s, {})).status, 200);
    assert.equal((await s.req('/api/login', { metodo: 'POST', corpo: { login: 'admin', senha: SENHA } })).status, 429);
  } finally { s.fechar(); }
});

test('PHP 2FA: ativar, login em duas etapas, codigo reutilizado e codigos de recuperacao', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    const ini = await (await a.enviar('/api/2fa/iniciar', 'POST', {})).json();
    assert.match(ini.segredo, /^[A-Z2-7]{32}$/); assert.match(ini.uri, /^otpauth:\/\/totp\//);
    assert.equal((await a.enviar('/api/2fa/ativar', 'POST', { codigo: '000000' })).status, 400);
    const at = await (await a.enviar('/api/2fa/ativar', 'POST', { codigo: totp(ini.segredo) })).json();
    assert.equal(at.codigos_recuperacao.length, 8);
    assert.equal((await a.enviar('/api/2fa/iniciar', 'POST', {})).status, 400); // ja ativo
    assert.equal((await a.json('/api/eu')).totp_ativo, true);

    // etapa 1: senha certa sem codigo -> pede o codigo e NAO cria sessao
    const e1 = await loginRaw(s, 'admin', SENHA);
    assert.equal(e1.status, 200); assert.deepEqual(await e1.json(), { precisa_2fa: true });
    assert.equal(e1.headers.getSetCookie().length, 0);
    // senha errada continua 401; codigo errado 401
    assert.equal((await loginRaw(s, 'admin', 'errada', '123456')).status, 401);
    assert.equal((await loginRaw(s, 'admin', SENHA, '000000')).status, 401);
    // codigo certo entra; o mesmo codigo nao vale duas vezes (replay)
    const cod = totp(ini.segredo, 1);
    assert.equal((await loginRaw(s, 'admin', SENHA, cod)).status, 200);
    assert.equal((await loginRaw(s, 'admin', SENHA, cod)).status, 401);
    // codigo de recuperacao: vale uma vez
    const rec = at.codigos_recuperacao[0];
    assert.equal((await loginRaw(s, 'admin', SENHA, rec)).status, 200);
    assert.equal((await loginRaw(s, 'admin', SENHA, rec)).status, 401);
    assert.equal((await loginRaw(s, 'admin', SENHA, at.codigos_recuperacao[1])).status, 200);
  } finally { s.fechar(); }
});

test('PHP 2FA: desativar exige senha e codigo; admin consegue resetar o 2FA de outro usuario', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    const ini = await (await a.enviar('/api/2fa/iniciar', 'POST', {})).json();
    await a.enviar('/api/2fa/ativar', 'POST', { codigo: totp(ini.segredo) });
    assert.equal((await a.enviar('/api/2fa/desativar', 'POST', { senha: 'errada', codigo: totp(ini.segredo, 1) })).status, 400);
    assert.equal((await a.enviar('/api/2fa/desativar', 'POST', { senha: SENHA, codigo: '000000' })).status, 400);
    assert.equal((await a.enviar('/api/2fa/desativar', 'POST', { senha: SENHA, codigo: totp(ini.segredo, 1) })).status, 200);
    assert.equal((await loginRaw(s, 'admin', SENHA)).status, 200); // sem 2FA de novo: entra so com a senha
    // reset por outro admin
    const b = await s.entrar();
    await b.enviar('/api/usuarios', 'POST', { login: 'colega', senha: 'abc12345-xyz', papel: 'gestor' });
    const c = await s.entrar('colega', 'abc12345-xyz');
    const i2 = await (await c.enviar('/api/2fa/iniciar', 'POST', {})).json();
    await c.enviar('/api/2fa/ativar', 'POST', { codigo: totp(i2.segredo) });
    assert.equal((await loginRaw(s, 'colega', 'abc12345-xyz')).status === 200 && (await (await loginRaw(s, 'colega', 'abc12345-xyz')).json()).precisa_2fa, true);
    const lista = (await b.json('/api/usuarios')).itens;
    const col = lista.find((u) => u.login === 'colega');
    assert.equal(col.totp_ativo, true);
    assert.equal((await b.enviar('/api/usuarios', 'PUT', { id: col.id, reset_2fa: true })).status, 200);
    assert.equal((await b.json('/api/usuarios')).itens.find((u) => u.login === 'colega').totp_ativo, false);
    await s.entrar('colega', 'abc12345-xyz');
  } finally { s.fechar(); }
});

test('PHP 2FA: com exigir_2fa, o painel so libera depois de ativar', opt, async () => {
  const s = await subir({ extra: "'exigir_2fa' => true," });
  try {
    const a = await s.entrar();
    assert.equal(a.eu.precisa_configurar_2fa, true);
    const bloq = await a.get('/api/estado');
    assert.equal(bloq.status, 403); assert.equal((await bloq.json()).precisa_configurar_2fa, true);
    assert.equal((await a.get('/api/produtividade')).status, 403);
    const tela = await a.get('/');
    assert.equal(tela.status, 200); // a tela carrega para mostrar o assistente
    await tela.text(); // le o corpo (a tela cresceu; sem ler, o cliente HTTP do Node reclama ao fechar a conexao)
    const ini = await (await a.enviar('/api/2fa/iniciar', 'POST', {})).json();
    assert.equal((await a.enviar('/api/2fa/ativar', 'POST', { codigo: totp(ini.segredo) })).status, 200);
    assert.equal((await a.get('/api/estado')).status, 200);
    assert.equal((await a.enviar('/api/2fa/desativar', 'POST', { senha: SENHA, codigo: totp(ini.segredo, 1) })).status, 400); // obrigatorio
  } finally { s.fechar(); }
});

test('PHP auditoria: registra logins, falhas, exportacoes e alteracoes; so o admin le; sem segredos', opt, async () => {
  const s = await subir();
  try {
    await loginRaw(s, 'admin', 'senha-errada-xyz');
    const a = await s.entrar();
    await a.get('/api/export/produtividade.csv?de=2026-03-01&ate=2026-03-06');
    await a.enviar('/api/regras', 'POST', { padrao: 'exemplo.com', categoria: 'improdutivo' });
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', senha: 'abc12345-xyz', papel: 'gestor' });
    const ev = (await a.json('/api/auditoria')).itens;
    const tipos = ev.map((e) => e.evento);
    for (const t of ['login_falha', 'login_ok', 'exportacao', 'regra_salva', 'usuario_criado']) assert.ok(tipos.includes(t), t);
    assert.ok(ev.every((e) => e.ip === '127.0.0.1'));
    assert.match(ev.find((e) => e.evento === 'exportacao').detalhe, /produtividade\.csv 2026-03-01 a 2026-03-06/);
    const bruto = JSON.stringify(ev);
    assert.ok(!bruto.includes('senha-errada-xyz') && !bruto.includes(SENHA) && !bruto.includes('abc12345-xyz'));
    assert.equal((await a.json('/api/auditoria?evento=login_falha')).itens.length, 1);
    const g = await s.entrar('gestor1', 'abc12345-xyz');
    assert.equal((await g.get('/api/auditoria')).status, 403);
  } finally { s.fechar(); }
});


test('PHP maquinas: admin oculta/restaura/exclui; ocultada volta se enviar de novo; gestor nao pode', opt, async () => {
  const s = await subir();
  try {
    await post(s, { host: 'VELHO-PC', usuario: 'CORP\\ana', data_hora: iso(30 * 60000) });
    await post(s, { host: 'NOVO-PC', usuario: 'CORP\\ana', data_hora: iso(5 * 60000) });
    const a = await s.entrar();
    const hosts = async () => (await a.json('/api/estado')).itens.map((i) => i.host).sort();
    assert.deepEqual(await hosts(), ['NOVO-PC', 'VELHO-PC']);
    assert.equal((await a.enviar('/api/maquinas/ocultar', 'POST', { host: 'VELHO-PC' })).status, 200);
    assert.deepEqual(await hosts(), ['NOVO-PC']);
    assert.deepEqual((await a.json('/api/maquinas/ocultas')).itens.map((x) => x.host), ['VELHO-PC']);
    // o historico bruto continua; so a listagem some
    assert.equal((await a.json('/api/historico?host=VELHO-PC&horas=24')).itens.length, 1);
    // voltou a enviar depois de ocultada: reaparece sozinha
    await post(s, { host: 'VELHO-PC', usuario: 'CORP\\ana', data_hora: iso(-60000) });
    assert.deepEqual(await hosts(), ['NOVO-PC', 'VELHO-PC']);
    // restaurar manual
    await a.enviar('/api/maquinas/ocultar', 'POST', { host: 'NOVO-PC' });
    assert.deepEqual(await hosts(), ['VELHO-PC']);
    assert.equal((await a.enviar('/api/maquinas/restaurar', 'POST', { host: 'NOVO-PC' })).status, 200);
    assert.deepEqual(await hosts(), ['NOVO-PC', 'VELHO-PC']);
    // excluir: apaga as leituras daquela maquina
    const del = await (await a.enviar('/api/maquinas?host=VELHO-PC', 'DELETE')).json();
    assert.equal(del.leituras_removidas, 2);
    assert.deepEqual(await hosts(), ['NOVO-PC']);
    assert.equal((await a.json('/api/historico?host=VELHO-PC&horas=24')).itens.length, 0);
    assert.equal((await a.enviar('/api/maquinas/ocultar', 'POST', {})).status, 400);
    // auditoria e permissoes
    const tipos = (await a.json('/api/auditoria')).itens.map((e) => e.evento);
    for (const t of ['maquina_ocultada', 'maquina_restaurada', 'maquina_excluida']) assert.ok(tipos.includes(t), t);
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', senha: 'abc12345-xyz', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'abc12345-xyz');
    assert.equal((await g.enviar('/api/maquinas/ocultar', 'POST', { host: 'NOVO-PC' })).status, 403);
    assert.equal((await g.enviar('/api/maquinas?host=NOVO-PC', 'DELETE')).status, 403);
    assert.equal((await g.get('/api/maquinas/ocultas')).status, 403);
  } finally { s.fechar(); }
});
// ---------- atualizacao do agent ----------

test('PHP: /api/agente/versao e /pacote exigem token e so entregam o que foi publicado', opt, async () => {
  const s = await subir();
  try {
    assert.equal((await s.req('/api/agente/versao')).status, 401);
    assert.equal((await s.req('/api/agente/pacote')).status, 401);
    assert.equal((await s.req('/api/agente/versao', { headers: AUTH_AGENTE })).status, 404, 'nada publicado ainda');
    const pasta = path.join(s.dados, 'agente');
    fs.mkdirSync(pasta, { recursive: true });
    const zip = Buffer.from([0x50, 0x4b, 3, 4, 1, 2, 3, 4, 255, 0]);
    fs.writeFileSync(path.join(pasta, 'pacote.zip'), zip);
    // manifest com BOM (Set-Content -Encoding UTF8 do PowerShell 5.1 grava BOM)
    fs.writeFileSync(path.join(pasta, 'manifest.json'),
      Buffer.concat([Buffer.from([0xEF, 0xBB, 0xBF]), Buffer.from(JSON.stringify({ versao: '1.2.0', sha256: 'ab', tamanho: 10, assinatura: 'c2ln' }))]));
    const m = await (await s.req('/api/agente/versao', { headers: AUTH_AGENTE })).json();
    assert.deepEqual(m, { versao: '1.2.0', sha256: 'ab', tamanho: 10, assinatura: 'c2ln' });
    const r = await s.req('/api/agente/pacote', { headers: AUTH_AGENTE });
    assert.equal(r.status, 200);
    assert.equal(r.headers.get('content-type'), 'application/zip');
    assert.deepEqual(Buffer.from(await r.arrayBuffer()), zip, 'bytes identicos (a assinatura depende disso)');
  } finally { s.fechar(); }
});

test('PHP: versao do agent aparece em /api/estado; valor estranho e ignorado', opt, async () => {
  const s = await subir();
  try {
    assert.equal((await post(s, { host: 'PC-V', ts: undefined, versao_agente: '1.1.0' })).status, 200);
    assert.equal((await post(s, { host: 'PC-X', versao_agente: '<script>' })).status, 200);
    assert.equal((await post(s, { host: 'PC-ANTIGO' })).status, 200);
    const g = await s.entrar();
    const est = await g.json('/api/estado');
    const v = (h) => est.itens.find((i) => i.host === h).versao_agente;
    assert.equal(v('PC-V'), '1.1.0');
    assert.equal(v('PC-X'), '');
    assert.equal(v('PC-ANTIGO'), '');
  } finally { s.fechar(); }
});

test('PHP: mudanca de versao do agent fica na auditoria (agente_atualizado), sem repetir quando nao muda', opt, async () => {
  const s = await subir();
  try {
    await post(s, { host: 'PC-H', versao_agente: '1.2.0' });
    await post(s, { host: 'PC-H', versao_agente: '1.2.0', ts: undefined });
    await post(s, { host: 'PC-H', versao_agente: '1.3.0', ts: undefined });
    const g = await s.entrar();
    const itens = (await g.json('/api/auditoria?evento=agente_atualizado')).itens.filter((i) => i.login === 'PC-H');
    assert.equal(itens.length, 2);
    assert.match(itens[0].detalhe, /1\.2\.0 -> 1\.3\.0/);
    assert.match(itens[1].detalhe, /primeira leitura.*1\.2\.0/);
  } finally { s.fechar(); }
});

test('PHP acesso remoto: politica liga/desliga por maquina, senha cifrada, so admin ve e tudo vai para a auditoria', opt, async () => {
  const s = await subir();
  try {
    const AG = AUTH_AGENTE;
    const corpo = { host: 'pc-piloto', id: '123456789', senha: 'AbCdEfGh1234567890xy' };
    // desligado por padrao: nada e aceito e a maquina nao e liberada
    assert.equal((await (await s.req('/api/remoto/politica?host=PC-PILOTO', { headers: AG })).json()).ativo, false);
    assert.equal((await s.req('/api/remoto', { metodo: 'POST', headers: AG, corpo })).status, 403);
    assert.equal((await s.req('/api/remoto/politica?host=X')).status, 401, 'politica exige o token do agent');
    assert.equal((await s.req('/api/remoto', { metodo: 'POST', corpo })).status, 401);

    const a = await s.entrar();
    // so administrador configura; modo invalido e recusado
    assert.equal((await a.enviar('/api/remoto/config', 'PUT', { modo: 'qualquer', lista: '' })).status, 400);
    assert.equal((await a.enviar('/api/remoto/config', 'PUT', { modo: 'lista', lista: 'pc-piloto\nPC-DOIS, pc-piloto' })).status, 200);
    const cfg = await a.json('/api/remoto/config');
    assert.equal(cfg.modo, 'lista');
    assert.deepEqual(cfg.lista, ['PC-PILOTO', 'PC-DOIS']);
    assert.equal((await (await s.req('/api/remoto/politica?host=pc-piloto', { headers: AG })).json()).ativo, true);
    assert.equal((await (await s.req('/api/remoto/politica?host=OUTRO', { headers: AG })).json()).ativo, false);

    // registro do agent: valida ID e senha; maquina fora da lista continua barrada
    assert.equal((await s.req('/api/remoto', { metodo: 'POST', headers: AG, corpo: { ...corpo, id: 'abc' } })).status, 400);
    assert.equal((await s.req('/api/remoto', { metodo: 'POST', headers: AG, corpo: { ...corpo, senha: 'curta' } })).status, 400);
    assert.equal((await s.req('/api/remoto', { metodo: 'POST', headers: AG, corpo: { ...corpo, host: 'OUTRO' } })).status, 403);
    assert.equal((await s.req('/api/remoto', { metodo: 'POST', headers: AG, corpo })).status, 200);
    assert.equal((await s.req('/api/remoto', { metodo: 'POST', headers: AG, corpo })).status, 200, 'repetir o mesmo registro nao da erro');

    // a senha nunca fica em texto puro no banco nem no arquivo de chave; o inventario so mostra o ID
    const bruto = fs.readFileSync(path.join(s.dados, 'presenca.sqlite')).toString('latin1');
    assert.ok(!bruto.includes(corpo.senha), 'senha em texto puro no banco');
    assert.equal(fs.readFileSync(path.join(s.dados, 'remoto.key'), 'utf8').trim().length, 64);
    await s.req('/api/inventario', { metodo: 'POST', headers: AG, corpo: { host: 'PC-PILOTO', tipo: 'DESKTOP' } });
    const inv = (await a.json('/api/inventario')).itens.find((x) => x.host === 'PC-PILOTO');
    assert.equal(inv.remoto_id, '123456789');
    assert.ok(!JSON.stringify(inv).includes(corpo.senha));

    // revelar a senha: admin, uma maquina por vez, e fica na auditoria
    assert.equal((await a.enviar('/api/remoto/acesso', 'POST', { host: 'NAO-EXISTE' })).status, 404);
    const acesso = await (await a.enviar('/api/remoto/acesso', 'POST', { host: 'pc-piloto' })).json();
    assert.equal(acesso.id, '123456789');
    assert.equal(acesso.senha, corpo.senha);

    // gestor (so consulta) nao configura nem ve senha
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'G', senha: 'senhaboa123-ok', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senhaboa123-ok');
    assert.equal((await g.enviar('/api/remoto/acesso', 'POST', { host: 'PC-PILOTO' })).status, 403);
    assert.equal((await g.enviar('/api/remoto/config', 'PUT', { modo: 'todas', lista: '' })).status, 403);
    assert.equal((await g.get('/api/remoto/config')).status, 403);

    const aud = async (ev) => (await a.json('/api/auditoria?evento=' + ev)).itens;
    assert.equal((await aud('acesso_remoto')).length, 1);
    assert.match((await aud('acesso_remoto'))[0].detalhe, /PC-PILOTO/);
    assert.equal((await aud('remoto_registrado')).length, 1, 'registro repetido nao gera novo evento');
    assert.ok((await aud('remoto_config')).length >= 1);

    // modo "todas" libera qualquer maquina; "desligado" volta a barrar
    await a.enviar('/api/remoto/config', 'PUT', { modo: 'todas', lista: '' });
    assert.equal((await (await s.req('/api/remoto/politica?host=QUALQUER', { headers: AG })).json()).ativo, true);
    await a.enviar('/api/remoto/config', 'PUT', { modo: 'desligado', lista: '' });
    assert.equal((await (await s.req('/api/remoto/politica?host=PC-PILOTO', { headers: AG })).json()).ativo, false);
  } finally { s.fechar(); }
});

test('PHP acesso remoto: o agent informa a etapa da instalacao e o painel mostra por maquina e em resumo', opt, async () => {
  const s = await subir();
  try {
    const AG = AUTH_AGENTE;
    const st = (corpo, headers = AG) => s.req('/api/remoto/status', { metodo: 'POST', headers, corpo });
    assert.equal((await st({ host: 'PC-A', estado: 'baixando' }, {})).status, 401, 'exige o token do agent');
    assert.equal((await st({ host: 'PC-A', estado: 'qualquer-coisa' })).status, 400, 'so aceita etapas conhecidas');
    assert.equal((await st({ estado: 'baixando' })).status, 400, 'host obrigatorio');

    await s.req('/api/inventario', { metodo: 'POST', headers: AG, corpo: { host: 'PC-A', tipo: 'DESKTOP' } });
    await s.req('/api/inventario', { metodo: 'POST', headers: AG, corpo: { host: 'PC-B', tipo: 'NOTEBOOK' } });
    await s.req('/api/inventario', { metodo: 'POST', headers: AG, corpo: { host: 'PC-C', tipo: 'DESKTOP' } });
    assert.equal((await st({ host: 'pc-a', estado: 'baixando', detalhe: 'RustDesk 1.5.3' })).status, 200);
    assert.equal((await st({ host: 'pc-a', estado: 'instalando' })).status, 200, 'a etapa mais recente substitui a anterior');
    assert.equal((await st({ host: 'PC-B', estado: 'sem-relay' })).status, 200);
    assert.equal((await st({ host: 'PC-C', estado: 'falha-instalacao', detalhe: 'hash nao confere' })).status, 200);
    for (const e of ['falha-senha', 'aguardando-sessao', 'prazo-esgotado']) assert.equal((await st({ host: 'PC-Z', estado: e })).status, 200, 'estado novo aceito: ' + e);   // o ultimo (prazo-esgotado) fica

    const a = await s.entrar();
    const inv = (await a.json('/api/inventario')).itens;
    const por = (h) => inv.find((x) => x.host === h);
    assert.equal(por('PC-A').remoto_estado, 'instalando');
    assert.equal(por('PC-A').remoto_estado_detalhe, '');
    assert.equal(por('PC-B').remoto_estado, 'sem-relay');
    assert.equal(por('PC-C').remoto_estado_detalhe, 'hash nao confere');
    assert.ok(por('PC-C').remoto_estado_em > 0);

    const cfg = await a.json('/api/remoto/config');
    assert.deepEqual(cfg.estados, { instalando: 1, 'sem-relay': 1, 'falha-instalacao': 1, 'prazo-esgotado': 1 });
  } finally { s.fechar(); }
});

test('PHP classificacao automatica: sites novos entram classificados, o botao trata os antigos, so sobra o que nao ha certeza e da para desfazer', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    const regra = async (dom) => (await a.json('/api/regras')).itens.find((r) => r.padrao === dom);
    const semRegra = async () => (await a.json('/api/dominios-sem-regra')).itens.map((x) => x.dominio).sort();
    const urls = ['https://api.ipify.org/', 'https://www.ilovepdf.com/pt', 'https://scania.elaw.com.br/x', 'https://lojatcl.com.br/', 'https://rustdesk.com/', 'https://forms.cloud.microsoft/a',
      'https://escritorio.adv.br/', 'https://meucassino.com/', 'https://sitedefilmes.net/', 'https://api.empresa-xyz.com/v1', 'https://sistema.avgeo.com.br/', 'https://zzz-desconhecido.com/',
      // parecem ter palavra-chave, mas NAO podem ser classificados por engano (software, financas, politica, energia, promotoria)
      'https://datastore.com.br/', 'https://seriesfinanceiras.com.br/', 'https://promotoria.com.br/', 'https://gamesa.com/', 'https://jogodapolitica.com.br/'];
    const ficam = ['datastore.com.br', 'gamesa.com', 'jogodapolitica.com.br', 'promotoria.com.br', 'seriesfinanceiras.com.br', 'sistema.avgeo.com.br', 'zzz-desconhecido.com'];

    // 1) ligada por padrao: o que o sistema reconhece ja entra classificado; o resto fica na lista
    assert.equal((await a.json('/api/regras')).auto_ativo, true);
    assert.equal((await nav(s, urls.map((u, i) => visita(u, 10 + i)))).status, 200);
    assert.deepEqual(await semRegra(), ficam);
    assert.equal((await regra('ipify.org')).categoria, 'neutro');
    assert.equal((await regra('ilovepdf.com')).categoria, 'produtivo');
    assert.equal((await regra('elaw.com.br')).categoria, 'produtivo');
    assert.equal((await regra('lojatcl.com.br')).categoria, 'improdutivo');
    assert.equal((await regra('cloud.microsoft')).categoria, 'produtivo');
    assert.equal((await regra('adv.br')).categoria, 'produtivo', 'sufixo institucional');
    assert.equal((await regra('meucassino.com')).categoria, 'improdutivo');
    assert.equal((await regra('api.empresa-xyz.com')).categoria, 'neutro', 'endereco de servico: so o proprio endereco');
    assert.equal((await regra('ipify.org')).criado_por, 'auto');

    // 2) a regra do administrador nunca e sobrescrita pela automatica
    await a.enviar('/api/regras', 'POST', { padrao: 'rustdesk.com', categoria: 'improdutivo' });
    assert.equal((await regra('rustdesk.com')).categoria, 'improdutivo');
    assert.equal((await regra('rustdesk.com')).criado_por, 'admin');

    // 3) desligada: os novos ficam na lista; o botao trata os antigos e diz o que resta
    assert.equal((await a.enviar('/api/regras/auto-config', 'PUT', { ativo: false })).status, 200);
    assert.equal((await a.json('/api/regras')).auto_ativo, false);
    await nav(s, ['https://dropbox.com/', 'https://medium.com/x', 'https://t.me/c', 'https://fast.com/', 'https://zzz-outro.com/'].map((u, i) => visita(u, 40 + i)));
    assert.deepEqual(await semRegra(), [...ficam, 'dropbox.com', 'fast.com', 'medium.com', 't.me', 'zzz-outro.com'].sort());
    const r = await (await a.enviar('/api/regras/auto', 'POST', {})).json();
    assert.equal(r.aplicadas, 4);
    assert.equal(r.por_categoria.neutro, 4);
    assert.ok(r.amostra.every((x) => x.motivo));
    assert.deepEqual(r.restantes, { sites: ficam.length + 1, programas: 0 });
    assert.deepEqual(await semRegra(), [...ficam, 'zzz-outro.com'].sort());
    assert.equal((await (await a.enviar('/api/regras/auto', 'POST', {})).json()).aplicadas, 0, 'repetir nao muda nada');

    // 4) programas: reconhece os conhecidos e deixa o resto
    await foco(s, [seg(Date.now() - 600000, 'anydesk', 120), seg(Date.now() - 500000, 'programa-desconhecido', 120), seg(Date.now() - 400000, 'foxitreader', 60)]);
    const r2 = await (await a.enviar('/api/regras/auto', 'POST', {})).json();
    assert.equal(r2.aplicadas, 2);
    assert.deepEqual((await a.json('/api/programas-sem-regra')).itens.map((x) => x.processo), ['programa-desconhecido']);

    // 5) auditoria e permissoes
    assert.ok((await a.json('/api/auditoria?evento=regras_automaticas')).itens.length >= 2);
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'G', senha: 'senhaboa123-ok', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senhaboa123-ok');
    assert.equal((await g.enviar('/api/regras/auto', 'POST', {})).status, 403);
    assert.equal((await g.enviar('/api/regras/auto', 'DELETE')).status, 403);
    assert.equal((await g.enviar('/api/regras/auto-config', 'PUT', { ativo: true })).status, 403);

    // 6) desfazer: remove so as automaticas, os sites voltam para a lista, a do administrador fica
    const d = await (await a.enviar('/api/regras/auto', 'DELETE')).json();
    assert.ok(d.removidas >= 10);
    assert.equal((await regra('ipify.org')), undefined);
    assert.equal((await regra('rustdesk.com')).categoria, 'improdutivo');
    assert.ok((await semRegra()).includes('api.ipify.org'));
  } finally { s.fechar(); }
});

test('PHP painel: a aba Acesso remoto existe, o script e servido, o menu e so para admin e a liberacao saiu da Administracao', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    const js = await (await a.get('/remoto.js')).text();
    assert.match(js, /remotoConectar/);
    assert.ok(js.includes('pp-remoto://conectar'));
    const html = await (await a.get('/')).text();
    assert.match(html, /data-aba="remoto" data-admin hidden/, 'botao so para administrador');
    assert.match(html, /id="aba-remoto"/);
    assert.ok(html.includes('<script src="remoto.js"></script>'));
    const adm = html.split('id="aba-admin"')[1].split('</section>')[0];
    assert.ok(!/ad-rem-form/.test(adm), 'a liberacao nao fica mais na Administracao');
    assert.match(html.split('id="aba-remoto"')[1].split('</section>')[0], /ad-rem-form/, 'a liberacao esta na aba nova');
    // a gaveta do Inventario usa as mesmas funcoes de conexao (sem codigo duplicado)
    const inv = await (await a.get('/inventario.js')).text();
    assert.ok(inv.includes('remotoConectar(x.host'));
    assert.ok(inv.includes('remotoCopiarSenha(x.host'));
  } finally { s.fechar(); }
});

test('PHP localizacao: dia com poucas leituras fora do escritorio e "Parcial" no BI e no CSV', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    await enviarLeituras(s, ['09:00', '09:05'].map((h) => leitura('2026-03-05', h, { resultado: 'Remoto', unidade: '' })));
    const a = await s.entrar();
    const bi = await a.json('/api/bi?de=2026-03-05&ate=2026-03-06');
    assert.equal(bi.kpis.dias_parciais, 1);
    assert.equal(bi.kpis.dias_remotos, 0);
    assert.equal(bi.colaboradores[0].dias_parciais, 1);
    assert.deepEqual(bi.colaboradores[0].datas.parcial, ['2026-03-05'], 'datas por situacao alimentam o detalhe dos cartoes do BI');
    assert.equal(bi.colaboradores[0].datas.parcial.length, bi.colaboradores[0].dias_parciais);
    assert.equal(bi.dias_local.find((d) => d.dia === '2026-03-05').parcial, 1);
    assert.match(await csv(await a.get('/api/export/presenca.csv?de=2026-03-05&ate=2026-03-05')), /2026-03-05;Parcial;/);
  } finally { s.fechar(); }
});

test('PHP: "recomecar do zero" exige admin e confirmacao, apaga leituras e mantem usuarios/regras', opt, async () => {
  const s = await subir();
  try {
    await post(s, { host: 'PC-1', versao_agente: '1.1.0' });
    const a = await s.entrar();
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'Gestor', senha: 'senha-gestor-1', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senha-gestor-1');
    assert.equal((await g.enviar('/api/leituras/zerar', 'POST', { confirmacao: 'ZERAR' })).status, 403);
    assert.equal((await a.enviar('/api/leituras/zerar', 'POST', {})).status, 400);
    assert.equal((await a.enviar('/api/leituras/zerar', 'POST', { confirmacao: 'zerar' })).status, 400);
    assert.equal((await a.json('/api/estado')).itens.length, 1, 'confirmacao errada nao apaga nada');
    const regrasAntes = (await a.json('/api/regras')).length ?? (await a.json('/api/regras')).itens?.length;
    const r = await a.enviar('/api/leituras/zerar', 'POST', { confirmacao: 'ZERAR' });
    assert.equal(r.status, 200);
    assert.equal((await r.json()).removidos.registros, 1);
    assert.equal((await a.json('/api/estado')).itens.length, 0);
    const reg2 = await a.json('/api/regras');
    assert.equal((reg2.length ?? reg2.itens?.length), regrasAntes, 'regras mantidas');
    await s.entrar('gestor1', 'senha-gestor-1'); // usuarios mantidos
    const aud = await a.json('/api/auditoria');
    assert.ok(JSON.stringify(aud).includes('leituras_zeradas'));
  } finally { s.fechar(); }
});

test('PHP: excluir colaborador apaga tudo dele, preserva os outros e exige admin', opt, async () => {
  const s = await subir();
  try {
    assert.equal((await post(s, { host: 'PC-ANA', usuario: 'CORP\\ana', nome_completo: 'Ana Souza', versao_agente: '1.1.6' })).status, 200);
    assert.equal((await post(s, { host: 'PC-BIA', usuario: 'CORP\\bia', nome_completo: 'Bia Lima', versao_agente: '1.1.6' })).status, 200);
    await nav(s, [visita('https://pje.trt15.jus.br/x', 30)], { host: 'PC-ANA', usuario: 'CORP\\ana', nome_completo: 'Ana Souza' });
    const a = await s.entrar();
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'G', senha: 'senha-gestor-1', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senha-gestor-1');
    assert.equal((await g.enviar('/api/colaboradores?login=ana', 'DELETE')).status, 403);
    assert.equal((await a.enviar('/api/colaboradores?login=', 'DELETE')).status, 400);
    assert.equal((await a.enviar('/api/colaboradores?login=fantasma', 'DELETE')).status, 404);
    const r = await a.enviar('/api/colaboradores?login=ana', 'DELETE');
    assert.equal(r.status, 200);
    const rem = (await r.json()).removidos;
    assert.equal(rem.registros, 1);
    assert.equal(rem.navegacao, 1);
    assert.equal(rem.colaboradores, 1);
    const est = await a.json('/api/estado');
    assert.deepEqual(est.itens.map((i) => i.host), ['PC-BIA'], 'so a Bia continua no painel');
    const logins = (await a.json('/api/colaboradores')).itens.map((c) => c.login);
    assert.deepEqual(logins, ['bia']);
    assert.equal((await a.get('/api/colaborador?login=ana')).status === 200 ? (await (await a.get('/api/colaborador?login=ana')).json()).visitas.length : 0, 0);
    assert.ok(JSON.stringify(await a.json('/api/auditoria')).includes('colaborador_excluido'));
  } finally { s.fechar(); }
});

test('PHP: site sem classificacao mostra quem acessou e a pre-identificacao (titulos, enderecos)', opt, async () => {
  const s = await subir();
  try {
    await nav(s, [visita('https://site-novo.example/produto/a', 30, { titulo: 'Loja Nova - Produto A', duracao_seg: 120 }),
                  visita('https://site-novo.example/produto/a', 20, { titulo: 'Loja Nova - Produto A', duracao_seg: 60 }),
                  visita('https://site-novo.example/carrinho', 10, { titulo: 'Carrinho', duracao_seg: 30 })],
      { host: 'PC-ANA', usuario: 'CORP\\ana', nome_completo: 'Ana Souza' });
    await nav(s, [visita('https://site-novo.example/produto/b', 15, { titulo: 'Loja Nova - Produto B', duracao_seg: 200 })],
      { host: 'PC-BIA', usuario: 'CORP\\bia', nome_completo: 'Bia Lima' });
    const a = await s.entrar();
    const lista = (await a.json('/api/dominios-sem-regra')).itens;
    const item = lista.find((x) => x.dominio === 'site-novo.example');
    assert.ok(item, 'aparece como sem regra');
    assert.deepEqual(item.quem.map((q) => q.login), ['ana', 'bia'], 'quem mais usou vem primeiro (ana 210 s, bia 200 s)');
    assert.equal(item.quem.length, 2);
    assert.ok(item.quem.every((q) => q.colaborador && q.segundos > 0));
    // o BI traz o mesmo campo
    const bi = await a.json('/api/bi');
    assert.ok(bi.sem_regra.find((x) => x.dominio === 'site-novo.example').quem.length === 2);
    const d = await a.json('/api/dominio?dominio=Site-Novo.example');
    assert.equal(d.dominio, 'site-novo.example');
    assert.equal(d.tem_regra, false);
    assert.equal(d.acessos_brutos, 4);
    assert.equal(d.titulos[0].titulo, 'Loja Nova - Produto A');
    assert.equal(d.titulos[0].acessos, 2);
    assert.ok(d.caminhos.some((c) => c.url === 'https://site-novo.example/carrinho'));
    assert.deepEqual(d.colaboradores.map((c) => c.login).sort(), ['ana', 'bia']);
    assert.ok(d.primeiro_ts && d.ultimo_ts >= d.primeiro_ts);
    assert.equal((await a.get('/api/dominio')).status, 400);
    // depois de classificar, sai da lista de pendentes
    await a.enviar('/api/regras', 'POST', { padrao: 'site-novo.example', categoria: 'improdutivo' });
    assert.equal((await a.json('/api/dominios-sem-regra')).itens.some((x) => x.dominio === 'site-novo.example'), false);
    assert.equal((await a.json('/api/dominio?dominio=site-novo.example')).categoria, 'improdutivo');
    assert.equal((await s.req('/api/dominio?dominio=x')).status, 401, 'exige login');
  } finally { s.fechar(); }
});

// ---------- relatorio completo em Excel ----------

// leitor minimo de .zip (suficiente para conferir o .xlsx gerado): { nome: Buffer }
function lerZip(buf) {
  const zlib = require('node:zlib');
  let fim = buf.length - 22;
  while (fim >= 0 && buf.readUInt32LE(fim) !== 0x06054b50) fim--;
  assert.ok(fim >= 0, 'zip sem registro final');
  const n = buf.readUInt16LE(fim + 10);
  let p = buf.readUInt32LE(fim + 16);
  const out = {};
  for (let i = 0; i < n; i++) {
    assert.equal(buf.readUInt32LE(p), 0x02014b50);
    const metodo = buf.readUInt16LE(p + 10), crc = buf.readUInt32LE(p + 16), csize = buf.readUInt32LE(p + 20), tam = buf.readUInt32LE(p + 24);
    const nl = buf.readUInt16LE(p + 28), el = buf.readUInt16LE(p + 30), cl = buf.readUInt16LE(p + 32), off = buf.readUInt32LE(p + 42);
    const nome = buf.subarray(p + 46, p + 46 + nl).toString('utf8');
    const lnl = buf.readUInt16LE(off + 26), lel = buf.readUInt16LE(off + 28);
    const bruto = buf.subarray(off + 30 + lnl + lel, off + 30 + lnl + lel + csize);
    const dados = metodo === 8 ? zlib.inflateRawSync(bruto) : bruto;
    assert.equal(dados.length, tam, `tamanho de ${nome}`);
    assert.equal(zlib.crc32 ? zlib.crc32(dados) : crc, crc, `crc de ${nome}`);
    out[nome] = dados;
    p += 46 + nl + el + cl;
  }
  return out;
}

test('PHP: relatorio.xlsx traz as abas certas, dados tipados e respeita o perfil', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    const rem = { resultado: 'Remoto', unidade: '' };
    await enviarLeituras(s, [
      ...['09:00', '09:05', '09:10', '09:15'].map((h) => leitura('2026-03-02', h)),                 // seg: presencial MTZ, um trecho so
      ...['09:00', '09:05', '09:10'].map((h) => leitura('2026-03-03', h, rem)),                     // ter: remoto
      ...['14:00', '14:05'].map((h) => leitura('2026-03-03', h, rem)),                              // mesmo local, mas 5 h depois: outro trecho
    ]);
    await nav(s, [visita('https://pje.trt15.jus.br/x', 0, { ts: Date.parse('2026-03-02T13:00:00-03:00'), titulo: 'Consulta de processo', duracao_seg: 600 })], { host: 'NOTE-ANA', usuario: 'CORP\\ana', nome_completo: 'Ana Souza' });
    const a = await s.entrar();
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'G', senha: 'senha-gestor-1', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senha-gestor-1');

    const r = await a.get('/api/export/relatorio.xlsx?de=2026-03-02&ate=2026-03-06');
    assert.equal(r.status, 200);
    assert.match(r.headers.get('content-type'), /spreadsheetml\.sheet/);
    assert.match(r.headers.get('content-disposition'), /relatorio_2026-03-02_a_2026-03-06\.xlsx/);
    const z = lerZip(Buffer.from(await r.arrayBuffer()));
    const wb = z['xl/workbook.xml'].toString('utf8');
    assert.match(wb, /Resumo por colaborador/);
    assert.match(wb, /Dia a dia/);
    assert.match(wb, /Localiza/);
    assert.doesNotMatch(wb, /Acessos/, 'sem acessos quando nao pedido');
    const resumo = z['xl/worksheets/sheet1.xml'].toString('utf8');
    assert.match(resumo, /Ana Souza - ana/);
    const dia = z['xl/worksheets/sheet2.xml'].toString('utf8');
    assert.match(dia, /Presencial/);
    assert.match(dia, /Remoto|Parcial/);
    assert.match(dia, /NOTE-ANA/);
    assert.match(dia, /pje\.trt15\.jus\.br \(10 min\)/);
    assert.match(dia, /s="2"><v>0\.00694/, 'duracao de 10 min como fracao de dia com formato [h]:mm:ss');
    const loc = z['xl/worksheets/sheet4.xml'].toString('utf8');
    assert.equal((loc.match(/<row /g) || []).length - 1, 3, 'seg (1 trecho) + ter manha + ter tarde = 3 trechos');
    assert.doesNotMatch(loc, /Pendente/);
    assert.match(loc, /IP de sa/);
    assert.match(loc, /127\.0\.0\.1/, 'IP de saida (o que o servidor viu na conexao do agent)');
    assert.match(dia, /127\.0\.0\.1/, 'IP de saida tambem no dia a dia');

    // gestor nao ganha a aba de acessos, mesmo pedindo; administrador ganha
    const zg = lerZip(Buffer.from(await (await g.get('/api/export/relatorio.xlsx?de=2026-03-02&ate=2026-03-06&acessos=1')).arrayBuffer()));
    assert.doesNotMatch(zg['xl/workbook.xml'].toString('utf8'), /Acessos/);
    const za = lerZip(Buffer.from(await (await a.get('/api/export/relatorio.xlsx?de=2026-03-02&ate=2026-03-06&acessos=1')).arrayBuffer()));
    assert.match(za['xl/workbook.xml'].toString('utf8'), /Acessos/);
    assert.match(za['xl/worksheets/sheet5.xml'].toString('utf8'), /Consulta de processo/);
    assert.equal((await s.req('/api/export/relatorio.xlsx')).status, 401);
    assert.ok(JSON.stringify(await a.json('/api/auditoria')).includes('relatorio.xlsx'));
  } finally { s.fechar(); }
});

// ---------- servidores: "ultimo usuario logado" no lugar do colaborador ----------

test('PHP servidores: SRV-B e SRV-A ja vem marcados; admin marca/desmarca; aparece no estado e na localizacao', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    await enviarLeituras(s, [
      leitura('2026-03-06', '10:00', { host: 'SRV-A', usuario: 'CORP\\msouza', nome_completo: 'João Vitor' }),
      leitura('2026-03-06', '10:05', { host: 'srv-b', usuario: 'CORP\\carlos', nome_completo: 'Leonardo Muniz' }),
      leitura('2026-03-06', '10:10', { host: 'MTZ1547', usuario: 'CORP\\carlos', nome_completo: 'Leonardo Muniz' }),
    ]);
    const a = await s.entrar();
    const por = (est, h) => est.itens.find((i) => i.host.toLowerCase() === h.toLowerCase());
    let est = await a.json('/api/estado');
    assert.equal(por(est, 'SRV-A').servidor, true);
    assert.equal(por(est, 'SRV-B').servidor, true, 'comparacao sem diferenciar maiusculas');
    assert.equal(por(est, 'MTZ1547').servidor, false);
    assert.equal(por(est, 'SRV-A').colaborador, 'João Vitor - msouza', 'o ultimo usuario continua nos dados');
    // gestor nao altera
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'G', senha: 'senha-gestor-1', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senha-gestor-1');
    assert.equal((await g.enviar('/api/servidores', 'POST', { host: 'MTZ1547', servidor: true })).status, 403);
    assert.equal((await a.enviar('/api/servidores', 'POST', { host: '' })).status, 400);
    assert.equal((await a.enviar('/api/servidores', 'POST', { host: 'mtz1547', servidor: true })).status, 200);
    assert.equal(por(await a.json('/api/estado'), 'MTZ1547').servidor, true);
    assert.equal((await a.enviar('/api/servidores', 'POST', { host: 'MTZ1547', servidor: false })).status, 200);
    assert.equal(por(await a.json('/api/estado'), 'MTZ1547').servidor, false);
    // relatorio: aba de localizacao identifica o servidor
    const z = lerZip(Buffer.from(await (await a.get('/api/export/relatorio.xlsx?de=2026-03-02&ate=2026-03-06')).arrayBuffer()));
    assert.match(z['xl/worksheets/sheet4.xml'].toString('utf8'), /Servidor - último usuário: João Vitor - msouza/);
    assert.ok(JSON.stringify(await a.json('/api/auditoria')).includes('servidor_marcado'));
  } finally { s.fechar(); }
});

// ---------- programas em foco ----------

const seg = (ts, proc, segs, titulo = '') => ({ ts, seg: segs, proc, titulo });
const foco = (s, itens, o = {}, headers = AUTH_AGENTE) =>
  s.req('/api/foco', { metodo: 'POST', headers, corpo: { host: 'NOTE-ANA', usuario: 'CORP\\ana', nome_completo: 'Ana Souza', itens, ...o } });
const T0 = Date.parse('2026-03-02T12:00:00-03:00');
// o agent corta os segmentos em blocos de ate 5 min; o servidor aceita ate 15 min por segmento
const blocos = (ts, proc, total, titulo = '') => Array.from({ length: Math.ceil(total / 300) }, (_, i) => seg(ts + i * 300000, proc, Math.min(300, total - i * 300), titulo));

test('PHP foco: exige token, valida entradas, e e idempotente (reenvio nao duplica)', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    const lote = [seg(T0, 'WINWORD', 300, 'Contrato.docx - Word'), seg(T0 + 300000, 'WINWORD', 120, 'Contrato.docx - Word'), seg(T0 + 420000, 'EXCEL', 60, 'Planilha1')];
    assert.equal((await foco(s, lote, {}, {})).status, 401);
    assert.equal((await foco(s, lote, {}, { Authorization: 'Bearer errado' })).status, 401);
    const r = await (await foco(s, lote)).json();
    assert.equal(r.gravadas, 3);
    assert.equal((await (await foco(s, lote)).json()).gravadas, 0, 'reenvio da fila nao duplica');
    assert.equal((await foco(s, [], { host: '' })).status, 400);
    assert.equal((await s.req('/api/foco', { metodo: 'POST', headers: AUTH_AGENTE, corpo: { host: 'X', itens: new Array(501).fill({}) } })).status, 400);
    // entradas ruins sao ignoradas, as boas passam
    const mix = await (await foco(s, [{ ts: 'x', seg: 5, proc: 'A' }, seg(T0 - 30 * 86400000, 'OLD', 5), seg(T0 + 500000, '<script>', 5), seg(T0 + 510000, 'POWERPNT', 99999, 'x'.repeat(400))])).json();
    assert.equal(mix.recebidas, 4);
    assert.equal(mix.gravadas, 2, 'POWERPNT + o nome sem os simbolos "<>" (script)');
    const a = await s.entrar();
  } finally { s.fechar(); }
});

test('PHP foco: classificacao de programas, lista sem regra e relatorio com programas', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    await enviarLeituras(s, ['09:00', '09:05', '09:10'].map((h) => leitura('2026-03-02', h)));
    await foco(s, [...blocos(T0, 'WINWORD', 3600, 'Contrato.docx'), ...blocos(T0 + 3600000, 'chrome', 1800), ...blocos(T0 + 5400000, 'RobloxPlayerBeta', 600), ...blocos(T0 + 6000000, 'ferramenta-nova', 900, 'Algo')]);
    await foco(s, blocos(T0, 'EXCEL', 1200, 'P'), { host: 'NOTE-BIA', usuario: 'CORP\\bia', nome_completo: 'Bia Lima' });
    const a = await s.entrar();
    // sem regra: so o programa novo (Word/Roblox ja vem classificados; chrome e navegador)
    const pend = (await a.json('/api/programas-sem-regra?de=2026-03-02&ate=2026-03-06')).itens;
    assert.deepEqual(pend.map((p) => p.processo), ['ferramenta-nova']);
    assert.equal(pend[0].quem[0].login, 'ana');
    assert.equal((await a.enviar('/api/regras', 'POST', { padrao: 'app:ferramenta-nova', categoria: 'produtivo' })).status, 200);
    assert.equal((await a.enviar('/api/regras', 'POST', { padrao: 'app:../etc', categoria: 'produtivo' })).status, 400);
    assert.deepEqual((await a.json('/api/programas-sem-regra?de=2026-03-02&ate=2026-03-06')).itens, []);

    const z = lerZip(Buffer.from(await (await a.get('/api/export/relatorio.xlsx?de=2026-03-02&ate=2026-03-06&acessos=1')).arrayBuffer()));
    const wb = z['xl/workbook.xml'].toString('utf8');
    for (const nome of ['Resumo por colaborador', 'Dia a dia', 'Programas', 'Foco detalhado']) assert.match(wb, new RegExp(nome));
    const prog = z['xl/worksheets/sheet3.xml'].toString('utf8');
    assert.match(prog, /<t xml:space="preserve">Word<\/t>/);
    assert.match(prog, /Roblox/);
    assert.match(prog, /Navegador \(ver sites\)/, 'navegador fica a parte dos programas produtivos');
    assert.match(prog, /Improdutivo/);
    assert.match(prog, /s="2"><v>0\.041666/, '1 h do Word como duracao');
    const resumo = z['xl/worksheets/sheet1.xml'].toString('utf8');
    assert.match(resumo, /Tempo ativo no PC/);
    assert.match(resumo, /% produtivo geral/);
    const dia = z['xl/worksheets/sheet2.xml'].toString('utf8');
    assert.match(dia, /Word \(60 min\)/);
    assert.match(dia, /Programas que mais usou/);
    const det = z['xl/worksheets/sheet6.xml'].toString('utf8');
    assert.match(det, /Contrato\.docx/);
  } finally { s.fechar(); }
});

test('PHP CSV completo: acessos, foco e leituras em fluxo, so para administrador', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    await enviarLeituras(s, ['09:00', '09:05'].map((h) => leitura('2026-03-02', h)));
    await foco(s, [seg(T0, 'WINWORD', 300, 'Contrato.docx'), seg(T0 + 300000, 'EXCEL', 60, '=1+1')]);
    const a = await s.entrar();
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'G', senha: 'senha-gestor-1', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senha-gestor-1');
    for (const t of ['foco', 'leituras', 'acessos']) assert.equal((await g.get(`/api/export/${t}.csv?de=2026-03-02&ate=2026-03-06`)).status, 403, `${t} so admin`);
    const f = await csv(await a.get('/api/export/foco.csv?de=2026-03-02&ate=2026-03-06'));
    assert.match(f, /Ana Souza - ana;ana;NOTE-ANA;Word;WINWORD;Produtivo;Contrato\.docx;300/);
    assert.match(f, /'=1\+1/, 'protege contra formula');
    const l = await csv(await a.get('/api/export/leituras.csv?de=2026-03-02&ate=2026-03-06'));
    assert.equal(l.trim().split('\r\n').length, 3, 'cabecalho + 2 leituras, nada resumido');
    assert.match(l, /127\.0\.0\.1/);
    assert.match(await csv(await a.get('/api/export/acessos.csv?de=2026-03-02&ate=2026-03-06')), /Data\/hora;Colaborador/);
  } finally { s.fechar(); }
});

test('PHP servidores fora das contas por colaborador: novos dados nao entram e o recalculo limpa o passado', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    const a = await s.entrar();
    // marca SRV02 como servidor ANTES: nada dele vira dia de presenca, site ou programa do usuario
    await a.enviar('/api/servidores', 'POST', { host: 'SRV02', servidor: true });
    await enviarLeituras(s, ['09:00', '09:05', '09:10'].map((h) => leitura('2026-03-02', h, { host: 'SRV02', usuario: 'CORP\\admin1', nome_completo: 'Admin Um' })));
    await nav(s, [visita('https://youtube.com/x', 0, { ts: Date.parse('2026-03-02T13:00:00-03:00'), duracao_seg: 100 })], { host: 'SRV02', usuario: 'CORP\\admin1', nome_completo: 'Admin Um' });
    await foco(s, blocos(T0, 'EXCEL', 600), { host: 'SRV02', usuario: 'CORP\\admin1', nome_completo: 'Admin Um' });
    const colabs = (await a.json('/api/colaboradores')).itens.map((c) => c.login);
    assert.ok(!colabs.includes('admin1'), 'servidor nao cria colaborador');
    const bi = await a.json('/api/bi?de=2026-03-02&ate=2026-03-06');
    assert.equal(bi.colaboradores.length, 0);
    const est = await a.json('/api/estado');
    assert.equal(est.itens.find((i) => i.host === 'SRV02').servidor, true, 'mas continua no Presenca agora, com o ultimo usuario');
    assert.equal(est.itens.find((i) => i.host === 'SRV02').colaborador, 'Admin Um - admin1');

    // dado antigo: SRV03 ainda NAO era servidor quando enviou; depois de marcado, o recalculo tira dos resumos
    await enviarLeituras(s, ['09:00', '09:05', '09:10', '09:15'].map((h) => leitura('2026-03-03', h, { host: 'SRV03', usuario: 'CORP\\admin1', nome_completo: 'Admin Um' })));
    await enviarLeituras(s, ['10:00', '10:05', '10:10', '10:15'].map((h) => leitura('2026-03-04', h)));            // Ana, no PC dela
    await enviarLeituras(s, ['08:00', '08:05'].map((h) => leitura('2026-03-02', h)));                              // dia anterior ao primeiro dia completo
    await nav(s, [visita('https://youtube.com/x', 0, { ts: Date.parse('2026-03-03T13:00:00-03:00'), duracao_seg: 100 })], { host: 'SRV03', usuario: 'CORP\\admin1', nome_completo: 'Admin Um' });
    let b2 = await a.json('/api/bi?de=2026-03-02&ate=2026-03-06');
    assert.ok(b2.colaboradores.some((c) => c.login === 'admin1'), 'antes: o servidor contava para admin1');
    await a.enviar('/api/servidores', 'POST', { host: 'SRV03', servidor: true });
    const r = await a.enviar('/api/resumos/reconstruir', 'POST', {});
    assert.equal(r.status, 200);
    b2 = await a.json('/api/bi?de=2026-03-02&ate=2026-03-06');
    assert.ok(!b2.colaboradores.some((c) => c.login === 'admin1'), 'depois: admin1 sumiu das contas');
    const ana = b2.colaboradores.find((c) => c.login === 'ana');
    assert.ok(ana, 'Ana continua');
    assert.equal(ana.dias_presenciais, 1, 'so o dia 04/03 (>= 4 leituras) segue presencial; o 02/03 (2 leituras) e anterior ao recalculo');
    // gestor nao pode recalcular
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'G', senha: 'senha-gestor-1', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senha-gestor-1');
    assert.equal((await g.enviar('/api/resumos/reconstruir', 'POST', {})).status, 403);
    assert.equal((await g.get('/api/servidores')).status, 403);
    assert.deepEqual((await a.json('/api/servidores')).itens.map((x) => x.host).sort(), ['SRV-A', 'SRV-B', 'SRV02', 'SRV03']);
  } finally { s.fechar(); }
});

test('PHP BI: programas entram na produtividade (produtivo/improdutivo/neutro) e no top de programas', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    await enviarLeituras(s, ['09:00', '09:05', '09:10'].map((h) => leitura('2026-03-02', h)));
    await nav(s, [visita('https://pje.trt15.jus.br/x', 0, { ts: Date.parse('2026-03-02T13:00:00-03:00'), duracao_seg: 600 })]); // site produtivo: 600 s
    await foco(s, [...blocos(T0, 'WINWORD', 1800), ...blocos(T0 + 2000000, 'RobloxPlayerBeta', 600), ...blocos(T0 + 3000000, 'explorer', 300), ...blocos(T0 + 4000000, 'chrome', 3000)]);
    const a = await s.entrar();
    const bi = await a.json('/api/bi?de=2026-03-02&ate=2026-03-06');
    const c = bi.colaboradores.find((x) => x.login === 'ana');
    assert.equal(c.segundos.produtivo, 600 + 1800, 'site + Word');
    assert.equal(c.segundos.improdutivo, 600, 'Roblox');
    assert.equal(c.segundos.neutro, 300, 'Explorer; o Chrome nao conta (valem os sites)');
    assert.equal(c.segundos_programas.produtivo, 1800);
    assert.equal(bi.top_programas.produtivo[0].nome, 'Word');
    assert.equal(bi.top_programas.improdutivo[0].nome, 'Roblox');
    assert.deepEqual(bi.top_programas.neutro.map((p) => p.nome), ['Explorador de Arquivos']);
    assert.ok(!JSON.stringify(bi.top_programas).includes('Chrome'));
    const dia = bi.dias_produtividade.find((d) => d.dia === '2026-03-02');
    assert.equal(dia.produtivo, 2400);
    // reclassificar um programa muda o resultado na hora
    await a.enviar('/api/regras', 'POST', { padrao: 'app:winword', categoria: 'improdutivo' });
    const bi2 = await a.json('/api/bi?de=2026-03-02&ate=2026-03-06');
    assert.equal(bi2.colaboradores.find((x) => x.login === 'ana').segundos.improdutivo, 600 + 1800);
    // a tela de produtividade (CSV) segue a mesma conta
    assert.match(await csv(await a.get('/api/export/produtividade.csv?de=2026-03-02&ate=2026-03-06')), /Ana Souza - ana/);
  } finally { s.fechar(); }
});

// ---------- inventario de maquinas ----------

const invAgent = (o = {}) => ({
  host: 'MTZ0779', fabricante: 'Dell Inc.', modelo: 'Inspiron 14 7472', serie: '6MPBYR2', tipo: 'NOTEBOOK', so: 'Microsoft Windows 11 Pro', so_versao: '10.0.26100', so_exibicao: '24H2',
  so_arquitetura: '64 bits', so_instalado_em: '2025-10-27', cpu: 'Intel Core i5', ram_gb: 16, discos: [{ modelo: 'ADATA 512GB', tipo: 'NVMe', gb: 477 }], disco_total_gb: 477,
  disco_c_total_gb: 474, disco_c_livre_gb: 176, ips: ['10.10.30.222', 'nao-e-ip', '192.168.1.5'], mac: '02-00-00-00-00-05', dominio: 'corp.local', bios_versao: '1.18.0',
  ultimo_boot: '2026-03-01T08:00:00-03:00', ...o,
});
const invPost = (s, corpo, headers = AUTH_AGENTE) => s.req('/api/inventario', { metodo: 'POST', headers, corpo });
// trecho do modelo real "Relatorio de Ativos" (cabecalho com acento, comentario com quebra de linha entre aspas, BOM)
const MODELO_CSV = '﻿"Nome";"Status";"Fabricante";"Número de série";"Tipo";"Modelo";"Nome alternativo do usuário";"Número de inventário";"Localização";"Comentários";\r\n'
  + '"NOTEBOOK DELL";"INDISPONÍVEL";"DELL";"6MPBYR2";"NOTEBOOK";"INSPIRON 14 7472";"SALA DE REUNIÕES";"MTZ0779";"Brasilia";"Bateria trocada 07/11/2023";\r\n'
  + '"NOTEBOOK DELL";"DISPONÍVEL";"DELL";"7MN4QK2";"NOTEBOOK";"INSPIRON 14 7460";"DISPONÍVEL ESTOQUE";"RP00123";"Brasilia";"";\r\n'
  + '"DESKTOP COMPLETO (CPU/MONITOR/TECLADO/MOUSE)";"INUTILIZÁVEL";"";"";"DESKTOP";"";"ESTOQUE";"SP00013";"São Paulo";"Furtado em 14/11/2024\r\nB.o Anexo";\r\n'
  + '"NOTEBOOK DELL";"STATUS ESTRANHO";"DELL";"";"NOTEBOOK";"";"FULANO";"MTZ0001";"Ribeirão Preto";"";\r\n'
  + '"NOTEBOOK DELL";"DISPONÍVEL";"DELL";"";"NOTEBOOK";"";"";"";"";"sem numero";\r\n';

test('PHP inventario: o agent envia, o servidor valida, normaliza e guarda historico de mudancas de hardware', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    assert.equal((await invPost(s, invAgent(), {})).status, 401);
    assert.equal((await invPost(s, invAgent({ host: '' }))).status, 400);
    assert.equal((await invPost(s, invAgent())).status, 200);
    const a = await s.entrar();
    let it = (await a.json('/api/inventario')).itens.find((x) => x.chave === 'MTZ0779');
    assert.equal(it.fabricante, 'DELL', 'Dell Inc. -> DELL');
    assert.equal(it.modelo, 'INSPIRON 14 7472');
    assert.equal(it.ram_gb, 16);
    assert.equal(it.ips, '10.10.30.222, 192.168.1.5', 'so IPs validos');
    assert.equal(it.discos[0].tipo, 'NVMe');
    assert.equal(it.nome_ativo, 'NOTEBOOK DELL');
    assert.equal(it.tem_agente, true);
    // controle manual nao e apagado quando o agent reenvia
    assert.equal((await a.enviar('/api/inventario', 'PUT', { chave: 'MTZ0779', status: 'INDISPONÍVEL', responsavel: 'ANA SOUZA', localizacao: 'Ribeirão Preto', comentarios: 'Bateria trocada' })).status, 200);
    // troca de memoria e de disco: vira historico
    assert.equal((await invPost(s, invAgent({ ram_gb: 32, disco_total_gb: 953, so_exibicao: '25H2' }))).status, 200);
    it = (await a.json('/api/inventario')).itens.find((x) => x.chave === 'MTZ0779');
    assert.equal(it.ram_gb, 32);
    assert.equal(it.responsavel, 'ANA SOUZA');
    assert.equal(it.status, 'INDISPONÍVEL');
    const h = (await a.json('/api/inventario/historico?chave=mtz0779')).itens;
    assert.deepEqual(h.map((x) => x.campo).sort(), ['Armazenamento (GB)', 'Memória (GB)', 'Versão do Windows']);
    assert.equal(h.find((x) => x.campo === 'Memória (GB)').antigo, '16');
    // uma coleta incompleta (RAM 0) nao apaga o dado bom
    await invPost(s, invAgent({ ram_gb: 0, cpu: '' }));
    it = (await a.json('/api/inventario')).itens.find((x) => x.chave === 'MTZ0779');
    assert.equal(it.ram_gb, 32);
    assert.equal(it.cpu, 'Intel Core i5');
  } finally { s.fechar(); }
});

test('PHP inventario: importa o modelo do Relatorio de Ativos, casa com o agent e exporta no mesmo formato', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    const a = await s.entrar();
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'G', senha: 'senha-gestor-1', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senha-gestor-1');
    assert.equal((await g.enviar('/api/inventario/importar', 'POST', { csv: MODELO_CSV })).status, 403);
    assert.equal((await a.enviar('/api/inventario/importar', 'POST', { csv: 'Coluna;Outra\r\n1;2\r\n' })).status, 400);
    const r = await (await a.enviar('/api/inventario/importar', 'POST', { csv: MODELO_CSV })).json();
    assert.deepEqual([r.novos, r.atualizados, r.ignorados, r.status_invalidos], [4, 0, 1, 1]);
    assert.deepEqual(await (await a.enviar('/api/inventario/importar', 'POST', { csv: MODELO_CSV })).json(), { ok: true, novos: 0, atualizados: 0, iguais: 4, ignorados: 1, status_invalidos: 1 }, 'reimportar nao muda nada');
    let lista = (await a.json('/api/inventario')).itens;
    const sp = lista.find((x) => x.chave === 'SP00013');
    assert.match(sp.comentarios, /Furtado em 14\/11\/2024[\s\S]*B\.o Anexo/);
    assert.equal(sp.status, 'INUTILIZÁVEL');
    assert.equal(sp.tem_agente, false, 'estoque/sem agent');
    assert.equal(lista.find((x) => x.chave === 'MTZ0001').status, '', 'status invalido nao e gravado');

    // o agent de MTZ0779 chega: casa com o cadastro (mesmo numero), preenche o hardware e mantem o controle da planilha
    await enviarLeituras(s, [leitura('2026-03-06', '10:00', { host: 'mtz0779', usuario: 'CORP\\ana', nome_completo: 'Ana Souza' })]);
    await invPost(s, invAgent());
    lista = (await a.json('/api/inventario')).itens;
    const rp = lista.find((x) => x.chave === 'MTZ0779');
    assert.equal(rp.responsavel, 'SALA DE REUNIÕES');
    assert.equal(rp.localizacao, 'Brasilia');
    assert.equal(rp.ram_gb, 16);
    assert.equal(rp.origem, 'ambos');
    assert.equal(rp.ultimo_usuario, 'Ana Souza - ana');
    assert.equal(rp.ip_saida, '127.0.0.1');
    assert.ok(rp.ultimo_contato);
    assert.equal(lista.filter((x) => x.chave === 'MTZ0779').length, 1, 'sem duplicar');
    // importar de novo NAO sobrescreve o que ja tem valor; "sobrescrever" faz o CSV mandar
    await a.enviar('/api/inventario', 'PUT', { chave: 'MTZ0779', responsavel: 'MARIA' });
    await a.enviar('/api/inventario/importar', 'POST', { csv: MODELO_CSV });
    assert.equal((await a.json('/api/inventario')).itens.find((x) => x.chave === 'MTZ0779').responsavel, 'MARIA');
    const r2 = await (await a.enviar('/api/inventario/importar', 'POST', { csv: MODELO_CSV, sobrescrever: true })).json();
    assert.ok(r2.atualizados >= 1);
    assert.equal((await a.json('/api/inventario')).itens.find((x) => x.chave === 'MTZ0779').responsavel, 'SALA DE REUNIÕES');

    // exportacao: as 10 primeiras colunas sao exatamente as do modelo
    const texto = await csv(await a.get('/api/export/inventario.csv'));
    const cab = texto.split('\r\n')[0].split(';');
    assert.deepEqual(cab.slice(0, 10), ['Nome', 'Status', 'Fabricante', 'Número de série', 'Tipo', 'Modelo', 'Nome alternativo do usuário', 'Número de inventário', 'Localização', 'Comentários']);
    assert.ok(cab.includes('Memória (GB)') && cab.includes('IP de saída') && cab.includes('Último contato'));
    assert.match(texto, /NOTEBOOK DELL;INDISPONÍVEL;DELL;6MPBYR2;NOTEBOOK;INSPIRON 14 7472;SALA DE REUNIÕES;MTZ0779;Brasilia;Bateria trocada 07\/11\/2023;/);
    const z = lerZip(Buffer.from(await (await g.get('/api/export/inventario.xlsx')).arrayBuffer()));
    const wb = z['xl/workbook.xml'].toString('utf8');
    assert.match(wb, /Ativos/);
    assert.match(wb, /Alterações de hardware/);
    assert.match(z['xl/worksheets/sheet1.xml'].toString('utf8'), /MTZ0779/);
    assert.equal((await s.req('/api/export/inventario.csv')).status, 401);
  } finally { s.fechar(); }
});

test('PHP inventario: admin cria, edita e exclui ativo sem agent (estoque); gestor so le', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    const a = await s.entrar();
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', nome: 'G', senha: 'senha-gestor-1', papel: 'gestor' });
    const g = await s.entrar('gestor1', 'senha-gestor-1');
    assert.equal((await g.enviar('/api/inventario', 'PUT', { chave: 'X1', status: 'DISPONÍVEL' })).status, 403);
    assert.equal((await g.enviar('/api/inventario?chave=X1', 'DELETE')).status, 403);
    assert.equal((await g.get('/api/inventario')).status, 200);
    assert.equal((await a.enviar('/api/inventario', 'PUT', { chave: '' })).status, 400);
    assert.equal((await a.enviar('/api/inventario', 'PUT', { chave: 'mtz9999', status: 'QUEBRADO' })).status, 400);
    const r = await (await a.enviar('/api/inventario', 'PUT', { chave: 'mtz9999', status: 'disponível', tipo: 'notebook', fabricante: 'dell', modelo: 'latitude 3540', serie: 'abc123', localizacao: 'Campinas', comentarios: 'novo' })).json();
    assert.equal(r.novo, true);
    const it = (await a.json('/api/inventario')).itens.find((x) => x.chave === 'MTZ9999');
    assert.equal(it.status, 'DISPONÍVEL');
    assert.equal(it.modelo, 'LATITUDE 3540');
    assert.equal(it.tem_agente, false);
    assert.equal((await a.enviar('/api/inventario?chave=mtz9999', 'DELETE')).status, 200);
    assert.equal((await a.json('/api/inventario')).itens.length, 0);
    assert.ok(JSON.stringify(await a.json('/api/auditoria')).includes('inventario_excluido'));
  } finally { s.fechar(); }
});

// ---------- painel (front-end): estrutura do HTML coerente com o JavaScript ----------
// Um comentario HTML aberto sem fechar ja engoliu uma aba inteira e derrubou o admin.js: estes testes pegam esse tipo de erro.

test('painel: HTML bem formado, cada menu tem sua secao e todo elemento ligado no carregamento existe', () => {
  const pub = path.join(WEB, '_app', 'public');
  const html = fs.readFileSync(path.join(pub, 'index.html'), 'utf8');
  assert.equal((html.match(/<!--/g) || []).length, (html.match(/-->/g) || []).length, 'comentario HTML sem fechar');
  const semComentarios = html.replace(/<!--[\s\S]*?-->/g, '');
  for (const tag of ['div', 'section', 'main', 'nav', 'aside', 'header']) {
    assert.equal((semComentarios.match(new RegExp(`<${tag}\\b`, 'g')) || []).length, (semComentarios.match(new RegExp(`</${tag}>`, 'g')) || []).length, `<${tag}> desbalanceada`);
  }
  const ids = new Set([...semComentarios.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));
  assert.equal(ids.size, (semComentarios.match(/\bid="/g) || []).length, 'id repetido');
  // cada botao de menu leva a uma secao que existe (e fora de comentario)
  const abas = [...semComentarios.matchAll(/data-aba="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(abas, ['presenca', 'bi', 'produtividade', 'classificacao', 'relatorio', 'politicas', 'inventario', 'remoto', 'admin']);
  for (const a of abas) assert.ok(ids.has(`aba-${a}`), `falta a secao aba-${a}`);
  // dois modulos, com as abas nos lugares combinados
  const modulos = [...semComentarios.matchAll(/<div class="modulo" data-titulo="([^"]+)">([\s\S]*?)<\/div>\s*(?=<div class="modulo"|<\/nav>)/g)];
  assert.deepEqual(modulos.map((m) => m[1]), ['Presença e Produtividade', 'Administração']);
  assert.deepEqual([...modulos[0][2].matchAll(/data-aba="([^"]+)"/g)].map((m) => m[1]), ['presenca', 'bi', 'produtividade', 'classificacao']);
  assert.deepEqual([...modulos[1][2].matchAll(/data-aba="([^"]+)"/g)].map((m) => m[1]), ['relatorio', 'politicas', 'inventario', 'remoto', 'admin']);
  // todo $('id').addEventListener / .href / .textContent feito FORA de funcao (na carga do script) precisa de elemento existente
  for (const arq of fs.readdirSync(pub).filter((f) => f.endsWith('.js') && !['qrcode.js', 'login.js'].includes(f))) {
    const js = fs.readFileSync(path.join(pub, arq), 'utf8');
    for (const m of js.matchAll(/^\$\('([\w-]+)'\)\./gm)) assert.ok(ids.has(m[1]), `${arq}: $('${m[1]}') na carga, mas o elemento nao existe no index.html`);
  }
  // os scripts do index.html existem
  for (const m of semComentarios.matchAll(/<script src="([^"]+)"/g)) assert.ok(fs.existsSync(path.join(pub, m[1])), `script ausente: ${m[1]}`);
});

test('painel: layout responsivo (menu lateral que vira gaveta no celular, sem largura fixa que estoure a tela)', () => {
  const css = fs.readFileSync(path.join(WEB, '_app', 'public', 'style.css'), 'utf8');
  assert.match(css, /\.shell\s*\{[^}]*grid-template-columns:\s*252px/);
  assert.match(css, /@media \(max-width: 860px\)[\s\S]*\.lateral\s*\{[^}]*position:\s*fixed[^}]*translateX/);
  assert.match(css, /@media \(max-width: 640px\)[\s\S]*font-size:\s*16px/, 'campos com 16px no celular (sem zoom automatico)');
  assert.match(css, /main > \*\s*\{\s*min-width:\s*0/);
  // sem rolagem lateral: o conteudo usa a largura toda ao lado do menu, as celulas quebram linha e o inventario usa tabela fixa
  assert.match(css, /main\s*\{[^}]*max-width:\s*1700px;\s*margin:\s*0;/);
  assert.doesNotMatch(css, /th, td\s*\{[^}]*white-space:\s*nowrap/, 'celulas nao podem forcar a largura da tabela');
  assert.match(css, /\.inv-compacta\s*\{[^}]*table-layout:\s*fixed/);
  assert.match(css, /\.inv-selects\s*\{[^}]*repeat\(auto-fit,\s*minmax\(160px/);
  const html = fs.readFileSync(path.join(WEB, '_app', 'public', 'index.html'), 'utf8');
  assert.match(html, /name="viewport" content="width=device-width, initial-scale=1"/);
  assert.match(html, /id="btn-menu"/);
});

// ---------- endurecimento (auditoria de seguranca) ----------

test('PHP: HSTS so em HTTPS', opt, async () => {
  const s = await subir();
  try {
    assert.equal((await s.req('/health')).headers.get('strict-transport-security'), null);
    assert.match((await s.req('/health', { headers: { 'X-Forwarded-Proto': 'https' } })).headers.get('strict-transport-security'), /max-age=31536000/);
    const h = (await s.req('/health')).headers;
    assert.match(h.get('permissions-policy'), /camera=\(\)/); assert.equal(h.get('cross-origin-opener-policy'), 'same-origin'); assert.equal(h.get('cross-origin-resource-policy'), 'same-origin');
  } finally { s.fechar(); }
});

test('PHP reautenticacao: acoes sensiveis pedem a senha de novo (vale 5 min) e erro e limitado', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar('admin', SENHA, true);
    const pede = async (r) => { assert.equal(r.status, 403); const j = await r.json(); assert.equal(j.precisa_reautenticar, true); assert.equal(j.pede_codigo, false); };
    await pede(await a.enviar('/api/leituras/zerar', 'POST', { confirmacao: 'ZERAR' }));
    await pede(await a.enviar('/api/api-tokens', 'POST', { nome: 'x' }));
    await pede(await a.enviar('/api/remoto/acesso', 'POST', { host: 'PC' }));
    await pede(await a.enviar('/api/colaboradores?login=ana', 'DELETE'));
    await pede(await a.enviar('/api/usuarios', 'POST', { login: 'novo1', senha: 'senha-nova-1' }));
    assert.equal((await a.get('/api/usuarios')).status, 200); // leitura continua livre
    assert.equal((await a.enviar('/api/reautenticar', 'POST', { senha: 'errada' })).status, 400);
    assert.equal((await a.enviar('/api/api-tokens', 'POST', { nome: 'x' })).status, 403);
    assert.equal((await a.enviar('/api/reautenticar', 'POST', { senha: SENHA })).status, 200);
    assert.equal((await a.enviar('/api/api-tokens', 'POST', { nome: 'x' })).status, 201);
    assert.equal((await a.enviar('/api/usuarios', 'POST', { login: 'novo1', senha: 'senha-nova-1' })).status, 200);
    // outra sessao do mesmo usuario nao herda a confirmacao
    const b = await s.entrar('admin', SENHA, true);
    await pede(await b.enviar('/api/api-tokens', 'POST', { nome: 'y' }));
    for (let i = 0; i < 5; i++) await b.enviar('/api/reautenticar', 'POST', { senha: 'errada' });
    assert.equal((await b.enviar('/api/reautenticar', 'POST', { senha: SENHA })).status, 429);
  } finally { s.fechar(); }
});

test('PHP login: o bloqueio e por IP + login (quem erra de fora nao tranca o dono da conta)', opt, async () => {
  const s = await subir({ extra: "'ip_header' => 'HTTP_X_FORWARDED_FOR'," });
  try {
    const de = (ip, senha) => s.req('/api/login', { metodo: 'POST', headers: { 'X-Forwarded-For': ip }, corpo: { login: 'admin', senha } });
    for (let i = 0; i < 5; i++) assert.equal((await de('9.9.9.9', 'x')).status, 401);
    assert.equal((await de('9.9.9.9', SENHA)).status, 429);   // a origem do atacante fica bloqueada
    assert.equal((await de('1.1.1.1', SENHA)).status, 200);   // o dono entra de outro IP
  } finally { s.fechar(); }
});

test('PHP senha: trocar a senha derruba as outras sessoes e mantem a atual', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar('admin', SENHA, true);
    const b = await s.entrar('admin', SENHA, true);
    assert.equal((await b.enviar('/api/senha', 'POST', { atual: SENHA, nova: 'outra-senha-99' })).status, 200);
    assert.equal((await b.get('/api/eu')).status, 200);
    assert.equal((await a.get('/api/eu')).status, 401);
  } finally { s.fechar(); }
});

test('PHP 2FA: exigir_2fa_admin obriga so administradores; gestor nao ve dados do RH', opt, async () => {
  const s = await subir({ extra: "'exigir_2fa_admin' => true," });
  try {
    const a = await s.entrar('admin', SENHA, true);
    assert.equal((await a.json('/api/eu')).precisa_configurar_2fa, true);
    assert.equal((await a.get('/api/estado')).status, 403);
    assert.equal((await a.get('/api/2fa/iniciar')).status !== 200, true);
  } finally { s.fechar(); }
  const s2 = await subir();
  try {
    const a = await s2.entrar();
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor1', senha: 'senha-gestor-1', papel: 'gestor' });
    await post(s2, { usuario: 'DOM\\ana', host: 'PC-ANA' });
    await a.enviar('/api/colaboradores', 'PUT', { login: 'ana', cargo: 'Analista', centro_custo: 'TI' });
    const g = await s2.entrar('gestor1', 'senha-gestor-1');
    const lista = (await g.json('/api/colaboradores')).itens;
    const lg = lista.find((x) => x.login === 'ana');
    assert.ok(lg); assert.equal(lg.cargo, undefined); assert.equal(lg.centro_custo, undefined); assert.equal(lg.jornada_horas, undefined);
    const la = (await a.json('/api/colaboradores')).itens.find((x) => x.login === 'ana');
    assert.equal(la.cargo, 'Analista'); assert.equal(la.centro_custo, 'TI');
  } finally { s2.fechar(); }
});

// ---------- 2FA cifrado e token por maquina ----------

test('2FA: o segredo e guardado cifrado, o que estava em texto e cifrado na migracao e o login continua funcionando', opt, () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tfa-'));
  const r = phpEscala(PHP_ESCALA_BASE(path.join(tmp, 'd')) + `
    $db = abrirBanco($cfg);
    $db->prepare("INSERT INTO usuarios (login, nome, senha_hash, papel, ativo, criado_em, totp_secret, totp_ativo) VALUES ('ana','Ana','x','admin',1,1,'JBSWY3DPEHPK3PXP',1)")->execute();
    $db->exec('PRAGMA user_version = 17');
    $db2 = abrirBanco($cfg);
    $g = $db2->query("SELECT totp_secret FROM usuarios WHERE login = 'ana'")->fetchColumn();
    echo substr($g, 0, 3), '|', (strpos($g, 'JBSWY3DP') === false ? 'oculto' : 'visivel'), '|', totpSegredoLer($cfg, $g), '|', totpSegredoLer($cfg, 'ABCDEFGH23456723');`);
  assert.equal(r, 'e1:|oculto|JBSWY3DPEHPK3PXP|ABCDEFGH23456723');
  fs.rmSync(tmp, { recursive: true, force: true });
});

test('PHP 2FA: ativar e entrar com codigo funcionam com o segredo cifrado no banco', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    const ini = await (await a.enviar('/api/2fa/iniciar', 'POST', {})).json();
    assert.equal((await a.enviar('/api/2fa/ativar', 'POST', { codigo: totp(ini.segredo) })).status, 200);
    const banco = phpEscala(PHP_ESCALA_BASE(s.dados) + `$db = abrirBanco($cfg); $g = $db->query("SELECT totp_secret FROM usuarios WHERE login='admin'")->fetchColumn(); echo substr($g,0,3), strpos($g, '${ini.segredo}') === false ? '|oculto' : '|VISIVEL';`);
    assert.equal(banco, 'e1:|oculto');
    const b = await s.req('/api/login', { metodo: 'POST', corpo: { login: 'admin', senha: SENHA } });
    assert.equal((await b.json()).precisa_2fa, true);
  } finally { s.fechar(); }
});

test('PHP agents: token de cadastro troca por token da maquina, que so vale para o proprio host', opt, async () => {
  const s = await subir();
  try {
    const reg = (tok, host) => s.req('/api/agente/registrar', { metodo: 'POST', headers: { Authorization: 'Bearer ' + tok }, corpo: { host } });
    assert.equal((await reg('errado', 'PC-A')).status, 401);
    const r = await (await reg(TOKEN, 'pc-a')).json();
    assert.match(r.token, /^ppm_[0-9a-f]{48}$/);
    assert.equal((await reg(r.token, 'PC-A')).status, 401);                       // token de maquina nao cadastra
    const H = { Authorization: 'Bearer ' + r.token };
    assert.equal((await post(s, { host: 'PC-A' }, H)).status, 200);               // proprio host (sem diferenciar maiusculas)
    assert.equal((await post(s, { host: 'PC-B' }, H)).status, 403);               // outro host
    assert.equal((await s.req('/api/batimento/politica?host=PC-B', { headers: H })).status, 403);
    assert.equal((await s.req('/api/batimento/politica?host=PC-A', { headers: H })).status, 200);
    assert.equal((await s.req('/api/config/unidades', { headers: H })).status, 200);
    assert.equal((await s.req('/api/foco', { metodo: 'POST', headers: H, corpo: { host: 'PC-B', itens: [] } })).status, 403);
    // enquanto o cadastro vale, o token antigo continua enviando por qualquer host
    assert.equal((await post(s, { host: 'PC-B', versao_agente: '1.4.9' })).status, 200);
    const a = await s.entrar();
    const antes = await a.json('/api/agentes/tokens');
    assert.equal(antes.registradas, 1); assert.equal(antes.cadastro_permitido, true);
    assert.deepEqual(antes.sem_token.map((x) => x.host), ['PC-B']);
    // desliga o token de cadastro para envio
    assert.equal((await a.enviar('/api/agentes/tokens/cadastro', 'PUT', { permitir: false })).status, 200);
    assert.equal((await post(s, { host: 'PC-B' })).status, 401);
    assert.equal((await post(s, { host: 'PC-A' }, H)).status, 200);
    assert.equal((await s.req('/api/agente/versao', { headers: AUTH_AGENTE })).status !== 401, true);  // recuperacao: o cadastro ainda le a versao
    assert.equal((await reg(TOKEN, 'PC-A')).status, 409);                          // nao rouba o token de quem ja tem
    assert.equal((await reg(TOKEN, 'PC-C')).status, 200);                          // maquina nova ainda cadastra
    assert.equal((await a.enviar('/api/agentes/tokens?host=PC-A', 'DELETE')).status, 200);
    assert.equal((await post(s, { host: 'PC-A' }, H)).status, 401);                // liberado: o token antigo morreu
    assert.equal((await reg(TOKEN, 'PC-A')).status, 200);
    const g = await s.entrar('admin', SENHA, true);
    assert.equal((await g.enviar('/api/agentes/tokens/cadastro', 'PUT', { permitir: true })).status, 403); // pede senha de novo
  } finally { s.fechar(); }
});

// ---------- politica de senha e 2FA de administrador por padrao ----------

test('PHP senha: minimo de 12 caracteres, sem o proprio login, sem senhas comuns nem repetitivas', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    const troca = async (nova) => a.enviar('/api/senha', 'POST', { atual: SENHA, nova });
    const msg = async (r) => (await r.json()).erro;
    let r = await troca('curta-demais'.slice(0, 11));  assert.equal(r.status, 400); assert.match(await msg(r), /12 caracteres/);
    r = await troca('aaaaaaaaaaaaaaaa');               assert.equal(r.status, 400); assert.match(await msg(r), /repetitiva/);
    r = await troca('Senha12345678');                  assert.equal(r.status, 400); assert.match(await msg(r), /comum/);
    r = await troca('xx-admin-xx-yy');                 assert.equal(r.status, 400); assert.match(await msg(r), /nome de usuário/);
    const novo = await a.enviar('/api/usuarios', 'POST', { login: 'maria.s', senha: 'maria.s-1234567', papel: 'gestor' });
    assert.equal(novo.status, 400); assert.match(await msg(novo), /nome de usuário/);
    assert.equal((await a.enviar('/api/usuarios', 'POST', { login: 'maria.s', senha: 'cafe-com-leite-9', papel: 'gestor' })).status, 200);
    assert.equal((await troca('uma-frase-bem-longa-42')).status, 200);
  } finally { s.fechar(); }
});

test('PHP 2FA: por padrao os administradores precisam ativar o 2FA (gestor nao)', opt, async () => {
  const s = await subir({ padrao2fa: true });
  try {
    const a = await s.entrar('admin', SENHA, true);
    assert.equal((await a.json('/api/eu')).precisa_configurar_2fa, true);
    assert.equal((await a.get('/api/estado')).status, 403);
  } finally { s.fechar(); }
});

// ---------- instantaneo diario do banco ----------

test('backup: o primeiro envio do dia gera o instantaneo sozinho, consistente, e o admin ve a situacao', opt, async () => {
  const s = await subir();
  try {
    assert.equal((await post(s, { host: 'PC-B1' })).status, 200);
    assert.equal((await post(s, { host: 'PC-B2' })).status, 200);
    await new Promise((r) => setTimeout(r, 700));
    const a = await s.entrar();
    const i = await a.json('/api/backup');
    assert.equal(i.ligado, true); assert.equal(i.existe, true); assert.ok(i.tamanho > 0); assert.ok(i.gerado_em > 0); assert.match(i.ultimo_estado, /^ok:/);
    const n = phpEscala(PHP_ESCALA_BASE(s.dados) + `$d = new PDO('sqlite:' . $cfg['dados_dir'] . '/backup/presenca-snapshot.sqlite'); echo (int)$d->query('SELECT COUNT(*) FROM registros')->fetchColumn(), '|', $d->query('PRAGMA integrity_check')->fetchColumn(), '|', is_file($cfg['dados_dir'] . '/backup/presenca-snapshot.sqlite.tmp') ? 'tmp' : 'limpo';`);
    assert.match(n, /^[12]\|ok\|limpo$/);
    assert.equal((await a.get('/api/backup')).status, 200);
    const g = await s.entrar('admin', SENHA, true);
    assert.equal((await g.enviar('/api/backup/gerar', 'POST', {})).status, 403);   // pede a senha de novo
  } finally { s.fechar(); }
});

test('backup: gerar agora funciona e a copia nao e feita sem espaco ou com banco acima do limite', opt, async () => {
  const s = await subir({ extra: "'backup_snapshot' => false," });
  try {
    await post(s, { host: 'PC-B1' });
    await new Promise((r) => setTimeout(r, 400));
    const a = await s.entrar();
    assert.equal((await a.json('/api/backup')).existe, false);      // desligado: nao gera sozinho
    const r = await a.enviar('/api/backup/gerar', 'POST', {});
    assert.equal(r.status, 200); const j = await r.json(); assert.equal(j.ok, true); assert.equal(j.existe, true);
  } finally { s.fechar(); }
  const s2 = await subir({ extra: "'backup_snapshot' => false, 'backup_max_mb' => 0.0001," });
  try {
    await post(s2, { host: 'PC-B1' });
    const a = await s2.entrar();
    const r = await a.enviar('/api/backup/gerar', 'POST', {});
    assert.equal(r.status, 500); assert.match((await r.json()).motivo, /maior que/);
    assert.equal((await a.json('/api/backup')).existe, false);
  } finally { s2.fechar(); }
});

// ---------- alertas por e-mail ----------

const arquivoAlertas = () => path.join(os.tmpdir(), 'alertas-' + Math.random().toString(36).slice(2) + '.jsonl');
const lerAlertas = (f) => (fs.existsSync(f) ? fs.readFileSync(f, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);

test('alertas: configuracao so pelo admin com senha de novo, e-mail validado e envio de teste', opt, async () => {
  const f = arquivoAlertas();
  const s = await subir({ extra: `'alerta_arquivo' => '${q(f)}',` });
  try {
    const a = await s.entrar();
    assert.deepEqual(await a.json('/api/alertas'), { email: '', ativo: false });
    assert.equal((await a.enviar('/api/alertas', 'PUT', { email: 'sem-arroba', ativo: true })).status, 400);
    assert.equal((await a.enviar('/api/alertas', 'PUT', { email: 'a@b.com\nBcc: x@y.com', ativo: true })).status, 400);   // injecao de cabecalho
    assert.equal((await a.enviar('/api/alertas', 'PUT', { email: '', ativo: true })).status, 400);
    assert.equal((await a.enviar('/api/alertas/teste', 'POST', {})).status, 500);            // sem e-mail salvo: nao envia
    assert.equal((await a.enviar('/api/alertas', 'PUT', { email: 'admin@exemplo.com', ativo: true })).status, 200);
    assert.deepEqual(await a.json('/api/alertas'), { email: 'admin@exemplo.com', ativo: true });
    assert.equal((await a.enviar('/api/alertas/teste', 'POST', {})).status, 200);
    const l = lerAlertas(f); assert.equal(l.length, 1); assert.equal(l[0].para, 'admin@exemplo.com'); assert.match(l[0].assunto, /Teste de alerta/);
    const g = await s.entrar('admin', SENHA, true);
    assert.equal((await g.enviar('/api/alertas', 'PUT', { email: 'x@y.com', ativo: true })).status, 403);   // pede a senha de novo
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor9', senha: 'senha-gestor-9-ok', papel: 'gestor' });
    const ge = await s.entrar('gestor9', 'senha-gestor-9-ok');
    assert.equal((await ge.get('/api/alertas')).status, 403);
  } finally { s.fechar(); fs.rmSync(f, { force: true }); }
});

test('alertas: falhas de login em sequencia avisam uma vez por hora e sem dados sensiveis', opt, async () => {
  const f = arquivoAlertas();
  const s = await subir({ extra: `'alerta_arquivo' => '${q(f)}',` });
  try {
    const a = await s.entrar();
    await a.enviar('/api/alertas', 'PUT', { email: 'admin@exemplo.com', ativo: true });
    for (let i = 0; i < 6; i++) await loginRaw(s, 'admin', 'errada-' + i);
    await loginRaw(s, 'admin', 'errada-x');
    const l = lerAlertas(f).filter((x) => /login/i.test(x.assunto));
    assert.equal(l.length, 1);
    assert.match(l[0].texto, /IP: /); assert.match(l[0].texto, /admin/);
    assert.ok(!l[0].texto.includes('errada-'), 'a senha tentada nao pode ir no e-mail');
  } finally { s.fechar(); fs.rmSync(f, { force: true }); }
});

test('alertas: queda no envio em horario de expediente avisa; fora do expediente ou com poucos PCs, nao', opt, async () => {
  const f = arquivoAlertas();
  const s = await subir({ agora: AGORA, extra: `'alerta_arquivo' => '${q(f)}',` });
  try {
    const em = (host, minAtras) => post(s, { host, usuario: 'DOM\\u' + host, data_hora: new Date(AGORA - minAtras * 60000).toISOString() });
    for (let i = 1; i <= 12; i++) assert.equal((await em('PCQ' + i, 60)).status, 200);   // 12 PCs enviaram ha 1 h
    assert.equal((await em('PCQ1', 5)).status, 200);                                       // so 1 continua
    const a = await s.entrar();
    await a.enviar('/api/alertas', 'PUT', { email: 'admin@exemplo.com', ativo: true });
    assert.equal((await em('PCQ2', 4)).status, 200);                                       // dispara a verificacao (2 de 12)
    const l = lerAlertas(f).filter((x) => /Queda/.test(x.assunto));
    assert.equal(l.length, 1); assert.match(l[0].texto, /2 PC\(s\)/); assert.match(l[0].texto, /12 nas/);
    assert.equal((await em('PCQ3', 3)).status, 200);                                       // intervalo minimo: nao repete
    assert.equal(lerAlertas(f).filter((x) => /Queda/.test(x.assunto)).length, 1);
  } finally { s.fechar(); fs.rmSync(f, { force: true }); }
  // fora do expediente (sabado) nao avisa
  const f2 = arquivoAlertas();
  const SAB = Date.parse('2026-03-07T15:00:00Z');
  const s2 = await subir({ agora: SAB, extra: `'alerta_arquivo' => '${q(f2)}',` });
  try {
    const em = (host, minAtras) => post(s2, { host, usuario: 'DOM\\u' + host, data_hora: new Date(SAB - minAtras * 60000).toISOString() });
    for (let i = 1; i <= 12; i++) await em('PCS' + i, 60);
    const a = await s2.entrar();
    await a.enviar('/api/alertas', 'PUT', { email: 'admin@exemplo.com', ativo: true });
    await em('PCS1', 4);
    assert.equal(lerAlertas(f2).length, 0);
  } finally { s2.fechar(); fs.rmSync(f2, { force: true }); }
});

test('PHP relatorio individual: mesmo modelo, comparado com o escritorio, com tempo por site e programa, so admin', opt, async () => {
  const s = await subir({ agora: AGORA });
  try {
    const horas = (n) => Array.from({ length: n }, (_, i) => `${String(9 + Math.floor(i * 5 / 60)).padStart(2, '0')}:${String(i * 5 % 60).padStart(2, '0')}`);
    const dia = async (login, nome, data, remoto, github, youtube) => {
      const base = { host: 'PC-' + login.toUpperCase(), usuario: 'CORP\\' + login, nome_completo: nome };
      await enviarLeituras(s, horas(14).map((hh) => leitura(data, hh, { ...base, ...(remoto ? { resultado: 'Remoto', unidade: '' } : {}) })));
      const ts = Date.parse(`${data}T12:00:00-03:00`);
      await nav(s, [visita('https://github.com/x', 0, { ts, duracao_seg: github }), visita('https://www.youtube.com/w', 0, { ts: ts + 1000, duracao_seg: youtube })], base);
      await foco(s, [seg(ts, 'WINWORD', 900), seg(ts + 900000, 'steam', 300), seg(ts + 1200000, 'chrome', 600)], base);
    };
    for (const d of ['2026-03-02', '2026-03-03', '2026-03-04']) await dia('ana', 'Ana Souza', d, false, 1200, 400);
    for (const d of ['2026-03-05', '2026-03-06']) await dia('ana', 'Ana Souza', d, true, 1200, 400);
    for (const d of ['2026-03-02', '2026-03-03', '2026-03-04', '2026-03-05', '2026-03-06']) await dia('bruno', 'Bruno Lima', d, false, 400, 1200);
    const a = await s.entrar();
    await a.enviar('/api/colaboradores/importar-rh', 'POST', { linhas: [{ login: 'ana', cargo: 'ADVOGADO', centro_custo: 'BANCO PAN', jornada: '6:00' }] });

    const r = await a.json('/api/relatorio?tipo=semanal&data=2026-03-04&login=ana');
    assert.equal(r.tipo, 'individual'); assert.equal(r.titulo, 'RELATÓRIO INDIVIDUAL DE PRODUTIVIDADE');
    assert.match(r.subtitulo, /ANA SOUZA/);
    assert.deepEqual([r.pessoa.nome, r.pessoa.cargo, r.pessoa.centro_custo, r.pessoa.jornada_horas], ['ANA SOUZA', 'ADVOGADO', 'BANCO PAN', 6]);
    assert.equal(r.kpis.dias_registro, 5); assert.equal(r.kpis.score, 75);
    assert.ok(r.kpis.score_escritorio < 75, 'o escritorio inclui o Bruno (46,4)');
    const sc = r.indicadores.find((x) => x.indicador === 'Score de produtividade');
    assert.equal(sc.valor, '75,0'); assert.equal(sc.atingida, false); assert.ok(sc.escritorio !== '-');
    assert.equal(r.classificacao.faixa, 'BOM');
    assert.deepEqual(r.modalidade.map((m) => [m.modalidade, m.registros]), [['Presencial', 3], ['Remoto (home)', 2]]);
    assert.equal(r.dia_semana.length, 5); assert.equal(r.diario.length, 5); assert.equal(r.diario[0].dia, '2026-03-02');
    assert.equal(r.diario[0].modalidade, 'Presencial'); assert.equal(r.diario[4].modalidade, 'Remoto');
    // onde o tempo foi: so da Ana (nao mistura com o Bruno)
    assert.equal(r.tempo.sites.find((x) => x.nome === 'github.com').categoria, 'produtivo');
    assert.equal(r.tempo.sites.find((x) => x.nome === 'github.com').seg, 6000);
    assert.equal(r.tempo.sites.find((x) => x.nome === 'youtube.com').categoria, 'improdutivo');
    assert.ok(r.tempo.programas.length >= 2); assert.ok(!r.tempo.programas.some((x) => /chrome/i.test(x.nome)), 'o navegador conta pelos sites');
    assert.equal(r.tempo.categorias.produtivo_seg, 5 * 2100);
    assert.equal(r.posicao, null, 'menos de 5 colaboradores com 5 dias: nao ha posicao');
    assert.ok(r.achados.some((x) => /média do escritório/.test(x))); assert.ok(r.recomendacoes[0].titulo === 'Como ler este relatório');
    assert.ok(r.recomendacoes.some((x) => x.titulo === 'Score abaixo da meta'));
    // mensal e periodo tambem; login em maiuscula e dominio\login funcionam
    assert.equal((await a.json('/api/relatorio?tipo=mensal&mes=2026-03&login=CORP%5Cana')).kpis.dias_registro, 5);
    assert.equal((await a.json('/api/relatorio?tipo=personalizado&de=2026-03-02&ate=2026-03-04&login=ana')).kpis.dias_registro, 3);
    // sem dados no periodo, pessoa inexistente e perfil gestor
    assert.equal((await a.json('/api/relatorio?tipo=mensal&mes=2026-02&login=ana')).sem_dados, true);
    assert.equal((await a.get('/api/relatorio?tipo=mensal&mes=2026-03&login=ninguem')).status, 404);
    await a.enviar('/api/usuarios', 'POST', { login: 'gestor8', senha: 'senha-gestor-8-ok', papel: 'gestor' });
    const g = await s.entrar('gestor8', 'senha-gestor-8-ok');
    assert.equal((await g.get('/api/relatorio?tipo=mensal&mes=2026-03&login=ana')).status, 403);
    // fica na auditoria com a pessoa consultada
    const aud = (await a.json('/api/auditoria?evento=relatorio')).itens;
    assert.ok(aud.some((x) => /individual ana/.test(x.detalhe)));
    // o relatorio geral continua igual
    assert.equal((await a.json('/api/relatorio?tipo=semanal&data=2026-03-04')).tipo, 'semanal');
  } finally { s.fechar(); }
});

// ---------- instalacao de software (pacotes assinados + tarefas por maquina) ----------
const crypto = require('node:crypto');

function novoPacote(conteudo, extra = {}) {
  const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const m = { v: 2, pid: crypto.randomBytes(16).toString('hex'), nome: 'Leitor de PDF', tipo: 'msi', arquivo: 'leitor.msi',
    sha256: crypto.createHash('sha256').update(conteudo).digest('hex'), tamanho: conteudo.length, args: '/qn /norestart', criado: Date.now(), ...extra };
  const manifesto = JSON.stringify(m);
  const assinatura = crypto.sign('sha256', Buffer.from(manifesto), privateKey).toString('base64');
  return { m, manifesto, assinatura };
}

async function tokenMaquina(s, host) {
  const r = await s.req('/api/agente/registrar', { metodo: 'POST', headers: { Authorization: 'Bearer ' + TOKEN }, corpo: { host } });
  return (await r.json()).token;
}

test('PHP software: do cadastro ao resultado, cada maquina so ve e baixa o que e dela', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    const conteudo = Buffer.from('MZ-instalador-de-mentira-'.repeat(200));
    const p = novoPacote(conteudo);
    assert.equal((await a.enviar('/api/software', 'POST', { manifesto: p.manifesto, assinatura: p.assinatura })).status, 200);
    assert.equal((await a.enviar('/api/software', 'POST', { manifesto: p.manifesto, assinatura: p.assinatura })).status, 409, 'pid repetido');
    // sem o arquivo ainda: nao instala
    assert.equal((await a.enviar('/api/software/instalar', 'POST', { pid: p.m.pid, hosts: ['PC-A'] })).status, 409);
    // arquivo trocado: recusa
    const put = (corpo) => s.req('/api/software/arquivo?pid=' + p.m.pid, { metodo: 'PUT', headers: { Cookie: a.cookie, 'X-CSRF-Token': a.eu.csrf, 'Content-Type': 'application/octet-stream' }, corpo });
    assert.equal((await put(Buffer.concat([conteudo.subarray(0, 100), Buffer.from('x'), conteudo.subarray(101)]))).status, 400);
    assert.equal((await put(conteudo.subarray(0, 50))).status, 400, 'incompleto');
    { const rp = await put(conteudo); assert.equal(rp.status, 200, await rp.text()); }
    const lista = await a.json('/api/software');
    assert.equal(lista.pacotes.length, 1);
    assert.equal(lista.pacotes[0].arquivo_ok, true);
    // disparo
    const ta = await tokenMaquina(s, 'pc-a'); const tb = await tokenMaquina(s, 'pc-b');
    const ag = (tok) => ({ Authorization: 'Bearer ' + tok });
    const r1 = await (await a.enviar('/api/software/instalar', 'POST', { pid: p.m.pid, hosts: ['pc-a', 'PC-B', 'PC-A'] })).json();
    assert.equal(r1.criadas, 2);
    assert.equal((await (await a.enviar('/api/software/instalar', 'POST', { pid: p.m.pid, hosts: ['PC-A'] })).json()).ignoradas, 1, 'nao duplica tarefa em aberto');
    // o agent de PC-A ve so a dele, com manifesto e assinatura exatamente como foram cadastrados
    const t = await (await s.req('/api/agente/tarefas?host=PC-A', { headers: ag(ta) })).json();
    assert.equal(t.tarefas.length, 1);
    assert.equal(t.tarefas[0].manifesto, p.manifesto);
    assert.equal(t.tarefas[0].assinatura, p.assinatura);
    assert.equal((await s.req('/api/agente/tarefas?host=PC-A', { headers: ag(tb) })).status, 403, 'token de outra maquina');
    assert.equal((await s.req('/api/agente/tarefas?host=PC-A', { headers: AUTH_AGENTE })).status, 403, 'token de cadastro nao executa nada');
    // download: so quem tem tarefa em aberto do pacote
    const dl = await s.req(`/api/agente/software?pid=${p.m.pid}&host=PC-A`, { headers: ag(ta) });
    assert.equal(dl.status, 200);
    assert.equal(Buffer.from(await dl.arrayBuffer()).compare(conteudo), 0);
    const tc = await tokenMaquina(s, 'pc-c');
    assert.equal((await s.req(`/api/agente/software?pid=${p.m.pid}&host=PC-C`, { headers: ag(tc) })).status, 404);
    // resultado: reserva antes, uma vez so
    const id = t.tarefas[0].id;
    const res = (tok, host, corpo) => s.req('/api/agente/tarefas/resultado', { metodo: 'POST', headers: ag(tok), corpo: { host, id, ...corpo } });
    assert.equal((await res(ta, 'PC-A', { estado: 'ok', codigo: 0 })).status, 409, 'sem reservar');
    assert.equal((await res(tb, 'PC-B', { estado: 'executando' })).status, 409, 'tarefa de outra maquina');
    assert.equal((await res(ta, 'PC-A', { estado: 'executando' })).status, 200);
    assert.equal((await res(ta, 'PC-A', { estado: 'executando' })).status, 409, 'outra rodada nao pega de novo');
    assert.equal((await (await s.req('/api/agente/tarefas?host=PC-A', { headers: ag(ta) })).json()).tarefas.length, 0, 'em execucao nao volta para a fila');
    assert.equal((await res(ta, 'PC-A', { estado: 'ok', codigo: 3010, saida: 'reinicio pendente' })).status, 200);
    const tar = (await a.json('/api/software/tarefas')).tarefas;
    const feita = tar.find((x) => x.id === id);
    assert.equal(feita.estado, 'ok'); assert.equal(feita.codigo, 3010); assert.equal(feita.host, 'PC-A');
    assert.equal((await a.enviar('/api/software/tarefas/repetir', 'POST', { id })).status, 409, 'so repete o que falhou');
    // auditoria
    const aud = JSON.stringify(await a.json('/api/auditoria'));
    for (const ev of ['software_cadastrado', 'software_arquivo', 'software_instalar']) assert.ok(aud.includes(ev), ev);
  } finally { s.fechar(); }
});

test('PHP software: validacao do manifesto, reautenticacao, cancelar, repetir e excluir', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    const conteudo = Buffer.from('x'.repeat(500));
    const criar = (m, ass) => a.enviar('/api/software', 'POST', { manifesto: JSON.stringify(m), assinatura: ass });
    const base = novoPacote(conteudo);
    const ass = base.assinatura;
    for (const mau of [{ tipo: 'dll' }, { sha256: 'xyz' }, { tamanho: 0 }, { tamanho: 999999999999 }, { pid: '1234' }, { nome: '' }, { arquivo: '..\\x.msi' }, { arquivo: 'a/b.msi' }, { v: 1 }, { args: 'x'.repeat(1001) }]) {
      assert.equal((await criar({ ...base.m, ...mau }, ass)).status, 400, JSON.stringify(mau).slice(0, 40));
    }
    assert.equal((await criar(base.m, 'curta')).status, 400, 'assinatura invalida');
    assert.equal((await a.enviar('/api/software', 'POST', { manifesto: 'nao e json', assinatura: ass })).status, 400);
    // sem reconfirmar a senha: nao cadastra nem dispara
    const b = await s.entrar('admin', SENHA, true);
    const r = await b.enviar('/api/software', 'POST', { manifesto: base.manifesto, assinatura: ass });
    assert.equal(r.status, 403); assert.equal((await r.json()).precisa_reautenticar, true);
    // fluxo: cadastra, envia, dispara, cancela, repete, falha, repete, exclui
    assert.equal((await a.enviar('/api/software', 'POST', { manifesto: base.manifesto, assinatura: ass })).status, 200);
    await s.req('/api/software/arquivo?pid=' + base.m.pid, { metodo: 'PUT', headers: { Cookie: a.cookie, 'X-CSRF-Token': a.eu.csrf }, corpo: conteudo });
    await a.enviar('/api/software/instalar', 'POST', { pid: base.m.pid, hosts: ['PC-A'] });
    let tar = (await a.json('/api/software/tarefas')).tarefas;
    assert.equal(tar.length, 1);
    assert.equal((await a.enviar('/api/software/tarefas/cancelar', 'POST', { id: tar[0].id })).status, 200);
    assert.equal((await a.enviar('/api/software/tarefas/cancelar', 'POST', { id: tar[0].id })).status, 409);
    assert.equal((await a.enviar('/api/software/tarefas/repetir', 'POST', { id: tar[0].id })).status, 200);
    const ta = await tokenMaquina(s, 'PC-A');
    const h = { Authorization: 'Bearer ' + ta };
    const id = tar[0].id;
    await s.req('/api/agente/tarefas/resultado', { metodo: 'POST', headers: h, corpo: { host: 'PC-A', id, estado: 'executando' } });
    await s.req('/api/agente/tarefas/resultado', { metodo: 'POST', headers: h, corpo: { host: 'PC-A', id, estado: 'falhou', codigo: 1603, saida: 'x'.repeat(5000) } });
    tar = (await a.json('/api/software/tarefas')).tarefas;
    assert.equal(tar[0].estado, 'falhou'); assert.equal(tar[0].saida.length, 4000, 'saida limitada');
    assert.equal((await a.enviar('/api/software/tarefas/repetir', 'POST', { id })).status, 200);
    assert.equal((await a.json('/api/software/tarefas')).tarefas[0].estado, 'pendente');
    assert.equal((await a.enviar('/api/software?pid=' + base.m.pid, 'DELETE')).status, 200);
    assert.equal((await a.json('/api/software')).pacotes.length, 0);
    assert.equal((await a.json('/api/software/tarefas')).tarefas.length, 0);
    assert.equal((await s.req(`/api/agente/software?pid=${base.m.pid}&host=PC-A`, { headers: h })).status, 404);
  } finally { s.fechar(); }
});

test('painel: a tela de software existe, carrega o script e assina com WebCrypto sem guardar a chave', () => {
  const pub = path.join(WEB, '_app', 'public');
  const html = fs.readFileSync(path.join(pub, 'index.html'), 'utf8');
  assert.match(html, /<script src="software\.js"><\/script>/);
  const js = fs.readFileSync(path.join(pub, 'software.js'), 'utf8');
  assert.match(js, /RSASSA-PKCS1-v1_5/);
  assert.match(js, /ext: false/, 'chave nao exportavel');
  assert.doesNotMatch(js, /localStorage|sessionStorage|indexedDB/, 'a chave nunca vai para o armazenamento do navegador');
});

// ---------- v20: zip, gatilho, desinstalacao e politica automatica ----------
function zipMinimo(arqs) {   // zip valido, sem compressao (so para testar)
  const partes = [], cd = []; let off = 0; const nomes = Object.keys(arqs);
  for (const nome of nomes) {
    const n = Buffer.from(nome), dados = Buffer.from(arqs[nome]), crc = require('node:zlib').crc32(dados);
    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0); lh.writeUInt16LE(20, 4); lh.writeUInt16LE(0x21, 12); lh.writeUInt32LE(crc, 14);
    lh.writeUInt32LE(dados.length, 18); lh.writeUInt32LE(dados.length, 22); lh.writeUInt16LE(n.length, 26);
    partes.push(lh, n, dados);
    const ch = Buffer.alloc(46);
    ch.writeUInt32LE(0x02014b50, 0); ch.writeUInt16LE(20, 4); ch.writeUInt16LE(20, 6); ch.writeUInt16LE(0x21, 14); ch.writeUInt32LE(crc, 16);
    ch.writeUInt32LE(dados.length, 20); ch.writeUInt32LE(dados.length, 24); ch.writeUInt16LE(n.length, 28); ch.writeUInt32LE(off, 42);
    cd.push(ch, n); off += 30 + n.length + dados.length;
  }
  const cdb = Buffer.concat(cd), eo = Buffer.alloc(22);
  eo.writeUInt32LE(0x06054b50, 0); eo.writeUInt16LE(nomes.length, 8); eo.writeUInt16LE(nomes.length, 10); eo.writeUInt32LE(cdb.length, 12); eo.writeUInt32LE(off, 16);
  return Buffer.concat([...partes, cdb, eo]);
}
const temZipPhp = temPhp && spawnSync('php', ['-r', 'echo class_exists("ZipArchive") ? 1 : 0;']).stdout.toString() === '1';

test('PHP software v2: manifesto com zip, gatilho e desinstalacao validado no servidor', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    const zip = zipMinimo({ 'installer/instalar.cmd': '@exit /b 0', 'installer/remover.cmd': '@exit /b 0', 'installer/config/Escritorio.ovpn': 'client' });
    const ok = { tipo: 'zip', arquivo: 'pacote.zip', executavel: 'installer/instalar.cmd', args: '' };
    const base = novoPacote(zip, ok);
    const assin = base.assinatura;
    const criar = (m) => a.enviar('/api/software', 'POST', { manifesto: JSON.stringify(m), assinatura: assin });
    for (const mau of [{ executavel: '' }, { executavel: '../a.cmd' }, { executavel: 'C:/a.cmd' }, { executavel: 'a/b.dll' }, { executavel: 'a\\b.cmd' }, { arquivo: 'pacote.msi' },
      { gatilho: '..\\x.exe' }, { gatilho: 'app.exe' }, { gatilho: '[programfiles]\\A\\*.exe' }, { gatilho: '\\\\srv\\x\\a.exe' },
      { desinstalar: { modo: 'formatar' } }, { desinstalar: { modo: 'msi', codigo: 'x' } }, { desinstalar: { modo: 'nome', software: '' } },
      { desinstalar: { modo: 'script', arquivo: 'installer/remover.exe' } }, { descricao: 'x'.repeat(301) }]) {
      assert.equal((await criar({ ...base.m, ...mau })).status, 400, JSON.stringify(mau).slice(0, 60));
    }
    assert.equal((await criar({ ...base.m, tipo: 'msi', arquivo: 'a.msi' })).status, 400, 'executavel so vale para zip');
    for (const bom of [{ gatilho: '[programfiles]\\App\\app.exe', descricao: 'Perfil do escritorio' },
      { desinstalar: { modo: 'script', arquivo: 'installer/remover.cmd' } }, { desinstalar: { modo: 'nome', software: 'OpenVPN' } },
      { desinstalar: { modo: 'msi', codigo: '{6B1F2D4E-1A2B-4C3D-8E9F-0123456789AB}', args: '/qn' } }]) {
      const m = { ...base.m, ...bom, pid: crypto.randomBytes(16).toString('hex') };
      assert.equal((await criar(m)).status, 200, JSON.stringify(bom).slice(0, 60));
    }
    // o zip enviado confere (nomes e arquivo a executar) quando a extensao zip do PHP existe
    const put = (pid, corpo) => s.req('/api/software/arquivo?pid=' + pid, { metodo: 'PUT', headers: { Cookie: a.cookie, 'X-CSRF-Token': a.eu.csrf, 'Content-Type': 'application/octet-stream' }, corpo });
    assert.equal((await a.enviar('/api/software', 'POST', { manifesto: base.manifesto, assinatura: base.assinatura })).status, 200);
    assert.equal((await put(base.m.pid, zip)).status, 200);
    if (temZipPhp) {
      const ruim = zipMinimo({ 'installer/instalar.cmd': '@exit /b 0', '../fora.txt': 'x' });
      const pr = novoPacote(ruim, ok);
      assert.equal((await a.enviar('/api/software', 'POST', { manifesto: pr.manifesto, assinatura: pr.assinatura })).status, 200);
      assert.equal((await put(pr.m.pid, ruim)).status, 400, 'nome perigoso no zip');
      const falta = zipMinimo({ 'outro.cmd': '@exit /b 0' });
      const pf = novoPacote(falta, ok);
      await a.enviar('/api/software', 'POST', { manifesto: pf.manifesto, assinatura: pf.assinatura });
      assert.equal((await put(pf.m.pid, falta)).status, 400, 'executavel ausente no zip');
    }
  } finally { s.fechar(); }
});

test('PHP software v2: desinstalar so existe se foi assinado, e a politica automatica cria a tarefa por maquina', opt, async () => {
  const s = await subir();
  try {
    const a = await s.entrar();
    const zip = zipMinimo({ 'instalar.cmd': '@exit /b 0', 'remover.cmd': '@exit /b 0' });
    const put = (pid, corpo) => s.req('/api/software/arquivo?pid=' + pid, { metodo: 'PUT', headers: { Cookie: a.cookie, 'X-CSRF-Token': a.eu.csrf, 'Content-Type': 'application/octet-stream' }, corpo });
    const novo = async (extra) => {
      const p = novoPacote(zip, { tipo: 'zip', arquivo: 'p.zip', executavel: 'instalar.cmd', args: '', ...extra });
      assert.equal((await a.enviar('/api/software', 'POST', { manifesto: p.manifesto, assinatura: p.assinatura })).status, 200);
      assert.equal((await put(p.m.pid, zip)).status, 200);
      return p;
    };
    const semDes = await novo({ nome: 'Sem desinstalar' });
    const comDes = await novo({ nome: 'Com desinstalar', desinstalar: { modo: 'script', arquivo: 'remover.cmd' } });
    const ag = (t) => ({ Authorization: 'Bearer ' + t });
    const ta = await tokenMaquina(s, 'mtz100');
    // desinstalar sem estar assinado no pacote: recusa
    assert.equal((await a.enviar('/api/software/instalar', 'POST', { pid: semDes.m.pid, hosts: ['MTZ100'], acao: 'desinstalar' })).status, 409);
    assert.equal((await a.enviar('/api/software/instalar', 'POST', { pid: comDes.m.pid, hosts: ['MTZ100'], acao: 'formatar' })).status, 400);
    assert.equal((await a.enviar('/api/software/instalar', 'POST', { pid: comDes.m.pid, hosts: ['MTZ100'], acao: 'desinstalar' })).status, 200);
    const t1 = (await (await s.req('/api/agente/tarefas?host=MTZ100', { headers: ag(ta) })).json()).tarefas;
    assert.equal(t1.length, 1); assert.equal(t1[0].acao, 'desinstalar'); assert.equal(t1[0].manifesto, comDes.manifesto);

    // politica automatica: pede senha, valida alvo e arquivo enviado
    const b = await s.entrar('admin', SENHA, true);
    const r = await b.enviar('/api/software/politica', 'POST', { pid: semDes.m.pid, auto: true, alvo: '' });
    assert.equal(r.status, 403);
    const pol = (corpo) => a.enviar('/api/software/politica', 'POST', corpo);
    assert.equal((await pol({ pid: semDes.m.pid, auto: true, alvo: 'MTZ*; $(calc)' })).status, 400, 'alvo invalido');
    assert.equal((await pol({ pid: 'zz', auto: true })).status, 400);
    assert.equal((await pol({ pid: semDes.m.pid, auto: true, alvo: 'MTZ*, NOTE-?' })).status, 200);
    const lista = (await a.json('/api/software')).pacotes.find((x) => x.pid === semDes.m.pid);
    assert.equal(lista.auto, true); assert.equal(lista.alvo, 'MTZ*, NOTE-?');
    // so as maquinas do alvo (e que nao sejam servidores) recebem, uma tarefa por maquina
    await a.enviar('/api/servidores', 'POST', { host: 'MTZSRV', servidor: true });
    const tb = await tokenMaquina(s, 'mtz101'), tc = await tokenMaquina(s, 'pc-zzz'), td = await tokenMaquina(s, 'mtzsrv'), te = await tokenMaquina(s, 'note-1');
    const buscar = async (host, tok) => (await (await s.req('/api/agente/tarefas?host=' + host, { headers: ag(tok) })).json()).tarefas;
    const t2 = await buscar('MTZ101', tb);
    assert.equal(t2.length, 1); assert.equal(t2[0].acao, 'instalar'); assert.equal(t2[0].manifesto, semDes.manifesto);
    assert.equal((await buscar('MTZ101', tb)).length, 1, 'nao duplica');
    assert.equal((await buscar('PC-ZZZ', tc)).length, 0, 'fora do alvo');
    assert.equal((await buscar('MTZSRV', td)).length, 0, 'servidor fica de fora');
    assert.equal((await buscar('NOTE-1', te)).length, 1, 'curinga ?');
    const tarefas = (await a.json('/api/software/tarefas')).tarefas.filter((x) => x.host === 'MTZ101');
    assert.equal(tarefas.length, 1); assert.equal(tarefas[0].criado_por, 'automatico');
    // falhou: nao refaz na hora (espera o intervalo)
    const res = (tok, host, id, corpo) => s.req('/api/agente/tarefas/resultado', { metodo: 'POST', headers: ag(tok), corpo: { host, id, ...corpo } });
    assert.equal((await res(tb, 'MTZ101', t2[0].id, { estado: 'executando' })).status, 200);
    assert.equal((await res(tb, 'MTZ101', t2[0].id, { estado: 'falhou', codigo: 1603, saida: 'erro' })).status, 200);
    assert.equal((await buscar('MTZ101', tb)).length, 0, 'falha recente: espera o intervalo');
    assert.equal((await pol({ pid: semDes.m.pid, auto: false, alvo: '' })).status, 200);
    assert.equal((await buscar('MTZ100', ta)).length, 1, 'a tarefa de desinstalar ainda esta la');
    const aud = JSON.stringify(await a.json('/api/auditoria'));
    for (const ev of ['software_politica', 'software_desinstalar']) assert.ok(aud.includes(ev), ev);
  } finally { s.fechar(); }
});

test('painel: politicas de instalacao no menu Administracao, zip e desinstalacao na tela', () => {
  const pub = path.join(WEB, '_app', 'public');
  const html = fs.readFileSync(path.join(pub, 'index.html'), 'utf8');
  assert.match(html, /<section id="aba-politicas"/);
  assert.match(html, /data-aba="politicas"[^>]*>Políticas de Instalação</);
  for (const id of ['sw-gat', 'sw-des', 'sw-exe', 'sw-pol-auto', 'sw-pol-alvo', 'sw-desc', 'sw-soft']) assert.match(html, new RegExp('id="' + id + '"'), id);
  const js = fs.readFileSync(path.join(pub, 'software.js'), 'utf8');
  assert.match(js, /api\/software\/politica/);
  assert.match(js, /acao: swAlvoAcao/);
  assert.match(js, /0x06054b50/, 'le o diretorio central do zip no navegador');
  assert.match(js, /bin\.charCodeAt\(i\) === 0/, 'tira o zero a esquerda do JWK');
});
