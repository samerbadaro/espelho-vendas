-- =====================================================================
-- 008 — Marca configurável, módulo de pastas opcional e registro de
--        quem visualizou cada documento.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Identidade visual e módulos do empreendimento (editável pelo admin)
-- ---------------------------------------------------------------------
alter table public.config
  add column cor_primaria     text not null default '#23251C' check (cor_primaria ~ '^#[0-9A-Fa-f]{6}$'),
  add column cor_destaque     text not null default '#94874A' check (cor_destaque ~ '^#[0-9A-Fa-f]{6}$'),
  add column logo_url         text,
  add column logo_escuro_url  text,
  add column imagem_login_url text,
  add column cidade           text,
  add column modulo_pastas    boolean not null default true;

grant update (nome_empreendimento, cor_primaria, cor_destaque, logo_url, logo_escuro_url,
              imagem_login_url, cidade, modulo_pastas, atualizado_em) on public.config to authenticated;
create policy config_edicao on public.config for update using (public.eh_admin()) with check (public.eh_admin());

-- Arquivos da marca (logo e imagem do login) são públicos por natureza
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('marca', 'marca', true, 5242880, array['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml'])
on conflict (id) do nothing;
create policy marca_envio on storage.objects for insert to authenticated
  with check (bucket_id = 'marca' and public.eh_admin());

-- ---------------------------------------------------------------------
-- Visualização de documentos: passa obrigatoriamente pelo servidor,
-- que registra quem abriu e gera um link de 1 minuto.
-- Os usuários deixam de poder baixar arquivos diretamente.
-- ---------------------------------------------------------------------
drop policy if exists documentos_visualizacao on storage.objects;

create function public.registrar_visualizacao(p_documento uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_doc public.documentos; v_tipo text;
begin
  select * into v_doc from public.documentos where id = p_documento;
  if not found or not public.pode_ver_pasta(v_doc.pasta_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  select nome into v_tipo from public.tipos_documento where id = v_doc.tipo_id;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v_doc.pasta_id, 'Documento visualizado', jsonb_build_object('documento', v_tipo, 'arquivo', v_doc.nome_arquivo), public.meu_email());
  return v_doc.caminho;
end;
$$;
revoke all on function public.registrar_visualizacao(uuid) from public, anon;
grant execute on function public.registrar_visualizacao(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Indicadores da tela inicial (somente equipe)
-- ---------------------------------------------------------------------
create function public.indicadores() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  return jsonb_build_object(
    'unidades', (select jsonb_object_agg(status, n) from (select status::text, count(*) n from public.unidades group by status) s),
    'pastas',   (select jsonb_object_agg(status, n) from (select status, count(*) n from public.pastas group by status) s),
    'pastas_total', (select count(*) from public.pastas),
    'pastas_submetidas', (select count(*) from public.pastas where codigo_aprovacao is not null),
    'vendas_7_dias', (select count(*) from public.historico where status_novo = 'vendida' and criado_em > now() - interval '7 days'),
    'reservas_7_dias', (select count(*) from public.historico where status_novo = 'reservada' and criado_em > now() - interval '7 days')
  );
end;
$$;
revoke all on function public.indicadores() from public, anon;
grant execute on function public.indicadores() to authenticated;
