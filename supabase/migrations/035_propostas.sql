-- =====================================================================
-- 035 — Propostas (trazidas da v2, já validadas no ambiente de testes)
--  Junta, nesta ordem, as migrações 101 a 105 da v2:
--   101 propostas, tabelas de venda e preço por tipo
--   102 dados comerciais do Duo Haus (preço do m², tabelas, peso das unidades)
--   103 carta proposta no modelo novo
--   104 séries Bimestrais, Trimestrais e Permuta
--   105 alçadas de aprovação e PV calculado pelo banco
--  Fica fora: fila de escolha, painéis, meeting público e vários empreendimentos.
--
--  O que muda no que já existe (nada além disto):
--   * unidades: 3 colunas novas (tipo_preco, peso, tabela), só preenchidas.
--   * alterar_status: idêntica à 016, com UMA linha a mais, que deixa a
--     aprovação automática da proposta mudar o status (o navegador não
--     consegue ligar essa chave).
--   * config.modulo_propostas: começa DESLIGADO. Enquanto estiver desligado,
--     ninguém de fora da equipe cria proposta.
--
-- Executar uma única vez no SQL Editor do Supabase, DEPOIS do backup
-- (035_backup_antes.sql).
-- =====================================================================

begin;  -- tudo ou nada: se qualquer passo falhar, nada fica gravado

alter table public.config add column if not exists modulo_propostas boolean not null default false;


-- ####################################################################
-- origem: v2/101_propostas.sql
-- ####################################################################
-- =====================================================================
-- 101 — Propostas (v2)
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

-- ####################################################################
-- origem: v2/102_dados_comerciais_duohaus.sql
-- ####################################################################
-- =====================================================================
-- 102 — Dados comerciais do Duo Haus (planilha Compacto_Studio.xlsm)
--  * Mês da tabela nov/2026, entrega out/2030, VPL a 0,7% a.m.
--  * R$/m²: tipo I (poente) 11.900; tipo II (nascente) 12.500
--  * Tabela 1 e Tabela 2, com o calendário usado na aba PV
--  * Peso e tabela de cada unidade.
--    A planilha numera os andares de 2 a 18 sem o 13º; o espelho vai de 2 a 17
--    com o 13º. Aqui a correspondência é pela ordem do andar (14º da planilha
--    = 13º do espelho ... 18º da planilha = 17º do espelho).
-- Pode ser rodado de novo para recarregar os valores.
-- =====================================================================

update public.comercial set
  mes_tabela = '2026-11-01', mes_entrega = '2030-10-01', taxa_vp = 0.007,
  comissao_pct = 0.0525, parte_sinal = 0.7, limite_captacao = -0.15,
  cidade_carta = 'Rio Verde - GO',
  texto_condicoes = $t$1. A partir desta data, até o mês da liberação do Habite-se, os valores serão reajustados pelo INCC (Índice Nacional da Construção Civil). A partir do 1º dia do mês seguinte à expedição do Habite-se, até a quitação, os valores serão reajustados mensalmente pelo IGP-M, acrescidos de juros de 1% ao mês.
2. Esta proposta será analisada pela Vendedora, que poderá recusá-la, ainda que imotivadamente.
3. A concessão do financiamento bancário está sujeita à análise de crédito e aos critérios do banco financiador. É de exclusiva responsabilidade do(s) Proponente(s) obter os recursos para a parcela de financiamento, por crédito bancário ou recursos próprios.
4. Os honorários de intermediação imobiliária serão pagos com o sinal de negócio definido nesta proposta. Em caso de recusa da proposta ou de não compensação do sinal, esta proposta perde a eficácia e a unidade fica liberada para comercialização.$t$,
  atualizado_em = now()
where id = 1;

insert into public.precos_tipo (tipo, preco_m2) values ('I', 11900), ('II', 12500)
on conflict (tipo) do update set preco_m2 = excluded.preco_m2;

