// Administracao > Politicas de Instalacao: cadastro de pacotes (assinados NO NAVEGADOR), envio do arquivo, aplicacao manual ou automatica
// (instalar e desinstalar) e acompanhamento. Um pacote pode ser um arquivo (msi, exe, ps1, cmd, vbs) ou um zip com varios arquivos.
// A chave privada do atualizador (atualizador-privada.xml, formato XML do .NET) e lida aqui, convertida em chave do WebCrypto
// NAO exportavel e guardada so em memoria: nao vai ao servidor, nao vai ao armazenamento do navegador e some ao fechar ou recarregar a pagina.

let swChave = null;      // CryptoKey de assinatura (so memoria)
let swDados = { pacotes: [], maquinas: [], limite_mb: 200 };
let swAlvoPid = null;
let swAlvoAcao = 'instalar';
let swPolPid = null;
let swZipNomes = [];     // arquivos do zip escolhido (lidos aqui no navegador, so para ajudar e validar)

const swTipos = { msi: 'msi', exe: 'exe', ps1: 'ps1', cmd: 'cmd', bat: 'cmd', vbs: 'vbs', zip: 'zip' };
const swExecExt = ['msi', 'exe', 'ps1', 'cmd', 'bat', 'vbs'];
const swDh = (ms) => (ms ? new Date(ms).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : '—');
const swMb = (n) => (n >= 1048576 ? (n / 1048576).toFixed(1).replace('.', ',') + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB');
const swMsg = (t) => { $('sw-msg').textContent = t; };
const swExt = (nome) => (nome.includes('.') ? nome.split('.').pop().toLowerCase() : '');

// WebCrypto recusa zero a esquerda nos campos do JWK; o XML do .NET as vezes traz (preenchimento de sinal). Tira antes de converter.
function b64url(b64) {
  const bin = atob(b64); let i = 0; while (i < bin.length - 1 && bin.charCodeAt(i) === 0) i++;
  return btoa(bin.slice(i)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
const hex = (buf) => [...new Uint8Array(buf)].map((x) => x.toString(16).padStart(2, '0')).join('');
function b64DeBytes(buf) { let s = ''; const u = new Uint8Array(buf); for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]); return btoa(s); }

// Converte o XML do .NET (RSAKeyValue) em chave de assinatura RSASSA-PKCS1-v1_5 / SHA-256 (a mesma que o agent confere).
async function swImportarChave(xmlTexto) {
  const doc = new DOMParser().parseFromString(xmlTexto, 'application/xml');
  const campo = (n) => { const e = doc.getElementsByTagName(n)[0]; return e ? e.textContent.trim() : ''; };
  const jwk = { kty: 'RSA', n: b64url(campo('Modulus')), e: b64url(campo('Exponent')), d: b64url(campo('D')), p: b64url(campo('P')), q: b64url(campo('Q')),
    dp: b64url(campo('DP')), dq: b64url(campo('DQ')), qi: b64url(campo('InverseQ')), ext: false };
  if (!jwk.n || !jwk.d || !jwk.p) throw new Error('Esse arquivo não parece ser a chave privada do atualizador (atualizador-privada.xml).');
  return crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
}

function swEstadoChave() {
  $('sw-chave-estado').textContent = swChave ? 'Chave de assinatura carregada (só nesta aba, apenas em memória).' : 'Chave de assinatura não carregada: indique o arquivo na hora de cadastrar uma política.';
  $('sw-chave-esquecer').hidden = !swChave;
}

async function swGarantirChave() {
  const arq = $('sw-chave').files[0];
  if (arq) {
    swChave = await swImportarChave(await arq.text());
    $('sw-chave').value = '';
    swEstadoChave();
  }
  if (!swChave) throw new Error('Indique o arquivo da chave de assinatura (atualizador-privada.xml).');
  return swChave;
}

// ---------- regras de nomes (as mesmas do servidor e do agent) ----------
function swSegmentoOk(s) {
  if (!s || s.length > 100 || !/^[A-Za-z0-9._ ()[\]-]+$/.test(s)) return false;
  if (s === '.' || s === '..' || /[. ]$/.test(s)) return false;
  return !/^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)/i.test(s);
}
function swCaminhoOk(p) { const a = p.split('/'); return p.length > 0 && p.length <= 240 && a.length <= 8 && a.every(swSegmentoOk); }
function swGatilhoOk(g) {
  return g.length <= 260 && !/[<>"|?*\x00-\x1f]/.test(g) && !g.includes('..')
    && /^(\[(programfiles|programfiles\(x86\)|programfiles\(x64\)|programdata|windir|system32|systemdrive)\]|[A-Za-z]:)\\[^\\]/i.test(g);
}

// Lista os arquivos de um zip lendo so o diretorio central (sem descompactar nada). Zip64 nao e suportado.
async function swListarZip(arquivo) {
  const cauda = Math.min(arquivo.size, 65557);
  const fim = new DataView(await arquivo.slice(arquivo.size - cauda).arrayBuffer());
  let i = cauda - 22;
  while (i >= 0 && fim.getUint32(i, true) !== 0x06054b50) i--;
  if (i < 0) throw new Error('Esse arquivo não é um zip válido.');
  const total = fim.getUint16(i + 10, true), tamCd = fim.getUint32(i + 12, true), offCd = fim.getUint32(i + 16, true);
  if (total === 0xffff || tamCd === 0xffffffff || offCd === 0xffffffff) throw new Error('Zip64 não é suportado: use um zip comum (até 4 GB e 65 mil arquivos).');
  const cd = new DataView(await arquivo.slice(offCd, offCd + tamCd).arrayBuffer());
  const nomes = []; let p = 0;
  for (let n = 0; n < total && p + 46 <= cd.byteLength; n++) {
    if (cd.getUint32(p, true) !== 0x02014b50) throw new Error('O zip está corrompido.');
    const nl = cd.getUint16(p + 28, true), el2 = cd.getUint16(p + 30, true), cl = cd.getUint16(p + 32, true);
    nomes.push(new TextDecoder('utf-8').decode(new Uint8Array(cd.buffer, cd.byteOffset + p + 46, nl)));
    p += 46 + nl + el2 + cl;
  }
  return nomes;
}

function swConferirZipNomes(nomes) {
  if (!nomes.length) throw new Error('O zip está vazio.');
  if (nomes.length > 2000) throw new Error('O zip tem arquivos demais (máximo 2000).');
  for (const n of nomes) {
    const limpo = n.replace(/\/$/, '');
    if (!limpo || !swCaminhoOk(limpo)) throw new Error('O zip tem um nome de arquivo não permitido: "' + n + '". Use só letras, números, ponto, espaço, hífen, sublinhado e parênteses (sem acentos).');
  }
}

function swEnviarArquivo(pid, arquivo) {
  return new Promise((resolve, reject) => {
    const x = new XMLHttpRequest();
    x.open('PUT', 'api/software/arquivo?pid=' + encodeURIComponent(pid));
    if (P.eu) x.setRequestHeader('X-CSRF-Token', P.eu.csrf);
    x.setRequestHeader('Content-Type', 'application/octet-stream');
    x.upload.onprogress = (ev) => { if (ev.lengthComputable) swMsg('Enviando o arquivo… ' + Math.round((ev.loaded / ev.total) * 100) + '%'); };
    x.onload = () => {
      let j = {}; try { j = JSON.parse(x.responseText); } catch (e) { /* resposta sem JSON */ }
      if (x.status === 401) { location.href = 'login'; return; }
      if (x.status >= 200 && x.status < 300) resolve(j); else reject(new Error(j.erro || 'HTTP ' + x.status));
    };
    x.onerror = () => reject(new Error('Falha de rede no envio do arquivo.'));
    x.send(arquivo);
  });
}

async function swSha256(arquivo) { return hex(await crypto.subtle.digest('SHA-256', await arquivo.arrayBuffer())); }

// ---------- formulario ----------
function swAtualizarForm() {
  const f = $('sw-arq').files[0];
  const zip = f && swExt(f.name) === 'zip';
  $('sw-l-exe').hidden = !zip;
  const modo = $('sw-des').value;
  $('sw-l-desv').hidden = !(modo === 'nome' || modo === 'msi' || (modo === 'script' && zip));
  $('sw-l-desa').hidden = !modo;
  $('sw-desv-rot').textContent = modo === 'msi' ? 'Código do produto MSI' : modo === 'script' ? 'Script de desinstalação dentro do zip' : 'Nome do programa';
  $('sw-desv').placeholder = modo === 'msi' ? '{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}' : modo === 'script' ? 'ex.: installer/remover.cmd' : 'exatamente como em Programas e Recursos';
  const exe = zip ? $('sw-exe').value : (f ? f.name : '');
  if (!$('sw-args').value && swExt(exe) === 'msi') $('sw-args').value = '/qn /norestart';
}

$('sw-arq').addEventListener('change', async () => {
  const f = $('sw-arq').files[0];
  swZipNomes = [];
  $('sw-exe').replaceChildren();
  if (f) {
    if (!$('sw-nome').value) $('sw-nome').value = f.name.replace(/\.[^.]+$/, '');
    if (swExt(f.name) === 'zip') {
      try {
        swZipNomes = await swListarZip(f);
        swConferirZipNomes(swZipNomes);
        // scripts de instalacao primeiro (instalar.cmd, install.ps1, setup.bat...): o instalador cru (.msi/.exe) so e a escolha certa quando nao ha script
        const pontos = (n) => (/(^|\/)(instalar|install|setup)[^/]*\.(cmd|bat|ps1|vbs)$/i.test(n) ? 0 : ['cmd', 'bat', 'ps1', 'vbs'].includes(swExt(n)) ? 1 : 2);
        const exes = swZipNomes.filter((n) => !n.endsWith('/') && swExecExt.includes(swExt(n))).sort((x, y) => pontos(x) - pontos(y));
        $('sw-exe').replaceChildren(...exes.map((n) => el('option', { value: n, text: n })));
        swMsg(exes.length ? swZipNomes.length + ' arquivo(s) no zip. Escolha qual deles executar.' : 'Esse zip não tem nenhum .msi, .exe, .ps1, .cmd, .bat ou .vbs para executar.');
      } catch (e) { swMsg(e.message); $('sw-arq').value = ''; }
    } else swMsg('');
  }
  swAtualizarForm();
});
$('sw-exe').addEventListener('change', swAtualizarForm);
$('sw-des').addEventListener('change', swAtualizarForm);

function swMontarDesinstalar(zip, tipo) {
  const modo = $('sw-des').value;
  if (!modo) return null;
  const valor = $('sw-desv').value.trim(), args = $('sw-desa').value.trim();
  const d = { modo };
  if (modo === 'msi') {
    if (!/^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$/.test(valor)) throw new Error('Código do produto MSI inválido. Formato: {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}.');
    d.codigo = valor;
  } else if (modo === 'nome') {
    if (!valor) throw new Error('Informe o nome do programa como aparece em Programas e Recursos.');
    d.software = valor;
  } else {
    if (zip) {
      if (!swCaminhoOk(valor) || !['ps1', 'cmd', 'bat', 'vbs'].includes(swExt(valor))) throw new Error('Script de desinstalação inválido (.ps1, .cmd, .bat ou .vbs dentro do zip).');
      if (!swZipNomes.some((n) => n.toLowerCase() === valor.toLowerCase())) throw new Error('O script "' + valor + '" não existe dentro do zip.');
      d.arquivo = valor;
    } else if (!['ps1', 'cmd', 'vbs'].includes(tipo)) throw new Error('Desinstalação por script exige um pacote .ps1, .cmd, .bat, .vbs ou .zip.');
  }
  if (args) d.args = args;
  return d;
}

$('sw-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const botao = ev.submitter || $('sw-form').querySelector('button[type=submit]');
  botao.disabled = true;
  try {
    const arq = $('sw-arq').files[0];
    if (!arq) throw new Error('Escolha o arquivo do pacote (instalador, script ou zip).');
    const ext = swExt(arq.name);
    if (!swTipos[ext]) throw new Error('Tipo não suportado. Use .msi, .exe, .ps1, .cmd, .bat, .vbs ou .zip.');
    if (!/^[A-Za-z0-9][A-Za-z0-9._ -]{0,100}$/.test(arq.name)) throw new Error('O nome do arquivo só pode ter letras, números, ponto, espaço, hífen e sublinhado (sem acentos). Renomeie o arquivo.');
    if (arq.size < 1) throw new Error('O arquivo está vazio.');
    if (arq.size > swDados.limite_mb * 1048576) throw new Error('O arquivo passa do limite de ' + swDados.limite_mb + ' MB deste servidor.');
    const nome = $('sw-nome').value.trim();
    if (!nome) throw new Error('Dê um nome à política.');
    const tipo = swTipos[ext], zip = tipo === 'zip';
    const m = { v: 2, pid: '', nome, tipo, arquivo: arq.name, sha256: '', tamanho: arq.size, args: $('sw-args').value.trim() };
    const desc = $('sw-desc').value.trim(); if (desc) m.descricao = desc;
    const soft = $('sw-soft').value.trim(); if (soft) m.software = soft;
    if (zip) {
      swConferirZipNomes(swZipNomes);
      const exe = $('sw-exe').value;
      if (!exe) throw new Error('Escolha o arquivo a executar dentro do zip.');
      m.executavel = exe;
    }
    const gat = $('sw-gat').value.trim();
    if (gat) { if (!swGatilhoOk(gat)) throw new Error('Arquivo gatilho inválido. Use um caminho completo, como [programfiles]\\Programa\\programa.exe (sem curingas).'); m.gatilho = gat; }
    const des = swMontarDesinstalar(zip, tipo); if (des) m.desinstalar = des;
    const chave = await swGarantirChave();
    swMsg('Calculando o hash do arquivo…');
    const rnd = new Uint8Array(16); crypto.getRandomValues(rnd);
    m.pid = [...rnd].map((x) => x.toString(16).padStart(2, '0')).join('');
    m.sha256 = await swSha256(arq);
    m.criado = Date.now();
    const manifesto = JSON.stringify(m);
    if (manifesto.length > 8000) throw new Error('Descrição, parâmetros e caminhos somam texto demais; encurte um pouco.');
    const assin = b64DeBytes(await crypto.subtle.sign({ name: 'RSASSA-PKCS1-v1_5' }, chave, new TextEncoder().encode(manifesto)));
    swMsg('Cadastrando a política…');
    const r = await api('api/software', { metodo: 'POST', corpo: { manifesto, assinatura: assin } });
    await swEnviarArquivo(r.pid, arq);
    swMsg('Política "' + nome + '" assinada e enviada. Agora aplique nos PCs (ou ligue a aplicação automática).');
    $('sw-form').reset(); swZipNomes = []; $('sw-exe').replaceChildren(); swAtualizarForm();
    await carregarSoftware();
  } catch (e) { swMsg(e.message); } finally { botao.disabled = false; }
});

