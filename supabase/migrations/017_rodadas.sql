-- =====================================================================
-- 017 — Rodadas de negócios
--  * O administrador cria rodadas (nome, data, local, limite de clientes)
--    para todas as imobiliárias ou só para as escolhidas.
--  * Corretores e imobiliárias liberados confirmam clientes: nome, quantas
--    pessoas vêm e telefone. O limite conta clientes, não pessoas.
--  * Cada um vê só a sua parte: o corretor vê os clientes dele, a imobiliária
--    vê os da equipe dela, a Sec. Vendas e o administrador veem tudo.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create table public.rodadas (
  id                  uuid primary key default gen_random_uuid(),
  nome                text not null check (length(trim(nome)) >= 3),
  data_hora           timestamptz not null,
  local               text,
  observacoes         text,
  limite_clientes     int not null default 25 check (limite_clientes > 0),
  inscricoes_abertas  boolean not null default true,
  todas_imobiliarias  boolean not null default true,
  criado_por          text,
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now()
);

create table public.rodadas_imobiliarias (
  rodada_id      uuid not null references public.rodadas(id) on delete cascade,
  imobiliaria_id uuid not null references public.imobiliarias(id) on delete cascade,
  primary key (rodada_id, imobiliaria_id)
);

create table public.rodada_inscricoes (
  id              uuid primary key default gen_random_uuid(),
  rodada_id       uuid not null references public.rodadas(id) on delete cascade,
  cliente_nome    text not null check (length(trim(cliente_nome)) >= 3),
  pessoas         int not null check (pessoas between 1 and 20),
  telefone        text,
  observacao      text,
  imobiliaria_id  uuid references public.imobiliarias(id),
  corretor_id     uuid,
  corretor_nome   text,
  cancelada       boolean not null default false,
  cancelada_em    timestamptz,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);
create index rodada_inscricoes_rodada_idx on public.rodada_inscricoes (rodada_id) where not cancelada;
-- o mesmo cliente não é confirmado duas vezes na mesma rodada
create unique index rodada_inscricoes_cliente_unico
  on public.rodada_inscricoes (rodada_id, lower(regexp_replace(trim(cliente_nome), '\s+', ' ', 'g')))
  where not cancelada;

alter table public.rodadas enable row level security;
alter table public.rodadas_imobiliarias enable row level security;
alter table public.rodada_inscricoes enable row level security;

