'use strict';
// Aba "Relatório" (administrador): monta na hora o relatório de produtividade (mensal, semanal ou período livre) a partir dos
// dados coletados, no mesmo desenho do relatório que o analista fazia a mão. Imprimir / salvar como PDF pelo navegador.

(function relatorioDeProdutividade() {
const relEstado = { tipo: 'mensal', escopo: 'geral', login: '', dados: null, colabs: new Map() };
const RN = (v, c = 1) => (v === null || v === undefined ? '—' : Number(v).toLocaleString('pt-BR', { minimumFractionDigits: c, maximumFractionDigits: c }));
const RH = (seg) => (seg === null || seg === undefined ? '—' : `${RN(seg / 3600)}h`);
const RP = (v) => (v === null || v === undefined ? '—' : `${RN(v)}%`);
const RDia = (iso) => iso.split('-').reverse().join('/');

function relMesAnterior() {
  const [a, m] = hoje().split('-').map(Number);
  const d = new Date(a, m - 2, 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

function relTabela(cabecalhos, linhas, classes = []) {
  const t = el('table', { class: 'rel-tab' }, el('thead', null, el('tr', null, ...cabecalhos.map((c, i) => el('th', { class: classes[i] || '', text: c })))));
  const tb = el('tbody');
  for (const l of linhas) tb.append(el('tr', null, ...l.map((c, i) => (c instanceof Node ? el('td', { class: classes[i] || '' }, c) : el('td', { class: classes[i] || '', text: String(c) })))));
  t.append(tb);
  return el('div', { class: 'rel-tab-wrap' }, t);
}
const relSecao = (titulo, ...filhos) => el('section', { class: 'rel-secao' }, el('h3', { text: titulo }), ...filhos);
const relNota = (texto) => el('p', { class: 'rel-nota', text: texto });
const relPessoaLinha = (p) => [p.nome, RN(p.score), RH(p.tempo_ativo_medio_dia_seg), String(p.dias), p.centro_custo || (p.cargo || '—')];

function relDesenhar(r) {
  if (r.tipo === 'individual') return relDesenharIndividual(r);
  const doc = $('rel-doc');
  doc.replaceChildren();
  doc.hidden = false;
  doc.append(
    el('header', { class: 'rel-topo' },
      el('p', { class: 'rel-marca', text: 'PRESENÇA E PRODUTIVIDADE · Relatório gerencial' }),
      el('h2', { text: r.titulo }), el('p', { class: 'rel-sub', text: r.subtitulo })));
  if (r.sem_dados) {
    doc.append(el('p', { class: 'rel-vazio', text: `Sem dados de presença e uso no período ${r.rotulo_periodo}. Escolha outro período.` }));
    return;
  }
  const per = r.periodo;
  const feriados = per.feriados_excluidos.length ? `; ${per.feriados_excluidos.map((d) => d.slice(8, 10) + '/' + d.slice(5, 7)).join(', ')} excluído(s) por feriado` : '';
  doc.append(
    el('div', { class: 'rel-kpis' },
      ...[[RN(r.kpis.colaboradores, 0), 'Colaboradores'], [RN(r.kpis.score), 'Score médio'], [RH(r.kpis.tempo_ativo_medio_dia_seg), 'Tempo ativo/dia'], [RP(r.kpis.pct_tempo_produtivo), '% Produtivo']]
        .map(([v, t]) => el('div', { class: 'rel-kpi' }, el('b', { text: v }), el('span', { text: t })))),
    el('p', { class: 'rel-periodo', text: `Período analisado: ${RDia(per.de)} a ${RDia(per.ate)} (${per.dias_uteis} dias úteis${feriados})${per.parcial ? ' - período em andamento' : ''}` }));

  // Metas
  doc.append(relSecao('Metas do escritório (média geral)',
    relTabela(['Indicador', 'Valor', 'Meta', 'Situação'], r.indicadores.map((i) => [i.indicador, i.valor, i.meta, el('span', { class: i.atingida ? 'rel-ok' : 'rel-falta', text: i.atingida ? '✔ Atingida' : '✖ Abaixo' })]), ['', 'num', 'num', '']),
    relNota(`Primeiro clique médio: ${r.cliques.primeiro_medio || '—'} · Último clique médio: ${r.cliques.ultimo_medio || '—'} · Jornada considerada: ${RN(r.jornada_padrao_horas)} h/dia (ajustável por pessoa na importação do RH).`)));

  // 1. Sumário
  const cl = r.classificacao;
  const sum = [relSecao('1. Sumário executivo',
    cl ? el('p', { class: 'rel-class' }, 'CLASSIFICAÇÃO GERAL: ', el('b', { text: cl.faixa }), ` - score ${RN(cl.score)} (meta ${RN(cl.meta, 0)}), ${cl.acima_da_meta ? 'acima' : 'abaixo'} da meta.`) : null,
    el('h4', { text: 'Principais achados' }), el('ul', null, ...r.achados.map((a) => el('li', { text: a }))),
    r.evolucao.length ? el('h4', { text: 'Evolução' }) : null,
    r.evolucao.length ? relTabela(['Período', 'Dias úteis', 'Logins', 'Score médio', 'Tempo ativo', '% Produtivo', ...(r.tem_rh ? ['% sem cadastro RH'] : [])],
      r.evolucao.map((e) => [e.rotulo, String(e.dias_uteis), String(e.colaboradores), RN(e.score), RH(e.tempo_ativo_medio_dia_seg), RP(e.pct_tempo_produtivo), ...(r.tem_rh ? [RP(e.pct_sem_rh)] : [])]), ['', 'num', 'num', 'num', 'num', 'num', 'num']) : null)];
  doc.append(...sum);

  // 2. Modalidade
  const mod = [relTabela(['Modalidade', 'Registros', 'Score médio', 'Tempo ativo', '% Produtivo'], r.modalidade.map((m) => [m.modalidade + (m.fora_da_comparacao ? ' *' : ''), RN(m.registros, 0), RN(m.score), RH(m.tempo_ativo_medio_dia_seg), RP(m.pct_tempo_produtivo)]), ['', 'num', 'num', 'num', 'num'])];
  mod.push(relNota('Registro = um colaborador em um dia útil. Cada dia vale pelo local onde o computador ficou mais tempo (60% das leituras em casa = dia de home). * Fica fora da comparação presencial x remoto.'));
  if (r.cargo_modalidade) {
    mod.push(el('h4', { text: 'Comparativo por cargo e modalidade' }),
      relTabela(['Cargo', 'Presencial', 'Remoto', 'Delta (presencial − remoto)', 'Registros remoto'], r.cargo_modalidade.map((c) => [c.cargo, c.presencial ? RN(c.presencial.score) : '—', c.remoto ? RN(c.remoto.score) : '—', c.delta === null ? '—' : (c.delta > 0 ? '+' : '') + RN(c.delta), (c.remoto ? RN(c.remoto.registros, 0) : '0') + (c.pouca_base ? ' *' : '')]), ['', 'num', 'num', 'num', 'num']),
      relNota('* Base remota pequena (menos de 30 registros): delta pouco representativo.'));
  } else mod.push(relNota('Comparativo por cargo: depende do cadastro do RH (Administração > Cadastro do RH).'));
  doc.append(relSecao('2. Análise por modalidade de trabalho', ...mod));

  // 3. Dia da semana
  doc.append(relSecao('3. Análise por dia da semana', relTabela(['Dia', 'Score médio', 'Tempo ativo', '% Produtivo'], r.dia_semana.map((d) => [d.nome, RN(d.score), RH(d.tempo_ativo_medio_dia_seg), RP(d.pct_tempo_produtivo)]), ['', 'num', 'num', 'num'])));

  // 4. Distribuição
  const maxPct = Math.max(1, ...r.distribuicao.faixas.map((f) => f.pct));
  doc.append(relSecao('4. Distribuição de performance',
    relTabela(['Faixa de score', 'Colaboradores', '%', ''], r.distribuicao.faixas.map((f) => [f.faixa, String(f.colaboradores), RP(f.pct), el('div', { class: `rel-barra faixa-${f.id}`, style: `width:${Math.round(f.pct / maxPct * 100)}%` })]), ['', 'num', 'num', 'barra']),
    relNota(`Base: ${r.distribuicao.base} colaboradores/logins com registro no período (score médio individual).`)));

  // 5. Alertas
  const al = r.alertas;
  const aviso = (titulo, itens, total, vazio) => [el('h4', { text: titulo }), itens.length ? relTabela(['Colaborador', 'Score', 'Tempo ativo', 'Dias', 'Centro de custo / cargo'], itens.map(relPessoaLinha), ['', 'num', 'num', 'num', '']) : relNota(vazio), total > itens.length ? relNota(`Mostrando ${itens.length} de ${total}.`) : null];
  const al5 = [
    ...aviso('CRÍTICO - score abaixo de 30 (ação imediata)', al.critico, al.total_critico, 'Nenhum colaborador abaixo de 30 pontos no período.'),
    ...aviso('ATENÇÃO - score entre 30 e 50 (acompanhamento recomendado)', al.atencao, al.total_atencao, 'Nenhum colaborador entre 30 e 50 pontos.'),
    ...aviso('ACOMPANHAMENTO - 10 menores scores com 5 ou mais dias registrados', al.acompanhamento, al.acompanhamento.length, 'Nenhum colaborador com 5 ou mais dias no período.'),
    el('h4', { text: 'VERIFICAR - menos de 5 dias registrados no período' }),
    al.poucos_dias.itens.length ? relTabela(['Colaborador / login', 'Dias', 'Score', 'Centro de custo / cargo'], al.poucos_dias.itens.map((p) => [p.nome, String(p.dias), RN(p.score), p.centro_custo || p.cargo || '—']), ['', 'num', 'num', '']) : relNota('Todos têm 5 ou mais dias.'),
    relNota('Poucos dias podem refletir férias, afastamento, admissão/desligamento ou conta de serviço: confirmar antes de interpretar o score.'),
  ];
  if (al.sem_rh) al5.push(el('h4', { text: `VERIFICAR - ${al.sem_rh.total} login(s) sem vínculo com o cadastro do RH (${RN(al.sem_rh.registros, 0)} registros, ${RP(al.sem_rh.pct_registros)} do período)` }),
    al.sem_rh.total ? relTabela(['Login', 'Dias', 'Score', 'Tempo ativo'], al.sem_rh.itens.map((p) => [p.login, String(p.dias), RN(p.score), RH(p.tempo_ativo_medio_dia_seg)]), ['', 'num', 'num', 'num']) : relNota('Todos têm vínculo com o RH.'));
  doc.append(relSecao('5. Alertas e pontos de atenção', ...al5));

  // 6. Top 10
  doc.append(relSecao('6. Destaques positivos',
    r.top10.length ? relTabela(['#', 'Colaborador', 'Score', 'Tempo ativo', '% Prod', 'Cargo'], r.top10.map((p, i) => [String(i + 1), p.nome, RN(p.score), RH(p.tempo_ativo_medio_dia_seg), RP(p.pct_tempo_produtivo), p.cargo || '—']), ['num', '', 'num', 'num', 'num', '']) : relNota('Nenhum colaborador com 5 ou mais dias no período.')));

  // 7. Centro de custo
  if (r.centros_custo) {
    const tc = (itens) => relTabela(['Centro de custo', 'Score', 'Tempo', 'Colab.'], itens.map((c) => [c.centro_custo, RN(c.score), RH(c.tempo_ativo_medio_dia_seg), String(c.colaboradores)]), ['', 'num', 'num', 'num']);
    doc.append(relSecao('7. Análise por centro de custo', el('h4', { text: 'Menor performance (top 10)' }), tc(r.centros_custo.menores), el('h4', { text: 'Melhor performance (top 10)' }), tc(r.centros_custo.melhores),
      relNota('Centros com 1 ou 2 colaboradores oscilam muito: interpretar com cautela. Registros sem cadastro do RH não entram nesta análise.')));
  } else doc.append(relSecao('7. Análise por centro de custo', relNota('Disponível depois de importar o cadastro do RH com o centro de custo (Administração > Cadastro do RH).')));

  // 8. Diário
  doc.append(relSecao('8. Evolução diária do período', relTabela(['Data', 'Score', 'Tempo ativo', 'Registros'], r.diario.map((d) => [RDia(d.dia), RN(d.score), RH(d.tempo_ativo_medio_dia_seg), String(d.registros)]), ['', 'num', 'num', 'num'])));

  // 9. Recomendações
  doc.append(relSecao('9. Recomendações', el('ol', null, ...r.recomendacoes.map((x) => el('li', null, el('b', { text: x.titulo + ': ' }), x.texto)))));

  const g = new Date(r.gerado_em);
  doc.append(el('footer', { class: 'rel-rodape', text: `Relatório gerado em ${g.toLocaleDateString('pt-BR')} às ${g.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })} | Presença e Produtividade · Dados do Presença e Produtividade - Confidencial` }));
}

// ---- relatório individual: o mesmo modelo, sobre uma pessoa, comparada com a média do escritório ----
const relCatNome = (c) => ({ produtivo: 'Produtivo', neutro: 'Neutro', improdutivo: 'Improdutivo' }[c] || c);
const relCatSelo = (c) => el('span', { class: 'rel-cat cat-' + c, text: relCatNome(c) });

function relDesenharIndividual(r) {
  const doc = $('rel-doc');
  doc.replaceChildren();
  doc.hidden = false;
  const p = r.pessoa;
  doc.append(el('header', { class: 'rel-topo' },
    el('p', { class: 'rel-marca', text: 'PRESENÇA E PRODUTIVIDADE · Relatório gerencial' }),
    el('h2', { text: r.titulo }), el('p', { class: 'rel-sub', text: r.subtitulo })));
  doc.append(el('p', { class: 'rel-periodo', text: `Colaborador: ${p.nome} (${p.login}) · Cargo: ${p.cargo || '—'} · Centro de custo: ${p.centro_custo || '—'} · Jornada considerada: ${RN(p.jornada_horas)} h/dia` }));
  if (r.sem_dados) {
    doc.append(el('p', { class: 'rel-vazio', text: `Sem dados de presença e uso de ${p.nome} no período ${r.rotulo_periodo}. Escolha outro período.` }));
    return;
  }
  const per = r.periodo;
  const feriados = per.feriados_excluidos.length ? `; ${per.feriados_excluidos.map((d) => d.slice(8, 10) + '/' + d.slice(5, 7)).join(', ')} excluído(s) por feriado` : '';
  doc.append(
    el('div', { class: 'rel-kpis' },
      ...[[RN(r.kpis.score), 'Score'], [RH(r.kpis.tempo_ativo_medio_dia_seg), 'Tempo ativo/dia'], [RP(r.kpis.pct_tempo_produtivo), '% Produtivo'], [RN(r.kpis.dias_registro, 0), 'Dias com registro']]
        .map(([v, t]) => el('div', { class: 'rel-kpi' }, el('b', { text: v }), el('span', { text: t })))),
    el('p', { class: 'rel-periodo', text: `Período analisado: ${RDia(per.de)} a ${RDia(per.ate)} (${per.dias_uteis} dias úteis${feriados})${per.parcial ? ' - período em andamento' : ''}` }));

  doc.append(relSecao('Metas e comparação com o escritório',
    relTabela(['Indicador', 'Valor', 'Média do escritório', 'Meta', 'Situação'], r.indicadores.map((i) => [i.indicador, i.valor, i.escritorio, i.meta, el('span', { class: i.atingida ? 'rel-ok' : 'rel-falta', text: i.atingida ? '✔ Atingida' : '✖ Abaixo' })]), ['', 'num', 'num', 'num', '']),
    relNota(`Primeiro clique médio: ${r.cliques.primeiro_medio || '—'} (escritório ${r.cliques.primeiro_escritorio || '—'}) · Último clique médio: ${r.cliques.ultimo_medio || '—'} (escritório ${r.cliques.ultimo_escritorio || '—'}).`)));

  const cl = r.classificacao;
  doc.append(relSecao('1. Sumário',
    cl ? el('p', { class: 'rel-class' }, 'CLASSIFICAÇÃO: ', el('b', { text: cl.faixa }), ` - score ${RN(cl.score)} (meta ${RN(cl.meta, 0)}), ${cl.acima_da_meta ? 'acima' : 'abaixo'} da meta.`) : null,
    el('h4', { text: 'Principais achados' }), el('ul', null, ...r.achados.map((a) => el('li', { text: a }))),
    r.evolucao.length ? el('h4', { text: 'Evolução' }) : null,
    r.evolucao.length ? relTabela(['Período', 'Dias úteis', 'Dias com registro', 'Score', 'Tempo ativo', '% Produtivo'],
      r.evolucao.map((e) => [e.rotulo, String(e.dias_uteis), String(e.dias), RN(e.score), RH(e.tempo_ativo_medio_dia_seg), RP(e.pct_tempo_produtivo)]), ['', 'num', 'num', 'num', 'num', 'num']) : null));

  const mod = [r.modalidade.length ? relTabela(['Modalidade', 'Dias', 'Score', 'Tempo ativo', '% Produtivo'], r.modalidade.map((m) => [m.modalidade, RN(m.registros, 0), RN(m.score), RH(m.tempo_ativo_medio_dia_seg), RP(m.pct_tempo_produtivo)]), ['', 'num', 'num', 'num', 'num']) : relNota('Nenhum dia com local definido no período.')];
  mod.push(relNota(`Cada dia vale pelo local onde o computador ficou mais tempo (60% das leituras em casa = dia de home).${r.dias_sem_local ? ` ${r.dias_sem_local} dia(s) ficaram sem local definido (poucas leituras ou sem rede) e não entram na comparação.` : ''}`));
  doc.append(relSecao('2. Presencial e remoto', ...mod));

  doc.append(relSecao('3. Dia da semana', relTabela(['Dia', 'Dias', 'Score', 'Tempo ativo', '% Produtivo'], r.dia_semana.map((d) => [d.nome, RN(d.registros, 0), RN(d.score), RH(d.tempo_ativo_medio_dia_seg), RP(d.pct_tempo_produtivo)]), ['', 'num', 'num', 'num', 'num'])));

  if (r.posicao) doc.append(relSecao('4. Posição no escritório',
    el('p', { class: 'rel-class' }, el('b', { text: `${r.posicao.posicao}º de ${r.posicao.de}` }), ` colaboradores com 5 ou mais dias registrados (score acima de ${r.posicao.acima_de_pct}% deles).`),
    relNota('Comparação por score médio no período. Cargos e funções têm rotinas diferentes: use como referência, não como ranking de mérito.')));
  else doc.append(relSecao('4. Posição no escritório', relNota('Sem posição: é preciso ter 5 ou mais dias registrados (e pelo menos 5 colaboradores nessa condição) para comparar.')));

  const t = r.tempo, c = t.categorias;
  const linhasCat = [['produtivo', c.produtivo_seg], ['neutro', c.neutro_seg], ['improdutivo', c.improdutivo_seg]].map(([k, seg]) => [relCatSelo(k), RH(seg), RP(c.total_seg > 0 ? seg * 100 / c.total_seg : null), el('div', { class: 'rel-barra cat-fundo-' + k, style: 'width:' + Math.round(c.total_seg > 0 ? seg * 100 / c.total_seg : 0) + '%' })]);
  const lista = (itens, vazio) => (itens.length ? relTabela(['Nome', 'Tipo de uso', 'Tempo', '% do tempo'], itens.map((x) => [x.nome, relCatSelo(x.categoria), RH(x.seg), RP(x.pct)]), ['', '', 'num', 'num']) : relNota(vazio));
  doc.append(relSecao('5. Onde o tempo foi gasto',
    relTabela(['Tipo de uso', 'Tempo', '%', ''], linhasCat, ['', 'num', 'num', 'barra']),
    el('h4', { text: 'Sites mais usados' }), lista(t.sites, 'Sem navegação registrada no período.'),
    el('h4', { text: 'Programas mais usados' }), lista(t.programas, 'Sem programas registrados no período.'),
    relNota('O navegador conta pelos sites. A classificação (produtivo, neutro, improdutivo) vem das regras da Classificação de sites e pode ser revista.')));

  doc.append(relSecao('6. Dia a dia', relTabela(['Data', 'Dia', 'Local', 'Score', 'Tempo ativo', 'Primeiro clique', 'Último clique', 'Ocioso'],
    r.diario.map((d) => [RDia(d.dia), d.dia_semana, d.modalidade, RN(d.score), RH(d.tempo_ativo_seg), d.primeiro_click || '—', d.ultimo_click || '—', d.ocioso_seg === null ? '—' : `${RN(d.ocioso_seg / 60, 0)} min`]), ['', '', '', 'num', 'num', 'num', 'num', 'num'])));

  doc.append(relSecao('7. Recomendações', el('ol', null, ...r.recomendacoes.map((x) => el('li', null, el('b', { text: x.titulo + ': ' }), x.texto)))));

  const g = new Date(r.gerado_em);
  doc.append(el('footer', { class: 'rel-rodape', text: `Relatório individual gerado em ${g.toLocaleDateString('pt-BR')} às ${g.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })} | Presença e Produtividade · Dados do Presença e Produtividade - Confidencial: uso restrito à gestão e ao RH` }));
}

function relConsulta() {
  const quem = relEstado.escopo === 'individual' ? `&login=${encodeURIComponent(relEstado.login)}` : '';
  if (relEstado.tipo === 'mensal') return `tipo=mensal&mes=${encodeURIComponent($('rel-mes').value)}${quem}`;
  if (relEstado.tipo === 'semanal') return `tipo=semanal&data=${encodeURIComponent($('rel-data').value)}${quem}`;
  return `tipo=personalizado&de=${encodeURIComponent($('rel-de').value)}&ate=${encodeURIComponent($('rel-ate').value)}${quem}`;
}

async function relGerar() {
  const msg = $('rel-msg');
  if (relEstado.escopo === 'individual' && !relEstado.login) { msg.textContent = 'Escolha o colaborador na lista (digite o nome ou o login).'; return; }
  msg.textContent = 'Calculando…';
  $('rel-gerar').disabled = true;
  try {
    const r = await api(`api/relatorio?${relConsulta()}`);
    relEstado.dados = r;
    relDesenhar(r);
    msg.textContent = r.sem_dados ? '' : `Pronto. Use "Imprimir / salvar PDF" para guardar.`;
    $('rel-imprimir').disabled = !!r.sem_dados;
  } catch (e) { msg.textContent = `Não foi possível gerar: ${e.message}`; }
  $('rel-gerar').disabled = false;
}

function relEscolherEscopo(escopo) {
  relEstado.escopo = escopo;
  for (const b of document.querySelectorAll('#rel-escopo .seg-btn')) b.setAttribute('aria-pressed', String(b.dataset.escopo === escopo));
  $('rel-l-colab').hidden = escopo !== 'individual';
  if (escopo === 'individual') $('rel-colab').focus();
}

// Lista de colaboradores para o seletor (nome - login); digitar parte do nome ou do login filtra.
async function relCarregarColabs() {
  try {
    const r = await api('api/colaboradores');
    relEstado.colabs = new Map();
    const lista = $('rel-colab-lista');
    lista.replaceChildren();
    for (const c of r.itens) {
      relEstado.colabs.set(c.colaborador, c.login);
      lista.append(el('option', { value: c.colaborador }));
    }
  } catch (e) { /* o seletor fica vazio; o aviso aparece ao gerar */ }
}

function relEscolherTipo(tipo) {
  relEstado.tipo = tipo;
  for (const b of document.querySelectorAll('#rel-tipo .seg-btn')) b.setAttribute('aria-pressed', String(b.dataset.tipo === tipo));
  $('rel-l-mes').hidden = tipo !== 'mensal';
  $('rel-l-sem').hidden = tipo !== 'semanal';
  $('rel-l-per').hidden = tipo !== 'personalizado';
}

for (const b of document.querySelectorAll('#rel-tipo .seg-btn')) b.addEventListener('click', () => { relEscolherTipo(b.dataset.tipo); relGerar(); });
for (const b of document.querySelectorAll('#rel-escopo .seg-btn')) b.addEventListener('click', () => {
  relEscolherEscopo(b.dataset.escopo);
  if (b.dataset.escopo === 'geral') relGerar();
});
$('rel-colab').addEventListener('input', () => {
  const v = $('rel-colab').value.trim();
  const login = relEstado.colabs.get(v) || [...relEstado.colabs.values()].find((l) => l === v.toLowerCase()) || '';
  if (login && login !== relEstado.login) { relEstado.login = login; relGerar(); }
  else if (!login) relEstado.login = '';
});
$('rel-gerar').addEventListener('click', relGerar);
$('rel-imprimir').addEventListener('click', () => window.print());
for (const id of ['rel-mes', 'rel-data', 'rel-de', 'rel-ate']) $(id).addEventListener('change', relGerar);

P.abas.relatorio = {
  carregar() {
    if (!$('rel-mes').value) {
      $('rel-mes').value = relMesAnterior();
      $('rel-data').value = somaDias(hoje(), -7);
      $('rel-ate').value = somaDias(hoje(), -1);
      $('rel-de').value = somaDias(hoje(), -30);
      relEscolherTipo('mensal');
      relCarregarColabs();
      relGerar();
    }
  },
};
})();
