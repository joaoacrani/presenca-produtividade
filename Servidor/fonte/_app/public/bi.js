'use strict';
// Painel BI: produtividade + localização por colaborador.

const biEstado = { dados: null, todos: null, periodo: null, busca: '', selecionado: null, vez: 0 };

const semAcento = (s) => String(s).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
const filtrarColab = (lista) => {
  const t = semAcento(biEstado.busca.trim());
  return t ? lista.filter((c) => semAcento(`${c.colaborador} ${c.nome} ${c.login}`).includes(t)) : lista;
};
const COR_LOCAL = [
  { id: 'presencial', nome: 'Presencial', cor: 'var(--presencial)' },
  { id: 'remoto', nome: 'Remoto / home', cor: 'var(--remoto)' },
  { id: 'parcial', nome: 'Parcial (poucas leituras)', cor: 'var(--parcial)' },
  { id: 'sem', nome: 'Sem registro', cor: 'var(--semsinal)' },
];

function cartaoKpi(id, rotulo, valor, detalhe, cor) {
  const ativo = biEstado.kpi === id;
  return el('button', { class: 'cartao kpi-clicavel' + (ativo ? ' ativo' : ''), type: 'button', 'aria-pressed': String(ativo), title: 'Clique para ver o detalhe por colaborador',
    style: cor ? `--cor:${cor}` : null, onclick: () => { biEstado.kpi = biEstado.kpi === id ? null : id; renderKpis(biEstado.dados.kpis); } },
    el('div', { class: 'rotulo', text: rotulo }),
    el('div', { class: 'valor', text: valor }),
    el('div', { class: 'detalhe', text: detalhe || '' }));
}

function renderKpis(k) {
  const alvo = $('bi-kpis');
  const cs = biEstado.dados ? biEstado.dados.colaboradores : [];
  const nPres = cs.filter((c) => c.dias_presenciais > 0).length, nHome = cs.filter((c) => c.dias_remotos > 0).length;   // pessoas, nao dias (quem alterna conta nos dois)
  alvo.replaceChildren(
    cartaoKpi('colab', 'Colaboradores', String(k.colaboradores), 'com dados no período'),
    cartaoKpi('pct', '% produtivo', fmtPct(k.pct_produtivo), 'produtivo ÷ (produtivo + improdutivo)', 'var(--produtivo)'),
    cartaoKpi('tempo', 'Tempo de navegação', fmtDur(k.tempo_total_seg), 'soma de todos os colaboradores'),
    cartaoKpi('presencial', 'Colaboradores presenciais', String(nPres), '', 'var(--presencial)'),
    cartaoKpi('remoto', 'Colaboradores em home', String(nHome), '', 'var(--remoto)'),
    cartaoKpi('parcial', 'Dias parciais', String(k.dias_parciais || 0), 'PC ligado pouco tempo no dia', 'var(--parcial)'),
    cartaoKpi('sem', 'Dias sem registro', String(k.dias_sem_registro), 'PC desligado, férias, atestado…', 'var(--semsinal)'));
  renderKpiDetalhe();
}

// Detalhe do cartao clicado: uma linha por colaborador (clique na linha abre a ficha dele).
function renderKpiDetalhe() {
  const alvo = $('bi-kpi-detalhe');
  const id = biEstado.kpi;
  if (!id || !biEstado.dados) { alvo.hidden = true; alvo.replaceChildren(); return; }
  const lista = filtrarColab(biEstado.dados.colaboradores);
  const datasTxt = (c, k) => (c.datas[k] || []).map((x) => (Array.isArray(x) ? `${diaCurto(x[0])}${x[1] ? ' (' + x[1] + ')' : ''}` : diaCurto(x))).join(', ');
  const ST = { presencial: ['Colaboradores presenciais', 'presencial'], remoto: ['Colaboradores em home', 'remoto'], parcial: ['Dias parciais', 'parcial'], sem: ['Dias sem registro', 'sem'] };
  let titulo, cab, linhas;
  if (ST[id]) {
    const k = ST[id][1];
    titulo = ST[id][0];
    cab = ['Colaborador e dias', 'Datas'];
    linhas = lista.filter((c) => (c.datas[k] || []).length).sort((a, b) => b.datas[k].length - a.datas[k].length || a.colaborador.localeCompare(b.colaborador, 'pt-BR'))
      .map((c) => ({ c, cel: [el('span', null, c.colaborador, el('b', { class: 'dias-badge', text: `${c.datas[k].length} dia${c.datas[k].length > 1 ? 's' : ''}` })), datasTxt(c, k)] }));
  } else if (id === 'pct') {
    titulo = '% produtivo por colaborador (maior primeiro)';
    cab = ['Colaborador', '% produtivo', 'Produtivo', 'Neutro', 'Improdutivo'];
    linhas = lista.filter((c) => c.total_seg > 0).sort((a, b) => (b.pct_produtivo === null ? -1 : b.pct_produtivo) - (a.pct_produtivo === null ? -1 : a.pct_produtivo))
      .map((c) => ({ c, cel: [c.colaborador, fmtPct(c.pct_produtivo), fmtDur(c.segundos.produtivo), fmtDur(c.segundos.neutro), fmtDur(c.segundos.improdutivo)] }));
  } else if (id === 'tempo') {
    titulo = 'Tempo de navegação por colaborador (maior primeiro)';
    cab = ['Colaborador', 'Tempo total', '% produtivo'];
    linhas = lista.filter((c) => c.total_seg > 0).sort((a, b) => b.total_seg - a.total_seg)
      .map((c) => ({ c, cel: [c.colaborador, fmtDur(c.total_seg), fmtPct(c.pct_produtivo)] }));
  } else {
    titulo = 'Colaboradores com dados no período';
    cab = ['Colaborador', 'Login', 'Dias com registro', 'Tempo de navegação'];
    linhas = lista.slice().sort((a, b) => a.colaborador.localeCompare(b.colaborador, 'pt-BR'))
      .map((c) => ({ c, cel: [c.colaborador, c.login, String(c.dias_presenciais + c.dias_remotos + (c.dias_parciais || 0)), c.total_seg > 0 ? fmtDur(c.total_seg) : '—'] }));
  }
  const corpo = el('tbody');
  for (const l of linhas) {
    const tr = el('tr', { class: 'clicavel', title: 'Ver ficha do colaborador', onclick: () => abrirColaborador(l.c.login) });
    l.cel.forEach((t, i) => tr.append(t instanceof Node ? el('td', null, t) : el('td', { text: t, class: i === cab.length - 1 && ST[id] ? 'obs' : null })));
    corpo.append(tr);
  }
  if (!linhas.length) corpo.append(el('tr', null, el('td', { colspan: String(cab.length), class: 'mudo', text: 'Nenhum colaborador neste período.' })));
  alvo.replaceChildren(
    el('div', { class: 'painel-topo' }, el('h2', { text: titulo }), el('span', { class: 'mudo', text: `${linhas.length} colaborador(es)` }),
      el('button', { class: 'btn pequeno', type: 'button', text: 'Fechar', onclick: () => { biEstado.kpi = null; renderKpis(biEstado.dados.kpis); } })),
    el('table', { class: 'kpi-tabela' }, el('thead', null, el('tr', null, ...cab.map((t) => el('th', { text: t })))), corpo));
  alvo.hidden = false;
}

