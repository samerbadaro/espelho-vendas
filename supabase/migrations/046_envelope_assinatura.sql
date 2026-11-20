-- =====================================================================
-- 046 — Envelope único de assinatura por pasta
--  * Boas práticas: um envelope por venda. O Quadro Resumo é o documento
--    principal; Normas, Carta Proposta e os documentos fixos do empreendimento
--    (memorial, plantas, convenção…) vão como anexos do mesmo envelope.
--  * contrato_anexos_fixos: documentos fixos cadastrados pelo administrador.
--  * envelopes: o que foi enviado (versões congeladas), situação e pacote assinado.
--  * envelope_assinantes: quem assina, ordem, canal, se já assinou.
--  * Enquanto há envelope ativo, os documentos ficam travados (sem ajuste).
--  * Substitui a assinatura por documento da 044 (contrato_assinantes sai).
-- Executar uma única vez no SQL Editor do Supabase (depois da 045).
-- =====================================================================
begin;

-- Carta proposta também é emitida no módulo
alter table public.contratos drop constraint if exists contratos_documento_check;
alter table public.contratos add constraint contratos_documento_check check (documento in ('quadro_resumo', 'normas', 'carta_proposta'));

-- Documentos fixos do empreendimento
create table if not exists public.contrato_anexos_fixos (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  caminho     text not null check (caminho ~ '^fixos/'),
  arquivo     text,
  ordem       int not null default 100,
  ativo       boolean not null default true,
  enviado_em  timestamptz not null default now(),
  enviado_por text
);
alter table public.contrato_anexos_fixos enable row level security;
drop policy if exists contrato_anexos_fixos_equipe on public.contrato_anexos_fixos;
create policy contrato_anexos_fixos_equipe on public.contrato_anexos_fixos for select using (public.eh_equipe());
revoke all on public.contrato_anexos_fixos from anon, authenticated;
grant select on public.contrato_anexos_fixos to authenticated;

create or replace function public.salvar_anexo_fixo(p_nome text, p_caminho text, p_arquivo text, p_ordem int)
returns public.contrato_anexos_fixos language plpgsql security definer set search_path = public as $$
declare v public.contrato_anexos_fixos;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.contrato_anexos_fixos (nome, caminho, arquivo, ordem, enviado_por)
  values (left(trim(p_nome), 150), p_caminho, left(p_arquivo, 200), coalesce(p_ordem, 100), public.meu_email()) returning * into v;
  return v;
