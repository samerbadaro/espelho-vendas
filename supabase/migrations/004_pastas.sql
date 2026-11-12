-- =====================================================================
-- 004 — Imobiliárias, pastas de compradores e documentos
-- Executar uma única vez no SQL Editor do Supabase.
--
-- Regra central: uma imobiliária NUNCA vê pastas, documentos ou arquivos
-- de outra. Isso é garantido aqui no banco (RLS), não só nas telas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Imobiliárias
-- ---------------------------------------------------------------------
create table public.imobiliarias (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null unique check (length(trim(nome)) > 1),
  ativa     boolean not null default true,
  criada_em timestamptz not null default now()
);

-- Perfis passam a aceitar o papel "imobiliaria" (um login por imobiliária)
alter table public.perfis drop constraint if exists perfis_papel_check;
alter table public.perfis add constraint perfis_papel_check check (papel in ('admin', 'vendas', 'imobiliaria'));
alter table public.perfis add column imobiliaria_id uuid references public.imobiliarias (id);
alter table public.perfis add column trocar_senha boolean not null default false;
alter table public.perfis add constraint perfis_imobiliaria_check
  check ((papel = 'imobiliaria') = (imobiliaria_id is not null));

-- ---------------------------------------------------------------------
-- Funções de permissão
--  eh_equipe(): admin ou Sec. Vendas (NÃO inclui imobiliárias)
--  minha_imobiliaria(): id da imobiliária do usuário logado (se ativa)
-- ---------------------------------------------------------------------
create or replace function public.eh_equipe() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid() and papel in ('admin', 'vendas'));
$$;

create function public.minha_imobiliaria() returns uuid
language sql stable security definer set search_path = public as $$
  select p.imobiliaria_id
    from public.perfis p join public.imobiliarias i on i.id = p.imobiliaria_id
   where p.user_id = auth.uid() and p.papel = 'imobiliaria' and i.ativa;
$$;

create function public.meu_email() returns text
language sql stable security definer set search_path = public as $$
  select email from public.perfis where user_id = auth.uid();
$$;

-- Imobiliárias logadas também veem o espelho, mesmo com o link público fora do ar
drop policy unidades_leitura on public.unidades;
create policy unidades_leitura on public.unidades for select
  using ((select publico_ativo from public.config where id = 1) or public.eh_equipe()
         or public.minha_imobiliaria() is not null);

alter table public.imobiliarias enable row level security;
revoke all on public.imobiliarias from anon, authenticated;
grant select on public.imobiliarias to authenticated;
grant insert (nome, ativa), update (nome, ativa) on public.imobiliarias to authenticated;
create policy imobiliarias_leitura on public.imobiliarias for select
  using (public.eh_equipe() or id = public.minha_imobiliaria());
create policy imobiliarias_inclusao on public.imobiliarias for insert with check (public.eh_admin());
create policy imobiliarias_edicao on public.imobiliarias for update using (public.eh_admin()) with check (public.eh_admin());

-- Admin vê todos os perfis; cada usuário vê o próprio (política já existe)

-- ---------------------------------------------------------------------
-- Pastas de compradores
-- ---------------------------------------------------------------------
create type public.estado_civil as enum ('solteiro', 'casado', 'uniao_estavel', 'divorciado', 'viuvo');
create type public.status_pasta as enum ('incompleta', 'aguardando_analise', 'em_analise', 'pendente_correcao', 'aprovada');

create sequence public.pastas_codigo_seq;

create table public.pastas (
  id                   uuid primary key default gen_random_uuid(),
  codigo               text not null unique default 'P-' || lpad(nextval('public.pastas_codigo_seq')::text, 4, '0'),
  imobiliaria_id       uuid not null default public.minha_imobiliaria() references public.imobiliarias (id),
  unidade_id           uuid references public.unidades (id),
  comprador_nome       text not null check (length(trim(comprador_nome)) > 1),
  comprador_cpf        text not null check (comprador_cpf ~ '^[0-9]{11}$'),
  comprador_nascimento date,
  comprador_telefone   text,
  comprador_email      text,
  estado_civil         public.estado_civil not null default 'solteiro',
  conjuge_nome         text,
  conjuge_cpf          text check (conjuge_cpf is null or conjuge_cpf ~ '^[0-9]{11}$'),
  conjuge_nascimento   date,
  conjuge_telefone     text,
  conjuge_email        text,
  dados_bancarios      text,          -- banco/agência/conta ou chave PIX
  observacoes          text,
  status               public.status_pasta not null default 'incompleta',
  criado_por           text,
  criada_em            timestamptz not null default now(),
  atualizada_em        timestamptz not null default now()
);
create index pastas_imobiliaria_idx on public.pastas (imobiliaria_id);
create index pastas_cpf_idx on public.pastas (comprador_cpf);
create index pastas_unidade_idx on public.pastas (unidade_id);

