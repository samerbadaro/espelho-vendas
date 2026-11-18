-- Atualização do banco de TESTES (espelho-v2) — 18/11/2026
-- Rodar uma vez no SQL Editor do projeto espelho-v2 (NUNCA no projeto do Duo Haus).
-- Traz do Duo Haus: 027 rodadas por pessoas, 028 funil dos parceiros, 029 corretor responsável, 030/031/033 treinamentos, 032 recepcionista;
-- e da v2: 115 número de presença e sorteio do Meeting.

-- >>>>> 027
-- =====================================================================
-- 027 — Rodadas: o limite passa a contar PESSOAS (cliente + acompanhantes)
--  * Um cliente com 2 acompanhantes ocupa 3 vagas.
--  * Confirmar ou editar só passa se couber no limite; senão VAGAS_INSUFICIENTES
--    (o hint diz quantas vagas restam).
--  * O nome do corretor nas confirmações é o nome do cadastro, nunca o e-mail.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create or replace function public.confirmar_cliente_rodada(
  p_rodada uuid, p_convidados text[], p_telefone text default null, p_observacao text default null,
  p_imobiliaria uuid default null
) returns public.rodada_inscricoes
language plpgsql security definer set search_path = public as $$
declare
  v_rodada public.rodadas;
  v_lista  text[] := public.normalizar_convidados(p_convidados);
  v_imob   uuid;
  v_nome   text;
  v_ocup   int;
  v        public.rodada_inscricoes;
begin
  select * into v_rodada from public.rodadas where id = p_rodada for update;
  if not found or not public.rodada_liberada(p_rodada) then raise exception 'RODADA_NAO_ENCONTRADA'; end if;
  if not public.eh_equipe() and not v_rodada.inscricoes_abertas then raise exception 'INSCRICOES_ENCERRADAS'; end if;
  if not public.eh_equipe() and v_rodada.data_hora < now() then raise exception 'RODADA_JA_ACONTECEU'; end if;

  select coalesce(sum(pessoas), 0) into v_ocup from public.rodada_inscricoes where rodada_id = p_rodada and not cancelada;
  if v_ocup >= v_rodada.limite_clientes then raise exception 'RODADA_LOTADA'; end if;
  if v_ocup + array_length(v_lista, 1) > v_rodada.limite_clientes then
    raise exception 'VAGAS_INSUFICIENTES' using hint = (v_rodada.limite_clientes - v_ocup)::text;
  end if;

  v_imob := case when public.eh_equipe() then p_imobiliaria else public.minha_imobiliaria() end;
  select nullif(trim(nome), '') into v_nome from public.perfis where user_id = auth.uid();

  begin
    insert into public.rodada_inscricoes (rodada_id, cliente_nome, pessoas, convidados, telefone, observacao, imobiliaria_id, corretor_id, corretor_nome)
    values (p_rodada, v_lista[1], array_length(v_lista, 1), v_lista, nullif(trim(p_telefone), ''),
            nullif(trim(p_observacao), ''), v_imob, auth.uid(), v_nome)
    returning * into v;
  exception when unique_violation then
    raise exception 'CLIENTE_JA_CONFIRMADO';
  end;
  return v;
end;
$$;

create or replace function public.editar_cliente_rodada(
  p_id uuid, p_convidados text[], p_telefone text default null, p_observacao text default null
) returns public.rodada_inscricoes
language plpgsql security definer set search_path = public as $$
declare v public.rodada_inscricoes; v_rodada public.rodadas; v_lista text[] := public.normalizar_convidados(p_convidados); v_outros int;
begin
  select * into v from public.rodada_inscricoes where id = p_id for update;
  if not found or v.cancelada or not public.pode_alterar_inscricao(v) then raise exception 'INSCRICAO_NAO_ENCONTRADA'; end if;
  select * into v_rodada from public.rodadas where id = v.rodada_id for update;
  if not public.eh_equipe() and (not v_rodada.inscricoes_abertas or v_rodada.data_hora < now()) then
    raise exception 'INSCRICOES_ENCERRADAS';
  end if;
  if array_length(v_lista, 1) > v.pessoas then
    select coalesce(sum(pessoas), 0) into v_outros from public.rodada_inscricoes
     where rodada_id = v.rodada_id and not cancelada and id <> p_id;
    if v_outros + array_length(v_lista, 1) > v_rodada.limite_clientes then
      raise exception 'VAGAS_INSUFICIENTES' using hint = greatest(0, v_rodada.limite_clientes - v_outros - v.pessoas)::text;
    end if;
  end if;
  begin
    update public.rodada_inscricoes
       set cliente_nome = v_lista[1], pessoas = array_length(v_lista, 1), convidados = v_lista,
           telefone = nullif(trim(p_telefone), ''), observacao = nullif(trim(p_observacao), ''), atualizado_em = now()
     where id = p_id returning * into v;
  exception when unique_violation then
    raise exception 'CLIENTE_JA_CONFIRMADO';
  end;
  return v;
