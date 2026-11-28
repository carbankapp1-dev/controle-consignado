/* Ligação da tela com o banco (Supabase).
   A tela chama srv('api_xxx', ...) como fazia no Google Script; aqui cada chamada vira uma função do banco.
   "f" (antigo id da planilha da loja) agora é o CNPJ da loja. */
window.API = (function () {
  const params = new URLSearchParams(location.search);
  const configurado = window.CFG && /^https:\/\//.test(CFG.SUPABASE_URL) && !/COLE_AQUI/.test(CFG.SUPABASE_KEY);
  const demo = params.has('demo') && window.DEMO;
  if (demo) return DEMO;

  const sb = configurado ? window.supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_KEY) : null;

  function hoje() { return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date()); }
  function erroMsg(e) {
    const m = String((e && (e.message || e.error_description)) || e || 'Erro desconhecido');
    if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return 'Sem conexão com o servidor. Verifique a internet e tente de novo.';
    if (/JWT expired|invalid JWT/i.test(m)) return 'Sua sessão expirou. Recarregue a página e entre de novo.';
    return m;
  }
  async function rpc(nome, p) {
    const { data, error } = await sb.rpc(nome, p || {});
    if (error) throw new Error(erroMsg(error));
    return data;
  }
  // linha do banco -> formato que a tela usa
  function pub(r) {
    return {
      f: r.cnpj, id: r.id, ordem: Number(r.ordem) || 0, placa: r.placa, modelo: r.modelo || '', chassi: r.chassi || '',
      valorVenda: Number(r.valor_venda) || 0, hodometro: r.hodometro || '', laudo: r.laudo || '',
      dtOferta: r.dt_oferta || '', loja: r.loja || '', cnpj: r.cnpj, dtColeta: r.dt_coleta || '', prazo: r.prazo || '',
      boletoStatus: r.boleto_status || '', boletoEnviadoEm: r.boleto_enviado_em || '', placaBoleto: r.placa_boleto || '',
      boletoVencimento: r.boleto_vencimento || '', docStatus: r.doc_status || '', docEnviadoEm: r.doc_enviado_em || '', rastreio: r.rastreio || '',
      boletoArquivos: [], lembretes: 0, lembretePausado: '', dados: {}
    };
  }
  const loja = l => ({ cnpj: l.cnpj, nome: l.nome, fileId: l.cnpj, total: Number(l.total) || 0, liberado: !!l.tem_senha, codigo: l.codigo || '', codigoEm: l.codigo_em || '',
    nDn: l.n_dn || '', gcm: l.gcm || '', coordenador: l.coordenador || '', gcmEmail: l.gcm_email || '' });

  async function veiculosDe(cnpjs) {
    const out = [];
    for (let de = 0; ; de += 1000) {
      let q = sb.from('veiculos').select('*').order('ordem').range(de, de + 999);
      if (cnpjs) q = q.in('cnpj', cnpjs);
      const { data, error } = await q;
      if (error) throw new Error(erroMsg(error));
      out.push(...data);
      if (data.length < 1000) break;
    }
    return out.map(pub);
  }

  const fns = {
    async api_listar(opts) {
      opts = opts || {};
      const quem = await rpc('cc_quem_sou');
      const lojas = (await rpc('cc_lojas')).map(loja);
      const out = { email: quem.email, role: quem.role, nome: quem.nome || '', hoje: hoje(), prazoDias: 88, produto: 'Consignado',
        destinatarios: {}, veiculos: [], bases: [], lojas: [] };
      let sel;
      if (quem.role !== 'loja') {   // administrador e coordenador escolhem a loja
        out.lojas = lojas;
        sel = opts.fileId === '*' ? lojas : opts.fileId ? lojas.filter(l => l.cnpj === opts.fileId) : [];
      } else sel = lojas;
      out.bases = sel.map(l => ({ fileId: l.cnpj, nome: l.nome, cnpj: l.cnpj, nDn: l.nDn, gcm: l.gcm, coordenador: l.coordenador, gcmEmail: l.gcmEmail, dados: {} }));
      if (sel.length) out.veiculos = await veiculosDe(quem.role !== 'loja' && opts.fileId === '*' ? null : sel.map(l => l.cnpj));
      return out;
    },
    api_importarLote: rows => rpc('cc_importar_lote', { p_rows: rows }),
    api_gerarCodigo: cnpj => rpc('cc_gerar_codigo', { p_cnpj: cnpj }),
    api_migrar: dados => rpc('cc_migrar', { p: dados }),
    api_salvarColeta: async (f, id, dt) => pub(await rpc('cc_salvar_coleta', { p_cnpj: f, p_id: id, p_dt: dt || '' })),
    api_salvarPrazo: async (f, id, dt) => pub(await rpc('cc_salvar_prazo', { p_cnpj: f, p_id: id, p_dt: dt || '' })),
    api_coordListar: async () => (await rpc('cc_coordenadores_listar')).map(c => ({ nome: c.nome, email: c.email || '', lojas: Number(c.lojas) || 0, temSenha: !!c.tem_senha, codigo: c.codigo || '', codigoEm: c.codigo_em || '' })),
    api_coordEmail: (nome, email) => rpc('cc_coord_salvar_email', { p_nome: nome, p_email: email }),
    api_coordCodigo: nome => rpc('cc_coord_gerar_codigo', { p_nome: nome }),
    api_gcmListar: async () => (await rpc('cc_gcms_listar')).map(c => ({ nome: c.nome, email: c.email || '', lojas: Number(c.lojas) || 0, temSenha: !!c.tem_senha, codigo: c.codigo || '', codigoEm: c.codigo_em || '' })),
    api_gcmEmail: (nome, email) => rpc('cc_gcm_salvar_email', { p_nome: nome, p_email: email }),
    api_gcmCodigo: nome => rpc('cc_gcm_gerar_codigo', { p_nome: nome }),
    api_salvarValor: async (f, id, valor) => pub(await rpc('cc_salvar_valor', { p_cnpj: f, p_id: id, p_valor: valor })),
    api_incluirVeiculo: async (f, dados) => pub(await rpc('cc_incluir_veiculo', { p_cnpj: f, p_dados: dados })),
    api_iniciarBoleto: async (f, id, placa) => pub(await rpc('cc_iniciar_boleto', { p_cnpj: f, p_id: id, p_placa: placa })),
    api_boletoChegou: async (f, id, venc) => pub(await rpc('cc_boleto_chegou', { p_cnpj: f, p_id: id, p_venc: venc })),
    api_salvarVencimento: async (f, id, venc) => pub(await rpc('cc_salvar_vencimento', { p_cnpj: f, p_id: id, p_venc: venc })),
    api_desfazerBoleto: async (f, id) => pub(await rpc('cc_desfazer_boleto', { p_cnpj: f, p_id: id })),
    api_salvarEnviadoEm: async (f, id, data) => pub(await rpc('cc_salvar_enviado_em', { p_cnpj: f, p_id: id, p_data: data || '' })),
    api_salvarRastreio: async (f, id, cod) => pub(await rpc('cc_salvar_rastreio', { p_cnpj: f, p_id: id, p_codigo: cod || '' })),
    api_finalizar: (f, id) => rpc('cc_finalizar', { p_cnpj: f, p_id: id }),
    api_excluir: (f, id) => rpc('cc_excluir', { p_cnpj: f, p_id: id })
  };

  // usuário digitado -> e-mail interno (CNPJ) ou e-mail do administrador
  const DOMINIO = 'lojas.consignado.app';
  const soNum = v => String(v || '').replace(/\D/g, '');
  function emailDe(usuario) {
    const u = String(usuario || '').trim().toLowerCase();
    if (u.includes('@')) return u;
    const c = soNum(u);
    if (c.length !== 14) throw new Error('Digite o CNPJ com 14 números (sem ponto nem traço).');
    return c + '@' + DOMINIO;
  }
  const escH = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  const campo = (id, rot, tipo, extra) => '<div class="f"><label for="' + id + '">' + rot + '</label><input id="' + id + '" type="' + tipo + '" ' + (extra || '') + '></div>';
  const tela = html => {
    document.getElementById('tabs').innerHTML = '';
    document.getElementById('topoDir').innerHTML = '';
    document.getElementById('main').innerHTML = '<div class="login">' + html + '</div>';
  };
  const avisoHTML = (msg, ok) => msg ? '<div class="info" style="margin-bottom:14px;text-align:left' +
    (ok ? '' : ';background:var(--perigo-bg);border-color:var(--perigo);color:var(--perigo)') + '">' + escH(msg) + '</div>' : '';
  async function trava(btn, fn) {
    const t = btn.textContent; btn.disabled = true; btn.textContent = 'Aguarde…';
    try { await fn(); } finally { btn.disabled = false; btn.textContent = t; }
  }

  function telaLogin(aviso, ok, usuario) {
    tela('<h2>Entrar</h2><p>Lojas: usuário é o <b>CNPJ</b> (só números). Coordenadores e GCMs: o <b>e-mail</b>.</p>' + avisoHTML(aviso, ok) +
      '<form id="fLogin">' + campo('lgUser', 'Usuário', 'text', 'autocomplete="username" value="' + escH(usuario || '') + '"') +
      campo('lgSenha', 'Senha', 'password', 'autocomplete="current-password"') +
      '<button class="btn pri" id="lgBtn" type="submit">Entrar</button></form>' +
      '<button class="lnk2" id="lgPrim" type="button">Primeiro acesso / esqueci a senha</button>');
    document.getElementById(usuario ? 'lgSenha' : 'lgUser').focus();
    document.getElementById('lgPrim').onclick = () => telaPrimeiro('', document.getElementById('lgUser').value);
    document.getElementById('fLogin').onsubmit = ev => {
      ev.preventDefault();
      const u = document.getElementById('lgUser').value, p = document.getElementById('lgSenha').value;
      trava(document.getElementById('lgBtn'), async () => {
        let email;
        try { email = emailDe(u); } catch (e) { return telaLogin(e.message, false, u); }
        if (!p) return telaLogin('Digite a senha.', false, u);
        const { error } = await sb.auth.signInWithPassword({ email, password: p });
        if (error) return telaLogin(/invalid login|credentials/i.test(error.message) ? 'Usuário ou senha incorretos.' : erroMsg(error), false, u);
        location.reload();
      });
    };
  }

  function telaPrimeiro(aviso, usuario) {
    const u0 = String(usuario || '').includes('@') ? String(usuario).trim() : soNum(usuario);
    tela('<h2>Criar senha</h2><p>Use o <b>código de 6 números</b> que o administrador passou para você.</p>' + avisoHTML(aviso) +
      '<form id="fPrim">' + campo('pcUser', 'Usuário (CNPJ da loja ou e-mail)', 'text', 'autocomplete="username" value="' + escH(u0) + '"') +
      campo('pcCod', 'Código de acesso', 'text', 'inputmode="numeric" maxlength="6" autocomplete="one-time-code"') +
      campo('pcS1', 'Nova senha (mínimo 6 caracteres)', 'password', 'autocomplete="new-password"') +
      campo('pcS2', 'Repita a nova senha', 'password', 'autocomplete="new-password"') +
      '<button class="btn pri" id="pcBtn" type="submit">Criar senha e entrar</button></form>' +
      '<button class="lnk2" id="pcVolta" type="button">Voltar para o login</button>');
    document.getElementById('pcVolta').onclick = () => telaLogin('', false, document.getElementById('pcUser').value);
    document.getElementById('fPrim').onsubmit = ev => {
      ev.preventDefault();
      const v = id => document.getElementById(id).value;
      const bruto = v('pcUser').trim(), ehEmail = bruto.includes('@');
      const cnpj = ehEmail ? bruto.toLowerCase() : soNum(bruto), cod = soNum(v('pcCod')), s1 = v('pcS1'), s2 = v('pcS2');
      if (!ehEmail && cnpj.length !== 14) return telaPrimeiro('Digite o CNPJ com 14 números (ou o e-mail, se for coordenador ou GCM).', cnpj);
      if (cod.length !== 6) return telaPrimeiro('O código tem 6 números.', cnpj);
      if (s1.length < 6) return telaPrimeiro('A senha precisa ter pelo menos 6 caracteres.', cnpj);
      if (s1 !== s2) return telaPrimeiro('As duas senhas não são iguais.', cnpj);
      trava(document.getElementById('pcBtn'), async () => {
        let r;
        try { r = await rpc('cc_criar_senha', { p_cnpj: cnpj, p_codigo: cod, p_senha: s1 }); }
        catch (e) { return telaPrimeiro(e.message, cnpj); }
        if (!r || !r.ok) return telaPrimeiro((r && r.erro) || 'Não foi possível criar a senha.', cnpj);
        const { error } = await sb.auth.signInWithPassword({ email: r.email || (cnpj + '@' + DOMINIO), password: s1 });
        if (error) return telaLogin('Senha criada! Agora entre com o seu usuário e a senha nova.', true, cnpj);
        location.reload();
      });
    };
  }

  return {
    demo: false,
    call(fn, ...args) {
      if (!fns[fn]) return Promise.reject(new Error('Função não disponível: ' + fn));
      try { return Promise.resolve(fns[fn](...args)); } catch (e) { return Promise.reject(e); }
    },
    // devolve os dados da tela inicial, ou null quando mostrou a tela de login
    async iniciar() {
      if (!sb) {
        document.getElementById('main').innerHTML = '<div class="vazio"><h3>Falta configurar</h3><p>Preencha o arquivo <b>js/config.js</b> com os dados do Supabase.<br>Para só ver como fica, abra com <a href="?demo=1">?demo=1</a> no final do endereço.</p></div>';
        return null;
      }
      const { data } = await sb.auth.getSession();
      if (!data.session) { telaLogin(''); return null; }
      return fns.api_listar({ fileId: '*' });   // gestores: todas as lojas (para a loja não muda nada)
    },
    async trocarSenha(nova) {
      const { error } = await sb.auth.updateUser({ password: nova });
      if (error) throw new Error(/different from the old/i.test(error.message) ? 'A senha nova precisa ser diferente da atual.' : erroMsg(error));
    },
    async sair() {
      if (sb) await sb.auth.signOut();
      location.href = location.origin + location.pathname;
    }
  };
})();
