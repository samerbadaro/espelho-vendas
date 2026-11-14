-- Atualização da v2 (14/11/2026): vários empreendimentos (109) e tabela de vendas com versões (110). Já aplicada no projeto de testes.
-- =====================================================================
-- 109 — Vários empreendimentos na mesma incorporadora (Fase 1, etapa A)
--  * Tabela de empreendimentos (nome, endereço, sigla, ordem, ativo).
--  * O primeiro empreendimento nasce da configuração atual (Duo Haus).
--  * Campo "empreendimento" nas tabelas de dados de cada lançamento,
--    preenchido automaticamente com o empreendimento padrão. Nada muda
--    nas telas nesta etapa: tudo continua funcionando como antes.
--  * Restrição de acesso: o administrador pode bloquear um empreendimento
--    para uma imobiliária (padrão: ela vê todos).
--  Decisões (14/11/2026): um banco por incorporadora; imobiliárias veem
--  todos os empreendimentos com restrição opcional; pastas numeradas por
--  empreendimento com sigla (DH-PA-001).
-- =====================================================================

create table if not exists public.empreendimentos (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  sigla      text not null unique check (sigla ~ '^[A-Z0-9]{2,4}$'),
  nome       text not null check (length(trim(nome)) >= 2),
  ativo      boolean not null default true,
  ordem      int not null default 0,
  criado_em  timestamptz not null default now()
);

insert into public.empreendimentos (slug, sigla, nome)
select 'duohaus', 'DH', coalesce(nullif(trim(c.nome_empreendimento), ''), 'Empreendimento')
  from public.config c where c.id = 1
   and not exists (select 1 from public.empreendimentos);

-- empreendimento usado quando nenhum é informado (o primeiro, por ordem)
create or replace function public.empreendimento_padrao() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.empreendimentos order by ordem, criado_em limit 1;
$$;
grant execute on function public.empreendimento_padrao() to anon, authenticated;

-- campo "empreendimento" nas tabelas de dados de lançamento
do $$
declare t text;
begin
  foreach t in array array['unidades', 'negociacoes', 'historico', 'pastas', 'rodadas', 'recepcao_eventos',
                           'portal_itens', 'portal_downloads', 'simulacoes_log', 'propostas'] loop
    if to_regclass('public.' || t) is not null then
      execute format('alter table public.%I add column if not exists empreendimento_id uuid references public.empreendimentos (id)', t);
      execute format('update public.%I set empreendimento_id = public.empreendimento_padrao() where empreendimento_id is null', t);
      execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_padrao()', t);
      execute format('alter table public.%I alter column empreendimento_id set not null', t);
      execute format('create index if not exists %I on public.%I (empreendimento_id)', t || '_empreendimento_idx', t);
    end if;
  end loop;
end $$;

-- negociação e histórico seguem o empreendimento da unidade
create or replace function public.herdar_empreendimento_da_unidade() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.unidade_id is not null then
    select empreendimento_id into new.empreendimento_id from public.unidades where id = new.unidade_id;
  end if;
  return new;
end;
$$;
drop trigger if exists negociacoes_empreendimento on public.negociacoes;
create trigger negociacoes_empreendimento before insert on public.negociacoes
  for each row execute function public.herdar_empreendimento_da_unidade();
drop trigger if exists historico_empreendimento on public.historico;
create trigger historico_empreendimento before insert on public.historico
  for each row execute function public.herdar_empreendimento_da_unidade();
drop trigger if exists propostas_empreendimento on public.propostas;
create trigger propostas_empreendimento before insert on public.propostas
  for each row execute function public.herdar_empreendimento_da_unidade();

-- restrição opcional: imobiliária sem acesso a um empreendimento
create table if not exists public.imobiliarias_bloqueios (
  imobiliaria_id    uuid not null references public.imobiliarias (id) on delete cascade,
  empreendimento_id uuid not null references public.empreendimentos (id) on delete cascade,
  criado_em         timestamptz not null default now(),
  criado_por        text,
  primary key (imobiliaria_id, empreendimento_id)
);