end;
$$;

-- o limite da rodada não pode ficar abaixo das pessoas já confirmadas
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
    select coalesce(sum(pessoas), 0) into v_ocupadas from public.rodada_inscricoes where rodada_id = p_id and not cancelada;
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

-- confirmações antigas que guardaram o e-mail no lugar do nome do corretor
update public.rodada_inscricoes i
   set corretor_nome = nullif(trim(p.nome), '')
  from public.perfis p
 where p.user_id = i.corretor_id and i.corretor_nome like '%@%';

comment on column public.rodadas.limite_clientes is 'Limite de PESSOAS (cliente + acompanhantes) desde a migração 027';

-- >>>>> 028
-- =====================================================================
-- 028 — Funil de vendas para imobiliárias e corretores (só leitura)
--  * O corretor vê as negociações das pastas dele; a imobiliária, as de
--    todos os seus corretores (mesma regra de acesso das pastas).
--  * Mover etapa continua só com a equipe (mover_etapa já exige eh_equipe).
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

drop policy if exists negociacoes_parceiros on public.negociacoes;
create policy negociacoes_parceiros on public.negociacoes for select
  using (pasta_id is not null and public.pode_ver_pasta(pasta_id));

-- >>>>> 029
-- =====================================================================
-- 029 — Corretor responsável pela pasta
--  * A pasta pertence ao corretor atribuído, não a quem a cadastrou.
--    pastas.criado_por_id passa a significar "corretor responsável" (é ele
--    que todas as regras de acesso já usam); quem cadastrou fica guardado
--    em pastas.cadastrado_por_id.
--  * O corretor vê as pastas atribuídas a ele (lista, funil e andamento);
--    a imobiliária continua vendo todas as suas.
--  * Equipe e imobiliária (para as suas pastas) atribuem ou trocam o corretor.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.pastas add column if not exists cadastrado_por_id uuid;
update public.pastas set cadastrado_por_id = criado_por_id where cadastrado_por_id is null;
comment on column public.pastas.criado_por_id is 'Corretor responsável (dono da pasta para as regras de acesso)';
comment on column public.pastas.cadastrado_por_id is 'Login que cadastrou a pasta';

-- pastas cadastradas pela equipe ou pela imobiliária não têm corretor até alguém atribuir
update public.pastas p set criado_por_id = null
  from public.perfis f
 where f.user_id = p.criado_por_id and f.papel <> 'corretor';

create or replace function public.pastas_cadastro() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_papel text;
begin
  new.cadastrado_por_id := auth.uid();
  select papel into v_papel from public.perfis where user_id = auth.uid();
  -- só um corretor vira dono automático da pasta que ele mesmo cadastra
  if coalesce(v_papel, '') <> 'corretor' then new.criado_por_id := null; end if;
  return new;
end;
$$;
drop trigger if exists pastas_cadastro on public.pastas;
create trigger pastas_cadastro before insert on public.pastas
  for each row execute function public.pastas_cadastro();   -- roda depois de pastas_antes (ordem alfabética)

