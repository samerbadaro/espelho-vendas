-- =====================================================================
-- 019 — Propostas (v2)
--  * Parâmetros comerciais do empreendimento (mês da tabela, entrega,
--    taxa do VPL, comissão, textos da carta proposta).
--  * Preço do m² por tipo, peso e tabela de cada unidade.
--  * Tabelas de venda (séries com % e calendário).
--  * Propostas: rascunho → enviada → aprovada / recusada / devolvida.
--    A aprovação leva a unidade para "Proposta recebida" no espelho.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Parâmetros comerciais (linha única)
-- ---------------------------------------------------------------------
create table public.comercial (
  id                 int primary key default 1 check (id = 1),
  mes_tabela         date not null default date_trunc('month', now())::date,  -- 1º dia do mês
  mes_entrega        date not null default (date_trunc('month', now()) + interval '48 months')::date,
  taxa_vp            numeric(8, 6) not null default 0.007 check (taxa_vp >= 0 and taxa_vp < 0.1),   -- ao mês
  comissao_pct       numeric(8, 6) not null default 0.05 check (comissao_pct >= 0 and comissao_pct < 0.3),
  parte_sinal        numeric(8, 6) not null default 0.7 check (parte_sinal > 0 and parte_sinal <= 1), -- do sinal para a comissão
  limite_captacao    numeric(8, 6) not null default -0.15,
  dias_vencimento    int[] not null default '{5,10,15,20}',
  vendedora          text,          -- razão social da SPE (carta proposta)
  vendedora_cnpj     text,
  cidade_carta       text,          -- local de assinatura da carta
  forma_sinal        text not null default 'PIX / transferência',
  forma_parcelas     text not null default 'Boleto',
  validade_dias      int not null default 5 check (validade_dias between 1 and 60),
  texto_abertura     text not null default 'Através desta o(s) Proponente(s) abaixo qualificado(s) formaliza(m) proposta para aquisição do imóvel descrito, cujos termos e condições seguem para avaliação da Vendedora.',
  texto_condicoes    text not null default '',
  atualizado_em      timestamptz not null default now()
);
insert into public.comercial default values;

create table public.precos_tipo (
  tipo     text primary key,
  preco_m2 numeric(12, 2) not null check (preco_m2 > 0)
);

create table public.tabelas_venda (
  nome text primary key
);

create table public.tabelas_series (
  id           serial primary key,
  tabela       text not null references public.tabelas_venda (nome) on update cascade on delete cascade,
  ordem        int not null,
  rotulo       text not null,
  periodicidade text not null check (periodicidade in ('Sinal', 'Mensais', 'Semestrais', 'Anuais', 'Unica', 'Financiamento')),
  qtd          int not null check (qtd >= 1),
  percentual   numeric(10, 8) not null check (percentual >= 0 and percentual <= 1),  -- da série inteira
  base         text not null check (base in ('venda', 'entrega')),
  meses        int not null,                                                          -- a partir da base
  unique (tabela, ordem)
);

alter table public.unidades
  add column if not exists tipo_preco text references public.precos_tipo (tipo) on update cascade,
  add column if not exists peso       numeric(10, 6) check (peso > 0),
  add column if not exists tabela     text references public.tabelas_venda (nome) on update cascade;

-- leitura: qualquer login (corretores precisam da tabela para montar a proposta)
alter table public.comercial      enable row level security;
alter table public.precos_tipo    enable row level security;
alter table public.tabelas_venda  enable row level security;
alter table public.tabelas_series enable row level security;
revoke all on public.comercial, public.precos_tipo, public.tabelas_venda, public.tabelas_series from anon, authenticated;
grant select on public.comercial, public.precos_tipo, public.tabelas_venda, public.tabelas_series to authenticated;
grant insert, update, delete on public.precos_tipo, public.tabelas_venda, public.tabelas_series to authenticated;
grant update on public.comercial to authenticated;
grant usage on sequence public.tabelas_series_id_seq to authenticated;
create policy comercial_leitura on public.comercial for select using (auth.uid() is not null);
create policy comercial_edicao on public.comercial for update using (public.eh_admin()) with check (public.eh_admin());
create policy precos_leitura on public.precos_tipo for select using (auth.uid() is not null);
create policy precos_edicao on public.precos_tipo for all using (public.eh_admin()) with check (public.eh_admin());
create policy tabelas_leitura on public.tabelas_venda for select using (auth.uid() is not null);
create policy tabelas_edicao on public.tabelas_venda for all using (public.eh_admin()) with check (public.eh_admin());
create policy series_leitura on public.tabelas_series for select using (auth.uid() is not null);
create policy series_edicao on public.tabelas_series for all using (public.eh_admin()) with check (public.eh_admin());

