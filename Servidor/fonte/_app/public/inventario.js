'use strict';
// Aba Inventário: ativos (notebooks, desktops...) com o que o agent coleta (SO, RAM, disco, IP) e os campos de controle
// (status, responsável, localização, comentários). Importa o CSV do "Relatório de Ativos" e exporta no mesmo modelo.

const DIAS_SEM_CONTATO = 7;
const invEstado = {
  itens: [], status: [], agora: Date.now(),
  filtro: { busca: '', tipos: new Set(), status: new Set(), local: '', fab: '', modelo: '', so: '', ram: '', disco: '', foco: '' },
  ord: { campo: 'chave', asc: true },
};

const TIPOS = [['NOTEBOOK', 'Notebooks'], ['DESKTOP', 'Desktops'], ['SERVIDOR', 'Servidores'], ['OUTROS', 'Outros / sem tipo']];
const STATUS_CHIPS = [['INDISPONÍVEL', 'Em uso'], ['DISPONÍVEL', 'Disponíveis'], ['REPARO', 'Em reparo'], ['INUTILIZÁVEL', 'Inutilizáveis'], ['(SEM)', 'Sem status']];

const tipoGrupo = (x) => (['NOTEBOOK', 'DESKTOP', 'SERVIDOR'].includes(x.tipo) ? x.tipo : 'OUTROS');
const statusGrupo = (x) => x.status || '(SEM)';
const semContato = (x) => x.tem_agente && (x.ultimo_contato === null || (invEstado.agora - x.ultimo_contato) > DIAS_SEM_CONTATO * 86400000);
const semCadastro = (x) => x.origem === 'agente' && !x.status;
const rotuloDisco = (x) => (x.discos || []).map((d) => `${d.tipo} ${d.gb} GB`).join(' + ');
const rotuloSO = (x) => `${(x.so || '').replace('Microsoft ', '')} ${x.so_exibicao || ''}`.trim();
const equip = (x) => [x.fabricante, x.modelo].filter(Boolean).join(' ');
const invTxt = (x) => `${x.num_inventario || x.chave} ${x.host} ${x.nome_ativo} ${x.serie} ${x.modelo} ${x.responsavel} ${x.ultimo_usuario} ${x.localizacao} ${x.ips} ${x.ip_saida} ${x.comentarios}`.toLowerCase();

// $excluir: grupo cujo filtro nao entra na conta (para mostrar quantos itens cada chip traria)
function invFiltrados(excluir) {
  const f = invEstado.filtro;
  const t = f.busca.trim().toLowerCase();
  return invEstado.itens.filter((x) => {
    if (t && !invTxt(x).includes(t)) return false;
    if (excluir !== 'tipos' && f.tipos.size && !f.tipos.has(tipoGrupo(x))) return false;
    if (excluir !== 'status' && f.status.size && !f.status.has(statusGrupo(x))) return false;
    if (f.local && x.localizacao !== f.local) return false;
    if (f.fab && x.fabricante !== f.fab) return false;
    if (f.modelo && x.modelo !== f.modelo) return false;
    if (f.so && rotuloSO(x) !== f.so) return false;
    if (f.ram === 'le4' && !(x.ram_gb > 0 && x.ram_gb <= 4)) return false;
    if (f.ram === '8' && x.ram_gb !== 8) return false;
    if (f.ram === '16' && x.ram_gb !== 16) return false;
    if (f.ram === 'ge32' && !(x.ram_gb >= 32)) return false;
    if (f.ram === 'sem' && x.ram_gb) return false;
    const discos = x.discos || [];
    if (f.disco === 'ssd' && !discos.some((d) => d.tipo === 'SSD' || d.tipo === 'NVMe')) return false;
    if (f.disco === 'nvme' && !discos.some((d) => d.tipo === 'NVMe')) return false;
    if (f.disco === 'hdd' && !discos.some((d) => d.tipo === 'HDD')) return false;
    if (f.disco === 'sem' && discos.length) return false;
    if (f.foco === 'agente' && !x.tem_agente) return false;
    if (f.foco === 'sem-agente' && x.tem_agente) return false;
    if (f.foco === 'sem-contato' && !semContato(x)) return false;
    if (f.foco === 'sem-cadastro' && !semCadastro(x)) return false;
    return true;
  });
}

