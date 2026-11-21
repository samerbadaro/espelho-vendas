-- =====================================================================
-- 116 — Módulos novos do Duo Haus (034–048) dentro de vários empreendimentos
--  * Propostas: módulo ligado na v2 e lido no empreendimento da proposta.
--  * Pix do sinal: configuração do empreendimento da pasta.
--  * Contratos: dados da vendedora, quadro de áreas, modelos e documentos
--    fixos passam a ser de cada empreendimento (cada incorporadora tem os seus).
--  * Leads: configuração, chave da planilha, cotas, rodízio e leads por
--    empreendimento (a chave da planilha diz de qual empreendimento é o lead).
--  * submeter_pasta: junta a versão da v2 (código com a sigla) com as
--    regras novas do Duo Haus (regime de bens, PJ, cônjuge e Pix).
-- Nada é configurado aqui: IA, D4Sign e minutas continuam em branco.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- Propostas: ligado na v2; a chave é a do empreendimento da proposta
-- ---------------------------------------------------------------------
alter table public.config alter column modulo_propostas set default true;
update public.config set modulo_propostas = true where not modulo_propostas;

create or replace function public.propostas_modulo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_equipe() and not coalesce((select modulo_propostas from public.config
                                              where empreendimento_id = coalesce(new.empreendimento_id, public.empreendimento_atual())), false) then
    raise exception 'MODULO_DESLIGADO' using hint = 'As propostas ainda não estão liberadas.';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Pix do sinal: configuração do empreendimento da pasta
-- ---------------------------------------------------------------------
create or replace function public.pix_integrado(p_pasta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select c.pix_modo = 'integrado' from public.config c join public.pastas p on p.empreendimento_id = c.empreendimento_id
                    where p.id = p_pasta), false);
$$;
revoke all on function public.pix_integrado(uuid) from public, anon, authenticated;

