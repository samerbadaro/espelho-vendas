-- 056 — Contraproposta: quem analisa devolve a proposta já alterada.
-- Fica guardada a versão enviada pelo corretor (proposta_original) e a da equipe (contraproposta),
-- para comparar. Se o corretor aceitar a contraproposta sem mexer, ela é aprovada na hora
-- (quem contrapropôs já tinha alçada para aquele PV).
begin;

alter table public.propostas
  add column if not exists proposta_original jsonb,
  add column if not exists contraproposta jsonb;

-- ---------------------------------------------------------------------
-- Contrapropor uma proposta em análise
-- p_dados: { series, resumo, comissao_pct, parte_sinal, coordenacao_pct, coordenacao_parcelas }
-- ---------------------------------------------------------------------
create or replace function public.contrapropor(p_id uuid, p_dados jsonb, p_motivo text) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v public.propostas;
  c public.comercial;
  r jsonb;
  v_email text := (select email from public.perfis where user_id = auth.uid());
  v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
  v_grupo boolean := coalesce(current_setting('propostas.grupo', true), '') = 'sim';
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into v from public.propostas where id = p_id for update;
  if not found then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  if v.grupo_id is not null and not v_grupo then raise exception 'PROPOSTA_EM_GRUPO' using hint = 'Proposta conjunta: contraproponha pelo grupo.'; end if;
  if v.status <> 'enviada' then raise exception 'PROPOSTA_NAO_ENVIADA'; end if;
  if v_motivo is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  if jsonb_typeof(p_dados -> 'series') <> 'array' or jsonb_array_length(p_dados -> 'series') = 0 then raise exception 'SERIES_INVALIDAS'; end if;

  select * into c from public.comercial where id = 1;
  r := public.pv_proposta(v.unidade_id, p_dados -> 'series', coalesce((p_dados ->> 'comissao_pct')::numeric, v.comissao_pct));
  -- a Sec. Vendas só contrapropõe dentro da sua alçada (no grupo, a conferência é feita sobre o conjunto)
  if not v_grupo and not public.eh_admin() and (r ->> 'pv_pct')::numeric < c.alcada_vendas_pv then
    raise exception 'ALCADA_ADMIN' using hint = 'PV abaixo do limite da Sec. Vendas: só o administrador faz esta contraproposta.';
  end if;

  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas
     set proposta_original = jsonb_build_object(
           'series', v.series, 'resumo', v.resumo, 'comissao_pct', v.comissao_pct, 'parte_sinal', v.parte_sinal,
           'coordenacao_pct', v.coordenacao_pct, 'coordenacao_parcelas', v.coordenacao_parcelas, 'enviada_em', v.enviada_em),
         contraproposta = jsonb_build_object('series', p_dados -> 'series', 'por', v_email, 'em', now(), 'motivo', v_motivo),
         series = p_dados -> 'series',
         resumo = coalesce(p_dados -> 'resumo', '{}') || r,
         comissao_pct = coalesce((p_dados ->> 'comissao_pct')::numeric, v.comissao_pct),
         parte_sinal = coalesce((p_dados ->> 'parte_sinal')::numeric, v.parte_sinal),
         coordenacao_pct = coalesce((p_dados ->> 'coordenacao_pct')::numeric, v.coordenacao_pct),
         coordenacao_parcelas = coalesce((p_dados ->> 'coordenacao_parcelas')::int, v.coordenacao_parcelas),
         status = 'devolvida', motivo_analise = v_motivo, analisada_por = v_email, analisada_em = now()
   where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);
  return v;
