-- =====================================================================
-- 021 — Portal do Corretor
--  * Materiais de venda organizados em categorias (book, plantas, vídeos…).
--  * Cada item é um arquivo enviado ou um link (tour virtual, vídeo no YouTube…).
--  * Sec. Vendas e administrador adicionam e removem; corretores e
--    imobiliárias só visualizam e baixam.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create table public.portal_itens (
  id            uuid primary key default gen_random_uuid(),
  categoria     text not null check (categoria in (
                  'book', 'ficha_tecnica', 'fotos_decorado', 'imagens', 'materiais_apoio',
                  'redes_sociais', 'plantas', 'simulador', 'tour_virtual', 'videos')),
  titulo        text not null check (length(trim(titulo)) >= 2),
  descricao     text,
  link          text check (link is null or link ~* '^https?://'),
  caminho       text,              -- arquivo no bucket "portal"
  nome_arquivo  text,
  tamanho       bigint,
  tipo_mime     text,
  criado_por    text,
  criado_em     timestamptz not null default now(),
  check ((link is not null) <> (caminho is not null))
);
create index portal_itens_categoria_idx on public.portal_itens (categoria);

alter table public.portal_itens enable row level security;

-- Quem enxerga o portal: equipe e quem tem login de imobiliária ou corretor
create or replace function public.acesso_portal() returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe() or public.minha_imobiliaria() is not null;
$$;

create policy portal_leitura on public.portal_itens for select using (public.acesso_portal());
grant select on public.portal_itens to authenticated;

-- Arquivos: bucket privado; downloads por link temporário
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('portal', 'portal', false, 524288000, null)
on conflict (id) do update set public = false;

create policy portal_arquivos_leitura on storage.objects for select to authenticated
  using (bucket_id = 'portal' and public.acesso_portal());
create policy portal_arquivos_envio on storage.objects for insert to authenticated
  with check (bucket_id = 'portal' and public.eh_equipe());
create policy portal_arquivos_remocao on storage.objects for delete to authenticated
  using (bucket_id = 'portal' and public.eh_equipe());

-- Adicionar item (arquivo já enviado ao bucket, ou link)
create or replace function public.adicionar_item_portal(
  p_categoria text, p_titulo text, p_descricao text default null, p_link text default null,
  p_caminho text default null, p_nome_arquivo text default null, p_tamanho bigint default null, p_tipo text default null
) returns public.portal_itens
language plpgsql security definer set search_path = public as $$
declare v public.portal_itens;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_titulo)), 0) < 2 then raise exception 'TITULO_OBRIGATORIO'; end if;
  if (nullif(trim(p_link), '') is null) = (p_caminho is null) then raise exception 'ARQUIVO_OU_LINK'; end if;
  if nullif(trim(p_link), '') is not null and trim(p_link) !~* '^https?://' then raise exception 'LINK_INVALIDO'; end if;
  insert into public.portal_itens (categoria, titulo, descricao, link, caminho, nome_arquivo, tamanho, tipo_mime, criado_por)
  values (p_categoria, trim(p_titulo), nullif(trim(p_descricao), ''), nullif(trim(p_link), ''), p_caminho,
          p_nome_arquivo, p_tamanho, p_tipo, public.meu_email())
  returning * into v;
  return v;
exception when check_violation then
  raise exception 'CATEGORIA_INVALIDA';
end;
$$;

create or replace function public.editar_item_portal(p_id uuid, p_titulo text, p_descricao text default null) returns public.portal_itens
language plpgsql security definer set search_path = public as $$
declare v public.portal_itens;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_titulo)), 0) < 2 then raise exception 'TITULO_OBRIGATORIO'; end if;
  update public.portal_itens set titulo = trim(p_titulo), descricao = nullif(trim(p_descricao), '')
   where id = p_id returning * into v;
  if not found then raise exception 'ITEM_NAO_ENCONTRADO'; end if;
  return v;
end;
$$;

-- Remove o item; devolve o caminho do arquivo para a tela apagar do bucket
create or replace function public.remover_item_portal(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_caminho text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  delete from public.portal_itens where id = p_id returning caminho into v_caminho;
  if not found then raise exception 'ITEM_NAO_ENCONTRADO'; end if;
  return v_caminho;
end;
$$;

revoke all on function public.adicionar_item_portal(text, text, text, text, text, text, bigint, text) from public, anon;
revoke all on function public.editar_item_portal(uuid, text, text) from public, anon;
revoke all on function public.remover_item_portal(uuid) from public, anon;
grant execute on function public.adicionar_item_portal(text, text, text, text, text, text, bigint, text) to authenticated;
grant execute on function public.editar_item_portal(uuid, text, text) to authenticated;
grant execute on function public.remover_item_portal(uuid) to authenticated;