const INV_ORDEM = {
  chave: (x) => x.num_inventario || x.chave, equip: (x) => equip(x), status: (x) => x.status, resp: (x) => x.responsavel || x.ultimo_usuario,
  sistema: (x) => rotuloSO(x), rede: (x) => x.ips, contato: (x) => x.ultimo_contato,
};
function invOrdenar(lista) {
  const { campo, asc } = invEstado.ord;
  const chave = INV_ORDEM[campo] || INV_ORDEM.chave;
  const vazio = (v) => v === null || v === undefined || v === '';
  return lista.slice().sort((a, b) => {
    const va = chave(a), vb = chave(b);
    if (vazio(va) && vazio(vb)) return 0;
    if (vazio(va)) return 1;      // vazios sempre no fim
    if (vazio(vb)) return -1;
    const c = typeof va === 'number' && typeof vb === 'number' ? va - vb : String(va).localeCompare(String(vb), 'pt-BR', { numeric: true });
    return asc ? c : -c;
  });
}

function invChips(idAlvo, opcoes, selecionados, grupoFn, chaveGrupo) {
  const base = invFiltrados(chaveGrupo);
  const alvo = $(idAlvo);
  const todos = el('button', { type: 'button', class: 'chip', 'aria-pressed': String(selecionados.size === 0), onclick: () => { selecionados.clear(); invAtualizar(); } },
    'Todos', el('span', { class: 'n', text: String(base.length) }));
  alvo.replaceChildren(todos, ...opcoes.map(([valor, rotulo]) => {
    const n = base.filter((x) => grupoFn(x) === valor).length;
    return el('button', { type: 'button', class: `chip${n === 0 && !selecionados.has(valor) ? ' zero' : ''}`, 'aria-pressed': String(selecionados.has(valor)),
      onclick: () => { if (selecionados.has(valor)) selecionados.delete(valor); else selecionados.add(valor); invAtualizar(); } },
      rotulo, el('span', { class: 'n', text: String(n) }));
  }));
}

function invPreencherSelects() {
  const unicos = (fn) => [...new Set(invEstado.itens.map(fn).filter(Boolean))].sort((a, b) => a.localeCompare(b, 'pt-BR', { numeric: true }));
  const opcoes = (id, lista, todos, chave) => { const sel = $(id); sel.replaceChildren(el('option', { value: '', text: todos }), ...lista.map((o) => el('option', { value: o, text: o }))); sel.value = invEstado.filtro[chave] || ''; };
  opcoes('inv-f-local', unicos((x) => x.localizacao), 'Todas as localizações', 'local');
  opcoes('inv-f-fab', unicos((x) => x.fabricante), 'Todos os fabricantes', 'fab');
  opcoes('inv-f-modelo', unicos((x) => x.modelo), 'Todos os modelos', 'modelo');
  opcoes('inv-f-so', unicos(rotuloSO), 'Todas as versões do Windows', 'so');
}

function invCartoes() {
  const it = invEstado.itens;
  const cont = (fn) => it.filter(fn).length;
  const cartao = (rotulo, valor, detalhe, cor, aoClicar) => el('button', { type: 'button', class: 'cartao', style: cor ? `--cor:${cor}` : null, onclick: aoClicar },
    el('div', { class: 'rotulo', text: rotulo }), el('div', { class: 'valor', text: String(valor) }), el('div', { class: 'detalhe', text: detalhe || '' }));
  const soStatus = (s) => () => { invLimpar(); invEstado.filtro.status = new Set([s]); invAtualizar(); };
  $('inv-cartoes').replaceChildren(
    cartao('Total de ativos', it.length, `${cont((x) => x.tipo === 'NOTEBOOK')} notebooks · ${cont((x) => x.tipo === 'DESKTOP')} desktops`, null, () => { invLimpar(); invAtualizar(); }),
    cartao('Em uso', cont((x) => x.status === 'INDISPONÍVEL'), 'status Indisponível', 'var(--presencial)', soStatus('INDISPONÍVEL')),
    cartao('Disponíveis', cont((x) => x.status === 'DISPONÍVEL'), 'em estoque', 'var(--acento)', soStatus('DISPONÍVEL')),
    cartao('Em reparo', cont((x) => x.status === 'REPARO'), '', 'var(--remoto)', soStatus('REPARO')),
    cartao('Inutilizáveis', cont((x) => x.status === 'INUTILIZÁVEL'), '', 'var(--semrede)', soStatus('INUTILIZÁVEL')),
    cartao('Com agente', cont((x) => x.tem_agente), `${cont(semContato)} sem contato há +${DIAS_SEM_CONTATO} dias`, 'var(--vpn)', () => { invLimpar(); invEstado.filtro.foco = 'agente'; invAtualizar(); }),
    cartao('Agente sem cadastro', cont(semCadastro), 'não está na planilha', 'var(--parcial)', () => { invLimpar(); invEstado.filtro.foco = 'sem-cadastro'; invAtualizar(); }));
}

