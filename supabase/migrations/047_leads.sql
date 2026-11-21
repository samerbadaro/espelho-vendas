-- =====================================================================
-- 047 — Leads (campanhas do Meta) com rodízio, prazo e funil
--  * Entrada: planilha do Google preenchida pelo Meta → script da planilha
--    → /api/leads/entrada (chave secreta) → receber_leads().
--  * Distribuição em dois níveis: imobiliária por cota (peso) e, dentro
--    dela, rodízio entre os corretores que o gestor colocou na lista.
--  * Prazo para "Assumir" (padrão 15 min) contado só no horário comercial;
--    estourou → próximo corretor da mesma imobiliária (depois, outra
--    imobiliária); depois de N tentativas → Sec. Vendas decide.
--  * Cliente que volta (mesmo telefone/e-mail) vai para o mesmo corretor
--    durante X dias. Pasta criada com o mesmo telefone/e-mail converte o lead.
--  * Telefone e e-mail só aparecem para o corretor depois de assumir.
-- Executar uma única vez no SQL Editor do Supabase (depois da 046).
-- =====================================================================
begin;

alter table public.config add column if not exists modulo_leads boolean not null default false;
grant update (modulo_leads) on public.config to authenticated;

-- Configuração ---------------------------------------------------------
create table if not exists public.leads_config (
  id                 int primary key default 1 check (id = 1),
  ativo              boolean not null default true,
  prazo_aceite_min   int not null default 15 check (prazo_aceite_min between 1 and 1440),
  prazo_contato_min  int not null default 120 check (prazo_contato_min between 5 and 10080),
  max_tentativas     int not null default 3 check (max_tentativas between 1 and 20),
  dias_semana        int[] not null default '{1,2,3,4,5,6}',
  hora_inicio        time not null default '08:00',
  hora_fim           time not null default '18:00',
  plantao_24h        boolean not null default false,
  dono_dias          int not null default 90 check (dono_dias between 0 and 730),
  emails_alerta      text,
  remetente_email    text,
  remetente_nome     text default 'Leads',
  url_app            text,
  ultimo_recebimento timestamptz,
  atualizado_em      timestamptz not null default now(),
  atualizado_por     text
);
insert into public.leads_config (id) values (1) on conflict do nothing;
alter table public.leads_config enable row level security;
drop policy if exists leads_config_leitura on public.leads_config;
create policy leads_config_leitura on public.leads_config for select using (public.eh_equipe() or public.minha_imobiliaria() is not null);
revoke all on public.leads_config from anon, authenticated;
grant select on public.leads_config to authenticated;

-- Chave da planilha (só o administrador vê, pela função)
create table if not exists public.leads_chave (
  id    int primary key default 1 check (id = 1),
  chave text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
);
insert into public.leads_chave (id) values (1) on conflict do nothing;
alter table public.leads_chave enable row level security;
revoke all on public.leads_chave from anon, authenticated;

-- Cotas por imobiliária e lista de corretores no rodízio
create table if not exists public.leads_imobiliarias (
  imobiliaria_id uuid primary key references public.imobiliarias(id) on delete cascade,
  cota           numeric(6, 2) not null default 0 check (cota >= 0),
  recebidos      int not null default 0
);
alter table public.leads_imobiliarias enable row level security;
drop policy if exists leads_imobiliarias_leitura on public.leads_imobiliarias;
create policy leads_imobiliarias_leitura on public.leads_imobiliarias for select using (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria());
revoke all on public.leads_imobiliarias from anon, authenticated;
grant select on public.leads_imobiliarias to authenticated;

create table if not exists public.leads_corretores (
  user_id        uuid primary key references public.perfis(user_id) on delete cascade,
  participa      boolean not null default false,
  ultimo_lead_em timestamptz,
  recebidos      int not null default 0,
  alterado_em    timestamptz not null default now(),
  alterado_por   text
);
alter table public.leads_corretores enable row level security;
drop policy if exists leads_corretores_leitura on public.leads_corretores;
create policy leads_corretores_leitura on public.leads_corretores for select using (
  public.eh_equipe() or user_id = auth.uid()
  or exists (select 1 from public.perfis p where p.user_id = leads_corretores.user_id and p.imobiliaria_id = public.minha_imobiliaria()));
revoke all on public.leads_corretores from anon, authenticated;
grant select on public.leads_corretores to authenticated;

