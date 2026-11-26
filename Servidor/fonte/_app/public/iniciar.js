'use strict';
// Inicialização: identifica o usuário logado, monta as abas, troca de senha e logout.

(async function iniciar() {
  try {
    P.eu = await api('api/eu');
  } catch (e) { return; } // api() já redireciona ao login em caso de 401
  $('quem').textContent = `${P.eu.nome || P.eu.login} (${P.eu.papel === 'admin' ? 'administrador' : 'gestor'})`;
  for (const b of document.querySelectorAll('[data-admin]')) b.hidden = P.eu.papel !== 'admin';

  for (const b of document.querySelectorAll('#abas button')) b.addEventListener('click', () => mostrarAba(b.dataset.aba));
  window.addEventListener('hashchange', () => mostrarAba(location.hash.slice(1)));

  $('btn-sair').addEventListener('click', async () => {
    try { await api('api/logout', { metodo: 'POST', corpo: {} }); } catch (_) { /* sai mesmo assim */ }
    location.href = 'login';
  });

  const dlg = $('dlg-senha');
  $('btn-senha').addEventListener('click', () => { $('form-senha').reset(); $('sn-erro').hidden = true; dlg.showModal(); });
  $('sn-cancelar').addEventListener('click', () => dlg.close());
  $('form-senha').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    try {
      await api('api/senha', { metodo: 'POST', corpo: { atual: $('sn-atual').value, nova: $('sn-nova').value } });
      dlg.close();
      alert('Senha alterada.');
    } catch (e) { $('sn-erro').textContent = e.message; $('sn-erro').hidden = false; }
  });

  $('btn-2fa').addEventListener('click', () => abrir2fa(false));
  $('btn-2fa').textContent = P.eu.totp_ativo ? 'Verificação em 2 etapas: ativa' : 'Ativar verificação em 2 etapas';
  if (P.eu.precisa_configurar_2fa) { abrir2fa(true); return; } // servidor exige 2FA: so segue depois de ativar
  mostrarAba(location.hash.slice(1) || 'presenca');
  setInterval(() => { if (P.abaAtual === 'presenca' && !document.hidden) carregarPresenca(); }, 30000);
})();
