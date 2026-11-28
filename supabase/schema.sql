-- =====================================================================
-- Controle Consignado — banco de dados (Supabase)
-- Rode este arquivo inteiro em: Supabase > SQL Editor > New query > Run
-- Pode rodar de novo sem perder dados (só recria as funções).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- tabelas ----------
create table if not exists cc_admins (
  email text primary key                         -- e-mail (login) de quem é administrador
);

create table if not exists lojas (
  cnpj              text primary key,            -- 14 dígitos, sem pontuação (é o usuário da loja)
  nome              text not null,
  acesso_codigo     text not null default '',    -- código de primeiro acesso / nova senha (6 números)
  acesso_codigo_em  timestamptz,
  acesso_tentativas int not null default 0,
  senha_criada_em   timestamptz,
  criado_em         timestamptz not null default now()
);

create table if not exists veiculos (
  cnpj             text not null references lojas(cnpj) on delete cascade,
  id               text not null,                -- PLACA_AAAA-MM-DD (placa + data da oferta)
  ordem            bigint generated always as identity,
  placa            text not null,
  modelo           text not null default '',
  valor_venda      numeric(12,2) not null default 0,
  hodometro        text not null default '',
  laudo            text not null default '',
  dt_oferta        date not null,
  loja             text not null default '',
  dt_coleta        date,
  prazo            date,                          -- dt_coleta + 88 dias
  boleto_status    text not null default '',      -- '' | solicitado | recebido | pago (versão antiga)
  boleto_enviado_em timestamptz,                  -- quando o formulário foi acionado
  placa_boleto     text not null default '',
  doc_status       text not null default '',      -- '' | enviado
  doc_enviado_em   timestamptz,                   -- data em que o boleto foi enviado
  rastreio         text not null default '',
  atualizado_em    timestamptz not null default now(),
  primary key (cnpj, id)
);

-- veículos finalizados ou excluídos: não voltam numa nova importação
create table if not exists finalizados (
  cnpj          text not null,
  id            text not null,
  motivo        text not null default '',
  finalizado_em timestamptz not null default now(),
  primary key (cnpj, id)
);

-- ---------- colunas da planilha nova (nov/2026) ----------
alter table lojas    add column if not exists n_dn        text not null default '';   -- Nº DN
alter table lojas    add column if not exists gcm         text not null default '';
alter table lojas    add column if not exists coordenador text not null default '';   -- nome, em MAIÚSCULAS
alter table veiculos add column if not exists chassi      text not null default '';

-- coordenadores: veem e alteram só as lojas em que o nome deles está na coluna COORDENADOR
create table if not exists cc_coordenadores (
  nome              text primary key,            -- igual à planilha, em MAIÚSCULAS
  email             text not null default '',    -- usuário de login
  acesso_codigo     text not null default '',
  acesso_codigo_em  timestamptz,
  acesso_tentativas int not null default 0,
  senha_criada_em   timestamptz
);
create unique index if not exists cc_coord_email_idx on cc_coordenadores (lower(email)) where email <> '';
alter table cc_coordenadores enable row level security;

-- ---------- quem está usando ----------
-- a loja entra com o CNPJ; por dentro vira o e-mail 12345678000199@lojas.consignado.app (nunca recebe mensagens)
create or replace function cc_dominio() returns text language sql immutable as $$ select 'lojas.consignado.app' $$;

create or replace function cc_meu_email() returns text
language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''))
$$;

create or replace function cc_eh_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select cc_meu_email() <> '' and exists (select 1 from cc_admins where lower(email) = cc_meu_email())
$$;

-- nome do coordenador logado ('' se não for coordenador)
create or replace function cc_coord_nome() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select nome from cc_coordenadores where cc_meu_email() <> '' and lower(email) = cc_meu_email()), '')
$$;

-- administrador ou coordenador (quem gerencia lojas)
create or replace function cc_eh_gestor() returns boolean
language sql stable security definer set search_path = public as $$
  select cc_eh_admin() or cc_coord_nome() <> ''
$$;

create or replace function cc_pode(p_cnpj text) returns boolean
language sql stable security definer set search_path = public as $$
  select cc_eh_admin()
      or (cc_meu_email() <> '' and cc_meu_email() = p_cnpj || '@' || cc_dominio())
      or (cc_coord_nome() <> '' and exists (select 1 from lojas where cnpj = p_cnpj and coordenador = cc_coord_nome()))
$$;