create or replace function public.atribuir_corretor(p_pasta uuid, p_corretor uuid)
returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v public.pastas; v_antes text; v_depois text;
begin
  select * into v from public.pastas where id = p_pasta for update;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if not (public.eh_equipe() or (public.eh_gestor() and v.imobiliaria_id = public.minha_imobiliaria())) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if p_corretor is not null and not exists (
    select 1 from public.perfis where user_id = p_corretor and papel = 'corretor' and imobiliaria_id = v.imobiliaria_id
  ) then raise exception 'CORRETOR_INVALIDO'; end if;
  if v.criado_por_id is not distinct from p_corretor then return v; end if;

  select coalesce(nullif(nome, ''), email) into v_antes from public.perfis where user_id = v.criado_por_id;
  select coalesce(nullif(nome, ''), email) into v_depois from public.perfis where user_id = p_corretor;
  update public.pastas set criado_por_id = p_corretor where id = p_pasta returning * into v;
  update public.negociacoes set corretor = v_depois where pasta_id = p_pasta and ativa;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Corretor responsável alterado',
          jsonb_build_object('corretor', coalesce(v_antes, 'sem corretor') || ' → ' || coalesce(v_depois, 'sem corretor')),
          public.meu_email());
  return v;
end;
$$;
revoke all on function public.atribuir_corretor(uuid, uuid) from public, anon;
grant execute on function public.atribuir_corretor(uuid, uuid) to authenticated;

-- >>>>> 030
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

-- >>>>> 031
-- =====================================================================
-- 031 — Ajuste da agenda de treinamentos
--  * Quarta, 18/11: começa às 14:00 (saem os horários da manhã).
--  * Quinta, 19/11: continua começando às 09:00.
--  * Todas as turmas passam a ter 20 pessoas.
--  * Segurança: horário da manhã de 18/11 que já tenha inscritos NÃO é
--    apagado (o script avisa quantos são); turma que já passou de 20
--    inscritos fica com o limite igual ao número de inscritos.
-- Rodar depois do 030, uma única vez, no SQL Editor do Supabase.
-- =====================================================================
alter table public.treinamento_horarios alter column limite set default 20;

do $$
declare t uuid; com_inscritos int; apagados int;
begin
  select id into t from public.treinamentos where nome = 'Treinamento Duo Haus';
  if t is null then raise exception 'Rode primeiro o 030_treinamentos.sql.'; end if;

  -- manhã de 18/11
  select count(distinct h.id) into com_inscritos
    from public.treinamento_horarios h join public.treinamento_inscricoes i on i.horario_id = h.id
   where h.treinamento_id = t
     and (h.inicio at time zone 'America/Sao_Paulo')::date = '2026-11-18'
     and (h.inicio at time zone 'America/Sao_Paulo')::time < '14:00';
  delete from public.treinamento_horarios h
   where h.treinamento_id = t
     and (h.inicio at time zone 'America/Sao_Paulo')::date = '2026-11-18'
     and (h.inicio at time zone 'America/Sao_Paulo')::time < '14:00'
     and not exists (select 1 from public.treinamento_inscricoes i where i.horario_id = h.id);
  get diagnostics apagados = row_count;

  -- 20 pessoas por turma
  update public.treinamento_horarios h
     set limite = greatest(20, (select count(*) from public.treinamento_inscricoes i where i.horario_id = h.id))
   where h.treinamento_id = t;

  raise notice 'Horários da manhã de 18/11 removidos: %.', apagados;
  if com_inscritos > 0 then
    raise notice 'ATENÇÃO: % horário(s) da manhã de 18/11 já tinham inscritos e foram mantidos. Remova as inscrições na tela de Treinamentos e rode este arquivo de novo.', com_inscritos;
  end if;
end $$;

-- >>>>> 032
-- =====================================================================
-- 032 — Perfil Recepcionista
--  * Novo papel 'recepcao': acesso somente ao Meeting.
--  * No Meeting pode tudo o que a equipe pode: ver a lista, confirmar
--    presença, incluir quem não estava na lista e editar dados.
--  * Não vê pastas, espelho, funil, rodadas, portal nem configurações.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.perfis drop constraint if exists perfis_papel_check;
alter table public.perfis add constraint perfis_papel_check
  check (papel in ('admin', 'vendas', 'imobiliaria', 'corretor', 'recepcao'));

