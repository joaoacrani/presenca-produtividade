'use strict';
// Classificação de sites (todos veem, só administradores alteram) e Administração.

// ---------- classificação ----------
async function carregarClassificacao() {
  const ehAdmin = P.eu.papel === 'admin';
  $('cl-nova-painel').hidden = !ehAdmin;
  $('cl-auto').hidden = !ehAdmin;
  try {
    const [pend, regras] = await Promise.all([api(`api/dominios-sem-regra?de=${somaDias(hoje(), -29)}&ate=${hoje()}`), api('api/regras')]);
    $('cl-auto-novos').checked = !!regras.auto_ativo;
    listaSemRegra($('cl-pendentes'), pend.itens, carregarClassificacao);
    try { listaProgramasSemRegra($('cl-prog-pendentes'), (await api(`api/programas-sem-regra?de=${somaDias(hoje(), -29)}&ate=${hoje()}`)).itens, carregarClassificacao); } catch (e) { $('cl-prog-pendentes').replaceChildren(el('p', { class: 'aviso', text: `Falha: ${e.message}` })); }
    const alvo = $('cl-listas');
    alvo.replaceChildren();
    for (const c of CATEGORIAS) {
      const itens = regras.itens.filter((r) => r.categoria === c.id);
      const painel = el('div', { class: 'painel' }, el('div', { class: 'painel-topo' }, seloCategoria(c.id), el('span', { class: 'mudo', text: `${itens.length} regras` })));
      const ul = el('ul', { class: 'lista-regras' });
      for (const r of itens) {
        ul.append(el('li', null, el('span', { text: r.padrao.startsWith('app:') ? `Programa: ${r.padrao.slice(4)}` : r.padrao }),
          r.criado_por === 'auto' ? el('span', { class: 'etq', title: 'Criada pela classificação automática', text: 'auto' }) : null,
          ehAdmin ? el('button', { class: 'btn pequeno', type: 'button', 'aria-label': `Remover ${r.padrao}`, onclick: async () => {
            try { await api(`api/regras?id=${r.id}`, { metodo: 'DELETE' }); carregarClassificacao(); } catch (e) { alert(e.message); }
          } }, 'Remover') : null));
      }
      painel.append(ul);
      alvo.append(painel);
    }
  } catch (e) {
    $('cl-pendentes').replaceChildren(el('p', { class: 'aviso', text: `Falha ao carregar: ${e.message}` }));
  }
}
P.abas.classificacao = { carregar: carregarClassificacao };

// ---------- classificação automática ----------
$('cl-auto-btn').addEventListener('click', async (ev) => {
  const b = ev.currentTarget; b.disabled = true; b.textContent = 'Classificando…';
  try {
    const r = await api(`api/regras/auto?de=${somaDias(hoje(), -29)}&ate=${hoje()}`, { metodo: 'POST', corpo: {} });
    const c = r.por_categoria;
    const msg = $('cl-auto-msg');
    msg.hidden = false;
    msg.textContent = r.aplicadas
      ? `${r.aplicadas} classificado(s) automaticamente: ${c.produtivo} produtivo · ${c.neutro} neutro · ${c.improdutivo} improdutivo. Restam ${r.restantes.sites} site(s) e ${r.restantes.programas} programa(s) para você decidir.`
      : `Nada novo para classificar automaticamente. Restam ${r.restantes.sites} site(s) e ${r.restantes.programas} programa(s) para você decidir.`;
    await carregarClassificacao();
  } catch (e) { alert(e.message); }
  b.disabled = false; b.textContent = 'Classificar automaticamente';
});
$('cl-auto-novos').addEventListener('change', async (ev) => {
  try { await api('api/regras/auto-config', { metodo: 'PUT', corpo: { ativo: ev.target.checked } }); } catch (e) { alert(e.message); ev.target.checked = !ev.target.checked; }
});
$('cl-auto-desfazer').addEventListener('click', async () => {
  if (!confirm('Remover todas as regras criadas automaticamente? As regras que você criou ou alterou ficam. Os sites voltam para a lista "sem classificação".')) return;
  try {
    const r = await api('api/regras/auto', { metodo: 'DELETE' });
    const msg = $('cl-auto-msg'); msg.hidden = false; msg.textContent = `${r.removidas} regra(s) automática(s) removida(s).`;
    await carregarClassificacao();
  } catch (e) { alert(e.message); }
});