insert into public.tabelas_venda (nome) values ('TABELA 1'), ('TABELA 2') on conflict do nothing;
delete from public.tabelas_series where tabela in ('TABELA 1', 'TABELA 2');
insert into public.tabelas_series (tabela, ordem, rotulo, periodicidade, qtd, percentual, base, meses) values
  ('TABELA 1', 1, 'Ato', 'Sinal', 1, 0.04, 'venda', 0),
  ('TABELA 1', 2, '30 / 60 / 90', 'Sinal', 3, 0.04, 'venda', 1),
  ('TABELA 1', 3, 'Mensais', 'Mensais', 44, 0.06, 'venda', 4),
  ('TABELA 1', 4, 'Semestrais', 'Semestrais', 7, 0.12, 'venda', 5),
  ('TABELA 1', 5, 'Única', 'Unica', 1, 0.04, 'entrega', -3),
  ('TABELA 1', 6, 'Financiamento', 'Financiamento', 1, 0.70, 'entrega', 1),
  ('TABELA 2', 1, 'Ato', 'Sinal', 1, 0.04, 'venda', 0),
  ('TABELA 2', 2, '30 / 60 / 90', 'Sinal', 3, 0.04, 'venda', 1),
  ('TABELA 2', 3, 'Mensais', 'Mensais', 44, 0.065, 'venda', 4),
  ('TABELA 2', 4, 'Semestrais', 'Semestrais', 7, 0.155, 'venda', 5),
  ('TABELA 2', 5, 'Única', 'Unica', 1, 0.05, 'entrega', -3),
  ('TABELA 2', 6, 'Financiamento', 'Financiamento', 1, 0.65, 'entrega', 1);

