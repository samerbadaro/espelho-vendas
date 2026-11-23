-- =====================================================================
-- 051 · Espelho acompanha o envelope de assinatura
--   envelope enviado   → unidade "Contrato em assinatura"
--   todos assinaram    → unidade "Vendida"
--   envelope cancelado → unidade volta para "Proposta recebida"
--   Chamada só pelo servidor (service_role), depois de cada evento da D4Sign.
-- =====================================================================
begin;

create or replace function public.contrato_espelho(p_envelope uuid, p_evento text) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_env  public.envelopes;
  v_uni  public.unidades;
  v_novo public.status_unidade;
begin
  if p_evento not in ('enviado', 'assinado', 'cancelado') then raise exception 'EVENTO_INVALIDO'; end if;
  select * into v_env from public.envelopes where id = p_envelope;
  if not found or v_env.proposta_id is null then return 'sem proposta'; end if;
  select u.* into v_uni from public.unidades u join public.propostas p on p.unidade_id = u.id where p.id = v_env.proposta_id;
  if not found then return 'sem unidade'; end if;

  v_novo := case
    when p_evento = 'enviado'   and v_uni.status in ('reservada', 'proposta')             then 'contrato'::public.status_unidade
    when p_evento = 'assinado'  and v_uni.status in ('reservada', 'proposta', 'contrato') then 'vendida'::public.status_unidade
    when p_evento = 'cancelado' and v_uni.status = 'contrato' then
      case when exists (select 1 from public.negociacoes n where n.unidade_id = v_uni.id and n.ativa and n.valor_venda is not null and n.pv_aprovado is not null)
           then 'proposta'::public.status_unidade else 'reservada'::public.status_unidade end
  end;
  if v_novo is null then return 'sem mudança (' || v_uni.status || ')'; end if;

  perform set_config('espelho.sistema', 'sim', true);
  perform public.alterar_status(v_uni.id, v_novo, v_uni.versao,
    case p_evento when 'cancelado' then 'Envelope de assinatura cancelado' end,
    null, null, null, null, null, v_env.pasta_id);
  perform set_config('espelho.sistema', '', true);
  return v_uni.status || ' → ' || v_novo;
end;
$$;
revoke all on function public.contrato_espelho(uuid, text) from public, anon, authenticated;
grant execute on function public.contrato_espelho(uuid, text) to service_role;

commit;