create or replace function public.recalcular_pasta(p_pasta uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ec        public.estado_civil;
  v_tipo      text;
  v_conjuge   boolean;
  v_submetida boolean;
  v_integrado boolean := public.pix_integrado(p_pasta);
  v_status    text;
  v_faltando  int;
  v_recusado  int;
  v_analise   int;
  v_enviado   int;
begin
  select estado_civil, tipo_pessoa, public.conjuge_no_contrato(estado_civil, regime_bens, conjuge_participa, tipo_pessoa), codigo_aprovacao is not null
    into v_ec, v_tipo, v_conjuge, v_submetida from public.pastas where id = p_pasta;

  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo
     and not (v_integrado and t.eh_pix)
     and case when v_tipo = 'pj' then t.aplica_a in ('pj', 'ambos') and t.obrigatorio_pj
              else t.aplica_a in ('pf', 'ambos') and v_ec = any (t.obrigatorio_para) and (t.pessoa <> 'conjuge' or v_conjuge) end
     and not exists (select 1 from public.documentos d where d.pasta_id = p_pasta and d.tipo_id = t.id and d.atual);
  if v_integrado and not public.pix_pago(p_pasta) then v_faltando := v_faltando + 1; end if;
  select count(*) into v_recusado from public.documentos where pasta_id = p_pasta and atual and status = 'recusado';
  select count(*) into v_analise  from public.documentos where pasta_id = p_pasta and atual and status = 'em_analise';
  select count(*) into v_enviado  from public.documentos where pasta_id = p_pasta and atual and status = 'enviado';

  if not v_submetida then
    v_status := case when v_faltando > 0 then 'incompleta' else 'pronta' end;
  else
    v_status := case
      when v_recusado > 0 then 'pendente_correcao'
      when v_faltando > 0 then 'incompleta'
      when v_analise > 0 then 'em_analise'
      when v_enviado > 0 then 'aguardando_analise'
      else 'aprovada' end;
  end if;

  update public.pastas set status = v_status where id = p_pasta and status is distinct from v_status;
  return v_status;
end;
$$;
revoke all on function public.recalcular_pasta(uuid) from public, anon, authenticated;

create or replace function public.config_pix_mudou() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.pix_modo is distinct from old.pix_modo then
    for r in select id from public.pastas where codigo_aprovacao is null and empreendimento_id = new.empreendimento_id loop
      perform public.recalcular_pasta(r.id);
    end loop;
  end if;
  return null;
end;
$$;

do $$
declare d text;
begin
  -- gerar_cobranca_pix: troca só a leitura da configuração
  select pg_get_functiondef('public.gerar_cobranca_pix(uuid)'::regprocedure) into d;
  if position('where id = 1' in d) > 0 then
    d := replace(d, 'select * into c from public.config where id = 1;',
                    'select c0.* into c from public.config c0 join public.pastas p0 on p0.empreendimento_id = c0.empreendimento_id where p0.id = p_pasta;');
    execute d;
  end if;
end $$;

-- Submissão: código com a sigla do empreendimento + regras de regime, PJ e Pix
create or replace function public.submeter_pasta(p_pasta uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v_pasta.codigo_aprovacao is not null then raise exception 'JA_SUBMETIDA'; end if;
  if length(trim(coalesce(v_pasta.comprador_telefone, ''))) < 10
     or length(trim(coalesce(v_pasta.comprador_email, ''))) <= 3
     or length(trim(coalesce(v_pasta.comprador_profissao, ''))) <= 1 then
    raise exception 'DADOS_INCOMPLETOS';
  end if;
  if v_pasta.tipo_pessoa = 'pf' and v_pasta.estado_civil in ('casado', 'uniao_estavel') and v_pasta.regime_bens is null then
    raise exception 'REGIME_NAO_INFORMADO';
  end if;
  if public.conjuge_no_contrato(v_pasta.estado_civil, v_pasta.regime_bens, v_pasta.conjuge_participa, v_pasta.tipo_pessoa)
     and (length(trim(coalesce(v_pasta.conjuge_nome, ''))) <= 1
          or v_pasta.conjuge_cpf is null
          or length(trim(coalesce(v_pasta.conjuge_profissao, ''))) <= 1) then
    raise exception 'DADOS_CONJUGE_INCOMPLETOS';
  end if;
  if public.pix_integrado(p_pasta) and not public.pix_pago(p_pasta) then
    raise exception 'PIX_PENDENTE';
  end if;
  if public.recalcular_pasta(p_pasta) <> 'pronta' then raise exception 'DOCUMENTOS_FALTANDO'; end if;

  update public.pastas
     set codigo_aprovacao = public.proximo_codigo(v_pasta.empreendimento_id, 'PA'),
         submetida_em = now(), submetida_por = public.meu_email()
   where id = p_pasta
  returning * into v_pasta;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pasta submetida ao incorporador', jsonb_build_object('codigo', v_pasta.codigo_aprovacao), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$$;

-- ---------------------------------------------------------------------
-- Contratos: cada empreendimento com os seus dados, quadro, modelos e fixos
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['empreendimento_contrato', 'unidade_areas', 'modelos_contrato', 'contrato_anexos_fixos'] loop
    execute format('alter table public.%I add column if not exists empreendimento_id uuid references public.empreendimentos (id) on delete cascade', t);
    execute format('update public.%I set empreendimento_id = public.empreendimento_padrao() where empreendimento_id is null', t);
    execute format('alter table public.%I alter column empreendimento_id set not null', t);
    execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_atual()', t);
    execute format('drop policy if exists %I on public.%I', t || '_do_empreendimento', t);
    execute format('create policy %I on public.%I as restrictive for select using (empreendimento_id = (select public.empreendimento_atual()))', t || '_do_empreendimento', t);
  end loop;
end $$;

-- dados da vendedora: uma linha por empreendimento
alter table public.empreendimento_contrato drop constraint if exists empreendimento_contrato_id_check;
create sequence if not exists public.empreendimento_contrato_id_seq as smallint;
select setval('public.empreendimento_contrato_id_seq', greatest((select max(id) from public.empreendimento_contrato), 1));
alter table public.empreendimento_contrato alter column id set default nextval('public.empreendimento_contrato_id_seq');
create unique index if not exists empreendimento_contrato_emp_key on public.empreendimento_contrato (empreendimento_id);

create or replace function public.salvar_empreendimento_contrato(p_dados jsonb) returns public.empreendimento_contrato
language plpgsql security definer set search_path = public as $$
declare v public.empreendimento_contrato;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.empreendimento_contrato (empreendimento_id, dados, atualizado_em, atualizado_por)
  values (public.empreendimento_atual(), coalesce(p_dados, '{}'), now(), public.meu_email())
  on conflict (empreendimento_id) do update set dados = excluded.dados, atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  return v;
end;
$$;

-- quadro de áreas: número único dentro do empreendimento
alter table public.unidade_areas drop constraint if exists unidade_areas_pkey;
alter table public.unidade_areas add primary key (empreendimento_id, numero);

create or replace function public.importar_quadro_areas(p_linhas jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then raise exception 'PLANILHA_VAZIA'; end if;
  if exists (select 1 from jsonb_array_elements(p_linhas) l where coalesce(trim(l ->> 'numero'), '') = '') then raise exception 'UNIDADE_SEM_NUMERO'; end if;
  if (select count(distinct trim(l ->> 'numero')) from jsonb_array_elements(p_linhas) l) <> jsonb_array_length(p_linhas) then raise exception 'UNIDADE_REPETIDA'; end if;
  delete from public.unidade_areas where empreendimento_id = v_emp;
  insert into public.unidade_areas (empreendimento_id, numero, torre, pavimento, area_privativa, area_acessoria, area_privativa_total, area_comum,
                                    area_total, fracao_ideal, vagas, escaninho, escaninho_local, escaninho_area)
  select v_emp, trim(l ->> 'numero'), nullif(trim(l ->> 'torre'), ''), nullif(trim(l ->> 'pavimento'), ''),
         (l ->> 'area_privativa')::numeric, (l ->> 'area_acessoria')::numeric, (l ->> 'area_privativa_total')::numeric,
         (l ->> 'area_comum')::numeric, (l ->> 'area_total')::numeric, (l ->> 'fracao_ideal')::numeric,
         nullif(trim(l ->> 'vagas'), ''), nullif(trim(l ->> 'escaninho'), ''), nullif(trim(l ->> 'escaninho_local'), ''),
         (l ->> 'escaninho_area')::numeric
    from jsonb_array_elements(p_linhas) l;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- modelos: um ativo por documento em cada empreendimento
drop index if exists public.modelos_contrato_um_ativo;
create unique index if not exists modelos_contrato_um_ativo on public.modelos_contrato (empreendimento_id, documento) where ativo;

create or replace function public.salvar_modelo_contrato(p_documento text, p_nome text, p_caminho text)
returns public.modelos_contrato language plpgsql security definer set search_path = public as $$
declare v public.modelos_contrato; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.modelos_contrato set ativo = false where empreendimento_id = v_emp and documento = p_documento and ativo;
  insert into public.modelos_contrato (empreendimento_id, documento, nome, caminho, enviado_por)
  values (v_emp, p_documento, left(p_nome, 200), p_caminho, public.meu_email()) returning * into v;
  return v;
end;
$$;

create or replace function public.usar_modelo_padrao(p_documento text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.modelos_contrato set ativo = false where empreendimento_id = public.empreendimento_atual() and documento = p_documento and ativo;
end;
$$;

create or replace function public.salvar_anexo_fixo(p_nome text, p_caminho text, p_arquivo text, p_ordem int)
returns public.contrato_anexos_fixos language plpgsql security definer set search_path = public as $$
declare v public.contrato_anexos_fixos;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.contrato_anexos_fixos (empreendimento_id, nome, caminho, arquivo, ordem, enviado_por)
  values (public.empreendimento_atual(), left(trim(p_nome), 150), p_caminho, left(p_arquivo, 200), coalesce(p_ordem, 100), public.meu_email()) returning * into v;
  return v;
end;
$$;

create or replace function public.alterar_anexo_fixo(p_id uuid, p_nome text, p_ordem int, p_ativo boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contrato_anexos_fixos set nome = coalesce(left(trim(p_nome), 150), nome), ordem = coalesce(p_ordem, ordem), ativo = coalesce(p_ativo, ativo)
   where id = p_id and empreendimento_id = public.empreendimento_atual();
end;
$$;

-- ---------------------------------------------------------------------
-- Leads por empreendimento
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['leads_config', 'leads_chave'] loop
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_id_check');
    execute format('create sequence if not exists public.%I', t || '_id_seq');
    execute format('select setval(%L, greatest((select max(id) from public.%I), 1))', 'public.' || t || '_id_seq', t);
    execute format('alter table public.%I alter column id set default nextval(%L)', t, 'public.' || t || '_id_seq');
  end loop;
  foreach t in array array['leads_config', 'leads_chave', 'leads_imobiliarias', 'leads_corretores', 'leads'] loop
    execute format('alter table public.%I add column if not exists empreendimento_id uuid references public.empreendimentos (id) on delete cascade', t);
    execute format('update public.%I set empreendimento_id = public.empreendimento_padrao() where empreendimento_id is null', t);
    execute format('alter table public.%I alter column empreendimento_id set not null', t);
    execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_atual()', t);
    execute format('drop policy if exists %I on public.%I', t || '_do_empreendimento', t);
    execute format('create policy %I on public.%I as restrictive for select using (empreendimento_id = (select public.empreendimento_atual()))', t || '_do_empreendimento', t);
  end loop;
end $$;
create unique index if not exists leads_config_emp_key on public.leads_config (empreendimento_id);
create unique index if not exists leads_chave_emp_key on public.leads_chave (empreendimento_id);
alter table public.leads_imobiliarias drop constraint if exists leads_imobiliarias_pkey;
alter table public.leads_imobiliarias add primary key (empreendimento_id, imobiliaria_id);
alter table public.leads_corretores drop constraint if exists leads_corretores_pkey;
alter table public.leads_corretores add primary key (empreendimento_id, user_id);
create index if not exists leads_emp_idx on public.leads (empreendimento_id, recebido_em desc);

-- todo empreendimento tem a sua configuração e a sua chave
insert into public.leads_config (empreendimento_id) select id from public.empreendimentos on conflict (empreendimento_id) do nothing;
insert into public.leads_chave (empreendimento_id) select id from public.empreendimentos on conflict (empreendimento_id) do nothing;
create or replace function public.empreendimento_cria_leads() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.leads_config (empreendimento_id) values (new.id) on conflict (empreendimento_id) do nothing;
  insert into public.leads_chave (empreendimento_id) values (new.id) on conflict (empreendimento_id) do nothing;
  return null;
end;
$$;
revoke all on function public.empreendimento_cria_leads() from public, anon, authenticated;
drop trigger if exists empreendimento_cria_leads on public.empreendimentos;
create trigger empreendimento_cria_leads after insert on public.empreendimentos for each row execute function public.empreendimento_cria_leads();

-- prazo e alertas: pela configuração do empreendimento
drop function if exists public.leads_prazo(timestamptz, int);
create or replace function public.leads_prazo(p_inicio timestamptz, p_minutos int, p_emp uuid default null) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare c public.leads_config; t timestamp; resto numeric := p_minutos; abre timestamp; fecha timestamp; dispo numeric; i int := 0;
begin
  select * into c from public.leads_config where empreendimento_id = coalesce(p_emp, public.empreendimento_atual());
  if c.id is null or c.plantao_24h or coalesce(array_length(c.dias_semana, 1), 0) = 0 or c.hora_fim <= c.hora_inicio then
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

drop function if exists public.leads_emails_alerta();
create or replace function public.leads_emails_alerta(p_emp uuid default null) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim((select emails_alerta from public.leads_config where empreendimento_id = coalesce(p_emp, public.empreendimento_atual()))), ''),
                  (select string_agg(email, ',') from public.perfis where papel = 'vendas'),
                  (select string_agg(email, ',') from public.perfis where papel = 'admin'));
$$;

/** Escolhe o próximo corretor (do rodízio do empreendimento do lead) e entrega o lead. */
create or replace function public.leads_atribuir(p_lead uuid, p_motivo text default 'Rodízio') returns void
language plpgsql security definer set search_path = public as $$
declare
  l public.leads; c public.leads_config; v_imob uuid; v_corr uuid; v_email text; v_nome text; v_prazo timestamptz;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null then return; end if;
  select * into c from public.leads_config where empreendimento_id = l.empreendimento_id;

  if coalesce(array_length(l.tentados, 1), 0) < c.max_tentativas then
    -- 1) próximo corretor da mesma imobiliária
    if l.imobiliaria_id is not null then
      select lc.user_id into v_corr
        from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
       where lc.empreendimento_id = l.empreendimento_id and lc.participa and p.papel = 'corretor'
         and p.imobiliaria_id = l.imobiliaria_id and not (lc.user_id = any (l.tentados))
       order by lc.ultimo_lead_em nulls first, lc.recebidos limit 1;
      if v_corr is not null then v_imob := l.imobiliaria_id; end if;
    end if;
    -- 2) imobiliária pela cota (quem está mais abaixo da sua proporção)
    if v_corr is null then
      select li.imobiliaria_id into v_imob
        from public.leads_imobiliarias li join public.imobiliarias i on i.id = li.imobiliaria_id and i.ativa
       where li.empreendimento_id = l.empreendimento_id and li.cota > 0 and li.imobiliaria_id is distinct from l.imobiliaria_id
         and exists (select 1 from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
                      where lc.empreendimento_id = l.empreendimento_id and lc.participa and p.papel = 'corretor'
                        and p.imobiliaria_id = li.imobiliaria_id and not (lc.user_id = any (l.tentados)))
       order by (li.recebidos + 1) / li.cota, li.cota desc, random() limit 1;
      if v_imob is not null then
        select lc.user_id into v_corr
          from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
         where lc.empreendimento_id = l.empreendimento_id and lc.participa and p.papel = 'corretor'
           and p.imobiliaria_id = v_imob and not (lc.user_id = any (l.tentados))
         order by lc.ultimo_lead_em nulls first, lc.recebidos limit 1;
        update public.leads_imobiliarias set recebidos = recebidos + 1 where empreendimento_id = l.empreendimento_id and imobiliaria_id = v_imob;
      end if;
    end if;
  end if;

  if v_corr is null then
    update public.leads set status = 'sem_destino', corretor_id = null, prazo_aceite_em = null, atualizado_em = now() where id = l.id;
    perform public.lead_evento(l.id, 'Aguardando a Sec. Vendas', jsonb_build_object('motivo',
      case when coalesce(array_length(l.tentados, 1), 0) >= c.max_tentativas then 'Limite de tentativas atingido' else 'Nenhum corretor disponível no rodízio' end));
    perform public.lead_avisar(l.id, public.leads_emails_alerta(l.empreendimento_id), 'Lead ' || l.codigo || ' sem corretor — distribuir manualmente',
      jsonb_build_array('O lead ' || l.codigo || ' não foi assumido por ninguém do rodízio e aguarda a Sec. Vendas.') || public.lead_resumo(l), 'Distribuir lead');
    return;
  end if;

  v_prazo := public.leads_prazo(now(), c.prazo_aceite_min, l.empreendimento_id);
  update public.leads set status = 'aguardando_aceite', imobiliaria_id = v_imob, corretor_id = v_corr, distribuido_em = now(),
         prazo_aceite_em = v_prazo, aceito_em = null, tentados = array_append(tentados, v_corr), atualizado_em = now()
   where id = l.id returning * into l;
  update public.leads_corretores set ultimo_lead_em = now(), recebidos = recebidos + 1 where empreendimento_id = l.empreendimento_id and user_id = v_corr;
  select email, nome into v_email, v_nome from public.perfis where user_id = v_corr;
  perform public.lead_evento(l.id, 'Enviado ao corretor', jsonb_build_object('corretor', coalesce(v_nome, v_email), 'motivo', p_motivo, 'prazo', v_prazo));
  perform public.lead_avisar(l.id, v_email, 'Novo lead ' || l.codigo || ' — assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    jsonb_build_array('Você recebeu um lead (' || p_motivo || '). Assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI')
      || ' para ver telefone e e-mail; depois disso ele vai para o próximo corretor.') || public.lead_resumo(l), 'Assumir lead');
