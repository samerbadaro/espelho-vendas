-- =====================================================================
-- 026 — Alçadas de aprovação e PV calculado pelo banco
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