update public.unidades u set tipo_preco = d.tipo, peso = d.peso, tabela = d.tabela
from (values
  ('201', 'I', 0.92, 'TABELA 1'),
  ('202', 'I', 0.92, 'TABELA 1'),
  ('203', 'II', 0.92, 'TABELA 2'),
  ('204', 'II', 0.92, 'TABELA 2'),
  ('205', 'II', 0.92, 'TABELA 2'),
  ('206', 'II', 0.92, 'TABELA 2'),
  ('207', 'II', 0.92, 'TABELA 2'),
  ('208', 'II', 0.92, 'TABELA 2'),
  ('301', 'I', 0.925, 'TABELA 1'),
  ('302', 'I', 0.925, 'TABELA 1'),
  ('303', 'II', 0.925, 'TABELA 2'),
  ('304', 'II', 0.925, 'TABELA 2'),
  ('305', 'II', 0.925, 'TABELA 2'),
  ('306', 'II', 0.925, 'TABELA 2'),
  ('307', 'II', 0.925, 'TABELA 2'),
  ('308', 'II', 0.925, 'TABELA 2'),
  ('309', 'I', 0.925, 'TABELA 1'),
  ('310', 'I', 0.925, 'TABELA 1'),
  ('311', 'I', 0.925, 'TABELA 1'),
  ('401', 'I', 0.9275, 'TABELA 1'),
  ('402', 'I', 0.9275, 'TABELA 1'),
  ('403', 'II', 0.9275, 'TABELA 2'),
  ('404', 'II', 0.9275, 'TABELA 2'),
  ('405', 'II', 0.9275, 'TABELA 2'),
  ('406', 'II', 0.9275, 'TABELA 2'),
  ('407', 'II', 0.9275, 'TABELA 2'),
  ('408', 'II', 0.9275, 'TABELA 2'),
  ('409', 'I', 0.9275, 'TABELA 1'),
  ('410', 'I', 0.9275, 'TABELA 1'),
  ('411', 'I', 0.9275, 'TABELA 1'),
  ('501', 'I', 0.93, 'TABELA 1'),
  ('502', 'I', 0.93, 'TABELA 1'),
  ('503', 'II', 0.93, 'TABELA 2'),
  ('504', 'II', 0.93, 'TABELA 2'),
  ('505', 'II', 0.93, 'TABELA 2'),
  ('506', 'II', 0.93, 'TABELA 2'),
  ('507', 'II', 0.93, 'TABELA 2'),
  ('508', 'II', 0.93, 'TABELA 2'),
  ('509', 'I', 0.93, 'TABELA 1'),
  ('510', 'I', 0.93, 'TABELA 1'),
  ('511', 'I', 0.93, 'TABELA 1'),
  ('601', 'I', 0.9325, 'TABELA 1'),
  ('602', 'I', 0.9325, 'TABELA 1'),
  ('603', 'II', 0.9325, 'TABELA 2'),
  ('604', 'II', 0.9325, 'TABELA 2'),
  ('605', 'II', 0.9325, 'TABELA 2'),
  ('606', 'II', 0.9325, 'TABELA 2'),
  ('607', 'II', 0.9325, 'TABELA 2'),
  ('608', 'II', 0.9325, 'TABELA 2'),
  ('609', 'I', 0.9325, 'TABELA 1'),
  ('610', 'I', 0.9325, 'TABELA 1'),
  ('611', 'I', 0.9325, 'TABELA 1'),
  ('701', 'I', 0.935, 'TABELA 1'),
  ('702', 'I', 0.935, 'TABELA 1'),
  ('703', 'II', 0.935, 'TABELA 2'),
  ('704', 'II', 0.935, 'TABELA 2'),
  ('705', 'II', 0.935, 'TABELA 2'),
  ('706', 'II', 0.935, 'TABELA 2'),
  ('707', 'II', 0.935, 'TABELA 2'),
  ('708', 'II', 0.935, 'TABELA 2'),
  ('709', 'I', 0.935, 'TABELA 1'),
  ('710', 'I', 0.935, 'TABELA 1'),
  ('711', 'I', 0.935, 'TABELA 1'),
  ('801', 'I', 0.9375, 'TABELA 1'),
  ('802', 'I', 0.9375, 'TABELA 1'),
  ('803', 'II', 0.9375, 'TABELA 2'),
  ('804', 'II', 0.9375, 'TABELA 2'),
  ('805', 'II', 0.9375, 'TABELA 2'),
  ('806', 'II', 0.9375, 'TABELA 2'),
  ('807', 'II', 0.9375, 'TABELA 2'),
  ('808', 'II', 0.9375, 'TABELA 2'),
  ('809', 'I', 0.9375, 'TABELA 1'),
  ('810', 'I', 0.9375, 'TABELA 1'),
  ('811', 'I', 0.9375, 'TABELA 1'),
  ('901', 'I', 0.94, 'TABELA 1'),
  ('902', 'I', 0.94, 'TABELA 1'),
  ('903', 'II', 0.94, 'TABELA 2'),
  ('904', 'II', 0.94, 'TABELA 2'),
  ('905', 'II', 0.94, 'TABELA 2'),
  ('906', 'II', 0.94, 'TABELA 2'),
  ('907', 'II', 0.94, 'TABELA 2'),
  ('908', 'II', 0.94, 'TABELA 2'),
  ('909', 'I', 0.94, 'TABELA 1'),
  ('910', 'I', 0.94, 'TABELA 1'),
  ('911', 'I', 0.94, 'TABELA 1'),
  ('1001', 'I', 0.9425, 'TABELA 1'),
  ('1002', 'I', 0.9425, 'TABELA 1'),
  ('1003', 'II', 0.9425, 'TABELA 2'),
  ('1004', 'II', 0.9425, 'TABELA 2'),
  ('1005', 'II', 0.9425, 'TABELA 2'),
  ('1006', 'II', 0.9425, 'TABELA 2'),
  ('1007', 'II', 0.9425, 'TABELA 2'),
  ('1008', 'II', 0.9425, 'TABELA 2'),
  ('1009', 'I', 0.9425, 'TABELA 1'),
  ('1010', 'I', 0.9425, 'TABELA 1'),
  ('1011', 'I', 0.9425, 'TABELA 1'),
  ('1101', 'I', 0.945, 'TABELA 1'),
  ('1102', 'I', 0.945, 'TABELA 1'),
  ('1103', 'II', 0.945, 'TABELA 2'),
  ('1104', 'II', 0.945, 'TABELA 2'),
  ('1105', 'II', 0.945, 'TABELA 2'),
  ('1106', 'II', 0.945, 'TABELA 2'),
  ('1107', 'II', 0.945, 'TABELA 2'),
  ('1108', 'II', 0.945, 'TABELA 2'),
  ('1109', 'I', 0.945, 'TABELA 1'),
  ('1110', 'I', 0.945, 'TABELA 1'),
  ('1111', 'I', 0.945, 'TABELA 1'),
  ('1201', 'I', 0.9475, 'TABELA 1'),
  ('1202', 'I', 0.9475, 'TABELA 1'),
  ('1203', 'II', 0.9475, 'TABELA 2'),
  ('1204', 'II', 0.9475, 'TABELA 2'),
  ('1205', 'II', 0.9475, 'TABELA 2'),
  ('1206', 'II', 0.9475, 'TABELA 2'),
  ('1207', 'II', 0.9475, 'TABELA 2'),
  ('1208', 'II', 0.9475, 'TABELA 2'),
  ('1209', 'I', 0.9475, 'TABELA 1'),
  ('1210', 'I', 0.9475, 'TABELA 1'),
  ('1211', 'I', 0.9475, 'TABELA 1'),
  ('1301', 'I', 0.95, 'TABELA 1'),
  ('1302', 'I', 0.95, 'TABELA 1'),
  ('1303', 'II', 0.95, 'TABELA 2'),
  ('1304', 'II', 0.95, 'TABELA 2'),
  ('1305', 'II', 0.95, 'TABELA 2'),
  ('1306', 'II', 0.95, 'TABELA 2'),
  ('1307', 'II', 0.95, 'TABELA 2'),
  ('1308', 'II', 0.95, 'TABELA 2'),
  ('1309', 'I', 0.95, 'TABELA 1'),
  ('1310', 'I', 0.95, 'TABELA 1'),
  ('1311', 'I', 0.95, 'TABELA 1'),
  ('1401', 'I', 0.9525, 'TABELA 1'),
  ('1402', 'I', 0.9525, 'TABELA 1'),
  ('1403', 'II', 0.9525, 'TABELA 2'),
  ('1404', 'II', 0.9525, 'TABELA 2'),
  ('1405', 'II', 0.9525, 'TABELA 2'),
  ('1406', 'II', 0.9525, 'TABELA 2'),
  ('1407', 'II', 0.9525, 'TABELA 2'),
  ('1408', 'II', 0.9525, 'TABELA 2'),
  ('1409', 'I', 0.9525, 'TABELA 1'),
  ('1410', 'I', 0.9525, 'TABELA 1'),
  ('1411', 'I', 0.9525, 'TABELA 1'),
  ('1501', 'I', 0.9575, 'TABELA 1'),
  ('1502', 'I', 0.9575, 'TABELA 1'),
  ('1503', 'II', 0.9575, 'TABELA 2'),
  ('1504', 'II', 0.9575, 'TABELA 2'),
  ('1505', 'II', 0.9575, 'TABELA 2'),
  ('1506', 'II', 0.9575, 'TABELA 2'),
  ('1507', 'II', 0.9575, 'TABELA 2'),
  ('1508', 'II', 0.9575, 'TABELA 2'),
  ('1509', 'I', 0.9575, 'TABELA 1'),
  ('1510', 'I', 0.9575, 'TABELA 1'),
  ('1511', 'I', 0.9575, 'TABELA 1'),
  ('1601', 'I', 0.9625, 'TABELA 1'),
  ('1602', 'I', 0.9625, 'TABELA 1'),
  ('1603', 'II', 0.9625, 'TABELA 2'),
  ('1604', 'II', 0.9625, 'TABELA 2'),
  ('1605', 'II', 0.9625, 'TABELA 2'),
  ('1606', 'II', 0.9625, 'TABELA 2'),
  ('1607', 'II', 0.9625, 'TABELA 2'),
  ('1608', 'II', 0.9625, 'TABELA 2'),
  ('1609', 'I', 0.9625, 'TABELA 1'),
  ('1610', 'I', 0.9625, 'TABELA 1'),
  ('1611', 'I', 0.9625, 'TABELA 1'),
  ('1701', 'I', 0.9675, 'TABELA 1'),
  ('1702', 'I', 0.9675, 'TABELA 1'),
  ('1703', 'II', 0.9675, 'TABELA 2'),
  ('1704', 'II', 0.9675, 'TABELA 2'),
  ('1705', 'II', 0.9675, 'TABELA 2'),
  ('1706', 'II', 0.9675, 'TABELA 2'),
  ('1707', 'II', 0.9675, 'TABELA 2'),
  ('1708', 'II', 0.9675, 'TABELA 2'),
  ('1709', 'I', 0.9675, 'TABELA 1'),
  ('1710', 'I', 0.9675, 'TABELA 1'),
  ('1711', 'I', 0.9675, 'TABELA 1')
) as d(numero, tipo, peso, tabela)
where u.numero = d.numero;