end;
$$;
create or replace function public.alterar_anexo_fixo(p_id uuid, p_nome text, p_ordem int, p_ativo boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contrato_anexos_fixos set nome = coalesce(left(trim(p_nome), 150), nome), ordem = coalesce(p_ordem, ordem), ativo = coalesce(p_ativo, ativo) where id = p_id;
end;
$$;

-- Envelopes
create table if not exists public.envelopes (
  id               uuid primary key default gen_random_uuid(),
  pasta_id         uuid not null references public.pastas(id) on delete cascade,
  proposta_id      uuid references public.propostas(id) on delete set null,
  d4sign_uuid      text unique,
  status           text not null default 'preparado' check (status in ('preparado', 'enviado', 'assinado', 'cancelado')),
  documentos       jsonb not null default '[]'::jsonb,   -- [{tipo, id, nome, versao, arquivo, d4sign_uuid}]
  criado_em        timestamptz not null default now(),
  criado_por       text,
  enviado_em       timestamptz,
  assinado_em      timestamptz,
  caminho_assinado text,
  cancelado_em     timestamptz,
  cancelado_por    text
);
create unique index if not exists envelopes_um_ativo on public.envelopes (pasta_id) where status in ('preparado', 'enviado');
alter table public.envelopes enable row level security;
drop policy if exists envelopes_equipe on public.envelopes;
create policy envelopes_equipe on public.envelopes for select using (public.eh_equipe());
revoke all on public.envelopes from anon, authenticated;
grant select on public.envelopes to authenticated;

create table if not exists public.envelope_assinantes (
  id            bigint generated always as identity primary key,
  envelope_id   uuid not null references public.envelopes(id) on delete cascade,
  ordem         int not null default 1,
  papel         text not null,
  nome          text,
  email         text not null,
  whatsapp      text,
  canal         text not null default 'email' check (canal in ('email', 'whatsapp')),
  key_signer    text,
  assinado      boolean not null default false,
  assinado_em   timestamptz,
  atualizado_em timestamptz not null default now()
);
create index if not exists envelope_assinantes_env_idx on public.envelope_assinantes (envelope_id);
alter table public.envelope_assinantes enable row level security;
drop policy if exists envelope_assinantes_equipe on public.envelope_assinantes;
create policy envelope_assinantes_equipe on public.envelope_assinantes for select using (public.eh_equipe());
revoke all on public.envelope_assinantes from anon, authenticated;
grant select on public.envelope_assinantes to authenticated;

-- A assinatura passa a ser por envelope
drop table if exists public.contrato_assinantes;

-- Ajuste de versão bloqueado enquanto o documento estiver num envelope ativo
create or replace function public.em_envelope_ativo(p_contrato uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.envelopes e, jsonb_array_elements(e.documentos) d
                  where e.status in ('preparado', 'enviado') and d ->> 'tipo' = 'contrato' and d ->> 'id' = p_contrato::text);
$$;

create or replace function public.enviar_versao_contrato(p_id uuid, p_caminho_docx text, p_caminho_pdf text)
returns public.contratos language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_caminho_docx is null and p_caminho_pdf is null then raise exception 'ARQUIVO_OBRIGATORIO'; end if;
  select * into v from public.contratos where id = p_id for update;
  if v.id is null or v.cancelado_em is not null then raise exception 'CONTRATO_NAO_ENCONTRADO'; end if;
  if public.em_envelope_ativo(p_id) or v.assinatura = 'assinado' then raise exception 'JA_ENVIADO_PARA_ASSINATURA'; end if;
  if (p_caminho_docx is not null and p_caminho_docx !~ ('^' || v.pasta_id::text || '/'))
     or (p_caminho_pdf is not null and p_caminho_pdf !~ ('^' || v.pasta_id::text || '/')) then
    raise exception 'CAMINHO_INVALIDO';
  end if;
  update public.contratos
     set versao = versao + 1, caminho_docx = p_caminho_docx, caminho = p_caminho_pdf,
         validacao = 'aguardando', validado_em = null, validado_por = null
   where id = p_id returning * into v;
  insert into public.contrato_versoes (contrato_id, versao, caminho_pdf, caminho_docx, origem, criado_por)
  values (v.id, v.versao, p_caminho_pdf, p_caminho_docx, 'ajuste', public.meu_email());
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato ajustado', jsonb_build_object('numero', v.numero, 'versao', v.versao), public.meu_email());
  return v;
end;
$$;

create or replace function public.cancelar_contrato(p_id uuid) returns public.contratos
language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if public.em_envelope_ativo(p_id) then raise exception 'EM_ENVELOPE'; end if;
  update public.contratos set cancelado_em = now(), cancelado_por = public.meu_email()
   where id = p_id and cancelado_em is null and assinatura <> 'assinado' returning * into v;
  if v.id is null then raise exception 'NAO_PODE_CANCELAR'; end if;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato cancelado', jsonb_build_object('numero', v.numero), public.meu_email());
  return v;
end;
$$;

revoke all on function public.salvar_anexo_fixo(text, text, text, int), public.alterar_anexo_fixo(uuid, text, int, boolean), public.em_envelope_ativo(uuid) from public, anon;
grant execute on function public.salvar_anexo_fixo(text, text, text, int), public.alterar_anexo_fixo(uuid, text, int, boolean), public.em_envelope_ativo(uuid) to authenticated;

commit;