$('sw-chave-esquecer').addEventListener('click', () => { swChave = null; swEstadoChave(); });

async function swReenviar(p) {
  const sel = document.createElement('input');
  sel.type = 'file';
  sel.onchange = async () => {
    const arq = sel.files[0];
    if (!arq) return;
    try {
      if ((await swSha256(arq)) !== p.sha256) throw new Error('Esse arquivo não é o mesmo que foi assinado (o hash é diferente).');
      await swEnviarArquivo(p.pid, arq);
      swMsg('Arquivo enviado.');
      await carregarSoftware();
    } catch (e) { swMsg(e.message); }
  };
  sel.click();
}

async function swExcluir(p) {
  if (!confirm('Excluir a política "' + p.nome + '"? As tarefas dela (inclusive o histórico) também são apagadas. PCs que já instalaram não são afetados.')) return;
  try { await api('api/software?pid=' + encodeURIComponent(p.pid), { metodo: 'DELETE' }); await carregarSoftware(); } catch (e) { alert(e.message); }
}

const swRot = {
  pendente: 'aguardando o PC', executando: 'executando', ok: 'instalado', falhou: 'falhou', cancelada: 'cancelada',
  desinstalar_pendente: 'desinstalação aguardando', desinstalar_executando: 'desinstalando', desinstalar_ok: 'desinstalado', desinstalar_falhou: 'desinstalação falhou', desinstalar_cancelada: 'desinstalação cancelada',
};
const swModoRot = { nome: 'pelo nome', msi: 'pelo código MSI', script: 'por script' };