end;
$$;

/** Entrada da planilha (servidor, com a chave): a chave diz o empreendimento. */
create or replace function public.receber_leads(p_chave text, p_linhas jsonb, p_origem text default 'planilha', p_url text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r jsonb; v_id text; l public.leads; v_dono public.leads; v_tel text; v_email text; v_nome text; c public.leads_config; v_emp uuid;
  novos int := 0; repetidos int := 0; v_corr_pasta uuid; v_imob_pasta uuid;
  chaves_meta text[] := array['id', 'lead_id', 'leadgen_id', 'created_time', 'data_de_criacao', 'ad_id', 'ad_name', 'adset_id', 'adset_name',
    'campaign_id', 'campaign_name', 'form_id', 'form_name', 'is_organic', 'platform', 'plataforma', 'nome_completo', 'full_name', 'nome', 'name',
    'first_name', 'last_name', 'primeiro_nome', 'sobrenome', 'phone_number', 'phone', 'telefone', 'numero_de_telefone', 'celular', 'whatsapp',
    'email', 'e_mail', '_linha', '_rotulos', 'inbox_url', 'lead_status', 'vehicle', 'retailer_item_id'];
begin
  select empreendimento_id into v_emp from public.leads_chave where p_chave is not null and chave = p_chave;
  if v_emp is null then raise exception 'CHAVE_INVALIDA'; end if;
  select * into c from public.leads_config where empreendimento_id = v_emp;
  update public.leads_config set ultimo_recebimento = now(), url_app = coalesce(p_url, url_app) where empreendimento_id = v_emp;
  for r in select * from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) loop
    v_id := nullif(trim(coalesce(r ->> 'id', r ->> 'lead_id', r ->> 'leadgen_id')), '');
    v_id := coalesce(regexp_replace(v_id, '^l:', ''), p_origem || ':' || coalesce(r ->> '_linha', md5(r::text)));
    if exists (select 1 from public.leads where meta_id = v_id) then repetidos := repetidos + 1; continue; end if;
    v_nome := nullif(trim(coalesce(r ->> 'nome_completo', r ->> 'full_name', r ->> 'nome', r ->> 'name',
                 nullif(trim(coalesce(r ->> 'first_name', r ->> 'primeiro_nome', '') || ' ' || coalesce(r ->> 'last_name', r ->> 'sobrenome', '')), ''))), '');
    v_tel := public.so_digitos_tel(coalesce(r ->> 'phone_number', r ->> 'telefone', r ->> 'numero_de_telefone', r ->> 'celular', r ->> 'whatsapp', r ->> 'phone'));
    v_email := nullif(lower(trim(coalesce(r ->> 'email', r ->> 'e_mail', ''))), '');
    insert into public.leads (empreendimento_id, meta_id, origem, campanha, conjunto, anuncio, formulario, plataforma, criado_meta_em, nome, telefone, email, respostas)
    values (v_emp, v_id, coalesce(p_origem, 'planilha'), nullif(r ->> 'campaign_name', ''), nullif(r ->> 'adset_name', ''), nullif(r ->> 'ad_name', ''),
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

    -- Cliente que voltou (no mesmo empreendimento): mesmo corretor durante "dono_dias"
    v_dono := null; v_corr_pasta := null; v_imob_pasta := null;
    select * into v_dono from public.leads x
     where x.id <> l.id and x.empreendimento_id = v_emp and x.corretor_id is not null and x.status <> 'perdido'
       and x.recebido_em > now() - make_interval(days => c.dono_dias)
       and ((v_tel is not null and x.telefone = v_tel) or (v_email is not null and lower(x.email) = v_email))
       and exists (select 1 from public.perfis p where p.user_id = x.corretor_id)
     order by x.recebido_em desc limit 1;
    if v_dono.id is null then
      -- ou cliente que já tem pasta neste empreendimento: corretor da pasta
      select coalesce(pa.cadastrado_por_id, pa.criado_por_id), pa.imobiliaria_id into v_corr_pasta, v_imob_pasta
        from public.pastas pa join public.perfis p on p.user_id = coalesce(pa.cadastrado_por_id, pa.criado_por_id) and p.papel = 'corretor'
       where pa.empreendimento_id = v_emp
         and ((v_tel is not null and public.so_digitos_tel(pa.comprador_telefone) = v_tel) or (v_email is not null and lower(pa.comprador_email) = v_email))
       order by pa.criada_em desc limit 1;
    else
      v_corr_pasta := v_dono.corretor_id; v_imob_pasta := v_dono.imobiliaria_id;
    end if;

    if v_corr_pasta is not null then
      update public.leads set retorno_de = v_dono.id, imobiliaria_id = v_imob_pasta, status = 'aguardando_aceite', corretor_id = v_corr_pasta,
             tentados = array[v_corr_pasta], distribuido_em = now(), prazo_aceite_em = public.leads_prazo(now(), c.prazo_aceite_min, v_emp)
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

/** Rodado a cada minuto pelo servidor, para todos os empreendimentos. */
create or replace function public.processar_leads() returns int
language plpgsql security definer set search_path = public as $$
declare l record; n int := 0;
begin
  for l in select id, corretor_id from public.leads where status = 'aguardando_aceite' and prazo_aceite_em < now() order by prazo_aceite_em limit 200 for update skip locked loop
    perform public.lead_evento(l.id, 'Prazo para assumir esgotado', jsonb_build_object('corretor', (select coalesce(nome, email) from public.perfis where user_id = l.corretor_id)));
    perform public.leads_atribuir(l.id, 'Redistribuído: o anterior não assumiu no prazo');
    n := n + 1;
  end loop;
  -- Assumiu mas não registrou contato no prazo: avisa o gestor da imobiliária (uma vez)
  for l in select x.id, x.codigo, x.imobiliaria_id, x.corretor_id from public.leads x
             join public.leads_config c on c.empreendimento_id = x.empreendimento_id
            where x.status = 'em_atendimento' and x.primeiro_contato_em is null
              and public.leads_prazo(x.aceito_em, c.prazo_contato_min, x.empreendimento_id) < now()
              and not exists (select 1 from public.lead_eventos e where e.lead_id = x.id and e.tipo = 'Sem registro de contato no prazo') limit 200 loop
    perform public.lead_evento(l.id, 'Sem registro de contato no prazo', '{}'::jsonb);
    perform public.lead_avisar(l.id, (select string_agg(email, ',') from public.perfis where papel = 'imobiliaria' and imobiliaria_id = l.imobiliaria_id),
      'Lead ' || l.codigo || ' sem contato registrado',
      jsonb_build_array((select coalesce(nome, email) from public.perfis where user_id = l.corretor_id) || ' assumiu o lead ' || l.codigo || ' e ainda não registrou o primeiro contato.'), 'Abrir lead');
  end loop;
  return n;
end;
$$;

do $$
declare d text;
begin
  -- listar_leads: só os leads do empreendimento atual
  select pg_get_functiondef('public.listar_leads(uuid)'::regprocedure) into d;
  if position('l.empreendimento_id' in d) = 0 then
    d := replace(d, 'where (p_id is null or l.id = p_id)', 'where l.empreendimento_id = public.empreendimento_atual() and (p_id is null or l.id = p_id)');
    execute d;
  end if;
  -- redistribuir_lead: prazo pela configuração do empreendimento do lead
  select pg_get_functiondef('public.redistribuir_lead(uuid, uuid)'::regprocedure) into d;
  d := replace(d, '(select prazo_aceite_min from public.leads_config where id = 1))',
                  '(select prazo_aceite_min from public.leads_config where empreendimento_id = l.empreendimento_id), l.empreendimento_id)');
  execute d;
  -- pasta nova converte só lead do mesmo empreendimento
  select pg_get_functiondef('public.pastas_converte_lead()'::regprocedure) into d;
  if position('new.empreendimento_id' in d) = 0 then
    d := replace(d, 'and (imobiliaria_id = new.imobiliaria_id)', 'and (imobiliaria_id = new.imobiliaria_id) and empreendimento_id = new.empreendimento_id');
    execute d;
  end if;
end $$;

create or replace function public.salvar_config_leads(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.leads_config (empreendimento_id) values (v_emp) on conflict (empreendimento_id) do nothing;
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
  where empreendimento_id = v_emp;
end;
$$;

create or replace function public.salvar_cotas_leads(p_cotas jsonb, p_zerar boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  for r in select (x ->> 'imobiliaria_id')::uuid as imob, greatest(0, coalesce((x ->> 'cota')::numeric, 0)) as cota from jsonb_array_elements(p_cotas) x loop
    insert into public.leads_imobiliarias (empreendimento_id, imobiliaria_id, cota) values (v_emp, r.imob, r.cota)
    on conflict (empreendimento_id, imobiliaria_id) do update set cota = excluded.cota;
  end loop;
  if p_zerar then update public.leads_imobiliarias set recebidos = 0 where empreendimento_id = v_emp; end if;
end;
$$;

create or replace function public.chave_leads(p_nova boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare v text; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.leads_chave (empreendimento_id) values (v_emp) on conflict (empreendimento_id) do nothing;
  if p_nova then update public.leads_chave set chave = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') where empreendimento_id = v_emp; end if;
  select chave into v from public.leads_chave where empreendimento_id = v_emp;
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
  insert into public.leads_corretores (empreendimento_id, user_id, participa, alterado_por) values (public.empreendimento_atual(), p_user, p_participa, public.meu_email())
  on conflict (empreendimento_id, user_id) do update set participa = excluded.participa, alterado_em = now(), alterado_por = excluded.alterado_por;
end;
$$;

-- Permissões (funções novas ou com assinatura nova)
revoke all on function public.leads_prazo(timestamptz, int, uuid), public.leads_emails_alerta(uuid) from public, anon, authenticated;
grant execute on function public.leads_prazo(timestamptz, int, uuid) to authenticated;

commit;