-- Leads ------------------------------------------------------------------
create sequence if not exists public.leads_codigo_seq;
create table if not exists public.leads (
  id                  uuid primary key default gen_random_uuid(),
  codigo              text not null unique default 'L-' || lpad(nextval('public.leads_codigo_seq')::text, 5, '0'),
  meta_id             text not null unique,
  origem              text not null default 'meta',
  campanha            text, conjunto text, anuncio text, formulario text, plataforma text,
  criado_meta_em      timestamptz,
  recebido_em         timestamptz not null default now(),
  nome                text,
  telefone            text,
  email               text,
  respostas           jsonb not null default '{}'::jsonb,
  status              text not null default 'sem_destino' check (status in (
                        'aguardando_aceite', 'em_atendimento', 'visita_agendada', 'visita_realizada', 'proposta',
                        'convertido', 'perdido', 'sem_destino')),
  imobiliaria_id      uuid references public.imobiliarias(id) on delete set null,
  corretor_id         uuid references public.perfis(user_id) on delete set null,
  distribuido_em      timestamptz,
  prazo_aceite_em     timestamptz,
  aceito_em           timestamptz,
  primeiro_contato_em timestamptz,
  tentados            uuid[] not null default '{}',
  motivo_perda        text,
  observacao          text,
  pasta_id            uuid references public.pastas(id) on delete set null,
  convertido_em       timestamptz,
  retorno_de          uuid references public.leads(id) on delete set null,
  atualizado_em       timestamptz not null default now()
);
create index if not exists leads_status_idx on public.leads (status, prazo_aceite_em);
create index if not exists leads_corretor_idx on public.leads (corretor_id);
create index if not exists leads_imob_idx on public.leads (imobiliaria_id);
create index if not exists leads_tel_idx on public.leads (telefone);
create index if not exists leads_email_idx on public.leads (lower(email));
alter table public.leads enable row level security;
-- Leitura direta só equipe e gestor da imobiliária; corretor lê por listar_leads() (dados mascarados até assumir)
drop policy if exists leads_leitura on public.leads;
create policy leads_leitura on public.leads for select using (public.eh_equipe() or (imobiliaria_id is not null and imobiliaria_id = public.minha_imobiliaria() and public.eh_gestor()));
revoke all on public.leads from anon, authenticated;
grant select on public.leads to authenticated;

create table if not exists public.lead_eventos (
  id            bigint generated always as identity primary key,
  lead_id       uuid not null references public.leads(id) on delete cascade,
  tipo          text not null,
  detalhes      jsonb not null default '{}'::jsonb,
  usuario_email text,
  criado_em     timestamptz not null default now()
);
create index if not exists lead_eventos_lead_idx on public.lead_eventos (lead_id, criado_em);
alter table public.lead_eventos enable row level security;
revoke all on public.lead_eventos from anon, authenticated;

create table if not exists public.lead_notificacoes (
  id         bigint generated always as identity primary key,
  lead_id    uuid references public.leads(id) on delete cascade,
  para       text not null,
  assunto    text not null,
  linhas     jsonb not null default '[]'::jsonb,   -- ["texto", ...]
  botao      text,                                  -- rótulo do botão
  caminho    text,                                  -- /painel/leads/<id>
  status     text not null default 'pendente' check (status in ('pendente', 'enviado', 'erro')),
  tentativas int not null default 0,
  erro       text,
  criado_em  timestamptz not null default now(),
  enviado_em timestamptz
);
create index if not exists lead_notificacoes_pend_idx on public.lead_notificacoes (status, criado_em);
alter table public.lead_notificacoes enable row level security;
revoke all on public.lead_notificacoes from anon, authenticated;

-- Auxiliares ----------------------------------------------------------------
create or replace function public.so_digitos_tel(t text) returns text
language sql immutable as $$
  select case when d = '' then null when length(d) >= 12 and d like '55%' then right(d, 11) else d end
    from (select regexp_replace(coalesce(t, ''), '\D', '', 'g') as d) x;
$$;

/** Soma minutos contando só o horário comercial (fuso de Brasília). */
create or replace function public.leads_prazo(p_inicio timestamptz, p_minutos int) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare c public.leads_config; t timestamp; resto numeric := p_minutos; abre timestamp; fecha timestamp; dispo numeric; i int := 0;
begin
  select * into c from public.leads_config where id = 1;
  if c.plantao_24h or coalesce(array_length(c.dias_semana, 1), 0) = 0 or c.hora_fim <= c.hora_inicio then
    return p_inicio + make_interval(mins => p_minutos);
  end if;
  t := p_inicio at time zone 'America/Sao_Paulo';
  loop
    i := i + 1;
    exit when i > 40;
    if extract(isodow from t)::int = any (c.dias_semana) then
      abre := date_trunc('day', t) + c.hora_inicio;
      fecha := date_trunc('day', t) + c.hora_fim;
      if t < abre then t := abre; end if;
      if t < fecha then
        dispo := extract(epoch from (fecha - t)) / 60;
        if resto <= dispo then return (t + make_interval(secs => resto * 60)) at time zone 'America/Sao_Paulo'; end if;
        resto := resto - dispo;
      end if;
    end if;
    t := date_trunc('day', t) + interval '1 day';
  end loop;
  return p_inicio + make_interval(mins => p_minutos);
end;
$$;