function swDesenhar() {
  const corpo = document.querySelector('#sw-tabela tbody');
  corpo.replaceChildren(...swDados.pacotes.map((p) => {
    const t = p.tarefas || {};
    const ordem = ['ok', 'executando', 'pendente', 'falhou', 'desinstalar_ok', 'desinstalar_executando', 'desinstalar_pendente', 'desinstalar_falhou'];
    const resumo = ordem.filter((k) => t[k]).map((k) => t[k] + ' ' + swRot[k]).join(' · ') || '—';
    const detalhes = [p.descricao, p.software ? 'Software: ' + p.software : '', p.executavel ? 'Executa: ' + p.executavel : '', p.args ? 'Parâmetros: ' + p.args : '',
      p.gatilho ? 'Gatilho: ' + p.gatilho : '', p.desinstalar ? 'Desinstala ' + swModoRot[p.desinstalar] : ''].filter(Boolean);
    return el('tr', null,
      el('td', null, el('b', { text: p.nome }), ...detalhes.map((d) => el('div', { class: 'mudo', text: d }))),
      el('td', { text: p.tipo }), el('td', { class: 'nowrap', text: swMb(p.tamanho) }),
      el('td', { text: p.auto ? 'automática · ' + (p.alvo || 'todas as máquinas') : 'manual' }),
      el('td', { class: 'nowrap', text: swDh(p.criado_em) + ' · ' + p.criado_por }),
      el('td', { text: p.arquivo_ok ? resumo : 'arquivo não enviado' }),
      el('td', null, el('div', { class: 'sw-acoes' },
        p.arquivo_ok ? el('button', { class: 'btn pequeno', type: 'button', onclick: () => swAbrirAlvo(p, 'instalar') }, 'Instalar…') : el('button', { class: 'btn pequeno', type: 'button', onclick: () => swReenviar(p) }, 'Enviar arquivo'),
        p.arquivo_ok && p.desinstalar ? el('button', { class: 'btn pequeno', type: 'button', onclick: () => swAbrirAlvo(p, 'desinstalar') }, 'Desinstalar…') : null,
        p.arquivo_ok ? el('button', { class: 'btn pequeno', type: 'button', onclick: () => swAbrirPolitica(p) }, 'Automática…') : null,
        el('button', { class: 'btn pequeno', type: 'button', onclick: () => swExcluir(p) }, 'Excluir'))));
  }));
  if (!swDados.pacotes.length) corpo.append(el('tr', null, el('td', { colspan: '7', class: 'mudo', text: 'Nenhuma política cadastrada.' })));
}

