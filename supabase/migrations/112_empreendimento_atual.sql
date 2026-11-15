-- =====================================================================
-- 112 — Vários empreendimentos (Fase 1, etapas B a E, banco)
--  * Cada login trabalha num "empreendimento atual" (guardado no perfil).
--    O banco filtra por ele espelho, pastas, negociações, histórico,
--    propostas, rodadas, Meeting, Portal e tabela de vendas: as telas
--    não precisam mudar as consultas.
--  * Identidade e módulos (config), dados comerciais (comercial) e a fila
--    de escolha (fila_config / fila_escolha) passam a ser por empreendimento.
--  * Pastas e fila são de cada empreendimento. Códigos com a sigla:
--    DH-P-001 (pasta) e DH-PA-001 (submetida ao incorporador).
--  * Unidades: número e posição únicos dentro do empreendimento.
--  * Painéis com visão consolidada da incorporadora (todos os empreendimentos).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Empreendimento atual
-- ---------------------------------------------------------------------
alter table public.perfis add column if not exists empreendimento_atual uuid references public.empreendimentos (id) on delete set null;
alter table public.empreendimentos add column if not exists seq_pasta int not null default 0;
alter table public.empreendimentos add column if not exists seq_aprovacao int not null default 0;

-- pode trabalhar no empreendimento: equipe em todos; imobiliária/corretor nos ativos e não bloqueados
create or replace function public.pode_usar_empreendimento(p_emp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.empreendimentos e where e.id = p_emp
                  and (public.eh_equipe() or (e.ativo and public.acesso_empreendimento(e.id))));
$$;

create or replace function public.empreendimento_atual() returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.empreendimento_atual from public.perfis p
      where p.user_id = auth.uid() and p.empreendimento_atual is not null and public.pode_usar_empreendimento(p.empreendimento_atual)),
    (select e.id from public.empreendimentos e
      where e.ativo and (auth.uid() is null or public.pode_usar_empreendimento(e.id))
      order by e.ordem, e.criado_em limit 1),
    public.empreendimento_padrao());
$$;

create or replace function public.escolher_empreendimento(p_emp uuid) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.pode_usar_empreendimento(p_emp) then raise exception 'EMPREENDIMENTO_SEM_ACESSO'; end if;
  update public.perfis set empreendimento_atual = p_emp where user_id = auth.uid();
  return p_emp;
end;
$$;

-- empreendimentos que o login pode usar, com o atual marcado
create or replace function public.meus_empreendimentos() returns table (id uuid, slug text, sigla text, nome text, ativo boolean, atual boolean, escolhido boolean)
language sql stable security definer set search_path = public as $$
  select e.id, e.slug, e.sigla, e.nome, e.ativo, e.id = public.empreendimento_atual(),
         exists (select 1 from public.perfis p where p.user_id = auth.uid() and p.empreendimento_atual is not null)
    from public.empreendimentos e
   where auth.uid() is not null and public.pode_usar_empreendimento(e.id)
   order by e.ordem, e.criado_em;
$$;

-- ---------------------------------------------------------------------
-- Configuração, dados comerciais e fila: uma linha por empreendimento
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['config', 'comercial', 'fila_config'] loop
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_id_check');
    execute format('create sequence if not exists public.%I', t || '_id_seq');
    execute format('select setval(%L, greatest((select max(id) from public.%I), 1))', 'public.' || t || '_id_seq', t);
    execute format('alter table public.%I alter column id set default nextval(%L)', t, 'public.' || t || '_id_seq');
    execute format('alter table public.%I add column if not exists empreendimento_id uuid references public.empreendimentos (id) on delete cascade', t);
    execute format('update public.%I set empreendimento_id = public.empreendimento_padrao() where empreendimento_id is null', t);
    execute format('alter table public.%I alter column empreendimento_id set not null', t);
    execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_atual()', t);
    execute format('create unique index if not exists %I on public.%I (empreendimento_id)', t || '_empreendimento_key', t);
    -- cada login lê (e o admin altera) só a linha do empreendimento atual
    execute format('drop policy if exists %I on public.%I', t || '_do_empreendimento', t);
    execute format('create policy %I on public.%I as restrictive for all using (empreendimento_id = (select public.empreendimento_atual())) with check (empreendimento_id = (select public.empreendimento_atual()))', t || '_do_empreendimento', t);
  end loop;
end $$;
grant usage on sequence public.config_id_seq, public.comercial_id_seq, public.fila_config_id_seq to authenticated;

create or replace function public.comercial_de(p_emp uuid) returns public.comercial
language sql stable security definer set search_path = public as $$
  select * from public.comercial where empreendimento_id = p_emp;
$$;