function invLimpar() {
  const f = invEstado.filtro;
  f.busca = ''; f.tipos.clear(); f.status.clear(); f.local = f.fab = f.modelo = f.so = f.ram = f.disco = f.foco = '';
  $('inv-busca').value = '';
}

function invTabela() {
  const lista = invOrdenar(invFiltrados());
  const corpo = document.querySelector('#inv-tabela tbody');
  corpo.replaceChildren();
  for (const x of lista.slice(0, 1000)) {
    const contato = x.ultimo_contato === null ? '—' : (semContato(x) ? `há ${Math.round((invEstado.agora - x.ultimo_contato) / 86400000)} dias` : dataCurta(x.ultimo_contato));
    const hw = [x.ram_gb ? `${x.ram_gb} GB` : '', rotuloDisco(x)].filter(Boolean).join(' · ');
    corpo.append(el('tr', { class: 'clicavel', onclick: () => invAbrir(x) },
      el('td', null, el('strong', { text: x.num_inventario || x.chave }), x.servidor ? el('span', { class: 'etq', text: 'Servidor' }) : null, x.remoto_id ? el('span', { class: 'etq', text: 'Remoto' }) : null, el('span', { class: 'sub2', text: x.tipo || '' })),
      el('td', null, equip(x) || '—', el('span', { class: 'sub2', text: x.serie ? `Série ${x.serie}` : '' })),
      el('td', null, x.status ? el('span', { class: `etq ${x.status === 'INUTILIZÁVEL' || x.status === 'REPARO' ? 'alerta' : ''}`, text: x.status }) : el('span', { class: 'mudo', text: x.origem === 'agente' ? 'sem cadastro' : '—' })),
      el('td', null, x.responsavel || x.ultimo_usuario || '—', el('span', { class: 'sub2', text: x.localizacao || '' })),
      el('td', null, (x.tem_agente && rotuloSO(x)) || '—', el('span', { class: 'sub2', text: hw })),
      el('td', null, x.ips || '—', el('span', { class: 'sub2', text: x.ip_saida ? `saída ${x.ip_saida}` : '' })),
      el('td', { class: `nowrap${semContato(x) ? ' alerta-texto' : ''}`, text: contato })));
  }
  if (!lista.length) corpo.append(el('tr', null, el('td', { colspan: '7', class: 'mudo', text: 'Nenhum ativo com esses filtros.' })));
  const total = invEstado.itens.length;
  $('inv-contagem').textContent = `${lista.length} de ${total} ativo(s)${lista.length > 1000 ? ' (mostrando 1000; use a exportação para tudo)' : ''}`;
  for (const th of document.querySelectorAll('#inv-tabela th[data-ord]')) {
    th.classList.toggle('ord-asc', th.dataset.ord === invEstado.ord.campo && invEstado.ord.asc);
    th.classList.toggle('ord-desc', th.dataset.ord === invEstado.ord.campo && !invEstado.ord.asc);
  }
  return lista;
}

function invAtualizar() {
  invChips('inv-chips-tipo', TIPOS, invEstado.filtro.tipos, tipoGrupo, 'tipos');
  invChips('inv-chips-status', STATUS_CHIPS, invEstado.filtro.status, statusGrupo, 'status');
  invTabela();
}

async function carregarInventario() {
  const ehAdmin = P.eu.papel === 'admin';
  for (const e of document.querySelectorAll('[data-inv-admin]')) e.hidden = !ehAdmin;
  try {
    const r = await api('api/inventario');
    invEstado.itens = r.itens; invEstado.status = r.status; invEstado.agora = r.agora;
    invPreencherSelects(); invCartoes(); invAtualizar();
  } catch (e) { $('inv-cartoes').replaceChildren(el('p', { class: 'aviso', text: `Falha ao carregar: ${e.message}` })); }
}