-- A rodada está liberada para quem está logado?
create or replace function public.rodada_liberada(p_rodada uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe() or exists (
    select 1 from public.rodadas r
     where r.id = p_rodada
       and public.minha_imobiliaria() is not null
       and (r.todas_imobiliarias
            or exists (select 1 from public.rodadas_imobiliarias ri
                        where ri.rodada_id = r.id and ri.imobiliaria_id = public.minha_imobiliaria())));
$$;

create policy rodadas_leitura on public.rodadas for select using (public.rodada_liberada(id));
create policy rodadas_imobs_leitura on public.rodadas_imobiliarias for select using (public.eh_equipe());
create policy inscricoes_leitura on public.rodada_inscricoes for select using (
  public.eh_equipe()
  or (imobiliaria_id = public.minha_imobiliaria() and (public.eh_gestor() or corretor_id = auth.uid()))
);
-- escrita só pelas funções abaixo

-- ---------------------------------------------------------------------
-- Administrador: criar ou editar rodada
-- ---------------------------------------------------------------------
create or replace function public.salvar_rodada(
  p_id uuid, p_nome text, p_data_hora timestamptz, p_local text, p_observacoes text,
  p_limite int, p_abertas boolean, p_todas boolean, p_imobiliarias uuid[]
) returns public.rodadas
language plpgsql security definer set search_path = public as $$
declare v public.rodadas; v_ocupadas int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if p_data_hora is null then raise exception 'DATA_OBRIGATORIA'; end if;
  if p_limite is null or p_limite < 1 then raise exception 'LIMITE_INVALIDO'; end if;
  if not p_todas and coalesce(array_length(p_imobiliarias, 1), 0) = 0 then raise exception 'IMOBILIARIAS_OBRIGATORIAS'; end if;

  if p_id is null then
    insert into public.rodadas (nome, data_hora, local, observacoes, limite_clientes, inscricoes_abertas, todas_imobiliarias, criado_por)
    values (trim(p_nome), p_data_hora, nullif(trim(p_local), ''), nullif(trim(p_observacoes), ''), p_limite, p_abertas, p_todas, public.meu_email())
    returning * into v;
  else
    select count(*) into v_ocupadas from public.rodada_inscricoes where rodada_id = p_id and not cancelada;
    if p_limite < v_ocupadas then raise exception 'LIMITE_ABAIXO_DOS_CONFIRMADOS' using hint = v_ocupadas::text; end if;
    update public.rodadas
       set nome = trim(p_nome), data_hora = p_data_hora, local = nullif(trim(p_local), ''),
           observacoes = nullif(trim(p_observacoes), ''), limite_clientes = p_limite,
           inscricoes_abertas = p_abertas, todas_imobiliarias = p_todas, atualizado_em = now()
     where id = p_id returning * into v;
    if not found then raise exception 'RODADA_NAO_ENCONTRADA'; end if;
  end if;

  delete from public.rodadas_imobiliarias where rodada_id = v.id;
  if not p_todas then
    insert into public.rodadas_imobiliarias (rodada_id, imobiliaria_id)
    select v.id, unnest(p_imobiliarias) on conflict do nothing;
  end if;
  return v;
end;
$$;

create or replace function public.excluir_rodada(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  delete from public.rodadas where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Vagas de cada rodada visível (o corretor não lê as inscrições dos outros)
-- ---------------------------------------------------------------------
create or replace function public.rodadas_vagas() returns table (rodada_id uuid, clientes int, pessoas int)
language sql stable security definer set search_path = public as $$
  select r.id, count(i.id)::int, coalesce(sum(i.pessoas), 0)::int
    from public.rodadas r
    left join public.rodada_inscricoes i on i.rodada_id = r.id and not i.cancelada
   where public.rodada_liberada(r.id)
   group by r.id;
$$;

-- ---------------------------------------------------------------------
-- Confirmar cliente (corretor, imobiliária ou equipe)
-- ---------------------------------------------------------------------
create or replace function public.confirmar_cliente_rodada(
  p_rodada uuid, p_cliente text, p_pessoas int, p_telefone text default null, p_observacao text default null,
  p_imobiliaria uuid default null
) returns public.rodada_inscricoes
language plpgsql security definer set search_path = public as $$
declare
  v_rodada public.rodadas;
  v_imob   uuid;
  v_nome   text;
  v_ocup   int;
  v        public.rodada_inscricoes;
begin
  select * into v_rodada from public.rodadas where id = p_rodada for update;   -- trava a rodada: o limite não estoura
  if not found or not public.rodada_liberada(p_rodada) then raise exception 'RODADA_NAO_ENCONTRADA'; end if;
  if not public.eh_equipe() and not v_rodada.inscricoes_abertas then raise exception 'INSCRICOES_ENCERRADAS'; end if;
  if not public.eh_equipe() and v_rodada.data_hora < now() then raise exception 'RODADA_JA_ACONTECEU'; end if;
  if coalesce(length(trim(p_cliente)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if p_pessoas is null or p_pessoas < 1 or p_pessoas > 20 then raise exception 'PESSOAS_INVALIDO'; end if;

  select count(*) into v_ocup from public.rodada_inscricoes where rodada_id = p_rodada and not cancelada;
  if v_ocup >= v_rodada.limite_clientes then raise exception 'RODADA_LOTADA'; end if;

  v_imob := case when public.eh_equipe() then p_imobiliaria else public.minha_imobiliaria() end;
  select coalesce(nullif(nome, ''), email) into v_nome from public.perfis where user_id = auth.uid();

  begin
    insert into public.rodada_inscricoes (rodada_id, cliente_nome, pessoas, telefone, observacao, imobiliaria_id, corretor_id, corretor_nome)
    values (p_rodada, regexp_replace(trim(p_cliente), '\s+', ' ', 'g'), p_pessoas, nullif(trim(p_telefone), ''),
            nullif(trim(p_observacao), ''), v_imob, auth.uid(), v_nome)
    returning * into v;
  exception when unique_violation then
    raise exception 'CLIENTE_JA_CONFIRMADO';
  end;
  return v;
end;
$$;

-- Quem pode mexer numa confirmação: equipe, a imobiliária dona ou o corretor que confirmou
create or replace function public.pode_alterar_inscricao(p public.rodada_inscricoes) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe()
      or (p.imobiliaria_id = public.minha_imobiliaria() and (public.eh_gestor() or p.corretor_id = auth.uid()));
$$;

create or replace function public.editar_cliente_rodada(
  p_id uuid, p_cliente text, p_pessoas int, p_telefone text default null, p_observacao text default null
) returns public.rodada_inscricoes
language plpgsql security definer set search_path = public as $$
declare v public.rodada_inscricoes; v_rodada public.rodadas;
begin
  select * into v from public.rodada_inscricoes where id = p_id for update;
  if not found or v.cancelada or not public.pode_alterar_inscricao(v) then raise exception 'INSCRICAO_NAO_ENCONTRADA'; end if;
  select * into v_rodada from public.rodadas where id = v.rodada_id;
  if not public.eh_equipe() and (not v_rodada.inscricoes_abertas or v_rodada.data_hora < now()) then
    raise exception 'INSCRICOES_ENCERRADAS';
  end if;
  if coalesce(length(trim(p_cliente)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if p_pessoas is null or p_pessoas < 1 or p_pessoas > 20 then raise exception 'PESSOAS_INVALIDO'; end if;
  begin
    update public.rodada_inscricoes
       set cliente_nome = regexp_replace(trim(p_cliente), '\s+', ' ', 'g'), pessoas = p_pessoas,
           telefone = nullif(trim(p_telefone), ''), observacao = nullif(trim(p_observacao), ''), atualizado_em = now()
     where id = p_id returning * into v;
  exception when unique_violation then
    raise exception 'CLIENTE_JA_CONFIRMADO';
  end;
  return v;
end;
$$;

create or replace function public.cancelar_cliente_rodada(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v public.rodada_inscricoes;
begin
  select * into v from public.rodada_inscricoes where id = p_id for update;
  if not found or v.cancelada or not public.pode_alterar_inscricao(v) then raise exception 'INSCRICAO_NAO_ENCONTRADA'; end if;
  update public.rodada_inscricoes set cancelada = true, cancelada_em = now(), atualizado_em = now() where id = p_id;
end;
$$;

revoke all on function public.salvar_rodada(uuid, text, timestamptz, text, text, int, boolean, boolean, uuid[]) from public, anon;
revoke all on function public.excluir_rodada(uuid) from public, anon;
revoke all on function public.rodadas_vagas() from public, anon;
revoke all on function public.confirmar_cliente_rodada(uuid, text, int, text, text, uuid) from public, anon;
revoke all on function public.editar_cliente_rodada(uuid, text, int, text, text) from public, anon;
revoke all on function public.cancelar_cliente_rodada(uuid) from public, anon;
grant execute on function public.salvar_rodada(uuid, text, timestamptz, text, text, int, boolean, boolean, uuid[]) to authenticated;
grant execute on function public.excluir_rodada(uuid) to authenticated;
grant execute on function public.rodadas_vagas() to authenticated;
grant execute on function public.confirmar_cliente_rodada(uuid, text, int, text, text, uuid) to authenticated;
grant execute on function public.editar_cliente_rodada(uuid, text, int, text, text) to authenticated;
grant execute on function public.cancelar_cliente_rodada(uuid) to authenticated;
grant select on public.rodadas, public.rodadas_imobiliarias, public.rodada_inscricoes to authenticated;

-- Lista de confirmados atualiza sozinha na tela
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.rodada_inscricoes;
  end if;
end $$;