$('cl-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  try {
    await api('api/regras', { metodo: 'POST', corpo: { padrao: $('cl-dominio').value, categoria: $('cl-cat').value } });
    $('cl-dominio').value = '';
    carregarClassificacao();
  } catch (e) { alert(e.message); }
});

// ---------- administração ----------
const adEstado = { periodo: null };

function ajustarLinksCsv() {
  const q = adEstado.periodo.consulta();
  $('ad-nav-csv').href = `api/export/acessos.csv?${q}`;
  $('ad-foco-csv').href = `api/export/foco.csv?${q}`;
  $('ad-leit-csv').href = `api/export/leituras.csv?${q}`;
}

async function carregarAdmin() {
  if (P.eu.papel !== 'admin') return;
  if (!adEstado.periodo) {
    adEstado.periodo = controlePeriodo($('ad-periodo'), 7, () => ajustarLinksCsv());
  }
  ajustarLinksCsv();
  await Promise.all([carregarColabs(), carregarUsuarios(), carregarAuditoria(), carregarOcultas(), carregarServidores(), carregarApiTokens(), carregarTokensAgentes(), carregarBackup(), carregarAlertas()]);
}

async function carregarColabs() {
  const corpo = document.querySelector('#ad-colabs tbody');
  try {
    const r = await api('api/colaboradores');
    corpo.replaceChildren();
    for (const c of r.itens) {
      const nome = el('input', { type: 'text', value: c.nome, placeholder: 'nome completo', 'aria-label': `Nome de ${c.login}`, maxlength: '150' });
      const setor = el('input', { type: 'text', value: c.setor, 'aria-label': `Setor de ${c.login}`, maxlength: '60' });
      const cargo = el('input', { type: 'text', value: c.cargo || '', 'aria-label': `Cargo de ${c.login}`, maxlength: '80' });
      const cc = el('input', { type: 'text', value: c.centro_custo || '', 'aria-label': `Centro de custo de ${c.login}`, maxlength: '120' });
      const ativo = el('input', { type: 'checkbox', 'aria-label': `Ativo: ${c.login}` });
      ativo.checked = c.ativo;
      const salvar = el('button', { class: 'btn pequeno', type: 'button', onclick: async (ev) => {
        ev.target.disabled = true;
        try {
          await api('api/colaboradores', { metodo: 'PUT', corpo: { login: c.login, nome: nome.value, setor: setor.value, cargo: cargo.value, centro_custo: cc.value, ativo: ativo.checked } });
          ev.target.textContent = 'Salvo ✓';
          setTimeout(() => { ev.target.textContent = 'Salvar'; ev.target.disabled = false; }, 1200);
        } catch (e) { alert(e.message); ev.target.disabled = false; }
      } }, 'Salvar');
      const excluir = el('button', { class: 'btn pequeno', type: 'button', title: 'Apaga leituras, sites e cadastro deste colaborador', onclick: async () => {
        if (!confirm(`Excluir DEFINITIVAMENTE ${c.colaborador || c.login}?\n\nApaga todas as leituras de presença, o histórico de sites e o cadastro. Não dá para desfazer.\nSe o PC dele ainda tiver o agent instalado, ele volta a aparecer.`)) return;
        try {
          const r = await api(`api/colaboradores?login=${encodeURIComponent(c.login)}`, { metodo: 'DELETE' });
          alert(`Excluído. Leituras removidas: ${r.removidos.registros}; acessos a sites: ${r.removidos.navegacao}.`);
          carregarColabs();
        } catch (e) { alert(e.message); }
      } }, 'Excluir');
      corpo.append(el('tr', null, el('td', { text: c.login }), el('td', null, nome), el('td', null, setor), el('td', null, cargo), el('td', null, cc), el('td', null, ativo), el('td', null, salvar, ' ', excluir)));
    }
  } catch (e) {
    corpo.replaceChildren(el('tr', null, el('td', { colspan: '8', class: 'mudo', text: `Falha: ${e.message}` })));
  }
}