// ---------- exportar o que esta filtrado (mesmas colunas do relatorio completo) ----------
const COLUNAS_CSV = ['Nome', 'Status', 'Fabricante', 'Número de série', 'Tipo', 'Modelo', 'Nome alternativo do usuário', 'Número de inventário', 'Localização', 'Comentários',
  'Sistema operacional', 'Versão do Windows', 'Processador', 'Memória (GB)', 'Armazenamento', 'Livre em C: (GB)', 'IP local', 'IP de saída', 'MAC', 'Domínio',
  'Unidade (agente)', 'Último usuário logado', 'Último contato', 'Versão do agente'];

function linhaCsv(x) {
  const dt = (ts) => (ts ? new Date(ts).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '');
  return [x.nome_ativo, x.status, x.fabricante, x.serie, x.tipo, x.modelo, x.responsavel, x.num_inventario || x.chave, x.localizacao, x.comentarios,
    `${x.so} ${x.so_exibicao}`.trim(), x.so_versao, x.cpu, x.ram_gb || '', rotuloDisco(x), x.disco_c_total_gb ? x.disco_c_livre_gb : '', x.ips, x.ip_saida, x.mac, x.dominio,
    x.unidade, x.ultimo_usuario, dt(x.ultimo_contato), x.agente_versao];
}
function celulaCsv(v) {
  let s = v === null || v === undefined ? '' : String(v);
  if (/^[=+\-@\t\r]/.test(s) && !/^-?\d+([.,]\d+)?$/.test(s)) s = `'${s}`; // evita virar formula no Excel
  return /[";\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}
function invExportarFiltrado(ev) {
  const lista = invOrdenar(invFiltrados());
  const texto = '﻿' + [COLUNAS_CSV, ...lista.map(linhaCsv)].map((l) => l.map(celulaCsv).join(';')).join('\r\n') + '\r\n';
  const hoje = new Date().toLocaleDateString('pt-BR').replace(/\//g, '.');
  const a = ev.currentTarget;
  if (a.dataset.url) URL.revokeObjectURL(a.dataset.url);
  a.dataset.url = URL.createObjectURL(new Blob([texto], { type: 'text/csv;charset=utf-8' }));
  a.href = a.dataset.url;
  a.download = `Relatorio de Ativos - filtrado (${lista.length}) - ${hoje}.csv`;
}

// etapa que o agent informou sobre a instalacao do acesso remoto (RustDesk)
const ROTULO_REMOTO = {
  baixando: 'Baixando o RustDesk…', instalando: 'Instalando o RustDesk…', configurando: 'Configurando o RustDesk…',
  registrado: 'Pronto: máquina registrada', ok: 'Pronto: funcionando', 'sem-relay': 'Aguardando: fora da rede da empresa (relay inacessível)',
  'falha-instalacao': 'Falha ao instalar o RustDesk', 'falha-servico': 'Falha ao registrar o serviço do Windows', 'falha-config': 'Falha ao configurar o relay',
  'sem-id': 'RustDesk instalado, mas ainda sem ID', 'falha-envio': 'Falha ao enviar o registro ao servidor',
  'falha-senha': 'Falha ao definir a senha de acesso', 'aguardando-sessao': 'Aguardando alguém entrar no Windows para concluir o registro', 'prazo-esgotado': 'Continua na próxima rodada (tempo da etapa esgotado)',
};

function invCampo(rotulo, valor) { return el('div', { class: 'inv-par' }, el('span', { class: 'mudo', text: rotulo }), el('strong', { text: valor === '' || valor === null || valor === undefined || valor === 0 ? '—' : String(valor) })); }

async function invAbrir(x) {
  const ehAdmin = P.eu.papel === 'admin';
  const corpo = gaveta(x.num_inventario || x.chave, [x.nome_ativo, x.servidor ? 'servidor' : ''].filter(Boolean).join(' · '));
  corpo.append(el('h4', { text: 'Equipamento' }), el('div', { class: 'inv-grade' },
    invCampo('Fabricante', x.fabricante), invCampo('Modelo', x.modelo), invCampo('Número de série', x.serie), invCampo('Tipo', x.tipo),
    invCampo('Sistema operacional', `${x.so} ${x.so_exibicao}`.trim()), invCampo('Versão / build', x.so_versao), invCampo('Arquitetura', x.so_arquitetura), invCampo('Windows instalado em', x.so_instalado_em),
    invCampo('Processador', x.cpu), invCampo('Memória', x.ram_gb ? `${x.ram_gb} GB` : ''), invCampo('Armazenamento', rotuloDisco(x)),
    invCampo('Disco C: livre', x.disco_c_total_gb ? `${x.disco_c_livre_gb} de ${x.disco_c_total_gb} GB` : ''),
    invCampo('IP local', x.ips), invCampo('IP de saída', x.ip_saida), invCampo('MAC', x.mac), invCampo('Domínio', x.dominio), invCampo('BIOS', x.bios_versao),
    invCampo('Último boot', x.ultimo_boot), invCampo('Unidade (agente)', x.unidade), invCampo('Último usuário logado', x.ultimo_usuario),
    invCampo('Último contato', x.ultimo_contato ? dataCurta(x.ultimo_contato) : ''), invCampo('Agente', x.agente_versao ? `v${x.agente_versao}` : (x.tem_agente ? 'sim' : 'sem agente')),
    invCampo('Dados coletados em', x.coletado_em ? dataCurta(x.coletado_em) : '')));

  const campos = {};
  const entrada = (rotulo, chave, tipo = 'text', opcoes) => {
    const c = opcoes ? el('select', { 'aria-label': rotulo }, ...opcoes.map((o) => el('option', { value: o, text: o || '(sem status)' }))) : (tipo === 'area' ? el('textarea', { rows: '3', 'aria-label': rotulo }) : el('input', { type: 'text', 'aria-label': rotulo }));
    c.value = x[chave] || ''; c.disabled = !ehAdmin; campos[chave] = c;
    return el('label', { class: 'inv-campo' }, el('span', { class: 'mudo', text: rotulo }), c);
  };
  corpo.append(el('h4', { text: 'Controle' }), el('div', { class: 'inv-form' },
    entrada('Status', 'status', 'text', ['', ...invEstado.status]), entrada('Nome alternativo do usuário (responsável)', 'responsavel'), entrada('Localização', 'localizacao'),
    entrada('Nome do ativo', 'nome_ativo'), entrada('Comentários', 'comentarios', 'area')));
  if (ehAdmin) {
    corpo.append(el('p', { class: 'grupo-btn' },
      el('button', { class: 'btn primario', type: 'button', onclick: async (ev) => {
        ev.target.disabled = true;
        try {
          const corpoPut = { chave: x.chave }; for (const [k, c] of Object.entries(campos)) corpoPut[k] = c.value;
          await api('api/inventario', { metodo: 'PUT', corpo: corpoPut });
          ev.target.textContent = 'Salvo ✓'; await carregarInventario();
          setTimeout(() => { ev.target.textContent = 'Salvar'; ev.target.disabled = false; }, 1200);
        } catch (e) { alert(e.message); ev.target.disabled = false; }
      } }, 'Salvar'),
      el('button', { class: 'btn', type: 'button', onclick: async () => {
        if (!confirm(`Excluir o ativo ${x.chave} do inventário? O histórico de hardware dele também é apagado.${x.tem_agente ? '\nSe o agent ainda estiver instalado, ele reaparece sozinho.' : ''}`)) return;
        try { await api(`api/inventario?chave=${encodeURIComponent(x.chave)}`, { metodo: 'DELETE' }); $('gaveta').hidden = true; carregarInventario(); } catch (e) { alert(e.message); }
      } }, 'Excluir ativo')));
  }
  if (ehAdmin && (x.remoto_id || x.remoto_estado)) {
    corpo.append(el('h4', { text: 'Acesso remoto' }));
    if (x.remoto_estado) {
      const falha = x.remoto_estado.startsWith('falha') || x.remoto_estado === 'sem-id';
      corpo.append(el('p', { class: falha ? 'aviso' : 'mudo', text: `${ROTULO_REMOTO[x.remoto_estado] || x.remoto_estado}${x.remoto_estado_detalhe ? ` (${x.remoto_estado_detalhe})` : ''} · ${dataCurta(x.remoto_estado_em)}` }));
    }
  }
  if (ehAdmin && x.remoto_id) {
    const msg = el('span', { class: 'mudo', text: `ID ${x.remoto_id}` });
    corpo.append(el('p', { class: 'grupo-btn' },
      el('button', { class: 'btn primario', type: 'button', onclick: async (ev) => {
        ev.target.disabled = true;
        try { await remotoConectar(x.host, (m) => { msg.textContent = m; }); } catch (e) { alert(e.message); }
        ev.target.disabled = false;
      } }, 'Acesso remoto'),
      el('button', { class: 'btn', type: 'button', onclick: async () => {
        try { const r = await remotoCopiarSenha(x.host); msg.textContent = `ID ${r.id} · senha copiada (cole no RustDesk)`; } catch (e) { alert(e.message); }
      } }, 'Copiar senha'), msg));
  }
  corpo.append(el('h4', { text: 'Alterações de hardware' }));
  const lista = el('ul', { class: 'lista-simples compacta' }, el('li', { class: 'mudo', text: 'Carregando…' }));
  corpo.append(lista);
  try {
    const h = (await api(`api/inventario/historico?chave=${encodeURIComponent(x.chave)}`)).itens;
    lista.replaceChildren(...(h.length ? h.map((i) => el('li', null, el('time', { class: 'mudo', text: dataCurta(i.ts) }), el('span', { text: `${i.campo}: ${i.antigo} → ${i.novo}` }))) : [el('li', { class: 'mudo', text: 'Nenhuma alteração registrada.' })]));
  } catch (e) { lista.replaceChildren(el('li', { class: 'aviso', text: e.message })); }
}

// lê o arquivo escolhido: UTF-8 e, se tiver caracteres inválidos, Windows-1252 (Excel antigo)
async function invLerArquivo(arq) {
  const buf = await arq.arrayBuffer();
  try { return new TextDecoder('utf-8', { fatal: true }).decode(buf); } catch { return new TextDecoder('windows-1252').decode(buf); }
}

function invLigar() {
  const f = invEstado.filtro;
  $('inv-busca').addEventListener('input', (ev) => { f.busca = ev.target.value; invAtualizar(); });
  for (const [id, chave] of [['inv-f-local', 'local'], ['inv-f-fab', 'fab'], ['inv-f-modelo', 'modelo'], ['inv-f-so', 'so'], ['inv-f-ram', 'ram'], ['inv-f-disco', 'disco'], ['inv-f-foco', 'foco']]) {
    $(id).addEventListener('change', (ev) => { f[chave] = ev.target.value; invAtualizar(); });
  }
  $('inv-limpar').addEventListener('click', () => { invLimpar(); for (const id of ['inv-f-local', 'inv-f-fab', 'inv-f-modelo', 'inv-f-so', 'inv-f-ram', 'inv-f-disco', 'inv-f-foco']) $(id).value = ''; invAtualizar(); });
  for (const th of document.querySelectorAll('#inv-tabela th[data-ord]')) {
    th.addEventListener('click', () => {
      const campo = th.dataset.ord;
      invEstado.ord = { campo, asc: invEstado.ord.campo === campo ? !invEstado.ord.asc : true };
      invTabela();
    });
  }
  $('inv-csv-filtro').addEventListener('click', invExportarFiltrado);
  $('inv-importar').addEventListener('click', () => $('inv-arquivo').click());
  $('inv-arquivo').addEventListener('change', async (ev) => {
    const arq = ev.target.files[0]; ev.target.value = '';
    if (!arq) return;
    const sobrescrever = confirm(`Importar "${arq.name}" para o inventário.\n\nOK = o CSV MANDA nos campos de controle (status, responsável, localização, comentários), inclusive trocando o que já está preenchido.\nCancelar = só preenche o que estiver vazio.\n\nDados coletados pelo agent nunca são sobrescritos pelo CSV.`);
    try {
      const r = await api('api/inventario/importar', { metodo: 'POST', corpo: { csv: await invLerArquivo(arq), sobrescrever } });
      alert(`Importação concluída.\nNovos: ${r.novos}\nAtualizados: ${r.atualizados}\nSem mudança: ${r.iguais}\nIgnorados (sem número de inventário): ${r.ignorados}${r.status_invalidos ? `\nStatus não reconhecido (ficou em branco): ${r.status_invalidos}` : ''}`);
      carregarInventario();
    } catch (e) { alert(e.message); }
  });
  $('inv-novo').addEventListener('click', () => {
    const num = (prompt('Número de inventário do novo ativo (ex.: MTZ0123):') || '').trim();
    if (!num) return;
    api('api/inventario', { metodo: 'PUT', corpo: { chave: num, status: 'DISPONÍVEL' } }).then(() => carregarInventario()).catch((e) => alert(e.message));
  });
}

P.abas.inventario = { carregar: carregarInventario };
invLigar();
$('inv-csv').href = 'api/export/inventario.csv';
$('inv-xlsx').href = 'api/export/inventario.xlsx';
