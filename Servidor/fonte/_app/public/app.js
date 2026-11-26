'use strict';
// Núcleo do painel + aba "Presença agora".
// Todo texto vindo do servidor entra no DOM via textContent (nunca innerHTML).

const P = {
  eu: null,
  abas: {},          // nome -> { carregar() }
  abaAtual: 'presenca',
};

const COR = {
  'Presencial': 'var(--presencial)',
  'Presencial via VPN': 'var(--presencial-vpn)',
  'Remoto via VPN': 'var(--vpn)',
  'Remoto': 'var(--remoto)',
  'Sem rede': 'var(--semrede)',
  'Sem sinal': 'var(--semsinal)',
  'No ar': 'var(--presencial)',
  'Fora do ar': 'var(--semrede)',
  'Sem registro': 'var(--semsinal)',
  'Parcial': 'var(--parcial)',
};
const ORDEM = ['Presencial', 'Presencial via VPN', 'Remoto via VPN', 'Remoto', 'Sem rede', 'Sem sinal', 'No ar', 'Fora do ar'];
// servidores com batimento: so interessa se esta no ar (nao a localizacao do ultimo usuario)
const ESTADOS_SERVIDOR = ['No ar', 'Fora do ar'];
const SITUACOES_GRAFICO = ['Presencial', 'Presencial via VPN', 'Remoto via VPN', 'Remoto', 'Sem rede'];
const CATEGORIAS = [
  { id: 'produtivo', nome: 'Produtivo', cor: 'var(--produtivo)' },
  { id: 'neutro', nome: 'Neutro', cor: 'var(--neutro)' },
  { id: 'improdutivo', nome: 'Improdutivo', cor: 'var(--improdutivo)' },
];
const ehPresencial = (r) => r === 'Presencial' || r === 'Presencial via VPN';
const OCIOSO_ALERTA_SEG = 30 * 60;

function el(tag, props, ...filhos) {
  const n = document.createElement(tag);
  if (props) {
    for (const [k, v] of Object.entries(props)) {
      if (k === 'class') n.className = v;
      else if (k === 'text') n.textContent = v;
      else if (k === 'style') n.setAttribute('style', v);
      else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
      else if (v === false || v === null || v === undefined) continue;
      else n.setAttribute(k, v === true ? '' : v);
    }
  }
  for (const f of filhos) if (f !== null && f !== undefined && f !== false) n.append(f);
  return n;
}
const $ = (id) => document.getElementById(id);