-- conferência: todas as unidades do espelho precisam ter recebido preço
do $$
declare faltam text;
begin
  select string_agg(numero, ', ' order by numero) into faltam from public.unidades where tipo_preco is null or peso is null or tabela is null;
  if faltam is not null then
    raise exception 'UNIDADES_SEM_PRECO: %', faltam using hint = 'Nada foi gravado. Envie esta mensagem para o suporte.';
  end if;
end $$;

-- ####################################################################
-- origem: v2/103_carta_modelo.sql
-- ####################################################################
-- =====================================================================
-- 103 — Carta proposta no modelo novo
--  * Campos da carta: vaga, escaninho, coordenação comercial.
--  * Textos de abertura e condições gerais do modelo (foro de Rio Verde).
--  * Nome de quem criou a proposta (sai como corretor na carta).
-- Executar uma única vez no SQL Editor do Supabase (projeto de testes).
-- =====================================================================

alter table public.comercial
  add column if not exists vaga                  text not null default 'Não inclui',
  add column if not exists escaninho             text not null default 'Não inclui',
  add column if not exists coordenacao_comercial text;

update public.comercial set
  forma_sinal = 'PIX',
  coordenacao_comercial = coalesce(coordenacao_comercial, 'Kavaná'),
  texto_abertura = 'Por meio desta, o(s) proponente(s) abaixo qualificado(s) formaliza(m) proposta para aquisição da unidade descrita, nos termos e condições a seguir, para avaliação da vendedora.',
  texto_condicoes = $t$A partir desta data e até o mês da expedição do habite-se, os valores serão reajustados pelo INCC (Índice Nacional de Custo da Construção). A partir do primeiro dia do mês seguinte ao habite-se e até a quitação, os valores serão reajustados mensalmente pelo IGP-M (Índice Geral de Preços do Mercado), acrescidos de juros de 1% (um por cento) ao mês.