create or replace function public.lead_evento(p_lead uuid, p_tipo text, p_detalhes jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.lead_eventos (lead_id, tipo, detalhes, usuario_email) values (p_lead, p_tipo, coalesce(p_detalhes, '{}'::jsonb), coalesce(public.meu_email(), 'sistema'));
$$;

/** Avisos por e-mail (o servidor envia a cada minuto). */
create or replace function public.lead_avisar(p_lead uuid, p_para text, p_assunto text, p_linhas jsonb, p_botao text default 'Abrir lead') returns void
language sql security definer set search_path = public as $$
  insert into public.lead_notificacoes (lead_id, para, assunto, linhas, botao, caminho)
  select p_lead, trim(e), p_assunto, p_linhas, p_botao, '/painel/leads/' || p_lead
    from unnest(string_to_array(p_para, ',')) e where trim(e) ~ '^[^\s@,]+@[^\s@,]+$';
$$;

create or replace function public.leads_emails_alerta() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim((select emails_alerta from public.leads_config where id = 1)), ''),
                  (select string_agg(email, ',') from public.perfis where papel = 'vendas'),
                  (select string_agg(email, ',') from public.perfis where papel = 'admin'));
$$;

/** Resumo das respostas para o e-mail (sem dados de contato). */
create or replace function public.lead_resumo(l public.leads) returns jsonb
language sql stable as $$
  select jsonb_build_array(
    'Lead ' || l.codigo || coalesce(' · ' || nullif(split_part(coalesce(l.nome, ''), ' ', 1), ''), ''),
    'Campanha: ' || coalesce(l.campanha, '—') || coalesce(' · ' || l.formulario, ''))
  || coalesce((select jsonb_agg(case when k ~ '_' then initcap(replace(k, '_', ' ')) else k end || ': ' || v) from jsonb_each_text(l.respostas) as r(k, v) where length(v) between 1 and 120), '[]'::jsonb);
$$;

/** Escolhe o próximo corretor e entrega o lead (ou manda para a Sec. Vendas). */
create or replace function public.leads_atribuir(p_lead uuid, p_motivo text default 'Rodízio') returns void
language plpgsql security definer set search_path = public as $$
declare
  l public.leads; c public.leads_config; v_imob uuid; v_corr uuid; v_email text; v_nome text; v_prazo timestamptz;
begin
  select * into c from public.leads_config where id = 1;
  select * into l from public.leads where id = p_lead for update;
  if l.id is null then return; end if;

  if coalesce(array_length(l.tentados, 1), 0) < c.max_tentativas then
    -- 1) próximo corretor da mesma imobiliária
    if l.imobiliaria_id is not null then
      select lc.user_id into v_corr
        from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
       where lc.participa and p.papel = 'corretor' and p.imobiliaria_id = l.imobiliaria_id and not (lc.user_id = any (l.tentados))
       order by lc.ultimo_lead_em nulls first, lc.recebidos limit 1;
      if v_corr is not null then v_imob := l.imobiliaria_id; end if;
    end if;
    -- 2) imobiliária pela cota (quem está mais abaixo da sua proporção)
    if v_corr is null then
      select li.imobiliaria_id into v_imob
        from public.leads_imobiliarias li join public.imobiliarias i on i.id = li.imobiliaria_id and i.ativa
       where li.cota > 0 and li.imobiliaria_id is distinct from l.imobiliaria_id
         and exists (select 1 from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
                      where lc.participa and p.papel = 'corretor' and p.imobiliaria_id = li.imobiliaria_id and not (lc.user_id = any (l.tentados)))
       order by (li.recebidos + 1) / li.cota, li.cota desc, random() limit 1;
      if v_imob is null and l.imobiliaria_id is null then v_imob := null; end if;
      if v_imob is not null then
        select lc.user_id into v_corr
          from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
         where lc.participa and p.papel = 'corretor' and p.imobiliaria_id = v_imob and not (lc.user_id = any (l.tentados))
         order by lc.ultimo_lead_em nulls first, lc.recebidos limit 1;
        update public.leads_imobiliarias set recebidos = recebidos + 1 where imobiliaria_id = v_imob;
      end if;
    end if;
  end if;

  if v_corr is null then
    update public.leads set status = 'sem_destino', corretor_id = null, prazo_aceite_em = null, atualizado_em = now() where id = l.id;
    perform public.lead_evento(l.id, 'Aguardando a Sec. Vendas', jsonb_build_object('motivo',
      case when coalesce(array_length(l.tentados, 1), 0) >= c.max_tentativas then 'Limite de tentativas atingido' else 'Nenhum corretor disponível no rodízio' end));
    perform public.lead_avisar(l.id, public.leads_emails_alerta(), 'Lead ' || l.codigo || ' sem corretor — distribuir manualmente',
      jsonb_build_array('O lead ' || l.codigo || ' não foi assumido por ninguém do rodízio e aguarda a Sec. Vendas.') || public.lead_resumo(l), 'Distribuir lead');
    return;
  end if;

  v_prazo := public.leads_prazo(now(), c.prazo_aceite_min);
  update public.leads set status = 'aguardando_aceite', imobiliaria_id = v_imob, corretor_id = v_corr, distribuido_em = now(),
         prazo_aceite_em = v_prazo, aceito_em = null, tentados = array_append(tentados, v_corr), atualizado_em = now()
   where id = l.id returning * into l;
  update public.leads_corretores set ultimo_lead_em = now(), recebidos = recebidos + 1 where user_id = v_corr;
  select email, nome into v_email, v_nome from public.perfis where user_id = v_corr;
  perform public.lead_evento(l.id, 'Enviado ao corretor', jsonb_build_object('corretor', coalesce(v_nome, v_email), 'motivo', p_motivo, 'prazo', v_prazo));
  perform public.lead_avisar(l.id, v_email, 'Novo lead ' || l.codigo || ' — assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    jsonb_build_array('Você recebeu um lead (' || p_motivo || '). Assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI')
      || ' para ver telefone e e-mail; depois disso ele vai para o próximo corretor.') || public.lead_resumo(l), 'Assumir lead');
