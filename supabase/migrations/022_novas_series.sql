-- =====================================================================
-- 022 — Novas séries: Bimestrais, Trimestrais e Permuta
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