function ordenarColab(lista, modo) {
  const c = lista.slice();
  const pc = (x) => (x.pct_produtivo === null ? -1 : x.pct_produtivo);
  if (modo === 'prod') c.sort((a, b) => pc(b) - pc(a));
  else if (modo === 'improd') c.sort((a, b) => (b.pct_produtivo === null ? -1 : 100 - b.pct_produtivo) - (a.pct_produtivo === null ? -1 : 100 - a.pct_produtivo));
  else if (modo === 'tempo') c.sort((a, b) => b.total_seg - a.total_seg);
  else c.sort((a, b) => a.colaborador.localeCompare(b.colaborador, 'pt-BR'));
  return c;
}

function linhaColaborador(c, barra, texto) {
  return el('button', { class: 'linha-barra', type: 'button', onclick: () => abrirColaborador(c.login), title: 'Ver detalhes' },
    el('span', { class: 'nome', text: c.colaborador }), barra, el('span', { class: 'valor-barra', text: texto }));
}

function renderBiProd() {
  const d = biEstado.dados;
  const alvo = $('bi-prod');
  alvo.replaceChildren();
  const lista = filtrarColab(ordenarColab(d.colaboradores, $('bi-ordem').value));
  for (const c of lista) {
    const s = c.segundos;
    const barra = barraEmpilhada(
      CATEGORIAS.map((cat) => ({ valor: s[cat.id], cor: cat.cor, rotulo: `${cat.nome}: ${fmtDur(s[cat.id])}` })),
      `${c.colaborador}: ${fmtDur(s.produtivo)} produtivo, ${fmtDur(s.neutro)} neutro, ${fmtDur(s.improdutivo)} improdutivo`);
    alvo.append(linhaColaborador(c, barra, c.total_seg > 0 ? `${fmtPct(c.pct_produtivo)} · ${fmtDur(c.total_seg)}` : 'sem acessos'));
  }
  if (!lista.length) alvo.append(el('p', { class: 'mudo recuo', text: d.colaboradores.length ? 'Nenhum colaborador encontrado.' : 'Sem dados no período.' }));
  legenda($('bi-leg-prod'), CATEGORIAS.map((c) => ({ nome: c.nome, cor: c.cor })));
}

function renderBiLocal() {
  const d = biEstado.dados;
  const alvo = $('bi-local');
  alvo.replaceChildren();
  const filtrados = filtrarColab(ordenarColab(d.colaboradores, 'nome'));
  for (const c of filtrados) {
    const un = Object.entries(c.unidades).map(([u, n]) => `${u}: ${n}`).join(' · ');
    const barra = barraEmpilhada([
      { valor: c.dias_presenciais, cor: 'var(--presencial)', rotulo: `Presencial: ${c.dias_presenciais} dia(s)` },
      { valor: c.dias_remotos, cor: 'var(--remoto)', rotulo: `Remoto: ${c.dias_remotos} dia(s)` },
      { valor: c.dias_parciais, cor: 'var(--parcial)', rotulo: `Parcial: ${c.dias_parciais} dia(s)` },
      { valor: c.dias_sem_registro, cor: 'var(--semsinal)', rotulo: `Sem registro: ${c.dias_sem_registro} dia(s)` },
    ], `${c.colaborador}: ${c.dias_presenciais} presenciais, ${c.dias_remotos} remotos, ${c.dias_parciais} parciais, ${c.dias_sem_registro} sem registro`);
    alvo.append(linhaColaborador(c, barra, `${c.dias_presenciais} pres · ${c.dias_remotos} rem${un ? ' · ' + un : ''}`));
  }
  if (!filtrados.length) alvo.append(el('p', { class: 'mudo recuo', text: d.colaboradores.length ? 'Nenhum colaborador encontrado.' : 'Sem dados no período.' }));
  legenda($('bi-leg-local'), COR_LOCAL);
}

