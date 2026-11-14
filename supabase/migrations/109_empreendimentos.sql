-- =====================================================================
-- 109 — Vários empreendimentos na mesma incorporadora (Fase 1, etapa A)
--  * Tabela de empreendimentos (nome, endereço, sigla, ordem, ativo).
--  * O primeiro empreendimento nasce da configuração atual (Duo Haus).
--  * Campo "empreendimento" nas tabelas de dados de cada lançamento,
--    preenchido automaticamente com o empreendimento padrão. Nada muda
--    nas telas nesta etapa: tudo continua funcionando como antes.
--  * Restrição de acesso: o administrador pode bloquear um empreendimento
--    para uma imobiliária (padrão: ela vê todos).
--  Decisões (14/11/2026): um banco por incorporadora; imobiliárias veem
--  todos os empreendimentos com restrição opcional; pastas numeradas por
--  empreendimento com sigla (DH-PA-001).
-- =====================================================================

create table if not exists public.empreendimentos (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  sigla      text not null unique check (sigla ~ '^[A-Z0-9]{2,4}$'),
  nome       text not null check (length(trim(nome)) >= 2),
  ativo      boolean not null default true,
  ordem      int not null default 0,
  criado_em  timestamptz not null default now()
);

insert into public.empreendimentos (slug, sigla, nome)
select 'duohaus', 'DH', coalesce(nullif(trim(c.nome_empreendimento), ''), 'Empreendimento')
  from public.config c where c.id = 1
   and not exists (select 1 from public.empreendimentos);

-- empreendimento usado quando nenhum é informado (o primeiro, por ordem)
create or replace function public.empreendimento_padrao() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.empreendimentos order by ordem, criado_em limit 1;
$$;
grant execute on function public.empreendimento_padrao() to anon, authenticated;

-- campo "empreendimento" nas tabelas de dados de lançamento
do $$
declare t text;
begin
  foreach t in array array['unidades', 'negociacoes', 'historico', 'pastas', 'rodadas', 'recepcao_eventos',
                           'portal_itens', 'portal_downloads', 'simulacoes_log', 'propostas'] loop
    if to_regclass('public.' || t) is not null then
      execute format('alter table public.%I add column if not exists empreendimento_id uuid references public.empreendimentos (id)', t);
      execute format('update public.%I set empreendimento_id = public.empreendimento_padrao() where empreendimento_id is null', t);
      execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_padrao()', t);
      execute format('alter table public.%I alter column empreendimento_id set not null', t);
      execute format('create index if not exists %I on public.%I (empreendimento_id)', t || '_empreendimento_idx', t);
    end if;
  end loop;
end $$;

-- negociação e histórico seguem o empreendimento da unidade
create or replace function public.herdar_empreendimento_da_unidade() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.unidade_id is not null then
    select empreendimento_id into new.empreendimento_id from public.unidades where id = new.unidade_id;
  end if;
  return new;
end;
$$;
drop trigger if exists negociacoes_empreendimento on public.negociacoes;
create trigger negociacoes_empreendimento before insert on public.negociacoes
  for each row execute function public.herdar_empreendimento_da_unidade();
drop trigger if exists historico_empreendimento on public.historico;
create trigger historico_empreendimento before insert on public.historico
  for each row execute function public.herdar_empreendimento_da_unidade();
drop trigger if exists propostas_empreendimento on public.propostas;
create trigger propostas_empreendimento before insert on public.propostas
  for each row execute function public.herdar_empreendimento_da_unidade();

-- restrição opcional: imobiliária sem acesso a um empreendimento
create table if not exists public.imobiliarias_bloqueios (
  imobiliaria_id    uuid not null references public.imobiliarias (id) on delete cascade,
  empreendimento_id uuid not null references public.empreendimentos (id) on delete cascade,
  criado_em         timestamptz not null default now(),
  criado_por        text,
  primary key (imobiliaria_id, empreendimento_id)
);

-- quem enxerga cada empreendimento: equipe vê todos; imobiliária/corretor, os não bloqueados
create or replace function public.acesso_empreendimento(p_empreendimento uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe()
      or (auth.uid() is not null and not exists (
            select 1 from public.imobiliarias_bloqueios b
             where b.empreendimento_id = p_empreendimento and b.imobiliaria_id = public.minha_imobiliaria()));
$$;
grant execute on function public.acesso_empreendimento(uuid) to authenticated;

alter table public.empreendimentos enable row level security;
alter table public.imobiliarias_bloqueios enable row level security;
revoke all on public.empreendimentos, public.imobiliarias_bloqueios from anon, authenticated;
grant select on public.empreendimentos to anon, authenticated;
grant select on public.imobiliarias_bloqueios to authenticated;
create policy empreendimentos_leitura on public.empreendimentos for select using (true);
create policy bloqueios_leitura on public.imobiliarias_bloqueios for select
  using (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria());

-- administrador cadastra empreendimentos e define bloqueios
create or replace function public.salvar_empreendimento(p_id uuid, p_nome text, p_slug text, p_sigla text,
  p_ativo boolean default true, p_ordem int default 0) returns public.empreendimentos
language plpgsql security definer set search_path = public as $$
declare v public.empreendimentos;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_id is null then
    insert into public.empreendimentos (nome, slug, sigla, ativo, ordem)
    values (trim(p_nome), lower(trim(p_slug)), upper(trim(p_sigla)), p_ativo, p_ordem) returning * into v;
  else
    update public.empreendimentos set nome = trim(p_nome), slug = lower(trim(p_slug)), sigla = upper(trim(p_sigla)),
           ativo = p_ativo, ordem = p_ordem where id = p_id returning * into v;
    if not found then raise exception 'EMPREENDIMENTO_NAO_ENCONTRADO'; end if;
  end if;
  return v;
exception when unique_violation then raise exception 'ENDERECO_OU_SIGLA_EM_USO';
end;
$$;

create or replace function public.bloquear_empreendimento(p_imobiliaria uuid, p_empreendimento uuid, p_bloquear boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_bloquear then
    insert into public.imobiliarias_bloqueios (imobiliaria_id, empreendimento_id, criado_por)
    values (p_imobiliaria, p_empreendimento, public.meu_email()) on conflict do nothing;
  else
    delete from public.imobiliarias_bloqueios where imobiliaria_id = p_imobiliaria and empreendimento_id = p_empreendimento;
  end if;
end;
$$;

revoke all on function public.salvar_empreendimento(uuid, text, text, text, boolean, int),
  public.bloquear_empreendimento(uuid, uuid, boolean) from public, anon;
grant execute on function public.salvar_empreendimento(uuid, text, text, text, boolean, int),
  public.bloquear_empreendimento(uuid, uuid, boolean) to authenticated;
