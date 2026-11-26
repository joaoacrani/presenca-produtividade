'use strict';
const form = document.getElementById('form');
const erro = document.getElementById('erro');
const botao = document.getElementById('entrar');
const bloco2fa = document.getElementById('bloco-2fa');
const campoCodigo = document.getElementById('codigo');

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  erro.hidden = true;
  botao.disabled = true;
  try {
    const corpo = { login: document.getElementById('login').value, senha: document.getElementById('senha').value };
    if (!bloco2fa.hidden) corpo.codigo = campoCodigo.value;
    const r = await fetch('api/login', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(corpo),
    });
    const j = await r.json().catch(() => ({}));
    if (r.ok && j.precisa_2fa) {            // senha certa: falta o segundo fator
      bloco2fa.hidden = false;
      campoCodigo.focus();
      return;
    }
    if (r.ok) { location.href = './'; return; }
    erro.textContent = j.erro || 'Não foi possível entrar.';
    erro.hidden = false;
    if (!bloco2fa.hidden) { campoCodigo.value = ''; campoCodigo.focus(); } else document.getElementById('senha').select();
  } catch (_) {
    erro.textContent = 'Sem conexão com o servidor.';
    erro.hidden = false;
  } finally {
    botao.disabled = false;
  }
});
