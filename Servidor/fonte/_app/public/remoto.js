'use strict';
// Aba "Acesso remoto" (só administrador): a situação do RustDesk em cada máquina com agent, conexão direta pela lista
// e a liberação (desligado / só a lista / todas). Os dados vêm do inventário (api/inventario); a senha só é pedida ao
// servidor no clique, uma máquina por vez (cada consulta vai para a Auditoria).

// ---------- conexão (usada por esta aba e pela gaveta do Inventário) ----------
async function remotoCredenciais(host) {
  return api('api/remoto/acesso', { metodo: 'POST', corpo: { host } });
}
// Abre o RustDesk já conectando. Usa o atalho próprio pp-remoto:// (instalado uma vez no PC de quem acessa, com
// Remoto\Instalar-Atalho-Remoto.ps1): o link nativo rustdesk:// é ignorado pelo RustDesk quando a janela dele já está aberta.
async function remotoConectar(host, aviso) {
  const r = await remotoCredenciais(host);
  if (aviso) aviso('Abrindo o RustDesk… se nada abrir, instale o atalho (uma vez) ou use "Copiar senha".');
  location.href = `pp-remoto://conectar?id=${encodeURIComponent(r.id)}&senha=${encodeURIComponent(r.senha)}`;
  return r;
}
async function remotoCopiarSenha(host) {
  const r = await remotoCredenciais(host);
  await navigator.clipboard.writeText(r.senha);
  return r;
}

// ---------- situação por máquina ----------
const rmEstado = { itens: [], busca: '', grupo: 'todas', soOnline: false, agora: Date.now(), onlineMin: 45, timer: null };

// ordem de exibição: o que dá para usar primeiro, depois o que está em andamento, depois o que precisa de atenção
const RM_GRUPOS = [
  { id: 'prontas', rotulo: 'Prontas', dica: 'podem ser acessadas', cor: 'var(--presencial)' },
  { id: 'instalando', rotulo: 'Instalando', dica: 'em andamento agora', cor: 'var(--vpn)' },
  { id: 'aguardando', rotulo: 'Aguardando', dica: 'falta alguém entrar no Windows', cor: 'var(--parcial)' },
  { id: 'falha', rotulo: 'Com falha', dica: 'precisam de atenção', cor: 'var(--semrede)' },
  { id: 'fora', rotulo: 'Fora da rede', dica: 'sem acesso ao relay', cor: 'var(--semsinal)' },
  { id: 'sem-info', rotulo: 'Sem confirmação', dica: 'agent antigo ou ainda sem retorno', cor: 'var(--mudo)' },
];

function rmGrupo(x) {
  const e = x.remoto_estado || '';
  if (['baixando', 'instalando', 'configurando'].includes(e)) return 'instalando';
  if (e === 'aguardando-sessao' || e === 'prazo-esgotado') return 'aguardando';
  if (e === 'sem-relay') return 'fora';
  if (e.startsWith('falha') || e === 'sem-id') return 'falha';
  if (e === 'registrado' || e === 'ok') return 'prontas';   // so quem CONFIRMOU (agent 1.4.2+) conta como pronta
  return 'sem-info';                                          // inclui ID registrado por agent antigo: nao ha prova de que o relay esta certo
}
const rmOnline = (x) => x.ultimo_contato !== null && x.ultimo_contato !== undefined && (rmEstado.agora - x.ultimo_contato) <= rmEstado.onlineMin * 60000;
function rmHa(ts) {
  if (ts === null || ts === undefined) return '—';
  const m = Math.max(0, Math.round((rmEstado.agora - ts) / 60000));
  if (m < 2) return 'agora';
  if (m < 60) return `há ${m} min`;
  const h = Math.round(m / 60);
  return h < 48 ? `há ${h} h` : `há ${Math.round(h / 24)} dias`;
}
const rmTexto = (x) => `${x.host} ${x.chave} ${x.remoto_id} ${x.ultimo_usuario} ${x.responsavel} ${x.localizacao} ${x.ips} ${x.ip_saida} ${x.num_inventario}`.toLowerCase();

