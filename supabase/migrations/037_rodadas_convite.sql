-- =====================================================================
-- 037 — Convite da rodada de negócios
--  * O administrador anexa o convite (imagem ou PDF) à rodada.
--  * Quem pode baixar: a equipe, e o corretor ou a imobiliária que tem pelo
--    menos um cliente confirmado (não cancelado) naquela rodada.
--  * Arquivo em bucket privado ("rodadas"), baixado por link temporário.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.rodadas
  add column if not exists convite_caminho text,
  add column if not exists convite_nome    text,
  add column if not exists convite_tipo    text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rodadas', 'rodadas', false, 20971520, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false;

-- Pode baixar o convite desta rodada?
create or replace function public.pode_baixar_convite(p_rodada uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe() or exists (
    select 1 from public.rodada_inscricoes i
     where i.rodada_id = p_rodada and not i.cancelada
       and i.imobiliaria_id = public.minha_imobiliaria()
       and (public.eh_gestor() or i.corretor_id = auth.uid()));
$$;

-- Arquivo "<id da rodada>/<nome>" no bucket
create or replace function public.convite_liberado(p_nome text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_id text := split_part(p_nome, '/', 1);
begin
  if v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  return public.pode_baixar_convite(v_id::uuid);
end;
$$;
revoke all on function public.pode_baixar_convite(uuid), public.convite_liberado(text) from public, anon;
grant execute on function public.pode_baixar_convite(uuid), public.convite_liberado(text) to authenticated;

drop policy if exists rodadas_convite_leitura on storage.objects;
drop policy if exists rodadas_convite_envio on storage.objects;
drop policy if exists rodadas_convite_remocao on storage.objects;
create policy rodadas_convite_leitura on storage.objects for select to authenticated
  using (bucket_id = 'rodadas' and public.convite_liberado(name));
create policy rodadas_convite_envio on storage.objects for insert to authenticated
  with check (bucket_id = 'rodadas' and public.eh_admin());
create policy rodadas_convite_remocao on storage.objects for delete to authenticated
  using (bucket_id = 'rodadas' and public.eh_admin());

-- Grava (ou tira) o convite da rodada; devolve o arquivo anterior para a tela apagar
create or replace function public.definir_convite_rodada(p_rodada uuid, p_caminho text, p_nome text default null, p_tipo text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_antigo text;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select convite_caminho into v_antigo from public.rodadas where id = p_rodada for update;
  if not found then raise exception 'RODADA_NAO_ENCONTRADA'; end if;
  if p_caminho is not null and split_part(p_caminho, '/', 1) <> p_rodada::text then raise exception 'CAMINHO_INVALIDO'; end if;
  update public.rodadas
     set convite_caminho = p_caminho,
         convite_nome = case when p_caminho is null then null else left(coalesce(p_nome, 'convite'), 200) end,
         convite_tipo = case when p_caminho is null then null else p_tipo end
   where id = p_rodada;
  return case when v_antigo is distinct from p_caminho then v_antigo end;
end;
$$;
revoke all on function public.definir_convite_rodada(uuid, text, text, text) from public, anon;
grant execute on function public.definir_convite_rodada(uuid, text, text, text) to authenticated;