-- ---------------------------------------------------------------------
-- Dados de lançamento: filtrados pelo empreendimento atual
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['unidades', 'negociacoes', 'historico', 'pastas', 'rodadas', 'recepcao_eventos',
                           'portal_itens', 'portal_downloads', 'simulacoes_log', 'propostas', 'tabelas_preco'] loop
    if to_regclass('public.' || t) is not null then
      execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_atual()', t);
      execute format('drop policy if exists %I on public.%I', t || '_do_empreendimento', t);
      execute format('create policy %I on public.%I as restrictive for select using (empreendimento_id = (select public.empreendimento_atual()))', t || '_do_empreendimento', t);
    end if;
  end loop;
end $$;

-- espelho público (TV/link) conforme a configuração do próprio empreendimento
drop policy if exists unidades_leitura on public.unidades;
create policy unidades_leitura on public.unidades for select using (
  (select c.publico_ativo from public.config c where c.empreendimento_id = unidades.empreendimento_id)
  or public.eh_equipe() or public.minha_imobiliaria() is not null);

-- número e posição únicos dentro de cada empreendimento
alter table public.unidades drop constraint if exists unidades_numero_key;
alter table public.unidades drop constraint if exists unidades_andar_posicao_key;
create unique index if not exists unidades_emp_numero_key on public.unidades (empreendimento_id, numero);
create unique index if not exists unidades_emp_andar_posicao_key on public.unidades (empreendimento_id, andar, posicao);

-- negociação: pasta e unidade do mesmo empreendimento
create or replace function public.negociacao_mesmo_empreendimento() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.pasta_id is not null
     and (select empreendimento_id from public.pastas where id = new.pasta_id)
         is distinct from (select empreendimento_id from public.unidades where id = new.unidade_id) then
    raise exception 'PASTA_DE_OUTRO_EMPREENDIMENTO' using hint = 'A pasta pertence a outro empreendimento.';
  end if;
  return new;
end;
$$;
drop trigger if exists negociacoes_mesmo_empreendimento on public.negociacoes;
create trigger negociacoes_mesmo_empreendimento before insert or update of unidade_id, pasta_id on public.negociacoes
  for each row execute function public.negociacao_mesmo_empreendimento();

-- ---------------------------------------------------------------------
-- Códigos das pastas com a sigla do empreendimento
-- ---------------------------------------------------------------------
update public.empreendimentos e set
  seq_pasta = greatest(e.seq_pasta, coalesce((select max(nullif(regexp_replace(p.codigo, '\D', '', 'g'), '')::int) from public.pastas p where p.empreendimento_id = e.id), 0)),
  seq_aprovacao = greatest(e.seq_aprovacao, coalesce((select max(nullif(regexp_replace(p.codigo_aprovacao, '\D', '', 'g'), '')::int) from public.pastas p where p.empreendimento_id = e.id), 0));
update public.pastas p set
  codigo = e.sigla || '-' || p.codigo,
  codigo_aprovacao = case when p.codigo_aprovacao is null then null else e.sigla || '-' || p.codigo_aprovacao end
  from public.empreendimentos e
 where e.id = p.empreendimento_id and p.codigo !~ '^[A-Z0-9]{2,4}-P';

create or replace function public.proximo_codigo(p_emp uuid, p_tipo text) returns text
language plpgsql security definer set search_path = public as $$
declare v_sigla text; v_n int;
begin
  if p_tipo = 'PA' then
    update public.empreendimentos set seq_aprovacao = seq_aprovacao + 1 where id = p_emp returning sigla, seq_aprovacao into v_sigla, v_n;
  else
    update public.empreendimentos set seq_pasta = seq_pasta + 1 where id = p_emp returning sigla, seq_pasta into v_sigla, v_n;
  end if;
  return v_sigla || '-' || public.formatar_codigo(p_tipo, v_n);
end;
$$;

alter table public.pastas alter column codigo set default public.proximo_codigo(public.empreendimento_atual(), 'P');
-- pasta gravada noutro empreendimento que não o atual: código com a sigla certa
create or replace function public.pastas_codigo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.codigo is null or split_part(new.codigo, '-', 1) is distinct from (select sigla from public.empreendimentos where id = new.empreendimento_id) then
    new.codigo := public.proximo_codigo(new.empreendimento_id, 'P');
  end if;
  return new;
