-- 055 — Proposta conjunta: o cliente escolhe várias unidades numa simulação só.
-- Cada unidade continua com a sua proposta (e depois o seu contrato e a sua assinatura);
-- as propostas ficam ligadas por grupo_id e são enviadas e analisadas juntas.
-- A alçada é calculada sobre o conjunto (soma dos valores presentes), para nenhuma
-- unidade cair de alçada sozinha por causa de centavos da divisão.
begin;

alter table public.propostas add column if not exists grupo_id uuid;
create index if not exists propostas_grupo_idx on public.propostas (grupo_id) where grupo_id is not null;

-- ---------------------------------------------------------------------
-- Envio individual: proposta de grupo só vai pelo envio do grupo
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
  if v.grupo_id is not null then raise exception 'PROPOSTA_EM_GRUPO' using hint = 'Proposta conjunta: envie pelo grupo.'; end if;
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
-- Envio do grupo: valida todas, calcula a alçada do conjunto e envia juntas
-- ---------------------------------------------------------------------
create or replace function public.enviar_grupo(p_grupo uuid) returns setof public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v   public.propostas;
  c   public.comercial;
  r   jsonb;
  v_vt numeric := 0; v_vp numeric := 0; v_sinal numeric := 0; v_com numeric := 0; v_n int := 0;
  v_pv numeric; v_alcada text;
begin
  select * into c from public.comercial where id = 1;
  for v in select * from public.propostas where grupo_id = p_grupo and status <> 'cancelada' order by codigo for update loop
    if not public.acesso_pasta(v.imobiliaria_id, v.criado_por_id) then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
    if v.status not in ('rascunho', 'devolvida') then raise exception 'PROPOSTA_BLOQUEADA'; end if;
    if v.pasta_id is null then raise exception 'PASTA_OBRIGATORIA' using hint = 'Vincule a pasta do comprador antes de enviar.'; end if;
    if jsonb_array_length(v.series) = 0 then raise exception 'SERIES_INVALIDAS'; end if;
    if exists (select 1 from jsonb_array_elements(v.series) s where s ->> 'periodicidade' = 'Permuta')
       and length(trim(coalesce(v.observacoes, ''))) < 5 then
      raise exception 'PERMUTA_SEM_OBSERVACAO' using hint = 'Descreva a permuta nas observações da proposta.';
    end if;
    r := public.pv_proposta(v.unidade_id, v.series, v.comissao_pct);
    v_vt := v_vt + (r ->> 'vpl_tabela')::numeric;
    v_vp := v_vp + (r ->> 'vpl_proposta')::numeric;
    v_sinal := v_sinal + (r ->> 'sinal')::numeric;
    v_com := v_com + (r ->> 'comissao')::numeric;
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;

  v_pv := round(v_vp / nullif(v_vt, 0) * 100, 2);
  v_alcada := case
    when c.alcada_automatica and v_pv >= c.alcada_auto_pv and v_sinal * c.parte_sinal + 0.01 * v_n >= v_com then 'automatica'
    when v_pv >= c.alcada_vendas_pv then 'vendas'
    else 'admin' end;

  perform set_config('propostas.funcao', 'sim', true);
  for v in select * from public.propostas where grupo_id = p_grupo and status <> 'cancelada' order by codigo loop
    r := public.pv_proposta(v.unidade_id, v.series, v.comissao_pct);
    update public.propostas
       set status = 'enviada', enviada_em = now(), motivo_analise = null, alcada = v_alcada,
           resumo = coalesce(resumo, '{}') || r || jsonb_build_object('pv_pct_grupo', v_pv)
     where id = v.id;
  end loop;
  perform set_config('propostas.funcao', '', true);

  if v_alcada = 'automatica' then
    for v in select * from public.propostas where grupo_id = p_grupo and status = 'enviada' order by codigo loop
      perform public.aprovar_proposta_interno(v.id, 'Aprovação automática (PV do conjunto ' || v_pv || '%)');
    end loop;
  end if;
  return query select * from public.propostas where grupo_id = p_grupo order by codigo;
end;
$$;
revoke all on function public.enviar_grupo(uuid) from public, anon;
grant execute on function public.enviar_grupo(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Análise individual: proposta de grupo só se analisa pelo grupo
-- (o cancelamento de uma unidade só continua permitido: desistência de uma delas)
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
  if v.grupo_id is not null and p_decisao <> 'cancelada' and coalesce(current_setting('propostas.grupo', true), '') <> 'sim' then
    raise exception 'PROPOSTA_EM_GRUPO' using hint = 'Proposta conjunta: analise pelo grupo.';
  end if;
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

-- ---------------------------------------------------------------------
-- Análise do grupo: a mesma decisão para todas, tudo ou nada
-- ---------------------------------------------------------------------
create or replace function public.analisar_grupo(p_grupo uuid, p_decisao text, p_motivo text default null) returns setof public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v public.propostas;
  v_n int := 0;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  perform set_config('propostas.grupo', 'sim', true);
  for v in select * from public.propostas where grupo_id = p_grupo and status <> 'cancelada' order by codigo for update loop
    perform public.analisar_proposta(v.id, p_decisao, p_motivo);
    v_n := v_n + 1;
  end loop;
  perform set_config('propostas.grupo', '', true);
  if v_n = 0 then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  return query select * from public.propostas where grupo_id = p_grupo order by codigo;
end;
$$;
revoke all on function public.analisar_grupo(uuid, text, text) from public, anon;
grant execute on function public.analisar_grupo(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- Tirar uma unidade da simulação conjunta (só rascunho ou devolvida, por quem edita)
-- ---------------------------------------------------------------------
create or replace function public.retirar_do_grupo(p_id uuid) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v public.propostas;
begin
  select * into v from public.propostas where id = p_id for update;
  if not found or not public.acesso_pasta(v.imobiliaria_id, v.criado_por_id) then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  if v.status not in ('rascunho', 'devolvida') then raise exception 'PROPOSTA_BLOQUEADA'; end if;
  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas
     set status = 'cancelada', motivo_analise = 'Unidade retirada da proposta conjunta',
         analisada_por = (select email from public.perfis where user_id = auth.uid()), analisada_em = now()
   where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);
  return v;
end;
$$;
revoke all on function public.retirar_do_grupo(uuid) from public, anon;
grant execute on function public.retirar_do_grupo(uuid) to authenticated;

commit;