end;
$$;
revoke all on function public.contrapropor(uuid, jsonb, text) from public, anon;
grant execute on function public.contrapropor(uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------
-- Contraproposta de uma proposta conjunta: uma entrada por proposta do grupo
-- p_itens: [{ id, dados }]
-- ---------------------------------------------------------------------
create or replace function public.contrapropor_grupo(p_grupo uuid, p_itens jsonb, p_motivo text) returns setof public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v public.propostas;
  c public.comercial;
  r jsonb;
  item jsonb;
  v_vt numeric := 0; v_vp numeric := 0; v_n int := 0;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into c from public.comercial where id = 1;
  for v in select * from public.propostas where grupo_id = p_grupo and status <> 'cancelada' order by codigo for update loop
    select x into item from jsonb_array_elements(p_itens) x where x ->> 'id' = v.id::text;
    if item is null then raise exception 'GRUPO_INCOMPLETO' using hint = 'A contraproposta precisa trazer todas as unidades do grupo.'; end if;
    r := public.pv_proposta(v.unidade_id, item -> 'dados' -> 'series', coalesce((item -> 'dados' ->> 'comissao_pct')::numeric, v.comissao_pct));
    v_vt := v_vt + (r ->> 'vpl_tabela')::numeric;
    v_vp := v_vp + (r ->> 'vpl_proposta')::numeric;
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  if not public.eh_admin() and round(v_vp / nullif(v_vt, 0) * 100, 2) < c.alcada_vendas_pv then
    raise exception 'ALCADA_ADMIN' using hint = 'PV abaixo do limite da Sec. Vendas: só o administrador faz esta contraproposta.';
  end if;

  perform set_config('propostas.grupo', 'sim', true);
  for item in select * from jsonb_array_elements(p_itens) loop
    perform public.contrapropor((item ->> 'id')::uuid, item -> 'dados', p_motivo);
  end loop;
  perform set_config('propostas.grupo', '', true);
  return query select * from public.propostas where grupo_id = p_grupo order by codigo;
end;
$$;
revoke all on function public.contrapropor_grupo(uuid, jsonb, text) from public, anon;
grant execute on function public.contrapropor_grupo(uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------
-- Aceitar a contraproposta sem alterar: aprova na hora (a proposta inteira, se for conjunta)
-- ---------------------------------------------------------------------
create or replace function public.aceitar_contraproposta(p_id uuid) returns setof public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v0 public.propostas;
  v  public.propostas;
begin
  select * into v0 from public.propostas where id = p_id;
  if not found or not public.acesso_pasta(v0.imobiliaria_id, v0.criado_por_id) then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  for v in select * from public.propostas
            where (id = p_id or (v0.grupo_id is not null and grupo_id = v0.grupo_id)) and status <> 'cancelada'
            order by codigo for update loop
    if not public.acesso_pasta(v.imobiliaria_id, v.criado_por_id) then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
    if v.status <> 'devolvida' or v.contraproposta is null then raise exception 'SEM_CONTRAPROPOSTA'; end if;
    if v.series is distinct from v.contraproposta -> 'series' then
      raise exception 'CONTRAPROPOSTA_ALTERADA' using hint = 'A proposta foi alterada depois da contraproposta: envie para análise.';
    end if;
    if v.pasta_id is null then raise exception 'PASTA_OBRIGATORIA' using hint = 'Vincule a pasta do comprador antes de aceitar.'; end if;
  end loop;

  for v in select * from public.propostas
            where (id = p_id or (v0.grupo_id is not null and grupo_id = v0.grupo_id)) and status <> 'cancelada'
            order by codigo loop
    perform set_config('propostas.funcao', 'sim', true);
    update public.propostas set status = 'enviada', enviada_em = now(), motivo_analise = null where id = v.id;
    perform set_config('propostas.funcao', '', true);
    perform public.aprovar_proposta_interno(v.id, 'Contraproposta aceita (feita por ' || coalesce(v.contraproposta ->> 'por', 'equipe') || ')');
  end loop;
  return query select * from public.propostas
                where (id = p_id or (v0.grupo_id is not null and grupo_id = v0.grupo_id)) order by codigo;
end;
$$;
revoke all on function public.aceitar_contraproposta(uuid) from public, anon;
grant execute on function public.aceitar_contraproposta(uuid) to authenticated;

commit;