-- ---------- segurança: leitura direta só do que é seu; gravação só pelas funções ----------
alter table cc_admins   enable row level security;
alter table lojas       enable row level security;
alter table veiculos    enable row level security;
alter table finalizados enable row level security;

drop policy if exists lojas_ler on lojas;
drop policy if exists veiculos_ler on veiculos;
create policy veiculos_ler on veiculos for select using (cc_pode(cnpj));

-- ---------- utilitários internos ----------
create or replace function cc_exige_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not cc_eh_admin() then raise exception 'Somente o administrador pode fazer isso.'; end if;
end $$;

create or replace function cc_pega(p_cnpj text, p_id text) returns veiculos
language plpgsql security definer set search_path = public as $$
declare v veiculos;
begin
  if not cc_pode(p_cnpj) then raise exception 'Sem acesso a esta loja.'; end if;
  select * into v from veiculos where cnpj = p_cnpj and id = p_id for update;
  if not found then raise exception 'Veículo não encontrado.'; end if;
  return v;
end $$;

-- ---------- tela inicial ----------
create or replace function cc_quem_sou() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('email', cc_meu_email(),
    'role', case when cc_eh_admin() then 'admin' when cc_coord_nome() <> '' then 'coord' else 'loja' end,
    'nome', cc_coord_nome())
$$;

-- lojas visíveis para quem está usando (o código de acesso só aparece para administrador/coordenador)
drop function if exists cc_lojas();
create or replace function cc_lojas()
returns table (cnpj text, nome text, total bigint, tem_senha boolean, codigo text, codigo_em timestamptz,
               n_dn text, gcm text, coordenador text)
language sql stable security definer set search_path = public as $$
  select l.cnpj, l.nome, (select count(*) from veiculos v where v.cnpj = l.cnpj),
         l.senha_criada_em is not null,
         case when cc_eh_gestor() then l.acesso_codigo else '' end,
         case when cc_eh_gestor() then l.acesso_codigo_em end,
         l.n_dn, l.gcm, l.coordenador
  from lojas l
  where cc_pode(l.cnpj)
  order by l.nome
$$;

