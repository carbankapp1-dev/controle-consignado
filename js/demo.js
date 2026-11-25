/* Modo demonstração: abra o site com ?demo=1 (administrador) ou ?demo=loja (visão da loja).
   Tudo fica só na memória do navegador e some ao recarregar. Não usa o banco. */
window.DEMO = (function () {
  const loja = new URLSearchParams(location.search).get('demo') === 'loja';
  const hojeISO = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date());
  const addDias = (iso, n) => { const p = iso.split('-'); const d = new Date(Date.UTC(+p[0], +p[1] - 1, +p[2] + n)); return d.toISOString().slice(0, 10); };
  const diasAtras = n => addDias(hojeISO(), -n);
  const lojas = [
    { cnpj: '11222333000181', nome: 'AUTO CENTER DEMO', senha: true, codigo: '', codigoEm: '' },
    { cnpj: '44555666000172', nome: 'VEICULOS EXEMPLO', senha: false, codigo: '', codigoEm: '' }
  ];
  let ordem = 0;
  const V = [];
  function novo(cnpj, placa, modelo, valor, dtOferta, extra) {
    const l = lojas.find(x => x.cnpj === cnpj);
    V.push(Object.assign({ f: cnpj, cnpj, id: placa + '_' + dtOferta, ordem: ++ordem, placa, modelo, valorVenda: valor, hodometro: '45000',
      laudo: 'https://example.com/laudo', dtOferta, loja: l.nome, dtColeta: '', prazo: '', boletoStatus: '', boletoEnviadoEm: '',
      placaBoleto: '', docStatus: '', docEnviadoEm: '', rastreio: '', boletoArquivos: [], lembretes: 0, lembretePausado: '', dados: {} }, extra || {}));
  }
  novo('11222333000181', 'ABC1D23', 'POLO TRACK 1.0', 72900, diasAtras(10));
  novo('11222333000181', 'FGH4J56', 'T-CROSS 200 TSI', 118500, diasAtras(30), { dtColeta: diasAtras(80), prazo: addDias(diasAtras(80), 88) });
  novo('11222333000181', 'KLM7N89', 'NIVUS HIGHLINE', 129900, diasAtras(40), { dtColeta: diasAtras(60), prazo: addDias(diasAtras(60), 88),
    boletoStatus: 'solicitado', boletoEnviadoEm: new Date(Date.now() - 80 * 3600e3).toISOString(), placaBoleto: 'KLM7N89' });
  novo('11222333000181', 'PQR0S12', 'VIRTUS EXCLUSIVE', 109000, diasAtras(50), { dtColeta: diasAtras(50), prazo: addDias(diasAtras(50), 88),
    boletoStatus: 'recebido', boletoEnviadoEm: new Date(Date.now() - 200 * 3600e3).toISOString(), placaBoleto: 'PQR0S12' });
  novo('11222333000181', 'TUV3W45', 'SAVEIRO CROSS', 98000, diasAtras(60), { dtColeta: diasAtras(55), prazo: addDias(diasAtras(55), 88),
    boletoStatus: 'recebido', boletoEnviadoEm: new Date(Date.now() - 400 * 3600e3).toISOString(), placaBoleto: 'TUV3W45',
    docStatus: 'enviado', docEnviadoEm: new Date(Date.now() - 5 * 864e5).toISOString(), rastreio: 'AA123456789BR' });
  novo('44555666000172', 'XYZ6A78', 'GOL 1.0', 52000, diasAtras(5));
  const fim = {};

  const espera = x => new Promise(r => setTimeout(() => r(JSON.parse(JSON.stringify(x))), 250));
  const pega = (f, id) => { const v = V.find(x => x.f === f && x.id === id); if (!v) throw new Error('Veículo não encontrado.'); return v; };
  const L = l => ({ cnpj: l.cnpj, nome: l.nome, fileId: l.cnpj, total: V.filter(v => v.cnpj === l.cnpj).length, liberado: l.senha, codigo: l.codigo, codigoEm: l.codigoEm });
  const placaN = p => String(p || '').toUpperCase().replace(/[^A-Z0-9]/g, '');

  const fns = {
    api_listar(opts) {
      opts = opts || {};
      const out = { email: loja ? '11222333000181@lojas.consignado.app' : 'admin@demo', role: loja ? 'loja' : 'admin', hoje: hojeISO(), prazoDias: 88,
        produto: 'Consignado', destinatarios: {}, veiculos: [], bases: [], lojas: [] };
      let sel;
      if (loja) sel = lojas.filter(l => l.cnpj === '11222333000181');
      else { out.lojas = lojas.map(L).sort((a, b) => a.nome.localeCompare(b.nome)); sel = opts.fileId === '*' ? lojas : lojas.filter(l => l.cnpj === opts.fileId); }
      out.bases = sel.map(l => ({ fileId: l.cnpj, nome: l.nome, cnpj: l.cnpj, dados: {} }));
      out.veiculos = V.filter(v => sel.some(l => l.cnpj === v.cnpj));
      return out;
    },
    api_importarLote(rows) {
      let novos = 0, atualizados = 0, lojasNovas = 0, ignorados = 0;
      rows.forEach(r => {
        const cnpj = String(r.cnpj).replace(/\D/g, '').padStart(14, '0');
        if (!lojas.find(l => l.cnpj === cnpj)) { lojas.push({ cnpj, nome: r.loja, senha: false, codigo: '', codigoEm: '' }); lojasNovas++; }
        const id = r.placa + '_' + r.dtOferta;
        if (fim[cnpj + id]) { ignorados++; return; }
        const ex = V.find(v => v.cnpj === cnpj && v.id === id);
        if (ex) { if (ex.modelo !== r.modelo) { ex.modelo = r.modelo; atualizados++; } }
        else { novo(cnpj, r.placa, r.modelo, r.valorVenda, r.dtOferta, { hodometro: r.hodometro, laudo: r.laudo }); novos++; }
      });
      return { novos, atualizados, lojasNovas, descartados: 0, ignorados };
    },
    api_gerarCodigo(cnpj) { const l = lojas.find(x => x.cnpj === cnpj); l.codigo = String(Math.floor(Math.random() * 1e6)).padStart(6, '0'); l.codigoEm = new Date().toISOString(); return { cnpj, codigo: l.codigo, codigo_em: l.codigoEm }; },
    api_migrar(p) {
      let nl = 0, nv = 0;
      (p.lojas || []).forEach(x => { if (!lojas.find(l => l.cnpj === x.cnpj)) { lojas.push({ cnpj: x.cnpj, nome: x.nome, senha: false, codigo: '', codigoEm: '' }); nl++; } });
      (p.veiculos || []).forEach(x => { const i = V.findIndex(v => v.cnpj === x.cnpj && v.id === x.id); const o = Object.assign({ f: x.cnpj, ordem: ++ordem, boletoArquivos: [], lembretes: 0, lembretePausado: '', dados: {} }, x, { valorVenda: Number(x.valorVenda) || 0 }); if (i >= 0) V[i] = o; else V.push(o); nv++; });
      return { lojas: nl, veiculos: nv, finalizados: (p.finalizados || []).length, descartados: 0 };
    },
    api_salvarColeta(f, id, dt) { const v = pega(f, id); v.dtColeta = dt || ''; v.prazo = dt ? addDias(dt, 88) : ''; return v; },
    api_salvarValor(f, id, n) { const v = pega(f, id); v.valorVenda = n; return v; },
    api_incluirVeiculo(f, d) {
      const placa = placaN(d.placa);
      if (V.some(v => v.f === f && v.id === placa + '_' + d.dtOferta)) throw new Error('Este veículo (placa e data da oferta) já está na lista.');
      novo(f, placa, d.modelo, d.valorVenda, d.dtOferta, { hodometro: d.hodometro || '', laudo: d.laudo || '' });
      return V[V.length - 1];
    },
    api_iniciarBoleto(f, id, placa) { const v = pega(f, id); Object.assign(v, { boletoStatus: 'solicitado', boletoEnviadoEm: new Date().toISOString(), placaBoleto: placaN(placa) }); return v; },
    api_boletoChegou(f, id) { const v = pega(f, id); if (v.boletoStatus === 'solicitado') v.boletoStatus = 'recebido'; return v; },
    api_desfazerBoleto(f, id) { const v = pega(f, id); if (v.docStatus) throw new Error('Apague primeiro a data de envio do boleto.'); Object.assign(v, { boletoStatus: '', boletoEnviadoEm: '', placaBoleto: '' }); return v; },
    api_salvarEnviadoEm(f, id, data) { const v = pega(f, id); v.docEnviadoEm = data ? new Date(data + 'T12:00:00-03:00').toISOString() : ''; v.docStatus = data ? 'enviado' : ''; return v; },
    api_salvarRastreio(f, id, c) {
      c = String(c || '').toUpperCase().replace(/\s/g, '');
      if (c && !/^[A-Z]{2}\d{9}[A-Z]{2}$/.test(c)) throw new Error('Código inválido. Formato: AA123456789BR');
      const v = pega(f, id); v.rastreio = c; return v;
    },
    api_finalizar(f, id) { const v = pega(f, id); if (v.docStatus !== 'enviado') throw new Error('Preencha antes a data em que o boleto foi enviado.'); fim[f + id] = 1; V.splice(V.indexOf(v), 1); return { ok: true }; },
    api_excluir(f, id) { const v = pega(f, id); fim[f + id] = 1; V.splice(V.indexOf(v), 1); return { ok: true }; }
  };
  return {
    demo: true,
    call(fn, ...args) { try { if (!fns[fn]) throw new Error('Função não disponível: ' + fn); return espera(fns[fn](...args)); } catch (e) { return Promise.reject(e); } },
    iniciar() { return espera(fns.api_listar({})); },
    trocarSenha() { return espera(true); },
    sair() { location.href = location.pathname + (loja ? '?demo=1' : '?demo=loja'); }
  };
})();
