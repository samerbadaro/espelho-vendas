-- =====================================================================
-- 030 — Treinamentos com agenda de horários
--  * Um treinamento tem vários horários (início de 30 em 30 minutos), cada
--    um com limite de pessoas (25). Lotou, não aceita mais inscrição.
--  * Cada corretor (ou login de imobiliária) se inscreve em UM horário do
--    treinamento. Para trocar, cancela a inscrição e se inscreve em outro.
--  * Visível para todas as imobiliárias. A equipe vê todos os inscritos,
--    inclui alguém na hora e confirma a presença; a imobiliária vê os seus.
--  * Já cria o treinamento de 18 e 19/11/2026: 09:00 a 11:30 e 14:00 a 19:00.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.config add column if not exists modulo_treinamentos boolean not null default true;
grant update (modulo_treinamentos) on public.config to authenticated;

create table if not exists public.treinamentos (
  id                  uuid primary key default gen_random_uuid(),
  nome                text not null,
  local               text,
  inscricoes_abertas  boolean not null default true,
  criado_em           timestamptz not null default now()
);

create table if not exists public.treinamento_horarios (
  id              uuid primary key default gen_random_uuid(),
  treinamento_id  uuid not null references public.treinamentos(id) on delete cascade,
  inicio          timestamptz not null,
  limite          int not null default 25 check (limite > 0),
  unique (treinamento_id, inicio)
);

create table if not exists public.treinamento_inscricoes (
  id              uuid primary key default gen_random_uuid(),
  treinamento_id  uuid not null references public.treinamentos(id) on delete cascade,
  horario_id      uuid not null references public.treinamento_horarios(id) on delete cascade,
  user_id         uuid,                       -- login de quem participa (nulo para quem a equipe incluiu na hora)
  nome            text not null,
  email           text,
  papel           text,
  imobiliaria_id  uuid references public.imobiliarias(id) on delete set null,
  imobiliaria     text,
  presente        boolean not null default false,
  presenca_em     timestamptz,
  presenca_por    text,
  incluido_por    text,
  criado_em       timestamptz not null default now()
);
-- um horário por pessoa em cada treinamento
create unique index if not exists treinamento_inscricoes_um_por_pessoa
  on public.treinamento_inscricoes (treinamento_id, user_id) where user_id is not null;
create index if not exists treinamento_inscricoes_horario on public.treinamento_inscricoes (horario_id);

alter table public.treinamentos enable row level security;
alter table public.treinamento_horarios enable row level security;
alter table public.treinamento_inscricoes enable row level security;
grant select on public.treinamentos, public.treinamento_horarios, public.treinamento_inscricoes to authenticated;
create policy treinamentos_leitura on public.treinamentos for select using (auth.uid() is not null);
create policy treinamento_horarios_leitura on public.treinamento_horarios for select using (auth.uid() is not null);
create policy treinamento_inscricoes_leitura on public.treinamento_inscricoes for select using (
  public.eh_equipe()
  or user_id = auth.uid()
  or (public.eh_gestor() and imobiliaria_id = public.minha_imobiliaria())
);

-- vagas de cada horário (todos veem a contagem, não os nomes)
create or replace function public.treinamento_vagas(p_treinamento uuid)
returns table (horario_id uuid, inscritos int, presentes int)
language sql stable security definer set search_path = public as $$
  select h.id, count(i.id)::int, count(i.id) filter (where i.presente)::int
    from public.treinamento_horarios h
    left join public.treinamento_inscricoes i on i.horario_id = h.id
   where h.treinamento_id = p_treinamento and auth.uid() is not null
   group by h.id;
$$;

-- inscrever: o próprio corretor/imobiliária; a equipe pode incluir um login (p_user) ou um nome avulso
create or replace function public.inscrever_treinamento(p_horario uuid, p_user uuid default null,
  p_nome text default null, p_imobiliaria text default null)
returns public.treinamento_inscricoes
language plpgsql security definer set search_path = public as $$
declare
  h public.treinamento_horarios; t public.treinamentos; v public.treinamento_inscricoes;
  alvo uuid; pf public.perfis; imob_nome text; ocupadas int; equipe boolean := public.eh_equipe();
