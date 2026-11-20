-- =====================================================================
-- 044 — Assinatura eletrônica (D4Sign)
--  * contratos: identificador na D4Sign, datas de envio/assinatura e PDF assinado.
--  * Novas situações: 'preparado' (na D4Sign, aguardando conferência da prévia)
--    e 'cancelado' (cancelado na D4Sign).
--  * contrato_assinantes: quem assina, em que ordem, por e-mail ou WhatsApp, e se já assinou.
--  * Quem grava é o servidor (com a chave secreta), depois de conferir o login da equipe.
-- Executar uma única vez no SQL Editor do Supabase (depois da 043).
-- =====================================================================
begin;

alter table public.contratos add column if not exists d4sign_uuid text unique;
alter table public.contratos add column if not exists enviado_assinatura_em timestamptz;
alter table public.contratos add column if not exists assinado_em timestamptz;
alter table public.contratos add column if not exists caminho_assinado text;
alter table public.contratos drop constraint if exists contratos_assinatura_check;
alter table public.contratos add constraint contratos_assinatura_check
  check (assinatura in ('nao_enviado', 'preparado', 'enviado', 'assinado', 'recusado', 'cancelado'));

create table if not exists public.contrato_assinantes (
  id           bigint generated always as identity primary key,
  contrato_id  uuid not null references public.contratos(id) on delete cascade,
  ordem        int not null default 1,
  papel        text not null,
  nome         text,
  email        text not null,
  whatsapp     text,
  canal        text not null default 'email' check (canal in ('email', 'whatsapp')),
  key_signer   text,
  assinado     boolean not null default false,
  assinado_em  timestamptz,
  atualizado_em timestamptz not null default now()
);
create index if not exists contrato_assinantes_contrato_idx on public.contrato_assinantes (contrato_id);
alter table public.contrato_assinantes enable row level security;
drop policy if exists contrato_assinantes_equipe on public.contrato_assinantes;
create policy contrato_assinantes_equipe on public.contrato_assinantes for select using (public.eh_equipe());
revoke all on public.contrato_assinantes from anon, authenticated;
grant select on public.contrato_assinantes to authenticated;

-- Cancelar pelo sistema só antes de ir para a D4Sign (depois, cancela pela integração)
create or replace function public.cancelar_contrato(p_id uuid) returns public.contratos
language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contratos set cancelado_em = now(), cancelado_por = public.meu_email()
   where id = p_id and cancelado_em is null and assinatura = 'nao_enviado' returning * into v;
  if v.id is null then raise exception 'NAO_PODE_CANCELAR'; end if;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato cancelado', jsonb_build_object('numero', v.numero), public.meu_email());
  return v;
end;
$$;

commit;
