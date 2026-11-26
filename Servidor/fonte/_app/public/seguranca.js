'use strict';
// Segurança da conta: verificação em duas etapas (2FA por aplicativo autenticador).

// No modo obrigatório, Esc não pode fechar o assistente (senão a tela ficaria vazia)
$('dlg-2fa').addEventListener('cancel', (e) => { if (P.eu && P.eu.precisa_configurar_2fa) e.preventDefault(); });

// QR code em SVG (fundo branco e margem de 4 módulos, como exige o padrão, para ler bem no tema escuro)
function qrSvg(texto, tamanho) {
  const qr = qrcode(0, 'M');
  qr.addData(texto);
  qr.make();
  const n = qr.getModuleCount(), q = 4, total = n + q * 2, NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', `0 0 ${total} ${total}`);
  svg.setAttribute('width', tamanho); svg.setAttribute('height', tamanho);
  svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', 'QR code para o aplicativo autenticador');
  svg.setAttribute('shape-rendering', 'crispEdges');
  const fundo = document.createElementNS(NS, 'rect');
  fundo.setAttribute('width', total); fundo.setAttribute('height', total); fundo.setAttribute('fill', '#ffffff');
  svg.append(fundo);
  let d = '';
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (qr.isDark(r, c)) d += `M${c + q} ${r + q}h1v1h-1z`;
  const p = document.createElementNS(NS, 'path');
  p.setAttribute('d', d); p.setAttribute('fill', '#000000');
  svg.append(p);
  return svg;
}

function agruparSegredo(s) { return s.replace(/(.{4})/g, '$1 ').trim(); }

async function abrir2fa(forcado) {
  const dlg = $('dlg-2fa');
  const corpo = $('d2-corpo');
  const fechar = () => { if (forcado) return; dlg.close(); };
  const erro = el('p', { class: 'erro', role: 'alert', hidden: true });
  const mostrarErro = (m) => { erro.textContent = m; erro.hidden = false; };
  corpo.replaceChildren();

  if (forcado) corpo.append(el('p', { class: 'aviso', text: 'Este servidor exige a verificação em duas etapas. Ative para continuar.' }));

  if (P.eu.totp_ativo) {
    const senha = el('input', { type: 'password', autocomplete: 'current-password', 'aria-label': 'Senha atual' });
    const cod = el('input', { type: 'text', inputmode: 'numeric', maxlength: '6', autocomplete: 'one-time-code', 'aria-label': 'Código do aplicativo' });
    corpo.append(el('h3', { text: 'Verificação em duas etapas' }),
      el('p', null, el('span', { class: 'selo', style: '--cor:var(--presencial)', text: 'Ativa' })),
      el('p', { class: 'mudo', text: 'Para desativar, confirme a senha e um código atual do aplicativo.' }),
      el('label', null, 'Senha atual', senha), el('label', null, 'Código de 6 dígitos', cod), erro,
      el('div', { class: 'dlg-acoes' },
        el('button', { class: 'btn', type: 'button', onclick: fechar }, 'Fechar'),
        el('button', { class: 'btn', type: 'button', onclick: async () => {
          erro.hidden = true;
          try { await api('api/2fa/desativar', { metodo: 'POST', corpo: { senha: senha.value, codigo: cod.value } }); P.eu.totp_ativo = false; dlg.close(); alert('Verificação em duas etapas desativada.'); }
          catch (e) { mostrarErro(e.message); }
        } }, 'Desativar')));
  } else {
    corpo.append(el('h3', { text: 'Ativar verificação em duas etapas' }),
      el('p', { class: 'mudo', text: 'Você precisará de um aplicativo autenticador no celular (Microsoft Authenticator, Google Authenticator, Authy…).' }));
    const area = el('div');
    corpo.append(area, erro);
    const botoes = el('div', { class: 'dlg-acoes' });
    if (!forcado) botoes.append(el('button', { class: 'btn', type: 'button', onclick: fechar }, 'Cancelar'));
    corpo.append(botoes);
    const comecar = el('button', { class: 'btn primario', type: 'button', onclick: async (ev) => {
      ev.target.disabled = true; erro.hidden = true;
      try {
        const r = await api('api/2fa/iniciar', { metodo: 'POST', corpo: {} });
        const cod = el('input', { type: 'text', inputmode: 'numeric', maxlength: '6', autocomplete: 'one-time-code', 'aria-label': 'Código de 6 dígitos' });
        area.replaceChildren(
          el('ol', { class: 'passos' },
            el('li', { text: 'No aplicativo autenticador, adicione uma conta e escaneie o QR code abaixo.' }),
            el('li', { text: 'Sem câmera? Escolha “inserir chave de configuração” e digite a chave que aparece abaixo do QR code.' }),
            el('li', { text: 'Digite o código de 6 dígitos que o aplicativo mostrar.' })),
          el('div', { class: 'qr-caixa' }, qrSvg(r.uri, 220)),
          el('p', { class: 'mudo pequeno centro', text: 'Chave de configuração (tipo: baseado em tempo)' }),
          el('p', { class: 'centro' }, el('code', { class: 'chave', text: agruparSegredo(r.segredo) })),
          el('p', { class: 'centro' }, el('button', { class: 'btn pequeno', type: 'button', onclick: (e) => {
            if (navigator.clipboard) navigator.clipboard.writeText(r.segredo).then(() => { e.target.textContent = 'Copiada ✓'; });
          } }, 'Copiar chave')),
          el('label', null, 'Código de 6 dígitos', cod));
        botoes.replaceChildren(el('button', { class: 'btn primario', type: 'button', onclick: async () => {
          erro.hidden = true;
          try {
            const a = await api('api/2fa/ativar', { metodo: 'POST', corpo: { codigo: cod.value } });
            P.eu.totp_ativo = true; P.eu.precisa_configurar_2fa = false;
            mostrarCodigosRecuperacao(a.codigos_recuperacao, forcado);
          } catch (e) { mostrarErro(e.message); }
        } }, 'Confirmar e ativar'));
        cod.focus();
      } catch (e) { mostrarErro(e.message); ev.target.disabled = false; }
    } }, 'Começar');
    botoes.append(comecar);
  }
  if (!dlg.open) dlg.showModal();
}

function mostrarCodigosRecuperacao(codigos, recarregar) {
  const corpo = $('d2-corpo');
  corpo.replaceChildren(
    el('h3', { text: 'Verificação ativada' }),
    el('p', { class: 'aviso', text: 'Guarde estes códigos de recuperação em local seguro. Cada um funciona uma vez, no lugar do código do aplicativo, se você perder o celular. Eles não serão mostrados de novo.' }),
    el('ul', { class: 'codigos' }, ...codigos.map((c) => el('li', { text: c }))),
    el('div', { class: 'dlg-acoes' },
      el('button', { class: 'btn', type: 'button', onclick: () => navigator.clipboard && navigator.clipboard.writeText(codigos.join('\n')) }, 'Copiar'),
      el('button', { class: 'btn primario', type: 'button', onclick: () => { if (recarregar) location.reload(); else $('dlg-2fa').close(); } }, 'Guardei os códigos')));
}
