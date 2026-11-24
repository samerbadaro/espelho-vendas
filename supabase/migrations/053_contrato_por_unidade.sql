-- =====================================================================
-- 053 · Contrato por unidade (proposta), não por pasta
--   Um cliente pode comprar mais de uma unidade na mesma pasta, e cada uma
--   anda no seu ritmo. A conferência do fluxo de pagamento e da comissão
--   passa a ser por proposta (antes era uma só por pasta). A conferência
--   das partes (dados_contrato) continua por pasta: é o mesmo comprador.
-- =====================================================================
begin;

create table if not exists public.pagamento_contrato (
  proposta_id   uuid primary key references public.propostas(id) on delete cascade,
  pasta_id      uuid not null references public.pastas(id) on delete cascade,
  comissao      jsonb not null default '[]',
  conferido_em  timestamptz,
  conferido_por text,
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
alter table public.pagamento_contrato enable row level security;
drop policy if exists pagamento_contrato_equipe on public.pagamento_contrato;
create policy pagamento_contrato_equipe on public.pagamento_contrato for select using (public.eh_equipe());
grant select on public.pagamento_contrato to authenticated;

-- leva a conferência que estava na pasta para a(s) proposta(s) a que ela se referia:
-- a proposta que já tem documento emitido, ou a única proposta aprovada da pasta
insert into public.pagamento_contrato (proposta_id, pasta_id, comissao, conferido_em, conferido_por, atualizado_em, atualizado_por)
select p.id, d.pasta_id, coalesce(d.comissao, '[]'), d.pagamento_conferido_em, d.pagamento_conferido_por, coalesce(d.atualizado_em, now()), d.atualizado_por
  from public.dados_contrato d
  join public.propostas p on p.pasta_id = d.pasta_id and p.status = 'aprovada'
 where (d.pagamento_conferido_em is not null or jsonb_array_length(coalesce(d.comissao, '[]')) > 0)
   and (exists (select 1 from public.contratos c where c.proposta_id = p.id)
        or (select count(*) from public.propostas q where q.pasta_id = d.pasta_id and q.status = 'aprovada') = 1)
on conflict (proposta_id) do nothing;

drop function if exists public.conferir_pagamento(uuid, jsonb, boolean);
create function public.conferir_pagamento(p_proposta uuid, p_comissao jsonb, p_conferido boolean)
returns public.pagamento_contrato language plpgsql security definer set search_path = public as $$
declare v public.pagamento_contrato; v_pasta uuid;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select pasta_id into v_pasta from public.propostas where id = p_proposta and status = 'aprovada' and pasta_id is not null;
  if v_pasta is null then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  insert into public.pagamento_contrato as x (proposta_id, pasta_id, comissao, conferido_em, conferido_por, atualizado_em, atualizado_por)
  values (p_proposta, v_pasta, coalesce(p_comissao, '[]'), case when p_conferido then now() end, case when p_conferido then public.meu_email() end, now(), public.meu_email())
  on conflict (proposta_id) do update set comissao = excluded.comissao,
     conferido_em = excluded.conferido_em, conferido_por = excluded.conferido_por,
     atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  if p_conferido then
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (v_pasta, 'Fluxo de pagamento conferido para o contrato',
            jsonb_build_object('proposta', (select codigo from public.propostas where id = p_proposta)), public.meu_email());
  end if;
  return v;
end;
$$;
revoke all on function public.conferir_pagamento(uuid, jsonb, boolean) from public, anon;
grant execute on function public.conferir_pagamento(uuid, jsonb, boolean) to authenticated;

create or replace function public.registrar_contrato(p_pasta uuid, p_proposta uuid, p_documento text, p_nome text, p_caminho text, p_dados jsonb, p_caminho_docx text default null)
returns public.contratos language plpgsql security definer set search_path = public as $$
declare v public.contratos; d public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not exists (select 1 from public.propostas where id = p_proposta and pasta_id = p_pasta and status = 'aprovada') then
    raise exception 'PROPOSTA_NAO_APROVADA';
  end if;
  select * into d from public.dados_contrato where pasta_id = p_pasta;
  if d.status is distinct from 'conferido' then raise exception 'DADOS_NAO_CONFERIDOS'; end if;
  -- fluxo de pagamento conferido desta unidade (053)
  if not exists (select 1 from public.pagamento_contrato where proposta_id = p_proposta and conferido_em is not null) then
    raise exception 'PAGAMENTO_NAO_CONFERIDO';
  end if;
  if p_caminho !~ ('^' || p_pasta::text || '/') or (p_caminho_docx is not null and p_caminho_docx !~ ('^' || p_pasta::text || '/')) then
    raise exception 'CAMINHO_INVALIDO';
  end if;
  insert into public.contratos (pasta_id, proposta_id, documento, nome, caminho, caminho_docx, dados, gerado_por)
  values (p_pasta, p_proposta, p_documento, left(p_nome, 200), p_caminho, p_caminho_docx, p_dados, public.meu_email())
  returning * into v;
  insert into public.contrato_versoes (contrato_id, versao, caminho_pdf, caminho_docx, origem, criado_por)
  values (v.id, 1, p_caminho, p_caminho_docx, 'sistema', public.meu_email());
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Contrato emitido', jsonb_build_object('numero', v.numero, 'documento', v.nome), public.meu_email());
  return v;
end;
$$;

commit;
