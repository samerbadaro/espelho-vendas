-- =====================================================================
-- 041 — Módulo de contratos
--  * empreendimento_contrato: dados da vendedora e do empreendimento usados
--    no Quadro Resumo (uma linha; edita só o administrador).
--  * unidade_areas: quadro de áreas por unidade (importado da planilha no
--    cadastro do empreendimento; substitui o quadro inteiro).
--  * dados_contrato ganha comissão (beneficiários) e conferência do fluxo
--    de pagamento.
--  * contratos: cada PDF emitido (Quadro Resumo, Normas), com número,
--    validação, assinatura (D4Sign na próxima fase) e cancelamento.
--  * Tudo restrito à equipe (administrador e Sec. Vendas).
-- Executar uma única vez no SQL Editor do Supabase (depois da 040).
-- =====================================================================
begin;

-- Dados da vendedora / empreendimento --------------------------------
create table if not exists public.empreendimento_contrato (
  id             smallint primary key default 1 check (id = 1),
  dados          jsonb not null default '{}'::jsonb,
  atualizado_em  timestamptz not null default now(),
  atualizado_por text
);
alter table public.empreendimento_contrato enable row level security;
drop policy if exists empreendimento_contrato_equipe on public.empreendimento_contrato;
create policy empreendimento_contrato_equipe on public.empreendimento_contrato for select using (public.eh_equipe());
revoke all on public.empreendimento_contrato from anon, authenticated;
grant select on public.empreendimento_contrato to authenticated;

create or replace function public.salvar_empreendimento_contrato(p_dados jsonb) returns public.empreendimento_contrato
language plpgsql security definer set search_path = public as $$
declare v public.empreendimento_contrato;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.empreendimento_contrato (id, dados, atualizado_em, atualizado_por)
  values (1, coalesce(p_dados, '{}'), now(), public.meu_email())
  on conflict (id) do update set dados = excluded.dados, atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  return v;
end;
$$;

-- Quadro de áreas -------------------------------------------------------
create table if not exists public.unidade_areas (
  numero               text primary key,
  torre                text,
  pavimento            text,
  area_privativa       numeric(12,4),
  area_acessoria       numeric(12,4),
  area_privativa_total numeric(12,4),
  area_comum           numeric(12,4),
  area_total           numeric(12,4),
  fracao_ideal         numeric(14,10),
  vagas                text,
  escaninho            text,
  escaninho_local      text,
  escaninho_area       numeric(10,4),
  atualizado_em        timestamptz not null default now()
);
alter table public.unidade_areas enable row level security;
drop policy if exists unidade_areas_equipe on public.unidade_areas;
create policy unidade_areas_equipe on public.unidade_areas for select using (public.eh_equipe());
revoke all on public.unidade_areas from anon, authenticated;
grant select on public.unidade_areas to authenticated;

