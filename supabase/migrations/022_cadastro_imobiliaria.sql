-- =====================================================================
-- 022 — Cadastro de imobiliárias pelo link público
--  * O dono da imobiliária preenche o cadastro em /cadastro e cria a
--    própria senha. O login nasce sem acesso a nada.
--  * O administrador aprova (cria a imobiliária e libera o login master)
--    ou recusa, com motivo.
--  * A criação do login é feita pelo servidor (Cloudflare), com a chave
--    secreta; a senha escolhida nunca é guardada pelo sistema.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create table public.solicitacoes_imobiliaria (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null unique references auth.users (id) on delete cascade,
  imobiliaria_nome  text not null check (length(trim(imobiliaria_nome)) >= 2),
  cnpj              text,
  creci             text,
  cidade            text,
  responsavel       text not null check (length(trim(responsavel)) >= 3),
  email             text not null,
  telefone          text not null,
  status            text not null default 'pendente' check (status in ('pendente', 'aprovada', 'recusada')),
  motivo            text,
  imobiliaria_id    uuid references public.imobiliarias (id),
  ip                text,
  criada_em         timestamptz not null default now(),
  analisada_em      timestamptz,
  analisada_por     text
);
create index solicitacoes_imobiliaria_status_idx on public.solicitacoes_imobiliaria (status, criada_em);

alter table public.solicitacoes_imobiliaria enable row level security;
-- o administrador vê todas; quem se cadastrou vê só a própria (para saber se foi aprovada)
create policy solicitacoes_leitura on public.solicitacoes_imobiliaria for select
  using (public.eh_admin() or user_id = auth.uid());
grant select on public.solicitacoes_imobiliaria to authenticated;
-- escrita: o servidor (chave secreta) e as funções abaixo

-- ---------------------------------------------------------------------
-- Aprovar: cria a imobiliária (ou usa uma existente) e libera o login master
-- ---------------------------------------------------------------------
create or replace function public.aprovar_solicitacao(
  p_id uuid, p_nome_imobiliaria text default null, p_imobiliaria_existente uuid default null
) returns public.solicitacoes_imobiliaria
language plpgsql security definer set search_path = public as $$
declare v public.solicitacoes_imobiliaria; v_imob uuid; v_nome text;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into v from public.solicitacoes_imobiliaria where id = p_id for update;
  if not found then raise exception 'SOLICITACAO_NAO_ENCONTRADA'; end if;
  if v.status <> 'pendente' then raise exception 'SOLICITACAO_JA_ANALISADA'; end if;
  if exists (select 1 from public.perfis where user_id = v.user_id) then raise exception 'JA_TEM_ACESSO'; end if;

  if p_imobiliaria_existente is not null then
    select id into v_imob from public.imobiliarias where id = p_imobiliaria_existente;
    if not found then raise exception 'IMOBILIARIA_NAO_ENCONTRADA'; end if;
    update public.imobiliarias set ativa = true where id = v_imob;
  else
    v_nome := regexp_replace(trim(coalesce(nullif(trim(p_nome_imobiliaria), ''), v.imobiliaria_nome)), '\s+', ' ', 'g');
    if exists (select 1 from public.imobiliarias where lower(nome) = lower(v_nome)) then raise exception 'NOME_EM_USO'; end if;
    insert into public.imobiliarias (nome) values (v_nome) returning id into v_imob;
  end if;

  insert into public.perfis (user_id, email, nome, papel, imobiliaria_id, trocar_senha)
  values (v.user_id, v.email, v.responsavel, 'imobiliaria', v_imob, false);

  update public.solicitacoes_imobiliaria
     set status = 'aprovada', imobiliaria_id = v_imob, analisada_em = now(), analisada_por = public.meu_email(), motivo = null
   where id = p_id returning * into v;
  return v;
end;
$$;

create or replace function public.recusar_solicitacao(p_id uuid, p_motivo text) returns public.solicitacoes_imobiliaria
language plpgsql security definer set search_path = public as $$
declare v public.solicitacoes_imobiliaria;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_motivo)), 0) < 3 then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  update public.solicitacoes_imobiliaria
     set status = 'recusada', motivo = trim(p_motivo), analisada_em = now(), analisada_por = public.meu_email()
   where id = p_id and status = 'pendente' returning * into v;
  if not found then raise exception 'SOLICITACAO_JA_ANALISADA'; end if;
  return v;
end;
$$;

revoke all on function public.aprovar_solicitacao(uuid, text, uuid) from public, anon;
revoke all on function public.recusar_solicitacao(uuid, text) from public, anon;
grant execute on function public.aprovar_solicitacao(uuid, text, uuid) to authenticated;
grant execute on function public.recusar_solicitacao(uuid, text) to authenticated;