function rmFiltrados() {
  const t = rmEstado.busca.trim().toLowerCase();
  const ordem = RM_GRUPOS.map((g) => g.id);
  return rmEstado.itens
    .filter((x) => (rmEstado.grupo === 'todas' || rmGrupo(x) === rmEstado.grupo) && (!t || rmTexto(x).includes(t)) && (!rmEstado.soOnline || rmOnline(x)))
    .sort((a, b) => (ordem.indexOf(rmGrupo(a)) - ordem.indexOf(rmGrupo(b))) || String(a.host || a.chave).localeCompare(String(b.host || b.chave), 'pt-BR', { numeric: true }));
}

function rmAviso(texto) {
  const p = $('rm-msg');
  p.hidden = !texto;
  p.textContent = texto || '';
}

function rmCartoes() {
  const cont = (id) => rmEstado.itens.filter((x) => rmGrupo(x) === id).length;
  const cartao = (id, rotulo, valor, dica, cor) => el('button', {
    type: 'button', class: `cartao kpi-clicavel${rmEstado.grupo === id ? ' ativo' : ''}`, style: cor ? `--cor:${cor}` : null, 'aria-pressed': String(rmEstado.grupo === id),
    onclick: () => { rmEstado.grupo = rmEstado.grupo === id && id !== 'todas' ? 'todas' : id; rmDesenhar(); },
  }, el('div', { class: 'rotulo', text: rotulo }), el('div', { class: 'valor', text: String(valor) }), el('div', { class: 'detalhe', text: dica || '' }));
  $('rm-cartoes').replaceChildren(
    cartao('todas', 'Máquinas com agent', rmEstado.itens.length, 'todas as situações', 'var(--acento)'),
    ...RM_GRUPOS.map((g) => cartao(g.id, g.rotulo, cont(g.id), g.dica, g.cor)));
}

// "199602839" -> "199 602 839" (como o RustDesk mostra o ID)
const rmIdBonito = (id) => String(id || '').replace(/(\d{3})(?=\d)/g, '$1 ');
// "Nome Sobrenome - login" -> { nome, login }
function rmQuem(x) {
  const t = x.ultimo_usuario || x.responsavel || '';
  const i = t.lastIndexOf(' - ');
  return i > 0 ? { nome: t.slice(0, i), login: t.slice(i + 3) } : { nome: t, login: '' };
}
// maior versão de agent vista: as que estão abaixo ganham um aviso (agent antigo = sem as correções do acesso remoto)
const rmVersaoNum = (v) => String(v || '0').split('.').reduce((a, n) => a * 1000 + (parseInt(n, 10) || 0), 0);
function rmVersaoMax() { return rmEstado.itens.reduce((m, x) => (rmVersaoNum(x.agente_versao) > rmVersaoNum(m) ? x.agente_versao : m), ''); }
// "config:ja-estava; relay:conversando" -> "configurado · falando com o relay" (o texto técnico fica no balão ao passar o mouse)
function rmDetalheAmigavel(d) {
  const p = [];
  for (const parte of String(d || '').split(/[;·]/).map((s) => s.trim()).filter(Boolean)) {
    if (parte.startsWith('config:')) { if (!p.includes('configurado')) p.push('configurado'); }
    else if (parte === 'relay:conversando') p.push('falando com o relay');
    else if (parte.startsWith('relay:')) p.push('relay ainda sem resposta');
    else p.push(parte);
  }
  return p.join(' · ');
}
const rmTipoRotulo = (t) => ({ NOTEBOOK: 'Notebook', DESKTOP: 'Desktop', SERVIDOR: 'Servidor' }[String(t || '').toUpperCase()] || t || '');

