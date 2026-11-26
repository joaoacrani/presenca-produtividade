'use strict';
// Relatórios: Relatório de Produtividade.

const relEstado = { prodPeriodo: null };

// ---------- produtividade ----------
async function carregarProdutividade() {
  if (!relEstado.prodPeriodo) relEstado.prodPeriodo = controlePeriodo($('prod-periodo'), 7, carregarProdutividade);
  const per = relEstado.prodPeriodo;
  $('prod-csv').href = `api/export/produtividade.csv?${per.consulta()}`;
  const corpo = document.querySelector('#prod-tabela tbody');
  const rodape = document.querySelector('#prod-tabela tfoot');
  try {
    const r = await api(`api/produtividade?${per.consulta()}`);
    corpo.replaceChildren();
    for (const c of r.colaboradores) {
      const s = c.segundos;
      corpo.append(el('tr', { class: 'linha', tabindex: '0', 'data-busca': semAcento(`${c.colaborador} ${c.login}`), onclick: () => abrirColaborador(c.login) },
        el('td', { text: c.colaborador }),
        el('td', { class: 'num', text: fmtDur(s.produtivo) }),
        el('td', { class: 'num', text: fmtDur(s.improdutivo) }),
        el('td', { class: 'num', text: fmtDur(s.neutro) }),
        el('td', { class: 'num', text: fmtDur(c.total_seg) }),
        el('td', { class: 'celula-barra' }, barraEmpilhada(
          CATEGORIAS.map((k) => ({ valor: s[k.id], cor: k.cor, rotulo: `${k.nome}: ${fmtDur(s[k.id])}` })), `${c.colaborador}: ${fmtPct(c.pct_produtivo)} produtivo`)),
        el('td', { class: 'num forte', text: fmtPct(c.pct_produtivo) })));
    }
    const t = r.totais;
    rodape.replaceChildren(el('tr', null,
      el('td', { text: 'Total' }), el('td', { class: 'num', text: fmtDur(t.segundos.produtivo) }),
      el('td', { class: 'num', text: fmtDur(t.segundos.improdutivo) }), el('td', { class: 'num', text: fmtDur(t.segundos.neutro) }),
      el('td', { class: 'num', text: fmtDur(t.total_seg) }), el('td'), el('td', { class: 'num forte', text: fmtPct(t.pct_produtivo) })));
    $('prod-vazio').hidden = r.colaboradores.length > 0;
    filtrarTabelaProd();
  } catch (e) {
    corpo.replaceChildren(el('tr', null, el('td', { colspan: '7', class: 'mudo', text: `Falha ao carregar: ${e.message}` })));
  }
}
P.abas.produtividade = { carregar: carregarProdutividade };
$('prod-imprimir').addEventListener('click', () => window.print());

function filtrarTabelaProd() {
  const t = semAcento($('prod-busca').value.trim());
  for (const tr of document.querySelectorAll('#prod-tabela tbody tr')) tr.hidden = !!t && !(tr.dataset.busca || '').includes(t);
}
$('prod-busca').addEventListener('input', filtrarTabelaProd);
