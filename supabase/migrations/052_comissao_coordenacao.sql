-- =====================================================================
-- 052 · Comissão com coordenação de vendas
--   comissao_pct passa a ser só a da imobiliária (5%); a coordenação de vendas
--   (Kavaná, 0,5%) é paga com o sinal, dividida em 1 a 3 parcelas (padrão 2).
--   O sinal precisa cobrir as duas (5,5% ÷ 70% = 7,86% do valor).
-- =====================================================================
begin;

alter table public.comercial
  add column if not exists coordenacao_pct       numeric(8, 6) not null default 0.005 check (coordenacao_pct >= 0 and coordenacao_pct < 0.05),
  add column if not exists coordenacao_parcelas  int not null default 2 check (coordenacao_parcelas between 1 and 3),
  add column if not exists coordenacao_documento text;

-- 5,25% (regra antiga, total) vira 5% da imobiliária + 0,5% da coordenação
update public.comercial set comissao_pct = 0.05 where id = 1 and comissao_pct = 0.0525;

alter table public.propostas
  add column if not exists coordenacao_pct      numeric(8, 6) check (coordenacao_pct >= 0 and coordenacao_pct < 0.05),
  add column if not exists coordenacao_parcelas int check (coordenacao_parcelas between 1 and 3);

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

  -- comissão = imobiliária (da proposta ou do parâmetro) + coordenação de vendas (052)
  v_com := round(v_total * (coalesce(p_comissao, c.comissao_pct) + coalesce(c.coordenacao_pct, 0)), 2);
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

commit;