// Colunas empilhadas por dia. series: [{dia, partes:[{valor, cor, rotulo}]}]
function colunasPorDia(alvo, series, rotuloTopo) {
  alvo.replaceChildren();
  const max = Math.max(1, ...series.map((s) => s.partes.reduce((n, p) => n + p.valor, 0)));
  for (const s of series) {
    const total = s.partes.reduce((n, p) => n + p.valor, 0);
    const barra = el('div', { class: 'barra', style: `height:${Math.round((total / max) * 130)}px` });
    for (const p of s.partes) if (p.valor > 0) barra.append(el('div', { class: 'seg', title: p.rotulo, style: `background:${p.cor};height:${(p.valor / total) * 100}%` }));
    alvo.append(el('div', { class: 'col' }, el('div', { class: 'tot', text: rotuloTopo(total) }), barra, el('div', { class: 'dia', text: diaCurto(s.dia) })));
  }
  if (!series.length) alvo.append(el('p', { class: 'mudo', text: 'Sem dados no período.' }));
}

// Sites (x.dominio, x.visitas) ou programas (x.nome, x.usuarios): a mesma lista de barras.
function renderTopo(id, lista) {
  const alvo = $(id);
  alvo.replaceChildren();
  const max = Math.max(1, ...lista.map((x) => x.segundos));
  for (const x of lista) {
    const prog = x.dominio === undefined;
    alvo.append(el('div', { class: 'linha-barra estatica' },
      el('span', { class: 'nome', title: prog ? x.processo : x.dominio, text: prog ? x.nome : x.dominio }),
      el('div', { class: 'barra-h' }, el('div', { class: 'seg-h', style: `width:${(x.segundos / max) * 100}%;background:var(--acento)` })),
      el('span', { class: 'valor-barra', text: prog ? `${fmtDur(x.segundos)} · ${x.usuarios} colab.` : `${fmtDur(x.segundos)} · ${x.visitas} acessos` })));
  }
  if (!lista.length) alvo.append(el('p', { class: 'mudo recuo', text: 'Nada neste grupo.' }));
}

// Botões de classificação rápida (só administradores gravam)
function botoesClassificar(dominio, aoSalvar) {
  if (P.eu.papel !== 'admin') return el('span', { class: 'mudo', text: 'só administradores classificam' });
  const f = el('span', { class: 'grupo-btn' });
  for (const c of CATEGORIAS) {
    f.append(el('button', { class: 'btn pequeno', type: 'button', style: `--cor:${c.cor}`, onclick: async (ev) => {
      ev.target.disabled = true;
      try { await api('api/regras', { metodo: 'POST', corpo: { padrao: dominio, categoria: c.id } }); aoSalvar(); }
      catch (e) { alert(e.message); ev.target.disabled = false; }
    } }, c.nome));
  }
  return f;
}

// Quem acessou: nomes clicaveis (abrem a ficha do colaborador). Mostra os 3 que mais usaram e "+N".
function chipsQuem(lista) {
  const f = el('span', { class: 'quem' });
  for (const q of (lista || []).slice(0, 3)) {
    f.append(el('button', { class: 'chip-quem', type: 'button', title: `${fmtDur(q.segundos)} · ${q.visitas} acessos — ver detalhes`, onclick: () => abrirColaborador(q.login) }, q.colaborador));
  }
  if ((lista || []).length > 3) f.append(el('span', { class: 'mudo', text: `+${lista.length - 3}` }));
  return f;
}

// "Pre-identificacao": o que os acessos revelam sobre o site (titulos, caminhos, quem e quando). O servidor nao visita o site.
async function carregarPreId(painel, dominio, consulta) {
  painel.replaceChildren(el('p', { class: 'mudo', text: 'Carregando…' }));
  try {
    const d = await api(`api/dominio?dominio=${encodeURIComponent(dominio)}&${consulta}`);
    painel.replaceChildren();
    const quando = d.primeiro_ts ? `${dataCurta(d.primeiro_ts)} a ${dataCurta(d.ultimo_ts)}` : 'sem acessos brutos no período (a retenção é curta)';
    painel.append(el('p', { class: 'mudo', text: `${d.acessos_brutos} acesso(s) · ${quando}${d.navegadores.length ? ' · ' + d.navegadores.join(', ') : ''}` }));
    painel.append(el('h4', { text: 'Títulos das páginas' }));
    const ul = el('ul', { class: 'lista-simples compacta' });
    for (const t of d.titulos) ul.append(el('li', null, el('span', { class: 'quebra', text: t.titulo }), el('span', { class: 'mudo', text: `${t.acessos}×` })));
    painel.append(d.titulos.length ? ul : el('p', { class: 'mudo', text: 'Nenhum título registrado.' }));
    painel.append(el('h4', { text: 'Endereços acessados (sem parâmetros)' }));
    const ul2 = el('ul', { class: 'lista-simples compacta' });
    for (const c of d.caminhos) ul2.append(el('li', null, el('span', { class: 'quebra', text: c.url }), el('span', { class: 'mudo', text: `${c.acessos}× · ${fmtDur(c.segundos)}` })));
    painel.append(d.caminhos.length ? ul2 : el('p', { class: 'mudo', text: 'Nenhum endereço registrado.' }));
    painel.append(el('h4', { text: 'Quem acessou' }));
    const ul3 = el('ul', { class: 'lista-simples compacta' });
    for (const c of d.colaboradores) {
      ul3.append(el('li', null,
        el('button', { class: 'chip-quem', type: 'button', onclick: () => abrirColaborador(c.login) }, c.colaborador),
        el('span', { class: 'mudo', text: `${fmtDur(c.segundos)} · ${c.visitas} acessos` })));
    }
    painel.append(ul3);
    // so o nome do site vai para a pesquisa (nada do colaborador); abre em outra aba
    painel.append(el('p', null, el('a', { class: 'btn pequeno', href: `https://www.google.com/search?q=${encodeURIComponent(dominio)}`, target: '_blank', rel: 'noopener noreferrer' }, 'Pesquisar este site na web')));
  } catch (e) {
    painel.replaceChildren(el('p', { class: 'aviso', text: `Falha: ${e.message}` }));
  }
}

