-- =====================================================================
-- ESPELHO DE VENDAS — estrutura do banco (Supabase / PostgreSQL)
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- Status comerciais possíveis de uma unidade
create type public.status_unidade as enum ('disponivel', 'reservada', 'vendida', 'bloqueada');

-- ---------------------------------------------------------------------
-- Configuração geral (linha única)
-- ---------------------------------------------------------------------
create table public.config (
  id                  int primary key default 1 check (id = 1),
  nome_empreendimento text not null default 'Espelho de Vendas',
  publico_ativo       boolean not null default true,   -- link público ligado/desligado
  atualizado_em       timestamptz not null default now()
);
insert into public.config default values;

-- ---------------------------------------------------------------------
-- Equipe com acesso ao painel (Sec. Vendas e administradores)
-- O login é feito pelo Supabase Auth; só quem tem linha aqui altera algo.
-- ---------------------------------------------------------------------
create table public.perfis (
  user_id   uuid primary key references auth.users (id) on delete cascade,
  email     text not null,
  nome      text,
  papel     text not null check (papel in ('admin', 'vendas')),
  criado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Unidades (sem nenhum dado pessoal de comprador)
-- ---------------------------------------------------------------------
create table public.unidades (
  id             uuid primary key default gen_random_uuid(),
  numero         text not null unique,          -- ex.: 1205
  andar          int  not null,
  posicao        int  not null,                 -- coluna no espelho (final da unidade)
  area_privativa numeric(8, 2),
  tipologia      text,
  status         public.status_unidade not null default 'disponivel',
  versao         int  not null default 1,       -- controle de edição simultânea
  atualizado_em  timestamptz not null default now(),
  unique (andar, posicao)
);

-- ---------------------------------------------------------------------
-- Histórico de toda mudança de status (auditoria)
-- ---------------------------------------------------------------------
create table public.historico (
  id              bigint generated always as identity primary key,
  unidade_id      uuid not null references public.unidades (id),
  numero          text not null,
  status_anterior public.status_unidade,
  status_novo     public.status_unidade not null,
  motivo          text,
  usuario_id      uuid,
  usuario_email   text,
  criado_em       timestamptz not null default now()
);
create index historico_unidade_idx on public.historico (unidade_id, criado_em desc);
create index historico_data_idx    on public.historico (criado_em desc);

-- ---------------------------------------------------------------------
-- Funções auxiliares de permissão
-- ---------------------------------------------------------------------
create function public.eh_equipe() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid());
$$;

create function public.eh_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid() and papel = 'admin');
$$;

-- ---------------------------------------------------------------------
-- Row Level Security: leitura controlada, escrita SOMENTE pelas funções
-- ---------------------------------------------------------------------
alter table public.config    enable row level security;
alter table public.perfis    enable row level security;
alter table public.unidades  enable row level security;
alter table public.historico enable row level security;

revoke all on public.config, public.perfis, public.unidades, public.historico from anon, authenticated;
grant select on public.config, public.unidades to anon, authenticated;
grant select on public.perfis, public.historico to authenticated;

-- Configuração: todos leem (nome do empreendimento e se o link público está ativo)
create policy config_leitura on public.config for select using (true);

-- Unidades: público lê só se o link público estiver ativo; equipe sempre lê
create policy unidades_leitura on public.unidades for select
  using ((select publico_ativo from public.config where id = 1) or public.eh_equipe());

-- Histórico: só a equipe
create policy historico_leitura on public.historico for select using (public.eh_equipe());

-- Perfis: cada um vê o próprio; admin vê todos
create policy perfis_leitura on public.perfis for select
  using (user_id = auth.uid() or public.eh_admin());

-- ---------------------------------------------------------------------
-- Alterar status de uma unidade (única forma de escrita)
--  * exige usuário da equipe
--  * trava a linha (FOR UPDATE) e confere a versão: se outra pessoa
--    alterou antes, retorna erro CONFLITO em vez de sobrescrever
--  * desfazer reserva/venda exige motivo
--  * grava histórico
-- ---------------------------------------------------------------------
create function public.alterar_status(
  p_unidade_id uuid,
  p_status     public.status_unidade,
  p_versao     int,
  p_motivo     text default null
) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  v_unidade public.unidades;
  v_email    text;
  v_anterior public.status_unidade;
  v_motivo  text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.eh_equipe() then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;

  select * into v_unidade from public.unidades where id = p_unidade_id for update;
  if not found then
    raise exception 'UNIDADE_NAO_ENCONTRADA';
  end if;

  if v_unidade.versao <> p_versao then
    raise exception 'CONFLITO' using hint = 'A unidade foi alterada por outra pessoa. Recarregue.';
  end if;

  if v_unidade.status = p_status then
    return v_unidade;
  end if;

  if v_unidade.status in ('reservada', 'vendida') and p_status in ('disponivel', 'bloqueada')
     and v_motivo is null then
    raise exception 'MOTIVO_OBRIGATORIO';
  end if;

  select email into v_email from public.perfis where user_id = auth.uid();
  v_anterior := v_unidade.status;

  update public.unidades
     set status = p_status, versao = versao + 1, atualizado_em = now()
   where id = p_unidade_id
  returning * into v_unidade;

  insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email)
  values (v_unidade.id, v_unidade.numero, v_anterior, p_status, v_motivo, auth.uid(), v_email);

  return v_unidade;
end;
$$;

-- ---------------------------------------------------------------------
-- Ligar/desligar o link público (somente admin)
-- ---------------------------------------------------------------------
create function public.definir_publico(p_ativo boolean) returns public.config
language plpgsql security definer set search_path = public as $$
declare v_config public.config;
begin
  if not public.eh_admin() then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  update public.config set publico_ativo = p_ativo, atualizado_em = now() where id = 1
  returning * into v_config;
  return v_config;
end;
$$;

revoke all on function public.alterar_status(uuid, public.status_unidade, int, text) from public, anon;
revoke all on function public.definir_publico(boolean) from public, anon;
grant execute on function public.alterar_status(uuid, public.status_unidade, int, text) to authenticated;
grant execute on function public.definir_publico(boolean) to authenticated;

-- ---------------------------------------------------------------------
-- Tempo real: avisa as telas quando unidades ou configuração mudam
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.unidades, public.config;
  end if;
end $$;