-- Quem opera o Meeting: equipe de vendas ou recepcionista
create or replace function public.pode_meeting() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid() and papel in ('admin', 'vendas', 'recepcao'));
$$;
revoke all on function public.pode_meeting() from public, anon;
grant execute on function public.pode_meeting() to authenticated;

drop policy if exists recepcao_eventos_leitura on public.recepcao_eventos;
drop policy if exists recepcao_participantes_leitura on public.recepcao_participantes;
create policy recepcao_eventos_leitura on public.recepcao_eventos for select using (public.pode_meeting());
create policy recepcao_participantes_leitura on public.recepcao_participantes for select using (public.pode_meeting());

create or replace function public.marcar_presenca(p_id uuid, p_presente boolean) returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes;
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.recepcao_participantes
     set presente = p_presente,
         chegada_em = case when p_presente then coalesce(chegada_em, now()) else null end,
         confirmado_por = case when p_presente then public.meu_email() else null end
   where id = p_id returning * into v;
  if not found then raise exception 'PARTICIPANTE_NAO_ENCONTRADO'; end if;
  return v;
end;
$$;

create or replace function public.incluir_participante(p_evento uuid, p_nome text, p_imobiliaria text default null, p_telefone text default null)
returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes;
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  insert into public.recepcao_participantes (evento_id, nome, imobiliaria, telefone, presente, chegada_em, confirmado_por, incluido_na_hora)
  values (p_evento, regexp_replace(trim(p_nome), '\s+', ' ', 'g'), nullif(trim(p_imobiliaria), ''),
          nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), ''), true, now(), public.meu_email(), true)
  returning * into v;
  return v;
end;
$$;

create or replace function public.editar_participante(p_id uuid, p_nome text, p_imobiliaria text default null,
                                                      p_telefone text default null, p_confirmar boolean default false)
returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes;
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  update public.recepcao_participantes
     set nome = regexp_replace(trim(p_nome), '\s+', ' ', 'g'),
         imobiliaria = nullif(regexp_replace(trim(coalesce(p_imobiliaria, '')), '\s+', ' ', 'g'), ''),
         telefone = nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), ''),
         presente = presente or p_confirmar,
         chegada_em = case when p_confirmar and not presente then now() else chegada_em end,
         confirmado_por = case when p_confirmar and not presente then public.meu_email() else confirmado_por end
   where id = p_id returning * into v;
  if not found then raise exception 'PARTICIPANTE_NAO_ENCONTRADO'; end if;
  return v;
end;
$$;

-- >>>>> 033
-- =====================================================================
-- 033 — Treinamentos: o administrador configura os horários
--  * Adicionar horários: um dia, das HH:MM às HH:MM, a cada N minutos,
--    com o limite de pessoas (os que já existem são mantidos).
--  * Remover um horário: só se ninguém estiver inscrito nele.
--  * O limite de cada turma continua em ajustar_limite_horario (030).
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create or replace function public.adicionar_horarios_treinamento(p_treinamento uuid, p_dia date, p_inicio time,
                                                                 p_fim time, p_intervalo int, p_limite int)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_dia is null or p_inicio is null then raise exception 'HORARIO_INVALIDO'; end if;
  if p_fim is null then p_fim := p_inicio; end if;
  if p_fim < p_inicio then raise exception 'FIM_ANTES_DO_INICIO'; end if;
  if coalesce(p_intervalo, 0) < 5 or p_intervalo > 480 then raise exception 'INTERVALO_INVALIDO'; end if;
  if coalesce(p_limite, 0) < 1 or p_limite > 1000 then raise exception 'LIMITE_INVALIDO'; end if;
  if not exists (select 1 from public.treinamentos where id = p_treinamento) then raise exception 'TREINAMENTO_NAO_ENCONTRADO'; end if;
  insert into public.treinamento_horarios (treinamento_id, inicio, limite)
  select p_treinamento, h at time zone 'America/Sao_Paulo', p_limite
    from generate_series(p_dia + p_inicio, p_dia + p_fim, make_interval(mins => p_intervalo)) as h
  on conflict (treinamento_id, inicio) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.remover_horario_treinamento(p_horario uuid)