// Programas (aplicativos) ainda sem classificacao: mesmos botoes dos sites, mas a regra vai como "app:<processo>".
function listaProgramasSemRegra(alvo, itens, aoSalvar) {
  alvo.replaceChildren();
  if (!itens.length) { alvo.append(el('p', { class: 'mudo', text: 'Todos os programas em uso já têm classificação (ou ainda não há coleta).' })); return; }
  for (const x of itens) {
    alvo.append(el('div', { class: 'linha-pend' },
      el('strong', { text: x.nome === x.processo ? x.processo : `${x.nome} (${x.processo})` }),
      el('span', { class: 'mudo', text: `${fmtDur(x.segundos)} · ${x.usuarios} colaborador(es)` }),
      chipsQuem(x.quem),
      botoesClassificar(`app:${x.processo.toLowerCase()}`, aoSalvar)));
  }
}

function listaSemRegra(alvo, itens, aoSalvar, consulta) {
  alvo.replaceChildren();
  if (!itens.length) { alvo.append(el('p', { class: 'mudo', text: 'Todos os sites acessados já têm classificação.' })); return; }
  const q = consulta || `de=${somaDias(hoje(), -29)}&ate=${hoje()}`;
  for (const x of itens) {
    const painel = el('div', { class: 'pre-id', hidden: true });
    const abrir = el('button', { class: 'btn pequeno', type: 'button', onclick: () => {
      painel.hidden = !painel.hidden;
      abrir.textContent = painel.hidden ? 'Identificar' : 'Fechar';
      if (!painel.hidden && !painel.dataset.ok) { painel.dataset.ok = '1'; carregarPreId(painel, x.dominio, q); }
    } }, 'Identificar');
    alvo.append(el('div', { class: 'linha-pend' },
      el('strong', { text: x.dominio }),
      el('span', { class: 'mudo', text: `${fmtDur(x.segundos)} · ${x.visitas} acessos · ${x.usuarios} colaborador(es)` }),
      chipsQuem(x.quem), abrir,
      botoesClassificar(x.dominio, aoSalvar),
      painel));
  }
}

// Carrega o periodo (todos os colaboradores) e, se houver busca, refaz os indicadores so para quem bate com ela.
async function carregarBI() {
  if (!biEstado.periodo) biEstado.periodo = controlePeriodo($('bi-periodo'), 30, carregarBI);
  const vez = ++biEstado.vez;
  try {
    const q = biEstado.periodo.consulta();
    $('bi-xlsx').href = `api/export/relatorio.xlsx?${q}${P.eu.papel === 'admin' ? '&acessos=1' : ''}`;
    $('bi-csv-presenca').href = `api/export/presenca.csv?${q}`;
    $('bi-csv-prod').href = `api/export/produtividade.csv?${q}`;
    const todos = await api(`api/bi?${q}`);
    if (vez !== biEstado.vez) return;
    biEstado.todos = todos;
    await aplicarFiltroBI(vez);
  } catch (e) {
    $('bi-kpis').replaceChildren(el('p', { class: 'aviso', text: `Falha ao carregar: ${e.message}` }));
  }
}

// logins que a busca atual cobre (null = sem busca = todos)
function loginsDaBusca() {
  if (!biEstado.busca.trim() || !biEstado.todos) return null;
  if (biEstado.selecionado) return [biEstado.selecionado];
  return filtrarColab(biEstado.todos.colaboradores).map((c) => c.login);
}

// Mostra os numeros de TODOS (sem busca) ou pede ao servidor os numeros so de quem a busca cobre:
// cartoes, graficos por dia, sites e programas mais usados, tudo acompanha o que esta na tela.
async function aplicarFiltroBI(vez) {
  const logins = loginsDaBusca();
  let d = biEstado.todos;
  if (logins !== null && logins.length < biEstado.todos.colaboradores.length) {
    d = await api(`api/bi?${biEstado.periodo.consulta()}&logins=${encodeURIComponent(logins.join(','))}`);
  }
  if (vez !== biEstado.vez) return;          // chegou uma resposta mais nova: esta ficou velha
  biEstado.dados = d;
  desenharBI(d);
}