-- ---------------------------------------------------------------------
-- Tipos de documento (configuráveis sem mexer no código)
--  obrigatorio_para: estados civis em que o documento é obrigatório
--  exibir_para: estados civis em que o campo aparece (vazio = sempre)
--  multiplo: aceita vários arquivos (ex.: "Outros documentos")
-- ---------------------------------------------------------------------
create table public.tipos_documento (
  id               serial primary key,
  nome             text not null,
  pessoa           text not null check (pessoa in ('comprador', 'conjuge', 'geral')),
  obrigatorio_para public.estado_civil[] not null default '{}',
  exibir_para      public.estado_civil[] not null default '{}',
  multiplo         boolean not null default false,
  ordem            int not null default 0,
  ativo            boolean not null default true
);

insert into public.tipos_documento (nome, pessoa, obrigatorio_para, exibir_para, multiplo, ordem) values
  ('RG ou CNH', 'comprador', '{solteiro,casado,uniao_estavel,divorciado,viuvo}', '{}', false, 10),
  ('CPF (se não constar no RG/CNH)', 'comprador', '{}', '{}', false, 20),
  ('Comprovante de endereço', 'comprador', '{solteiro,casado,uniao_estavel,divorciado,viuvo}', '{}', false, 30),
  ('Certidão de nascimento', 'comprador', '{solteiro}', '{solteiro}', false, 40),
  ('Certidão de casamento', 'comprador', '{casado}', '{casado}', false, 41),
  ('Escritura ou declaração de união estável', 'comprador', '{uniao_estavel}', '{uniao_estavel}', false, 42),
  ('Certidão de casamento com averbação do divórcio', 'comprador', '{divorciado}', '{divorciado}', false, 43),
  ('Certidão de casamento e certidão de óbito do cônjuge', 'comprador', '{viuvo}', '{viuvo}', false, 44),
  ('RG ou CNH do cônjuge', 'conjuge', '{casado,uniao_estavel}', '{casado,uniao_estavel}', false, 50),
  ('CPF do cônjuge (se não constar no RG/CNH)', 'conjuge', '{}', '{casado,uniao_estavel}', false, 60),
  ('Comprovante de endereço do cônjuge (se diferente)', 'conjuge', '{}', '{casado,uniao_estavel}', false, 70),
  ('Procuração', 'geral', '{}', '{}', false, 80),
  ('Outros documentos', 'geral', '{}', '{}', true, 90);

-- ---------------------------------------------------------------------
-- Documentos enviados (cada arquivo é uma linha; substituições ficam
-- guardadas com atual = false, para auditoria)
-- ---------------------------------------------------------------------
create type public.status_documento as enum ('enviado', 'em_analise', 'aprovado', 'recusado');

create table public.documentos (
  id            uuid primary key default gen_random_uuid(),
  pasta_id      uuid not null references public.pastas (id),
  tipo_id       int  not null references public.tipos_documento (id),
  caminho       text not null unique,       -- caminho no armazenamento privado
  nome_arquivo  text not null,
  tamanho       bigint,
  mime          text,
  status        public.status_documento not null default 'enviado',
  motivo_recusa text,
  atual         boolean not null default true,
  enviado_por   text,
  enviado_em    timestamptz not null default now(),
  analisado_por text,
  analisado_em  timestamptz
);
create index documentos_pasta_idx on public.documentos (pasta_id, tipo_id);

-- ---------------------------------------------------------------------
-- Histórico das pastas (auditoria; não grava CPF nem dados pessoais)
-- ---------------------------------------------------------------------
create table public.historico_pastas (
  id            bigint generated always as identity primary key,
  pasta_id      uuid not null references public.pastas (id),
  acao          text not null,
  detalhes      jsonb,
  usuario_email text,
  criado_em     timestamptz not null default now()
);
create index historico_pastas_idx on public.historico_pastas (pasta_id, criado_em desc);

-- ---------------------------------------------------------------------
-- Acesso a uma pasta: equipe vê todas; imobiliária só as suas
-- ---------------------------------------------------------------------
create function public.pode_ver_pasta(p_pasta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.pastas p
     where p.id = p_pasta
       and (public.eh_equipe() or p.imobiliaria_id = public.minha_imobiliaria()));
$$;

alter table public.pastas           enable row level security;
alter table public.tipos_documento  enable row level security;
alter table public.documentos       enable row level security;
alter table public.historico_pastas enable row level security;

