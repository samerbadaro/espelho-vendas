-- =====================================================================
-- 012 — Funil de vendas (kanban) e download de todos os documentos
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Etapa da venda, depois da documentação aprovada
-- ---------------------------------------------------------------------
alter table public.pastas
  add column if not exists etapa_venda text not null default 'aprovada'
    check (etapa_venda in ('aprovada', 'reserva', 'contrato_confeccao', 'enviado_assinatura', 'assinado')),
  add column if not exists etapa_atualizada_em timestamptz;

create function public.mover_etapa(p_pasta uuid, p_etapa text) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare
  v_pasta public.pastas;
  v_rotulo text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if v_pasta.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
  if p_etapa not in ('aprovada', 'reserva', 'contrato_confeccao', 'enviado_assinatura', 'assinado') then
    raise exception 'ETAPA_INVALIDA';
  end if;
  if v_pasta.etapa_venda = p_etapa then return v_pasta; end if;

  update public.pastas set etapa_venda = p_etapa, etapa_atualizada_em = now() where id = p_pasta
  returning * into v_pasta;

  v_rotulo := case p_etapa
    when 'aprovada' then 'Pasta aprovada' when 'reserva' then 'Reserva'
    when 'contrato_confeccao' then 'Contrato em confecção' when 'enviado_assinatura' then 'Enviado para assinatura'
    else 'Assinado / Vendido' end;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Etapa da venda alterada', jsonb_build_object('documento', v_rotulo), public.meu_email());
  return v_pasta;
end;
$$;
revoke all on function public.mover_etapa(uuid, text) from public, anon;
grant execute on function public.mover_etapa(uuid, text) to authenticated;

-- O gatilho de histórico não deve registrar a etapa como "dados alterados"
create or replace function public.pastas_depois() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_campos text[];
begin
  if tg_op = 'INSERT' then
    insert into public.historico_pastas (pasta_id, acao, usuario_email) values (new.id, 'Pasta criada', public.meu_email());
    perform public.recalcular_pasta(new.id);
  else
    select array_agg(n.key order by n.key) into v_campos
      from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value
       and n.key not in ('status', 'atualizada_em', 'unidade_id', 'codigo_aprovacao', 'submetida_em', 'submetida_por',
                         'etapa_venda', 'etapa_atualizada_em');
    if v_campos is not null then
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (new.id, 'Dados alterados', jsonb_build_object('campos', v_campos), public.meu_email());
    end if;
    if new.estado_civil is distinct from old.estado_civil then
      perform public.recalcular_pasta(new.id);
    end if;
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- Sigla de cada tipo de documento (usada no nome dos arquivos baixados)
-- ---------------------------------------------------------------------
alter table public.tipos_documento add column if not exists sigla text;
update public.tipos_documento set sigla = case
  when nome like 'RG ou CNH%' then 'IDENTIFICACAO'
  when nome like 'CPF%' then 'CPF'
  when nome like 'Comprovante de endereço%' then 'ENDERECO'
  when nome = 'Certidão de nascimento' then 'CERTIDAO_NASCIMENTO'
  when nome = 'Certidão de casamento' then 'CERTIDAO_CASAMENTO'
  when nome like 'Escritura ou declaração de união estável%' then 'UNIAO_ESTAVEL'
  when nome like '%averbação do divórcio%' then 'CERTIDAO_DIVORCIO'
  when nome like '%óbito%' then 'CERTIDAO_OBITO'
  when nome = 'Procuração' then 'PROCURACAO'
  when nome = 'Comprovante do PIX' then 'PIX'
  else 'DOCUMENTO' end
where sigla is null;

-- ---------------------------------------------------------------------
-- Lista os documentos atuais de uma pasta para o download completo
-- (somente equipe) e registra o download no histórico
-- ---------------------------------------------------------------------
create function public.registrar_download(p_pasta uuid)
returns table (caminho text, nome_arquivo text, sigla text, pessoa text, nome_pessoa text, codigo text, cliente text)
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into v_pasta from public.pastas where id = p_pasta;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;

  insert into public.historico_pastas (pasta_id, acao, usuario_email)
  values (p_pasta, 'Download de todos os documentos', public.meu_email());

  return query
    select d.caminho, d.nome_arquivo, coalesce(t.sigla, 'DOCUMENTO'), t.pessoa,
           case when t.pessoa = 'conjuge' then coalesce(v_pasta.conjuge_nome, 'CONJUGE') else v_pasta.comprador_nome end,
           coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo), v_pasta.comprador_nome
      from public.documentos d join public.tipos_documento t on t.id = d.tipo_id
     where d.pasta_id = p_pasta and d.atual
     order by t.ordem, d.enviado_em;
end;
$$;
revoke all on function public.registrar_download(uuid) from public, anon;
grant execute on function public.registrar_download(uuid) to authenticated;