function desenharBI(d) {
  const q = biEstado.periodo.consulta();
  renderKpis(d.kpis);
  renderBiProd();
  renderBiLocal();
  atualizarResumoBI();
  colunasPorDia($('bi-dias-prod'), d.dias_produtividade.map((x) => ({
    dia: x.dia,
    partes: CATEGORIAS.map((c) => ({ valor: x[c.id], cor: c.cor, rotulo: `${c.nome}: ${fmtDur(x[c.id])}` })),
  })), (t) => `${(t / 3600).toFixed(1).replace('.', ',')} h`);
  legenda($('bi-leg-dias'), CATEGORIAS.map((c) => ({ nome: c.nome, cor: c.cor })));
  colunasPorDia($('bi-dias-local'), d.dias_local.map((x) => ({
    dia: x.dia,
    partes: [{ valor: x.presencial, cor: 'var(--presencial)', rotulo: `Presencial: ${x.presencial}` }, { valor: x.remoto, cor: 'var(--remoto)', rotulo: `Remoto: ${x.remoto}` },
      { valor: x.parcial, cor: 'var(--parcial)', rotulo: `Parcial: ${x.parcial}` }],
  })), (t) => String(t));
  legenda($('bi-leg-dias-local'), COR_LOCAL.slice(0, 3));
  for (const c of ['produtivo', 'improdutivo', 'neutro']) { renderTopo(`bi-top-${c}`, d.top[c]); renderTopo(`bi-prog-${c}`, (d.top_programas || {})[c] || []); }
  $('bi-semregra-painel').hidden = d.sem_regra.length === 0;
  listaSemRegra($('bi-semregra'), d.sem_regra, carregarBI, q);
  renderKpiDetalhe();
  carregarComparativo();
}
P.abas.bi = { carregar: carregarBI };
$('bi-imprimir').addEventListener('click', () => window.print());
$('bi-ordem').addEventListener('change', () => { if (biEstado.dados) renderBiProd(); });

// ---------- busca com lista de sugestoes ----------
const SUGESTOES_MAX = 8;
let sugAtiva = -1, sugLista = [], sugTimer = null;

function destacar(texto, termo) {
  const t = semAcento(termo.trim());
  const base = semAcento(texto);
  const i = t && base.length === texto.length ? base.indexOf(t) : -1;
  if (i < 0) return [document.createTextNode(texto)];
  return [document.createTextNode(texto.slice(0, i)), el('mark', { text: texto.slice(i, i + t.length) }), document.createTextNode(texto.slice(i + t.length))];
}

function fecharSugestoes() {
  $('bi-sugestoes').hidden = true; sugAtiva = -1;
  $('bi-busca').setAttribute('aria-expanded', 'false'); $('bi-busca').removeAttribute('aria-activedescendant');
}
function marcarSugestao(i) {
  sugAtiva = i;
  const itens = $('bi-sugestoes').querySelectorAll('li[role=option]');
  itens.forEach((li, k) => li.setAttribute('aria-selected', String(k === i)));
  const li = itens[i];
  if (li) { $('bi-busca').setAttribute('aria-activedescendant', li.id); li.scrollIntoView({ block: 'nearest' }); } else $('bi-busca').removeAttribute('aria-activedescendant');
}
function mostrarSugestoes() {
  const caixa = $('bi-sugestoes');
  const termo = biEstado.busca.trim();
  if (!termo || biEstado.selecionado || !biEstado.todos) { fecharSugestoes(); return; }
  const todas = filtrarColab(biEstado.todos.colaboradores);
  sugLista = todas.slice(0, SUGESTOES_MAX);
  caixa.replaceChildren();
  if (!todas.length) {
    caixa.append(el('li', { class: 'sug-vazio', role: 'presentation', text: 'Nenhum colaborador encontrado' }));
  } else {
    sugLista.forEach((c, i) => {
      const nomeBase = c.nome || c.colaborador;
      const linha2 = [c.login, c.setor, c.pct_produtivo === null || c.pct_produtivo === undefined ? '' : `${fmtPct(c.pct_produtivo)} produtivo`].filter(Boolean).join(' · ');
      const li = el('li', { id: `bi-sug-${i}`, role: 'option', 'aria-selected': 'false' },
        el('span', { class: 'sug-nome' }, ...destacar(nomeBase, termo)), el('small', { class: 'mudo', text: linha2 }));
      li.addEventListener('mousedown', (e) => { e.preventDefault(); escolherSugestao(c); });   // antes do blur do campo
      li.addEventListener('mousemove', () => { if (sugAtiva !== i) marcarSugestao(i); });
      caixa.append(li);
    });
    if (todas.length > SUGESTOES_MAX) caixa.append(el('li', { class: 'sug-rodape', role: 'presentation', text: `+ ${todas.length - SUGESTOES_MAX} colaborador(es): continue digitando ou tecle Enter para ver todos` }));
  }
  caixa.hidden = false; sugAtiva = -1;
  $('bi-busca').setAttribute('aria-expanded', 'true'); $('bi-busca').removeAttribute('aria-activedescendant');
}

function escolherSugestao(c) {
  fecharSugestoes();
  aplicarBuscaBI(c.colaborador, { selecionado: c.login });
}

function atualizarResumoBI() {
  const t = biEstado.busca.trim();
  $('bi-limpar').hidden = !t;
  if (!biEstado.dados || !biEstado.todos) { $('bi-resumo').textContent = ''; return; }
  const total = biEstado.todos.colaboradores.length;
  const n = t ? (loginsDaBusca() || []).length : total;
  $('bi-resumo').textContent = t
    ? (n ? `Indicadores de ${n} de ${total} colaborador(es): ${biEstado.selecionado ? biEstado.busca : '“' + t + '”'}` : `Nenhum colaborador encontrado para “${t}”`)
    : `${total} colaborador(es) com dados no período`;
}