async function carregarUsuarios() {
  const corpo = document.querySelector('#ad-usuarios tbody');
  try {
    const r = await api('api/usuarios');
    corpo.replaceChildren();
    for (const u of r.itens) {
      const acao = async (corpoReq, msg) => {
        try { await api('api/usuarios', { metodo: 'PUT', corpo: { id: u.id, ...corpoReq } }); carregarUsuarios(); } catch (e) { alert(msg ? `${msg}: ${e.message}` : e.message); }
      };
      corpo.append(el('tr', null,
        el('td', { text: u.login }), el('td', { text: u.nome || '—' }),
        el('td', { text: u.papel === 'admin' ? 'Administrador' : 'Gestor' }),
        el('td', { text: u.totp_ativo ? 'Ativo' : '—' }),
        el('td', null, el('span', { class: 'selo', style: `--cor:${u.ativo ? 'var(--presencial)' : 'var(--semsinal)'}`, text: u.ativo ? 'Ativo' : 'Inativo' })),
        el('td', { text: u.ultimo_login ? dataCurta(u.ultimo_login) : 'nunca' }),
        el('td', { class: 'grupo-btn' },
          el('button', { class: 'btn pequeno', type: 'button', onclick: () => {
            const s = prompt(`Nova senha para ${u.login} (mínimo 12 caracteres):`);
            if (s) acao({ senha: s }, 'Senha não alterada');
          } }, 'Redefinir senha'),
          el('button', { class: 'btn pequeno', type: 'button', onclick: () => acao({ papel: u.papel === 'admin' ? 'gestor' : 'admin' }) }, u.papel === 'admin' ? 'Tornar gestor' : 'Tornar admin'),
          u.totp_ativo ? el('button', { class: 'btn pequeno', type: 'button', onclick: () => { if (confirm(`Resetar o 2FA de ${u.login}? Ele poderá entrar só com a senha e ativar de novo.`)) acao({ reset_2fa: true }); } }, 'Resetar 2FA') : null,
          el('button', { class: 'btn pequeno', type: 'button', onclick: () => acao({ ativo: !u.ativo }) }, u.ativo ? 'Desativar' : 'Ativar'))));
    }
  } catch (e) {
    corpo.replaceChildren(el('tr', null, el('td', { colspan: '7', class: 'mudo', text: `Falha: ${e.message}` })));
  }
}

$('ad-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  try {
    await api('api/usuarios', { metodo: 'POST', corpo: { login: $('ad-login').value, nome: $('ad-nome').value, senha: $('ad-senha').value, papel: $('ad-papel').value } });
    ev.target.reset();
    carregarUsuarios();
  } catch (e) { alert(e.message); }
});
P.abas.admin = { carregar: carregarAdmin };

// ---------- auditoria ----------
const ROTULO_EVENTO = {
  rh_importado: 'Cadastro do RH importado',
  api_token_criado: 'API: token criado', api_token_revogado: 'API: token revogado', api_acesso: 'API: consulta de dados',
  login_ok: 'Entrou', login_falha: 'Falha de login', login_bloqueado: 'Conta bloqueada', login_bloqueado_ip: 'IP bloqueado', logout: 'Saiu',
  exportacao: 'Exportou', regra_salva: 'Regra salva', regra_removida: 'Regra removida', usuario_criado: 'Usuário criado', usuario_alterado: 'Usuário alterado',
  agente_atualizado: 'Agente atualizado', regras_automaticas: 'Classificação automática aplicada', regras_automaticas_desfeitas: 'Classificação automática desfeita', classificacao_auto_config: 'Classificação automática: configuração', acesso_remoto: 'Acesso remoto (senha consultada)', remoto_registrado: 'Acesso remoto registrado', remoto_config: 'Acesso remoto: liberação', colaborador_alterado: 'Colaborador alterado', senha_alterada: 'Senha alterada', '2fa_ativado': '2FA ativado', maquina_ocultada: 'Máquina ocultada', maquina_restaurada: 'Máquina restaurada', maquina_excluida: 'Máquina excluída', '2fa_desativado': '2FA desativado', '2fa_resetado': '2FA resetado',
};
const EVENTO_ALERTA = new Set(['login_falha', 'login_bloqueado', 'login_bloqueado_ip', '2fa_resetado', '2fa_desativado']);

