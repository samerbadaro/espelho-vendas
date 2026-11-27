-- 059 — Tabelas de venda editáveis pelo administrador (Propostas › Parâmetros da proposta).
-- Salva as séries de uma tabela de uma vez (tudo ou nada), conferindo que os percentuais somam 100%.
begin;

create or replace function public.salvar_tabela_venda(p_tabela text, p_series jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_soma numeric;
  v_n int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not exists (select 1 from public.tabelas_venda where nome = p_tabela) then raise exception 'TABELA_NAO_ENCONTRADA'; end if;
  if jsonb_typeof(p_series) <> 'array' or jsonb_array_length(p_series) = 0 then raise exception 'SERIES_INVALIDAS'; end if;
  select sum((s ->> 'percentual')::numeric), count(*) into v_soma, v_n from jsonb_array_elements(p_series) s;
  if abs(v_soma - 1) > 0.000001 then
    raise exception 'TABELA_SOMA_INVALIDA' using hint = 'Os percentuais da tabela precisam somar 100% (hoje: ' || round(v_soma * 100, 4) || '%).';
  end if;
  if (select count(*) from jsonb_array_elements(p_series) s where s ->> 'periodicidade' = 'Financiamento') > 1 then
    raise exception 'TABELA_FINANCIAMENTO_DUPLICADO' using hint = 'A tabela só pode ter uma série de financiamento.';
  end if;

  delete from public.tabelas_series where tabela = p_tabela;
  insert into public.tabelas_series (tabela, ordem, rotulo, periodicidade, qtd, percentual, base, meses)
  select p_tabela, row_number() over (order by o), coalesce(nullif(trim(s ->> 'rotulo'), ''), s ->> 'periodicidade'), s ->> 'periodicidade',
         (s ->> 'qtd')::int, (s ->> 'percentual')::numeric, s ->> 'base', (s ->> 'meses')::int
    from jsonb_array_elements(p_series) with ordinality as x(s, o);
  return v_n;
end;
$$;
revoke all on function public.salvar_tabela_venda(text, jsonb) from public, anon;
grant execute on function public.salvar_tabela_venda(text, jsonb) to authenticated;

commit;