revoke all on public.pastas, public.tipos_documento, public.documentos, public.historico_pastas from anon, authenticated;
revoke all on sequence public.pastas_codigo_seq from anon;
grant usage on sequence public.pastas_codigo_seq to authenticated;

grant select on public.pastas, public.tipos_documento, public.documentos, public.historico_pastas to authenticated;
-- campos que podem ser preenchidos; status, unidade e código só mudam pelas funções
grant insert (imobiliaria_id, comprador_nome, comprador_cpf, comprador_nascimento, comprador_telefone, comprador_email,
              estado_civil, conjuge_nome, conjuge_cpf, conjuge_nascimento, conjuge_telefone, conjuge_email,
              dados_bancarios, observacoes) on public.pastas to authenticated;
grant update (comprador_nome, comprador_cpf, comprador_nascimento, comprador_telefone, comprador_email,
              estado_civil, conjuge_nome, conjuge_cpf, conjuge_nascimento, conjuge_telefone, conjuge_email,
              dados_bancarios, observacoes) on public.pastas to authenticated;

create policy pastas_leitura on public.pastas for select
  using (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria());
create policy pastas_inclusao on public.pastas for insert
  with check (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria());
create policy pastas_edicao on public.pastas for update
  using (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria())
  with check (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria());

create policy tipos_leitura on public.tipos_documento for select
  using (public.eh_equipe() or public.minha_imobiliaria() is not null);
create policy documentos_leitura on public.documentos for select using (public.pode_ver_pasta(pasta_id));
create policy historico_pastas_leitura on public.historico_pastas for select using (public.pode_ver_pasta(pasta_id));

-- ---------------------------------------------------------------------
-- Status geral da pasta, calculado automaticamente
--  pendente_correcao: algum documento atual recusado
--  incompleta: falta documento obrigatório (ou o do cônjuge, se casado/união)
--  aprovada: todos os obrigatórios aprovados e nada aguardando
--  em_analise: algum documento em análise
--  aguardando_analise: tudo enviado, ninguém analisou ainda
-- ---------------------------------------------------------------------
create function public.recalcular_pasta(p_pasta uuid) returns public.status_pasta
language plpgsql security definer set search_path = public as $$
declare
  v_ec       public.estado_civil;
  v_status   public.status_pasta;
  v_faltando int;
  v_recusado int;
  v_analise  int;
  v_enviado  int;
begin
  select estado_civil into v_ec from public.pastas where id = p_pasta;

  select count(*) into v_recusado from public.documentos where pasta_id = p_pasta and atual and status = 'recusado';
  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo and v_ec = any (t.obrigatorio_para)
     and not exists (select 1 from public.documentos d where d.pasta_id = p_pasta and d.tipo_id = t.id and d.atual);
  select count(*) into v_analise from public.documentos where pasta_id = p_pasta and atual and status = 'em_analise';
  select count(*) into v_enviado from public.documentos where pasta_id = p_pasta and atual and status = 'enviado';

  v_status := case
    when v_recusado > 0 then 'pendente_correcao'
    when v_faltando > 0 then 'incompleta'
    when v_analise > 0 then 'em_analise'
    when v_enviado > 0 then 'aguardando_analise'
    else 'aprovada' end;

  update public.pastas set status = v_status where id = p_pasta and status is distinct from v_status;
  return v_status;
end;
$$;

-- Ao criar/editar a pasta: registra quem, quais campos mudaram e recalcula o status
create function public.pastas_antes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := public.meu_email();
  end if;
  new.atualizada_em := now();
  -- limpa dados do cônjuge quando o estado civil não tem cônjuge
  if new.estado_civil not in ('casado', 'uniao_estavel') then
    new.conjuge_nome := null; new.conjuge_cpf := null; new.conjuge_nascimento := null;
    new.conjuge_telefone := null; new.conjuge_email := null;
  end if;
  return new;
end;
$$;

create function public.pastas_depois() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_campos text[];
begin
  if tg_op = 'INSERT' then
    insert into public.historico_pastas (pasta_id, acao, usuario_email) values (new.id, 'Pasta criada', public.meu_email());
    perform public.recalcular_pasta(new.id);
  else
    select array_agg(n.key order by n.key) into v_campos
      from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value
       and n.key not in ('status', 'atualizada_em', 'unidade_id');
    if v_campos is not null then
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (new.id, 'Dados alterados', jsonb_build_object('campos', v_campos), public.meu_email());
    end if;
    if new.estado_civil is distinct from old.estado_civil then
      perform public.recalcular_pasta(new.id);
    end if;
  end if;
  return null;