function swDesenharMaquinas() {
  const f = $('sw-filtro').value.trim().toLowerCase();
  $('sw-maquinas').replaceChildren(...swDados.maquinas.filter((m) => !f || m.host.toLowerCase().includes(f)).map((m) => el('label', { class: 'item-marcar' + (m.token_proprio ? '' : ' mudo') },
    el('input', { type: 'checkbox', value: m.host, disabled: !m.token_proprio }), ' ' + m.host + ' · agent ' + (m.versao || '—') + (m.token_proprio ? '' : ' · sem token próprio (ainda não pode receber)'))));
}

function swAbrirAlvo(p, acao) {
  swAlvoPid = p.pid; swAlvoAcao = acao;
  $('sw-alvo-titulo').textContent = (acao === 'desinstalar' ? 'Desinstalar "' : 'Instalar "') + p.nome + '" em:';
  $('sw-instalar').textContent = acao === 'desinstalar' ? 'Desinstalar nas marcadas' : 'Instalar nas marcadas';
  $('sw-alvo-msg').textContent = '';
  $('sw-filtro').value = '';
  swDesenharMaquinas();
  $('sw-alvo').hidden = false;
  $('sw-alvo').scrollIntoView({ block: 'nearest' });
}

function swAbrirPolitica(p) {
  swPolPid = p.pid;
  $('sw-pol-titulo').textContent = 'Aplicação automática de "' + p.nome + '"';
  $('sw-pol-auto').checked = p.auto;
  $('sw-pol-alvo').value = p.alvo || '';
  $('sw-pol-msg').textContent = '';
  $('sw-pol').hidden = false;
  $('sw-pol').scrollIntoView({ block: 'nearest' });
}