-- Substitui o quadro inteiro. p_linhas = [{numero, torre, pavimento, area_privativa, ...}]
create or replace function public.importar_quadro_areas(p_linhas jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then raise exception 'PLANILHA_VAZIA'; end if;
  if exists (select 1 from jsonb_array_elements(p_linhas) l where coalesce(trim(l ->> 'numero'), '') = '') then raise exception 'UNIDADE_SEM_NUMERO'; end if;
  if (select count(distinct trim(l ->> 'numero')) from jsonb_array_elements(p_linhas) l) <> jsonb_array_length(p_linhas) then raise exception 'UNIDADE_REPETIDA'; end if;
  delete from public.unidade_areas where true;
  insert into public.unidade_areas (numero, torre, pavimento, area_privativa, area_acessoria, area_privativa_total, area_comum,
                                    area_total, fracao_ideal, vagas, escaninho, escaninho_local, escaninho_area)
  select trim(l ->> 'numero'), nullif(trim(l ->> 'torre'), ''), nullif(trim(l ->> 'pavimento'), ''),
         (l ->> 'area_privativa')::numeric, (l ->> 'area_acessoria')::numeric, (l ->> 'area_privativa_total')::numeric,
         (l ->> 'area_comum')::numeric, (l ->> 'area_total')::numeric, (l ->> 'fracao_ideal')::numeric,
         nullif(trim(l ->> 'vagas'), ''), nullif(trim(l ->> 'escaninho'), ''), nullif(trim(l ->> 'escaninho_local'), ''),
         (l ->> 'escaninho_area')::numeric
    from jsonb_array_elements(p_linhas) l;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Comissão e conferência do pagamento ---------------------------------
alter table public.dados_contrato add column if not exists comissao jsonb not null default '[]'::jsonb;
alter table public.dados_contrato add column if not exists pagamento_conferido_em timestamptz;
alter table public.dados_contrato add column if not exists pagamento_conferido_por text;

create or replace function public.conferir_pagamento(p_pasta uuid, p_comissao jsonb, p_conferido boolean)
returns public.dados_contrato language plpgsql security definer set search_path = public as $$
declare v public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  insert into public.dados_contrato as d (pasta_id, comissao, pagamento_conferido_em, pagamento_conferido_por, atualizado_em, atualizado_por)
  values (p_pasta, coalesce(p_comissao, '[]'), case when p_conferido then now() end, case when p_conferido then public.meu_email() end, now(), public.meu_email())
  on conflict (pasta_id) do update set comissao = excluded.comissao,
     pagamento_conferido_em = excluded.pagamento_conferido_em, pagamento_conferido_por = excluded.pagamento_conferido_por,
     atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  if p_conferido then
    insert into public.historico_pastas (pasta_id, acao, usuario_email) values (p_pasta, 'Fluxo de pagamento conferido para o contrato', public.meu_email());
  end if;
  return v;
end;
$$;

-- Contratos emitidos ------------------------------------------------------
create table if not exists public.contratos (
  id             uuid primary key default gen_random_uuid(),
  numero         bigint generated always as identity (start with 1001) unique,
  pasta_id       uuid not null references public.pastas(id) on delete cascade,
  proposta_id    uuid references public.propostas(id) on delete set null,
  documento      text not null check (documento in ('quadro_resumo', 'normas')),
  nome           text not null,
  caminho        text not null,
  dados          jsonb,
  validacao      text not null default 'aguardando' check (validacao in ('aguardando', 'validado')),
  assinatura     text not null default 'nao_enviado' check (assinatura in ('nao_enviado', 'enviado', 'assinado', 'recusado')),
  gerado_em      timestamptz not null default now(),
  gerado_por     text,
  validado_em    timestamptz,
  validado_por   text,
  cancelado_em   timestamptz,
  cancelado_por  text
);
create index if not exists contratos_pasta_idx on public.contratos (pasta_id);
alter table public.contratos enable row level security;
drop policy if exists contratos_equipe on public.contratos;
create policy contratos_equipe on public.contratos for select using (public.eh_equipe());
revoke all on public.contratos from anon, authenticated;
grant select on public.contratos to authenticated;

create or replace function public.registrar_contrato(p_pasta uuid, p_proposta uuid, p_documento text, p_nome text, p_caminho text, p_dados jsonb)
returns public.contratos language plpgsql security definer set search_path = public as $$
declare v public.contratos; d public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not exists (select 1 from public.propostas where id = p_proposta and pasta_id = p_pasta and status = 'aprovada') then
    raise exception 'PROPOSTA_NAO_APROVADA';
  end if;
  select * into d from public.dados_contrato where pasta_id = p_pasta;
  if d.status is distinct from 'conferido' then raise exception 'DADOS_NAO_CONFERIDOS'; end if;
  if d.pagamento_conferido_em is null then raise exception 'PAGAMENTO_NAO_CONFERIDO'; end if;
  if p_caminho !~ ('^' || p_pasta::text || '/') then raise exception 'CAMINHO_INVALIDO'; end if;
  insert into public.contratos (pasta_id, proposta_id, documento, nome, caminho, dados, gerado_por)
  values (p_pasta, p_proposta, p_documento, left(p_nome, 200), p_caminho, p_dados, public.meu_email())
  returning * into v;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Contrato emitido', jsonb_build_object('numero', v.numero, 'documento', v.nome), public.meu_email());
  return v;
end;
$$;

create or replace function public.validar_contrato(p_id uuid) returns public.contratos
language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contratos set validacao = 'validado', validado_em = now(), validado_por = public.meu_email()
   where id = p_id and cancelado_em is null returning * into v;
  if v.id is null then raise exception 'CONTRATO_NAO_ENCONTRADO'; end if;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato validado', jsonb_build_object('numero', v.numero), public.meu_email());
  return v;
end;
$$;

create or replace function public.cancelar_contrato(p_id uuid) returns public.contratos
language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contratos set cancelado_em = now(), cancelado_por = public.meu_email()
   where id = p_id and cancelado_em is null and assinatura <> 'assinado' returning * into v;
  if v.id is null then raise exception 'NAO_PODE_CANCELAR'; end if;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato cancelado', jsonb_build_object('numero', v.numero), public.meu_email());
  return v;
end;
$$;

-- Arquivos: bucket privado, só a equipe lê e grava ("<pasta>/<arquivo>.pdf")
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('contratos', 'contratos', false, 26214400, array['application/pdf'])
on conflict (id) do update set public = false;
drop policy if exists contratos_leitura on storage.objects;
drop policy if exists contratos_envio on storage.objects;
create policy contratos_leitura on storage.objects for select to authenticated using (bucket_id = 'contratos' and public.eh_equipe());
create policy contratos_envio on storage.objects for insert to authenticated with check (bucket_id = 'contratos' and public.eh_equipe());

revoke all on function public.salvar_empreendimento_contrato(jsonb), public.importar_quadro_areas(jsonb),
  public.conferir_pagamento(uuid, jsonb, boolean), public.registrar_contrato(uuid, uuid, text, text, text, jsonb),
  public.validar_contrato(uuid), public.cancelar_contrato(uuid) from public, anon;
grant execute on function public.salvar_empreendimento_contrato(jsonb), public.importar_quadro_areas(jsonb),
  public.conferir_pagamento(uuid, jsonb, boolean), public.registrar_contrato(uuid, uuid, text, text, text, jsonb),
  public.validar_contrato(uuid), public.cancelar_contrato(uuid) to authenticated;

commit;
