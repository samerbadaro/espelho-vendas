-- =====================================================================
-- 043 — Modelos de contrato em Word (com marcadores)
--  * O administrador envia o Word do jurídico com marcadores ({comprador.nome}…)
--    para cada documento (Quadro Resumo, Normas Contratuais).
--  * Só um modelo ativo por documento; os anteriores ficam no histórico.
--  * Sem modelo enviado, o sistema usa o modelo padrão.
-- Executar uma única vez no SQL Editor do Supabase (depois da 042).
-- =====================================================================
begin;

create table if not exists public.modelos_contrato (
  id          uuid primary key default gen_random_uuid(),
  documento   text not null check (documento in ('quadro_resumo', 'normas')),
  nome        text not null,
  caminho     text not null check (caminho ~ '^modelos/'),
  ativo       boolean not null default true,
  enviado_em  timestamptz not null default now(),
  enviado_por text
);
create unique index if not exists modelos_contrato_um_ativo on public.modelos_contrato (documento) where ativo;
alter table public.modelos_contrato enable row level security;
drop policy if exists modelos_contrato_equipe on public.modelos_contrato;
create policy modelos_contrato_equipe on public.modelos_contrato for select using (public.eh_equipe());
revoke all on public.modelos_contrato from anon, authenticated;
grant select on public.modelos_contrato to authenticated;

-- Ativa um modelo novo (o anterior do mesmo documento sai de uso)
create or replace function public.salvar_modelo_contrato(p_documento text, p_nome text, p_caminho text)
returns public.modelos_contrato language plpgsql security definer set search_path = public as $$
declare v public.modelos_contrato;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.modelos_contrato set ativo = false where documento = p_documento and ativo;
  insert into public.modelos_contrato (documento, nome, caminho, enviado_por)
  values (p_documento, left(p_nome, 200), p_caminho, public.meu_email()) returning * into v;
  return v;
end;
$$;

-- Volta para o modelo padrão do sistema
create or replace function public.usar_modelo_padrao(p_documento text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.modelos_contrato set ativo = false where documento = p_documento and ativo;
end;
$$;

revoke all on function public.salvar_modelo_contrato(text, text, text), public.usar_modelo_padrao(text) from public, anon;
grant execute on function public.salvar_modelo_contrato(text, text, text), public.usar_modelo_padrao(text) to authenticated;

commit;
