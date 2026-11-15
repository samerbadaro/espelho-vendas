-- =====================================================================
-- 111 — Simulador do Portal com cenários livres
--  * config.simulador passa a ser {"cenarios": [...]}. Cada cenário tem
--    nome (tipologia, metragem, posição...), descrição opcional, de 1 a 6
--    preços de referência (rótulo + valor), captação mínima e fluxo padrão
--    (ato, 30/60/90, mensais, semestrais/anuais, única).
--  * Os dados antigos (Poente/Nascente) viram dois cenários.
--  * Quantidade máxima de parcelas: calculada na tela pela data de entrega.
-- =====================================================================

update public.config
   set simulador = jsonb_build_object('cenarios', (
         select jsonb_agg(jsonb_build_object(
                  'id', k, 'nome', initcap(k), 'descricao', '',
                  'precos', jsonb_build_array(
                     jsonb_build_object('rotulo', 'A partir de', 'valor', (simulador -> k ->> 'a_partir')::numeric),
                     jsonb_build_object('rotulo', 'Preço médio', 'valor', (simulador -> k ->> 'medio')::numeric)),
                  'captacao', (simulador -> k ->> 'captacao')::numeric,
                  'pct', simulador -> k -> 'pct') order by k desc)
           from unnest(array['poente', 'nascente']) k where simulador ? k))
 where id = 1 and simulador ? 'poente' and not simulador ? 'cenarios';

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
  update public.config set simulador = jsonb_build_object('cenarios', p -> 'cenarios'), atualizado_em = now() where id = 1;
end;
$$;
revoke all on function public.salvar_simulador(jsonb) from public, anon;
grant execute on function public.salvar_simulador(jsonb) to authenticated;