async function carregarAuditoria() {
  $('au-meu-ip').textContent = P.eu.ip || '—';
  const corpo = document.querySelector('#au-tabela tbody');
  try {
    const ev = $('au-evento').value;
    const r = await api(`api/auditoria?limite=200${ev ? '&evento=' + encodeURIComponent(ev) : ''}`);
    corpo.replaceChildren();
    for (const x of r.itens) {
      corpo.append(el('tr', null,
        el('td', { text: new Date(x.ts).toLocaleString('pt-BR') }), el('td', { text: x.login || '—' }), el('td', { text: x.ip || '—' }),
        el('td', null, el('span', { class: 'selo', style: `--cor:${EVENTO_ALERTA.has(x.evento) ? 'var(--improdutivo)' : 'var(--semsinal)'}`, text: ROTULO_EVENTO[x.evento] || x.evento })),
        el('td', { class: 'obs', text: x.detalhe || '' })));
    }
    if (!r.itens.length) corpo.append(el('tr', null, el('td', { colspan: '5', class: 'mudo', text: 'Nenhum evento.' })));
  } catch (e) {
    corpo.replaceChildren(el('tr', null, el('td', { colspan: '5', class: 'mudo', text: `Falha: ${e.message}` })));
  }
}
$('au-evento').addEventListener('change', carregarAuditoria);
// ---------- máquinas ocultas ----------
async function carregarServidores() {
  const corpo = document.querySelector('#ad-servidores tbody');
  try {
    const r = await api('api/servidores');
    corpo.replaceChildren();
    for (const x of r.itens) {
      corpo.append(el('tr', null, el('td', { text: x.host }), el('td', { text: x.por || '—' }),
        el('td', null, el('button', { class: 'btn pequeno', type: 'button', onclick: async () => {
          try { await api('api/servidores', { metodo: 'POST', corpo: { host: x.host, servidor: false } }); carregarServidores(); } catch (e) { alert(e.message); }
        } }, 'Desmarcar'))));
    }
    if (!r.itens.length) corpo.append(el('tr', null, el('td', { colspan: '3', class: 'mudo', text: 'Nenhum servidor marcado.' })));
  } catch (e) {
    corpo.replaceChildren(el('tr', null, el('td', { colspan: '3', class: 'mudo', text: `Falha: ${e.message}` })));
  }
}

async function carregarOcultas() {
  const corpo = document.querySelector('#ad-ocultas tbody');
  try {
    const r = await api('api/maquinas/ocultas');
    corpo.replaceChildren();
    for (const x of r.itens) {
      corpo.append(el('tr', null, el('td', { text: x.host }), el('td', { text: dataCurta(x.ocultado_em) }), el('td', { text: x.por || '—' }),
        el('td', null, el('button', { class: 'btn pequeno', type: 'button', onclick: async () => {
          try { await api('api/maquinas/restaurar', { metodo: 'POST', corpo: { host: x.host } }); carregarOcultas(); } catch (e) { alert(e.message); }
        } }, 'Restaurar'))));
    }
    if (!r.itens.length) corpo.append(el('tr', null, el('td', { colspan: '4', class: 'mudo', text: 'Nenhuma máquina oculta.' })));
  } catch (e) {
    corpo.replaceChildren(el('tr', null, el('td', { colspan: '4', class: 'mudo', text: `Falha: ${e.message}` })));
  }
}
$('ad-zerar').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  if ($('ad-zerar-conf').value.trim() !== 'ZERAR') { alert('Digite ZERAR (em maiúsculas) para confirmar.'); return; }
  const colab = $('ad-zerar-colab').checked;
  if (!confirm(`Apagar TODAS as leituras de presença e de sites${colab ? ' e o cadastro de colaboradores' : ''}? Isso não pode ser desfeito.`)) return;
  try {
    const r = await api('api/leituras/zerar', { metodo: 'POST', corpo: { confirmacao: 'ZERAR', colaboradores: colab } });
    $('ad-zerar-conf').value = '';
    alert(`Pronto. Leituras apagadas: ${r.removidos.registros}.`);
    carregarAdmin();
  } catch (e) { alert(e.message); }
});