-- quem enxerga cada empreendimento: equipe vê todos; imobiliária/corretor, os não bloqueados
create or replace function public.acesso_empreendimento(p_empreendimento uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe()
      or (auth.uid() is not null and not exists (
            select 1 from public.imobiliarias_bloqueios b
             where b.empreendimento_id = p_empreendimento and b.imobiliaria_id = public.minha_imobiliaria()));
$$;
grant execute on function public.acesso_empreendimento(uuid) to authenticated;

alter table public.empreendimentos enable row level security;
alter table public.imobiliarias_bloqueios enable row level security;
revoke all on public.empreendimentos, public.imobiliarias_bloqueios from anon, authenticated;
grant select on public.empreendimentos to anon, authenticated;
grant select on public.imobiliarias_bloqueios to authenticated;
create policy empreendimentos_leitura on public.empreendimentos for select using (true);
create policy bloqueios_leitura on public.imobiliarias_bloqueios for select
  using (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria());

-- administrador cadastra empreendimentos e define bloqueios
create or replace function public.salvar_empreendimento(p_id uuid, p_nome text, p_slug text, p_sigla text,
  p_ativo boolean default true, p_ordem int default 0) returns public.empreendimentos
language plpgsql security definer set search_path = public as $$
declare v public.empreendimentos;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_id is null then
    insert into public.empreendimentos (nome, slug, sigla, ativo, ordem)
    values (trim(p_nome), lower(trim(p_slug)), upper(trim(p_sigla)), p_ativo, p_ordem) returning * into v;
  else
    update public.empreendimentos set nome = trim(p_nome), slug = lower(trim(p_slug)), sigla = upper(trim(p_sigla)),
           ativo = p_ativo, ordem = p_ordem where id = p_id returning * into v;
    if not found then raise exception 'EMPREENDIMENTO_NAO_ENCONTRADO'; end if;
  end if;
  return v;
exception when unique_violation then raise exception 'ENDERECO_OU_SIGLA_EM_USO';
end;
$$;

create or replace function public.bloquear_empreendimento(p_imobiliaria uuid, p_empreendimento uuid, p_bloquear boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_bloquear then
    insert into public.imobiliarias_bloqueios (imobiliaria_id, empreendimento_id, criado_por)
    values (p_imobiliaria, p_empreendimento, public.meu_email()) on conflict do nothing;
  else
    delete from public.imobiliarias_bloqueios where imobiliaria_id = p_imobiliaria and empreendimento_id = p_empreendimento;
  end if;
end;
$$;

revoke all on function public.salvar_empreendimento(uuid, text, text, text, boolean, int),
  public.bloquear_empreendimento(uuid, uuid, boolean) from public, anon;
grant execute on function public.salvar_empreendimento(uuid, text, text, text, boolean, int),
  public.bloquear_empreendimento(uuid, uuid, boolean) to authenticated;
-- =====================================================================
-- 110 — Tabela de vendas com versões e captações
--  * Cada tabela (versão) tem o preço de cada unidade e até 3 captações
--    (fluxos de pagamento em %). Cada unidade aponta para uma captação.
--  * Quantidade de parcelas automática: mensais, semestrais etc. vão até
--    a entrega (com folga configurável), recalculadas pelo mês da venda.
--    Uma tabela de nov/26 usada em fev/27 tem menos mensais, de valor maior.
--  * Vigência sem rotina agendada: a tabela vigente é a última com
--    "vigente_desde" já alcançado. Pode-se agendar a próxima (a partir do
--    dia X, à 0h de Brasília) ou ativar na hora. Até a virada, a tabela
--    nova fica disponível para consulta.
--  * Reajuste por % (todas ou unidades escolhidas) e carga por arquivo,
--    sempre numa tabela em rascunho ou agendada.
--  * A proposta guarda a tabela em que foi feita; só é enviada enquanto
--    essa tabela estiver vigente.
--  A primeira tabela nasce dos preços atuais (R$/m² × peso) e das
--  tabelas 1 e 2, que viram as captações 1 e 2.
-- =====================================================================

create table if not exists public.tabelas_preco (
  id                uuid primary key default gen_random_uuid(),
  empreendimento_id uuid not null default public.empreendimento_padrao() references public.empreendimentos (id),
  nome              text not null check (length(trim(nome)) >= 2),
  mes_referencia    date not null check (extract(day from mes_referencia) = 1),
  vigente_desde     timestamptz,          -- vazio = rascunho
  origem            text not null default 'manual' check (origem in ('inicial', 'arquivo', 'reajuste', 'copia', 'manual')),
  observacao        text,
  base_id           uuid references public.tabelas_preco (id) on delete set null,
  criada_por        text,
  criada_em         timestamptz not null default now(),
  ativada_por       text,
  atualizada_em     timestamptz not null default now()
);
create index if not exists tabelas_preco_emp_idx on public.tabelas_preco (empreendimento_id, vigente_desde);

create table if not exists public.captacoes (
  tabela_id uuid not null references public.tabelas_preco (id) on delete cascade,
  numero    smallint not null check (numero between 1 and 3),
  nome      text not null,
  primary key (tabela_id, numero)
);

create table if not exists public.captacoes_series (
  id            serial primary key,
  tabela_id     uuid not null,
  captacao      smallint not null,
  ordem         int not null,
  rotulo        text not null,
  periodicidade text not null check (periodicidade in ('Sinal', 'Mensais', 'Bimestrais', 'Trimestrais', 'Semestrais', 'Anuais', 'Unica', 'Financiamento')),
  percentual    numeric(10, 8) not null check (percentual > 0 and percentual <= 1),
  qtd           int check (qtd >= 1),       -- vazio = automática até a entrega
  base          text not null check (base in ('venda', 'entrega')),
  meses         int not null,                -- 1ª parcela: meses a partir da base
  fim_meses     int,                         -- automática: última parcela até entrega + fim_meses
  foreign key (tabela_id, captacao) references public.captacoes (tabela_id, numero) on delete cascade,
  unique (tabela_id, captacao, ordem),
  check (qtd is not null or fim_meses is not null)
);

create table if not exists public.tabelas_preco_itens (
  tabela_id  uuid not null references public.tabelas_preco (id) on delete cascade,
  unidade_id uuid not null references public.unidades (id) on delete cascade,
  preco      numeric(14, 2) not null check (preco > 0),
  captacao   smallint not null check (captacao between 1 and 3),
  primary key (tabela_id, unidade_id)
);

alter table public.propostas add column if not exists tabela_id uuid references public.tabelas_preco (id);

-- ---------------------------------------------------------------------
-- Vigência
-- ---------------------------------------------------------------------
create or replace function public.tabela_vigente(p_emp uuid default null) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.tabelas_preco
   where empreendimento_id = coalesce(p_emp, public.empreendimento_padrao()) and vigente_desde <= now()
   order by vigente_desde desc, criada_em desc limit 1;
$$;

create or replace function public.tabela_proxima(p_emp uuid default null) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.tabelas_preco
   where empreendimento_id = coalesce(p_emp, public.empreendimento_padrao()) and vigente_desde > now()
   order by vigente_desde limit 1;
$$;

create or replace function public.situacao_tabela(p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when t.vigente_desde is null then 'rascunho'
              when t.vigente_desde > now() then 'agendada'
              when t.id = public.tabela_vigente(t.empreendimento_id) then 'vigente'
              else 'encerrada' end
    from public.tabelas_preco t where t.id = p_id;
$$;

create or replace function public.hoje_brasilia() returns date
language sql stable set search_path = public as $$ select (now() at time zone 'America/Sao_Paulo')::date; $$;

-- ---------------------------------------------------------------------
-- Fluxo da tabela para uma unidade, no mês da venda
-- ---------------------------------------------------------------------
create or replace function public.mes_venda_tabela(p_tabela uuid, p_data date) returns date
language sql stable security definer set search_path = public as $$
  select greatest(t.mes_referencia, date_trunc('month', coalesce(p_data, public.hoje_brasilia()))::date)
    from public.tabelas_preco t where t.id = p_tabela;
$$;

create or replace function public.series_tabela(p_tabela uuid, p_unidade uuid, p_data date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  with i as (select * from public.tabelas_preco_itens where tabela_id = p_tabela and unidade_id = p_unidade),
       m as (select public.mes_venda_tabela(p_tabela, p_data) as venda, (select mes_entrega from public.comercial where id = 1) as entrega),
       s as (
         select cs.*, i.preco,
                ((case cs.base when 'venda' then m.venda else m.entrega end) + make_interval(months => cs.meses))::date as inicio,
                m.entrega
           from public.captacoes_series cs join i on cs.tabela_id = i.tabela_id and cs.captacao = i.captacao, m
       ),
       q as (
         select s.*, coalesce(s.qtd, greatest(1,
                  floor(public.meses_entre(s.inicio, (s.entrega + make_interval(months => s.fim_meses))::date)::numeric
                        / public.passo_meses(s.periodicidade))::int + 1)) as n
           from s
       )
  select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'qtd', n, 'periodicidade', periodicidade,
                                               'vencimento', inicio, 'valor', percentual * preco / n) order by ordem), '[]')
    from q;
$$;

-- preço da unidade numa tabela (padrão: a vigente do empreendimento da unidade)
drop function if exists public.preco_tabela_unidade(uuid);
create or replace function public.preco_tabela_unidade(p_unidade uuid, p_tabela uuid default null) returns numeric
language sql stable security definer set search_path = public as $$
  select i.preco from public.unidades u
    join public.tabelas_preco_itens i on i.unidade_id = u.id
                                     and i.tabela_id = coalesce(p_tabela, public.tabela_vigente(u.empreendimento_id))
   where u.id = p_unidade;
$$;

-- PV calculado pelo banco: tabela da proposta, no mês da venda
drop function if exists public.pv_proposta(uuid, jsonb, numeric);
create or replace function public.pv_proposta(p_unidade uuid, p_series jsonb, p_comissao numeric default null,
  p_tabela uuid default null, p_data date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c        public.comercial;
  v_tab    uuid;
  v_preco  numeric;
  v_venda  date;
  v_mes_sec int;
  v_vpl_t  numeric := 0;
  v_vpl_p  numeric := 0;
  v_total  numeric := 0;
  v_sinal  numeric := 0;
  v_com    numeric;
  s        record;
  k        int;
  v_mes    int;
begin
  select * into c from public.comercial where id = 1;
  v_tab := coalesce(p_tabela, public.tabela_vigente((select empreendimento_id from public.unidades where id = p_unidade)));
  v_preco := public.preco_tabela_unidade(p_unidade, v_tab);
  if v_preco is null then raise exception 'UNIDADE_SEM_PRECO'; end if;
  v_venda := public.mes_venda_tabela(v_tab, p_data);
  v_mes_sec := public.meses_entre(v_venda, c.mes_entrega) + 1;   -- financiamento: mês seguinte à entrega

  for k in 0 .. 1 loop
    for s in select (e ->> 'qtd')::int as qtd, e ->> 'periodicidade' as periodicidade, (e ->> 'vencimento')::date as vencimento,
                    (e ->> 'valor')::numeric as valor
               from jsonb_array_elements(case k when 0 then public.series_tabela(v_tab, p_unidade, p_data) else p_series end) e loop
      for v_mes in 0 .. s.qtd - 1 loop
        if k = 0 then
          v_vpl_t := v_vpl_t + s.valor / power(1 + c.taxa_vp, case when s.periodicidade = 'Financiamento' then v_mes_sec
                     else public.meses_entre(v_venda, (s.vencimento + make_interval(months => v_mes * public.passo_meses(s.periodicidade)))::date) end);
        else
          v_vpl_p := v_vpl_p + round(s.valor, 2) / power(1 + c.taxa_vp, case when s.periodicidade = 'Financiamento' then v_mes_sec
                     else public.meses_entre(v_venda, (s.vencimento + make_interval(months => v_mes * public.passo_meses(s.periodicidade)))::date) end);
          v_total := v_total + round(s.valor, 2);
          if s.periodicidade = 'Sinal' then v_sinal := v_sinal + round(s.valor, 2); end if;
        end if;
      end loop;
    end loop;
  end loop;

  v_com := round(v_total * coalesce(p_comissao, c.comissao_pct), 2);
  return jsonb_build_object(
    'tabela_id', v_tab, 'preco_tabela', round(v_preco, 2), 'total', round(v_total, 2),
    'vpl_tabela', round(v_vpl_t, 2), 'vpl_proposta', round(v_vpl_p, 2),
    'diferenca_vpl', round(v_vpl_p - v_vpl_t, 2),
    'pv_pct', round(v_vpl_p / nullif(v_vpl_t, 0) * 100, 2),
    'sinal', round(v_sinal, 2), 'comissao', v_com,
    'comissao_coberta', v_sinal * c.parte_sinal + 0.01 >= v_com,
    'calculado_pelo_banco', true);
end;
$$;

-- ---------------------------------------------------------------------
-- Carga inicial: preços atuais e tabelas 1/2 → captações 1/2
-- ---------------------------------------------------------------------
do $$
declare v_tab uuid; c public.comercial;
begin
  if exists (select 1 from public.tabelas_preco) then return; end if;
  select * into c from public.comercial where id = 1;
  if c is null or not exists (select 1 from public.unidades where tipo_preco is not null and peso is not null and tabela is not null) then return; end if;

  insert into public.tabelas_preco (nome, mes_referencia, vigente_desde, origem, criada_por, ativada_por)
  values ('Tabela ' || to_char(c.mes_tabela, 'MM/YYYY'), c.mes_tabela, now(), 'inicial', 'sistema', 'sistema')
  returning id into v_tab;

  create temp table _cap on commit drop as
    select nome as tabela, row_number() over (order by nome)::smallint as numero
      from public.tabelas_venda where nome in (select distinct tabela from public.unidades where tabela is not null) limit 3;

  insert into public.captacoes (tabela_id, numero, nome) select v_tab, numero, 'Captação ' || numero from _cap;

  insert into public.captacoes_series (tabela_id, captacao, ordem, rotulo, periodicidade, percentual, qtd, base, meses, fim_meses)
  select v_tab, x.numero, s.ordem, s.rotulo, s.periodicidade, s.percentual,
         case when x.auto then null else s.qtd end, s.base, s.meses,
         case when x.auto then least(0, x.ultima + public.passo_meses(s.periodicidade) - 1) end
    from public.tabelas_series s
    join lateral (
      select _cap.numero,
             public.meses_entre(c.mes_entrega, (c.mes_tabela + make_interval(months => s.meses + (s.qtd - 1) * public.passo_meses(s.periodicidade)))::date) as ultima,
             s.base = 'venda' and s.qtd > 1 and s.periodicidade in ('Mensais', 'Bimestrais', 'Trimestrais', 'Semestrais', 'Anuais')
             and public.meses_entre(c.mes_entrega, (c.mes_tabela + make_interval(months => s.meses + (s.qtd - 1) * public.passo_meses(s.periodicidade)))::date) <= 0 as auto
        from _cap where _cap.tabela = s.tabela) x on true
   where s.percentual > 0;

  insert into public.tabelas_preco_itens (tabela_id, unidade_id, preco, captacao)
  select v_tab, u.id,
         round(pt.preco_m2 * u.peso * u.area_privativa
               / (select avg(y.peso) from public.unidades y where y.tipo_preco = u.tipo_preco and y.peso is not null), 2),
         _cap.numero
    from public.unidades u join public.precos_tipo pt on pt.tipo = u.tipo_preco join _cap on _cap.tabela = u.tabela
   where u.area_privativa is not null and u.peso is not null;

  update public.propostas set tabela_id = v_tab where tabela_id is null;
end $$;

-- ---------------------------------------------------------------------
-- Propostas: tabela da proposta
-- ---------------------------------------------------------------------
create or replace function public.propostas_tabela() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_vig uuid;
begin
  v_vig := public.tabela_vigente((select empreendimento_id from public.unidades where id = new.unidade_id));
  if tg_op = 'INSERT' then
    new.tabela_id := v_vig;
  elsif new.tabela_id is distinct from old.tabela_id then
    -- trocar de tabela só para a vigente; a proposta passa a ser de hoje
    if new.tabela_id is distinct from v_vig then raise exception 'TABELA_NAO_VIGENTE'; end if;
    new.data_proposta := public.hoje_brasilia();
    if exists (select 1 from jsonb_array_elements(new.series) x where (x ->> 'vencimento')::date < new.data_proposta) then
      raise exception 'VENCIMENTO_ANTERIOR' using hint = 'Nenhum vencimento pode ser anterior à data da proposta.';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists propostas_tabela on public.propostas;
create trigger propostas_tabela before insert or update on public.propostas
  for each row execute function public.propostas_tabela();

create or replace function public.enviar_proposta(p_id uuid) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v   public.propostas;
  c   public.comercial;
  r   jsonb;
  v_alcada text;
begin
  select * into v from public.propostas where id = p_id for update;
  if not found or not public.acesso_pasta(v.imobiliaria_id, v.criado_por_id) then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  if v.status not in ('rascunho', 'devolvida') then raise exception 'PROPOSTA_BLOQUEADA'; end if;
  if v.pasta_id is null then raise exception 'PASTA_OBRIGATORIA' using hint = 'Vincule a pasta do comprador antes de enviar.'; end if;
  if jsonb_array_length(v.series) = 0 then raise exception 'SERIES_INVALIDAS'; end if;
  if exists (select 1 from jsonb_array_elements(v.series) s where s ->> 'periodicidade' = 'Permuta')
     and length(trim(coalesce(v.observacoes, ''))) < 5 then
    raise exception 'PERMUTA_SEM_OBSERVACAO' using hint = 'Descreva a permuta nas observações da proposta.';
  end if;
  if v.tabela_id is distinct from public.tabela_vigente(v.empreendimento_id) then
    raise exception 'TABELA_ENCERRADA' using hint = 'A tabela desta proposta não está mais vigente. Atualize para a tabela vigente.';
  end if;

  select * into c from public.comercial where id = 1;
  r := public.pv_proposta(v.unidade_id, v.series, v.comissao_pct, v.tabela_id, v.data_proposta);
  v_alcada := case
    when c.alcada_automatica and (r ->> 'pv_pct')::numeric >= c.alcada_auto_pv and (r ->> 'comissao_coberta')::boolean then 'automatica'
    when (r ->> 'pv_pct')::numeric >= c.alcada_vendas_pv then 'vendas'
    else 'admin' end;

  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas
     set status = 'enviada', enviada_em = now(), motivo_analise = null, alcada = v_alcada,
         resumo = coalesce(resumo, '{}') || r
   where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);

  if v_alcada = 'automatica' then
    v := public.aprovar_proposta_interno(p_id, 'Aprovação automática (PV ' || (r ->> 'pv_pct') || '%)');
  end if;
  return v;
end;
$$;

-- ---------------------------------------------------------------------
-- Gestão das tabelas (administrador)
-- ---------------------------------------------------------------------
create or replace function public.tabela_para_editar(p_tabela uuid) returns public.tabelas_preco
language plpgsql security definer set search_path = public as $$
declare t public.tabelas_preco;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into t from public.tabelas_preco where id = p_tabela for update;
  if not found then raise exception 'TABELA_NAO_ENCONTRADA'; end if;
  if t.vigente_desde is not null and t.vigente_desde <= now() then
    raise exception 'TABELA_JA_VIGENTE' using hint = 'Tabela vigente ou encerrada não muda. Crie uma nova tabela.';
  end if;
  return t;
end;
$$;

-- nova tabela: cópia da base (padrão: a vigente), com reajuste opcional
create or replace function public.nova_tabela(p_nome text, p_mes date, p_base uuid default null,
  p_reajuste numeric default null, p_unidades uuid[] default null, p_emp uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_emp uuid := coalesce(p_emp, public.empreendimento_padrao()); v_base uuid; v_id uuid;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_reajuste is not null and (p_reajuste <= -0.5 or p_reajuste > 1) then raise exception 'REAJUSTE_INVALIDO'; end if;
  v_base := coalesce(p_base, public.tabela_vigente(v_emp));
  insert into public.tabelas_preco (empreendimento_id, nome, mes_referencia, origem, base_id, criada_por)
  values (v_emp, trim(p_nome), date_trunc('month', p_mes)::date,
          case when v_base is null then 'manual' when p_reajuste is not null then 'reajuste' else 'copia' end, v_base, public.meu_email())
  returning id into v_id;
  if v_base is not null then
    insert into public.captacoes (tabela_id, numero, nome) select v_id, numero, nome from public.captacoes where tabela_id = v_base;
    insert into public.captacoes_series (tabela_id, captacao, ordem, rotulo, periodicidade, percentual, qtd, base, meses, fim_meses)
    select v_id, captacao, ordem, rotulo, periodicidade, percentual, qtd, base, meses, fim_meses from public.captacoes_series where tabela_id = v_base;
    insert into public.tabelas_preco_itens (tabela_id, unidade_id, preco, captacao)
    select v_id, unidade_id,
           case when p_reajuste is not null and (p_unidades is null or unidade_id = any (p_unidades)) then round(preco * (1 + p_reajuste), 2) else preco end,
           captacao
      from public.tabelas_preco_itens where tabela_id = v_base;
  end if;
  return v_id;
end;
$$;

create or replace function public.salvar_dados_tabela(p_tabela uuid, p_nome text, p_mes date, p_observacao text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.tabela_para_editar(p_tabela);
  update public.tabelas_preco set nome = trim(p_nome), mes_referencia = date_trunc('month', p_mes)::date,
         observacao = nullif(trim(coalesce(p_observacao, '')), ''), atualizada_em = now()
   where id = p_tabela;
end;
$$;

-- reajuste por % (todas as unidades ou as escolhidas)
create or replace function public.reajustar_tabela(p_tabela uuid, p_pct numeric, p_unidades uuid[] default null) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform public.tabela_para_editar(p_tabela);
  if p_pct is null or p_pct <= -0.5 or p_pct > 1 or p_pct = 0 then raise exception 'REAJUSTE_INVALIDO'; end if;
  update public.tabelas_preco_itens set preco = round(preco * (1 + p_pct), 2)
   where tabela_id = p_tabela and (p_unidades is null or unidade_id = any (p_unidades));
  get diagnostics n = row_count;
  update public.tabelas_preco set atualizada_em = now() where id = p_tabela;
  return n;
end;
$$;

-- preço/captação de uma unidade
create or replace function public.definir_item_tabela(p_tabela uuid, p_unidade uuid, p_preco numeric, p_captacao smallint)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.tabela_para_editar(p_tabela);
  if p_preco is null or p_preco <= 0 then raise exception 'PRECO_INVALIDO'; end if;
  if not exists (select 1 from public.captacoes where tabela_id = p_tabela and numero = p_captacao) then raise exception 'CAPTACAO_INEXISTENTE'; end if;
  insert into public.tabelas_preco_itens (tabela_id, unidade_id, preco, captacao) values (p_tabela, p_unidade, round(p_preco, 2), p_captacao)
  on conflict (tabela_id, unidade_id) do update set preco = excluded.preco, captacao = excluded.captacao;
  update public.tabelas_preco set atualizada_em = now() where id = p_tabela;
end;
$$;

-- carga por arquivo: [{numero, preco, captacao, area?, tipologia?}]
create or replace function public.importar_tabela(p_tabela uuid, p_linhas jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  t public.tabelas_preco;
  erros text[] := '{}';
  l record;
  n_precos int := 0; n_unid int := 0;
begin
  t := public.tabela_para_editar(p_tabela);
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then raise exception 'ARQUIVO_VAZIO'; end if;

  for l in
    select x.numero, x.preco, x.captacao, x.area, nullif(trim(x.tipologia), '') as tipologia, u.id as unidade_id,
           count(*) over (partition by x.numero) as repeticoes
      from jsonb_to_recordset(p_linhas) as x(numero text, preco numeric, captacao smallint, area numeric, tipologia text)
      left join public.unidades u on u.numero = trim(x.numero) and u.empreendimento_id = t.empreendimento_id
  loop
    if l.unidade_id is null then erros := erros || ('Unidade ' || coalesce(l.numero, '?') || ' não existe');
    elsif l.repeticoes > 1 then erros := erros || ('Unidade ' || l.numero || ' repetida');
    elsif l.preco is null or l.preco <= 0 then erros := erros || ('Unidade ' || l.numero || ': preço inválido');
    elsif not exists (select 1 from public.captacoes where tabela_id = p_tabela and numero = l.captacao) then
      erros := erros || ('Unidade ' || l.numero || ': captação ' || coalesce(l.captacao::text, 'vazia') || ' não cadastrada');
    elsif l.area is not null and l.area <= 0 then erros := erros || ('Unidade ' || l.numero || ': área inválida');
    end if;
  end loop;
  if cardinality(erros) > 0 then
    raise exception 'ARQUIVO_INVALIDO' using detail = array_to_string(erros[1:20], '; ');
  end if;

  insert into public.tabelas_preco_itens (tabela_id, unidade_id, preco, captacao)
  select p_tabela, u.id, round(x.preco, 2), x.captacao
    from jsonb_to_recordset(p_linhas) as x(numero text, preco numeric, captacao smallint)
    join public.unidades u on u.numero = trim(x.numero) and u.empreendimento_id = t.empreendimento_id
  on conflict (tabela_id, unidade_id) do update set preco = excluded.preco, captacao = excluded.captacao;
  get diagnostics n_precos = row_count;

  -- informações da unidade (área e tipologia), quando vierem no arquivo
  update public.unidades u set
         area_privativa = coalesce(x.area, u.area_privativa),
         tipologia = coalesce(nullif(trim(x.tipologia), ''), u.tipologia)
    from jsonb_to_recordset(p_linhas) as x(numero text, area numeric, tipologia text)
   where u.numero = trim(x.numero) and u.empreendimento_id = t.empreendimento_id
     and ((x.area is not null and x.area is distinct from u.area_privativa)
       or (nullif(trim(x.tipologia), '') is not null and trim(x.tipologia) is distinct from u.tipologia));
  get diagnostics n_unid = row_count;

  update public.tabelas_preco set origem = case when origem = 'manual' then 'arquivo' else origem end, atualizada_em = now() where id = p_tabela;
  return jsonb_build_object('precos', n_precos, 'unidades_atualizadas', n_unid);
end;
$$;

-- captações (até 3), cada uma somando 100%
create or replace function public.salvar_captacoes(p_tabela uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare c jsonb; s jsonb; v_soma numeric; v_ordem int;
begin
  perform public.tabela_para_editar(p_tabela);
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) not between 1 and 3 then raise exception 'CAPTACOES_1_A_3'; end if;
  for c in select * from jsonb_array_elements(p) loop
    if (c ->> 'numero')::int not between 1 and 3 then raise exception 'CAPTACOES_1_A_3'; end if;
    select coalesce(sum((x ->> 'percentual')::numeric), 0) into v_soma from jsonb_array_elements(c -> 'series') x;
    if abs(v_soma - 1) > 0.000001 then
      raise exception 'CAPTACAO_NAO_SOMA_100' using detail = coalesce(c ->> 'nome', 'Captação ' || (c ->> 'numero')) || ' soma ' || round(v_soma * 100, 4) || '%';
    end if;
  end loop;
  if exists (select 1 from public.tabelas_preco_itens i where i.tabela_id = p_tabela
              and i.captacao not in (select (x ->> 'numero')::int from jsonb_array_elements(p) x)) then
    raise exception 'CAPTACAO_EM_USO' using hint = 'Há unidades ligadas a uma captação removida. Troque a captação delas antes.';
  end if;

  delete from public.captacoes where tabela_id = p_tabela;
  for c in select * from jsonb_array_elements(p) loop
    insert into public.captacoes (tabela_id, numero, nome)
    values (p_tabela, (c ->> 'numero')::int, coalesce(nullif(trim(c ->> 'nome'), ''), 'Captação ' || (c ->> 'numero')));
    v_ordem := 0;
    for s in select * from jsonb_array_elements(c -> 'series') loop
      v_ordem := v_ordem + 1;
      insert into public.captacoes_series (tabela_id, captacao, ordem, rotulo, periodicidade, percentual, qtd, base, meses, fim_meses)
      values (p_tabela, (c ->> 'numero')::int, v_ordem, coalesce(nullif(trim(s ->> 'rotulo'), ''), s ->> 'periodicidade'), s ->> 'periodicidade',
              (s ->> 'percentual')::numeric, nullif(s ->> 'qtd', '')::int, s ->> 'base', (s ->> 'meses')::int,
              case when nullif(s ->> 'qtd', '') is null then coalesce(nullif(s ->> 'fim_meses', '')::int, 0) end);
    end loop;
  end loop;
  update public.tabelas_preco set atualizada_em = now() where id = p_tabela;
end;
$$;

-- ativar agora (p_data vazio ou hoje) ou agendar para o dia, à 0h de Brasília
create or replace function public.ativar_tabela(p_tabela uuid, p_data date default null) returns public.tabelas_preco
language plpgsql security definer set search_path = public as $$
declare t public.tabelas_preco; v_quando timestamptz; v_faltam int; v_cap record;
begin
  t := public.tabela_para_editar(p_tabela);
  if not exists (select 1 from public.captacoes where tabela_id = p_tabela) then raise exception 'TABELA_SEM_CAPTACAO'; end if;
  for v_cap in select c.nome, coalesce(sum(s.percentual), 0) as soma from public.captacoes c
                 left join public.captacoes_series s on s.tabela_id = c.tabela_id and s.captacao = c.numero
                where c.tabela_id = p_tabela group by c.nome loop
    if abs(v_cap.soma - 1) > 0.000001 then raise exception 'CAPTACAO_NAO_SOMA_100' using detail = v_cap.nome; end if;
  end loop;
  select count(*) into v_faltam from public.unidades u
   where u.empreendimento_id = t.empreendimento_id
     and not exists (select 1 from public.tabelas_preco_itens i where i.tabela_id = p_tabela and i.unidade_id = u.id);
  if v_faltam > 0 then raise exception 'TABELA_INCOMPLETA' using detail = v_faltam || ' unidade(s) sem preço'; end if;

  if p_data is null or p_data <= public.hoje_brasilia() then
    v_quando := now();
  else
    v_quando := p_data::timestamp at time zone 'America/Sao_Paulo';
    if exists (select 1 from public.tabelas_preco where empreendimento_id = t.empreendimento_id and id <> p_tabela and vigente_desde > now()) then
      raise exception 'JA_EXISTE_TABELA_AGENDADA' using hint = 'Cancele o agendamento da outra tabela antes.';
    end if;
  end if;
  update public.tabelas_preco set vigente_desde = v_quando, ativada_por = public.meu_email(), atualizada_em = now()
   where id = p_tabela returning * into t;
  -- ativada na hora: qualquer agendamento anterior a ela perde o sentido
  if v_quando <= now() then
    update public.tabelas_preco set vigente_desde = null
     where empreendimento_id = t.empreendimento_id and id <> p_tabela and vigente_desde > now();
  end if;
  return t;
end;
$$;

create or replace function public.cancelar_agendamento(p_tabela uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.tabela_para_editar(p_tabela);
  update public.tabelas_preco set vigente_desde = null, ativada_por = null, atualizada_em = now() where id = p_tabela;
end;
$$;

create or replace function public.excluir_tabela(p_tabela uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.tabelas_preco;
begin
  t := public.tabela_para_editar(p_tabela);
  if t.vigente_desde is not null then raise exception 'TABELA_AGENDADA' using hint = 'Cancele o agendamento antes de excluir.'; end if;
  if exists (select 1 from public.propostas where tabela_id = p_tabela) then raise exception 'TABELA_COM_PROPOSTAS'; end if;
  delete from public.tabelas_preco where id = p_tabela;
end;
$$;

-- ---------------------------------------------------------------------
-- Leitura
-- ---------------------------------------------------------------------
create or replace view public.tabelas_preco_resumo with (security_invoker = true) as
select t.id, t.empreendimento_id, t.nome, t.mes_referencia, t.vigente_desde, t.origem, t.observacao, t.base_id,
       t.criada_por, t.criada_em, t.ativada_por, t.atualizada_em,
       case when t.vigente_desde is null then 'rascunho'
            when t.vigente_desde > now() then 'agendada'
            when t.id = public.tabela_vigente(t.empreendimento_id) then 'vigente'
            else 'encerrada' end as situacao,
       (select count(*) from public.tabelas_preco_itens i where i.tabela_id = t.id) as unidades,
       (select coalesce(sum(i.preco), 0) from public.tabelas_preco_itens i where i.tabela_id = t.id) as vgv
  from public.tabelas_preco t;

alter table public.tabelas_preco enable row level security;
alter table public.captacoes enable row level security;
alter table public.captacoes_series enable row level security;
alter table public.tabelas_preco_itens enable row level security;
revoke all on public.tabelas_preco, public.captacoes, public.captacoes_series, public.tabelas_preco_itens, public.tabelas_preco_resumo from anon, authenticated;
grant select on public.tabelas_preco, public.captacoes, public.captacoes_series, public.tabelas_preco_itens, public.tabelas_preco_resumo to authenticated;

-- equipe vê todas; corretores e imobiliárias, só as publicadas (vigente, agendada e antigas) dos empreendimentos liberados
drop policy if exists tabelas_preco_leitura on public.tabelas_preco;
create policy tabelas_preco_leitura on public.tabelas_preco for select
  using (public.eh_equipe() or (auth.uid() is not null and vigente_desde is not null and public.acesso_empreendimento(empreendimento_id)));
drop policy if exists captacoes_leitura on public.captacoes;
create policy captacoes_leitura on public.captacoes for select using (exists (select 1 from public.tabelas_preco t where t.id = tabela_id));
drop policy if exists captacoes_series_leitura on public.captacoes_series;
create policy captacoes_series_leitura on public.captacoes_series for select using (exists (select 1 from public.tabelas_preco t where t.id = tabela_id));
drop policy if exists tabelas_itens_leitura on public.tabelas_preco_itens;
create policy tabelas_itens_leitura on public.tabelas_preco_itens for select using (exists (select 1 from public.tabelas_preco t where t.id = tabela_id));

revoke all on function public.nova_tabela(text, date, uuid, numeric, uuid[], uuid), public.salvar_dados_tabela(uuid, text, date, text),
  public.reajustar_tabela(uuid, numeric, uuid[]), public.definir_item_tabela(uuid, uuid, numeric, smallint),
  public.importar_tabela(uuid, jsonb), public.salvar_captacoes(uuid, jsonb), public.ativar_tabela(uuid, date),
  public.cancelar_agendamento(uuid), public.excluir_tabela(uuid), public.tabela_para_editar(uuid),
  public.pv_proposta(uuid, jsonb, numeric, uuid, date), public.preco_tabela_unidade(uuid, uuid),
  public.series_tabela(uuid, uuid, date), public.tabela_vigente(uuid), public.tabela_proxima(uuid),
  public.situacao_tabela(uuid), public.mes_venda_tabela(uuid, date), public.propostas_tabela() from public, anon;
grant execute on function public.nova_tabela(text, date, uuid, numeric, uuid[], uuid), public.salvar_dados_tabela(uuid, text, date, text),
  public.reajustar_tabela(uuid, numeric, uuid[]), public.definir_item_tabela(uuid, uuid, numeric, smallint),
  public.importar_tabela(uuid, jsonb), public.salvar_captacoes(uuid, jsonb), public.ativar_tabela(uuid, date),
  public.cancelar_agendamento(uuid), public.excluir_tabela(uuid),
  public.pv_proposta(uuid, jsonb, numeric, uuid, date), public.preco_tabela_unidade(uuid, uuid),
  public.series_tabela(uuid, uuid, date), public.tabela_vigente(uuid), public.tabela_proxima(uuid),
  public.situacao_tabela(uuid), public.mes_venda_tabela(uuid, date) to authenticated;