returns void language plpgsql security definer set search_path = public as $$
declare ocupadas int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select count(*) into ocupadas from public.treinamento_inscricoes where horario_id = p_horario;
  if ocupadas > 0 then raise exception 'HORARIO_COM_INSCRITOS' using hint = ocupadas::text; end if;
  delete from public.treinamento_horarios where id = p_horario;
  if not found then raise exception 'HORARIO_NAO_ENCONTRADO'; end if;
end;
$$;

revoke all on function public.adicionar_horarios_treinamento(uuid, date, time, time, int, int),
  public.remover_horario_treinamento(uuid) from public, anon;
grant execute on function public.adicionar_horarios_treinamento(uuid, date, time, time, int, int),
  public.remover_horario_treinamento(uuid) to authenticated;

-- >>>>> 115
-- =====================================================================
-- 115 — Meeting: número de presença e sorteio
--  * Ao confirmar a presença, o participante recebe um número sequencial
--    do meeting (1, 2, 3...), na ordem de chegada. Desfazer a confirmação
--    não libera o número; quem volta a ser confirmado mantém o mesmo.
--  * Sorteio feito no banco (sem viciar pelo navegador), só entre os
--    presentes com número que ainda não foram sorteados. Cada sorteio fica
--    registrado (ordem, prêmio, quem sorteou). Ganhador ausente: marca e
--    sorteia de novo.
--  * Recepcionista (032) opera o Meeting como a equipe: inclui, edita,
--    remove inscrição, cadastra meeting e faz o sorteio.
-- =====================================================================

alter table public.recepcao_participantes add column if not exists numero int;
create unique index if not exists recepcao_participantes_numero_key on public.recepcao_participantes (evento_id, numero) where numero is not null;

-- quem já estava confirmado recebe o número pela ordem de chegada
update public.recepcao_participantes p set numero = x.n
  from (select id, row_number() over (partition by evento_id order by chegada_em nulls last, criado_em) as n
          from public.recepcao_participantes where presente) x
 where x.id = p.id and p.numero is null
   and not exists (select 1 from public.recepcao_participantes q where q.evento_id = p.evento_id and q.numero is not null);

create or replace function public.recepcao_numerar() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.presente and new.numero is null then
    perform 1 from public.recepcao_eventos where id = new.evento_id for update;   -- um número por vez no meeting
    select coalesce(max(numero), 0) + 1 into new.numero from public.recepcao_participantes where evento_id = new.evento_id;
  end if;
  return new;
end;
$$;
drop trigger if exists recepcao_participantes_numerar on public.recepcao_participantes;
create trigger recepcao_participantes_numerar before insert or update of presente on public.recepcao_participantes
  for each row execute function public.recepcao_numerar();

-- ---------------------------------------------------------------------
-- Sorteio
-- ---------------------------------------------------------------------
create table if not exists public.meeting_sorteios (
  id              uuid primary key default gen_random_uuid(),
  evento_id       uuid not null references public.recepcao_eventos (id) on delete cascade,
  participante_id uuid not null references public.recepcao_participantes (id) on delete cascade,
  ordem           int not null,
  numero          int not null,
  nome            text not null,
  imobiliaria     text,
  premio          text,
  status          text not null default 'valido' check (status in ('valido', 'ausente')),
  sorteado_em     timestamptz not null default now(),
  sorteado_por    text,
  unique (evento_id, participante_id)
);
alter table public.meeting_sorteios enable row level security;
revoke all on public.meeting_sorteios from anon, authenticated;
grant select on public.meeting_sorteios to authenticated;
drop policy if exists meeting_sorteios_leitura on public.meeting_sorteios;
create policy meeting_sorteios_leitura on public.meeting_sorteios for select
  using (public.pode_meeting() and exists (select 1 from public.recepcao_eventos e where e.id = evento_id));