$('ad-serv-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const host = $('ad-serv-host').value.trim();
  if (!host) return;
  try { await api('api/servidores', { metodo: 'POST', corpo: { host, servidor: true } }); $('ad-serv-host').value = ''; carregarServidores(); } catch (e) { alert(e.message); }
});
$('ad-serv-recalc').addEventListener('click', async () => {
  if (!confirm('Refazer os resumos diários (presença, sites e programas) sem as leituras dos servidores?\n\nSó são refeitos os dias que ainda têm dados brutos (leituras 90 dias, sites 30, programas 60). Dias mais antigos ficam como estão.')) return;
  try {
    const r = (await api('api/resumos/reconstruir', { metodo: 'POST', corpo: {} })).resultado;
    alert(`Pronto.\nPresença refeita a partir de ${r.presenca_dia.a_partir_de || '—'} (${r.presenca_dia.linhas} linhas)\nSites a partir de ${r.nav_dia.a_partir_de || '—'} (${r.nav_dia.linhas})\nProgramas a partir de ${r.foco_dia.a_partir_de || '—'} (${r.foco_dia.linhas})`);
  } catch (e) { alert(e.message); }
});


// ---------- API de dados: tokens do analista ----------
async function carregarApiTokens() {
  $('ad-api-url').textContent = new URL('api/v1/', location.href).href;
  const corpo = document.querySelector('#ad-api-tabela tbody');
  const dh = (ms) => (ms ? new Date(ms).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : '—');
  try {
    const r = await api('api/api-tokens');
    corpo.replaceChildren();
    for (const x of r.itens) {
      const cor = x.estado === 'ativo' ? 'var(--presencial)' : 'var(--semsinal)';
      corpo.append(el('tr', null,
        el('td', null, el('strong', { text: x.nome }), x.anonimizar ? el('span', { class: 'etq', text: 'códigos' }) : null),
        el('td', { class: 'nowrap', text: x.prefixo + '…' }), el('td', { class: 'nowrap', text: dh(x.criado_em) }),
        el('td', { class: 'nowrap', text: x.expira_em ? dh(x.expira_em) : 'sem validade' }), el('td', { class: 'nowrap', text: dh(x.ultimo_uso) }),
        el('td', { text: String(x.usos) }),
        el('td', null, el('span', { class: 'selo', style: `--cor:${cor}`, text: x.estado })),
        el('td', null, x.estado === 'revogado' ? null : el('button', { class: 'btn pequeno', type: 'button', onclick: async () => {
          if (!confirm(`Revogar o token "${x.nome}"? Quem usa ele perde o acesso na hora.`)) return;
          try { await api(`api/api-tokens?id=${x.id}`, { metodo: 'DELETE' }); carregarApiTokens(); } catch (e) { alert(e.message); }
        } }, 'Revogar'))));
    }
    if (!r.itens.length) corpo.append(el('tr', null, el('td', { colspan: '8', class: 'mudo', text: 'Nenhum token criado.' })));
  } catch (e) {
    corpo.replaceChildren(el('tr', null, el('td', { colspan: '8', class: 'mudo', text: `Falha: ${e.message}` })));
  }
}
$('ad-api-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const nome = $('ad-api-nome').value.trim();
  if (!nome) { $('ad-api-nome').focus(); return; }
  try {
    const r = await api('api/api-tokens', { metodo: 'POST', corpo: { nome, validade_dias: parseInt($('ad-api-validade').value, 10), anonimizar: $('ad-api-anonimo').checked } });
    $('ad-api-valor').textContent = r.token;
    $('ad-api-novo').hidden = false;
    $('ad-api-nome').value = '';
    carregarApiTokens();
  } catch (e) { alert(e.message); }
});
$('ad-api-copiar').addEventListener('click', async () => {
  try { await navigator.clipboard.writeText($('ad-api-valor').textContent); $('ad-api-copiar').textContent = 'Copiado'; setTimeout(() => { $('ad-api-copiar').textContent = 'Copiar'; }, 2000); }
  catch (e) { alert('Não foi possível copiar: selecione o texto e copie manualmente.'); }
});