function rmLinha(x) {
  const g = RM_GRUPOS.find((o) => o.id === rmGrupo(x));
  const online = rmOnline(x);
  const rotuloEstado = x.remoto_estado ? (ROTULO_REMOTO[x.remoto_estado] || x.remoto_estado) : (x.remoto_id ? 'Registrada, sem confirmação (agent antigo)' : 'Sem informação');
  const detalheBruto = x.remoto_estado_detalhe || '';
  const detalhe = [rmDetalheAmigavel(detalheBruto), x.remoto_estado_em ? rmHa(x.remoto_estado_em) : ''].filter(Boolean).join(' · ');
  const q = rmQuem(x);
  const antigo = x.agente_versao && rmVersaoNum(x.agente_versao) < rmVersaoNum(rmVersaoMax());
  const equipamento = [rmTipoRotulo(x.tipo), x.modelo].filter(Boolean).join(' · ');
  const acoes = el('div', { class: 'rm-acoes' });
  if (x.remoto_id) {
    acoes.append(
      el('button', { class: 'btn pequeno primario', type: 'button', title: online ? 'Abre o RustDesk já conectando nesta máquina' : 'A máquina não aparece online agora; pode não conectar', onclick: async (ev) => {
        ev.stopPropagation(); const b = ev.currentTarget; b.disabled = true;
        try { await remotoConectar(x.host, (m) => rmAviso(`${x.host}: ${m}`)); } catch (e) { alert(e.message); }
        b.disabled = false;
      } }, 'Conectar'),
      el('button', { class: 'btn pequeno', type: 'button', onclick: async (ev) => {
        ev.stopPropagation();
        try { const r = await remotoCopiarSenha(x.host); rmAviso(`${x.host}: ID ${r.id} · senha copiada (cole no RustDesk)`); } catch (e) { alert(e.message); }
      } }, 'Copiar senha'));
  }
  acoes.append(el('button', { class: 'btn pequeno', type: 'button', onclick: (ev) => { ev.stopPropagation(); invAbrir(x); } }, 'Detalhes'));
  return el('tr', { class: 'clicavel', onclick: () => invAbrir(x) },
    el('td', null,
      el('div', { class: 'rm-l1' }, el('strong', { text: x.host || x.chave }), x.servidor ? el('span', { class: 'etq', text: 'Servidor' }) : null,
        antigo ? el('span', { class: 'etq alerta', title: `Agent v${x.agente_versao}: a mais recente é v${rmVersaoMax()}`, text: `agent v${x.agente_versao}` }) : null),
      equipamento ? el('div', { class: 'sub2', text: equipamento }) : null),
    el('td', null,
      el('div', { class: 'rm-l1', text: q.nome || '—' }),
      (q.login || x.localizacao) ? el('div', { class: 'sub2', text: [q.login, x.localizacao].filter(Boolean).join(' · ') }) : null),
    el('td', null,
      el('div', { class: 'rm-l1' }, el('span', { class: 'selo', style: `--cor:${g.cor}`, text: rotuloEstado })),
      detalhe ? el('div', { class: 'sub2', title: detalheBruto, text: detalhe }) : null),
    el('td', { class: 'nowrap rm-id', title: x.remoto_id ? 'ID do RustDesk' : '', text: x.remoto_id ? rmIdBonito(x.remoto_id) : '—' }),
    el('td', { class: `nowrap${online ? '' : ' mudo'}` },
      el('div', { class: 'rm-l1' }, el('span', { class: 'selo', style: `--cor:${online ? 'var(--presencial)' : 'var(--semsinal)'}`, text: online ? 'online' : 'offline' })),
      el('div', { class: 'sub2', text: rmHa(x.ultimo_contato) })),
    el('td', null, acoes));
}