end;
$$;

/** Entrada da planilha (chamada só pelo servidor, com a chave). */
create or replace function public.receber_leads(p_chave text, p_linhas jsonb, p_origem text default 'planilha', p_url text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r jsonb; v_id text; l public.leads; v_dono public.leads; v_tel text; v_email text; v_nome text; c public.leads_config;
  novos int := 0; repetidos int := 0; v_corr_pasta uuid; v_imob_pasta uuid;
  chaves_meta text[] := array['id', 'lead_id', 'leadgen_id', 'created_time', 'data_de_criacao', 'ad_id', 'ad_name', 'adset_id', 'adset_name',
    'campaign_id', 'campaign_name', 'form_id', 'form_name', 'is_organic', 'platform', 'plataforma', 'nome_completo', 'full_name', 'nome', 'name',
    'first_name', 'last_name', 'primeiro_nome', 'sobrenome', 'phone_number', 'phone', 'telefone', 'numero_de_telefone', 'celular', 'whatsapp',
    'email', 'e_mail', '_linha', '_rotulos', 'inbox_url', 'lead_status', 'vehicle', 'retailer_item_id'];
begin
  if p_chave is null or p_chave <> (select chave from public.leads_chave where id = 1) then raise exception 'CHAVE_INVALIDA'; end if;
  select * into c from public.leads_config where id = 1;
  update public.leads_config set ultimo_recebimento = now(), url_app = coalesce(p_url, url_app) where id = 1;
  for r in select * from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) loop
    v_id := nullif(trim(coalesce(r ->> 'id', r ->> 'lead_id', r ->> 'leadgen_id')), '');
    v_id := coalesce(regexp_replace(v_id, '^l:', ''), p_origem || ':' || coalesce(r ->> '_linha', md5(r::text)));
    if exists (select 1 from public.leads where meta_id = v_id) then repetidos := repetidos + 1; continue; end if;
    v_nome := nullif(trim(coalesce(r ->> 'nome_completo', r ->> 'full_name', r ->> 'nome', r ->> 'name',
                 nullif(trim(coalesce(r ->> 'first_name', r ->> 'primeiro_nome', '') || ' ' || coalesce(r ->> 'last_name', r ->> 'sobrenome', '')), ''))), '');
    v_tel := public.so_digitos_tel(coalesce(r ->> 'phone_number', r ->> 'telefone', r ->> 'numero_de_telefone', r ->> 'celular', r ->> 'whatsapp', r ->> 'phone'));
    v_email := nullif(lower(trim(coalesce(r ->> 'email', r ->> 'e_mail', ''))), '');
    insert into public.leads (meta_id, origem, campanha, conjunto, anuncio, formulario, plataforma, criado_meta_em, nome, telefone, email, respostas)
    values (v_id, coalesce(p_origem, 'planilha'), nullif(r ->> 'campaign_name', ''), nullif(r ->> 'adset_name', ''), nullif(r ->> 'ad_name', ''),
            nullif(r ->> 'form_name', ''), nullif(coalesce(r ->> 'platform', r ->> 'plataforma'), ''),
            case when coalesce(r ->> 'created_time', r ->> 'data_de_criacao', '') ~ '^\d{4}-\d{2}-\d{2}' then (coalesce(r ->> 'created_time', r ->> 'data_de_criacao'))::timestamptz end,
            initcap(v_nome), v_tel, v_email,
            coalesce((select jsonb_object_agg(coalesce(nullif(trim(r -> '_rotulos' ->> k), ''), k), v) from jsonb_each_text(r) as x(k, v) where not (k = any (chaves_meta)) and nullif(trim(v), '') is not null), '{}'::jsonb))
    returning * into l;
    novos := novos + 1;
    perform public.lead_evento(l.id, 'Lead recebido', jsonb_build_object('campanha', l.campanha, 'formulario', l.formulario, 'origem', l.origem));

    if not c.ativo then
      perform public.lead_evento(l.id, 'Aguardando a Sec. Vendas', jsonb_build_object('motivo', 'Rodízio desligado'));
      continue;
    end if;

    -- Cliente que voltou: mesmo corretor durante "dono_dias"
    select * into v_dono from public.leads x
     where x.id <> l.id and x.corretor_id is not null and x.status <> 'perdido'
       and x.recebido_em > now() - make_interval(days => c.dono_dias)
       and ((v_tel is not null and x.telefone = v_tel) or (v_email is not null and lower(x.email) = v_email))
       and exists (select 1 from public.perfis p where p.user_id = x.corretor_id)
     order by x.recebido_em desc limit 1;
    if v_dono.id is null then
      -- ou cliente que já tem pasta: corretor da pasta
      select coalesce(pa.cadastrado_por_id, pa.criado_por_id), pa.imobiliaria_id into v_corr_pasta, v_imob_pasta
        from public.pastas pa join public.perfis p on p.user_id = coalesce(pa.cadastrado_por_id, pa.criado_por_id) and p.papel = 'corretor'
       where (v_tel is not null and public.so_digitos_tel(pa.comprador_telefone) = v_tel) or (v_email is not null and lower(pa.comprador_email) = v_email)
       order by pa.criada_em desc limit 1;
    else
      v_corr_pasta := v_dono.corretor_id; v_imob_pasta := v_dono.imobiliaria_id;
    end if;

    if v_corr_pasta is not null then
      update public.leads set retorno_de = v_dono.id, imobiliaria_id = v_imob_pasta, status = 'aguardando_aceite', corretor_id = v_corr_pasta,
             tentados = array[v_corr_pasta], distribuido_em = now(), prazo_aceite_em = public.leads_prazo(now(), c.prazo_aceite_min)
       where id = l.id returning * into l;
      perform public.lead_evento(l.id, 'Enviado ao corretor', jsonb_build_object('motivo', 'Cliente já atendido por este corretor',
        'corretor', (select coalesce(nome, email) from public.perfis where user_id = v_corr_pasta), 'prazo', l.prazo_aceite_em));
      perform public.lead_avisar(l.id, (select email from public.perfis where user_id = v_corr_pasta),
        'Cliente seu voltou: lead ' || l.codigo || ' — assuma até ' || to_char(l.prazo_aceite_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
        jsonb_build_array('Um cliente que já é seu preencheu um novo formulário. Assuma até ' || to_char(l.prazo_aceite_em at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI') || '.') || public.lead_resumo(l), 'Assumir lead');
    else
      perform public.leads_atribuir(l.id, 'Rodízio');
    end if;
  end loop;
  return jsonb_build_object('novos', novos, 'repetidos', repetidos);
end;
$$;

/** Rodado a cada minuto pelo servidor: prazos vencidos voltam ao rodízio. */
create or replace function public.processar_leads() returns int
language plpgsql security definer set search_path = public as $$
declare l record; n int := 0; c public.leads_config;
begin
  select * into c from public.leads_config where id = 1;
  for l in select id, corretor_id from public.leads where status = 'aguardando_aceite' and prazo_aceite_em < now() order by prazo_aceite_em limit 200 for update skip locked loop
    perform public.lead_evento(l.id, 'Prazo para assumir esgotado', jsonb_build_object('corretor', (select coalesce(nome, email) from public.perfis where user_id = l.corretor_id)));
    perform public.leads_atribuir(l.id, 'Redistribuído: o anterior não assumiu no prazo');
    n := n + 1;
  end loop;
  -- Assumiu mas não registrou contato no prazo: avisa o gestor da imobiliária (uma vez)
  for l in select x.id, x.codigo, x.imobiliaria_id, x.corretor_id from public.leads x
            where x.status = 'em_atendimento' and x.primeiro_contato_em is null
              and public.leads_prazo(x.aceito_em, c.prazo_contato_min) < now()
              and not exists (select 1 from public.lead_eventos e where e.lead_id = x.id and e.tipo = 'Sem registro de contato no prazo') limit 200 loop
    perform public.lead_evento(l.id, 'Sem registro de contato no prazo', '{}'::jsonb);
    perform public.lead_avisar(l.id, (select string_agg(email, ',') from public.perfis where papel = 'imobiliaria' and imobiliaria_id = l.imobiliaria_id),
      'Lead ' || l.codigo || ' sem contato registrado',
      jsonb_build_array((select coalesce(nome, email) from public.perfis where user_id = l.corretor_id) || ' assumiu o lead ' || l.codigo || ' e ainda não registrou o primeiro contato.'), 'Abrir lead');
  end loop;
  return n;
end;
$$;

/** Notificações pendentes (servidor). */
create or replace function public.leads_notificacoes_pendentes(p_limite int default 50) returns setof public.lead_notificacoes
language sql security definer set search_path = public as $$
  select * from public.lead_notificacoes where status = 'pendente' or (status = 'erro' and tentativas < 3 and criado_em > now() - interval '1 day')
   order by criado_em limit p_limite;
$$;
create or replace function public.leads_marcar_notificacao(p_id bigint, p_ok boolean, p_erro text default null) returns void
language sql security definer set search_path = public as $$
  update public.lead_notificacoes set status = case when p_ok then 'enviado' else 'erro' end, tentativas = tentativas + 1,
         enviado_em = case when p_ok then now() end, erro = left(p_erro, 300) where id = p_id;
$$;

-- Leitura -------------------------------------------------------------------
create or replace function public.pode_ver_lead(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.leads l where l.id = p_id and (
    public.eh_equipe() or l.corretor_id = auth.uid()
    or (public.eh_gestor() and l.imobiliaria_id = public.minha_imobiliaria())));
$$;
drop policy if exists lead_eventos_leitura on public.lead_eventos;
create policy lead_eventos_leitura on public.lead_eventos for select using (public.pode_ver_lead(lead_id));
grant select on public.lead_eventos to authenticated;

create or replace function public.listar_leads(p_id uuid default null)
returns table (id uuid, codigo text, status text, campanha text, conjunto text, anuncio text, formulario text, plataforma text,
               recebido_em timestamptz, nome text, telefone text, email text, respostas jsonb, imobiliaria_id uuid, imobiliaria text,
               corretor_id uuid, corretor text, distribuido_em timestamptz, prazo_aceite_em timestamptz, aceito_em timestamptz,
               primeiro_contato_em timestamptz, tentativas int, motivo_perda text, observacao text, pasta_id uuid, pasta_codigo text,
               convertido_em timestamptz, retorno boolean, mascarado boolean)
language sql stable security definer set search_path = public as $$
  with eu as (select papel, imobiliaria_id from public.perfis where user_id = auth.uid())
  select l.id, l.codigo, l.status, l.campanha, l.conjunto, l.anuncio, l.formulario, l.plataforma, l.recebido_em,
         case when m.mask then split_part(coalesce(l.nome, ''), ' ', 1) else l.nome end,
         case when m.mask then null else l.telefone end,
         case when m.mask then null else l.email end,
         l.respostas, l.imobiliaria_id, i.nome, l.corretor_id, coalesce(p.nome, p.email), l.distribuido_em, l.prazo_aceite_em, l.aceito_em,
         l.primeiro_contato_em, coalesce(array_length(l.tentados, 1), 0), l.motivo_perda, l.observacao, l.pasta_id, pa.codigo, l.convertido_em,
         l.retorno_de is not null, m.mask
    from public.leads l
    cross join eu
    left join public.imobiliarias i on i.id = l.imobiliaria_id
    left join public.perfis p on p.user_id = l.corretor_id
    left join public.pastas pa on pa.id = l.pasta_id
    cross join lateral (select (eu.papel = 'corretor' and l.status = 'aguardando_aceite') as mask) m
   where (p_id is null or l.id = p_id)
     and (eu.papel in ('admin', 'vendas')
          or (eu.papel = 'imobiliaria' and l.imobiliaria_id = eu.imobiliaria_id)
          or (eu.papel = 'corretor' and l.corretor_id = auth.uid()))
   order by l.recebido_em desc
   limit 2000;
$$;

-- Ações -----------------------------------------------------------------------
create or replace function public.assumir_lead(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_id for update;
  if l.id is null or l.corretor_id is distinct from auth.uid() then raise exception 'LEAD_NAO_E_SEU'; end if;
  if l.status <> 'aguardando_aceite' then raise exception 'LEAD_JA_ASSUMIDO'; end if;
  update public.leads set status = 'em_atendimento', aceito_em = now(), prazo_aceite_em = null, atualizado_em = now() where id = p_id;
  perform public.lead_evento(p_id, 'Assumido', jsonb_build_object('minutos', round(extract(epoch from (now() - l.distribuido_em)) / 60)));
end;
$$;

create or replace function public.pode_mexer_lead(l public.leads) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe() or (l.corretor_id = auth.uid() and l.status <> 'aguardando_aceite')
      or (public.eh_gestor() and l.imobiliaria_id = public.minha_imobiliaria());
$$;

create or replace function public.registrar_contato_lead(p_id uuid, p_canal text, p_nota text) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_id for update;
  if l.id is null or not public.pode_mexer_lead(l) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.leads set primeiro_contato_em = coalesce(primeiro_contato_em, now()), atualizado_em = now() where id = p_id;
  perform public.lead_evento(p_id, 'Contato', jsonb_build_object('canal', left(p_canal, 30), 'nota', left(nullif(trim(p_nota), ''), 1000)));
end;
$$;

create or replace function public.mover_lead(p_id uuid, p_status text, p_motivo text default null, p_obs text default null) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_id for update;
  if l.id is null or not public.pode_mexer_lead(l) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_status not in ('em_atendimento', 'visita_agendada', 'visita_realizada', 'proposta', 'perdido') then raise exception 'ETAPA_INVALIDA'; end if;
  if l.status in ('aguardando_aceite', 'sem_destino') then raise exception 'LEAD_SEM_ATENDIMENTO'; end if;
  if l.status in ('perdido', 'convertido') and not (public.eh_equipe() or public.eh_gestor()) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_status = 'perdido' and nullif(trim(p_motivo), '') is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  update public.leads set status = p_status, motivo_perda = case when p_status = 'perdido' then left(trim(p_motivo), 120) end,
         observacao = coalesce(nullif(trim(p_obs), ''), observacao), atualizado_em = now() where id = p_id;
  perform public.lead_evento(p_id, case when p_status = 'perdido' then 'Perdido' when l.status in ('perdido', 'convertido') then 'Reaberto' else 'Etapa alterada' end,
    jsonb_build_object('de', l.status, 'para', p_status, 'motivo', nullif(trim(p_motivo), ''), 'obs', nullif(trim(p_obs), '')));
end;
$$;

/** Redistribuir: equipe (qualquer corretor ou rodízio) e gestor (só a própria equipe). */
create or replace function public.redistribuir_lead(p_id uuid, p_corretor uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads; v_imob uuid; v_email text; v_prazo timestamptz;
begin
  select * into l from public.leads where id = p_id for update;
  if l.id is null then raise exception 'LEAD_NAO_ENCONTRADO'; end if;
  if l.status in ('convertido') then raise exception 'LEAD_CONVERTIDO'; end if;
  if not public.eh_equipe() and not (public.eh_gestor() and l.imobiliaria_id = public.minha_imobiliaria()) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_corretor is null then
    if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
    update public.leads set tentados = '{}', corretor_id = null where id = p_id;
    perform public.lead_evento(p_id, 'Devolvido ao rodízio', '{}'::jsonb);
    perform public.leads_atribuir(p_id, 'Rodízio (redistribuído pela equipe)');
    return;
  end if;
  select imobiliaria_id, email into v_imob, v_email from public.perfis where user_id = p_corretor and papel = 'corretor';
  if v_imob is null then raise exception 'CORRETOR_INVALIDO'; end if;
  if not public.eh_equipe() and v_imob <> public.minha_imobiliaria() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  v_prazo := public.leads_prazo(now(), (select prazo_aceite_min from public.leads_config where id = 1));
  update public.leads set imobiliaria_id = v_imob, corretor_id = p_corretor, status = 'aguardando_aceite', distribuido_em = now(),
         prazo_aceite_em = v_prazo, aceito_em = null, tentados = array_append(tentados, p_corretor), atualizado_em = now()
   where id = p_id returning * into l;
  perform public.lead_evento(p_id, 'Enviado ao corretor', jsonb_build_object('motivo', 'Escolhido manualmente',
    'corretor', (select coalesce(nome, email) from public.perfis where user_id = p_corretor), 'prazo', v_prazo));
  perform public.lead_avisar(p_id, v_email, 'Novo lead ' || l.codigo || ' — assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    jsonb_build_array('Um lead foi direcionado a você. Assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI') || '.') || public.lead_resumo(l), 'Assumir lead');
end;
$$;

create or replace function public.vincular_pasta_lead(p_lead uuid, p_pasta uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null or not (public.eh_equipe() or l.corretor_id = auth.uid() or (public.eh_gestor() and l.imobiliaria_id = public.minha_imobiliaria())) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if not exists (select 1 from public.pastas where id = p_pasta and (public.eh_equipe() or imobiliaria_id = coalesce(public.minha_imobiliaria(), l.imobiliaria_id))) then
    raise exception 'PASTA_INVALIDA';
  end if;
  update public.leads set status = 'convertido', pasta_id = p_pasta, convertido_em = now(), motivo_perda = null,
         aceito_em = coalesce(aceito_em, now()), primeiro_contato_em = coalesce(primeiro_contato_em, now()), atualizado_em = now() where id = p_lead;
  perform public.lead_evento(p_lead, 'Convertido em pasta', jsonb_build_object('pasta', (select codigo from public.pastas where id = p_pasta)));
end;
$$;

-- Pasta nova com o mesmo telefone/e-mail de um lead em atendimento converte o lead
create or replace function public.pastas_converte_lead() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_tel text := public.so_digitos_tel(new.comprador_telefone); v_email text := lower(nullif(trim(new.comprador_email), '')); l record;
begin
  if v_tel is null and v_email is null then return null; end if;
  for l in select id from public.leads
            where status not in ('convertido', 'perdido', 'sem_destino') and pasta_id is null
              and (imobiliaria_id = new.imobiliaria_id)
              and ((v_tel is not null and telefone = v_tel) or (v_email is not null and lower(email) = v_email)) loop
    update public.leads set status = 'convertido', pasta_id = new.id, convertido_em = now(), aceito_em = coalesce(aceito_em, now()),
           primeiro_contato_em = coalesce(primeiro_contato_em, now()), atualizado_em = now() where id = l.id;
    perform public.lead_evento(l.id, 'Convertido em pasta', jsonb_build_object('pasta', new.codigo, 'automatico', true));
  end loop;
  return null;
end;
$$;
drop trigger if exists pastas_converte_lead on public.pastas;
create trigger pastas_converte_lead after insert on public.pastas for each row execute function public.pastas_converte_lead();

-- Configuração (administrador) e lista do rodízio (gestor) -----------------------
create or replace function public.salvar_config_leads(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.leads_config set
    ativo = coalesce((p ->> 'ativo')::boolean, ativo),
    prazo_aceite_min = coalesce((p ->> 'prazo_aceite_min')::int, prazo_aceite_min),
    prazo_contato_min = coalesce((p ->> 'prazo_contato_min')::int, prazo_contato_min),
    max_tentativas = coalesce((p ->> 'max_tentativas')::int, max_tentativas),
    dias_semana = coalesce((select array_agg(x::int order by x::int) from jsonb_array_elements_text(p -> 'dias_semana') x), dias_semana),
    hora_inicio = coalesce((p ->> 'hora_inicio')::time, hora_inicio),
    hora_fim = coalesce((p ->> 'hora_fim')::time, hora_fim),
    plantao_24h = coalesce((p ->> 'plantao_24h')::boolean, plantao_24h),
    dono_dias = coalesce((p ->> 'dono_dias')::int, dono_dias),
    emails_alerta = case when p ? 'emails_alerta' then nullif(trim(p ->> 'emails_alerta'), '') else emails_alerta end,
    remetente_email = case when p ? 'remetente_email' then nullif(trim(p ->> 'remetente_email'), '') else remetente_email end,
    remetente_nome = case when p ? 'remetente_nome' then nullif(trim(p ->> 'remetente_nome'), '') else remetente_nome end,
    atualizado_em = now(), atualizado_por = public.meu_email()
  where id = 1;
end;
$$;

create or replace function public.salvar_cotas_leads(p_cotas jsonb, p_zerar boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  for r in select (x ->> 'imobiliaria_id')::uuid as imob, greatest(0, coalesce((x ->> 'cota')::numeric, 0)) as cota from jsonb_array_elements(p_cotas) x loop
    insert into public.leads_imobiliarias (imobiliaria_id, cota) values (r.imob, r.cota)
    on conflict (imobiliaria_id) do update set cota = excluded.cota;
  end loop;
  if p_zerar then update public.leads_imobiliarias set recebidos = 0 where true; end if;
end;
$$;

create or replace function public.chave_leads(p_nova boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_nova then update public.leads_chave set chave = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') where id = 1; end if;
  select chave into v from public.leads_chave where id = 1;
  return v;
end;
$$;

create or replace function public.definir_rodizio_corretor(p_user uuid, p_participa boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_imob uuid;
begin
  select imobiliaria_id into v_imob from public.perfis where user_id = p_user and papel = 'corretor';
  if v_imob is null then raise exception 'CORRETOR_INVALIDO'; end if;
  if not (public.eh_equipe() or (public.eh_gestor() and v_imob = public.minha_imobiliaria())) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.leads_corretores (user_id, participa, alterado_por) values (p_user, p_participa, public.meu_email())
  on conflict (user_id) do update set participa = excluded.participa, alterado_em = now(), alterado_por = excluded.alterado_por;
end;
$$;

-- Permissões ---------------------------------------------------------------------
revoke all on function public.so_digitos_tel(text), public.leads_prazo(timestamptz, int), public.lead_evento(uuid, text, jsonb),
  public.lead_avisar(uuid, text, text, jsonb, text), public.leads_emails_alerta(), public.lead_resumo(public.leads), public.leads_atribuir(uuid, text),
  public.receber_leads(text, jsonb, text, text), public.processar_leads(), public.leads_notificacoes_pendentes(int), public.leads_marcar_notificacao(bigint, boolean, text),
  public.pode_ver_lead(uuid), public.listar_leads(uuid), public.assumir_lead(uuid), public.pode_mexer_lead(public.leads), public.registrar_contato_lead(uuid, text, text),
  public.mover_lead(uuid, text, text, text), public.redistribuir_lead(uuid, uuid), public.vincular_pasta_lead(uuid, uuid), public.pastas_converte_lead(),
  public.salvar_config_leads(jsonb), public.salvar_cotas_leads(jsonb, boolean), public.chave_leads(boolean), public.definir_rodizio_corretor(uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.receber_leads(text, jsonb, text, text), public.processar_leads(), public.leads_notificacoes_pendentes(int),
  public.leads_marcar_notificacao(bigint, boolean, text) to service_role;
grant execute on function public.pode_ver_lead(uuid), public.listar_leads(uuid), public.assumir_lead(uuid), public.registrar_contato_lead(uuid, text, text),
  public.mover_lead(uuid, text, text, text), public.redistribuir_lead(uuid, uuid), public.vincular_pasta_lead(uuid, uuid), public.salvar_config_leads(jsonb),
  public.salvar_cotas_leads(jsonb, boolean), public.chave_leads(boolean), public.definir_rodizio_corretor(uuid, boolean), public.leads_prazo(timestamptz, int)
  to authenticated;

commit;