begin
  select * into h from public.treinamento_horarios where id = p_horario for update;
  if not found then raise exception 'HORARIO_NAO_ENCONTRADO'; end if;
  select * into t from public.treinamentos where id = h.treinamento_id;
  if not equipe then
    if not t.inscricoes_abertas then raise exception 'INSCRICOES_ENCERRADAS'; end if;
    if h.inicio <= now() then raise exception 'HORARIO_JA_COMECOU'; end if;
  end if;

  alvo := case when equipe then p_user else auth.uid() end;
  if not equipe and (p_user is not null and p_user <> auth.uid()) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;

  if alvo is not null then
    select * into pf from public.perfis where user_id = alvo;
    if not found or pf.papel not in ('corretor', 'imobiliaria') then raise exception 'SO_CORRETOR'; end if;
    if exists (select 1 from public.treinamento_inscricoes where treinamento_id = h.treinamento_id and user_id = alvo) then
      raise exception 'JA_INSCRITO';
    end if;
    select nome into imob_nome from public.imobiliarias where id = pf.imobiliaria_id;
  elsif not equipe or coalesce(length(trim(p_nome)), 0) < 3 then
    raise exception 'NOME_OBRIGATORIO';
  end if;

  select count(*) into ocupadas from public.treinamento_inscricoes where horario_id = p_horario;
  if ocupadas >= h.limite then raise exception 'HORARIO_LOTADO'; end if;

  insert into public.treinamento_inscricoes (treinamento_id, horario_id, user_id, nome, email, papel, imobiliaria_id, imobiliaria, incluido_por)
  values (h.treinamento_id, p_horario, alvo,
          coalesce(nullif(trim(pf.nome), ''), trim(p_nome), pf.email), pf.email, pf.papel,
          pf.imobiliaria_id, coalesce(imob_nome, nullif(trim(p_imobiliaria), '')),
          case when equipe then public.meu_email() end)
  returning * into v;
  return v;
exception when unique_violation then
  raise exception 'JA_INSCRITO';
end;
$$;

-- cancelar: a própria pessoa (antes do horário) ou a equipe
create or replace function public.cancelar_inscricao_treinamento(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v public.treinamento_inscricoes; h public.treinamento_horarios;
begin
  select * into v from public.treinamento_inscricoes where id = p_id for update;
  if not found then raise exception 'INSCRICAO_NAO_ENCONTRADA'; end if;
  if not public.eh_equipe() then
    if v.user_id is distinct from auth.uid() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
    select * into h from public.treinamento_horarios where id = v.horario_id;
    if h.inicio <= now() then raise exception 'HORARIO_JA_COMECOU'; end if;
    if v.presente then raise exception 'PRESENCA_JA_CONFIRMADA'; end if;
  end if;
  delete from public.treinamento_inscricoes where id = p_id;
end;
$$;

-- presença: só a equipe
create or replace function public.presenca_treinamento(p_id uuid, p_presente boolean)
returns public.treinamento_inscricoes language plpgsql security definer set search_path = public as $$
declare v public.treinamento_inscricoes;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.treinamento_inscricoes
     set presente = p_presente,
         presenca_em = case when p_presente then now() end,
         presenca_por = case when p_presente then public.meu_email() end
   where id = p_id returning * into v;
  if not found then raise exception 'INSCRICAO_NAO_ENCONTRADA'; end if;
  return v;
end;
$$;

-- abrir ou fechar inscrições, e mudar o limite de um horário (administrador)
create or replace function public.ajustar_treinamento(p_treinamento uuid, p_abertas boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.treinamentos set inscricoes_abertas = p_abertas where id = p_treinamento;
end;
$$;
create or replace function public.ajustar_limite_horario(p_horario uuid, p_limite int)
returns void language plpgsql security definer set search_path = public as $$
declare ocupadas int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select count(*) into ocupadas from public.treinamento_inscricoes where horario_id = p_horario;
  if p_limite < greatest(1, ocupadas) then raise exception 'LIMITE_ABAIXO_DOS_INSCRITOS' using hint = ocupadas::text; end if;
  update public.treinamento_horarios set limite = p_limite where id = p_horario;
end;
$$;

revoke all on function public.treinamento_vagas(uuid), public.inscrever_treinamento(uuid, uuid, text, text),
  public.cancelar_inscricao_treinamento(uuid), public.presenca_treinamento(uuid, boolean),
  public.ajustar_treinamento(uuid, boolean), public.ajustar_limite_horario(uuid, int) from public, anon;
grant execute on function public.treinamento_vagas(uuid), public.inscrever_treinamento(uuid, uuid, text, text),
  public.cancelar_inscricao_treinamento(uuid), public.presenca_treinamento(uuid, boolean),
  public.ajustar_treinamento(uuid, boolean), public.ajustar_limite_horario(uuid, int) to authenticated;

-- ---------------------------------------------------------------------
-- Treinamento de 18 e 19/11/2026 (horário de Brasília)
-- ---------------------------------------------------------------------
do $$
declare t uuid; d date; hr time;
begin
  if exists (select 1 from public.treinamentos where nome = 'Treinamento Duo Haus') then return; end if;
  insert into public.treinamentos (nome) values ('Treinamento Duo Haus') returning id into t;
  foreach d in array array['2026-11-18'::date, '2026-11-19'::date] loop
    for hr in select generate_series('2000-01-01 09:00'::timestamp, '2000-01-01 11:30', interval '30 minutes')::time
              union all
              select generate_series('2000-01-01 14:00'::timestamp, '2000-01-01 19:00', interval '30 minutes')::time loop
      insert into public.treinamento_horarios (treinamento_id, inicio, limite)
      values (t, (d + hr) at time zone 'America/Sao_Paulo', 25);
    end loop;
  end loop;
end $$;