// Aplica a busca: as listas mudam na hora e os numeros gerais (pedidos ao servidor) logo depois, sem disparar a cada letra.
function aplicarBuscaBI(valor, opcoes = {}) {
  biEstado.busca = valor;
  biEstado.selecionado = opcoes.selecionado || null;
  $('bi-busca').value = valor;
  if (biEstado.dados) { renderBiProd(); renderBiLocal(); renderKpiDetalhe(); }
  atualizarResumoBI();
  clearTimeout(sugTimer);
  const aplicar = async () => {
    if (!biEstado.todos) return;
    const vez = ++biEstado.vez;
    try { await aplicarFiltroBI(vez); } catch (e) { $('bi-resumo').textContent = `Falha ao filtrar: ${e.message}`; }
  };
  if (opcoes.imediato || opcoes.selecionado || !valor.trim()) aplicar(); else sugTimer = setTimeout(aplicar, 350);
}

const campoBusca = $('bi-busca');
campoBusca.addEventListener('input', (e) => { aplicarBuscaBI(e.target.value); mostrarSugestoes(); });
campoBusca.addEventListener('focus', () => { if (biEstado.busca.trim()) mostrarSugestoes(); });
campoBusca.addEventListener('blur', () => setTimeout(fecharSugestoes, 120));
campoBusca.addEventListener('keydown', (e) => {
  const aberta = !$('bi-sugestoes').hidden && sugLista.length > 0;
  if (e.key === 'ArrowDown') { e.preventDefault(); if (!aberta) mostrarSugestoes(); else marcarSugestao((sugAtiva + 1) % sugLista.length); }
  else if (e.key === 'ArrowUp' && aberta) { e.preventDefault(); marcarSugestao((sugAtiva - 1 + sugLista.length) % sugLista.length); }
  else if (e.key === 'Enter') {
    e.preventDefault();
    if (aberta && sugAtiva >= 0) { escolherSugestao(sugLista[sugAtiva]); return; }
    fecharSugestoes();
    aplicarBuscaBI(biEstado.busca, { imediato: true });
    // Enter com um unico resultado abre a ficha do colaborador
    const r = biEstado.todos ? filtrarColab(biEstado.todos.colaboradores) : [];
    if (r.length === 1) abrirColaborador(r[0].login);
  } else if (e.key === 'Escape') {
    if (!$('bi-sugestoes').hidden) fecharSugestoes(); else if (biEstado.busca) aplicarBuscaBI('');
  }
});
$('bi-limpar').addEventListener('click', () => { aplicarBuscaBI(''); fecharSugestoes(); campoBusca.focus(); });

// o menu Exportar fecha ao escolher uma opcao, ao clicar fora e com Esc
const menuExportar = $('bi-exportar');
menuExportar.addEventListener('click', (e) => { if (e.target.closest('.menu-lista a, .menu-lista button')) setTimeout(() => { menuExportar.open = false; }, 0); });
document.addEventListener('click', (e) => { if (menuExportar.open && !menuExportar.contains(e.target)) menuExportar.open = false; });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && menuExportar.open) { menuExportar.open = false; menuExportar.querySelector('summary').focus(); } });

// ---------- Home x Presencial (so administradores) ----------
let minSalvo = 3;
try { const v = parseInt(localStorage.getItem('comp_min_dias'), 10); if (v >= 1 && v <= 30) minSalvo = v; } catch (e) { /* sem armazenamento: usa o padrao */ }
const compEstado = { vez: 0, min: minSalvo };
const fmtMinDia = (seg) => (seg === null || seg === undefined ? '—' : seg >= 3600 ? `${Math.floor(seg / 3600)} h ${String(Math.round((seg % 3600) / 60)).padStart(2, '0')} min` : `${Math.round(seg / 60)} min`);
const fmtDifPp = (v) => (v === null || v === undefined ? '—' : Math.abs(v) < 2 ? '≈ igual' : `${v > 0 ? '+' : '−'}${String(Math.abs(v)).replace('.', ',')} pp`);
const fmtDifMin = (seg) => (seg === null || seg === undefined ? '—' : Math.abs(seg) < 300 ? '≈ igual' : `${seg > 0 ? '+' : '−'}${fmtMinDia(Math.abs(seg))}`);
const classeDif = (v, limite) => (v === null || v === undefined || Math.abs(v) < limite ? 'dif-igual' : v > 0 ? 'dif-mais' : 'dif-menos');

$('bi-home-min').addEventListener('change', (e) => {
  compEstado.min = parseInt(e.target.value, 10) || 3;
  try { localStorage.setItem('comp_min_dias', String(compEstado.min)); } catch (err) { /* so deixa de lembrar */ }
  carregarComparativo();
});

async function carregarComparativo() {
  const painel = $('bi-home');
  if (!painel || P.eu.papel !== 'admin' || !biEstado.periodo) return;
  const vez = ++compEstado.vez;
  const logins = loginsDaBusca();
  const sel = $('bi-home-min');
  if (![...sel.options].some((o) => o.value === String(compEstado.min))) sel.append(el('option', { value: String(compEstado.min), text: String(compEstado.min) }));
  sel.value = String(compEstado.min);
  const q = biEstado.periodo.consulta() + `&min=${compEstado.min}` + (logins !== null ? `&logins=${encodeURIComponent(logins.join(','))}` : '');
  $('bi-csv-comparativo').href = `api/export/comparativo.csv?${q}`;
  try {
    const r = await api(`api/comparativo?${q}`);
    if (vez !== compEstado.vez) return;
    desenharComparativo(r);
  } catch (e) {
    $('bi-home-geral').replaceChildren(el('p', { class: 'aviso', text: `Falha ao carregar o comparativo: ${e.message}` }));
  }
}

