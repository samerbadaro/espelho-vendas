-- =====================================================================
-- 048 — Vídeos do manual
--  * Um vídeo (link do YouTube, Vimeo, Loom ou Google Drive) por capítulo
--    do manual. O texto do manual fica no código (src/manual/conteudo.ts).
--  * Todos os logados leem; só o administrador cadastra ou remove.
-- Executar uma única vez no SQL Editor do Supabase (depois da 047).
-- =====================================================================
begin;

create table if not exists public.manual_videos (
  capitulo       text primary key check (capitulo ~ '^[a-z0-9-]{2,60}$'),
  url            text not null check (url ~ '^https://'),
  titulo         text,
  atualizado_em  timestamptz not null default now(),
  atualizado_por text
);
alter table public.manual_videos enable row level security;
drop policy if exists manual_videos_leitura on public.manual_videos;
create policy manual_videos_leitura on public.manual_videos for select using (auth.uid() is not null);
revoke all on public.manual_videos from anon, authenticated;
grant select on public.manual_videos to authenticated;

create or replace function public.salvar_video_manual(p_capitulo text, p_url text, p_titulo text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if nullif(trim(p_url), '') is null then
    delete from public.manual_videos where capitulo = p_capitulo;
    return;
  end if;
  if trim(p_url) !~ '^https://' then raise exception 'LINK_INVALIDO'; end if;
  insert into public.manual_videos (capitulo, url, titulo, atualizado_por)
  values (p_capitulo, left(trim(p_url), 500), left(nullif(trim(p_titulo), ''), 150), public.meu_email())
  on conflict (capitulo) do update set url = excluded.url, titulo = excluded.titulo, atualizado_em = now(), atualizado_por = excluded.atualizado_por;
end;
$$;
revoke all on function public.salvar_video_manual(text, text, text) from public, anon;
grant execute on function public.salvar_video_manual(text, text, text) to authenticated;

commit;