function rmDesenhar() {
  rmCartoes();
  const lista = rmFiltrados();
  const corpo = document.querySelector('#rm-tabela tbody');
  corpo.replaceChildren(...lista.slice(0, 500).map(rmLinha));
  if (!lista.length) corpo.append(el('tr', null, el('td', { colspan: '6', class: 'mudo', text: rmEstado.itens.length ? 'Nenhuma máquina com esses filtros.' : 'Nenhuma máquina com agent ainda.' })));
  const total = rmEstado.itens.length;
  $('rm-contagem').textContent = `${lista.length} de ${total} máquina(s)${lista.length > 500 ? ' (mostrando 500)' : ''}`;
}

async function rmCarregarLista() {
  try {
    const r = await api('api/inventario');
    rmEstado.itens = r.itens.filter((x) => x.tem_agente);
    rmEstado.agora = r.agora;
    rmEstado.onlineMin = (P.eu && P.eu.online_min) || 45;
    // a gaveta de detalhes (invAbrir) usa a lista de status do inventário
    if (typeof invEstado !== 'undefined' && !invEstado.status.length) { invEstado.status = r.status; invEstado.agora = r.agora; }
    $('rm-atualizado').textContent = `atualizado às ${new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}`;
    rmDesenhar();
  } catch (e) {
    $('rm-cartoes').replaceChildren(el('p', { class: 'aviso', text: `Falha ao carregar: ${e.message}` }));
  }
}

// ---------- liberação (desligado / só a lista / todas) ----------
async function carregarRemotoConfig() {
  try {
    const r = await api('api/remoto/config');
    $('ad-rem-modo').value = r.modo;
    $('ad-rem-lista').value = r.lista.join('\n');
    $('ad-rem-lista').hidden = r.modo !== 'lista';
    const e = r.estados || {};
    const em = (e.baixando || 0) + (e.instalando || 0) + (e.configurando || 0);
    const falhas = Object.entries(e).filter(([k]) => k.startsWith('falha') || k === 'sem-id').reduce((s, [, n]) => s + n, 0);
    const partes = [`${r.registradas} registrada(s)`];
    if (em) partes.push(`${em} instalando`);
    if (e['sem-relay']) partes.push(`${e['sem-relay']} fora da rede`);
    const espera = (e['aguardando-sessao'] || 0) + (e['prazo-esgotado'] || 0);
    if (espera) partes.push(`${espera} aguardando`);
    if (falhas) partes.push(`${falhas} com falha`);
    $('ad-rem-resumo').textContent = partes.join(' · ');
  } catch (e) { $('ad-rem-resumo').textContent = `Falha: ${e.message}`; }
}

// ---------- aba ----------
async function carregarRemoto() {
  if (P.eu.papel !== 'admin') return;
  await Promise.all([rmCarregarLista(), carregarRemotoConfig()]);
  // enquanto a aba está aberta, atualiza sozinha a cada 30 s (as máquinas vão mudando de situação)
  if (!rmEstado.timer) rmEstado.timer = setInterval(() => { if (P.abaAtual === 'remoto' && !document.hidden) rmCarregarLista(); }, 30000);
}
P.abas.remoto = { carregar: carregarRemoto };

$('rm-busca').addEventListener('input', (ev) => { rmEstado.busca = ev.target.value; rmDesenhar(); });
$('rm-online').addEventListener('change', (ev) => { rmEstado.soOnline = ev.target.checked; rmDesenhar(); });
$('rm-atualizar').addEventListener('click', () => { rmAviso(''); rmCarregarLista(); carregarRemotoConfig(); });
$('ad-rem-modo').addEventListener('change', () => { $('ad-rem-lista').hidden = $('ad-rem-modo').value !== 'lista'; });
$('ad-rem-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const modo = $('ad-rem-modo').value;
  if (modo === 'todas' && !confirm('Liberar o acesso remoto em TODAS as máquinas com o agent? Cada uma vai instalar o RustDesk na próxima atualização.')) return;
  try { await api('api/remoto/config', { metodo: 'PUT', corpo: { modo, lista: $('ad-rem-lista').value } }); await carregarRemotoConfig(); } catch (e) { alert(e.message); }
});