function cartaoHome(rotulo, cor, m, extra) {
  return el('div', { class: 'cartao', style: `--cor:${cor}` },
    el('div', { class: 'rotulo', text: rotulo }),
    el('div', { class: 'valor', text: fmtPct(m.pct_produtivo) }),
    el('div', { class: 'detalhe', text: `${fmtMinDia(m.prod_seg_dia)} produtivos por dia` }),
    el('div', { class: 'detalhe', text: extra }));
}

function desenharComparativo(r) {
  const g = r.geral;
  $('bi-home-sub').textContent = g.colaboradores ? `${g.colaboradores} colaborador(es) comparados` : '';
  const cartoes = $('bi-home-geral');
  cartoes.className = 'cartoes home-geral';
  cartoes.replaceChildren();
  if (g.colaboradores > 0) {
    cartoes.append(
      cartaoHome('No escritório', 'var(--presencial)', g.presencial, `${g.presencial.dias} dias no total`),
      cartaoHome('Em casa (home)', 'var(--remoto)', g.remoto, `${g.remoto.dias} dias no total`),
      el('div', { class: `cartao home-dif ${classeDif(g.dif_pct, 2)}` },
        el('div', { class: 'rotulo', text: 'Home em relação ao escritório' }),
        el('div', { class: 'valor', text: fmtDifPp(g.dif_pct) }),
        el('div', { class: 'detalhe', text: `Tempo produtivo por dia: ${fmtDifMin(g.dif_prod_seg_dia)}` })));
  }

  const corpo = document.querySelector('#bi-home-tabela tbody');
  corpo.replaceChildren();
  const barraPar = (a, b) => el('div', { class: 'home-barras', 'aria-hidden': 'true' },
    el('i', { class: 'b-pres', style: `width:${Math.min(100, a || 0)}%` }), el('i', { class: 'b-rem', style: `width:${Math.min(100, b || 0)}%` }));
  for (const c of r.colaboradores) {
    const p = c.presencial, h = c.remoto;
    const tr = el('tr', { class: 'clicavel', title: 'Abrir a ficha do colaborador', onclick: () => abrirColaborador(c.login) },
      el('td', { text: c.colaborador }),
      el('td', { class: 'nowrap', text: `${p.dias} · ${h.dias}` }),
      el('td', { class: 'nowrap' }, el('b', { text: fmtPct(p.pct_produtivo) })),
      el('td', { class: 'nowrap' }, el('b', { text: fmtPct(h.pct_produtivo) }), barraPar(p.pct_produtivo, h.pct_produtivo)),
      el('td', { class: `nowrap ${classeDif(c.dif_pct, 2)}`, text: fmtDifPp(c.dif_pct) }),
      el('td', { class: 'nowrap', text: fmtMinDia(p.prod_seg_dia) }),
      el('td', { class: 'nowrap', text: fmtMinDia(h.prod_seg_dia) }),
      el('td', { class: `nowrap ${classeDif(c.dif_prod_seg_dia, 300)}`, text: fmtDifMin(c.dif_prod_seg_dia) }));
    corpo.append(tr);
  }
  const vazio = !r.colaboradores.length;
  $('bi-home-tabela').hidden = vazio;
  const aviso = $('bi-home-vazio');
  aviso.hidden = !vazio;
  aviso.replaceChildren();
  if (vazio) {
    aviso.append(
      el('strong', { text: r.fora.length ? 'Ninguém tem dias suficientes nos dois modos neste período' : 'Sem dados de presença neste período' }),
      el('span', { class: 'mudo', text: r.fora.length
        ? `Para entrar na comparação é preciso ter pelo menos ${r.min_dias} dia(s) no escritório e ${r.min_dias} dia(s) de home. Quem está mais perto aparece abaixo. Você pode baixar o mínimo no seletor ao lado ou ampliar o período.`
        : 'Escolha um período com leituras de presença.' }));
  }

  // quem ficou de fora e quanto falta (os mais perto de entrar primeiro)
  const fora = $('bi-home-fora');
  const corpoFora = document.querySelector('#bi-home-fora-tabela tbody');
  corpoFora.replaceChildren();
  if (r.fora.length) {
    for (const x of r.fora) {
      const faltaP = Math.max(0, r.min_dias - x.dias_presencial), faltaH = Math.max(0, r.min_dias - x.dias_remoto);
      const falta = [faltaP ? `${faltaP} dia(s) no escritório` : '', faltaH ? `${faltaH} dia(s) de home` : ''].filter(Boolean).join(' e ');
      corpoFora.append(el('tr', { class: 'clicavel', onclick: () => abrirColaborador(x.login) },
        el('td', { text: x.colaborador }),
        el('td', { class: 'nowrap', text: String(x.dias_presencial) }),
        el('td', { class: 'nowrap', text: String(x.dias_remoto) }),
        el('td', { class: 'mudo', text: `faltam ${falta}` })));
    }
    fora.querySelector('summary').textContent = `Fora da comparação (${r.fora.length}${r.fora.length >= 50 ? '+' : ''}): não têm ${r.min_dias} dia(s) nos dois modos`;
    fora.hidden = false;
    fora.open = vazio;     // sem ninguem na comparacao, a lista ja vem aberta
  } else { fora.hidden = true; fora.open = false; }

  // dia a dia (so quando a busca traz um colaborador)
  const det = $('bi-home-detalhe');
  det.replaceChildren();
  const um = r.colaboradores.length === 1 && r.colaboradores[0].dias ? r.colaboradores[0] : null;
  if (um) {
    det.append(el('h3', { text: `Dia a dia de ${um.colaborador}` }));
    const t = el('table', { class: 'tabela' }, el('thead', null, el('tr', null, ...['Dia', 'Local do dia', 'Leituras (escritório · home)', '% produtivo', 'Produtivo', 'Uso total'].map((x) => el('th', { text: x })))));
    const tb = el('tbody');
    for (const d of um.dias) {
      tb.append(el('tr', null,
        el('td', { class: 'nowrap', text: `${diaBR(d.dia)}` }),
        el('td', null, el('span', { class: 'selo', style: `--cor:${d.modo === 'presencial' ? 'var(--presencial)' : 'var(--remoto)'}`, text: d.modo === 'presencial' ? 'Escritório' : 'Home' })),
        el('td', { class: 'nowrap', text: `${d.leituras_presencial} · ${d.leituras_remoto}` }),
        el('td', { class: 'nowrap', text: fmtPct(d.pct_produtivo) }),
        el('td', { class: 'nowrap', text: fmtDur(d.produtivo) }),
        el('td', { class: 'nowrap', text: fmtDur(d.produtivo + d.improdutivo + d.neutro) })));
    }
    t.append(tb);
    det.append(el('div', { class: 'tabela-wrap' }, t));
  }
}