Esta proposta será analisada pela vendedora, que poderá recusá-la, ainda que sem motivação.
A concessão do financiamento bancário está sujeita à análise de crédito e aos critérios do banco financiador. É de responsabilidade exclusiva do(s) proponente(s) obter os recursos para a parcela de financiamento, por crédito bancário ou recursos próprios.
Os honorários de intermediação imobiliária serão pagos com o sinal de negócio definido nesta proposta. Os valores de sinal e intermediação devem ser quitados na assinatura desta proposta.
Em caso de recusa desta proposta ou de não compensação do sinal, ela perderá qualquer eficácia jurídica e a unidade ficará liberada para comercialização, sem ônus para o(s) proponente(s).
Questões oriundas desta proposta serão resolvidas preferencialmente por via conciliatória ou arbitral, ficando eleito o foro da comarca de Rio Verde - GO.$t$,
  atualizado_em = now()
where id = 1;

-- Nome de quem criou a proposta
alter table public.propostas add column if not exists criado_por_nome text;
update public.propostas p set criado_por_nome = coalesce(nullif(pf.nome, ''), pf.email)
  from public.perfis pf where pf.user_id = p.criado_por_id and p.criado_por_nome is null;

create or replace function public.propostas_nome_criador() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    select coalesce(nullif(nome, ''), email) into new.criado_por_nome from public.perfis where user_id = auth.uid();
  else
    new.criado_por_nome := old.criado_por_nome;
  end if;
  return new;
end;
$$;
drop trigger if exists propostas_nome_criador on public.propostas;
-- roda depois de propostas_antes (ordem alfabética dos gatilhos)
create trigger propostas_nome_criador before insert or update on public.propostas
  for each row execute function public.propostas_nome_criador();

-- ####################################################################
-- origem: v2/104_novas_series.sql
-- ####################################################################
-- =====================================================================
-- 104 — Novas séries: Bimestrais, Trimestrais e Permuta
--  * Tabelas de venda passam a aceitar as novas periodicidades.
--  * Proposta com Permuta só é enviada com as observações preenchidas
--    (o que entra na permuta: imóvel, carro, serviços...).
-- Executar uma única vez no SQL Editor do Supabase (projeto de testes).
-- =====================================================================

alter table public.tabelas_series drop constraint if exists tabelas_series_periodicidade_check;
alter table public.tabelas_series add constraint tabelas_series_periodicidade_check
  check (periodicidade in ('Sinal', 'Mensais', 'Bimestrais', 'Trimestrais', 'Semestrais', 'Anuais', 'Unica', 'Permuta', 'Financiamento'));

create or replace function public.enviar_proposta(p_id uuid) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare v public.propostas;
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
  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas set status = 'enviada', enviada_em = now(), motivo_analise = null where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);
  return v;
end;
$$;
revoke all on function public.enviar_proposta(uuid) from public, anon;
grant execute on function public.enviar_proposta(uuid) to authenticated;

-- ####################################################################
-- origem: v2/105_alcadas_pv_banco.sql
-- ####################################################################
-- =====================================================================
-- 105 — Alçadas de aprovação e PV calculado pelo banco
--  * O banco recalcula o preço de tabela, o VPL da tabela e o da proposta
--    no envio (não depende mais do cálculo feito no navegador).
--  * Alçadas: PV ≥ limite automático e sinal cobrindo a comissão → aprovada
--    na hora; PV ≥ limite da Sec. Vendas → Sec. Vendas aprova; abaixo disso
--    só o administrador aprova. Limites ajustáveis na tabela "comercial".
-- Executar uma única vez no SQL Editor do Supabase (projeto de testes).
-- =====================================================================

alter table public.comercial
  add column if not exists alcada_automatica boolean not null default true,
  add column if not exists alcada_auto_pv    numeric(6, 2) not null default 100,   -- PV (% do VPL da tabela) para aprovar sozinho
  add column if not exists alcada_vendas_pv  numeric(6, 2) not null default 98;    -- a partir daqui a Sec. Vendas aprova; abaixo, só o administrador

alter table public.propostas add column if not exists alcada text check (alcada in ('automatica', 'vendas', 'admin'));