-- ---------------------------------------------------------------------
-- Propostas
-- ---------------------------------------------------------------------
create sequence public.propostas_codigo_seq;

create table public.propostas (
  id              uuid primary key default gen_random_uuid(),
  codigo          text not null unique default 'PR-' || lpad(nextval('public.propostas_codigo_seq')::text, 4, '0'),
  unidade_id      uuid not null references public.unidades (id),
  pasta_id        uuid references public.pastas (id),
  imobiliaria_id  uuid references public.imobiliarias (id) default public.minha_imobiliaria(),
  criado_por_id   uuid default auth.uid(),
  criado_por      text,
  data_proposta   date not null default (now() at time zone 'America/Sao_Paulo')::date,
  status          text not null default 'rascunho'
                  check (status in ('rascunho', 'enviada', 'aprovada', 'recusada', 'devolvida', 'cancelada')),
  series          jsonb not null default '[]',   -- [{qtd, periodicidade, vencimento, valor}]
  resumo          jsonb not null default '{}',   -- valores calculados na tela (tabela × proposta, comissão)
  observacoes     text,
  comissao_pct    numeric(8, 6),
  parte_sinal     numeric(8, 6),
  motivo_analise  text,
  analisada_por   text,
  analisada_em    timestamptz,
  enviada_em      timestamptz,
  versao          int not null default 1,
  criada_em       timestamptz not null default now(),
  atualizada_em   timestamptz not null default now()
);
create index propostas_unidade_idx on public.propostas (unidade_id);
create index propostas_pasta_idx on public.propostas (pasta_id);
create index propostas_imob_idx on public.propostas (imobiliaria_id, criado_por_id);

create table public.historico_propostas (
  id            bigint generated always as identity primary key,
  proposta_id   uuid not null references public.propostas (id) on delete cascade,
  acao          text not null,
  detalhes      jsonb,
  usuario_email text,
  criado_em     timestamptz not null default now()
);
create index historico_propostas_idx on public.historico_propostas (proposta_id, criado_em desc);

-- Regras aplicadas em toda gravação
create function public.propostas_antes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_serie jsonb;
  v_email text;
begin
  select email into v_email from public.perfis where user_id = auth.uid();
  if tg_op = 'INSERT' then
    new.data_proposta := (now() at time zone 'America/Sao_Paulo')::date;  -- dia da criação, no horário de Brasília
    new.criado_por_id := auth.uid();
    new.criado_por := v_email;
    new.status := 'rascunho';
    if not public.eh_equipe() then new.imobiliaria_id := public.minha_imobiliaria(); end if;
  else
    -- campos que só mudam pelas funções de envio e análise
    if current_setting('propostas.funcao', true) is distinct from 'sim' then
      new.status := old.status; new.motivo_analise := old.motivo_analise;
      new.analisada_por := old.analisada_por; new.analisada_em := old.analisada_em; new.enviada_em := old.enviada_em;
      if old.status not in ('rascunho', 'devolvida') and not public.eh_equipe() then
        raise exception 'PROPOSTA_BLOQUEADA' using hint = 'Só é possível editar rascunhos ou propostas devolvidas.';
      end if;
    end if;
    new.data_proposta := old.data_proposta;
    new.criado_por_id := old.criado_por_id; new.criado_por := old.criado_por;
    new.imobiliaria_id := case when public.eh_equipe() then new.imobiliaria_id else old.imobiliaria_id end;
    new.versao := old.versao + 1;
    new.atualizada_em := now();
  end if;

  if new.pasta_id is not null and not public.pode_ver_pasta(new.pasta_id) then
    raise exception 'PASTA_NAO_ENCONTRADA';
  end if;
  if jsonb_typeof(new.series) <> 'array' then raise exception 'SERIES_INVALIDAS'; end if;
  -- nenhum vencimento antes da data da proposta (hoje, ou a data em que ela foi salva)
  for v_serie in select * from jsonb_array_elements(new.series) loop
    if (v_serie ->> 'vencimento')::date < new.data_proposta then
      raise exception 'VENCIMENTO_ANTERIOR' using hint = 'Nenhum vencimento pode ser anterior à data da proposta.';
    end if;
    if coalesce((v_serie ->> 'qtd')::int, 0) < 1 or coalesce((v_serie ->> 'valor')::numeric, 0) <= 0 then
      raise exception 'SERIE_INVALIDA';
    end if;
  end loop;
  return new;
end;
$$;
create trigger propostas_antes before insert or update on public.propostas
  for each row execute function public.propostas_antes();