end;
$$;
drop trigger if exists pastas_a_codigo on public.pastas;
create trigger pastas_a_codigo before insert on public.pastas for each row execute function public.pastas_codigo();

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
  if v_pasta.estado_civil in ('casado', 'uniao_estavel')
     and (length(trim(coalesce(v_pasta.conjuge_nome, ''))) <= 1
          or v_pasta.conjuge_cpf is null
          or length(trim(coalesce(v_pasta.conjuge_profissao, ''))) <= 1) then
    raise exception 'DADOS_CONJUGE_INCOMPLETOS';
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
-- Funções que liam a linha única de configuração
-- ---------------------------------------------------------------------
create or replace function public.definir_publico(p_ativo boolean) returns public.config
language plpgsql security definer set search_path = public as $$
declare v_config public.config;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.config set publico_ativo = p_ativo, atualizado_em = now() where empreendimento_id = public.empreendimento_atual()
  returning * into v_config;
  return v_config;
end;
$$;

create or replace function public.salvar_simulador(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare c jsonb; pr jsonb; s numeric;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if jsonb_typeof(p -> 'cenarios') <> 'array' or jsonb_array_length(p -> 'cenarios') not between 1 and 30 then
    raise exception 'CENARIOS_INVALIDOS';
  end if;
  for c in select * from jsonb_array_elements(p -> 'cenarios') loop
    if length(trim(coalesce(c ->> 'nome', ''))) < 2 or length(coalesce(c ->> 'id', '')) < 1 then raise exception 'NOME_INVALIDO'; end if;
    if jsonb_typeof(c -> 'precos') <> 'array' or jsonb_array_length(c -> 'precos') not between 1 and 6 then raise exception 'PRECO_INVALIDO'; end if;
    for pr in select * from jsonb_array_elements(c -> 'precos') loop
      if coalesce((pr ->> 'valor')::numeric, 0) <= 0 or length(trim(coalesce(pr ->> 'rotulo', ''))) = 0 then raise exception 'PRECO_INVALIDO'; end if;
    end loop;
    if coalesce((c ->> 'captacao')::numeric, 0) not between 1 and 100 then raise exception 'CAPTACAO_INVALIDA'; end if;
    if coalesce((c #>> '{pct,unica}')::numeric, 0) > 5 then raise exception 'UNICA_ACIMA_DO_LIMITE'; end if;
    select sum(v::numeric) into s from jsonb_each_text(c -> 'pct') as x(k, v);
    if s is null or s > 100 or s < (c ->> 'captacao')::numeric then raise exception 'FLUXO_PADRAO_INVALIDO'; end if;
  end loop;
  update public.config set simulador = jsonb_build_object('cenarios', p -> 'cenarios'), atualizado_em = now()
   where empreendimento_id = public.empreendimento_atual();
end;
$$;

-- fluxo da tabela: entrega do empreendimento da tabela
create or replace function public.series_tabela(p_tabela uuid, p_unidade uuid, p_data date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  with i as (select * from public.tabelas_preco_itens where tabela_id = p_tabela and unidade_id = p_unidade),
       m as (select public.mes_venda_tabela(p_tabela, p_data) as venda,
                    (select c.mes_entrega from public.comercial c join public.tabelas_preco t on t.empreendimento_id = c.empreendimento_id where t.id = p_tabela) as entrega),
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

create or replace function public.pv_proposta(p_unidade uuid, p_series jsonb, p_comissao numeric default null,
  p_tabela uuid default null, p_data date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c        public.comercial;
  v_emp    uuid;
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
  select empreendimento_id into v_emp from public.unidades where id = p_unidade;
  c := public.comercial_de(v_emp);
  v_tab := coalesce(p_tabela, public.tabela_vigente(v_emp));
  v_preco := public.preco_tabela_unidade(p_unidade, v_tab);
  if v_preco is null then raise exception 'UNIDADE_SEM_PRECO'; end if;
  v_venda := public.mes_venda_tabela(v_tab, p_data);
  v_mes_sec := public.meses_entre(v_venda, c.mes_entrega) + 1;

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
  if (select empreendimento_id from public.pastas where id = v.pasta_id) is distinct from v.empreendimento_id then
    raise exception 'PASTA_DE_OUTRO_EMPREENDIMENTO' using hint = 'A pasta pertence a outro empreendimento.';
  end if;
  if jsonb_array_length(v.series) = 0 then raise exception 'SERIES_INVALIDAS'; end if;
  if exists (select 1 from jsonb_array_elements(v.series) s where s ->> 'periodicidade' = 'Permuta')
     and length(trim(coalesce(v.observacoes, ''))) < 5 then
    raise exception 'PERMUTA_SEM_OBSERVACAO' using hint = 'Descreva a permuta nas observações da proposta.';
  end if;
  if v.tabela_id is distinct from public.tabela_vigente(v.empreendimento_id) then
    raise exception 'TABELA_ENCERRADA' using hint = 'A tabela desta proposta não está mais vigente. Atualize para a tabela vigente.';
  end if;

  c := public.comercial_de(v.empreendimento_id);
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

-- nova tabela no empreendimento atual
create or replace function public.nova_tabela(p_nome text, p_mes date, p_base uuid default null,
  p_reajuste numeric default null, p_unidades uuid[] default null, p_emp uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_emp uuid := coalesce(p_emp, public.empreendimento_atual()); v_base uuid; v_id uuid;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_reajuste is not null and (p_reajuste <= -0.5 or p_reajuste > 1) then raise exception 'REAJUSTE_INVALIDO'; end if;
  v_base := coalesce(p_base, public.tabela_vigente(v_emp));
  if v_base is not null and (select empreendimento_id from public.tabelas_preco where id = v_base) <> v_emp then v_base := null; end if;
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

-- ---------------------------------------------------------------------
-- Fila de escolha por empreendimento
-- ---------------------------------------------------------------------
alter table public.fila_escolha add column if not exists empreendimento_id uuid references public.empreendimentos (id) on delete cascade;
update public.fila_escolha f set empreendimento_id = p.empreendimento_id from public.pastas p where p.id = f.pasta_id and f.empreendimento_id is null;
alter table public.fila_escolha alter column empreendimento_id set not null;
create index if not exists fila_escolha_emp_idx on public.fila_escolha (empreendimento_id, posicao);
create or replace function public.fila_escolha_emp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select empreendimento_id into new.empreendimento_id from public.pastas where id = new.pasta_id;
  return new;
end;
$$;
drop trigger if exists fila_escolha_emp on public.fila_escolha;
create trigger fila_escolha_emp before insert on public.fila_escolha for each row execute function public.fila_escolha_emp();

create or replace function public.fila_de(p_emp uuid) returns public.fila_config
language sql stable security definer set search_path = public as $$
  select * from public.fila_config where empreendimento_id = p_emp;
$$;

drop function if exists public.fila_liberadas();
create or replace function public.fila_liberadas(p_emp uuid default null) returns int
language sql stable security definer set search_path = public as $$
  select case when not f.ativa or f.inicio is null or now() < f.inicio then 0
              else f.lote * (floor(extract(epoch from now() - f.inicio) / (f.intervalo_min * 60))::int + 1) end
    from public.fila_config f where f.empreendimento_id = coalesce(p_emp, public.empreendimento_atual());
$$;

drop function if exists public.fila_libera_em(int);
create or replace function public.fila_libera_em(p_posicao int, p_emp uuid default null) returns timestamptz
language sql stable security definer set search_path = public as $$
  select f.inicio + make_interval(mins => ((p_posicao - 1) / f.lote) * f.intervalo_min)
    from public.fila_config f where f.empreendimento_id = coalesce(p_emp, public.empreendimento_atual());
$$;

create or replace function public.fila_situacao() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ativa', f.ativa, 'inicio', f.inicio, 'lote', f.lote, 'intervalo_min', f.intervalo_min,
    'unidades_por_pasta', f.unidades_por_pasta,
    'liberadas', least(public.fila_liberadas(f.empreendimento_id), (select count(*) from public.fila_escolha e where e.empreendimento_id = f.empreendimento_id)),
    'total', (select count(*) from public.fila_escolha e where e.empreendimento_id = f.empreendimento_id),
    'proximo_lote_em', case when f.ativa and f.inicio is not null then
        case when now() < f.inicio then f.inicio
             else f.inicio + make_interval(mins => (floor(extract(epoch from now() - f.inicio) / (f.intervalo_min * 60))::int + 1) * f.intervalo_min) end end,
    'agora', now())
  from public.fila_config f where f.empreendimento_id = public.empreendimento_atual();
$$;

create or replace function public.minha_fila() returns table (
  pasta_id uuid, codigo text, comprador text, imobiliaria text, corretor text, posicao int,
  liberada boolean, libera_em timestamptz, reservas int, unidades text[]
)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.codigo_aprovacao, p.codigo), p.comprador_nome, i.nome,
         coalesce(nullif(pf.nome, ''), p.criado_por), f.posicao,
         f.posicao <= public.fila_liberadas(f.empreendimento_id), public.fila_libera_em(f.posicao, f.empreendimento_id),
         (select count(*)::int from public.negociacoes n where n.pasta_id = p.id and n.ativa),
         (select array_agg(u.numero order by u.numero) from public.negociacoes n join public.unidades u on u.id = n.unidade_id where n.pasta_id = p.id and n.ativa)
    from public.fila_escolha f
    join public.pastas p on p.id = f.pasta_id
    left join public.imobiliarias i on i.id = p.imobiliaria_id
    left join public.perfis pf on pf.user_id = p.criado_por_id
   where f.empreendimento_id = public.empreendimento_atual() and public.acesso_pasta(p.imobiliaria_id, p.criado_por_id)
   order by f.posicao;
$$;

create or replace function public.configurar_fila(p_ativa boolean, p_inicio timestamptz, p_lote int, p_intervalo int, p_unidades_por_pasta int default 1)
returns public.fila_config
language plpgsql security definer set search_path = public as $$
declare v public.fila_config;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_ativa and p_inicio is null then raise exception 'INICIO_OBRIGATORIO'; end if;
  insert into public.fila_config (empreendimento_id) values (public.empreendimento_atual()) on conflict (empreendimento_id) do nothing;
  update public.fila_config set ativa = p_ativa, inicio = p_inicio, lote = p_lote, intervalo_min = p_intervalo,
         unidades_por_pasta = coalesce(p_unidades_por_pasta, 1), atualizado_em = now(), atualizado_por = public.meu_email()
   where empreendimento_id = public.empreendimento_atual() returning * into v;
  return v;
end;
$$;

create or replace function public.montar_fila() returns int
language plpgsql security definer set search_path = public as $$
declare v_emp uuid := public.empreendimento_atual(); v_ini int; v_n int;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select coalesce(max(posicao), 0) into v_ini from public.fila_escolha where empreendimento_id = v_emp;
  insert into public.fila_escolha (pasta_id, posicao)
  select p.id, v_ini + row_number() over (order by p.submetida_em nulls last, p.codigo_aprovacao nulls last, p.criada_em)
    from public.pastas p
   where p.empreendimento_id = v_emp and p.status = 'aprovada' and not exists (select 1 from public.fila_escolha f where f.pasta_id = p.id);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function public.mover_na_fila(p_pasta uuid, p_posicao int) returns void
language plpgsql security definer set search_path = public as $$
declare v_atual int; v_max int; v_nova int; v_emp uuid;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select posicao, empreendimento_id into v_atual, v_emp from public.fila_escolha where pasta_id = p_pasta;
  if v_atual is null then raise exception 'PASTA_FORA_DA_FILA'; end if;
  select max(posicao) into v_max from public.fila_escolha where empreendimento_id = v_emp;
  v_nova := greatest(1, least(p_posicao, v_max));
  if v_nova = v_atual then return; end if;
  if v_nova < v_atual then
    update public.fila_escolha set posicao = posicao + 1 where empreendimento_id = v_emp and posicao >= v_nova and posicao < v_atual;
  else
    update public.fila_escolha set posicao = posicao - 1 where empreendimento_id = v_emp and posicao > v_atual and posicao <= v_nova;
  end if;
  update public.fila_escolha set posicao = v_nova where pasta_id = p_pasta;
end;
$$;

create or replace function public.remover_da_fila(p_pasta uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_pos int; v_emp uuid;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  delete from public.fila_escolha where pasta_id = p_pasta returning posicao, empreendimento_id into v_pos, v_emp;
  if v_pos is not null then update public.fila_escolha set posicao = posicao - 1 where empreendimento_id = v_emp and posicao > v_pos; end if;
end;
$$;

create or replace function public.reservar_pela_fila(p_pasta uuid, p_unidade uuid) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  f public.fila_config;
  p public.pastas;
  u public.unidades;
  v_pos int;
begin
  select * into p from public.pastas where id = p_pasta;
  if not found or not public.acesso_pasta(p.imobiliaria_id, p.criado_por_id) then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  f := public.fila_de(p.empreendimento_id);
  if f is null or not f.ativa then raise exception 'FILA_DESLIGADA'; end if;
  if p.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
  select posicao into v_pos from public.fila_escolha where pasta_id = p_pasta;
  if v_pos is null then raise exception 'PASTA_FORA_DA_FILA'; end if;
  if v_pos > public.fila_liberadas(p.empreendimento_id) then
    raise exception 'PASTA_AINDA_NAO_LIBERADA' using hint = to_char(public.fila_libera_em(v_pos, p.empreendimento_id) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
  end if;
  if (select count(*) from public.negociacoes where pasta_id = p_pasta and ativa) >= f.unidades_por_pasta then
    raise exception 'LIMITE_DE_UNIDADES_DA_PASTA';
  end if;
  select * into u from public.unidades where id = p_unidade for update;
  if not found or u.empreendimento_id <> p.empreendimento_id then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  if u.status <> 'disponivel' then raise exception 'UNIDADE_INDISPONIVEL' using hint = 'Outra pessoa reservou esta unidade agora há pouco.'; end if;

  perform set_config('espelho.sistema', 'sim', true);
  u := public.alterar_status(p_unidade, 'reservada', u.versao, null, null, null, null, null, null, p_pasta);
  perform set_config('espelho.sistema', '', true);
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Unidade reservada pela fila de escolha', jsonb_build_object('unidade', u.numero, 'posicao', v_pos), public.meu_email());
  return u;
end;
$$;

-- ---------------------------------------------------------------------
-- Indicadores, rodadas e painéis
-- ---------------------------------------------------------------------
create or replace function public.indicadores() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  return jsonb_build_object(
    'unidades', (select jsonb_object_agg(status, n) from (select status::text, count(*) n from public.unidades where empreendimento_id = v_emp group by status) s),
    'pastas',   (select jsonb_object_agg(status, n) from (select status, count(*) n from public.pastas where empreendimento_id = v_emp group by status) s),
    'pastas_total', (select count(*) from public.pastas where empreendimento_id = v_emp),
    'pastas_submetidas', (select count(*) from public.pastas where empreendimento_id = v_emp and codigo_aprovacao is not null),
    'vendas_7_dias', (select count(*) from public.historico where empreendimento_id = v_emp and status_novo = 'vendida' and criado_em > now() - interval '7 days'),
    'reservas_7_dias', (select count(*) from public.historico where empreendimento_id = v_emp and status_novo = 'reservada' and criado_em > now() - interval '7 days')
  );
end;
$$;

create or replace function public.rodadas_vagas() returns table (rodada_id uuid, clientes int, pessoas int)
language sql stable security definer set search_path = public as $$
  select r.id, count(i.id)::int, coalesce(sum(i.pessoas), 0)::int
    from public.rodadas r
    left join public.rodada_inscricoes i on i.rodada_id = r.id and not i.cancelada
   where r.empreendimento_id = public.empreendimento_atual() and public.rodada_liberada(r.id)
   group by r.id;
$$;

drop function if exists public.paineis();
create or replace function public.paineis(p_todos boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;

  with
  un as (
    select u.id, u.numero, u.status, u.empreendimento_id, public.preco_tabela_unidade(u.id) as preco
      from public.unidades u where p_todos or u.empreendimento_id = v_emp
  ),
  neg as (
    select n.*, u.status as status_unidade, u.numero
      from public.negociacoes n join public.unidades u on u.id = n.unidade_id
     where n.ativa and (p_todos or n.empreendimento_id = v_emp)
  ),
  pas as (select * from public.pastas p where p_todos or p.empreendimento_id = v_emp),
  vendas_mes as (
    select to_char(date_trunc('month', h.criado_em at time zone 'America/Sao_Paulo'), 'YYYY-MM') as mes, h.status_novo, count(distinct h.unidade_id) as n
      from public.historico h
     where (p_todos or h.empreendimento_id = v_emp)
       and h.status_novo in ('reservada', 'proposta', 'contrato', 'vendida')
       and h.criado_em >= date_trunc('month', now()) - interval '11 months'
     group by 1, 2
  ),
  rank_imob as (
    select coalesce(n.imobiliaria, 'Venda direta') as nome,
           count(*) filter (where n.status_unidade = 'reservada') as reservas,
           count(*) filter (where n.status_unidade in ('proposta', 'contrato', 'vendida')) as vendas,
           count(*) filter (where n.status_unidade = 'vendida') as vendidas,
           coalesce(sum(n.valor_venda) filter (where n.status_unidade in ('proposta', 'contrato', 'vendida')), 0) as vgv
      from neg n group by 1
  ),
  pastas_imob as (
    select i.nome, count(*) filter (where p.status = 'aprovada') as aprovadas, count(*) as total
      from pas p join public.imobiliarias i on i.id = p.imobiliaria_id group by 1
  ),
  rank_corretor as (
    select coalesce(n.corretor, '—') as nome, coalesce(n.imobiliaria, 'Venda direta') as imobiliaria,
           count(*) filter (where n.status_unidade = 'reservada') as reservas,
           count(*) filter (where n.status_unidade in ('proposta', 'contrato', 'vendida')) as vendas,
           coalesce(sum(n.valor_venda) filter (where n.status_unidade in ('proposta', 'contrato', 'vendida')), 0) as vgv
      from neg n group by 1, 2
  ),
  props as (
    select * from public.propostas where status <> 'rascunho' and (p_todos or empreendimento_id = v_emp)
  ),
  por_emp as (
    select e.id, e.sigla, e.nome, e.ordem, e.criado_em,
           (select count(*) from un where un.empreendimento_id = e.id) as unidades,
           (select count(*) from un where un.empreendimento_id = e.id and un.status = 'disponivel') as disponiveis,
           (select count(*) from un where un.empreendimento_id = e.id and un.status = 'vendida') as vendidas,
           (select count(*) from neg where neg.empreendimento_id = e.id and neg.status_unidade in ('proposta', 'contrato', 'vendida')) as vendas,
           (select round(coalesce(sum(preco), 0), 2) from un where un.empreendimento_id = e.id) as vgv_tabela,
           (select round(coalesce(sum(valor_venda), 0), 2) from neg where neg.empreendimento_id = e.id and neg.status_unidade in ('proposta', 'contrato', 'vendida')) as vgv_vendido
      from public.empreendimentos e where p_todos or e.id = v_emp
  )
  select jsonb_build_object(
    'gerado_em', now(),
    'consolidado', p_todos,
    'por_empreendimento', coalesce((select jsonb_agg(jsonb_build_object('sigla', sigla, 'nome', nome, 'unidades', unidades, 'disponiveis', disponiveis,
                                     'vendidas', vendidas, 'vendas', vendas, 'vgv_tabela', vgv_tabela, 'vgv_vendido', vgv_vendido) order by ordem, criado_em) from por_emp), '[]'),
    'unidades', (select jsonb_object_agg(status, jsonb_build_object('n', n, 'vgv_tabela', vgv))
                   from (select status, count(*) n, round(coalesce(sum(preco), 0), 2) vgv from un group by status) x),
    'vgv_tabela_total', (select round(coalesce(sum(preco), 0), 2) from un),
    'vendas', (select jsonb_object_agg(status_unidade, jsonb_build_object('n', n, 'vgv', vgv))
                 from (select status_unidade, count(*) n, round(coalesce(sum(valor_venda), 0), 2) vgv from neg group by 1) x),
    'por_mes', coalesce((select jsonb_agg(jsonb_build_object('mes', mes, 'status', status_novo, 'n', n) order by mes) from vendas_mes), '[]'),
    'funil', jsonb_build_object(
       'pastas', (select count(*) from pas),
       'submetidas', (select count(*) from pas where codigo_aprovacao is not null),
       'aprovadas', (select count(*) from pas where status = 'aprovada'),
       'com_unidade', (select count(distinct pasta_id) from neg where pasta_id is not null),
       'proposta', (select count(*) from neg where status_unidade in ('proposta', 'contrato', 'vendida')),
       'contrato', (select count(*) from neg where status_unidade in ('contrato', 'vendida')),
       'vendida', (select count(*) from neg where status_unidade = 'vendida')),
    'ranking_imobiliarias', coalesce((
       select jsonb_agg(jsonb_build_object('nome', r.nome, 'reservas', r.reservas, 'vendas', r.vendas, 'vendidas', r.vendidas,
                                           'vgv', r.vgv, 'pastas_aprovadas', coalesce(pi.aprovadas, 0), 'pastas', coalesce(pi.total, 0))
                        order by r.vgv desc, r.vendas desc, r.reservas desc)
         from rank_imob r left join pastas_imob pi on pi.nome = r.nome), '[]'),
    'ranking_corretores', coalesce((
       select jsonb_agg(jsonb_build_object('nome', nome, 'imobiliaria', imobiliaria, 'reservas', reservas, 'vendas', vendas, 'vgv', vgv)
                        order by vgv desc, vendas desc, reservas desc)
         from rank_corretor), '[]'),
    'propostas', jsonb_build_object(
       'por_status', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from props group by 1) x), '{}'),
       'automaticas', (select count(*) from props where status = 'aprovada' and analisada_por like 'Aprovação automática%'),
       'pv_medio_aprovadas', (select round(avg((resumo ->> 'pv_pct')::numeric), 2) from props where status = 'aprovada'),
       'horas_medias_analise', (select round(avg(extract(epoch from analisada_em - enviada_em) / 3600)::numeric, 1)
                                  from props where analisada_em is not null and enviada_em is not null
                                   and coalesce(analisada_por, '') not like 'Aprovação automática%'),
       'aguardando_vendas', (select count(*) from props where status = 'enviada' and alcada = 'vendas'),
       'aguardando_admin', (select count(*) from props where status = 'enviada' and alcada = 'admin'),
       'motivos', coalesce((select jsonb_agg(x order by x ->> 'em' desc) from (
          select jsonb_build_object('codigo', codigo, 'status', status, 'motivo', motivo_analise, 'em', analisada_em) x
            from props where status in ('devolvida', 'recusada') and motivo_analise is not null
           order by analisada_em desc limit 8) m), '[]'))
  ) into r;
  return r;
end;
$$;

-- ---------------------------------------------------------------------
-- Cadastro de empreendimento: já nasce com configuração, dados comerciais e fila
-- ---------------------------------------------------------------------
create or replace function public.salvar_empreendimento(p_id uuid, p_nome text, p_slug text, p_sigla text,
  p_ativo boolean default true, p_ordem int default 0) returns public.empreendimentos
language plpgsql security definer set search_path = public as $$
declare v public.empreendimentos; v_base uuid := public.empreendimento_padrao();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_id is null then
    insert into public.empreendimentos (nome, slug, sigla, ativo, ordem)
    values (trim(p_nome), lower(trim(p_slug)), upper(trim(p_sigla)), p_ativo, p_ordem) returning * into v;
    -- identidade: cores e fonte do primeiro empreendimento; módulos desligados; sem logo
    insert into public.config
    select (jsonb_populate_record(null::public.config, to_jsonb(c) || jsonb_build_object(
              'id', nextval('public.config_id_seq'), 'empreendimento_id', v.id, 'nome_empreendimento', v.nome,
              'logo_url', null, 'logo_escuro_url', null, 'imagem_login_url', null, 'publico_ativo', false,
              'modulo_funil', false, 'modulo_portal', false, 'modulo_rodadas', false, 'modulo_meeting', false, 'modulo_tv', false,
              'simulador', jsonb_build_object('cenarios', '[]'::jsonb), 'atualizado_em', now()))).*
      from public.config c where c.empreendimento_id = v_base;
    -- dados comerciais: copiados do primeiro (o administrador ajusta entrega, SPE etc.)
    insert into public.comercial
    select (jsonb_populate_record(null::public.comercial, to_jsonb(c) || jsonb_build_object(
              'id', nextval('public.comercial_id_seq'), 'empreendimento_id', v.id, 'vendedora', null, 'vendedora_cnpj', null,
              'atualizado_em', now()))).*
      from public.comercial c where c.empreendimento_id = v_base;
    insert into public.fila_config (empreendimento_id) values (v.id) on conflict do nothing;
  else
    update public.empreendimentos set nome = trim(p_nome), slug = lower(trim(p_slug)), sigla = upper(trim(p_sigla)),
           ativo = p_ativo, ordem = p_ordem where id = p_id returning * into v;
    if not found then raise exception 'EMPREENDIMENTO_NAO_ENCONTRADO'; end if;
  end if;
  return v;
exception when unique_violation then raise exception 'ENDERECO_OU_SIGLA_EM_USO';
end;
$$;

-- dados comerciais do empreendimento atual (administrador)
create or replace function public.salvar_comercial(p jsonb) returns public.comercial
language plpgsql security definer set search_path = public as $$
declare v public.comercial;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.comercial c set
    mes_entrega = coalesce(date_trunc('month', (p ->> 'mes_entrega')::date)::date, c.mes_entrega),
    taxa_vp = coalesce((p ->> 'taxa_vp')::numeric, c.taxa_vp),
    comissao_pct = coalesce((p ->> 'comissao_pct')::numeric, c.comissao_pct),
    parte_sinal = coalesce((p ->> 'parte_sinal')::numeric, c.parte_sinal),
    alcada_automatica = coalesce((p ->> 'alcada_automatica')::boolean, c.alcada_automatica),
    alcada_auto_pv = coalesce((p ->> 'alcada_auto_pv')::numeric, c.alcada_auto_pv),
    alcada_vendas_pv = coalesce((p ->> 'alcada_vendas_pv')::numeric, c.alcada_vendas_pv),
    vendedora = case when p ? 'vendedora' then nullif(trim(p ->> 'vendedora'), '') else c.vendedora end,
    vendedora_cnpj = case when p ? 'vendedora_cnpj' then nullif(trim(p ->> 'vendedora_cnpj'), '') else c.vendedora_cnpj end,
    cidade_carta = case when p ? 'cidade_carta' then nullif(trim(p ->> 'cidade_carta'), '') else c.cidade_carta end,
    atualizado_em = now()
   where c.empreendimento_id = public.empreendimento_atual() returning * into v;
  return v;
end;
$$;

revoke all on function public.pode_usar_empreendimento(uuid), public.empreendimento_atual(), public.escolher_empreendimento(uuid),
  public.meus_empreendimentos(), public.comercial_de(uuid), public.proximo_codigo(uuid, text), public.pastas_codigo(),
  public.fila_de(uuid), public.fila_liberadas(uuid), public.fila_libera_em(int, uuid), public.paineis(boolean),
  public.salvar_comercial(jsonb), public.fila_escolha_emp(), public.negociacao_mesmo_empreendimento() from public, anon;
grant execute on function public.proximo_codigo(uuid, text) to authenticated;
grant execute on function public.empreendimento_atual() to anon, authenticated;
grant execute on function public.pode_usar_empreendimento(uuid), public.escolher_empreendimento(uuid), public.meus_empreendimentos(),
  public.fila_liberadas(uuid), public.fila_libera_em(int, uuid), public.paineis(boolean), public.salvar_comercial(jsonb) to authenticated;