$('sw-pol-fechar').addEventListener('click', () => { $('sw-pol').hidden = true; swPolPid = null; });
$('sw-pol-salvar').addEventListener('click', async () => {
  const auto = $('sw-pol-auto').checked, alvo = $('sw-pol-alvo').value.trim();
  const p = swDados.pacotes.find((x) => x.pid === swPolPid);
  if (auto && !confirm('Ligar a aplicação automática de "' + (p ? p.nome : '') + '" em ' + (alvo ? 'máquinas que combinem com "' + alvo + '"' : 'TODAS as máquinas (as novas inclusive)') + '? Cada PC instala em até 15 minutos, como administrador do sistema.')) return;
  try {
    await api('api/software/politica', { metodo: 'POST', corpo: { pid: swPolPid, auto, alvo } });
    $('sw-pol-msg').textContent = auto ? 'Aplicação automática ligada.' : 'Aplicação automática desligada.';
    await carregarSoftware();
  } catch (e) { $('sw-pol-msg').textContent = e.message; }
});

$('sw-filtro').addEventListener('input', swDesenharMaquinas);
$('sw-marcar').addEventListener('click', () => { for (const c of $('sw-maquinas').querySelectorAll('input:not(:disabled)')) c.checked = true; });
$('sw-limpar').addEventListener('click', () => { for (const c of $('sw-maquinas').querySelectorAll('input')) c.checked = false; });
$('sw-fechar').addEventListener('click', () => { $('sw-alvo').hidden = true; swAlvoPid = null; });
$('sw-instalar').addEventListener('click', async () => {
  const hosts = [...$('sw-maquinas').querySelectorAll('input:checked')].map((c) => c.value);
  if (!hosts.length) { $('sw-alvo-msg').textContent = 'Marque ao menos uma máquina.'; return; }
  const p = swDados.pacotes.find((x) => x.pid === swAlvoPid);
  const verbo = swAlvoAcao === 'desinstalar' ? 'Desinstalar' : 'Instalar';
  if (!confirm(verbo + ' "' + (p ? p.nome : '') + '" em ' + hosts.length + ' máquina(s)? Cada PC executa em até 15 minutos, como administrador do sistema.')) return;
  try {
    const r = await api('api/software/instalar', { metodo: 'POST', corpo: { pid: swAlvoPid, hosts, acao: swAlvoAcao } });
    $('sw-alvo-msg').textContent = r.criadas + ' tarefa(s) criada(s)' + (r.ignoradas ? ', ' + r.ignoradas + ' já estavam em andamento' : '') + '.';
    await carregarSoftware();
  } catch (e) { $('sw-alvo-msg').textContent = e.message; }
});

