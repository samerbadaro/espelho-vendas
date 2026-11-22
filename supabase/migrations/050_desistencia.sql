-- =====================================================================
-- 050 · Desistência do cliente
--   "Cliente desistiu": com Pix cadastrado a pasta vai para "Devolução de Pix";
--   sem Pix, direto para "Cliente cancelado". Depois de devolver o Pix,
--   a equipe confirma e a pasta passa a "Cliente cancelado".
-- =====================================================================
begin;

alter table public.pastas drop constraint if exists pastas_status_check;
alter table public.pastas add constraint pastas_status_check
  check (status in ('incompleta', 'pronta', 'aguardando_analise', 'em_analise', 'pendente_correcao', 'aprovada', 'devolucao_pix', 'cancelada'));

alter table public.pastas add column if not exists desistencia_em timestamptz;
alter table public.pastas add column if not exists desistencia_por text;
alter table public.pastas add column if not exists desistencia_motivo text;
alter table public.pastas add column if not exists status_antes_desistencia text;
alter table public.pastas add column if not exists pix_devolvido_em timestamptz;
alter table public.pastas add column if not exists pix_devolvido_por text;
alter table public.pastas add column if not exists pix_devolucao_obs text;

-- Pasta de cliente que desistiu não muda mais de status sozinha (documentos, recálculos, submissão)
create or replace function public.pastas_trava_desistencia() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.status in ('devolucao_pix', 'cancelada')
     and new.status not in ('devolucao_pix', 'cancelada')
     and coalesce(current_setting('app.desistencia', true), '') <> 'ok' then
    new.status := old.status;
  end if;
  return new;
end;
$$;
drop trigger if exists pastas_trava_desistencia on public.pastas;
create trigger pastas_trava_desistencia before update of status on public.pastas
  for each row execute function public.pastas_trava_desistencia();
revoke all on function public.pastas_trava_desistencia() from public, anon, authenticated;

-- Não aceita documentos novos em pasta de cliente que desistiu
create or replace function public.documentos_trava_desistencia() returns trigger
language plpgsql set search_path = public as $$
begin
  if exists (select 1 from public.pastas where id = new.pasta_id and status in ('devolucao_pix', 'cancelada')) then
    raise exception 'PASTA_CANCELADA' using hint = 'O cliente desistiu: a pasta não recebe documentos.';
  end if;
  return new;
end;
$$;
drop trigger if exists documentos_trava_desistencia on public.documentos;
create trigger documentos_trava_desistencia before insert on public.documentos
  for each row execute function public.documentos_trava_desistencia();
revoke all on function public.documentos_trava_desistencia() from public, anon, authenticated;

-- Tem Pix cadastrado? (comprovante anexado ou cobrança Pix paga)
create or replace function public.pasta_tem_pix(p_pasta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.documentos d join public.tipos_documento t on t.id = d.tipo_id
                  where d.pasta_id = p_pasta and d.atual and t.eh_pix and d.status <> 'recusado')
      or public.pix_pago(p_pasta);
$$;
revoke all on function public.pasta_tem_pix(uuid) from public, anon, authenticated;

-- Botão "Cliente desistiu": a imobiliária dona da pasta ou a equipe
create or replace function public.cliente_desistiu(p_pasta uuid, p_motivo text) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v public.pastas; v_pix boolean; v_novo text; v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  select * into v from public.pastas where id = p_pasta for update;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if not public.acesso_pasta(v.imobiliaria_id, v.criado_por_id) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if v.status in ('devolucao_pix', 'cancelada') then raise exception 'JA_DESISTIU'; end if;
  if v_motivo is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  if exists (select 1 from public.negociacoes where pasta_id = p_pasta and ativa) then
    raise exception 'UNIDADE_VINCULADA' using hint = 'Libere a unidade no espelho antes de registrar a desistência.';
  end if;

  v_pix := public.pasta_tem_pix(p_pasta);
  v_novo := case when v_pix then 'devolucao_pix' else 'cancelada' end;

  perform set_config('app.desistencia', 'ok', true);
  update public.pastas
     set status = v_novo, status_antes_desistencia = v.status,
         desistencia_em = now(), desistencia_por = public.meu_email(), desistencia_motivo = left(v_motivo, 500)
   where id = p_pasta
  returning * into v;
  perform set_config('app.desistencia', '', true);

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Cliente desistiu',
          jsonb_build_object('motivo', v_motivo, 'pix_cadastrado', v_pix, 'status_anterior', v.status_antes_desistencia),
          public.meu_email());
  return v;
end;
$$;
revoke all on function public.cliente_desistiu(uuid, text) from public, anon;
grant execute on function public.cliente_desistiu(uuid, text) to authenticated;

-- Equipe confirma que devolveu o Pix: a pasta passa a "Cliente cancelado"
create or replace function public.confirmar_devolucao_pix(p_pasta uuid, p_obs text default null) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v public.pastas;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into v from public.pastas where id = p_pasta for update;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if v.status <> 'devolucao_pix' then raise exception 'NAO_ESTA_NA_DEVOLUCAO'; end if;

  perform set_config('app.desistencia', 'ok', true);
  update public.pastas
     set status = 'cancelada', pix_devolvido_em = now(), pix_devolvido_por = public.meu_email(),
         pix_devolucao_obs = left(nullif(trim(coalesce(p_obs, '')), ''), 500)
   where id = p_pasta
  returning * into v;
  perform set_config('app.desistencia', '', true);

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pix devolvido: cliente cancelado', jsonb_build_object('observacao', nullif(trim(coalesce(p_obs, '')), '')), public.meu_email());
  return v;
end;
$$;
revoke all on function public.confirmar_devolucao_pix(uuid, text) from public, anon;
grant execute on function public.confirmar_devolucao_pix(uuid, text) to authenticated;

commit;