end;
$$;

create trigger pastas_antes before insert or update on public.pastas
  for each row execute function public.pastas_antes();
create trigger pastas_depois after insert or update on public.pastas
  for each row execute function public.pastas_depois();

-- ---------------------------------------------------------------------
-- Armazenamento privado dos arquivos
-- Caminho: <imobiliaria_id>/<pasta_id>/<arquivo>
-- Sem link público: cada visualização gera um link temporário, após
-- conferir quem está pedindo.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos', 'documentos', false, 15728640,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
on conflict (id) do update set public = false;

create function public.pode_acessar_arquivo(p_caminho text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_imob uuid; v_pasta uuid;
begin
  v_imob  := split_part(p_caminho, '/', 1)::uuid;
  v_pasta := split_part(p_caminho, '/', 2)::uuid;
  return exists (
    select 1 from public.pastas p
     where p.id = v_pasta and p.imobiliaria_id = v_imob
       and (public.eh_equipe() or p.imobiliaria_id = public.minha_imobiliaria()));
exception when others then
  return false;
end;
$$;

create policy documentos_envio on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and public.pode_acessar_arquivo(name));
create policy documentos_visualizacao on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and public.pode_acessar_arquivo(name));
-- sem políticas de update/delete: arquivos enviados não podem ser apagados nem trocados

-- ---------------------------------------------------------------------
-- Registrar um arquivo enviado
--  * confere acesso à pasta e se o arquivo está mesmo no lugar certo
--  * imobiliária só substitui documento recusado ou ainda não analisado
--  * a versão anterior fica guardada (atual = false)
-- ---------------------------------------------------------------------
create function public.registrar_documento(
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
  if not found or not (public.eh_equipe() or v_pasta.imobiliaria_id = public.minha_imobiliaria()) then
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

-- ---------------------------------------------------------------------
-- Analisar documento (somente equipe): em análise, aprovado ou recusado
-- ---------------------------------------------------------------------
create function public.analisar_documento(
  p_documento uuid, p_status public.status_documento, p_motivo text default null
) returns public.documentos
language plpgsql security definer set search_path = public as $$
declare
  v_doc    public.documentos;
  v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
  v_nome   text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_status = 'enviado' then raise exception 'STATUS_INVALIDO'; end if;
  if p_status = 'recusado' and v_motivo is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;

  update public.documentos
     set status = p_status,
         motivo_recusa = case when p_status = 'recusado' then v_motivo else null end,
         analisado_por = public.meu_email(), analisado_em = now()
   where id = p_documento and atual
  returning * into v_doc;
  if not found then raise exception 'DOCUMENTO_NAO_ENCONTRADO'; end if;

  select nome into v_nome from public.tipos_documento where id = v_doc.tipo_id;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v_doc.pasta_id,
          case p_status when 'aprovado' then 'Documento aprovado' when 'recusado' then 'Documento recusado' else 'Documento em análise' end,
          jsonb_strip_nulls(jsonb_build_object('documento', v_nome, 'motivo', v_motivo)), public.meu_email());

  perform public.recalcular_pasta(v_doc.pasta_id);
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- Vincular pasta a uma unidade (somente equipe)
-- ---------------------------------------------------------------------
create function public.vincular_unidade(p_pasta uuid, p_unidade uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas; v_numero text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.pastas set unidade_id = p_unidade where id = p_pasta returning * into v_pasta;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  select numero into v_numero from public.unidades where id = p_unidade;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, case when p_unidade is null then 'Unidade desvinculada' else 'Unidade vinculada' end,
          jsonb_strip_nulls(jsonb_build_object('unidade', v_numero)), public.meu_email());
  return v_pasta;
end;
$$;

-- Usuário marca que já trocou a senha provisória
create function public.senha_trocada() returns void
language sql security definer set search_path = public as $$
  update public.perfis set trocar_senha = false where user_id = auth.uid();
$$;

revoke all on function public.recalcular_pasta(uuid) from public, anon, authenticated;
revoke all on function public.registrar_documento(uuid, int, text, text, bigint, text) from public, anon;
revoke all on function public.analisar_documento(uuid, public.status_documento, text) from public, anon;
revoke all on function public.vincular_unidade(uuid, uuid) from public, anon;
revoke all on function public.senha_trocada() from public, anon;
grant execute on function public.registrar_documento(uuid, int, text, text, bigint, text) to authenticated;
grant execute on function public.analisar_documento(uuid, public.status_documento, text) to authenticated;
grant execute on function public.vincular_unidade(uuid, uuid) to authenticated;
grant execute on function public.senha_trocada() to authenticated;