create function public.propostas_depois() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.historico_propostas (proposta_id, acao, detalhes, usuario_email)
  values (new.id,
          case when tg_op = 'INSERT' then 'Proposta criada'
               when new.status <> old.status then 'Status: ' || new.status
               else 'Proposta editada' end,
          jsonb_strip_nulls(jsonb_build_object(
            'total', new.resumo -> 'total', 'pv', new.resumo -> 'pv_pct', 'motivo', new.motivo_analise)),
          (select email from public.perfis where user_id = auth.uid()));
  return new;
end;
$$;
create trigger propostas_depois after insert or update on public.propostas
  for each row execute function public.propostas_depois();

alter table public.propostas enable row level security;
alter table public.historico_propostas enable row level security;
revoke all on public.propostas, public.historico_propostas from anon, authenticated;
grant select, insert, update on public.propostas to authenticated;
grant usage on sequence public.propostas_codigo_seq to authenticated;
grant select on public.historico_propostas to authenticated;
create policy propostas_leitura on public.propostas for select
  using (public.acesso_pasta(imobiliaria_id, criado_por_id));
create policy propostas_inclusao on public.propostas for insert
  with check (public.eh_equipe() or public.minha_imobiliaria() is not null);
create policy propostas_edicao on public.propostas for update
  using (public.acesso_pasta(imobiliaria_id, criado_por_id))
  with check (public.acesso_pasta(imobiliaria_id, criado_por_id));
create policy historico_propostas_leitura on public.historico_propostas for select
  using (exists (select 1 from public.propostas p where p.id = proposta_id and public.acesso_pasta(p.imobiliaria_id, p.criado_por_id)));

-- ---------------------------------------------------------------------
-- Enviar para análise (corretor, imobiliária ou equipe)
-- ---------------------------------------------------------------------
create function public.enviar_proposta(p_id uuid) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare v public.propostas;
begin
  select * into v from public.propostas where id = p_id for update;
  if not found or not public.acesso_pasta(v.imobiliaria_id, v.criado_por_id) then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  if v.status not in ('rascunho', 'devolvida') then raise exception 'PROPOSTA_BLOQUEADA'; end if;
  if v.pasta_id is null then raise exception 'PASTA_OBRIGATORIA' using hint = 'Vincule a pasta do comprador antes de enviar.'; end if;
  if jsonb_array_length(v.series) = 0 then raise exception 'SERIES_INVALIDAS'; end if;
  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas set status = 'enviada', enviada_em = now(), motivo_analise = null where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);
  return v;
end;
$$;

-- ---------------------------------------------------------------------
-- Análise (somente equipe): aprovar, recusar ou devolver para ajuste.
-- Aprovar leva a unidade para "Proposta recebida" no espelho, com o
-- valor total e o PV (% do VPL da tabela).
-- ---------------------------------------------------------------------
create function public.analisar_proposta(p_id uuid, p_decisao text, p_motivo text default null) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v public.propostas;
  u public.unidades;
  v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_decisao not in ('aprovada', 'recusada', 'devolvida', 'cancelada') then raise exception 'DECISAO_INVALIDA'; end if;
  select * into v from public.propostas where id = p_id for update;
  if not found then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  if p_decisao in ('recusada', 'devolvida', 'cancelada') and v_motivo is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  if p_decisao in ('aprovada', 'recusada', 'devolvida') and v.status <> 'enviada' then raise exception 'PROPOSTA_NAO_ENVIADA'; end if;

  if p_decisao = 'aprovada' then
    -- uma proposta aprovada por unidade
    if exists (select 1 from public.propostas where unidade_id = v.unidade_id and status = 'aprovada' and id <> v.id) then
      raise exception 'UNIDADE_COM_PROPOSTA_APROVADA';
    end if;
    select * into u from public.unidades where id = v.unidade_id;
    if u.status in ('disponivel', 'reservada') then
      perform public.alterar_status(u.id, 'proposta', u.versao, null, null, null, null,
        (v.resumo ->> 'total')::numeric, round((v.resumo ->> 'pv_pct')::numeric, 2), v.pasta_id);
    elsif u.status <> 'proposta' then
      raise exception 'UNIDADE_INDISPONIVEL' using hint = 'A unidade está em outra etapa no espelho.';
    end if;
  end if;

  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas
     set status = p_decisao, motivo_analise = v_motivo,
         analisada_por = (select email from public.perfis where user_id = auth.uid()), analisada_em = now()
   where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);
  return v;
end;
$$;

revoke all on function public.enviar_proposta(uuid), public.analisar_proposta(uuid, text, text) from public, anon;
grant execute on function public.enviar_proposta(uuid), public.analisar_proposta(uuid, text, text) to authenticated;