// ---------- detalhe de um colaborador ----------
async function abrirColaborador(login) {
  const per = (biEstado.periodo && biEstado.periodo.de()) ? biEstado.periodo : null;
  const consulta = per ? per.consulta() : `de=${somaDias(hoje(), -29)}&ate=${hoje()}`;
  const corpo = gaveta('Carregando…', '');
  try {
    const d = await api(`api/colaborador?login=${encodeURIComponent(login)}&${consulta}`);
    $('g-titulo').textContent = d.colaborador.colaborador;
    $('g-sub').textContent = `${diaBR(d.de)} a ${diaBR(d.ate)}${d.colaborador.setor ? ' · ' + d.colaborador.setor : ''}`;
    const p = d.produtividade, t = p.totais, pr = d.presenca;
    corpo.append(el('div', { class: 'mini-kpis' },
      el('div', null, el('b', { text: fmtPct(t.pct_produtivo) }), el('span', { class: 'mudo', text: 'produtivo' })),
      el('div', null, el('b', { text: fmtDur(t.total_seg) }), el('span', { class: 'mudo', text: 'navegação' })),
      el('div', null, el('b', { text: String(pr.presenciais) }), el('span', { class: 'mudo', text: 'dias presenciais' })),
      el('div', null, el('b', { text: String(pr.remotos) }), el('span', { class: 'mudo', text: 'dias remotos' })),
      el('div', null, el('b', { text: String(pr.parciais || 0) }), el('span', { class: 'mudo', text: 'dias parciais' }))));

    corpo.append(el('h4', { text: 'Tempo por categoria' }),
      barraEmpilhada(CATEGORIAS.map((c) => ({ valor: t.segundos[c.id], cor: c.cor, rotulo: `${c.nome}: ${fmtDur(t.segundos[c.id])}` })), 'Tempo por categoria'),
      el('div', { class: 'legenda' }, ...CATEGORIAS.map((c) => el('span', null, el('i', { style: `--cor:${c.cor}` }), `${c.nome}: ${fmtDur(t.segundos[c.id])}`))));

    corpo.append(el('h4', { text: 'Presença por dia útil' }));
    const dias = el('div', { class: 'dias-chips' });
    for (const x of pr.detalhe) {
      dias.append(el('span', { class: 'chip-dia', style: `--cor:${COR[x.status] || 'var(--semsinal)'}`, title: `${diaBR(x.dia)}: ${x.status}${x.unidade ? ' ' + x.unidade : ''}` },
        el('b', { text: diaCurto(x.dia) }), x.status === 'Presencial' ? `Pres. ${x.unidade}` : x.status));
    }
    corpo.append(dias);

    corpo.append(el('h4', { text: 'Sites mais acessados' }));
    const topo = [];
    for (const c of CATEGORIAS) for (const x of p.top[c.id].slice(0, 5)) topo.push({ ...x, cat: c.id });
    topo.sort((a, b) => b.segundos - a.segundos);
    const ul = el('ul', { class: 'lista-simples' });
    for (const x of topo.slice(0, 12)) ul.append(el('li', null, seloCategoria(x.cat), el('span', { text: x.dominio }), el('span', { class: 'mudo', text: `${fmtDur(x.segundos)} · ${x.visitas}×` })));
    corpo.append(topo.length ? ul : el('p', { class: 'mudo', text: 'Nenhum acesso registrado.' }));

    corpo.append(el('h4', { text: `Últimos acessos (${d.visitas.length})` }));
    const vis = el('ul', { class: 'lista-simples compacta' });
    for (const v of d.visitas.slice(0, 80)) {
      vis.append(el('li', null,
        el('time', { class: 'mudo', text: dataCurta(v.ts) }), seloCategoria(v.categoria),
        el('span', { class: 'quebra', title: v.url, text: v.titulo ? `${v.dominio} — ${v.titulo}` : v.dominio })));
    }
    corpo.append(d.visitas.length ? vis : el('p', { class: 'mudo', text: 'Sem acessos detalhados (o detalhe é mantido por 30 dias).' }));
  } catch (e) {
    corpo.append(el('p', { class: 'aviso', text: `Falha ao carregar: ${e.message}` }));
  }
}