// ---------- formatação ----------
function fmtDur(seg) {
  seg = Math.round(seg || 0);
  if (seg < 60) return seg > 0 ? `${seg} s` : '0';
  const min = Math.round(seg / 60);
  if (min < 60) return `${min} min`;
  return `${Math.floor(min / 60)} h ${String(min % 60).padStart(2, '0')} min`;
}
const fmtPct = (v) => (v === null || v === undefined ? '—' : `${String(v).replace('.', ',')}%`);
const fmtMoeda = (v) => (v === null || v === undefined ? '—' : v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' }));
function quando(min) {
  if (min < 1) return 'agora';
  if (min < 60) return `${min} min`;
  const h = Math.floor(min / 60);
  if (h < 24) return `${h} h ${min % 60} min`;
  return `${Math.floor(h / 24)} d`;
}
const dataCurta = (ts) => new Date(ts).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
const diaBR = (iso) => { const [a, m, d] = iso.split('-'); return `${d}/${m}/${a}`; };
const diaCurto = (iso) => { const [, m, d] = iso.split('-'); return `${d}/${m}`; };
const hoje = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
function somaDias(iso, n) {
  const [a, m, d] = iso.split('-').map(Number);
  const x = new Date(a, m - 1, d + n);
  return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`;
}

// ---------- API ----------
// Reconfirma a senha (e o código do app autenticador, se houver) para ações sensíveis. Devolve true se confirmou.
function confirmarIdentidade(pedeCodigo) {
  return new Promise((resolve) => {
    const senha = el('input', { type: 'password', autocomplete: 'current-password', required: true });
    const codigo = pedeCodigo ? el('input', { type: 'text', inputmode: 'numeric', autocomplete: 'one-time-code', maxlength: '12', required: true }) : null;
    const erro = el('p', { class: 'erro', role: 'alert', hidden: true });
    const cancelar = el('button', { class: 'btn', type: 'button', text: 'Cancelar' });
    const ok = el('button', { class: 'btn primario', type: 'submit', text: 'Confirmar' });
    const form = el('form', { class: 'dlg', method: 'dialog' },
      el('h3', { text: 'Confirme sua identidade' }),
      el('p', { text: 'Esta ação é sensível. Digite sua senha' + (pedeCodigo ? ' e o código do aplicativo autenticador' : '') + ' para continuar.' }),
      el('label', null, 'Senha', senha), codigo ? el('label', null, 'Código de verificação', codigo) : null, erro,
      el('div', { class: 'dlg-acoes' }, cancelar, ok));
    const dlg = el('dialog', null, form);
    document.body.append(dlg);
    let feito = false;
    const fechar = (v) => { if (feito) return; feito = true; dlg.close(); dlg.remove(); resolve(v); };
    cancelar.addEventListener('click', () => fechar(false));
    dlg.addEventListener('cancel', () => fechar(false));
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      ok.disabled = true; erro.hidden = true;
      try {
        const headers = { 'Content-Type': 'application/json' };
        if (P.eu) headers['X-CSRF-Token'] = P.eu.csrf;
        const r = await fetch('api/reautenticar', { method: 'POST', credentials: 'same-origin', headers, body: JSON.stringify({ senha: senha.value, codigo: codigo ? codigo.value : '' }) });
        const j = await r.json().catch(() => ({}));
        if (r.ok) return fechar(true);
        erro.textContent = j.erro || `HTTP ${r.status}`; erro.hidden = false; senha.value = '';
      } catch (err) { erro.textContent = 'Sem conexão com o servidor.'; erro.hidden = false; }
      ok.disabled = false; senha.focus();
    });
    dlg.showModal(); senha.focus();
  });
}

async function api(caminho, { metodo = 'GET', corpo } = {}, jaConfirmou = false) {
  const headers = {};
  if (corpo !== undefined) headers['Content-Type'] = 'application/json';
  if (metodo !== 'GET' && P.eu) headers['X-CSRF-Token'] = P.eu.csrf;
  const r = await fetch(caminho, { method: metodo, credentials: 'same-origin', headers, body: corpo === undefined ? undefined : JSON.stringify(corpo) });
  if (r.status === 401) { location.href = 'login'; throw new Error('sessão expirada'); }
  const j = await r.json().catch(() => ({}));
  if (r.status === 403 && j.precisa_reautenticar && !jaConfirmou) {
    if (await confirmarIdentidade(!!j.pede_codigo)) return api(caminho, { metodo, corpo }, true);
    throw new Error('Ação cancelada.');
  }
  if (!r.ok) throw new Error(j.erro || `HTTP ${r.status}`);
  return j;
}

// ---------- componentes ----------
function selo(status) {
  return el('span', { class: 'selo', style: `--cor:${COR[status] || 'var(--semsinal)'}`, text: status });
}
function seloCategoria(cat) {
  const c = CATEGORIAS.find((x) => x.id === cat) || CATEGORIAS[1];
  return el('span', { class: 'selo', style: `--cor:${c.cor}`, text: c.nome });
}
function legenda(alvo, itens) {
  alvo.replaceChildren(...itens.map((i) => el('span', null, el('i', { style: `--cor:${i.cor}` }), i.nome)));
}

// Barra horizontal empilhada. partes: [{valor, cor, rotulo}]
function barraEmpilhada(partes, descricao) {
  const total = partes.reduce((n, p) => n + p.valor, 0);
  const barra = el('div', { class: 'barra-h', role: 'img', 'aria-label': descricao });
  if (total <= 0) { barra.classList.add('vazia'); return barra; }
  for (const p of partes) {
    if (p.valor <= 0) continue;
    barra.append(el('div', { class: 'seg-h', title: p.rotulo, style: `width:${(p.valor / total) * 100}%;background:${p.cor}` }));
  }
  return barra;
}

// Controle de período (de/ate + atalhos). Devolve { de(), ate() }. onChange é chamado ao mudar.
function controlePeriodo(alvo, dias, onChange) {
  const de = el('input', { type: 'date', 'aria-label': 'Data inicial' });
  const ate = el('input', { type: 'date', 'aria-label': 'Data final' });
  const ymd = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  // faixas prontas: cada uma devolve [de, ate]; o botao "ativo" e o que bate com as datas atuais
  const PRONTOS = [
    { id: '7', rotulo: '7 dias', faixa: () => [somaDias(hoje(), -6), hoje()] },
    { id: '30', rotulo: '30 dias', faixa: () => [somaDias(hoje(), -29), hoje()] },
    { id: '90', rotulo: '90 dias', faixa: () => [somaDias(hoje(), -89), hoje()] },
    { id: 'mes', rotulo: 'Este mês', faixa: () => [hoje().slice(0, 8) + '01', hoje()] },
    { id: 'passado', rotulo: 'Mês passado', faixa: () => { const [a, m] = hoje().split('-').map(Number); return [ymd(new Date(a, m - 2, 1)), ymd(new Date(a, m - 1, 0))]; } },
  ];
  let personalizado = false;
  const botoes = PRONTOS.map((p) => el('button', { type: 'button', class: 'seg-btn', onclick: () => {
    const [d, a] = p.faixa(); de.value = d; ate.value = a; personalizado = false; atualizar(); onChange();
  } }, p.rotulo));
  const btnPers = el('button', { type: 'button', class: 'seg-btn', onclick: () => { personalizado = true; atualizar(); de.focus(); } }, 'Personalizado');
  const datas = el('span', { class: 'periodo-datas', hidden: true }, el('label', null, 'De ', de), el('label', null, 'até ', ate));
  const resumo = el('span', { class: 'periodo-resumo mudo' });
  const fmt = (s) => (s ? s.split('-').reverse().join('/') : '');

  function atualizar() {
    let achou = -1;
    PRONTOS.forEach((p, i) => { const [d, a] = p.faixa(); if (!personalizado && de.value === d && ate.value === a) achou = i; });
    botoes.forEach((b, i) => b.setAttribute('aria-pressed', String(i === achou)));
    const pers = achou < 0;                       // datas que nao batem com nenhuma faixa pronta = personalizado
    btnPers.setAttribute('aria-pressed', String(pers));
    datas.hidden = !pers;
    const n = de.value && ate.value ? Math.round((Date.parse(ate.value) - Date.parse(de.value)) / 86400000) + 1 : 0;
    resumo.textContent = n > 0 ? `${fmt(de.value)} a ${fmt(ate.value)} · ${n} dia${n > 1 ? 's' : ''}` : '';
  }

  ate.value = hoje(); de.value = somaDias(hoje(), -(dias - 1));
  alvo.classList.add('periodo-bloco');
  alvo.replaceChildren(el('div', { class: 'seg', role: 'group', 'aria-label': 'Período' }, ...botoes, btnPers), datas, resumo);
  // o intervalo nunca fica invertido: mexeu no inicio alem do fim, o fim acompanha, e vice-versa
  const aoMudarData = (quem) => () => {
    if (de.value && ate.value && de.value > ate.value) { if (quem === 'de') ate.value = de.value; else de.value = ate.value; }
    personalizado = true; atualizar(); onChange();
  };
  de.addEventListener('change', aoMudarData('de')); ate.addEventListener('change', aoMudarData('ate'));
  atualizar();
  return {
    de: () => de.value, ate: () => ate.value,
    consulta: () => `de=${encodeURIComponent(de.value)}&ate=${encodeURIComponent(ate.value)}`,
  };
}

function gaveta(titulo, sub) {
  $('g-titulo').textContent = titulo;
  $('g-sub').textContent = sub || '';
  const corpo = $('g-corpo');
  corpo.replaceChildren();
  $('gaveta').hidden = false;
  $('gaveta-fundo').hidden = false;
  $('gaveta').scrollTop = 0;
  return corpo;
}

// ---------- menu lateral (celular: abre como gaveta) ----------
function fecharMenu() {
  const l = $('lateral'); if (!l) return;
  l.classList.remove('aberta'); $('lateral-fundo').classList.remove('aberto'); $('lateral-fundo').hidden = true;
  $('btn-menu').setAttribute('aria-expanded', 'false');
}
function alternarMenu() {
  const l = $('lateral'); const abrir = !l.classList.contains('aberta');
  l.classList.toggle('aberta', abrir); $('lateral-fundo').classList.toggle('aberto', abrir); $('lateral-fundo').hidden = !abrir;
  $('btn-menu').setAttribute('aria-expanded', String(abrir));
}

// ---------- abas ----------
function mostrarAba(nome) {
  if (!document.getElementById(`aba-${nome}`)) nome = 'presenca';
  P.abaAtual = nome;
  for (const b of document.querySelectorAll('#abas button')) b.classList.toggle('ativa', b.dataset.aba === nome);
  const atual = document.querySelector(`#abas button[data-aba="${nome}"]`);
  if (atual) { $('titulo-pagina').textContent = atual.textContent; $('modulo-pagina').textContent = atual.closest('.modulo').dataset.titulo || ''; }
  fecharMenu();
  $('gaveta').hidden = true; $('gaveta-fundo').hidden = true;
  for (const s of document.querySelectorAll('.aba')) s.hidden = s.id !== `aba-${nome}`;
  if (location.hash !== `#${nome}`) history.replaceState(null, '', `#${nome}`);
  const a = P.abas[nome];
  if (a && a.carregar) a.carregar();
}

// ---------- aba Presença ----------
const estado = { itens: [], filtroStatus: '', filtroUnidade: '', busca: '', ordem: 'colaborador', asc: true, onlineMin: 45 };

const resultadoDe = (i) => (i.resultado === 'Presencial' && i.vpn_ativa === 'sim' ? 'Presencial via VPN' : i.resultado);
const statusDe = (i) => (i.servidor && i.batimento ? (i.ativo ? 'No ar' : 'Fora do ar') : (i.ativo ? resultadoDe(i) : 'Sem sinal'));

function observacoes(i) {
  const out = [];
  if (i.servidor && i.batimento) {
    if (i.boot_em) out.push(el('span', { class: 'etq', text: `ligado desde ${new Date(i.boot_em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}` }));
  } else if (!i.ativo) out.push(el('span', { class: 'etq', text: `última posição: ${resultadoDe(i)}${i.unidade ? ' ' + i.unidade : ''}` }));
  if (i.servidor) out.unshift(el('span', { class: 'etq', text: 'Servidor' }));
  if (i.sessao_remota === 'sim') out.push(el('span', { class: 'etq alerta', text: 'Sessão RDP' }));
  if (i.bloqueada === 'sim') out.push(el('span', { class: 'etq', text: 'Tela bloqueada' }));
  else if (i.ocioso_seg !== null && i.ocioso_seg >= OCIOSO_ALERTA_SEG) {
    out.push(el('span', { class: 'etq', text: `Ocioso ${Math.round(i.ocioso_seg / 60)} min` }));
  }
  if (i.versao_agente) out.push(el('span', { class: 'etq', text: `agent v${i.versao_agente}` }));
  if (i.ativo && i.confianca && i.confianca !== 'alta') out.push(el('span', { class: 'etq alerta', text: `Confiança ${i.confianca}` }));
  return out;
}

function renderCartoes() {
  const cont = {};
  const porUnidade = { 'Presencial': {}, 'Presencial via VPN': {} };
  for (const i of estado.itens) {
    const s = statusDe(i);
    cont[s] = (cont[s] || 0) + 1;
    if (porUnidade[s]) porUnidade[s][i.unidade || '?'] = (porUnidade[s][i.unidade || '?'] || 0) + 1;
  }
  const alvo = $('cartoes');
  alvo.replaceChildren();
  alvo.append(el('button', { class: 'cartao', type: 'button', onclick: () => definirStatus('') },
    el('div', { class: 'rotulo', text: 'Total de máquinas' }),
    el('div', { class: 'valor', text: String(estado.itens.length) }),
    el('div', { class: 'detalhe', text: 'vistas nos últimos 30 dias' })));
  const temServidor = estado.itens.some((i) => i.servidor && i.batimento);
  for (const s of ORDEM) {
    if (ESTADOS_SERVIDOR.includes(s) && !temServidor) continue;
    const det = porUnidade[s] ? Object.entries(porUnidade[s]).sort().map(([u, n]) => `${u}: ${n}`).join(' · ') : '';
    alvo.append(el('button', { class: 'cartao', type: 'button', style: `--cor:${COR[s]}`, onclick: () => definirStatus(s) },
      el('div', { class: 'rotulo', text: s }),
      el('div', { class: 'valor', text: String(cont[s] || 0) }),
      el('div', { class: 'detalhe', text: det })));
  }
}
function definirStatus(s) {
  estado.filtroStatus = s;
  $('f-status').value = s;
  renderTabela();
}

function valorOrdem(i, k) {
  if (k === 'status') return ORDEM.indexOf(statusDe(i));
  if (k === 'idade_min') return i.idade_min;
  return String(i[k] || '').toLowerCase();
}
function renderTabela() {
  const termo = estado.busca.trim().toLowerCase();
  let lista = estado.itens.filter((i) => {
    if (estado.filtroStatus && statusDe(i) !== estado.filtroStatus) return false;
    if (estado.filtroUnidade && i.unidade !== estado.filtroUnidade) return false;
    if (termo && !(`${i.colaborador} ${i.usuario} ${i.host}`.toLowerCase().includes(termo))) return false;
    return true;
  });
  const k = estado.ordem;
  lista = lista.slice().sort((a, b) => {
    const x = valorOrdem(a, k), y = valorOrdem(b, k);
    const c = x < y ? -1 : x > y ? 1 : 0;
    return estado.asc ? c : -c;
  });
  const corpo = document.querySelector('#tabela tbody');
  corpo.replaceChildren();
  for (const i of lista) {
    const tr = el('tr', { class: 'linha', tabindex: '0', onclick: () => abrirHistoricoMaquina(i) },
      el('td', { text: i.servidor ? `Último usuário: ${i.colaborador || '—'}` : (i.colaborador || '—') }),
      el('td', { text: i.host }),
      el('td', null, selo(statusDe(i))),
      el('td', { text: !(i.servidor && i.batimento) && i.ativo && ehPresencial(resultadoDe(i)) ? i.unidade : '—' }),
      el('td', { text: quando(i.idade_min) }),
      el('td', { class: 'obs' }, ...observacoes(i)));
    tr.addEventListener('keydown', (e) => { if (e.key === 'Enter') abrirHistoricoMaquina(i); });
    corpo.append(tr);
  }
  $('vazio').hidden = lista.length > 0;
}

function renderUnidades() {
  const sel = $('f-unidade');
  const atual = sel.value;
  const unidades = [...new Set(estado.itens.map((i) => i.unidade).filter(Boolean))].sort();
  sel.replaceChildren(el('option', { value: '', text: 'Todas as unidades' }), ...unidades.map((u) => el('option', { value: u, text: u })));
  sel.value = unidades.includes(atual) ? atual : '';
  estado.filtroUnidade = sel.value;
}

function renderAviso() {
  const aviso = $('aviso');
  const algumAtivo = estado.itens.some((i) => i.ativo);
  if (estado.itens.length && !algumAtivo) {
    aviso.hidden = false;
    aviso.textContent = 'Nenhuma máquina enviou sinal recentemente (provavelmente computadores desligados ou sem rede). Mostrando a última posição conhecida.';
  } else aviso.hidden = true;
}

async function abrirHistoricoMaquina(i) {
  const corpo = gaveta(i.servidor ? `${i.host} (servidor)` : (i.colaborador || i.host), `${i.host} · últimas 48 h${i.servidor ? ' · último usuário: ' + (i.colaborador || '—') : ''}`);
  const lista = el('ol', { class: 'linha-tempo' }, el('li', { class: 'mudo', text: 'Carregando…' }));
  corpo.append(lista);
  if (i.login) corpo.append(el('p', null, el('button', { class: 'btn', type: 'button', onclick: () => abrirColaborador(i.login) }, 'Ver produtividade deste colaborador')));
  if (P.eu.papel === 'admin') {
    // limpeza de máquinas antigas (ex.: PC renomeado): ocultar é reversível; excluir apaga as leituras da máquina
    corpo.append(el('h4', { text: 'Administração da máquina' }), el('p', { class: 'grupo-btn' },
      el('button', { class: 'btn', type: 'button', onclick: async () => {
        try { await api('api/servidores', { metodo: 'POST', corpo: { host: i.host, servidor: !i.servidor } }); $('gaveta').hidden = true; carregarPresenca(); }
        catch (e) { alert(e.message); }
      } }, i.servidor ? 'Desmarcar como servidor' : 'Marcar como servidor'),
      el('button', { class: 'btn', type: 'button', onclick: async () => {
        try { await api('api/maquinas/ocultar', { metodo: 'POST', corpo: { host: i.host } }); $('gaveta').hidden = true; carregarPresenca(); }
        catch (e) { alert(e.message); }
      } }, 'Ocultar do painel'),
      el('button', { class: 'btn', type: 'button', onclick: async () => {
        if (!confirm(`Excluir TODAS as leituras de presença da máquina ${i.host}? Não dá para desfazer. Os relatórios por colaborador não são alterados.`)) return;
        try { const r = await api(`api/maquinas?host=${encodeURIComponent(i.host)}`, { metodo: 'DELETE' }); $('gaveta').hidden = true; carregarPresenca(); alert(`${r.leituras_removidas} leitura(s) removida(s).`); }
        catch (e) { alert(e.message); }
      } }, 'Excluir leituras')),
      el('p', { class: 'mudo pequeno', text: 'Ocultar tira a máquina da lista; ela volta sozinha se enviar dados de novo.' }));
  }
  try {
    const r = await api(`api/historico?host=${encodeURIComponent(i.host)}&horas=48`);
    lista.replaceChildren();
    const blocos = [];
    for (const h of r.itens.slice().reverse()) {
      h.resultado = resultadoDe(h);
      const chave = `${h.resultado}|${h.unidade}`;
      const ult = blocos[blocos.length - 1];
      if (ult && ult.chave === chave && h.ts - ult.fim <= 90 * 60000) { ult.fim = h.ts; ult.n++; } else blocos.push({ chave, ini: h.ts, fim: h.ts, n: 1, h });
    }
    if (!blocos.length) lista.append(el('li', { class: 'mudo', text: 'Sem registros.' }));
    for (const b of blocos.reverse()) {
      const mesmoDia = new Date(b.ini).toDateString() === new Date(b.fim).toDateString();
      const faixa = b.ini === b.fim ? dataCurta(b.ini) : `${dataCurta(b.ini)} → ${mesmoDia ? dataCurta(b.fim).slice(-5) : dataCurta(b.fim)}`;
      lista.append(el('li', null, el('time', { text: faixa }), selo(b.h.resultado), el('span', { class: 'mudo', text: ehPresencial(b.h.resultado) ? b.h.unidade : '' })));
    }
  } catch (e) {
    lista.replaceChildren(el('li', { class: 'mudo', text: 'Não foi possível carregar o histórico.' }));
  }
}

function renderGrafico(dias) {
  const g = $('grafico');
  g.replaceChildren();
  const max = Math.max(1, ...dias.map((d) => d.total));
  for (const d of dias) {
    const barra = el('div', { class: 'barra', style: `height:${Math.round((d.total / max) * 130)}px` });
    for (const s of SITUACOES_GRAFICO) {
      const n = d.resultados[s] || 0;
      if (n) barra.append(el('div', { class: 'seg', title: `${s}: ${n}`, style: `background:${COR[s]};height:${(n / d.total) * 100}%` }));
    }
    g.append(el('div', { class: 'col' }, el('div', { class: 'tot', text: String(d.total) }), barra, el('div', { class: 'dia', text: diaCurto(d.dia) })));
  }
  legenda($('legenda'), SITUACOES_GRAFICO.map((s) => ({ nome: s, cor: COR[s] })));
  if (!dias.length) g.append(el('p', { class: 'mudo', text: 'Ainda sem dados.' }));
}

async function carregarPresenca() {
  try {
    const [est, res] = await Promise.all([api('api/estado'), api('api/resumo?dias=14')]);
    estado.itens = est.itens;
    estado.onlineMin = est.online_min;
    renderCartoes(); renderUnidades(); renderTabela(); renderAviso(); renderGrafico(res.itens);
    $('atualizado').textContent = `Atualizado às ${new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}`;
  } catch (e) {
    $('atualizado').textContent = 'Falha ao atualizar';
  }
}
P.abas.presenca = { carregar: carregarPresenca };

$('busca').addEventListener('input', (e) => { estado.busca = e.target.value; renderTabela(); });
$('f-status').addEventListener('change', (e) => { estado.filtroStatus = e.target.value; renderTabela(); });
$('f-unidade').addEventListener('change', (e) => { estado.filtroUnidade = e.target.value; renderTabela(); });
const fecharGaveta = () => { $('gaveta').hidden = true; $('gaveta-fundo').hidden = true; };
$('g-fechar').addEventListener('click', fecharGaveta);
$('gaveta-fundo').addEventListener('click', fecharGaveta);
new MutationObserver(() => { if ($('gaveta').hidden) $('gaveta-fundo').hidden = true; }).observe($('gaveta'), { attributes: true, attributeFilter: ['hidden'] });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { fecharGaveta(); fecharMenu(); } });
$('btn-menu').addEventListener('click', alternarMenu);
$('lateral-fundo').addEventListener('click', fecharMenu);
for (const th of document.querySelectorAll('th[data-ord]')) {
  th.addEventListener('click', () => {
    const k = th.dataset.ord;
    if (estado.ordem === k) estado.asc = !estado.asc; else { estado.ordem = k; estado.asc = true; }
    renderTabela();
  });
}