create or replace function public.sortear_meeting(p_evento uuid, p_premio text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.recepcao_participantes; v public.meeting_sorteios; v_ordem int;
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  perform 1 from public.recepcao_eventos where id = p_evento and empreendimento_id = public.empreendimento_atual() for update;
  if not found then raise exception 'MEETING_NAO_ENCONTRADO'; end if;

  select p.* into g from public.recepcao_participantes p
   where p.evento_id = p_evento and p.presente and p.numero is not null
     and not exists (select 1 from public.meeting_sorteios s where s.evento_id = p_evento and s.participante_id = p.id)
   order by random() limit 1;
  if not found then raise exception 'SEM_PARTICIPANTES_PARA_SORTEIO'; end if;

  select coalesce(max(ordem), 0) + 1 into v_ordem from public.meeting_sorteios where evento_id = p_evento;
  insert into public.meeting_sorteios (evento_id, participante_id, ordem, numero, nome, imobiliaria, premio, sorteado_por)
  values (p_evento, g.id, v_ordem, g.numero, g.nome, g.imobiliaria, nullif(trim(coalesce(p_premio, '')), ''), public.meu_email())
  returning * into v;
  return to_jsonb(v);
end;
$$;

create or replace function public.sorteio_ausente(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.meeting_sorteios set status = 'ausente' where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Recepcionista opera o Meeting como a equipe
-- ---------------------------------------------------------------------
create or replace function public.incluir_participante(p_evento uuid, p_nome text, p_imobiliaria text default null, p_telefone text default null)
returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes; v_tel text := public.normalizar_telefone(p_telefone);
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if v_tel is not null and exists (select 1 from public.recepcao_participantes where evento_id = p_evento and telefone = v_tel and origem = 'inscricao') then
    raise exception 'TELEFONE_JA_INSCRITO';
  end if;
  insert into public.recepcao_participantes (evento_id, nome, imobiliaria, telefone, presente, chegada_em, confirmado_por, incluido_na_hora, origem)
  values (p_evento, regexp_replace(trim(p_nome), '\s+', ' ', 'g'), nullif(trim(p_imobiliaria), ''), v_tel, true, now(), public.meu_email(), true, 'na_hora')
  returning * into v;
  return v;
end;
$$;

create or replace function public.remover_inscricao(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  delete from public.recepcao_participantes where id = p_id;
end;
$$;

create or replace function public.salvar_meeting(
  p_id uuid, p_nome text, p_slug text, p_data_hora timestamptz default null, p_local text default null,
  p_descricao text default null, p_abertas boolean default false, p_vagas int default null, p_encerra_em timestamptz default null
) returns public.recepcao_eventos
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_eventos; v_slug text := lower(trim(coalesce(p_slug, '')));
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if v_slug !~ '^[a-z0-9][a-z0-9-]{2,59}$' then raise exception 'ENDERECO_INVALIDO'; end if;
  if exists (select 1 from public.recepcao_eventos where slug = v_slug and id is distinct from p_id) then raise exception 'ENDERECO_EM_USO'; end if;
  if p_id is null then
    insert into public.recepcao_eventos (nome, slug, data_hora, local, descricao, inscricoes_abertas, vagas, encerra_em)
    values (trim(p_nome), v_slug, p_data_hora, nullif(trim(p_local), ''), nullif(trim(p_descricao), ''), p_abertas, p_vagas, p_encerra_em)
    returning * into v;
  else
    update public.recepcao_eventos
       set nome = trim(p_nome), slug = v_slug, data_hora = p_data_hora, local = nullif(trim(p_local), ''),
           descricao = nullif(trim(p_descricao), ''), inscricoes_abertas = p_abertas, vagas = p_vagas,
           encerra_em = p_encerra_em, atualizado_em = now()
     where id = p_id returning * into v;
    if not found then raise exception 'MEETING_NAO_ENCONTRADO'; end if;
  end if;
  return v;
end;
$$;

revoke all on function public.sortear_meeting(uuid, text), public.sorteio_ausente(uuid), public.recepcao_numerar() from public, anon;
grant execute on function public.sortear_meeting(uuid, text), public.sorteio_ausente(uuid) to authenticated;
-- políticas de leitura chamam pode_meeting(): visitante sem login recebe "não", e não erro
grant execute on function public.pode_meeting() to anon;
