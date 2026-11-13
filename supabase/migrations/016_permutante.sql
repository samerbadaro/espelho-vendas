-- =====================================================================
-- 016 — Novo status de unidade: Permutante
--  Funciona como "Bloqueada": a unidade fica fora da venda, não entra em
--  negociação e não pode ser reservada nem movida pelo funil.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter type public.status_unidade add value if not exists 'permutante';

create or replace function public.mover_etapa(p_pasta uuid, p_etapa text, p_unidade uuid default null) returns public.pastas
language plpgsql security definer set search_path = public as $fn$
declare
  v_pasta    public.pastas;
  v_unidade  public.unidades;
  v_neg      public.negociacoes;
  v_novo     public.status_unidade;
  v_anterior public.status_unidade;
  v_email    text := public.meu_email();
  v_rotulo   text;
  v_imob     text;
  v_corretor text;
  v_codigo   text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_etapa not in ('aprovada', 'reserva', 'contrato_confeccao', 'enviado_assinatura', 'assinado') then
    raise exception 'ETAPA_INVALIDA';
  end if;
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if v_pasta.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
  if p_unidade is null then raise exception 'SEM_UNIDADE'; end if;

  v_codigo := coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo);
  v_rotulo := case p_etapa
    when 'aprovada' then 'Pasta aprovada' when 'reserva' then 'Reserva'
    when 'contrato_confeccao' then 'Contrato em confecção' when 'enviado_assinatura' then 'Enviado para assinatura'
    else 'Assinado / Vendido' end;
  v_novo := case p_etapa
    when 'aprovada' then 'disponivel' when 'reserva' then 'reservada' when 'contrato_confeccao' then 'proposta'
    when 'enviado_assinatura' then 'contrato' else 'vendida' end;

  select * into v_unidade from public.unidades where id = p_unidade for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  select * into v_neg from public.negociacoes where unidade_id = p_unidade and ativa for update;

  -- ---------- volta para "Pasta aprovada": libera esta unidade ----------
  if p_etapa = 'aprovada' then
    if v_neg.pasta_id is distinct from p_pasta then raise exception 'UNIDADE_DE_OUTRA_PASTA'; end if;
    v_anterior := v_unidade.status;
    update public.negociacoes set ativa = false, encerrada_em = now(), atualizada_em = now(),
           motivo_encerramento = 'Card voltou para "Pasta aprovada" no funil de vendas'
     where id = v_neg.id;
    update public.unidades set status = 'disponivel', versao = versao + 1, atualizado_em = now()
     where id = p_unidade returning * into v_unidade;
    insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
    values (v_unidade.id, v_unidade.numero, v_anterior, 'disponivel', 'Card voltou para "Pasta aprovada" no funil de vendas',
            auth.uid(), v_email, jsonb_build_object('pasta', v_codigo));
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (p_pasta, 'Unidade liberada', jsonb_build_object('unidade', v_unidade.numero, 'documento', 'Funil de vendas'), v_email);
    select * into v_pasta from public.pastas where id = p_pasta;
    return v_pasta;
  end if;

  -- ---------- demais etapas ----------
  if v_unidade.status in ('bloqueada', 'permutante')
     or (v_unidade.status <> 'disponivel' and v_neg.pasta_id is distinct from p_pasta) then
    raise exception 'UNIDADE_OCUPADA' using hint = v_unidade.numero;
  end if;

  select i.nome into v_imob from public.imobiliarias i where i.id = v_pasta.imobiliaria_id;
  select coalesce(nullif(pf.nome, ''), pf.email) into v_corretor from public.perfis pf where pf.user_id = v_pasta.criado_por_id;

  if v_neg.id is null then
    insert into public.negociacoes (unidade_id, pasta_id, imobiliaria, corretor, cliente, criado_por)
    values (p_unidade, p_pasta, v_imob, coalesce(v_corretor, v_pasta.criado_por), v_pasta.comprador_nome, v_email);
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (p_pasta, 'Unidade vinculada', jsonb_build_object('unidade', v_unidade.numero), v_email);
  else
    update public.negociacoes set atualizada_em = now() where id = v_neg.id;
  end if;

  if v_unidade.status <> v_novo then
    v_anterior := v_unidade.status;
    update public.unidades set status = v_novo, versao = versao + 1, atualizado_em = now()
     where id = p_unidade returning * into v_unidade;
    insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
    values (v_unidade.id, v_unidade.numero, v_anterior, v_novo, 'Funil de vendas: ' || v_rotulo, auth.uid(), v_email,
            jsonb_build_object('pasta', v_codigo, 'cliente', v_pasta.comprador_nome));
  end if;

  update public.pastas set etapa_atualizada_em = now() where id = p_pasta;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Etapa da venda alterada', jsonb_build_object('documento', v_rotulo, 'unidade', v_unidade.numero), v_email);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$fn$;
revoke all on function public.mover_etapa(uuid, text, uuid) from public, anon;
grant execute on function public.mover_etapa(uuid, text, uuid) to authenticated;

-- Espelho: liberar para Permutante encerra a negociação, como Bloqueada
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
  if not public.eh_equipe() then
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
revoke all on function public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric, uuid) from public, anon;
grant execute on function public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric, uuid) to authenticated;
