'use strict';
// Aba "Chamados" (administrador): importa os relatorios do TomTicket (.xlsx, lidos aqui no navegador) e monta o relatorio de
// chamados do HelpDesk na hora (indicadores, por categoria, por atendente, quem mais abriu, evolucao e dia da semana).
// Usa as funcoes de chamados-xlsx.js. O texto da mensagem do chamado nunca sai do navegador.

(function chamadosDoHelpdesk() {
const CN = (v, c = 1) => (v === null || v === undefined ? '—' : Number(v).toLocaleString('pt-BR', { minimumFractionDigits: c, maximumFractionDigits: c }));
const CH = (h) => (h === null || h === undefined ? '—' : h >= 48 ? `${CN(h / 24)} d` : `${CN(h)} h`);
const CDia = (iso) => iso.split('-').reverse().join('/');
const CDh = (ms) => (ms ? new Date(ms).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : '—');
const chEstado = { dados: null };

function chPeriodo() {
  const tipo = $('ch-periodo').value;
  const [a, m] = hoje().split('-').map(Number);
  const ult = (ano, mes) => new Date(ano, mes, 0).getDate();
  const f2 = (n) => String(n).padStart(2, '0');
  if (tipo === 'mes-anterior') { const d = new Date(a, m - 2, 1); const ano = d.getFullYear(), mes = d.getMonth() + 1; return [`${ano}-${f2(mes)}-01`, `${ano}-${f2(mes)}-${f2(ult(ano, mes))}`]; }
  if (tipo === 'mes-atual') return [`${a}-${f2(m)}-01`, hoje()];
  if (tipo === '7') return [somaDias(hoje(), -6), hoje()];
  if (tipo === '90') return [somaDias(hoje(), -89), hoje()];
  if (tipo === 'personalizado') return [$('ch-de').value, $('ch-ate').value];
  return [somaDias(hoje(), -29), hoje()];
}

const chConsulta = () => { const [de, ate] = chPeriodo(); return new URLSearchParams({ de, ate, base: $('ch-base').value }).toString(); };

function chTabela(cabecalhos, linhas, classes = []) {
  const t = el('table', { class: 'rel-tab' }, el('thead', null, el('tr', null, ...cabecalhos.map((c, i) => el('th', { class: classes[i] || '', text: c })))));
  const tb = el('tbody');
  for (const l of linhas) tb.append(el('tr', null, ...l.map((c, i) => (c instanceof Node ? el('td', { class: classes[i] || '' }, c) : el('td', { class: classes[i] || '', text: c })))));
  t.append(tb);
  return el('div', { class: 'rel-tab-wrap' }, t);
}
const chSecao = (titulo, ...filhos) => el('section', { class: 'rel-secao' }, el('h3', { text: titulo }), ...filhos);
const chBarra = (pct, max) => el('div', { class: 'rel-barra', style: `width:${max > 0 ? Math.max(2, Math.round((pct / max) * 100)) : 0}%;background:#1A2E4A` });

function chGrupo(titulo, lista, rotulo) {
  const max = lista.reduce((m, g) => Math.max(m, g.total), 0);
  return chSecao(titulo, lista.length
    ? chTabela([rotulo, 'Chamados', '%', 'Tempo médio', ''], lista.map((g) => [g.nome, String(g.total), `${CN(g.pct)}%`, CH(g.tempo_medio_h), chBarra(g.total, max)]), ['', 'num', 'num', 'num', 'barra'])
    : el('p', { class: 'rel-nota', text: 'Sem dados no período.' }));
}

function chDesenhar(r) {
  const doc = $('ch-doc');
  doc.replaceChildren();
  doc.hidden = false;
  const p = r.periodo, k = r.resumo, a = r.anterior;
  doc.append(el('header', { class: 'rel-topo' },
    el('p', { class: 'rel-marca', text: 'PRESENÇA E PRODUTIVIDADE · Relatório gerencial' }),
    el('h2', { text: 'Relatório de Chamados do HelpDesk' }),
    el('p', { class: 'rel-sub', text: `${CDia(p.de)} a ${CDia(p.ate)} · contados pela data de ${p.base === 'criacao' ? 'criação' : 'finalização'}` })));
  if (!k.total) {
    doc.append(el('p', { class: 'rel-vazio', text: 'Nenhum chamado neste período. Importe os relatórios do TomTicket ou escolha outro período.' }));
    return;
  }
  const variacao = a.variacao_total_pct === null ? 'sem período anterior para comparar' : `${a.variacao_total_pct > 0 ? '+' : ''}${CN(a.variacao_total_pct)}% em relação aos ${a.total} chamados de ${CDia(a.de)} a ${CDia(a.ate)}`;
  doc.append(
    el('div', { class: 'rel-kpis' },
      ...[[CN(k.total, 0), 'Chamados'], [CH(k.tempo_medio_h), 'Tempo médio até finalizar'], [k.pct_ate_24h === null ? '—' : `${CN(k.pct_ate_24h)}%`, 'Finalizados em até 24 h'], [CN(k.por_dia_util), 'Chamados por dia útil']]
        .map(([v, t]) => el('div', { class: 'rel-kpi' }, el('b', { text: v }), el('span', { text: t })))),
    el('p', { class: 'rel-periodo', text: `Variação: ${variacao}.` }));

  doc.append(chSecao('1. Indicadores', chTabela(['Indicador', 'Valor'], [
    ['Chamados no período', CN(k.total, 0)], ['Finalizados', CN(k.finalizados, 0)], ['Sem data de finalização', CN(k.abertos, 0)], ['Sem categoria', CN(k.sem_categoria, 0)],
    ['Tempo médio até finalizar', CH(k.tempo_medio_h)], ['Tempo mediano', CH(k.tempo_mediano_h)],
    ['Finalizados em até 24 h', k.pct_ate_24h === null ? '—' : `${CN(k.pct_ate_24h)}%`], ['Finalizados em até 72 h', k.pct_ate_72h === null ? '—' : `${CN(k.pct_ate_72h)}%`],
    ['Chamados com as duas datas (base do tempo)', CN(k.com_tempo, 0)]], ['', 'num']),
    el('p', { class: 'rel-nota', text: 'O tempo vai da criação à finalização e só considera chamados que têm as duas datas. Alguns relatórios do TomTicket trazem só uma delas.' })));
  doc.append(chGrupo('2. Por categoria', r.por_categoria, 'Categoria'));
  doc.append(chGrupo('3. Por atendente', r.por_atendente, 'Atendente (quem finalizou)'));
  doc.append(chGrupo('4. Quem mais abriu chamados', r.top_solicitantes, 'Solicitante'));
  const ev = r.evolucao.serie;
  const maxE = ev.reduce((m, s) => Math.max(m, s.total), 0);
  const rot = r.evolucao.granularidade;
  doc.append(chSecao(`5. Evolução (${rot === 'dia' ? 'por dia' : rot === 'semana' ? 'por semana, início na segunda' : 'por mês'})`,
    chTabela([rot === 'mes' ? 'Mês' : rot === 'semana' ? 'Semana de' : 'Dia', 'Chamados', 'Tempo médio', ''],
      ev.map((s) => [rot === 'mes' ? `${s.rotulo.slice(5)}/${s.rotulo.slice(0, 4)}` : CDia(s.rotulo), String(s.total), CH(s.tempo_medio_h), chBarra(s.total, maxE)]), ['', 'num', 'num', 'barra'])));
  const maxD = r.por_dia_semana.reduce((m, d) => Math.max(m, d.total), 0);
  doc.append(chSecao('6. Dia da semana', chTabela(['Dia', 'Chamados', ''], r.por_dia_semana.map((d) => [d.dia, String(d.total), chBarra(d.total, maxD)]), ['', 'num', 'barra'])));
  const c = r.cobertura;
  doc.append(el('p', { class: 'rel-rodape', text: `Dados do TomTicket · ${c.total} chamado(s) no sistema${c.primeiro_ms ? ` (de ${CDh(c.primeiro_ms)} a ${CDh(c.ultimo_ms)})` : ''} · último envio: ${CDh(c.ultimo_import)} · relatório gerado em ${CDh(r.gerado_em)}` }));
}

async function chResumo() {
  try {
    const c = await api('api/chamados/resumo');
    $('ch-resumo').textContent = c.total
      ? `${c.total} chamado(s) no sistema, de ${new Date(c.primeiro_ms).toLocaleDateString('pt-BR')} a ${new Date(c.ultimo_ms).toLocaleDateString('pt-BR')}. Último envio: ${CDh(c.ultimo_import)}.`
      : 'Nenhum chamado importado ainda.';
    return c;
  } catch (e) { $('ch-resumo').textContent = `Falha: ${e.message}`; return null; }
}

async function chGerar() {
  const [de, ate] = chPeriodo();
  if (!de || !ate) { $('ch-msg').textContent = 'Informe as duas datas do período.'; return; }
  $('ch-msg').textContent = 'Calculando…';
  $('ch-gerar').disabled = true;
  try {
    const r = await api(`api/chamados/relatorio?${chConsulta()}`);
    chEstado.dados = r;
    chDesenhar(r);
    $('ch-msg').textContent = r.resumo.total ? 'Pronto. Use "Imprimir / salvar PDF" ou baixe o Excel.' : '';
    $('ch-imprimir').disabled = !r.resumo.total;
    $('ch-excel').hidden = !r.resumo.total;
    $('ch-excel').href = `api/export/chamados.xlsx?${chConsulta()}`;
  } catch (e) { $('ch-msg').textContent = `Não foi possível gerar: ${e.message}`; }
  $('ch-gerar').disabled = false;
}

async function chImportar() {
  const arqs = [...$('ch-arq').files];
  if (!arqs.length) { $('ch-msg').textContent = 'Escolha um ou mais arquivos .xlsx do TomTicket.'; return; }
  const botao = $('ch-importar');
  botao.disabled = true;
  const log = $('ch-log');
  log.replaceChildren();
  const tot = { novos: 0, atualizados: 0, iguais: 0, invalidos: 0 };
  let ok = 0;
  for (const f of arqs) {
    const li = el('li', { text: `${f.name}: lendo…` });
    log.append(li);
    try {
      const r = ccParseTomTicket(await ccLerXlsx(await f.arrayBuffer()));
      if (r.erro) { li.textContent = `${f.name}: ${r.erro}`; li.classList.add('erro'); continue; }
      if (!r.linhas.length) { li.textContent = `${f.name}: nenhum chamado encontrado.`; li.classList.add('erro'); continue; }
      const acc = { novos: 0, atualizados: 0, iguais: 0, invalidos: 0 };
      for (let i = 0; i < r.linhas.length; i += 500) {
        li.textContent = `${f.name}: enviando ${Math.min(i + 500, r.linhas.length)} de ${r.linhas.length}…`;
        const x = await api('api/chamados/importar', { metodo: 'POST', corpo: { linhas: r.linhas.slice(i, i + 500), arquivo: f.name } });
        for (const k of Object.keys(acc)) acc[k] += x[k] || 0;
      }
      for (const k of Object.keys(tot)) tot[k] += acc[k];
      ok++;
      li.textContent = `${f.name}: ${r.linhas.length} chamado(s): ${acc.novos} novos, ${acc.atualizados} atualizados, ${acc.iguais} já existiam, ${acc.invalidos} inválidos.${r.colunas.finalizacao ? '' : ' (este arquivo não traz a data de finalização)'}`;
    } catch (e) { li.textContent = `${f.name}: ${e.message}`; li.classList.add('erro'); }
  }
  $('ch-msg').textContent = `Importação concluída: ${ok} de ${arqs.length} arquivo(s). ${tot.novos} novos, ${tot.atualizados} atualizados, ${tot.iguais} já existiam, ${tot.invalidos} inválidos.`;
  $('ch-arq').value = '';
  botao.disabled = false;
  await chResumo();
  if (!$('ch-doc').hidden) chGerar();
}

$('ch-importar').addEventListener('click', chImportar);
$('ch-gerar').addEventListener('click', chGerar);
$('ch-imprimir').addEventListener('click', () => window.print());
$('ch-periodo').addEventListener('change', () => { $('ch-l-per').hidden = $('ch-periodo').value !== 'personalizado'; });

P.abas.chamados = {
  async carregar() {
    if (!$('ch-de').value) { $('ch-de').value = somaDias(hoje(), -29); $('ch-ate').value = hoje(); $('ch-periodo').value = 'mes-anterior'; }
    const c = await chResumo();
    if (c && c.total && $('ch-doc').hidden) chGerar();
  },
};
})();
