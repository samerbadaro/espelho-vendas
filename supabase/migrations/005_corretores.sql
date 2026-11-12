-- =====================================================================
-- 005 — Corretores
--  * Imobiliária (gestor) vê TODAS as pastas da imobiliária e cria os
--    logins dos seus corretores.
--  * Corretor vê SOMENTE as pastas que ele mesmo criou.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- Novo papel
alter table public.perfis drop constraint if exists perfis_papel_check;
alter table public.perfis add constraint perfis_papel_check check (papel in ('admin', 'vendas', 'imobiliaria', 'corretor'));
alter table public.perfis drop constraint if exists perfis_imobiliaria_check;
alter table public.perfis add constraint perfis_imobiliaria_check
  check ((papel in ('imobiliaria', 'corretor')) = (imobiliaria_id is not null));

-- Quem criou a pasta (id do login), para o filtro do corretor
alter table public.pastas add column if not exists criado_por_id uuid;
update public.pastas p set criado_por_id = pf.user_id
  from public.perfis pf where p.criado_por_id is null and pf.email = p.criado_por;
create index if not exists pastas_criador_idx on public.pastas (criado_por_id);

-- ---------------------------------------------------------------------
-- Funções de permissão
-- ---------------------------------------------------------------------
create or replace function public.minha_imobiliaria() returns uuid
language sql stable security definer set search_path = public as $$
  select p.imobiliaria_id
    from public.perfis p join public.imobiliarias i on i.id = p.imobiliaria_id
   where p.user_id = auth.uid() and p.papel in ('imobiliaria', 'corretor') and i.ativa;
$$;

-- gestor = login da imobiliária (vê tudo da imobiliária)
create function public.eh_gestor() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid() and papel = 'imobiliaria');
$$;

-- Regra única de acesso a uma pasta
create function public.acesso_pasta(p_imob uuid, p_criador uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe()
      or (p_imob = public.minha_imobiliaria() and (public.eh_gestor() or p_criador = auth.uid()));
$$;

create or replace function public.pode_ver_pasta(p_pasta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pastas p where p.id = p_pasta and public.acesso_pasta(p.imobiliaria_id, p.criado_por_id));
$$;

create or replace function public.pode_acessar_arquivo(p_caminho text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_imob uuid; v_pasta uuid;
begin
  v_imob  := split_part(p_caminho, '/', 1)::uuid;
  v_pasta := split_part(p_caminho, '/', 2)::uuid;
  return exists (
    select 1 from public.pastas p
     where p.id = v_pasta and p.imobiliaria_id = v_imob
       and public.acesso_pasta(p.imobiliaria_id, p.criado_por_id));
exception when others then
  return false;
end;
$$;

-- ---------------------------------------------------------------------
-- Políticas
-- ---------------------------------------------------------------------
drop policy pastas_leitura on public.pastas;
drop policy pastas_edicao on public.pastas;
create policy pastas_leitura on public.pastas for select
  using (public.acesso_pasta(imobiliaria_id, criado_por_id));
create policy pastas_edicao on public.pastas for update
  using (public.acesso_pasta(imobiliaria_id, criado_por_id))
  with check (public.acesso_pasta(imobiliaria_id, criado_por_id));
-- inclusão continua: só na própria imobiliária (ou equipe)

-- Perfis: cada um vê o próprio; admin vê todos; imobiliária vê os seus corretores
drop policy perfis_leitura on public.perfis;
create policy perfis_leitura on public.perfis for select
  using (user_id = auth.uid() or public.eh_admin()
         or (public.eh_gestor() and imobiliaria_id = public.minha_imobiliaria()));

-- ---------------------------------------------------------------------
-- Registro do criador da pasta
-- ---------------------------------------------------------------------
create or replace function public.pastas_antes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := public.meu_email();
    new.criado_por_id := auth.uid();
  end if;
  new.atualizada_em := now();
  if new.estado_civil not in ('casado', 'uniao_estavel') then
    new.conjuge_nome := null; new.conjuge_cpf := null; new.conjuge_nascimento := null;
    new.conjuge_telefone := null; new.conjuge_email := null;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Envio de documento passa a usar a mesma regra de acesso
-- ---------------------------------------------------------------------
create or replace function public.registrar_documento(
  p_pasta uuid, p_tipo int, p_caminho text, p_nome text, p_tamanho bigint, p_mime text
) returns public.documentos
language plpgsql security definer set search_path = public as $$
declare
  v_pasta public.pastas;
  v_tipo  public.tipos_documento;
  v_atual public.documentos;
  v_doc   public.documentos;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if p_caminho not like v_pasta.imobiliaria_id::text || '/' || v_pasta.id::text || '/%' then
    raise exception 'CAMINHO_INVALIDO';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'documentos' and name = p_caminho) then
    raise exception 'ARQUIVO_NAO_ENCONTRADO';
  end if;
  select * into v_tipo from public.tipos_documento where id = p_tipo and ativo;
  if not found then raise exception 'TIPO_INVALIDO'; end if;

  if not v_tipo.multiplo then
    select * into v_atual from public.documentos where pasta_id = p_pasta and tipo_id = p_tipo and atual for update;
    if v_atual.id is not null then
      if not public.eh_equipe() and v_atual.status in ('em_analise', 'aprovado') then
        raise exception 'DOCUMENTO_BLOQUEADO';
      end if;
      update public.documentos set atual = false where id = v_atual.id;
    end if;
  end if;

  insert into public.documentos (pasta_id, tipo_id, caminho, nome_arquivo, tamanho, mime, enviado_por)
  values (p_pasta, p_tipo, p_caminho, left(p_nome, 200), p_tamanho, left(p_mime, 100), public.meu_email())
  returning * into v_doc;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, case when v_atual.id is null then 'Documento enviado' else 'Documento substituído' end,
          jsonb_build_object('documento', v_tipo.nome, 'arquivo', left(p_nome, 200)), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  return v_doc;
end;
$$;