// ---------- alertas por e-mail ----------
async function carregarAlertas() {
  $('ad-al-health').textContent = new URL('health', location.href).href;
  try {
    const r = await api('api/alertas');
    $('ad-al-email').value = r.email || '';
    $('ad-al-ativo').checked = !!r.ativo;
  } catch (e) { $('ad-al-msg').textContent = 'Falha: ' + e.message; }
}
$('ad-al-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  try {
    await api('api/alertas', { metodo: 'PUT', corpo: { email: $('ad-al-email').value.trim(), ativo: $('ad-al-ativo').checked } });
    $('ad-al-msg').textContent = 'Salvo.';
  } catch (e) { $('ad-al-msg').textContent = e.message; }
});
$('ad-al-teste').addEventListener('click', async () => {
  $('ad-al-msg').textContent = 'Enviando...';
  try { await api('api/alertas/teste', { metodo: 'POST', corpo: {} }); $('ad-al-msg').textContent = 'Teste enviado: confira a caixa de entrada e o spam.'; }
  catch (e) { $('ad-al-msg').textContent = e.message; }
});

// ---------- backup do banco ----------
async function carregarBackup() {
  const mb = (n) => (n / 1048576).toFixed(1).replace('.', ',') + ' MB';
  try {
    const r = await api('api/backup');
    const quando = r.gerado_em ? new Date(r.gerado_em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : 'nunca';
    $('ad-bk-resumo').textContent = (r.ligado ? '' : 'Desligado no config.php. ') + 'Banco: ' + mb(r.tamanho_banco) + '. Última cópia: ' + quando + (r.existe ? ' (' + mb(r.tamanho) + ' aguardando o download do PC)' : ' (nenhuma no servidor agora: já foi baixada ou ainda não foi gerada)') + '. ' + (r.ultimo_estado || '');
  } catch (e) { $('ad-bk-resumo').textContent = 'Falha: ' + e.message; }
}
$('ad-bk-gerar').addEventListener('click', async () => {
  try { await api('api/backup/gerar', { metodo: 'POST', corpo: {} }); } catch (e) { alert(e.message); }
  carregarBackup();
});

// ---------- token proprio por maquina ----------
let tkPermitido = true;
async function carregarTokensAgentes() {
  const corpo = document.querySelector('#ad-tk-tabela tbody');
  const dh = (ms) => (ms ? new Date(ms).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : '—');
  try {
    const r = await api('api/agentes/tokens');
    tkPermitido = r.cadastro_permitido;
    $('ad-tk-resumo').textContent = r.registradas + ' máquina(s) com token próprio; ' + r.sem_token.length + ' ativa(s) nos últimos 30 dias ainda com o token de cadastro. Token de cadastro para envio: ' + (r.cadastro_permitido ? 'permitido' : 'desligado') + '.';
    $('ad-tk-alternar').textContent = r.cadastro_permitido ? 'Desligar token de cadastro para envio' : 'Permitir token de cadastro para envio';
    $('ad-tk-dica').textContent = r.cadastro_permitido ? (r.sem_token.length ? 'Ainda há máquinas sem token próprio: elas parariam de enviar.' : 'Todas as máquinas ativas já trocaram.') : 'Máquinas sem token próprio não enviam dados, mas ainda baixam a atualização do agent.';
    corpo.replaceChildren(...r.sem_token.map((x) => el('tr', null, el('td', { text: x.host }), el('td', { text: x.versao || '—' }), el('td', { class: 'nowrap', text: dh(x.visto_em) }))));
    if (!r.sem_token.length) corpo.append(el('tr', null, el('td', { colspan: '3', class: 'mudo', text: 'Nenhuma.' })));
  } catch (e) { corpo.replaceChildren(el('tr', null, el('td', { colspan: '3', class: 'mudo', text: 'Falha: ' + e.message }))); }
}
$('ad-tk-alternar').addEventListener('click', async () => {
  const desligar = tkPermitido;
  if (desligar && !confirm('Desligar o token de cadastro para envio? Máquinas que ainda não trocaram para o token próprio deixam de enviar dados até serem atualizadas.')) return;
  try { await api('api/agentes/tokens/cadastro', { metodo: 'PUT', corpo: { permitir: !desligar } }); carregarTokensAgentes(); } catch (e) { alert(e.message); }
});


// ---------- importacao do cadastro do RH (CSV) ----------
const RH_CAMPOS = {
  login: ['login', 'usuario', 'user', 'username', 'usuario de rede', 'login de rede'],
  nome: ['nome', 'nome completo', 'colaborador', 'funcionario', 'nome do colaborador', 'nome do funcionario'],
  cargo: ['cargo', 'funcao', 'cargo/funcao'],
  centro_custo: ['centro de custo', 'centro_custo', 'centro custo', 'centro de custos', 'cc', 'centro'],
};
function lerCsvRh(texto) {
  const prim = texto.split(/\r?\n/, 1)[0] || '';
  const sep = [';', '\t', ','].map((s) => [s, prim.split(s).length]).sort((a, b) => b[1] - a[1])[0][0];
  const linhas = []; let campo = '', linha = [], aspas = false;
  for (let i = 0; i < texto.length; i++) {
    const ch = texto[i];
    if (aspas) { if (ch === '"') { if (texto[i + 1] === '"') { campo += '"'; i++; } else aspas = false; } else campo += ch; }
    else if (ch === '"') aspas = true;
    else if (ch === sep) { linha.push(campo); campo = ''; }
    else if (ch === '\n') { linha.push(campo.replace(/\r$/, '')); campo = ''; linhas.push(linha); linha = []; }
    else campo += ch;
  }
  if (campo !== '' || linha.length) { linha.push(campo.replace(/\r$/, '')); linhas.push(linha); }
  const cab = (linhas.shift() || []).map((x) => semAcento(x).trim());
  const idx = {};
  for (const [k, nomes] of Object.entries(RH_CAMPOS)) { const i = cab.findIndex((c) => nomes.includes(c)); if (i >= 0) idx[k] = i; }
  const itens = linhas.filter((l) => l.some((x) => x.trim() !== '')).map((l) => {
    const o = {}; for (const [k, i] of Object.entries(idx)) o[k] = (l[i] || '').trim(); return o;
  });
  return { idx, itens };
}
let rhPendente = null;
$('ad-rh-arquivo').addEventListener('change', async (ev) => {
  const f = ev.target.files[0]; rhPendente = null; $('ad-rh-importar').disabled = true; $('ad-rh-resultado').replaceChildren();
  if (!f) { $('ad-rh-previa').textContent = ''; return; }
  const buf = await f.arrayBuffer();
  let texto;
  try { texto = new TextDecoder('utf-8', { fatal: true }).decode(buf); } catch (e) { texto = new TextDecoder('windows-1252').decode(buf); }   // Excel brasileiro salva em ANSI
  const r = lerCsvRh(texto.replace(/^\uFEFF/, ''));
  const achadas = Object.keys(r.idx);
  if (!(achadas.includes('login') || achadas.includes('nome')) || !(achadas.includes('cargo') || achadas.includes('centro_custo'))) {
    $('ad-rh-previa').textContent = 'Não reconheci as colunas. Preciso de login e/ou nome, e de cargo e/ou centro de custo na primeira linha. Colunas lidas: ' + (texto.split(/\r?\n/, 1)[0] || '').slice(0, 200);
    return;
  }
  rhPendente = r.itens;
  $('ad-rh-previa').textContent = `${r.itens.length} linha(s) lidas. Colunas reconhecidas: ${achadas.map((k) => ({ login: 'login', nome: 'nome', cargo: 'cargo', centro_custo: 'centro de custo' }[k])).join(', ')}.`;
  $('ad-rh-importar').disabled = false;
});
$('ad-rh-importar').addEventListener('click', async () => {
  if (!rhPendente) return;
  $('ad-rh-importar').disabled = true;
  try {
    const r = await api('api/colaboradores/importar-rh', { metodo: 'POST', corpo: { linhas: rhPendente } });
    const alvo = $('ad-rh-resultado');
    alvo.replaceChildren(el('p', null, el('b', { text: `${r.atualizados} colaborador(es) atualizados.` }), ` ${r.ignoradas} linha(s) sem cargo e sem centro de custo foram ignoradas.`));
    if (r.total_nao_encontrados) alvo.append(el('p', { class: 'mudo', text: `Não encontrados no painel (${r.total_nao_encontrados}): ${r.nao_encontrados.join('; ')}${r.total_nao_encontrados > r.nao_encontrados.length ? '…' : ''}` }));
    if (r.total_ambiguos) alvo.append(el('p', { class: 'mudo', text: `Nome repetido, não aplicado (${r.total_ambiguos}): ${r.ambiguos.join('; ')}` }));
    carregarColabs();
  } catch (e) { alert(e.message); }
  $('ad-rh-importar').disabled = false;
});