-- ---------- acesso das lojas: usuário (CNPJ) e senha ----------
-- administrador gera um código de 6 números (vale 7 dias) para a loja criar ou trocar a senha
create or replace function cc_gerar_codigo(p_cnpj text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare c text := lpad((floor(random() * 1000000))::int::text, 6, '0'); l lojas;
begin
  if not cc_eh_gestor() or not cc_pode(p_cnpj) then raise exception 'Somente o administrador ou o coordenador da loja pode fazer isso.'; end if;
  update lojas set acesso_codigo = c, acesso_codigo_em = now(), acesso_tentativas = 0
  where cnpj = p_cnpj returning * into l;
  if not found then raise exception 'Loja não encontrada.'; end if;
  return json_build_object('cnpj', l.cnpj, 'codigo', c, 'codigo_em', l.acesso_codigo_em);
end $$;

-- cria (ou troca a senha de) um usuário de login direto no Supabase Auth
create or replace function cc_grava_usuario(v_email text, p_senha text, p_meta jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid;
begin
  select id into uid from auth.users where lower(email) = lower(v_email);
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change,
      email_change_token_current, reauthentication_token, phone_change, phone_change_token)
    values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', lower(v_email),
      crypt(p_senha, gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb,
      coalesce(p_meta, '{}'::jsonb), now(), now(), '', '', '', '', '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text,
      jsonb_build_object('sub', uid::text, 'email', lower(v_email), 'email_verified', true), 'email', now(), now(), now());
  else
    update auth.users set encrypted_password = crypt(p_senha, gen_salt('bf')), updated_at = now() where id = uid;
  end if;
end $$;

-- confere código de acesso (comum a lojas e coordenadores); devolve '' se ok ou a mensagem de erro
create or replace function cc_confere_codigo(p_cod text, p_cod_em timestamptz, p_tent int, p_digitado text) returns text
language sql immutable as $$
  select case
    when coalesce(p_cod, '') = '' then 'SEM'
    when p_tent >= 5 then 'Código bloqueado por excesso de tentativas. Peça um código novo ao administrador.'
    when p_cod_em < now() - interval '7 days' then 'Este código venceu (vale 7 dias). Peça um código novo ao administrador.'
    when p_cod <> trim(coalesce(p_digitado, '')) then 'ERRADO'
    else '' end
$$;

-- cria a senha com usuário (CNPJ da loja ou e-mail do coordenador) + código. Pode ser chamada sem login.
create or replace function cc_criar_senha(p_cnpj text, p_codigo text, p_senha text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_user text := lower(trim(coalesce(p_cnpj, '')));
  v_cnpj text := regexp_replace(coalesce(p_cnpj, ''), '\D', '', 'g');
  v_email text; l lojas; c cc_coordenadores; r text;
begin
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;

  -- coordenador: usuário é o e-mail
  if position('@' in v_user) > 0 then
    if exists (select 1 from cc_admins where lower(email) = v_user) then
      raise exception 'Este e-mail é de administrador: a senha dele é trocada no próprio site, em Trocar senha.';
    end if;
    select * into c from cc_coordenadores where lower(email) = v_user for update;
    r := case when found then cc_confere_codigo(c.acesso_codigo, c.acesso_codigo_em, c.acesso_tentativas, p_codigo) else 'SEM' end;
    if r = 'SEM' then raise exception 'Não há código de acesso para este usuário. Peça um código ao administrador.'; end if;
    if r = 'ERRADO' then
      update cc_coordenadores set acesso_tentativas = acesso_tentativas + 1 where nome = c.nome;
      return json_build_object('ok', false, 'erro', 'Código incorreto. Confira com o administrador.');
    end if;
    if r <> '' then raise exception '%', r; end if;
    perform cc_grava_usuario(v_user, p_senha, jsonb_build_object('coordenador', c.nome));
    update cc_coordenadores set acesso_codigo = '', acesso_codigo_em = null, acesso_tentativas = 0, senha_criada_em = now()
    where nome = c.nome;
    return json_build_object('ok', true, 'email', v_user);
  end if;

  -- loja: usuário é o CNPJ
  if length(v_cnpj) <> 14 then raise exception 'Informe o CNPJ com 14 números.'; end if;
  select * into l from lojas where cnpj = v_cnpj for update;
  r := case when found then cc_confere_codigo(l.acesso_codigo, l.acesso_codigo_em, l.acesso_tentativas, p_codigo) else 'SEM' end;
  if r = 'SEM' then raise exception 'Não há código de acesso para este CNPJ. Peça um código ao administrador.'; end if;
  if r = 'ERRADO' then
    update lojas set acesso_tentativas = acesso_tentativas + 1 where cnpj = v_cnpj;
    return json_build_object('ok', false, 'erro', 'Código incorreto. Confira com o administrador.');
  end if;
  if r <> '' then raise exception '%', r; end if;

  v_email := v_cnpj || '@' || cc_dominio();
  perform cc_grava_usuario(v_email, p_senha, jsonb_build_object('cnpj', v_cnpj));
  update lojas set acesso_codigo = '', acesso_codigo_em = null, acesso_tentativas = 0, senha_criada_em = now()
  where cnpj = v_cnpj;
  return json_build_object('ok', true, 'email', v_email);
end $$;

-- ---------- administrador: coordenadores ----------
-- lista os coordenadores que aparecem nas lojas (coluna COORDENADOR) e os já cadastrados
create or replace function cc_coordenadores_listar()
returns table (nome text, email text, lojas bigint, tem_senha boolean, codigo text, codigo_em timestamptz)
language sql stable security definer set search_path = public as $$
  with nomes as (
    select coordenador as nome from lojas where coordenador <> ''
    union select nome from cc_coordenadores)
  select n.nome, coalesce(c.email, ''), (select count(*) from lojas l where l.coordenador = n.nome),
         c.senha_criada_em is not null, coalesce(c.acesso_codigo, ''), c.acesso_codigo_em
  from nomes n left join cc_coordenadores c on c.nome = n.nome
  where cc_eh_admin()
  order by n.nome
$$;

create or replace function cc_coord_salvar_email(p_nome text, p_email text) returns json
language plpgsql security definer set search_path = public as $$
declare v_nome text := upper(trim(coalesce(p_nome, ''))); v_email text := lower(trim(coalesce(p_email, '')));
begin
  perform cc_exige_admin();
  if v_nome = '' then raise exception 'Informe o nome do coordenador.'; end if;
  if v_email <> '' and v_email !~ '^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$' then raise exception 'E-mail inválido.'; end if;
  if v_email <> '' and exists (select 1 from cc_admins where lower(email) = v_email) then
    raise exception 'Este e-mail já é de administrador.';
  end if;
  if v_email <> '' and exists (select 1 from cc_coordenadores where lower(email) = v_email and nome <> v_nome) then
    raise exception 'Este e-mail já está em outro coordenador.';
  end if;
  insert into cc_coordenadores (nome, email) values (v_nome, v_email)
  on conflict (nome) do update set email = excluded.email;
  return json_build_object('nome', v_nome, 'email', v_email);
end $$;

create or replace function cc_coord_gerar_codigo(p_nome text) returns json
language plpgsql security definer set search_path = public as $$
declare c text := lpad((floor(random() * 1000000))::int::text, 6, '0'); r cc_coordenadores;
begin
  perform cc_exige_admin();
  update cc_coordenadores set acesso_codigo = c, acesso_codigo_em = now(), acesso_tentativas = 0
  where nome = upper(trim(p_nome)) and email <> '' returning * into r;
  if not found then raise exception 'Cadastre antes o e-mail (usuário) do coordenador.'; end if;
  return json_build_object('nome', r.nome, 'codigo', c, 'codigo_em', r.acesso_codigo_em);
end $$;

-- ---------- administrador: importação da planilha ----------
-- rows: [{placa, modelo, chassi, valorBoleto, dtOferta, dtLiberacao, dtBoleto (AAAA-MM-DD), loja, cnpj, nDn, coordenador, gcm}]
-- A planilha manda: veículo que já existe tem modelo, chassi, loja, Valor do Boleto, Data da Liberação e Data Boleto
-- atualizados pelo que vier preenchido nela (o andamento — boleto, envio, rastreio — nunca é tocado).
-- Dados da loja (nome, Nº DN, GCM, coordenador) também ficam iguais à planilha.
create or replace function cc_importar_lote(p_rows jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  r record; v_placa text; v_cnpj text; v_nome text; v_id text; ex veiculos; v_lib date; v_bol date; v_nova boolean; v_tem boolean;
  iso text := '^\d{4}-\d{2}-\d{2}$';
  n_novos int := 0; n_atual int := 0; n_lojas int := 0; n_desc int := 0; n_ign int := 0; n_exist int := 0;
begin
  perform cc_exige_admin();
  for r in select * from jsonb_to_recordset(coalesce(p_rows, '[]'::jsonb))
      as x(placa text, modelo text, chassi text, "valorBoleto" numeric, "dtOferta" text, "dtLiberacao" text, "dtBoleto" text,
           loja text, cnpj text, "nDn" text, coordenador text, gcm text)
  loop
    v_placa := upper(regexp_replace(coalesce(r.placa, ''), '[^A-Za-z0-9]', '', 'g'));
    v_cnpj  := lpad(regexp_replace(coalesce(r.cnpj, ''), '\D', '', 'g'), 14, '0');
    v_nome  := trim(coalesce(r.loja, ''));
    if v_placa = '' or v_nome = '' or length(v_cnpj) <> 14 or v_cnpj = '00000000000000'
       or coalesce(r."dtOferta", '') !~ iso then
      n_desc := n_desc + 1; continue;
    end if;
    v_id  := v_placa || '_' || r."dtOferta";
    v_lib := case when r."dtLiberacao" ~ iso then r."dtLiberacao"::date end;
    v_bol := case when r."dtBoleto" ~ iso then r."dtBoleto"::date end;

    insert into lojas (cnpj, nome, n_dn, gcm, coordenador)
    values (v_cnpj, v_nome, trim(coalesce(r."nDn", '')), upper(trim(coalesce(r.gcm, ''))), upper(trim(coalesce(r.coordenador, ''))))
    on conflict (cnpj) do update set nome = excluded.nome,
      n_dn = case when excluded.n_dn <> '' then excluded.n_dn else lojas.n_dn end,
      gcm = case when excluded.gcm <> '' then excluded.gcm else lojas.gcm end,
      coordenador = case when excluded.coordenador <> '' then excluded.coordenador else lojas.coordenador end
    returning (xmax = 0) into v_nova;   -- true quando a loja é nova
    if v_nova then n_lojas := n_lojas + 1; end if;

    -- o mesmo carro é identificado pela PLACA dentro da loja (a data da oferta pode variar entre planilhas)
    select * into ex from veiculos where cnpj = v_cnpj and placa = v_placa order by ordem desc limit 1;
    v_tem := found;
    if v_tem then
      n_exist := n_exist + 1;
    elsif exists (select 1 from finalizados where cnpj = v_cnpj and (id = v_id or split_part(id, '_', 1) = v_placa)) then
      n_ign := n_ign + 1; continue;
    end if;
    if v_tem then
      if ex.modelo is distinct from trim(coalesce(r.modelo, '')) or ex.chassi is distinct from upper(trim(coalesce(r.chassi, '')))
         or ex.loja is distinct from v_nome
         or (coalesce(r."valorBoleto", 0) > 0 and ex.valor_venda <> round(r."valorBoleto", 2))
         or (v_lib is not null and ex.dt_coleta is distinct from v_lib) or (v_bol is not null and ex.prazo is distinct from v_bol) then
        update veiculos set modelo = trim(coalesce(r.modelo, '')), chassi = upper(trim(coalesce(r.chassi, ''))), loja = v_nome,
          valor_venda = case when coalesce(r."valorBoleto", 0) > 0 then round(r."valorBoleto", 2) else valor_venda end,
          dt_coleta = coalesce(v_lib, dt_coleta), prazo = coalesce(v_bol, prazo), atualizado_em = now()
        where cnpj = v_cnpj and id = ex.id;
        n_atual := n_atual + 1;
      end if;
    else
      insert into veiculos (cnpj, id, placa, modelo, chassi, valor_venda, dt_oferta, loja, dt_coleta, prazo)
      values (v_cnpj, v_id, v_placa, trim(coalesce(r.modelo, '')), upper(trim(coalesce(r.chassi, ''))),
              round(coalesce(r."valorBoleto", 0), 2), r."dtOferta"::date, v_nome, v_lib, v_bol);
      n_novos := n_novos + 1;
    end if;
  end loop;
  return json_build_object('novos', n_novos, 'atualizados', n_atual, 'lojasNovas', n_lojas,
                           'descartados', n_desc, 'ignorados', n_ign, 'existentes', n_exist);
end $$;

-- ---------- limpeza: o mesmo carro (placa) repetido na mesma loja ----------
-- Fica a linha que já tem andamento (boleto/documento/rastreio); empate: a mais recente.
-- Ela recebe os dados de planilha da linha mais recente (modelo, chassi, valor, datas). As outras são apagadas.
create or replace function cc_limpar_duplicados() returns int
language plpgsql security definer set search_path = public as $$
declare g record; k veiculos; nv veiculos; n int := 0;
begin
  for g in select cnpj, placa from veiculos group by cnpj, placa having count(*) > 1 loop
    select * into k from veiculos where cnpj = g.cnpj and placa = g.placa
      order by (boleto_status <> '' or doc_status <> '' or rastreio <> '') desc, ordem desc limit 1;
    select * into nv from veiculos where cnpj = g.cnpj and placa = g.placa order by ordem desc limit 1;
    if nv.id <> k.id then
      update veiculos set modelo = nv.modelo, chassi = coalesce(nullif(nv.chassi, ''), chassi),
        valor_venda = case when nv.valor_venda > 0 then nv.valor_venda else valor_venda end,
        dt_oferta = nv.dt_oferta, dt_coleta = coalesce(nv.dt_coleta, dt_coleta), prazo = coalesce(nv.prazo, prazo), atualizado_em = now()
      where cnpj = k.cnpj and id = k.id;
    end if;
    delete from veiculos where cnpj = g.cnpj and placa = g.placa and id <> k.id;
    n := n + 1;
  end loop;
  return n;
end $$;
select cc_limpar_duplicados();

-- ---------- administrador: dados da versão antiga (Google Script) ----------
-- p: {lojas:[{cnpj,nome}], veiculos:[{...campos da planilha antiga...}], finalizados:[{cnpj,id}]}
-- O andamento que vem da versão antiga substitui o que já estiver aqui para o mesmo veículo.
create or replace function cc_migrar(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare r record; n_lojas int := 0; n_veic int := 0; n_fim int := 0; n_desc int := 0; v_cnpj text;
  iso_data text := '^\d{4}-\d{2}-\d{2}';
begin
  perform cc_exige_admin();
  for r in select * from jsonb_to_recordset(coalesce(p -> 'lojas', '[]')) as x(cnpj text, nome text) loop
    v_cnpj := lpad(regexp_replace(coalesce(r.cnpj, ''), '\D', '', 'g'), 14, '0');
    if v_cnpj = '00000000000000' or trim(coalesce(r.nome, '')) = '' then continue; end if;
    insert into lojas (cnpj, nome) values (v_cnpj, trim(r.nome)) on conflict (cnpj) do nothing;
    if found then n_lojas := n_lojas + 1; end if;
  end loop;

  for r in select * from jsonb_to_recordset(coalesce(p -> 'finalizados', '[]')) as x(cnpj text, id text) loop
    v_cnpj := lpad(regexp_replace(coalesce(r.cnpj, ''), '\D', '', 'g'), 14, '0');
    if coalesce(r.id, '') = '' then continue; end if;
    insert into finalizados (cnpj, id, motivo) values (v_cnpj, r.id, 'versao antiga') on conflict do nothing;
    if found then n_fim := n_fim + 1; end if;
  end loop;

  for r in select * from jsonb_to_recordset(coalesce(p -> 'veiculos', '[]')) as x(
      cnpj text, id text, placa text, modelo text, "valorVenda" text, hodometro text, laudo text, "dtOferta" text, loja text,
      "dtColeta" text, prazo text, "boletoStatus" text, "boletoEnviadoEm" text, "placaBoleto" text,
      "docStatus" text, "docEnviadoEm" text, rastreio text) loop
    v_cnpj := lpad(regexp_replace(coalesce(r.cnpj, ''), '\D', '', 'g'), 14, '0');
    if coalesce(r.id, '') = '' or coalesce(r.placa, '') = '' or coalesce(r."dtOferta", '') !~ iso_data
       or not exists (select 1 from lojas where cnpj = v_cnpj) then
      n_desc := n_desc + 1; continue;
    end if;
    insert into veiculos (cnpj, id, placa, modelo, valor_venda, hodometro, laudo, dt_oferta, loja, dt_coleta, prazo,
      boleto_status, boleto_enviado_em, placa_boleto, doc_status, doc_enviado_em, rastreio)
    values (v_cnpj, r.id, upper(r.placa), coalesce(r.modelo, ''), coalesce(nullif(r."valorVenda", '')::numeric, 0),
      coalesce(r.hodometro, ''), coalesce(r.laudo, ''), left(r."dtOferta", 10)::date, coalesce(r.loja, ''),
      case when r."dtColeta" ~ iso_data then left(r."dtColeta", 10)::date end,
      case when r.prazo ~ iso_data then left(r.prazo, 10)::date end,
      coalesce(r."boletoStatus", ''), nullif(r."boletoEnviadoEm", '')::timestamptz, coalesce(r."placaBoleto", ''),
      coalesce(r."docStatus", ''), nullif(r."docEnviadoEm", '')::timestamptz, coalesce(r.rastreio, ''))
    on conflict (cnpj, id) do update set
      modelo = excluded.modelo, valor_venda = excluded.valor_venda, hodometro = excluded.hodometro, laudo = excluded.laudo,
      loja = excluded.loja, dt_coleta = excluded.dt_coleta, prazo = excluded.prazo, boleto_status = excluded.boleto_status,
      boleto_enviado_em = excluded.boleto_enviado_em, placa_boleto = excluded.placa_boleto, doc_status = excluded.doc_status,
      doc_enviado_em = excluded.doc_enviado_em, rastreio = excluded.rastreio, atualizado_em = now();
    delete from finalizados where cnpj = v_cnpj and id = r.id;
    n_veic := n_veic + 1;
  end loop;
  return json_build_object('lojas', n_lojas, 'veiculos', n_veic, 'finalizados', n_fim, 'descartados', n_desc);
end $$;

-- ---------- ações nos veículos (administrador e lojas) ----------
-- Data da Liberação (coluna dt_coleta) e Data Boleto (coluna prazo): vêm da planilha e podem ser corrigidas à mão
create or replace function cc_salvar_coleta(p_cnpj text, p_id text, p_dt text) returns veiculos
language plpgsql security definer set search_path = public as $$
declare v veiculos := cc_pega(p_cnpj, p_id);
begin
  update veiculos set dt_coleta = case when coalesce(p_dt, '') ~ '^\d{4}-\d{2}-\d{2}$' then p_dt::date end, atualizado_em = now()
  where cnpj = p_cnpj and id = p_id returning * into v;
  return v;
end $$;

create or replace function cc_salvar_prazo(p_cnpj text, p_id text, p_dt text) returns veiculos
language plpgsql security definer set search_path = public as $$
declare v veiculos := cc_pega(p_cnpj, p_id);
begin
  update veiculos set prazo = case when coalesce(p_dt, '') ~ '^\d{4}-\d{2}-\d{2}$' then p_dt::date end, atualizado_em = now()
  where cnpj = p_cnpj and id = p_id returning * into v;
  return v;
end $$;

create or replace function cc_salvar_valor(p_cnpj text, p_id text, p_valor numeric) returns veiculos
language plpgsql security definer set search_path = public as $$
declare v veiculos := cc_pega(p_cnpj, p_id); n numeric := round(coalesce(p_valor, 0), 2);
begin
  if not (n > 0) or n > 99999999 then raise exception 'Informe um valor do boleto válido.'; end if;
  update veiculos set valor_venda = n, atualizado_em = now() where cnpj = p_cnpj and id = p_id returning * into v;
  return v;
end $$;

create or replace function cc_incluir_veiculo(p_cnpj text, p_dados jsonb) returns veiculos
language plpgsql security definer set search_path = public as $$
declare
  l lojas; v veiculos;
  v_placa text := upper(regexp_replace(coalesce(p_dados ->> 'placa', ''), '[^A-Za-z0-9]', '', 'g'));
  v_modelo text := trim(coalesce(p_dados ->> 'modelo', ''));
  v_valor numeric := round(coalesce(nullif(p_dados ->> 'valorVenda', '')::numeric, 0), 2);
  v_dt text := coalesce(p_dados ->> 'dtOferta', '');
  v_lib text := coalesce(p_dados ->> 'dtLiberacao', '');
  v_bol text := coalesce(p_dados ->> 'dtBoleto', '');
  iso text := '^\d{4}-\d{2}-\d{2}$';
begin
  if not cc_pode(p_cnpj) then raise exception 'Sem acesso a esta loja.'; end if;
  select * into l from lojas where cnpj = p_cnpj;
  if not found then raise exception 'Loja não encontrada.'; end if;
  if length(v_placa) <> 7 then raise exception 'Placa inválida (7 caracteres).'; end if;
  if v_modelo = '' then raise exception 'Informe o modelo.'; end if;
  if not (v_valor > 0) or v_valor > 99999999 then raise exception 'Informe um valor do boleto válido.'; end if;
  if v_dt !~ iso then raise exception 'Informe a data da oferta.'; end if;
  if exists (select 1 from veiculos where cnpj = p_cnpj and (placa = v_placa or id = v_placa || '_' || v_dt)) then
    raise exception 'Esta placa já está na lista desta loja.';
  end if;
  insert into veiculos (cnpj, id, placa, modelo, chassi, valor_venda, dt_oferta, loja, dt_coleta, prazo)
  values (p_cnpj, v_placa || '_' || v_dt, v_placa, v_modelo, upper(trim(coalesce(p_dados ->> 'chassi', ''))), v_valor,
          v_dt::date, l.nome, case when v_lib ~ iso then v_lib::date end, case when v_bol ~ iso then v_bol::date end)
  returning * into v;
  -- se já tinha sido finalizado/excluído antes, volta a valer
  delete from finalizados where cnpj = p_cnpj and id = v.id;
  return v;
end $$;

-- botão Boleto: o formulário (link) foi aberto para esta placa
create or replace function cc_iniciar_boleto(p_cnpj text, p_id text, p_placa text) returns veiculos
language plpgsql security definer set search_path = public as $$
declare v veiculos := cc_pega(p_cnpj, p_id); v_placa text := upper(regexp_replace(coalesce(p_placa, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if v.boleto_status <> '' then raise exception 'O boleto deste veículo já foi solicitado.'; end if;
  if length(v_placa) <> 7 then raise exception 'Placa inválida (7 caracteres).'; end if;
  update veiculos set boleto_status = 'solicitado', boleto_enviado_em = now(), placa_boleto = v_placa, atualizado_em = now()
  where cnpj = p_cnpj and id = p_id returning * into v;
  return v;
end $$;

-- a loja recebeu o boleto
create or replace function cc_boleto_chegou(p_cnpj text, p_id text) returns veiculos
language plpgsql security definer set search_path = public as $$
declare v veiculos := cc_pega(p_cnpj, p_id);
begin
  if v.boleto_status = 'solicitado' then
    update veiculos set boleto_status = 'recebido', atualizado_em = now() where cnpj = p_cnpj and id = p_id returning * into v;
  end if;
  return v;
end $$;

-- volta o boleto para "não solicitado" (clicou por engano)
create or replace function cc_desfazer_boleto(p_cnpj text, p_id text) returns veiculos
language plpgsql security definer set search_path = public as $$
declare v veiculos := cc_pega(p_cnpj, p_id);
begin
  if v.doc_status = 'enviado' then raise exception 'Apague primeiro a data de envio do boleto.'; end if;
  update veiculos set boleto_status = '', boleto_enviado_em = null, placa_boleto = '', atualizado_em = now()
  where cnpj = p_cnpj and id = p_id returning * into v;
  return v;
end $$;

-- data em que o boleto foi enviado (a contagem de dias do documento parte dela)
create or replace function cc_salvar_enviado_em(p_cnpj text, p_id text, p_data text) returns veiculos
language plpgsql security definer set search_path = public as $$
declare v veiculos := cc_pega(p_cnpj, p_id);
begin
  if v.boleto_status not in ('recebido', 'pago') then raise exception 'O boleto ainda não chegou.'; end if;
  if coalesce(p_data, '') <> '' and p_data !~ '^20\d{2}-\d{2}-\d{2}$' then raise exception 'Data inválida.'; end if;
  if coalesce(p_data, '') = '' then
    update veiculos set doc_enviado_em = null, doc_status = '', atualizado_em = now()
    where cnpj = p_cnpj and id = p_id returning * into v;
  else
    update veiculos set doc_enviado_em = (p_data || ' 12:00')::timestamp at time zone 'America/Sao_Paulo',
      doc_status = 'enviado', atualizado_em = now()
    where cnpj = p_cnpj and id = p_id returning * into v;
  end if;
  return v;
end $$;

create or replace function cc_salvar_rastreio(p_cnpj text, p_id text, p_codigo text) returns veiculos
language plpgsql security definer set search_path = public as $$
declare v veiculos := cc_pega(p_cnpj, p_id); c text := upper(regexp_replace(coalesce(p_codigo, ''), '\s', '', 'g'));
begin
  if c <> '' and c !~ '^[A-Z]{2}\d{9}[A-Z]{2}$' then raise exception 'Código inválido. Formato: AA123456789BR'; end if;
  update veiculos set rastreio = c, atualizado_em = now() where cnpj = p_cnpj and id = p_id returning * into v;
  return v;
end $$;

-- documento recebido: processo concluído, a linha sai da lista
create or replace function cc_finalizar(p_cnpj text, p_id text) returns json
language plpgsql security definer set search_path = public as $$
declare v veiculos := cc_pega(p_cnpj, p_id);
begin
  if v.boleto_status not in ('recebido', 'pago') and v.doc_status <> 'enviado' then raise exception 'Disponível depois que o boleto chegar.'; end if;
  insert into finalizados (cnpj, id, motivo) values (p_cnpj, p_id, 'finalizado') on conflict (cnpj, id) do nothing;
  delete from veiculos where cnpj = p_cnpj and id = p_id;
  return json_build_object('ok', true);
end $$;

-- excluir: carro devolvido ou que não foi retirado (qualquer etapa)
create or replace function cc_excluir(p_cnpj text, p_id text) returns json
language plpgsql security definer set search_path = public as $$
declare v veiculos := cc_pega(p_cnpj, p_id);
begin
  insert into finalizados (cnpj, id, motivo) values (p_cnpj, p_id, 'excluido') on conflict (cnpj, id) do nothing;
  delete from veiculos where cnpj = p_cnpj and id = p_id;
  return json_build_object('ok', true);
end $$;

-- ---------- permissões ----------
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all tables in schema public from anon, authenticated;
grant select on veiculos to authenticated;
grant execute on function cc_criar_senha(text, text, text) to anon, authenticated;
grant execute on function cc_quem_sou(), cc_lojas(), cc_gerar_codigo(text), cc_importar_lote(jsonb), cc_migrar(jsonb),
  cc_coordenadores_listar(), cc_coord_salvar_email(text, text), cc_coord_gerar_codigo(text),
  cc_coord_nome(), cc_eh_gestor(), cc_salvar_prazo(text, text, text),
  cc_salvar_coleta(text, text, text), cc_salvar_valor(text, text, numeric), cc_incluir_veiculo(text, jsonb),
  cc_iniciar_boleto(text, text, text), cc_boleto_chegou(text, text), cc_desfazer_boleto(text, text),
  cc_salvar_enviado_em(text, text, text), cc_salvar_rastreio(text, text, text), cc_finalizar(text, text),
  cc_excluir(text, text), cc_meu_email(), cc_eh_admin(), cc_pode(text), cc_dominio()
  to authenticated;

-- =====================================================================
-- ADMINISTRADOR: depois de criar o seu usuário em Authentication > Users,
-- troque pelo e-mail usado lá e rode só esta linha
-- =====================================================================
-- insert into cc_admins (email) values ('seu.email@exemplo.com') on conflict do nothing;