-- ---------------------------------------------------------------------
-- Cálculo (mesma regra do motor da tela, conferido contra a planilha)
-- ---------------------------------------------------------------------
create or replace function public.preco_tabela_unidade(p_unidade uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select pt.preco_m2 * u.peso * u.area_privativa
         / (select avg(x.peso) from public.unidades x where x.tipo_preco = u.tipo_preco and x.peso is not null)
    from public.unidades u join public.precos_tipo pt on pt.tipo = u.tipo_preco
   where u.id = p_unidade;
$$;

create or replace function public.passo_meses(p text) returns int language sql immutable as $$
  select case p when 'Bimestrais' then 2 when 'Trimestrais' then 3 when 'Semestrais' then 6 when 'Anuais' then 12 else 1 end;
$$;

-- meses entre duas datas (pelo mês, ignorando o dia)
create or replace function public.meses_entre(de date, ate date) returns int language sql immutable as $$
  select (extract(year from ate)::int * 12 + extract(month from ate)::int) - (extract(year from de)::int * 12 + extract(month from de)::int);
$$;

create or replace function public.pv_proposta(p_unidade uuid, p_series jsonb, p_comissao numeric default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c        public.comercial;
  u        public.unidades;
  v_preco  numeric;
  v_mes_sec int;
  v_vpl_t  numeric := 0;
  v_vpl_p  numeric := 0;
  v_total  numeric := 0;
  v_sinal  numeric := 0;
  v_com    numeric;
  s        record;
  k        int;
  v_mes    int;
  v_base   date;
begin
  select * into c from public.comercial where id = 1;
  select * into u from public.unidades where id = p_unidade;
  v_preco := public.preco_tabela_unidade(p_unidade);
  if v_preco is null or u.tabela is null then raise exception 'UNIDADE_SEM_PRECO'; end if;
  v_mes_sec := public.meses_entre(c.mes_tabela, c.mes_entrega) + 1;   -- financiamento: mês seguinte à entrega

  -- tabela
  for s in select * from public.tabelas_series where tabela = u.tabela loop
    v_base := case s.base when 'venda' then c.mes_tabela else c.mes_entrega end;
    for k in 0 .. s.qtd - 1 loop
      v_mes := case when s.periodicidade = 'Financiamento' then v_mes_sec
                    else public.meses_entre(c.mes_tabela, (v_base + make_interval(months => s.meses + k * public.passo_meses(s.periodicidade)))::date) end;
      v_vpl_t := v_vpl_t + (s.percentual * v_preco / s.qtd) / power(1 + c.taxa_vp, v_mes);
    end loop;
  end loop;

  -- proposta
  for s in select (e ->> 'qtd')::int as qtd, e ->> 'periodicidade' as periodicidade, (e ->> 'vencimento')::date as vencimento,
                  round((e ->> 'valor')::numeric, 2) as valor
             from jsonb_array_elements(p_series) e loop
    for k in 0 .. s.qtd - 1 loop
      v_mes := case when s.periodicidade = 'Financiamento' then v_mes_sec
                    else public.meses_entre(c.mes_tabela, (s.vencimento + make_interval(months => k * public.passo_meses(s.periodicidade)))::date) end;
      v_vpl_p := v_vpl_p + s.valor / power(1 + c.taxa_vp, v_mes);
      v_total := v_total + s.valor;
      if s.periodicidade = 'Sinal' then v_sinal := v_sinal + s.valor; end if;
    end loop;
  end loop;

  v_com := round(v_total * coalesce(p_comissao, c.comissao_pct), 2);
  return jsonb_build_object(
    'preco_tabela', round(v_preco, 2), 'total', round(v_total, 2),
    'vpl_tabela', round(v_vpl_t, 2), 'vpl_proposta', round(v_vpl_p, 2),
    'diferenca_vpl', round(v_vpl_p - v_vpl_t, 2),
    'pv_pct', round(v_vpl_p / nullif(v_vpl_t, 0) * 100, 2),
    'sinal', round(v_sinal, 2), 'comissao', v_com,
    'comissao_coberta', v_sinal * c.parte_sinal + 0.01 >= v_com,
    'calculado_pelo_banco', true);
end;
$$;
grant execute on function public.pv_proposta(uuid, jsonb, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- alterar_status: igual ao 016, aceitando chamadas internas do sistema
-- ---------------------------------------------------------------------
create or replace function public.alterar_status(
  p_unidade_id  uuid,
  p_status      public.status_unidade,
  p_versao      int,
  p_motivo      text    default null,
  p_imobiliaria text    default null,
  p_corretor    text    default null,
  p_cliente     text    default null,
  p_valor       numeric default null,
  p_pv          numeric default null,
  p_pasta       uuid    default null
) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  v_unidade  public.unidades;
  v_neg      public.negociacoes;
  v_pasta    public.pastas;
  v_email    text;
  v_anterior public.status_unidade;
  v_motivo   text := nullif(trim(coalesce(p_motivo, '')), '');
  v_imob     text;
  v_corretor text;
  v_cliente  text;
  v_valor    numeric;
  v_pv       numeric;
  v_detalhes jsonb;
  v_rotulo   text;
  v_codigo   text;
begin
  -- equipe, ou o próprio sistema (aprovação automática da proposta, reserva pela fila)
  if not public.eh_equipe() and current_setting('espelho.sistema', true) is distinct from 'sim' then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;

  select * into v_unidade from public.unidades where id = p_unidade_id for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  if v_unidade.versao <> p_versao then
    raise exception 'CONFLITO' using hint = 'A unidade foi alterada por outra pessoa. Recarregue.';
  end if;
  if v_unidade.status = p_status then return v_unidade; end if;

  v_anterior := v_unidade.status;
  select email into v_email from public.perfis where user_id = auth.uid();
  select * into v_neg from public.negociacoes where unidade_id = p_unidade_id and ativa for update;

  if p_status in ('disponivel', 'bloqueada', 'permutante') then
    if v_anterior not in ('disponivel', 'bloqueada', 'permutante') and v_motivo is null then
      raise exception 'MOTIVO_OBRIGATORIO';
    end if;
    if v_neg.id is not null then
      update public.negociacoes
         set ativa = false, encerrada_em = now(), motivo_encerramento = v_motivo, atualizada_em = now()
       where id = v_neg.id;
      if v_neg.pasta_id is not null then
        update public.pastas set etapa_atualizada_em = now() where id = v_neg.pasta_id;
        insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
        values (v_neg.pasta_id, 'Unidade liberada no espelho',
                jsonb_strip_nulls(jsonb_build_object('unidade', v_unidade.numero, 'motivo', v_motivo)), v_email);
      end if;
    end if;
    v_detalhes := null;
  else
    if v_neg.pasta_id is not null then
      if p_pasta is not null and p_pasta <> v_neg.pasta_id then
        raise exception 'UNIDADE_COM_OUTRA_PASTA';
      end if;
      select * into v_pasta from public.pastas where id = v_neg.pasta_id for update;
    else
      if p_pasta is null then raise exception 'PASTA_OBRIGATORIA'; end if;
      select * into v_pasta from public.pastas where id = p_pasta for update;
      if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
      if v_pasta.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
    end if;

    select i.nome into v_imob from public.imobiliarias i where i.id = v_pasta.imobiliaria_id;
    select coalesce(nullif(pf.nome, ''), pf.email) into v_corretor from public.perfis pf where pf.user_id = v_pasta.criado_por_id;
    v_imob     := coalesce(v_imob, v_neg.imobiliaria);
    v_corretor := coalesce(v_corretor, v_pasta.criado_por, v_neg.corretor);
    v_cliente  := coalesce(v_pasta.comprador_nome, v_neg.cliente);
    v_valor    := coalesce(p_valor, v_neg.valor_venda);
    v_pv       := coalesce(p_pv, v_neg.pv_aprovado);
    v_codigo   := coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo);

    if p_status = 'proposta' and (v_valor is null or v_pv is null) then
      raise exception 'DADOS_PROPOSTA_OBRIGATORIOS';
    end if;
    if v_valor is not null and v_valor <= 0 then raise exception 'VALOR_INVALIDO'; end if;
    if v_pv is not null and v_pv < 0 then raise exception 'PV_INVALIDO'; end if;

    if v_neg.id is null then
      insert into public.negociacoes (unidade_id, pasta_id, imobiliaria, corretor, cliente, valor_venda, pv_aprovado, criado_por)
      values (p_unidade_id, v_pasta.id, v_imob, v_corretor, v_cliente, v_valor, v_pv, v_email);
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (v_pasta.id, 'Unidade vinculada', jsonb_build_object('unidade', v_unidade.numero), v_email);
    else
      update public.negociacoes
         set pasta_id = v_pasta.id, imobiliaria = v_imob, corretor = v_corretor, cliente = v_cliente,
             valor_venda = v_valor, pv_aprovado = v_pv, atualizada_em = now()
       where id = v_neg.id;
    end if;

    v_rotulo := case p_status when 'reservada' then 'Reserva' when 'proposta' then 'Contrato em confecção'
                              when 'contrato' then 'Enviado para assinatura' else 'Assinado / Vendido' end;
    update public.pastas set etapa_atualizada_em = now() where id = v_pasta.id;
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (v_pasta.id, 'Etapa da venda alterada',
            jsonb_build_object('documento', v_rotulo || ' (pelo espelho)', 'unidade', v_unidade.numero), v_email);

    v_detalhes := jsonb_strip_nulls(jsonb_build_object(
      'pasta', v_codigo, 'cliente', v_cliente, 'imobiliaria', v_imob, 'corretor', v_corretor,
      'valor_venda', p_valor, 'pv_aprovado', p_pv));
  end if;

  update public.unidades
     set status = p_status, versao = versao + 1, atualizado_em = now()
   where id = p_unidade_id
  returning * into v_unidade;

  insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
  values (v_unidade.id, v_unidade.numero, v_anterior, p_status, v_motivo, auth.uid(), v_email, v_detalhes);

  return v_unidade;
end;
$$;

-- ---------------------------------------------------------------------
-- Aprovação (interna): leva a unidade para "Proposta recebida"
-- ---------------------------------------------------------------------
create or replace function public.aprovar_proposta_interno(p_id uuid, p_aprovador text) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v public.propostas;
  u public.unidades;
begin
  select * into v from public.propostas where id = p_id for update;
  if exists (select 1 from public.propostas where unidade_id = v.unidade_id and status = 'aprovada' and id <> v.id) then
    raise exception 'UNIDADE_COM_PROPOSTA_APROVADA';
  end if;
  select * into u from public.unidades where id = v.unidade_id;
  perform set_config('espelho.sistema', 'sim', true);
  if u.status in ('disponivel', 'reservada') then
    perform public.alterar_status(u.id, 'proposta', u.versao, null, null, null, null,
      (v.resumo ->> 'total')::numeric, round((v.resumo ->> 'pv_pct')::numeric, 2), v.pasta_id);
  elsif u.status <> 'proposta' then
    perform set_config('espelho.sistema', '', true);
    raise exception 'UNIDADE_INDISPONIVEL' using hint = 'A unidade está em outra etapa no espelho.';
  end if;
  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas
     set status = 'aprovada', motivo_analise = null, analisada_por = p_aprovador, analisada_em = now()
   where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);
  perform set_config('espelho.sistema', '', true);
  return v;
end;
$$;
revoke all on function public.aprovar_proposta_interno(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Enviar: o banco recalcula o PV e define a alçada
-- ---------------------------------------------------------------------
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

  select * into c from public.comercial where id = 1;
  r := public.pv_proposta(v.unidade_id, v.series, v.comissao_pct);
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
revoke all on function public.enviar_proposta(uuid) from public, anon;
grant execute on function public.enviar_proposta(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Análise pela equipe, respeitando a alçada
-- ---------------------------------------------------------------------
create or replace function public.analisar_proposta(p_id uuid, p_decisao text, p_motivo text default null) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v public.propostas;
  v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_decisao not in ('aprovada', 'recusada', 'devolvida', 'cancelada') then raise exception 'DECISAO_INVALIDA'; end if;
  select * into v from public.propostas where id = p_id for update;
  if not found then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  if p_decisao in ('recusada', 'devolvida', 'cancelada') and v_motivo is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  if p_decisao in ('aprovada', 'recusada', 'devolvida') and v.status <> 'enviada' then raise exception 'PROPOSTA_NAO_ENVIADA'; end if;

  if p_decisao = 'aprovada' then
    if v.alcada = 'admin' and not public.eh_admin() then
      raise exception 'ALCADA_ADMIN' using hint = 'PV abaixo do limite da Sec. Vendas: só o administrador aprova.';
    end if;
    return public.aprovar_proposta_interno(p_id, (select email from public.perfis where user_id = auth.uid()));
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
revoke all on function public.analisar_proposta(uuid, text, text) from public, anon;
grant execute on function public.analisar_proposta(uuid, text, text) to authenticated;

-- ####################################################################
-- Chave liga/desliga: com o módulo desligado, só a equipe cria proposta
-- ####################################################################
create or replace function public.propostas_modulo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_equipe() and not coalesce((select modulo_propostas from public.config where id = 1), false) then
    raise exception 'MODULO_DESLIGADO' using hint = 'As propostas ainda não estão liberadas.';
  end if;
  return new;
end;
$$;
drop trigger if exists propostas_0_modulo on public.propostas;
-- "0" no nome: roda antes dos outros gatilhos (ordem alfabética)
create trigger propostas_0_modulo before insert on public.propostas
  for each row execute function public.propostas_modulo();

-- preços só para quem tem login (a v2 deixava estas funções abertas)
revoke all on function public.pv_proposta(uuid, jsonb, numeric), public.preco_tabela_unidade(uuid) from public, anon;
grant execute on function public.pv_proposta(uuid, jsonb, numeric), public.preco_tabela_unidade(uuid) to authenticated;

commit;