async function swAcaoTarefa(acao, id) {
  try { await api('api/software/tarefas/' + acao, { metodo: 'POST', corpo: { id } }); await carregarSoftware(); } catch (e) { alert(e.message); }
}

function swDesenharTarefas(tarefas) {
  const corpo = document.querySelector('#sw-tarefas tbody');
  corpo.replaceChildren(...tarefas.map((t) => {
    const des = t.acao === 'desinstalar';
    const res = t.estado === 'ok' || t.estado === 'falhou'
      ? el('details', null, el('summary', { text: 'código ' + (t.codigo === null ? '—' : t.codigo) }), el('pre', { class: 'saida-sw', text: t.saida || '(sem saída)' })) : el('span', { class: 'mudo', text: '—' });
    return el('tr', null, el('td', { text: t.host }), el('td', { text: t.nome || '(política excluída)' }), el('td', { text: des ? 'desinstalar' : 'instalar' + (t.criado_por === 'automatico' ? ' (auto)' : '') }),
      el('td', { text: swRot[(des ? 'desinstalar_' : '') + t.estado] || t.estado }),
      el('td', { class: 'nowrap', text: swDh(t.fim_em || t.inicio_em || t.criado_em) }), el('td', null, res),
      el('td', { class: 'nowrap' },
        t.estado === 'pendente' ? el('button', { class: 'btn pequeno', type: 'button', onclick: () => swAcaoTarefa('cancelar', t.id) }, 'Cancelar') : null,
        t.estado === 'falhou' || t.estado === 'cancelada' ? el('button', { class: 'btn pequeno', type: 'button', onclick: () => swAcaoTarefa('repetir', t.id) }, 'Repetir') : null));
  }));
  if (!tarefas.length) corpo.append(el('tr', null, el('td', { colspan: '7', class: 'mudo', text: 'Nenhuma tarefa ainda.' })));
}

async function carregarSoftware() {
  swEstadoChave();
  try {
    swDados = await api('api/software');
    swDesenhar();
    if (swAlvoPid) swDesenharMaquinas();
    swDesenharTarefas((await api('api/software/tarefas')).tarefas);
  } catch (e) { swMsg('Falha: ' + e.message); }
}

P.abas.politicas = { carregar: carregarSoftware };
