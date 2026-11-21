-- Atualização do banco de TESTES (espelho-v2) — 21/11/2026
-- Rodar uma vez no SQL Editor do projeto espelho-v2 (NUNCA no projeto do Duo Haus).
-- Substitui o arquivo de 18/11 (que não chegou a ser rodado): já inclui tudo o que estava nele.
-- Traz do Duo Haus 027 a 048 (rodadas, funil e espelho dos parceiros, treinamentos, recepcionista,
-- premiação do portal, regime de bens, PJ, contratos, D4Sign, Pix do sinal, leads, manual)
-- e da v2: 115 (número de presença e sorteio) e 116 (esses módulos separados por empreendimento).
-- Da 035 entram só as partes novas: as propostas (101 a 105) já estão neste banco.
-- Nada é configurado: IA, D4Sign, minutas e leads ficam em branco.

-- >>>>> 027_rodadas_vagas_pessoas
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

-- >>>>> 028_funil_parceiros
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

-- >>>>> 029_corretor_responsavel
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

-- >>>>> 030_treinamentos
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

-- >>>>> 031_treinamentos_ajuste
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

-- >>>>> 032_recepcionista
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

-- >>>>> 033_treinamentos_horarios
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

-- >>>>> 034_portal_premiacao
-- =====================================================================
-- 034 — Portal do Corretor: categoria "Regras da premiação"
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================
alter table public.portal_itens drop constraint if exists portal_itens_categoria_check;
alter table public.portal_itens add constraint portal_itens_categoria_check check (categoria in (
  'book', 'ficha_tecnica', 'fotos_decorado', 'imagens', 'materiais_apoio', 'redes_sociais',
  'plantas', 'premiacao', 'simulador', 'tour_virtual', 'videos'));

-- >>>>> 035 (só as partes novas)
begin;
alter table public.config add column if not exists modulo_propostas boolean not null default false;
create or replace function public.propostas_modulo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_equipe() and not coalesce((select modulo_propostas from public.config
                                              where empreendimento_id = coalesce(new.empreendimento_id, public.empreendimento_atual())), false) then
    raise exception 'MODULO_DESLIGADO' using hint = 'As propostas ainda não estão liberadas.';
  end if;
  return new;
end;
$$;
drop trigger if exists propostas_0_modulo on public.propostas;
create trigger propostas_0_modulo before insert on public.propostas
  for each row execute function public.propostas_modulo();
commit;

-- >>>>> 036_propostas_permissao
-- =====================================================================
-- 036 — Corrige o salvar de Empreendimento depois do 035
-- O 035 criou a chave "modulo_propostas", mas não liberou a gravação dela.
-- Como a tela de Empreendimento salva todas as chaves juntas, qualquer
-- mudança de módulo dava erro. Executar uma única vez no SQL Editor.
-- =====================================================================
grant update (modulo_propostas) on public.config to authenticated;

-- >>>>> 037_rodadas_convite
-- =====================================================================
-- 037 — Convite da rodada de negócios
--  * O administrador anexa o convite (imagem ou PDF) à rodada.
--  * Quem pode baixar: a equipe, e o corretor ou a imobiliária que tem pelo
--    menos um cliente confirmado (não cancelado) naquela rodada.
--  * Arquivo em bucket privado ("rodadas"), baixado por link temporário.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.rodadas
  add column if not exists convite_caminho text,
  add column if not exists convite_nome    text,
  add column if not exists convite_tipo    text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rodadas', 'rodadas', false, 20971520, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false;

-- Pode baixar o convite desta rodada?
create or replace function public.pode_baixar_convite(p_rodada uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe() or exists (
    select 1 from public.rodada_inscricoes i
     where i.rodada_id = p_rodada and not i.cancelada
       and i.imobiliaria_id = public.minha_imobiliaria()
       and (public.eh_gestor() or i.corretor_id = auth.uid()));
$$;

-- Arquivo "<id da rodada>/<nome>" no bucket
create or replace function public.convite_liberado(p_nome text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_id text := split_part(p_nome, '/', 1);
begin
  if v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  return public.pode_baixar_convite(v_id::uuid);
end;
$$;
revoke all on function public.pode_baixar_convite(uuid), public.convite_liberado(text) from public, anon;
grant execute on function public.pode_baixar_convite(uuid), public.convite_liberado(text) to authenticated;

drop policy if exists rodadas_convite_leitura on storage.objects;
drop policy if exists rodadas_convite_envio on storage.objects;
drop policy if exists rodadas_convite_remocao on storage.objects;
create policy rodadas_convite_leitura on storage.objects for select to authenticated
  using (bucket_id = 'rodadas' and public.convite_liberado(name));
create policy rodadas_convite_envio on storage.objects for insert to authenticated
  with check (bucket_id = 'rodadas' and public.eh_admin());
create policy rodadas_convite_remocao on storage.objects for delete to authenticated
  using (bucket_id = 'rodadas' and public.eh_admin());

-- Grava (ou tira) o convite da rodada; devolve o arquivo anterior para a tela apagar
create or replace function public.definir_convite_rodada(p_rodada uuid, p_caminho text, p_nome text default null, p_tipo text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_antigo text;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select convite_caminho into v_antigo from public.rodadas where id = p_rodada for update;
  if not found then raise exception 'RODADA_NAO_ENCONTRADA'; end if;
  if p_caminho is not null and split_part(p_caminho, '/', 1) <> p_rodada::text then raise exception 'CAMINHO_INVALIDO'; end if;
  update public.rodadas
     set convite_caminho = p_caminho,
         convite_nome = case when p_caminho is null then null else left(coalesce(p_nome, 'convite'), 200) end,
         convite_tipo = case when p_caminho is null then null else p_tipo end
   where id = p_rodada;
  return case when v_antigo is distinct from p_caminho then v_antigo end;
end;
$$;
revoke all on function public.definir_convite_rodada(uuid, text, text, text) from public, anon;
grant execute on function public.definir_convite_rodada(uuid, text, text, text) to authenticated;

-- >>>>> 038_dados_contrato
-- =====================================================================
-- 038 — Dados para contrato (leitura dos documentos com IA)
--  * Depois que a pasta tem proposta APROVADA, a equipe (administrador e
--    Sec. Vendas) abre "Dados para contrato" e pede para a IA ler os
--    documentos da pasta. A IA sugere; a equipe confere e marca "Conferido".
--  * Corretor e imobiliária não veem estes dados.
--  * Cada leitura fica registrada (quem, quando, modelo e tokens).
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create table if not exists public.dados_contrato (
  pasta_id      uuid primary key references public.pastas(id) on delete cascade,
  dados         jsonb not null default '{}'::jsonb,
  fontes        jsonb not null default '{}'::jsonb,
  alertas       jsonb not null default '[]'::jsonb,
  status        text not null default 'rascunho' check (status in ('rascunho', 'conferido')),
  lido_em       timestamptz,
  lido_por      text,
  conferido_em  timestamptz,
  conferido_por text,
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
alter table public.dados_contrato enable row level security;
drop policy if exists dados_contrato_equipe on public.dados_contrato;
create policy dados_contrato_equipe on public.dados_contrato for select using (public.eh_equipe());
revoke all on public.dados_contrato from anon, authenticated;
grant select on public.dados_contrato to authenticated;

create table if not exists public.ia_leituras (
  id              bigint generated always as identity primary key,
  pasta_id        uuid references public.pastas(id) on delete set null,
  usuario_email   text,
  modelo          text,
  documentos      int,
  tokens_entrada  int,
  tokens_saida    int,
  criado_em       timestamptz not null default now()
);
alter table public.ia_leituras enable row level security;
drop policy if exists ia_leituras_admin on public.ia_leituras;
create policy ia_leituras_admin on public.ia_leituras for select using (public.eh_admin());
revoke all on public.ia_leituras from anon, authenticated;
grant select on public.ia_leituras to authenticated;

-- A pasta já tem proposta aprovada?
create or replace function public.contrato_liberado(p_pasta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.propostas where pasta_id = p_pasta and status = 'aprovada');
$$;

-- O que a IA precisa: dados digitados na pasta + lista de documentos atuais (só equipe, só com proposta aprovada)
create or replace function public.documentos_para_leitura(p_pasta uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  select jsonb_build_object(
    'pasta', jsonb_build_object('codigo', p.codigo, 'estado_civil', p.estado_civil,
      'comprador', jsonb_build_object('nome', p.comprador_nome, 'cpf', p.comprador_cpf, 'nascimento', p.comprador_nascimento,
                                      'email', p.comprador_email, 'telefone', p.comprador_telefone, 'profissao', p.comprador_profissao),
      'conjuge', jsonb_build_object('nome', p.conjuge_nome, 'cpf', p.conjuge_cpf, 'nascimento', p.conjuge_nascimento,
                                    'email', p.conjuge_email, 'telefone', p.conjuge_telefone, 'profissao', p.conjuge_profissao)),
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'caminho', d.caminho, 'arquivo', d.nome_arquivo,
                                 'mime', d.mime, 'tipo', t.nome, 'pessoa', t.pessoa) order by t.ordem, d.enviado_em)
                              from public.documentos d join public.tipos_documento t on t.id = d.tipo_id
                             where d.pasta_id = p.id and d.atual and d.status <> 'recusado'), '[]'::jsonb))
    into v from public.pastas p where p.id = p_pasta;
  if v is null then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  return v;
end;
$$;

-- Grava o resultado da leitura (substitui a sugestão anterior; volta para "rascunho")
create or replace function public.gravar_leitura_ia(p_pasta uuid, p_dados jsonb, p_fontes jsonb, p_alertas jsonb,
                                                    p_modelo text, p_documentos int, p_tokens_entrada int, p_tokens_saida int)
returns public.dados_contrato language plpgsql security definer set search_path = public as $$
declare v public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  insert into public.dados_contrato as d (pasta_id, dados, fontes, alertas, status, lido_em, lido_por, atualizado_em, atualizado_por)
  values (p_pasta, coalesce(p_dados, '{}'), coalesce(p_fontes, '{}'), coalesce(p_alertas, '[]'), 'rascunho', now(), public.meu_email(), now(), public.meu_email())
  on conflict (pasta_id) do update set dados = excluded.dados, fontes = excluded.fontes, alertas = excluded.alertas,
     status = 'rascunho', lido_em = now(), lido_por = public.meu_email(), conferido_em = null, conferido_por = null,
     atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  insert into public.ia_leituras (pasta_id, usuario_email, modelo, documentos, tokens_entrada, tokens_saida)
  values (p_pasta, public.meu_email(), left(p_modelo, 60), p_documentos, p_tokens_entrada, p_tokens_saida);
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Documentos lidos com IA', jsonb_build_object('documentos', p_documentos), public.meu_email());
  return v;
end;
$$;

-- A equipe corrige os campos e, se quiser, marca como conferido
create or replace function public.salvar_dados_contrato(p_pasta uuid, p_dados jsonb, p_conferido boolean default false)
returns public.dados_contrato language plpgsql security definer set search_path = public as $$
declare v public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  insert into public.dados_contrato as d (pasta_id, dados, status, conferido_em, conferido_por, atualizado_em, atualizado_por)
  values (p_pasta, coalesce(p_dados, '{}'), case when p_conferido then 'conferido' else 'rascunho' end,
          case when p_conferido then now() end, case when p_conferido then public.meu_email() end, now(), public.meu_email())
  on conflict (pasta_id) do update set dados = excluded.dados, status = excluded.status,
     conferido_em = excluded.conferido_em, conferido_por = excluded.conferido_por,
     atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  if p_conferido then
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (p_pasta, 'Dados para contrato conferidos', null, public.meu_email());
  end if;
  return v;
end;
$$;

revoke all on function public.contrato_liberado(uuid), public.documentos_para_leitura(uuid),
  public.gravar_leitura_ia(uuid, jsonb, jsonb, jsonb, text, int, int, int), public.salvar_dados_contrato(uuid, jsonb, boolean) from public, anon;
grant execute on function public.contrato_liberado(uuid), public.documentos_para_leitura(uuid),
  public.gravar_leitura_ia(uuid, jsonb, jsonb, jsonb, text, int, int, int), public.salvar_dados_contrato(uuid, jsonb, boolean) to authenticated;

-- >>>>> 039_regime_bens
-- =====================================================================
-- 039 — Regime de bens e participação do cônjuge
--  * Casado(a) ou união estável: informar o regime de bens.
--  * Separação total ou obrigatória: o cliente escolhe se o cônjuge
--    participa do contrato. Se não participa, os dados e documentos do
--    cônjuge deixam de ser exigidos (a certidão de casamento continua).
--  * Pastas antigas sem regime seguem exigindo o cônjuge, como hoje;
--    o regime passa a ser exigido ao submeter.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================
begin;

alter table public.pastas add column if not exists regime_bens text
  check (regime_bens is null or regime_bens in ('comunhao_parcial', 'comunhao_universal', 'separacao_total', 'separacao_obrigatoria', 'participacao_aquestos'));
alter table public.pastas add column if not exists conjuge_participa boolean not null default true;
grant insert (regime_bens, conjuge_participa), update (regime_bens, conjuge_participa) on public.pastas to authenticated;

-- O cônjuge entra no contrato (dados e documentos exigidos)?
create or replace function public.conjuge_no_contrato(p_ec public.estado_civil, p_regime text, p_participa boolean)
returns boolean language sql immutable as $$
  select p_ec in ('casado', 'uniao_estavel')
     and (coalesce(p_regime, '') not in ('separacao_total', 'separacao_obrigatoria') or coalesce(p_participa, true));
$$;
grant execute on function public.conjuge_no_contrato(public.estado_civil, text, boolean) to authenticated;

create or replace function public.pastas_antes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := public.meu_email();
    new.criado_por_id := auth.uid();
  end if;

  if tg_op = 'INSERT'
     or (new.comprador_nome, new.comprador_cpf, new.comprador_nascimento, new.comprador_telefone,
         new.comprador_email, new.comprador_profissao, new.estado_civil, new.observacoes)
        is distinct from
        (old.comprador_nome, old.comprador_cpf, old.comprador_nascimento, old.comprador_telefone,
         old.comprador_email, old.comprador_profissao, old.estado_civil, old.observacoes) then
    if length(trim(coalesce(new.comprador_telefone, ''))) < 10
       or length(trim(coalesce(new.comprador_email, ''))) <= 3
       or length(trim(coalesce(new.comprador_profissao, ''))) <= 1 then
      raise exception 'DADOS_INCOMPLETOS' using hint = 'Telefone, e-mail e profissão do comprador são obrigatórios.';
    end if;
  end if;

  new.atualizada_em := now();
  if new.estado_civil not in ('casado', 'uniao_estavel') then new.regime_bens := null; end if;
  if coalesce(new.regime_bens, '') not in ('separacao_total', 'separacao_obrigatoria') then new.conjuge_participa := true; end if;
  if not public.conjuge_no_contrato(new.estado_civil, new.regime_bens, new.conjuge_participa) then
    new.conjuge_nome := null; new.conjuge_cpf := null; new.conjuge_nascimento := null;
    new.conjuge_telefone := null; new.conjuge_email := null; new.conjuge_profissao := null;
  end if;
  return new;
end;
$$;

create or replace function public.recalcular_pasta(p_pasta uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ec        public.estado_civil;
  v_conjuge   boolean;
  v_submetida boolean;
  v_status    text;
  v_faltando  int;
  v_recusado  int;
  v_analise   int;
  v_enviado   int;
begin
  select estado_civil, public.conjuge_no_contrato(estado_civil, regime_bens, conjuge_participa), codigo_aprovacao is not null
    into v_ec, v_conjuge, v_submetida from public.pastas where id = p_pasta;

  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo and v_ec = any (t.obrigatorio_para)
     and (t.pessoa <> 'conjuge' or v_conjuge)
     and not exists (select 1 from public.documentos d where d.pasta_id = p_pasta and d.tipo_id = t.id and d.atual);
  select count(*) into v_recusado from public.documentos where pasta_id = p_pasta and atual and status = 'recusado';
  select count(*) into v_analise  from public.documentos where pasta_id = p_pasta and atual and status = 'em_analise';
  select count(*) into v_enviado  from public.documentos where pasta_id = p_pasta and atual and status = 'enviado';

  if not v_submetida then
    v_status := case when v_faltando > 0 then 'incompleta' else 'pronta' end;
  else
    v_status := case
      when v_recusado > 0 then 'pendente_correcao'
      when v_faltando > 0 then 'incompleta'
      when v_analise > 0 then 'em_analise'
      when v_enviado > 0 then 'aguardando_analise'
      else 'aprovada' end;
  end if;

  update public.pastas set status = v_status where id = p_pasta and status is distinct from v_status;
  return v_status;
end;
$$;

create or replace function public.submeter_pasta(p_pasta uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v_pasta.codigo_aprovacao is not null then raise exception 'JA_SUBMETIDA'; end if;
  if length(trim(coalesce(v_pasta.comprador_telefone, ''))) < 10
     or length(trim(coalesce(v_pasta.comprador_email, ''))) <= 3
     or length(trim(coalesce(v_pasta.comprador_profissao, ''))) <= 1 then
    raise exception 'DADOS_INCOMPLETOS';
  end if;
  if v_pasta.estado_civil in ('casado', 'uniao_estavel') and v_pasta.regime_bens is null then
    raise exception 'REGIME_NAO_INFORMADO';
  end if;
  if public.conjuge_no_contrato(v_pasta.estado_civil, v_pasta.regime_bens, v_pasta.conjuge_participa)
     and (length(trim(coalesce(v_pasta.conjuge_nome, ''))) <= 1
          or v_pasta.conjuge_cpf is null
          or length(trim(coalesce(v_pasta.conjuge_profissao, ''))) <= 1) then
    raise exception 'DADOS_CONJUGE_INCOMPLETOS';
  end if;
  if public.recalcular_pasta(p_pasta) <> 'pronta' then raise exception 'DOCUMENTOS_FALTANDO'; end if;

  update public.pastas
     set codigo_aprovacao = public.formatar_codigo('PA', nextval('public.pastas_aprovacao_seq')),
         submetida_em = now(), submetida_por = public.meu_email()
   where id = p_pasta
  returning * into v_pasta;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pasta submetida ao incorporador', jsonb_build_object('codigo', v_pasta.codigo_aprovacao), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$$;

create or replace function public.pastas_depois() returns trigger
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
       and n.key not in ('status', 'atualizada_em', 'unidade_id', 'codigo_aprovacao', 'submetida_em', 'submetida_por',
                         'etapa_venda', 'etapa_atualizada_em', 'unidades_numeros');
    if v_campos is not null then
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (new.id, 'Dados alterados', jsonb_build_object('campos', v_campos), public.meu_email());
    end if;
    if (new.estado_civil, new.regime_bens, new.conjuge_participa) is distinct from (old.estado_civil, old.regime_bens, old.conjuge_participa) then
      perform public.recalcular_pasta(new.id);
    end if;
  end if;
  return null;
end;
$$;

-- Leitura com IA: passa também o regime e se o cônjuge participa
create or replace function public.documentos_para_leitura(p_pasta uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  select jsonb_build_object(
    'pasta', jsonb_build_object('codigo', p.codigo, 'estado_civil', p.estado_civil, 'regime_bens', p.regime_bens,
      'conjuge_no_contrato', public.conjuge_no_contrato(p.estado_civil, p.regime_bens, p.conjuge_participa),
      'comprador', jsonb_build_object('nome', p.comprador_nome, 'cpf', p.comprador_cpf, 'nascimento', p.comprador_nascimento,
                                      'email', p.comprador_email, 'telefone', p.comprador_telefone, 'profissao', p.comprador_profissao),
      'conjuge', jsonb_build_object('nome', p.conjuge_nome, 'cpf', p.conjuge_cpf, 'nascimento', p.conjuge_nascimento,
                                    'email', p.conjuge_email, 'telefone', p.conjuge_telefone, 'profissao', p.conjuge_profissao)),
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'caminho', d.caminho, 'arquivo', d.nome_arquivo,
                                 'mime', d.mime, 'tipo', t.nome, 'pessoa', t.pessoa) order by t.ordem, d.enviado_em)
                              from public.documentos d join public.tipos_documento t on t.id = d.tipo_id
                             where d.pasta_id = p.id and d.atual and d.status <> 'recusado'), '[]'::jsonb))
    into v from public.pastas p where p.id = p_pasta;
  if v is null then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  return v;
end;
$$;

commit;

-- >>>>> 040_pessoa_juridica
-- =====================================================================
-- 040 — Comprador Pessoa Jurídica
--  * A pasta passa a ter tipo_pessoa: 'pf' (padrão) ou 'pj'.
--  * PJ: razão social e CNPJ da empresa; os campos do comprador
--    (nome, CPF, nascimento, telefone, e-mail, profissão, estado civil)
--    passam a ser do REPRESENTANTE LEGAL. Cônjuge não entra no contrato.
--  * Documentos por tipo: contrato social, cartão CNPJ e comprovante de
--    endereço da empresa para PJ; certidões de estado civil só para PF.
-- Executar uma única vez no SQL Editor do Supabase (depois da 039).
-- =====================================================================
begin;

alter table public.pastas add column if not exists tipo_pessoa text not null default 'pf' check (tipo_pessoa in ('pf', 'pj'));
alter table public.pastas add column if not exists empresa_razao_social text;
alter table public.pastas add column if not exists empresa_cnpj text check (empresa_cnpj is null or empresa_cnpj ~ '^[0-9]{14}$');
alter table public.pastas drop constraint if exists pastas_pj_completa;
alter table public.pastas add constraint pastas_pj_completa check (
  tipo_pessoa = 'pf' or (length(trim(coalesce(empresa_razao_social, ''))) > 1 and empresa_cnpj is not null));
grant insert (tipo_pessoa, empresa_razao_social, empresa_cnpj), update (tipo_pessoa, empresa_razao_social, empresa_cnpj) on public.pastas to authenticated;

-- Documentos: a quem se aplicam e se são obrigatórios para PJ
alter table public.tipos_documento add column if not exists aplica_a text not null default 'pf' check (aplica_a in ('pf', 'pj', 'ambos'));
alter table public.tipos_documento add column if not exists obrigatorio_pj boolean not null default false;
update public.tipos_documento set aplica_a = 'ambos', obrigatorio_pj = true  where nome in ('RG ou CNH', 'Comprovante de endereço', 'Comprovante do PIX');
update public.tipos_documento set aplica_a = 'ambos', obrigatorio_pj = false where nome in ('CPF (se não constar no RG/CNH)', 'Procuração');
insert into public.tipos_documento (nome, pessoa, aplica_a, obrigatorio_pj, ordem, sigla)
select v.nome, 'comprador', 'pj', v.obrig, v.ordem, v.sigla
  from (values ('Contrato social e última alteração', true, 1, 'CONTRATO_SOCIAL'),
               ('Cartão CNPJ', true, 2, 'CARTAO_CNPJ'),
               ('Comprovante de endereço da empresa', true, 3, 'ENDERECO_EMPRESA')) v(nome, obrig, ordem, sigla)
 where not exists (select 1 from public.tipos_documento t where t.nome = v.nome);

-- O cônjuge entra no contrato? (PJ: nunca)
drop function if exists public.conjuge_no_contrato(public.estado_civil, text, boolean);
create or replace function public.conjuge_no_contrato(p_ec public.estado_civil, p_regime text, p_participa boolean, p_tipo text default 'pf')
returns boolean language sql immutable as $$
  select coalesce(p_tipo, 'pf') = 'pf' and p_ec in ('casado', 'uniao_estavel')
     and (coalesce(p_regime, '') not in ('separacao_total', 'separacao_obrigatoria') or coalesce(p_participa, true));
$$;
grant execute on function public.conjuge_no_contrato(public.estado_civil, text, boolean, text) to authenticated;

create or replace function public.pastas_antes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := public.meu_email();
    new.criado_por_id := auth.uid();
  end if;

  if tg_op = 'INSERT'
     or (new.comprador_nome, new.comprador_cpf, new.comprador_nascimento, new.comprador_telefone,
         new.comprador_email, new.comprador_profissao, new.estado_civil, new.observacoes)
        is distinct from
        (old.comprador_nome, old.comprador_cpf, old.comprador_nascimento, old.comprador_telefone,
         old.comprador_email, old.comprador_profissao, old.estado_civil, old.observacoes) then
    if length(trim(coalesce(new.comprador_telefone, ''))) < 10
       or length(trim(coalesce(new.comprador_email, ''))) <= 3
       or length(trim(coalesce(new.comprador_profissao, ''))) <= 1 then
      raise exception 'DADOS_INCOMPLETOS' using hint = 'Telefone, e-mail e profissão do comprador são obrigatórios.';
    end if;
  end if;

  new.atualizada_em := now();
  if new.tipo_pessoa = 'pf' then new.empresa_razao_social := null; new.empresa_cnpj := null; end if;
  if new.estado_civil not in ('casado', 'uniao_estavel') then new.regime_bens := null; end if;
  if coalesce(new.regime_bens, '') not in ('separacao_total', 'separacao_obrigatoria') then new.conjuge_participa := true; end if;
  if not public.conjuge_no_contrato(new.estado_civil, new.regime_bens, new.conjuge_participa, new.tipo_pessoa) then
    new.conjuge_nome := null; new.conjuge_cpf := null; new.conjuge_nascimento := null;
    new.conjuge_telefone := null; new.conjuge_email := null; new.conjuge_profissao := null;
  end if;
  return new;
end;
$$;

create or replace function public.recalcular_pasta(p_pasta uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ec        public.estado_civil;
  v_tipo      text;
  v_conjuge   boolean;
  v_submetida boolean;
  v_status    text;
  v_faltando  int;
  v_recusado  int;
  v_analise   int;
  v_enviado   int;
begin
  select estado_civil, tipo_pessoa, public.conjuge_no_contrato(estado_civil, regime_bens, conjuge_participa, tipo_pessoa), codigo_aprovacao is not null
    into v_ec, v_tipo, v_conjuge, v_submetida from public.pastas where id = p_pasta;

  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo
     and case when v_tipo = 'pj' then t.aplica_a in ('pj', 'ambos') and t.obrigatorio_pj
              else t.aplica_a in ('pf', 'ambos') and v_ec = any (t.obrigatorio_para) and (t.pessoa <> 'conjuge' or v_conjuge) end
     and not exists (select 1 from public.documentos d where d.pasta_id = p_pasta and d.tipo_id = t.id and d.atual);
  select count(*) into v_recusado from public.documentos where pasta_id = p_pasta and atual and status = 'recusado';
  select count(*) into v_analise  from public.documentos where pasta_id = p_pasta and atual and status = 'em_analise';
  select count(*) into v_enviado  from public.documentos where pasta_id = p_pasta and atual and status = 'enviado';

  if not v_submetida then
    v_status := case when v_faltando > 0 then 'incompleta' else 'pronta' end;
  else
    v_status := case
      when v_recusado > 0 then 'pendente_correcao'
      when v_faltando > 0 then 'incompleta'
      when v_analise > 0 then 'em_analise'
      when v_enviado > 0 then 'aguardando_analise'
      else 'aprovada' end;
  end if;

  update public.pastas set status = v_status where id = p_pasta and status is distinct from v_status;
  return v_status;
end;
$$;

create or replace function public.submeter_pasta(p_pasta uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v_pasta.codigo_aprovacao is not null then raise exception 'JA_SUBMETIDA'; end if;
  if length(trim(coalesce(v_pasta.comprador_telefone, ''))) < 10
     or length(trim(coalesce(v_pasta.comprador_email, ''))) <= 3
     or length(trim(coalesce(v_pasta.comprador_profissao, ''))) <= 1 then
    raise exception 'DADOS_INCOMPLETOS';
  end if;
  if v_pasta.tipo_pessoa = 'pf' and v_pasta.estado_civil in ('casado', 'uniao_estavel') and v_pasta.regime_bens is null then
    raise exception 'REGIME_NAO_INFORMADO';
  end if;
  if public.conjuge_no_contrato(v_pasta.estado_civil, v_pasta.regime_bens, v_pasta.conjuge_participa, v_pasta.tipo_pessoa)
     and (length(trim(coalesce(v_pasta.conjuge_nome, ''))) <= 1
          or v_pasta.conjuge_cpf is null
          or length(trim(coalesce(v_pasta.conjuge_profissao, ''))) <= 1) then
    raise exception 'DADOS_CONJUGE_INCOMPLETOS';
  end if;
  if public.recalcular_pasta(p_pasta) <> 'pronta' then raise exception 'DOCUMENTOS_FALTANDO'; end if;

  update public.pastas
     set codigo_aprovacao = public.formatar_codigo('PA', nextval('public.pastas_aprovacao_seq')),
         submetida_em = now(), submetida_por = public.meu_email()
   where id = p_pasta
  returning * into v_pasta;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pasta submetida ao incorporador', jsonb_build_object('codigo', v_pasta.codigo_aprovacao), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$$;

create or replace function public.pastas_depois() returns trigger
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
       and n.key not in ('status', 'atualizada_em', 'unidade_id', 'codigo_aprovacao', 'submetida_em', 'submetida_por',
                         'etapa_venda', 'etapa_atualizada_em', 'unidades_numeros');
    if v_campos is not null then
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (new.id, 'Dados alterados', jsonb_build_object('campos', v_campos), public.meu_email());
    end if;
    if (new.estado_civil, new.regime_bens, new.conjuge_participa, new.tipo_pessoa)
       is distinct from (old.estado_civil, old.regime_bens, old.conjuge_participa, old.tipo_pessoa) then
      perform public.recalcular_pasta(new.id);
    end if;
  end if;
  return null;
end;
$$;

-- Leitura com IA: inclui empresa (PJ)
create or replace function public.documentos_para_leitura(p_pasta uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  select jsonb_build_object(
    'pasta', jsonb_build_object('codigo', p.codigo, 'tipo_pessoa', p.tipo_pessoa, 'estado_civil', p.estado_civil, 'regime_bens', p.regime_bens,
      'conjuge_no_contrato', public.conjuge_no_contrato(p.estado_civil, p.regime_bens, p.conjuge_participa, p.tipo_pessoa),
      'empresa', case when p.tipo_pessoa = 'pj' then jsonb_build_object('razao_social', p.empresa_razao_social, 'cnpj', p.empresa_cnpj) end,
      'comprador', jsonb_build_object('nome', p.comprador_nome, 'cpf', p.comprador_cpf, 'nascimento', p.comprador_nascimento,
                                      'email', p.comprador_email, 'telefone', p.comprador_telefone, 'profissao', p.comprador_profissao),
      'conjuge', jsonb_build_object('nome', p.conjuge_nome, 'cpf', p.conjuge_cpf, 'nascimento', p.conjuge_nascimento,
                                    'email', p.conjuge_email, 'telefone', p.conjuge_telefone, 'profissao', p.conjuge_profissao)),
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'caminho', d.caminho, 'arquivo', d.nome_arquivo,
                                 'mime', d.mime, 'tipo', t.nome, 'pessoa', t.pessoa) order by t.ordem, d.enviado_em)
                              from public.documentos d join public.tipos_documento t on t.id = d.tipo_id
                             where d.pasta_id = p.id and d.atual and d.status <> 'recusado'), '[]'::jsonb))
    into v from public.pastas p where p.id = p_pasta;
  if v is null then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  return v;
end;
$$;

commit;

-- >>>>> 041_contratos
-- =====================================================================
-- 041 — Módulo de contratos
--  * empreendimento_contrato: dados da vendedora e do empreendimento usados
--    no Quadro Resumo (uma linha; edita só o administrador).
--  * unidade_areas: quadro de áreas por unidade (importado da planilha no
--    cadastro do empreendimento; substitui o quadro inteiro).
--  * dados_contrato ganha comissão (beneficiários) e conferência do fluxo
--    de pagamento.
--  * contratos: cada PDF emitido (Quadro Resumo, Normas), com número,
--    validação, assinatura (D4Sign na próxima fase) e cancelamento.
--  * Tudo restrito à equipe (administrador e Sec. Vendas).
-- Executar uma única vez no SQL Editor do Supabase (depois da 040).
-- =====================================================================
begin;

-- Dados da vendedora / empreendimento --------------------------------
create table if not exists public.empreendimento_contrato (
  id             smallint primary key default 1 check (id = 1),
  dados          jsonb not null default '{}'::jsonb,
  atualizado_em  timestamptz not null default now(),
  atualizado_por text
);
alter table public.empreendimento_contrato enable row level security;
drop policy if exists empreendimento_contrato_equipe on public.empreendimento_contrato;
create policy empreendimento_contrato_equipe on public.empreendimento_contrato for select using (public.eh_equipe());
revoke all on public.empreendimento_contrato from anon, authenticated;
grant select on public.empreendimento_contrato to authenticated;

create or replace function public.salvar_empreendimento_contrato(p_dados jsonb) returns public.empreendimento_contrato
language plpgsql security definer set search_path = public as $$
declare v public.empreendimento_contrato;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.empreendimento_contrato (id, dados, atualizado_em, atualizado_por)
  values (1, coalesce(p_dados, '{}'), now(), public.meu_email())
  on conflict (id) do update set dados = excluded.dados, atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  return v;
end;
$$;

-- Quadro de áreas -------------------------------------------------------
create table if not exists public.unidade_areas (
  numero               text primary key,
  torre                text,
  pavimento            text,
  area_privativa       numeric(12,4),
  area_acessoria       numeric(12,4),
  area_privativa_total numeric(12,4),
  area_comum           numeric(12,4),
  area_total           numeric(12,4),
  fracao_ideal         numeric(14,10),
  vagas                text,
  escaninho            text,
  escaninho_local      text,
  escaninho_area       numeric(10,4),
  atualizado_em        timestamptz not null default now()
);
alter table public.unidade_areas enable row level security;
drop policy if exists unidade_areas_equipe on public.unidade_areas;
create policy unidade_areas_equipe on public.unidade_areas for select using (public.eh_equipe());
revoke all on public.unidade_areas from anon, authenticated;
grant select on public.unidade_areas to authenticated;

-- Substitui o quadro inteiro. p_linhas = [{numero, torre, pavimento, area_privativa, ...}]
create or replace function public.importar_quadro_areas(p_linhas jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then raise exception 'PLANILHA_VAZIA'; end if;
  if exists (select 1 from jsonb_array_elements(p_linhas) l where coalesce(trim(l ->> 'numero'), '') = '') then raise exception 'UNIDADE_SEM_NUMERO'; end if;
  if (select count(distinct trim(l ->> 'numero')) from jsonb_array_elements(p_linhas) l) <> jsonb_array_length(p_linhas) then raise exception 'UNIDADE_REPETIDA'; end if;
  delete from public.unidade_areas where true;
  insert into public.unidade_areas (numero, torre, pavimento, area_privativa, area_acessoria, area_privativa_total, area_comum,
                                    area_total, fracao_ideal, vagas, escaninho, escaninho_local, escaninho_area)
  select trim(l ->> 'numero'), nullif(trim(l ->> 'torre'), ''), nullif(trim(l ->> 'pavimento'), ''),
         (l ->> 'area_privativa')::numeric, (l ->> 'area_acessoria')::numeric, (l ->> 'area_privativa_total')::numeric,
         (l ->> 'area_comum')::numeric, (l ->> 'area_total')::numeric, (l ->> 'fracao_ideal')::numeric,
         nullif(trim(l ->> 'vagas'), ''), nullif(trim(l ->> 'escaninho'), ''), nullif(trim(l ->> 'escaninho_local'), ''),
         (l ->> 'escaninho_area')::numeric
    from jsonb_array_elements(p_linhas) l;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Comissão e conferência do pagamento ---------------------------------
alter table public.dados_contrato add column if not exists comissao jsonb not null default '[]'::jsonb;
alter table public.dados_contrato add column if not exists pagamento_conferido_em timestamptz;
alter table public.dados_contrato add column if not exists pagamento_conferido_por text;

create or replace function public.conferir_pagamento(p_pasta uuid, p_comissao jsonb, p_conferido boolean)
returns public.dados_contrato language plpgsql security definer set search_path = public as $$
declare v public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  insert into public.dados_contrato as d (pasta_id, comissao, pagamento_conferido_em, pagamento_conferido_por, atualizado_em, atualizado_por)
  values (p_pasta, coalesce(p_comissao, '[]'), case when p_conferido then now() end, case when p_conferido then public.meu_email() end, now(), public.meu_email())
  on conflict (pasta_id) do update set comissao = excluded.comissao,
     pagamento_conferido_em = excluded.pagamento_conferido_em, pagamento_conferido_por = excluded.pagamento_conferido_por,
     atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  if p_conferido then
    insert into public.historico_pastas (pasta_id, acao, usuario_email) values (p_pasta, 'Fluxo de pagamento conferido para o contrato', public.meu_email());
  end if;
  return v;
end;
$$;

-- Contratos emitidos ------------------------------------------------------
create table if not exists public.contratos (
  id             uuid primary key default gen_random_uuid(),
  numero         bigint generated always as identity (start with 1001) unique,
  pasta_id       uuid not null references public.pastas(id) on delete cascade,
  proposta_id    uuid references public.propostas(id) on delete set null,
  documento      text not null check (documento in ('quadro_resumo', 'normas')),
  nome           text not null,
  caminho        text not null,
  dados          jsonb,
  validacao      text not null default 'aguardando' check (validacao in ('aguardando', 'validado')),
  assinatura     text not null default 'nao_enviado' check (assinatura in ('nao_enviado', 'enviado', 'assinado', 'recusado')),
  gerado_em      timestamptz not null default now(),
  gerado_por     text,
  validado_em    timestamptz,
  validado_por   text,
  cancelado_em   timestamptz,
  cancelado_por  text
);
create index if not exists contratos_pasta_idx on public.contratos (pasta_id);
alter table public.contratos enable row level security;
drop policy if exists contratos_equipe on public.contratos;
create policy contratos_equipe on public.contratos for select using (public.eh_equipe());
revoke all on public.contratos from anon, authenticated;
grant select on public.contratos to authenticated;

create or replace function public.registrar_contrato(p_pasta uuid, p_proposta uuid, p_documento text, p_nome text, p_caminho text, p_dados jsonb)
returns public.contratos language plpgsql security definer set search_path = public as $$
declare v public.contratos; d public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not exists (select 1 from public.propostas where id = p_proposta and pasta_id = p_pasta and status = 'aprovada') then
    raise exception 'PROPOSTA_NAO_APROVADA';
  end if;
  select * into d from public.dados_contrato where pasta_id = p_pasta;
  if d.status is distinct from 'conferido' then raise exception 'DADOS_NAO_CONFERIDOS'; end if;
  if d.pagamento_conferido_em is null then raise exception 'PAGAMENTO_NAO_CONFERIDO'; end if;
  if p_caminho !~ ('^' || p_pasta::text || '/') then raise exception 'CAMINHO_INVALIDO'; end if;
  insert into public.contratos (pasta_id, proposta_id, documento, nome, caminho, dados, gerado_por)
  values (p_pasta, p_proposta, p_documento, left(p_nome, 200), p_caminho, p_dados, public.meu_email())
  returning * into v;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Contrato emitido', jsonb_build_object('numero', v.numero, 'documento', v.nome), public.meu_email());
  return v;
end;
$$;

create or replace function public.validar_contrato(p_id uuid) returns public.contratos
language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contratos set validacao = 'validado', validado_em = now(), validado_por = public.meu_email()
   where id = p_id and cancelado_em is null returning * into v;
  if v.id is null then raise exception 'CONTRATO_NAO_ENCONTRADO'; end if;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato validado', jsonb_build_object('numero', v.numero), public.meu_email());
  return v;
end;
$$;

create or replace function public.cancelar_contrato(p_id uuid) returns public.contratos
language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contratos set cancelado_em = now(), cancelado_por = public.meu_email()
   where id = p_id and cancelado_em is null and assinatura <> 'assinado' returning * into v;
  if v.id is null then raise exception 'NAO_PODE_CANCELAR'; end if;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato cancelado', jsonb_build_object('numero', v.numero), public.meu_email());
  return v;
end;
$$;

-- Arquivos: bucket privado, só a equipe lê e grava ("<pasta>/<arquivo>.pdf")
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('contratos', 'contratos', false, 26214400, array['application/pdf'])
on conflict (id) do update set public = false;
drop policy if exists contratos_leitura on storage.objects;
drop policy if exists contratos_envio on storage.objects;
create policy contratos_leitura on storage.objects for select to authenticated using (bucket_id = 'contratos' and public.eh_equipe());
create policy contratos_envio on storage.objects for insert to authenticated with check (bucket_id = 'contratos' and public.eh_equipe());

revoke all on function public.salvar_empreendimento_contrato(jsonb), public.importar_quadro_areas(jsonb),
  public.conferir_pagamento(uuid, jsonb, boolean), public.registrar_contrato(uuid, uuid, text, text, text, jsonb),
  public.validar_contrato(uuid), public.cancelar_contrato(uuid) from public, anon;
grant execute on function public.salvar_empreendimento_contrato(jsonb), public.importar_quadro_areas(jsonb),
  public.conferir_pagamento(uuid, jsonb, boolean), public.registrar_contrato(uuid, uuid, text, text, text, jsonb),
  public.validar_contrato(uuid), public.cancelar_contrato(uuid) to authenticated;

commit;

-- >>>>> 042_contratos_versoes
-- =====================================================================
-- 042 — Contratos: Word editável e versões ajustadas
--  * Cada documento emitido guarda o PDF e o Word (.docx) gerados.
--  * A equipe baixa o Word, ajusta e envia de volta (.docx e/ou .pdf):
--    vira uma nova versão, a validação volta para "aguardando" e é essa
--    versão que segue para a D4Sign (que converte o Word em PDF).
--  * Só dá para ajustar enquanto o documento não foi enviado para assinatura.
-- Executar uma única vez no SQL Editor do Supabase (depois da 041).
-- =====================================================================
begin;

alter table public.contratos alter column caminho drop not null;
alter table public.contratos add column if not exists caminho_docx text;
alter table public.contratos add column if not exists versao int not null default 1;

create table if not exists public.contrato_versoes (
  id           bigint generated always as identity primary key,
  contrato_id  uuid not null references public.contratos(id) on delete cascade,
  versao       int not null,
  caminho_pdf  text,
  caminho_docx text,
  origem       text not null check (origem in ('sistema', 'ajuste')),
  criado_em    timestamptz not null default now(),
  criado_por   text,
  unique (contrato_id, versao)
);
alter table public.contrato_versoes enable row level security;
drop policy if exists contrato_versoes_equipe on public.contrato_versoes;
create policy contrato_versoes_equipe on public.contrato_versoes for select using (public.eh_equipe());
revoke all on public.contrato_versoes from anon, authenticated;
grant select on public.contrato_versoes to authenticated;

update storage.buckets set allowed_mime_types = array['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document']
 where id = 'contratos';

drop function if exists public.registrar_contrato(uuid, uuid, text, text, text, jsonb);
create or replace function public.registrar_contrato(p_pasta uuid, p_proposta uuid, p_documento text, p_nome text, p_caminho text, p_dados jsonb, p_caminho_docx text default null)
returns public.contratos language plpgsql security definer set search_path = public as $$
declare v public.contratos; d public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not exists (select 1 from public.propostas where id = p_proposta and pasta_id = p_pasta and status = 'aprovada') then
    raise exception 'PROPOSTA_NAO_APROVADA';
  end if;
  select * into d from public.dados_contrato where pasta_id = p_pasta;
  if d.status is distinct from 'conferido' then raise exception 'DADOS_NAO_CONFERIDOS'; end if;
  if d.pagamento_conferido_em is null then raise exception 'PAGAMENTO_NAO_CONFERIDO'; end if;
  if p_caminho !~ ('^' || p_pasta::text || '/') or (p_caminho_docx is not null and p_caminho_docx !~ ('^' || p_pasta::text || '/')) then
    raise exception 'CAMINHO_INVALIDO';
  end if;
  insert into public.contratos (pasta_id, proposta_id, documento, nome, caminho, caminho_docx, dados, gerado_por)
  values (p_pasta, p_proposta, p_documento, left(p_nome, 200), p_caminho, p_caminho_docx, p_dados, public.meu_email())
  returning * into v;
  insert into public.contrato_versoes (contrato_id, versao, caminho_pdf, caminho_docx, origem, criado_por)
  values (v.id, 1, p_caminho, p_caminho_docx, 'sistema', public.meu_email());
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Contrato emitido', jsonb_build_object('numero', v.numero, 'documento', v.nome), public.meu_email());
  return v;
end;
$$;

-- Nova versão ajustada (Word e/ou PDF). Volta a validação para "aguardando".
create or replace function public.enviar_versao_contrato(p_id uuid, p_caminho_docx text, p_caminho_pdf text)
returns public.contratos language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_caminho_docx is null and p_caminho_pdf is null then raise exception 'ARQUIVO_OBRIGATORIO'; end if;
  select * into v from public.contratos where id = p_id for update;
  if v.id is null or v.cancelado_em is not null then raise exception 'CONTRATO_NAO_ENCONTRADO'; end if;
  if v.assinatura <> 'nao_enviado' then raise exception 'JA_ENVIADO_PARA_ASSINATURA'; end if;
  if (p_caminho_docx is not null and p_caminho_docx !~ ('^' || v.pasta_id::text || '/'))
     or (p_caminho_pdf is not null and p_caminho_pdf !~ ('^' || v.pasta_id::text || '/')) then
    raise exception 'CAMINHO_INVALIDO';
  end if;
  update public.contratos
     set versao = versao + 1, caminho_docx = p_caminho_docx, caminho = p_caminho_pdf,
         validacao = 'aguardando', validado_em = null, validado_por = null
   where id = p_id returning * into v;
  insert into public.contrato_versoes (contrato_id, versao, caminho_pdf, caminho_docx, origem, criado_por)
  values (v.id, v.versao, p_caminho_pdf, p_caminho_docx, 'ajuste', public.meu_email());
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato ajustado', jsonb_build_object('numero', v.numero, 'versao', v.versao), public.meu_email());
  return v;
end;
$$;

revoke all on function public.registrar_contrato(uuid, uuid, text, text, text, jsonb, text), public.enviar_versao_contrato(uuid, text, text) from public, anon;
grant execute on function public.registrar_contrato(uuid, uuid, text, text, text, jsonb, text), public.enviar_versao_contrato(uuid, text, text) to authenticated;

commit;

-- >>>>> 043_modelos_contrato
-- =====================================================================
-- 043 — Modelos de contrato em Word (com marcadores)
--  * O administrador envia o Word do jurídico com marcadores ({comprador.nome}…)
--    para cada documento (Quadro Resumo, Normas Contratuais).
--  * Só um modelo ativo por documento; os anteriores ficam no histórico.
--  * Sem modelo enviado, o sistema usa o modelo padrão.
-- Executar uma única vez no SQL Editor do Supabase (depois da 042).
-- =====================================================================
begin;

create table if not exists public.modelos_contrato (
  id          uuid primary key default gen_random_uuid(),
  documento   text not null check (documento in ('quadro_resumo', 'normas')),
  nome        text not null,
  caminho     text not null check (caminho ~ '^modelos/'),
  ativo       boolean not null default true,
  enviado_em  timestamptz not null default now(),
  enviado_por text
);
create unique index if not exists modelos_contrato_um_ativo on public.modelos_contrato (documento) where ativo;
alter table public.modelos_contrato enable row level security;
drop policy if exists modelos_contrato_equipe on public.modelos_contrato;
create policy modelos_contrato_equipe on public.modelos_contrato for select using (public.eh_equipe());
revoke all on public.modelos_contrato from anon, authenticated;
grant select on public.modelos_contrato to authenticated;

-- Ativa um modelo novo (o anterior do mesmo documento sai de uso)
create or replace function public.salvar_modelo_contrato(p_documento text, p_nome text, p_caminho text)
returns public.modelos_contrato language plpgsql security definer set search_path = public as $$
declare v public.modelos_contrato;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.modelos_contrato set ativo = false where documento = p_documento and ativo;
  insert into public.modelos_contrato (documento, nome, caminho, enviado_por)
  values (p_documento, left(p_nome, 200), p_caminho, public.meu_email()) returning * into v;
  return v;
end;
$$;

-- Volta para o modelo padrão do sistema
create or replace function public.usar_modelo_padrao(p_documento text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.modelos_contrato set ativo = false where documento = p_documento and ativo;
end;
$$;

revoke all on function public.salvar_modelo_contrato(text, text, text), public.usar_modelo_padrao(text) from public, anon;
grant execute on function public.salvar_modelo_contrato(text, text, text), public.usar_modelo_padrao(text) to authenticated;

commit;

-- >>>>> 044_d4sign
-- =====================================================================
-- 044 — Assinatura eletrônica (D4Sign)
--  * contratos: identificador na D4Sign, datas de envio/assinatura e PDF assinado.
--  * Novas situações: 'preparado' (na D4Sign, aguardando conferência da prévia)
--    e 'cancelado' (cancelado na D4Sign).
--  * contrato_assinantes: quem assina, em que ordem, por e-mail ou WhatsApp, e se já assinou.
--  * Quem grava é o servidor (com a chave secreta), depois de conferir o login da equipe.
-- Executar uma única vez no SQL Editor do Supabase (depois da 043).
-- =====================================================================
begin;

alter table public.contratos add column if not exists d4sign_uuid text unique;
alter table public.contratos add column if not exists enviado_assinatura_em timestamptz;
alter table public.contratos add column if not exists assinado_em timestamptz;
alter table public.contratos add column if not exists caminho_assinado text;
alter table public.contratos drop constraint if exists contratos_assinatura_check;
alter table public.contratos add constraint contratos_assinatura_check
  check (assinatura in ('nao_enviado', 'preparado', 'enviado', 'assinado', 'recusado', 'cancelado'));

create table if not exists public.contrato_assinantes (
  id           bigint generated always as identity primary key,
  contrato_id  uuid not null references public.contratos(id) on delete cascade,
  ordem        int not null default 1,
  papel        text not null,
  nome         text,
  email        text not null,
  whatsapp     text,
  canal        text not null default 'email' check (canal in ('email', 'whatsapp')),
  key_signer   text,
  assinado     boolean not null default false,
  assinado_em  timestamptz,
  atualizado_em timestamptz not null default now()
);
create index if not exists contrato_assinantes_contrato_idx on public.contrato_assinantes (contrato_id);
alter table public.contrato_assinantes enable row level security;
drop policy if exists contrato_assinantes_equipe on public.contrato_assinantes;
create policy contrato_assinantes_equipe on public.contrato_assinantes for select using (public.eh_equipe());
revoke all on public.contrato_assinantes from anon, authenticated;
grant select on public.contrato_assinantes to authenticated;

-- Cancelar pelo sistema só antes de ir para a D4Sign (depois, cancela pela integração)
create or replace function public.cancelar_contrato(p_id uuid) returns public.contratos
language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contratos set cancelado_em = now(), cancelado_por = public.meu_email()
   where id = p_id and cancelado_em is null and assinatura = 'nao_enviado' returning * into v;
  if v.id is null then raise exception 'NAO_PODE_CANCELAR'; end if;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato cancelado', jsonb_build_object('numero', v.numero), public.meu_email());
  return v;
end;
$$;

commit;

-- >>>>> 045_pix_sinal
-- =====================================================================
-- 045 — Pix do sinal na pasta: comprovante anexado OU Pix gerado pelo sistema
--  * config.pix_modo: 'comprovante' (padrão, como hoje: anexa o comprovante)
--    ou 'integrado' (o sistema gera um Pix de valor fixo e dá baixa sozinho).
--  * config.pix_valor / pix_validade_horas / pix_provedor ('simulado' para testes;
--    'itau', 'infinitepay', 'mercadopago' quando a integração for ligada).
--  * No modo integrado, o "Comprovante do PIX" deixa de ser exigido e a pasta só
--    fica pronta com um Pix pago.
-- Executar uma única vez no SQL Editor do Supabase (depois da 044).
-- =====================================================================
begin;

alter table public.config add column if not exists pix_modo text not null default 'comprovante' check (pix_modo in ('comprovante', 'integrado'));
alter table public.config add column if not exists pix_valor numeric(12,2) not null default 2000 check (pix_valor > 0);
alter table public.config add column if not exists pix_validade_horas int not null default 48 check (pix_validade_horas between 1 and 720);
alter table public.config add column if not exists pix_provedor text not null default 'simulado' check (pix_provedor in ('simulado', 'itau', 'infinitepay', 'mercadopago'));
grant update (pix_modo, pix_valor, pix_validade_horas, pix_provedor) on public.config to authenticated;

alter table public.tipos_documento add column if not exists eh_pix boolean not null default false;
update public.tipos_documento set eh_pix = true where nome = 'Comprovante do PIX';

create table if not exists public.cobrancas_pix (
  id                uuid primary key default gen_random_uuid(),
  pasta_id          uuid not null references public.pastas(id) on delete cascade,
  valor             numeric(12,2) not null,
  provedor          text not null,
  txid              text not null unique,
  copia_cola        text not null,
  status            text not null default 'pendente' check (status in ('pendente', 'pago', 'cancelado')),
  expira_em         timestamptz not null,
  pago_em           timestamptz,
  pagador_nome      text,
  pagador_documento text,
  e2e_id            text,
  criado_em         timestamptz not null default now(),
  criado_por        text
);
create index if not exists cobrancas_pix_pasta_idx on public.cobrancas_pix (pasta_id);
alter table public.cobrancas_pix enable row level security;
drop policy if exists cobrancas_pix_leitura on public.cobrancas_pix;
create policy cobrancas_pix_leitura on public.cobrancas_pix for select using (public.pode_ver_pasta(pasta_id));
revoke all on public.cobrancas_pix from anon, authenticated;
grant select on public.cobrancas_pix to authenticated;

-- Pix pago nesta pasta?
create or replace function public.pix_pago(p_pasta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.cobrancas_pix where pasta_id = p_pasta and status = 'pago');
$$;

-- Gera (ou devolve o que ainda vale) o Pix do sinal. Provedores reais entram pelo servidor.
create or replace function public.gerar_cobranca_pix(p_pasta uuid) returns public.cobrancas_pix
language plpgsql security definer set search_path = public as $$
declare v public.cobrancas_pix; c public.config; t text;
begin
  if not public.pode_ver_pasta(p_pasta) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into c from public.config where id = 1;
  if c.pix_modo <> 'integrado' then raise exception 'PIX_NAO_INTEGRADO'; end if;
  if public.pix_pago(p_pasta) then raise exception 'PIX_JA_PAGO'; end if;
  select * into v from public.cobrancas_pix where pasta_id = p_pasta and status = 'pendente' and expira_em > now() order by criado_em desc limit 1;
  if v.id is not null then return v; end if;
  if c.pix_provedor <> 'simulado' then raise exception 'PROVEDOR_NAO_CONFIGURADO'; end if;
  t := 'SIM' || upper(replace(gen_random_uuid()::text, '-', ''));
  insert into public.cobrancas_pix (pasta_id, valor, provedor, txid, copia_cola, expira_em, criado_por)
  values (p_pasta, c.pix_valor, 'simulado', left(t, 35),
          'PIX DE TESTE - NAO PAGAR - ' || left(t, 35) || ' - R$ ' || to_char(c.pix_valor, 'FM999G999D00'),
          now() + make_interval(hours => c.pix_validade_horas), public.meu_email())
  returning * into v;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pix do sinal gerado', jsonb_build_object('valor', v.valor, 'expira_em', v.expira_em), public.meu_email());
  return v;
end;
$$;

-- Só para testes (provedor simulado): a equipe marca como pago.
create or replace function public.simular_pagamento_pix(p_cobranca uuid) returns public.cobrancas_pix
language plpgsql security definer set search_path = public as $$
declare v public.cobrancas_pix; p public.pastas;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into v from public.cobrancas_pix where id = p_cobranca for update;
  if v.id is null or v.provedor <> 'simulado' then raise exception 'SO_EM_TESTE'; end if;
  if v.status <> 'pendente' then raise exception 'PIX_NAO_PENDENTE'; end if;
  select * into p from public.pastas where id = v.pasta_id;
  update public.cobrancas_pix
     set status = 'pago', pago_em = now(), pagador_nome = p.comprador_nome,
         pagador_documento = coalesce(p.empresa_cnpj, p.comprador_cpf), e2e_id = 'E' || upper(left(replace(gen_random_uuid()::text, '-', ''), 31))
   where id = p_cobranca returning * into v;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Pix do sinal pago', jsonb_build_object('valor', v.valor, 'simulado', true), public.meu_email());
  perform public.recalcular_pasta(v.pasta_id);
  return v;
end;
$$;

create or replace function public.recalcular_pasta(p_pasta uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ec        public.estado_civil;
  v_tipo      text;
  v_conjuge   boolean;
  v_submetida boolean;
  v_integrado boolean := coalesce((select pix_modo = 'integrado' from public.config where id = 1), false);
  v_status    text;
  v_faltando  int;
  v_recusado  int;
  v_analise   int;
  v_enviado   int;
begin
  select estado_civil, tipo_pessoa, public.conjuge_no_contrato(estado_civil, regime_bens, conjuge_participa, tipo_pessoa), codigo_aprovacao is not null
    into v_ec, v_tipo, v_conjuge, v_submetida from public.pastas where id = p_pasta;

  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo
     and not (v_integrado and t.eh_pix)
     and case when v_tipo = 'pj' then t.aplica_a in ('pj', 'ambos') and t.obrigatorio_pj
              else t.aplica_a in ('pf', 'ambos') and v_ec = any (t.obrigatorio_para) and (t.pessoa <> 'conjuge' or v_conjuge) end
     and not exists (select 1 from public.documentos d where d.pasta_id = p_pasta and d.tipo_id = t.id and d.atual);
  if v_integrado and not public.pix_pago(p_pasta) then v_faltando := v_faltando + 1; end if;
  select count(*) into v_recusado from public.documentos where pasta_id = p_pasta and atual and status = 'recusado';
  select count(*) into v_analise  from public.documentos where pasta_id = p_pasta and atual and status = 'em_analise';
  select count(*) into v_enviado  from public.documentos where pasta_id = p_pasta and atual and status = 'enviado';

  if not v_submetida then
    v_status := case when v_faltando > 0 then 'incompleta' else 'pronta' end;
  else
    v_status := case
      when v_recusado > 0 then 'pendente_correcao'
      when v_faltando > 0 then 'incompleta'
      when v_analise > 0 then 'em_analise'
      when v_enviado > 0 then 'aguardando_analise'
      else 'aprovada' end;
  end if;

  update public.pastas set status = v_status where id = p_pasta and status is distinct from v_status;
  return v_status;
end;
$$;

create or replace function public.submeter_pasta(p_pasta uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v_pasta.codigo_aprovacao is not null then raise exception 'JA_SUBMETIDA'; end if;
  if length(trim(coalesce(v_pasta.comprador_telefone, ''))) < 10
     or length(trim(coalesce(v_pasta.comprador_email, ''))) <= 3
     or length(trim(coalesce(v_pasta.comprador_profissao, ''))) <= 1 then
    raise exception 'DADOS_INCOMPLETOS';
  end if;
  if v_pasta.tipo_pessoa = 'pf' and v_pasta.estado_civil in ('casado', 'uniao_estavel') and v_pasta.regime_bens is null then
    raise exception 'REGIME_NAO_INFORMADO';
  end if;
  if public.conjuge_no_contrato(v_pasta.estado_civil, v_pasta.regime_bens, v_pasta.conjuge_participa, v_pasta.tipo_pessoa)
     and (length(trim(coalesce(v_pasta.conjuge_nome, ''))) <= 1
          or v_pasta.conjuge_cpf is null
          or length(trim(coalesce(v_pasta.conjuge_profissao, ''))) <= 1) then
    raise exception 'DADOS_CONJUGE_INCOMPLETOS';
  end if;
  if coalesce((select pix_modo = 'integrado' from public.config where id = 1), false) and not public.pix_pago(p_pasta) then
    raise exception 'PIX_PENDENTE';
  end if;
  if public.recalcular_pasta(p_pasta) <> 'pronta' then raise exception 'DOCUMENTOS_FALTANDO'; end if;

  update public.pastas
     set codigo_aprovacao = public.formatar_codigo('PA', nextval('public.pastas_aprovacao_seq')),
         submetida_em = now(), submetida_por = public.meu_email()
   where id = p_pasta
  returning * into v_pasta;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pasta submetida ao incorporador', jsonb_build_object('codigo', v_pasta.codigo_aprovacao), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$$;

-- Ao trocar o modo do Pix, recalcula as pastas ainda não submetidas
create or replace function public.config_pix_mudou() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.pix_modo is distinct from old.pix_modo then
    for r in select id from public.pastas where codigo_aprovacao is null loop perform public.recalcular_pasta(r.id); end loop;
  end if;
  return null;
end;
$$;
drop trigger if exists config_pix_mudou on public.config;
create trigger config_pix_mudou after update of pix_modo on public.config for each row execute function public.config_pix_mudou();

revoke all on function public.pix_pago(uuid), public.gerar_cobranca_pix(uuid), public.simular_pagamento_pix(uuid) from public, anon;
grant execute on function public.pix_pago(uuid), public.gerar_cobranca_pix(uuid), public.simular_pagamento_pix(uuid) to authenticated;

commit;

-- >>>>> 046_envelope_assinatura
-- =====================================================================
-- 046 — Envelope único de assinatura por pasta
--  * Boas práticas: um envelope por venda. O Quadro Resumo é o documento
--    principal; Normas, Carta Proposta e os documentos fixos do empreendimento
--    (memorial, plantas, convenção…) vão como anexos do mesmo envelope.
--  * contrato_anexos_fixos: documentos fixos cadastrados pelo administrador.
--  * envelopes: o que foi enviado (versões congeladas), situação e pacote assinado.
--  * envelope_assinantes: quem assina, ordem, canal, se já assinou.
--  * Enquanto há envelope ativo, os documentos ficam travados (sem ajuste).
--  * Substitui a assinatura por documento da 044 (contrato_assinantes sai).
-- Executar uma única vez no SQL Editor do Supabase (depois da 045).
-- =====================================================================
begin;

-- Carta proposta também é emitida no módulo
alter table public.contratos drop constraint if exists contratos_documento_check;
alter table public.contratos add constraint contratos_documento_check check (documento in ('quadro_resumo', 'normas', 'carta_proposta'));

-- Documentos fixos do empreendimento
create table if not exists public.contrato_anexos_fixos (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  caminho     text not null check (caminho ~ '^fixos/'),
  arquivo     text,
  ordem       int not null default 100,
  ativo       boolean not null default true,
  enviado_em  timestamptz not null default now(),
  enviado_por text
);
alter table public.contrato_anexos_fixos enable row level security;
drop policy if exists contrato_anexos_fixos_equipe on public.contrato_anexos_fixos;
create policy contrato_anexos_fixos_equipe on public.contrato_anexos_fixos for select using (public.eh_equipe());
revoke all on public.contrato_anexos_fixos from anon, authenticated;
grant select on public.contrato_anexos_fixos to authenticated;

create or replace function public.salvar_anexo_fixo(p_nome text, p_caminho text, p_arquivo text, p_ordem int)
returns public.contrato_anexos_fixos language plpgsql security definer set search_path = public as $$
declare v public.contrato_anexos_fixos;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.contrato_anexos_fixos (nome, caminho, arquivo, ordem, enviado_por)
  values (left(trim(p_nome), 150), p_caminho, left(p_arquivo, 200), coalesce(p_ordem, 100), public.meu_email()) returning * into v;
  return v;
end;
$$;
create or replace function public.alterar_anexo_fixo(p_id uuid, p_nome text, p_ordem int, p_ativo boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contrato_anexos_fixos set nome = coalesce(left(trim(p_nome), 150), nome), ordem = coalesce(p_ordem, ordem), ativo = coalesce(p_ativo, ativo) where id = p_id;
end;
$$;

-- Envelopes
create table if not exists public.envelopes (
  id               uuid primary key default gen_random_uuid(),
  pasta_id         uuid not null references public.pastas(id) on delete cascade,
  proposta_id      uuid references public.propostas(id) on delete set null,
  d4sign_uuid      text unique,
  status           text not null default 'preparado' check (status in ('preparado', 'enviado', 'assinado', 'cancelado')),
  documentos       jsonb not null default '[]'::jsonb,   -- [{tipo, id, nome, versao, arquivo, d4sign_uuid}]
  criado_em        timestamptz not null default now(),
  criado_por       text,
  enviado_em       timestamptz,
  assinado_em      timestamptz,
  caminho_assinado text,
  cancelado_em     timestamptz,
  cancelado_por    text
);
create unique index if not exists envelopes_um_ativo on public.envelopes (pasta_id) where status in ('preparado', 'enviado');
alter table public.envelopes enable row level security;
drop policy if exists envelopes_equipe on public.envelopes;
create policy envelopes_equipe on public.envelopes for select using (public.eh_equipe());
revoke all on public.envelopes from anon, authenticated;
grant select on public.envelopes to authenticated;

create table if not exists public.envelope_assinantes (
  id            bigint generated always as identity primary key,
  envelope_id   uuid not null references public.envelopes(id) on delete cascade,
  ordem         int not null default 1,
  papel         text not null,
  nome          text,
  email         text not null,
  whatsapp      text,
  canal         text not null default 'email' check (canal in ('email', 'whatsapp')),
  key_signer    text,
  assinado      boolean not null default false,
  assinado_em   timestamptz,
  atualizado_em timestamptz not null default now()
);
create index if not exists envelope_assinantes_env_idx on public.envelope_assinantes (envelope_id);
alter table public.envelope_assinantes enable row level security;
drop policy if exists envelope_assinantes_equipe on public.envelope_assinantes;
create policy envelope_assinantes_equipe on public.envelope_assinantes for select using (public.eh_equipe());
revoke all on public.envelope_assinantes from anon, authenticated;
grant select on public.envelope_assinantes to authenticated;

-- A assinatura passa a ser por envelope
drop table if exists public.contrato_assinantes;

-- Ajuste de versão bloqueado enquanto o documento estiver num envelope ativo
create or replace function public.em_envelope_ativo(p_contrato uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.envelopes e, jsonb_array_elements(e.documentos) d
                  where e.status in ('preparado', 'enviado') and d ->> 'tipo' = 'contrato' and d ->> 'id' = p_contrato::text);
$$;

create or replace function public.enviar_versao_contrato(p_id uuid, p_caminho_docx text, p_caminho_pdf text)
returns public.contratos language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_caminho_docx is null and p_caminho_pdf is null then raise exception 'ARQUIVO_OBRIGATORIO'; end if;
  select * into v from public.contratos where id = p_id for update;
  if v.id is null or v.cancelado_em is not null then raise exception 'CONTRATO_NAO_ENCONTRADO'; end if;
  if public.em_envelope_ativo(p_id) or v.assinatura = 'assinado' then raise exception 'JA_ENVIADO_PARA_ASSINATURA'; end if;
  if (p_caminho_docx is not null and p_caminho_docx !~ ('^' || v.pasta_id::text || '/'))
     or (p_caminho_pdf is not null and p_caminho_pdf !~ ('^' || v.pasta_id::text || '/')) then
    raise exception 'CAMINHO_INVALIDO';
  end if;
  update public.contratos
     set versao = versao + 1, caminho_docx = p_caminho_docx, caminho = p_caminho_pdf,
         validacao = 'aguardando', validado_em = null, validado_por = null
   where id = p_id returning * into v;
  insert into public.contrato_versoes (contrato_id, versao, caminho_pdf, caminho_docx, origem, criado_por)
  values (v.id, v.versao, p_caminho_pdf, p_caminho_docx, 'ajuste', public.meu_email());
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato ajustado', jsonb_build_object('numero', v.numero, 'versao', v.versao), public.meu_email());
  return v;
end;
$$;

create or replace function public.cancelar_contrato(p_id uuid) returns public.contratos
language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if public.em_envelope_ativo(p_id) then raise exception 'EM_ENVELOPE'; end if;
  update public.contratos set cancelado_em = now(), cancelado_por = public.meu_email()
   where id = p_id and cancelado_em is null and assinatura <> 'assinado' returning * into v;
  if v.id is null then raise exception 'NAO_PODE_CANCELAR'; end if;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato cancelado', jsonb_build_object('numero', v.numero), public.meu_email());
  return v;
end;
$$;

revoke all on function public.salvar_anexo_fixo(text, text, text, int), public.alterar_anexo_fixo(uuid, text, int, boolean), public.em_envelope_ativo(uuid) from public, anon;
grant execute on function public.salvar_anexo_fixo(text, text, text, int), public.alterar_anexo_fixo(uuid, text, int, boolean), public.em_envelope_ativo(uuid) to authenticated;

commit;

-- >>>>> 047_leads
-- =====================================================================
-- 047 — Leads (campanhas do Meta) com rodízio, prazo e funil
--  * Entrada: planilha do Google preenchida pelo Meta → script da planilha
--    → /api/leads/entrada (chave secreta) → receber_leads().
--  * Distribuição em dois níveis: imobiliária por cota (peso) e, dentro
--    dela, rodízio entre os corretores que o gestor colocou na lista.
--  * Prazo para "Assumir" (padrão 15 min) contado só no horário comercial;
--    estourou → próximo corretor da mesma imobiliária (depois, outra
--    imobiliária); depois de N tentativas → Sec. Vendas decide.
--  * Cliente que volta (mesmo telefone/e-mail) vai para o mesmo corretor
--    durante X dias. Pasta criada com o mesmo telefone/e-mail converte o lead.
--  * Telefone e e-mail só aparecem para o corretor depois de assumir.
-- Executar uma única vez no SQL Editor do Supabase (depois da 046).
-- =====================================================================
begin;

alter table public.config add column if not exists modulo_leads boolean not null default false;
grant update (modulo_leads) on public.config to authenticated;

-- Configuração ---------------------------------------------------------
create table if not exists public.leads_config (
  id                 int primary key default 1 check (id = 1),
  ativo              boolean not null default true,
  prazo_aceite_min   int not null default 15 check (prazo_aceite_min between 1 and 1440),
  prazo_contato_min  int not null default 120 check (prazo_contato_min between 5 and 10080),
  max_tentativas     int not null default 3 check (max_tentativas between 1 and 20),
  dias_semana        int[] not null default '{1,2,3,4,5,6}',
  hora_inicio        time not null default '08:00',
  hora_fim           time not null default '18:00',
  plantao_24h        boolean not null default false,
  dono_dias          int not null default 90 check (dono_dias between 0 and 730),
  emails_alerta      text,
  remetente_email    text,
  remetente_nome     text default 'Leads',
  url_app            text,
  ultimo_recebimento timestamptz,
  atualizado_em      timestamptz not null default now(),
  atualizado_por     text
);
insert into public.leads_config (id) values (1) on conflict do nothing;
alter table public.leads_config enable row level security;
drop policy if exists leads_config_leitura on public.leads_config;
create policy leads_config_leitura on public.leads_config for select using (public.eh_equipe() or public.minha_imobiliaria() is not null);
revoke all on public.leads_config from anon, authenticated;
grant select on public.leads_config to authenticated;

-- Chave da planilha (só o administrador vê, pela função)
create table if not exists public.leads_chave (
  id    int primary key default 1 check (id = 1),
  chave text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
);
insert into public.leads_chave (id) values (1) on conflict do nothing;
alter table public.leads_chave enable row level security;
revoke all on public.leads_chave from anon, authenticated;

-- Cotas por imobiliária e lista de corretores no rodízio
create table if not exists public.leads_imobiliarias (
  imobiliaria_id uuid primary key references public.imobiliarias(id) on delete cascade,
  cota           numeric(6, 2) not null default 0 check (cota >= 0),
  recebidos      int not null default 0
);
alter table public.leads_imobiliarias enable row level security;
drop policy if exists leads_imobiliarias_leitura on public.leads_imobiliarias;
create policy leads_imobiliarias_leitura on public.leads_imobiliarias for select using (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria());
revoke all on public.leads_imobiliarias from anon, authenticated;
grant select on public.leads_imobiliarias to authenticated;

create table if not exists public.leads_corretores (
  user_id        uuid primary key references public.perfis(user_id) on delete cascade,
  participa      boolean not null default false,
  ultimo_lead_em timestamptz,
  recebidos      int not null default 0,
  alterado_em    timestamptz not null default now(),
  alterado_por   text
);
alter table public.leads_corretores enable row level security;
drop policy if exists leads_corretores_leitura on public.leads_corretores;
create policy leads_corretores_leitura on public.leads_corretores for select using (
  public.eh_equipe() or user_id = auth.uid()
  or exists (select 1 from public.perfis p where p.user_id = leads_corretores.user_id and p.imobiliaria_id = public.minha_imobiliaria()));
revoke all on public.leads_corretores from anon, authenticated;
grant select on public.leads_corretores to authenticated;

-- Leads ------------------------------------------------------------------
create sequence if not exists public.leads_codigo_seq;
create table if not exists public.leads (
  id                  uuid primary key default gen_random_uuid(),
  codigo              text not null unique default 'L-' || lpad(nextval('public.leads_codigo_seq')::text, 5, '0'),
  meta_id             text not null unique,
  origem              text not null default 'meta',
  campanha            text, conjunto text, anuncio text, formulario text, plataforma text,
  criado_meta_em      timestamptz,
  recebido_em         timestamptz not null default now(),
  nome                text,
  telefone            text,
  email               text,
  respostas           jsonb not null default '{}'::jsonb,
  status              text not null default 'sem_destino' check (status in (
                        'aguardando_aceite', 'em_atendimento', 'visita_agendada', 'visita_realizada', 'proposta',
                        'convertido', 'perdido', 'sem_destino')),
  imobiliaria_id      uuid references public.imobiliarias(id) on delete set null,
  corretor_id         uuid references public.perfis(user_id) on delete set null,
  distribuido_em      timestamptz,
  prazo_aceite_em     timestamptz,
  aceito_em           timestamptz,
  primeiro_contato_em timestamptz,
  tentados            uuid[] not null default '{}',
  motivo_perda        text,
  observacao          text,
  pasta_id            uuid references public.pastas(id) on delete set null,
  convertido_em       timestamptz,
  retorno_de          uuid references public.leads(id) on delete set null,
  atualizado_em       timestamptz not null default now()
);
create index if not exists leads_status_idx on public.leads (status, prazo_aceite_em);
create index if not exists leads_corretor_idx on public.leads (corretor_id);
create index if not exists leads_imob_idx on public.leads (imobiliaria_id);
create index if not exists leads_tel_idx on public.leads (telefone);
create index if not exists leads_email_idx on public.leads (lower(email));
alter table public.leads enable row level security;
-- Leitura direta só equipe e gestor da imobiliária; corretor lê por listar_leads() (dados mascarados até assumir)
drop policy if exists leads_leitura on public.leads;
create policy leads_leitura on public.leads for select using (public.eh_equipe() or (imobiliaria_id is not null and imobiliaria_id = public.minha_imobiliaria() and public.eh_gestor()));
revoke all on public.leads from anon, authenticated;
grant select on public.leads to authenticated;

create table if not exists public.lead_eventos (
  id            bigint generated always as identity primary key,
  lead_id       uuid not null references public.leads(id) on delete cascade,
  tipo          text not null,
  detalhes      jsonb not null default '{}'::jsonb,
  usuario_email text,
  criado_em     timestamptz not null default now()
);
create index if not exists lead_eventos_lead_idx on public.lead_eventos (lead_id, criado_em);
alter table public.lead_eventos enable row level security;
revoke all on public.lead_eventos from anon, authenticated;

create table if not exists public.lead_notificacoes (
  id         bigint generated always as identity primary key,
  lead_id    uuid references public.leads(id) on delete cascade,
  para       text not null,
  assunto    text not null,
  linhas     jsonb not null default '[]'::jsonb,   -- ["texto", ...]
  botao      text,                                  -- rótulo do botão
  caminho    text,                                  -- /painel/leads/<id>
  status     text not null default 'pendente' check (status in ('pendente', 'enviado', 'erro')),
  tentativas int not null default 0,
  erro       text,
  criado_em  timestamptz not null default now(),
  enviado_em timestamptz
);
create index if not exists lead_notificacoes_pend_idx on public.lead_notificacoes (status, criado_em);
alter table public.lead_notificacoes enable row level security;
revoke all on public.lead_notificacoes from anon, authenticated;

-- Auxiliares ----------------------------------------------------------------
create or replace function public.so_digitos_tel(t text) returns text
language sql immutable as $$
  select case when d = '' then null when length(d) >= 12 and d like '55%' then right(d, 11) else d end
    from (select regexp_replace(coalesce(t, ''), '\D', '', 'g') as d) x;
$$;

/** Soma minutos contando só o horário comercial (fuso de Brasília). */
create or replace function public.leads_prazo(p_inicio timestamptz, p_minutos int) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare c public.leads_config; t timestamp; resto numeric := p_minutos; abre timestamp; fecha timestamp; dispo numeric; i int := 0;
begin
  select * into c from public.leads_config where id = 1;
  if c.plantao_24h or coalesce(array_length(c.dias_semana, 1), 0) = 0 or c.hora_fim <= c.hora_inicio then
    return p_inicio + make_interval(mins => p_minutos);
  end if;
  t := p_inicio at time zone 'America/Sao_Paulo';
  loop
    i := i + 1;
    exit when i > 40;
    if extract(isodow from t)::int = any (c.dias_semana) then
      abre := date_trunc('day', t) + c.hora_inicio;
      fecha := date_trunc('day', t) + c.hora_fim;
      if t < abre then t := abre; end if;
      if t < fecha then
        dispo := extract(epoch from (fecha - t)) / 60;
        if resto <= dispo then return (t + make_interval(secs => resto * 60)) at time zone 'America/Sao_Paulo'; end if;
        resto := resto - dispo;
      end if;
    end if;
    t := date_trunc('day', t) + interval '1 day';
  end loop;
  return p_inicio + make_interval(mins => p_minutos);
end;
$$;

create or replace function public.lead_evento(p_lead uuid, p_tipo text, p_detalhes jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.lead_eventos (lead_id, tipo, detalhes, usuario_email) values (p_lead, p_tipo, coalesce(p_detalhes, '{}'::jsonb), coalesce(public.meu_email(), 'sistema'));
$$;

/** Avisos por e-mail (o servidor envia a cada minuto). */
create or replace function public.lead_avisar(p_lead uuid, p_para text, p_assunto text, p_linhas jsonb, p_botao text default 'Abrir lead') returns void
language sql security definer set search_path = public as $$
  insert into public.lead_notificacoes (lead_id, para, assunto, linhas, botao, caminho)
  select p_lead, trim(e), p_assunto, p_linhas, p_botao, '/painel/leads/' || p_lead
    from unnest(string_to_array(p_para, ',')) e where trim(e) ~ '^[^\s@,]+@[^\s@,]+$';
$$;

create or replace function public.leads_emails_alerta() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim((select emails_alerta from public.leads_config where id = 1)), ''),
                  (select string_agg(email, ',') from public.perfis where papel = 'vendas'),
                  (select string_agg(email, ',') from public.perfis where papel = 'admin'));
$$;

/** Resumo das respostas para o e-mail (sem dados de contato). */
create or replace function public.lead_resumo(l public.leads) returns jsonb
language sql stable as $$
  select jsonb_build_array(
    'Lead ' || l.codigo || coalesce(' · ' || nullif(split_part(coalesce(l.nome, ''), ' ', 1), ''), ''),
    'Campanha: ' || coalesce(l.campanha, '—') || coalesce(' · ' || l.formulario, ''))
  || coalesce((select jsonb_agg(case when k ~ '_' then initcap(replace(k, '_', ' ')) else k end || ': ' || v) from jsonb_each_text(l.respostas) as r(k, v) where length(v) between 1 and 120), '[]'::jsonb);
$$;

/** Escolhe o próximo corretor e entrega o lead (ou manda para a Sec. Vendas). */
create or replace function public.leads_atribuir(p_lead uuid, p_motivo text default 'Rodízio') returns void
language plpgsql security definer set search_path = public as $$
declare
  l public.leads; c public.leads_config; v_imob uuid; v_corr uuid; v_email text; v_nome text; v_prazo timestamptz;
begin
  select * into c from public.leads_config where id = 1;
  select * into l from public.leads where id = p_lead for update;
  if l.id is null then return; end if;

  if coalesce(array_length(l.tentados, 1), 0) < c.max_tentativas then
    -- 1) próximo corretor da mesma imobiliária
    if l.imobiliaria_id is not null then
      select lc.user_id into v_corr
        from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
       where lc.participa and p.papel = 'corretor' and p.imobiliaria_id = l.imobiliaria_id and not (lc.user_id = any (l.tentados))
       order by lc.ultimo_lead_em nulls first, lc.recebidos limit 1;
      if v_corr is not null then v_imob := l.imobiliaria_id; end if;
    end if;
    -- 2) imobiliária pela cota (quem está mais abaixo da sua proporção)
    if v_corr is null then
      select li.imobiliaria_id into v_imob
        from public.leads_imobiliarias li join public.imobiliarias i on i.id = li.imobiliaria_id and i.ativa
       where li.cota > 0 and li.imobiliaria_id is distinct from l.imobiliaria_id
         and exists (select 1 from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
                      where lc.participa and p.papel = 'corretor' and p.imobiliaria_id = li.imobiliaria_id and not (lc.user_id = any (l.tentados)))
       order by (li.recebidos + 1) / li.cota, li.cota desc, random() limit 1;
      if v_imob is null and l.imobiliaria_id is null then v_imob := null; end if;
      if v_imob is not null then
        select lc.user_id into v_corr
          from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
         where lc.participa and p.papel = 'corretor' and p.imobiliaria_id = v_imob and not (lc.user_id = any (l.tentados))
         order by lc.ultimo_lead_em nulls first, lc.recebidos limit 1;
        update public.leads_imobiliarias set recebidos = recebidos + 1 where imobiliaria_id = v_imob;
      end if;
    end if;
  end if;

  if v_corr is null then
    update public.leads set status = 'sem_destino', corretor_id = null, prazo_aceite_em = null, atualizado_em = now() where id = l.id;
    perform public.lead_evento(l.id, 'Aguardando a Sec. Vendas', jsonb_build_object('motivo',
      case when coalesce(array_length(l.tentados, 1), 0) >= c.max_tentativas then 'Limite de tentativas atingido' else 'Nenhum corretor disponível no rodízio' end));
    perform public.lead_avisar(l.id, public.leads_emails_alerta(), 'Lead ' || l.codigo || ' sem corretor — distribuir manualmente',
      jsonb_build_array('O lead ' || l.codigo || ' não foi assumido por ninguém do rodízio e aguarda a Sec. Vendas.') || public.lead_resumo(l), 'Distribuir lead');
    return;
  end if;

  v_prazo := public.leads_prazo(now(), c.prazo_aceite_min);
  update public.leads set status = 'aguardando_aceite', imobiliaria_id = v_imob, corretor_id = v_corr, distribuido_em = now(),
         prazo_aceite_em = v_prazo, aceito_em = null, tentados = array_append(tentados, v_corr), atualizado_em = now()
   where id = l.id returning * into l;
  update public.leads_corretores set ultimo_lead_em = now(), recebidos = recebidos + 1 where user_id = v_corr;
  select email, nome into v_email, v_nome from public.perfis where user_id = v_corr;
  perform public.lead_evento(l.id, 'Enviado ao corretor', jsonb_build_object('corretor', coalesce(v_nome, v_email), 'motivo', p_motivo, 'prazo', v_prazo));
  perform public.lead_avisar(l.id, v_email, 'Novo lead ' || l.codigo || ' — assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    jsonb_build_array('Você recebeu um lead (' || p_motivo || '). Assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI')
      || ' para ver telefone e e-mail; depois disso ele vai para o próximo corretor.') || public.lead_resumo(l), 'Assumir lead');
end;
$$;

/** Entrada da planilha (chamada só pelo servidor, com a chave). */
create or replace function public.receber_leads(p_chave text, p_linhas jsonb, p_origem text default 'planilha', p_url text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r jsonb; v_id text; l public.leads; v_dono public.leads; v_tel text; v_email text; v_nome text; c public.leads_config;
  novos int := 0; repetidos int := 0; v_corr_pasta uuid; v_imob_pasta uuid;
  chaves_meta text[] := array['id', 'lead_id', 'leadgen_id', 'created_time', 'data_de_criacao', 'ad_id', 'ad_name', 'adset_id', 'adset_name',
    'campaign_id', 'campaign_name', 'form_id', 'form_name', 'is_organic', 'platform', 'plataforma', 'nome_completo', 'full_name', 'nome', 'name',
    'first_name', 'last_name', 'primeiro_nome', 'sobrenome', 'phone_number', 'phone', 'telefone', 'numero_de_telefone', 'celular', 'whatsapp',
    'email', 'e_mail', '_linha', '_rotulos', 'inbox_url', 'lead_status', 'vehicle', 'retailer_item_id'];
begin
  if p_chave is null or p_chave <> (select chave from public.leads_chave where id = 1) then raise exception 'CHAVE_INVALIDA'; end if;
  select * into c from public.leads_config where id = 1;
  update public.leads_config set ultimo_recebimento = now(), url_app = coalesce(p_url, url_app) where id = 1;
  for r in select * from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) loop
    v_id := nullif(trim(coalesce(r ->> 'id', r ->> 'lead_id', r ->> 'leadgen_id')), '');
    v_id := coalesce(regexp_replace(v_id, '^l:', ''), p_origem || ':' || coalesce(r ->> '_linha', md5(r::text)));
    if exists (select 1 from public.leads where meta_id = v_id) then repetidos := repetidos + 1; continue; end if;
    v_nome := nullif(trim(coalesce(r ->> 'nome_completo', r ->> 'full_name', r ->> 'nome', r ->> 'name',
                 nullif(trim(coalesce(r ->> 'first_name', r ->> 'primeiro_nome', '') || ' ' || coalesce(r ->> 'last_name', r ->> 'sobrenome', '')), ''))), '');
    v_tel := public.so_digitos_tel(coalesce(r ->> 'phone_number', r ->> 'telefone', r ->> 'numero_de_telefone', r ->> 'celular', r ->> 'whatsapp', r ->> 'phone'));
    v_email := nullif(lower(trim(coalesce(r ->> 'email', r ->> 'e_mail', ''))), '');
    insert into public.leads (meta_id, origem, campanha, conjunto, anuncio, formulario, plataforma, criado_meta_em, nome, telefone, email, respostas)
    values (v_id, coalesce(p_origem, 'planilha'), nullif(r ->> 'campaign_name', ''), nullif(r ->> 'adset_name', ''), nullif(r ->> 'ad_name', ''),
            nullif(r ->> 'form_name', ''), nullif(coalesce(r ->> 'platform', r ->> 'plataforma'), ''),
            case when coalesce(r ->> 'created_time', r ->> 'data_de_criacao', '') ~ '^\d{4}-\d{2}-\d{2}' then (coalesce(r ->> 'created_time', r ->> 'data_de_criacao'))::timestamptz end,
            initcap(v_nome), v_tel, v_email,
            coalesce((select jsonb_object_agg(coalesce(nullif(trim(r -> '_rotulos' ->> k), ''), k), v) from jsonb_each_text(r) as x(k, v) where not (k = any (chaves_meta)) and nullif(trim(v), '') is not null), '{}'::jsonb))
    returning * into l;
    novos := novos + 1;
    perform public.lead_evento(l.id, 'Lead recebido', jsonb_build_object('campanha', l.campanha, 'formulario', l.formulario, 'origem', l.origem));

    if not c.ativo then
      perform public.lead_evento(l.id, 'Aguardando a Sec. Vendas', jsonb_build_object('motivo', 'Rodízio desligado'));
      continue;
    end if;

    -- Cliente que voltou: mesmo corretor durante "dono_dias"
    select * into v_dono from public.leads x
     where x.id <> l.id and x.corretor_id is not null and x.status <> 'perdido'
       and x.recebido_em > now() - make_interval(days => c.dono_dias)
       and ((v_tel is not null and x.telefone = v_tel) or (v_email is not null and lower(x.email) = v_email))
       and exists (select 1 from public.perfis p where p.user_id = x.corretor_id)
     order by x.recebido_em desc limit 1;
    if v_dono.id is null then
      -- ou cliente que já tem pasta: corretor da pasta
      select coalesce(pa.cadastrado_por_id, pa.criado_por_id), pa.imobiliaria_id into v_corr_pasta, v_imob_pasta
        from public.pastas pa join public.perfis p on p.user_id = coalesce(pa.cadastrado_por_id, pa.criado_por_id) and p.papel = 'corretor'
       where (v_tel is not null and public.so_digitos_tel(pa.comprador_telefone) = v_tel) or (v_email is not null and lower(pa.comprador_email) = v_email)
       order by pa.criada_em desc limit 1;
    else
      v_corr_pasta := v_dono.corretor_id; v_imob_pasta := v_dono.imobiliaria_id;
    end if;

    if v_corr_pasta is not null then
      update public.leads set retorno_de = v_dono.id, imobiliaria_id = v_imob_pasta, status = 'aguardando_aceite', corretor_id = v_corr_pasta,
             tentados = array[v_corr_pasta], distribuido_em = now(), prazo_aceite_em = public.leads_prazo(now(), c.prazo_aceite_min)
       where id = l.id returning * into l;
      perform public.lead_evento(l.id, 'Enviado ao corretor', jsonb_build_object('motivo', 'Cliente já atendido por este corretor',
        'corretor', (select coalesce(nome, email) from public.perfis where user_id = v_corr_pasta), 'prazo', l.prazo_aceite_em));
      perform public.lead_avisar(l.id, (select email from public.perfis where user_id = v_corr_pasta),
        'Cliente seu voltou: lead ' || l.codigo || ' — assuma até ' || to_char(l.prazo_aceite_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
        jsonb_build_array('Um cliente que já é seu preencheu um novo formulário. Assuma até ' || to_char(l.prazo_aceite_em at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI') || '.') || public.lead_resumo(l), 'Assumir lead');
    else
      perform public.leads_atribuir(l.id, 'Rodízio');
    end if;
  end loop;
  return jsonb_build_object('novos', novos, 'repetidos', repetidos);
end;
$$;

/** Rodado a cada minuto pelo servidor: prazos vencidos voltam ao rodízio. */
create or replace function public.processar_leads() returns int
language plpgsql security definer set search_path = public as $$
declare l record; n int := 0; c public.leads_config;
begin
  select * into c from public.leads_config where id = 1;
  for l in select id, corretor_id from public.leads where status = 'aguardando_aceite' and prazo_aceite_em < now() order by prazo_aceite_em limit 200 for update skip locked loop
    perform public.lead_evento(l.id, 'Prazo para assumir esgotado', jsonb_build_object('corretor', (select coalesce(nome, email) from public.perfis where user_id = l.corretor_id)));
    perform public.leads_atribuir(l.id, 'Redistribuído: o anterior não assumiu no prazo');
    n := n + 1;
  end loop;
  -- Assumiu mas não registrou contato no prazo: avisa o gestor da imobiliária (uma vez)
  for l in select x.id, x.codigo, x.imobiliaria_id, x.corretor_id from public.leads x
            where x.status = 'em_atendimento' and x.primeiro_contato_em is null
              and public.leads_prazo(x.aceito_em, c.prazo_contato_min) < now()
              and not exists (select 1 from public.lead_eventos e where e.lead_id = x.id and e.tipo = 'Sem registro de contato no prazo') limit 200 loop
    perform public.lead_evento(l.id, 'Sem registro de contato no prazo', '{}'::jsonb);
    perform public.lead_avisar(l.id, (select string_agg(email, ',') from public.perfis where papel = 'imobiliaria' and imobiliaria_id = l.imobiliaria_id),
      'Lead ' || l.codigo || ' sem contato registrado',
      jsonb_build_array((select coalesce(nome, email) from public.perfis where user_id = l.corretor_id) || ' assumiu o lead ' || l.codigo || ' e ainda não registrou o primeiro contato.'), 'Abrir lead');
  end loop;
  return n;
end;
$$;

/** Notificações pendentes (servidor). */
create or replace function public.leads_notificacoes_pendentes(p_limite int default 50) returns setof public.lead_notificacoes
language sql security definer set search_path = public as $$
  select * from public.lead_notificacoes where status = 'pendente' or (status = 'erro' and tentativas < 3 and criado_em > now() - interval '1 day')
   order by criado_em limit p_limite;
$$;
create or replace function public.leads_marcar_notificacao(p_id bigint, p_ok boolean, p_erro text default null) returns void
language sql security definer set search_path = public as $$
  update public.lead_notificacoes set status = case when p_ok then 'enviado' else 'erro' end, tentativas = tentativas + 1,
         enviado_em = case when p_ok then now() end, erro = left(p_erro, 300) where id = p_id;
$$;

-- Leitura -------------------------------------------------------------------
create or replace function public.pode_ver_lead(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.leads l where l.id = p_id and (
    public.eh_equipe() or l.corretor_id = auth.uid()
    or (public.eh_gestor() and l.imobiliaria_id = public.minha_imobiliaria())));
$$;
drop policy if exists lead_eventos_leitura on public.lead_eventos;
create policy lead_eventos_leitura on public.lead_eventos for select using (public.pode_ver_lead(lead_id));
grant select on public.lead_eventos to authenticated;

create or replace function public.listar_leads(p_id uuid default null)
returns table (id uuid, codigo text, status text, campanha text, conjunto text, anuncio text, formulario text, plataforma text,
               recebido_em timestamptz, nome text, telefone text, email text, respostas jsonb, imobiliaria_id uuid, imobiliaria text,
               corretor_id uuid, corretor text, distribuido_em timestamptz, prazo_aceite_em timestamptz, aceito_em timestamptz,
               primeiro_contato_em timestamptz, tentativas int, motivo_perda text, observacao text, pasta_id uuid, pasta_codigo text,
               convertido_em timestamptz, retorno boolean, mascarado boolean)
language sql stable security definer set search_path = public as $$
  with eu as (select papel, imobiliaria_id from public.perfis where user_id = auth.uid())
  select l.id, l.codigo, l.status, l.campanha, l.conjunto, l.anuncio, l.formulario, l.plataforma, l.recebido_em,
         case when m.mask then split_part(coalesce(l.nome, ''), ' ', 1) else l.nome end,
         case when m.mask then null else l.telefone end,
         case when m.mask then null else l.email end,
         l.respostas, l.imobiliaria_id, i.nome, l.corretor_id, coalesce(p.nome, p.email), l.distribuido_em, l.prazo_aceite_em, l.aceito_em,
         l.primeiro_contato_em, coalesce(array_length(l.tentados, 1), 0), l.motivo_perda, l.observacao, l.pasta_id, pa.codigo, l.convertido_em,
         l.retorno_de is not null, m.mask
    from public.leads l
    cross join eu
    left join public.imobiliarias i on i.id = l.imobiliaria_id
    left join public.perfis p on p.user_id = l.corretor_id
    left join public.pastas pa on pa.id = l.pasta_id
    cross join lateral (select (eu.papel = 'corretor' and l.status = 'aguardando_aceite') as mask) m
   where (p_id is null or l.id = p_id)
     and (eu.papel in ('admin', 'vendas')
          or (eu.papel = 'imobiliaria' and l.imobiliaria_id = eu.imobiliaria_id)
          or (eu.papel = 'corretor' and l.corretor_id = auth.uid()))
   order by l.recebido_em desc
   limit 2000;
$$;

-- Ações -----------------------------------------------------------------------
create or replace function public.assumir_lead(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_id for update;
  if l.id is null or l.corretor_id is distinct from auth.uid() then raise exception 'LEAD_NAO_E_SEU'; end if;
  if l.status <> 'aguardando_aceite' then raise exception 'LEAD_JA_ASSUMIDO'; end if;
  update public.leads set status = 'em_atendimento', aceito_em = now(), prazo_aceite_em = null, atualizado_em = now() where id = p_id;
  perform public.lead_evento(p_id, 'Assumido', jsonb_build_object('minutos', round(extract(epoch from (now() - l.distribuido_em)) / 60)));
end;
$$;

create or replace function public.pode_mexer_lead(l public.leads) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe() or (l.corretor_id = auth.uid() and l.status <> 'aguardando_aceite')
      or (public.eh_gestor() and l.imobiliaria_id = public.minha_imobiliaria());
$$;

create or replace function public.registrar_contato_lead(p_id uuid, p_canal text, p_nota text) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_id for update;
  if l.id is null or not public.pode_mexer_lead(l) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.leads set primeiro_contato_em = coalesce(primeiro_contato_em, now()), atualizado_em = now() where id = p_id;
  perform public.lead_evento(p_id, 'Contato', jsonb_build_object('canal', left(p_canal, 30), 'nota', left(nullif(trim(p_nota), ''), 1000)));
end;
$$;

create or replace function public.mover_lead(p_id uuid, p_status text, p_motivo text default null, p_obs text default null) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_id for update;
  if l.id is null or not public.pode_mexer_lead(l) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_status not in ('em_atendimento', 'visita_agendada', 'visita_realizada', 'proposta', 'perdido') then raise exception 'ETAPA_INVALIDA'; end if;
  if l.status in ('aguardando_aceite', 'sem_destino') then raise exception 'LEAD_SEM_ATENDIMENTO'; end if;
  if l.status in ('perdido', 'convertido') and not (public.eh_equipe() or public.eh_gestor()) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_status = 'perdido' and nullif(trim(p_motivo), '') is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  update public.leads set status = p_status, motivo_perda = case when p_status = 'perdido' then left(trim(p_motivo), 120) end,
         observacao = coalesce(nullif(trim(p_obs), ''), observacao), atualizado_em = now() where id = p_id;
  perform public.lead_evento(p_id, case when p_status = 'perdido' then 'Perdido' when l.status in ('perdido', 'convertido') then 'Reaberto' else 'Etapa alterada' end,
    jsonb_build_object('de', l.status, 'para', p_status, 'motivo', nullif(trim(p_motivo), ''), 'obs', nullif(trim(p_obs), '')));
end;
$$;

/** Redistribuir: equipe (qualquer corretor ou rodízio) e gestor (só a própria equipe). */
create or replace function public.redistribuir_lead(p_id uuid, p_corretor uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads; v_imob uuid; v_email text; v_prazo timestamptz;
begin
  select * into l from public.leads where id = p_id for update;
  if l.id is null then raise exception 'LEAD_NAO_ENCONTRADO'; end if;
  if l.status in ('convertido') then raise exception 'LEAD_CONVERTIDO'; end if;
  if not public.eh_equipe() and not (public.eh_gestor() and l.imobiliaria_id = public.minha_imobiliaria()) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_corretor is null then
    if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
    update public.leads set tentados = '{}', corretor_id = null where id = p_id;
    perform public.lead_evento(p_id, 'Devolvido ao rodízio', '{}'::jsonb);
    perform public.leads_atribuir(p_id, 'Rodízio (redistribuído pela equipe)');
    return;
  end if;
  select imobiliaria_id, email into v_imob, v_email from public.perfis where user_id = p_corretor and papel = 'corretor';
  if v_imob is null then raise exception 'CORRETOR_INVALIDO'; end if;
  if not public.eh_equipe() and v_imob <> public.minha_imobiliaria() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  v_prazo := public.leads_prazo(now(), (select prazo_aceite_min from public.leads_config where id = 1));
  update public.leads set imobiliaria_id = v_imob, corretor_id = p_corretor, status = 'aguardando_aceite', distribuido_em = now(),
         prazo_aceite_em = v_prazo, aceito_em = null, tentados = array_append(tentados, p_corretor), atualizado_em = now()
   where id = p_id returning * into l;
  perform public.lead_evento(p_id, 'Enviado ao corretor', jsonb_build_object('motivo', 'Escolhido manualmente',
    'corretor', (select coalesce(nome, email) from public.perfis where user_id = p_corretor), 'prazo', v_prazo));
  perform public.lead_avisar(p_id, v_email, 'Novo lead ' || l.codigo || ' — assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    jsonb_build_array('Um lead foi direcionado a você. Assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI') || '.') || public.lead_resumo(l), 'Assumir lead');
end;
$$;

create or replace function public.vincular_pasta_lead(p_lead uuid, p_pasta uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null or not (public.eh_equipe() or l.corretor_id = auth.uid() or (public.eh_gestor() and l.imobiliaria_id = public.minha_imobiliaria())) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if not exists (select 1 from public.pastas where id = p_pasta and (public.eh_equipe() or imobiliaria_id = coalesce(public.minha_imobiliaria(), l.imobiliaria_id))) then
    raise exception 'PASTA_INVALIDA';
  end if;
  update public.leads set status = 'convertido', pasta_id = p_pasta, convertido_em = now(), motivo_perda = null,
         aceito_em = coalesce(aceito_em, now()), primeiro_contato_em = coalesce(primeiro_contato_em, now()), atualizado_em = now() where id = p_lead;
  perform public.lead_evento(p_lead, 'Convertido em pasta', jsonb_build_object('pasta', (select codigo from public.pastas where id = p_pasta)));
end;
$$;

-- Pasta nova com o mesmo telefone/e-mail de um lead em atendimento converte o lead
create or replace function public.pastas_converte_lead() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_tel text := public.so_digitos_tel(new.comprador_telefone); v_email text := lower(nullif(trim(new.comprador_email), '')); l record;
begin
  if v_tel is null and v_email is null then return null; end if;
  for l in select id from public.leads
            where status not in ('convertido', 'perdido', 'sem_destino') and pasta_id is null
              and (imobiliaria_id = new.imobiliaria_id)
              and ((v_tel is not null and telefone = v_tel) or (v_email is not null and lower(email) = v_email)) loop
    update public.leads set status = 'convertido', pasta_id = new.id, convertido_em = now(), aceito_em = coalesce(aceito_em, now()),
           primeiro_contato_em = coalesce(primeiro_contato_em, now()), atualizado_em = now() where id = l.id;
    perform public.lead_evento(l.id, 'Convertido em pasta', jsonb_build_object('pasta', new.codigo, 'automatico', true));
  end loop;
  return null;
end;
$$;
drop trigger if exists pastas_converte_lead on public.pastas;
create trigger pastas_converte_lead after insert on public.pastas for each row execute function public.pastas_converte_lead();

-- Configuração (administrador) e lista do rodízio (gestor) -----------------------
create or replace function public.salvar_config_leads(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.leads_config set
    ativo = coalesce((p ->> 'ativo')::boolean, ativo),
    prazo_aceite_min = coalesce((p ->> 'prazo_aceite_min')::int, prazo_aceite_min),
    prazo_contato_min = coalesce((p ->> 'prazo_contato_min')::int, prazo_contato_min),
    max_tentativas = coalesce((p ->> 'max_tentativas')::int, max_tentativas),
    dias_semana = coalesce((select array_agg(x::int order by x::int) from jsonb_array_elements_text(p -> 'dias_semana') x), dias_semana),
    hora_inicio = coalesce((p ->> 'hora_inicio')::time, hora_inicio),
    hora_fim = coalesce((p ->> 'hora_fim')::time, hora_fim),
    plantao_24h = coalesce((p ->> 'plantao_24h')::boolean, plantao_24h),
    dono_dias = coalesce((p ->> 'dono_dias')::int, dono_dias),
    emails_alerta = case when p ? 'emails_alerta' then nullif(trim(p ->> 'emails_alerta'), '') else emails_alerta end,
    remetente_email = case when p ? 'remetente_email' then nullif(trim(p ->> 'remetente_email'), '') else remetente_email end,
    remetente_nome = case when p ? 'remetente_nome' then nullif(trim(p ->> 'remetente_nome'), '') else remetente_nome end,
    atualizado_em = now(), atualizado_por = public.meu_email()
  where id = 1;
end;
$$;

create or replace function public.salvar_cotas_leads(p_cotas jsonb, p_zerar boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  for r in select (x ->> 'imobiliaria_id')::uuid as imob, greatest(0, coalesce((x ->> 'cota')::numeric, 0)) as cota from jsonb_array_elements(p_cotas) x loop
    insert into public.leads_imobiliarias (imobiliaria_id, cota) values (r.imob, r.cota)
    on conflict (imobiliaria_id) do update set cota = excluded.cota;
  end loop;
  if p_zerar then update public.leads_imobiliarias set recebidos = 0 where true; end if;
end;
$$;

create or replace function public.chave_leads(p_nova boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_nova then update public.leads_chave set chave = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') where id = 1; end if;
  select chave into v from public.leads_chave where id = 1;
  return v;
end;
$$;

create or replace function public.definir_rodizio_corretor(p_user uuid, p_participa boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_imob uuid;
begin
  select imobiliaria_id into v_imob from public.perfis where user_id = p_user and papel = 'corretor';
  if v_imob is null then raise exception 'CORRETOR_INVALIDO'; end if;
  if not (public.eh_equipe() or (public.eh_gestor() and v_imob = public.minha_imobiliaria())) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.leads_corretores (user_id, participa, alterado_por) values (p_user, p_participa, public.meu_email())
  on conflict (user_id) do update set participa = excluded.participa, alterado_em = now(), alterado_por = excluded.alterado_por;
end;
$$;

-- Permissões ---------------------------------------------------------------------
revoke all on function public.so_digitos_tel(text), public.leads_prazo(timestamptz, int), public.lead_evento(uuid, text, jsonb),
  public.lead_avisar(uuid, text, text, jsonb, text), public.leads_emails_alerta(), public.lead_resumo(public.leads), public.leads_atribuir(uuid, text),
  public.receber_leads(text, jsonb, text, text), public.processar_leads(), public.leads_notificacoes_pendentes(int), public.leads_marcar_notificacao(bigint, boolean, text),
  public.pode_ver_lead(uuid), public.listar_leads(uuid), public.assumir_lead(uuid), public.pode_mexer_lead(public.leads), public.registrar_contato_lead(uuid, text, text),
  public.mover_lead(uuid, text, text, text), public.redistribuir_lead(uuid, uuid), public.vincular_pasta_lead(uuid, uuid), public.pastas_converte_lead(),
  public.salvar_config_leads(jsonb), public.salvar_cotas_leads(jsonb, boolean), public.chave_leads(boolean), public.definir_rodizio_corretor(uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.receber_leads(text, jsonb, text, text), public.processar_leads(), public.leads_notificacoes_pendentes(int),
  public.leads_marcar_notificacao(bigint, boolean, text) to service_role;
grant execute on function public.pode_ver_lead(uuid), public.listar_leads(uuid), public.assumir_lead(uuid), public.registrar_contato_lead(uuid, text, text),
  public.mover_lead(uuid, text, text, text), public.redistribuir_lead(uuid, uuid), public.vincular_pasta_lead(uuid, uuid), public.salvar_config_leads(jsonb),
  public.salvar_cotas_leads(jsonb, boolean), public.chave_leads(boolean), public.definir_rodizio_corretor(uuid, boolean), public.leads_prazo(timestamptz, int)
  to authenticated;

commit;

-- >>>>> 048_manual_videos
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

-- >>>>> 115_meeting_numero_sorteio
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

-- >>>>> 116_modulos_duohaus_multi
-- =====================================================================
-- 116 — Módulos novos do Duo Haus (034–048) dentro de vários empreendimentos
--  * Propostas: módulo ligado na v2 e lido no empreendimento da proposta.
--  * Pix do sinal: configuração do empreendimento da pasta.
--  * Contratos: dados da vendedora, quadro de áreas, modelos e documentos
--    fixos passam a ser de cada empreendimento (cada incorporadora tem os seus).
--  * Leads: configuração, chave da planilha, cotas, rodízio e leads por
--    empreendimento (a chave da planilha diz de qual empreendimento é o lead).
--  * submeter_pasta: junta a versão da v2 (código com a sigla) com as
--    regras novas do Duo Haus (regime de bens, PJ, cônjuge e Pix).
-- Nada é configurado aqui: IA, D4Sign e minutas continuam em branco.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- Propostas: ligado na v2; a chave é a do empreendimento da proposta
-- ---------------------------------------------------------------------
alter table public.config alter column modulo_propostas set default true;
update public.config set modulo_propostas = true where not modulo_propostas;

create or replace function public.propostas_modulo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_equipe() and not coalesce((select modulo_propostas from public.config
                                              where empreendimento_id = coalesce(new.empreendimento_id, public.empreendimento_atual())), false) then
    raise exception 'MODULO_DESLIGADO' using hint = 'As propostas ainda não estão liberadas.';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Pix do sinal: configuração do empreendimento da pasta
-- ---------------------------------------------------------------------
create or replace function public.pix_integrado(p_pasta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select c.pix_modo = 'integrado' from public.config c join public.pastas p on p.empreendimento_id = c.empreendimento_id
                    where p.id = p_pasta), false);
$$;
revoke all on function public.pix_integrado(uuid) from public, anon, authenticated;

create or replace function public.recalcular_pasta(p_pasta uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ec        public.estado_civil;
  v_tipo      text;
  v_conjuge   boolean;
  v_submetida boolean;
  v_integrado boolean := public.pix_integrado(p_pasta);
  v_status    text;
  v_faltando  int;
  v_recusado  int;
  v_analise   int;
  v_enviado   int;
begin
  select estado_civil, tipo_pessoa, public.conjuge_no_contrato(estado_civil, regime_bens, conjuge_participa, tipo_pessoa), codigo_aprovacao is not null
    into v_ec, v_tipo, v_conjuge, v_submetida from public.pastas where id = p_pasta;

  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo
     and not (v_integrado and t.eh_pix)
     and case when v_tipo = 'pj' then t.aplica_a in ('pj', 'ambos') and t.obrigatorio_pj
              else t.aplica_a in ('pf', 'ambos') and v_ec = any (t.obrigatorio_para) and (t.pessoa <> 'conjuge' or v_conjuge) end
     and not exists (select 1 from public.documentos d where d.pasta_id = p_pasta and d.tipo_id = t.id and d.atual);
  if v_integrado and not public.pix_pago(p_pasta) then v_faltando := v_faltando + 1; end if;
  select count(*) into v_recusado from public.documentos where pasta_id = p_pasta and atual and status = 'recusado';
  select count(*) into v_analise  from public.documentos where pasta_id = p_pasta and atual and status = 'em_analise';
  select count(*) into v_enviado  from public.documentos where pasta_id = p_pasta and atual and status = 'enviado';

  if not v_submetida then
    v_status := case when v_faltando > 0 then 'incompleta' else 'pronta' end;
  else
    v_status := case
      when v_recusado > 0 then 'pendente_correcao'
      when v_faltando > 0 then 'incompleta'
      when v_analise > 0 then 'em_analise'
      when v_enviado > 0 then 'aguardando_analise'
      else 'aprovada' end;
  end if;

  update public.pastas set status = v_status where id = p_pasta and status is distinct from v_status;
  return v_status;
end;
$$;
revoke all on function public.recalcular_pasta(uuid) from public, anon, authenticated;

create or replace function public.config_pix_mudou() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.pix_modo is distinct from old.pix_modo then
    for r in select id from public.pastas where codigo_aprovacao is null and empreendimento_id = new.empreendimento_id loop
      perform public.recalcular_pasta(r.id);
    end loop;
  end if;
  return null;
end;
$$;

do $$
declare d text;
begin
  -- gerar_cobranca_pix: troca só a leitura da configuração
  select pg_get_functiondef('public.gerar_cobranca_pix(uuid)'::regprocedure) into d;
  if position('where id = 1' in d) > 0 then
    d := replace(d, 'select * into c from public.config where id = 1;',
                    'select c0.* into c from public.config c0 join public.pastas p0 on p0.empreendimento_id = c0.empreendimento_id where p0.id = p_pasta;');
    execute d;
  end if;
end $$;

-- Submissão: código com a sigla do empreendimento + regras de regime, PJ e Pix
create or replace function public.submeter_pasta(p_pasta uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v_pasta.codigo_aprovacao is not null then raise exception 'JA_SUBMETIDA'; end if;
  if length(trim(coalesce(v_pasta.comprador_telefone, ''))) < 10
     or length(trim(coalesce(v_pasta.comprador_email, ''))) <= 3
     or length(trim(coalesce(v_pasta.comprador_profissao, ''))) <= 1 then
    raise exception 'DADOS_INCOMPLETOS';
  end if;
  if v_pasta.tipo_pessoa = 'pf' and v_pasta.estado_civil in ('casado', 'uniao_estavel') and v_pasta.regime_bens is null then
    raise exception 'REGIME_NAO_INFORMADO';
  end if;
  if public.conjuge_no_contrato(v_pasta.estado_civil, v_pasta.regime_bens, v_pasta.conjuge_participa, v_pasta.tipo_pessoa)
     and (length(trim(coalesce(v_pasta.conjuge_nome, ''))) <= 1
          or v_pasta.conjuge_cpf is null
          or length(trim(coalesce(v_pasta.conjuge_profissao, ''))) <= 1) then
    raise exception 'DADOS_CONJUGE_INCOMPLETOS';
  end if;
  if public.pix_integrado(p_pasta) and not public.pix_pago(p_pasta) then
    raise exception 'PIX_PENDENTE';
  end if;
  if public.recalcular_pasta(p_pasta) <> 'pronta' then raise exception 'DOCUMENTOS_FALTANDO'; end if;

  update public.pastas
     set codigo_aprovacao = public.proximo_codigo(v_pasta.empreendimento_id, 'PA'),
         submetida_em = now(), submetida_por = public.meu_email()
   where id = p_pasta
  returning * into v_pasta;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pasta submetida ao incorporador', jsonb_build_object('codigo', v_pasta.codigo_aprovacao), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$$;

-- ---------------------------------------------------------------------
-- Contratos: cada empreendimento com os seus dados, quadro, modelos e fixos
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['empreendimento_contrato', 'unidade_areas', 'modelos_contrato', 'contrato_anexos_fixos'] loop
    execute format('alter table public.%I add column if not exists empreendimento_id uuid references public.empreendimentos (id) on delete cascade', t);
    execute format('update public.%I set empreendimento_id = public.empreendimento_padrao() where empreendimento_id is null', t);
    execute format('alter table public.%I alter column empreendimento_id set not null', t);
    execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_atual()', t);
    execute format('drop policy if exists %I on public.%I', t || '_do_empreendimento', t);
    execute format('create policy %I on public.%I as restrictive for select using (empreendimento_id = (select public.empreendimento_atual()))', t || '_do_empreendimento', t);
  end loop;
end $$;

-- dados da vendedora: uma linha por empreendimento
alter table public.empreendimento_contrato drop constraint if exists empreendimento_contrato_id_check;
create sequence if not exists public.empreendimento_contrato_id_seq as smallint;
select setval('public.empreendimento_contrato_id_seq', greatest((select max(id) from public.empreendimento_contrato), 1));
alter table public.empreendimento_contrato alter column id set default nextval('public.empreendimento_contrato_id_seq');
create unique index if not exists empreendimento_contrato_emp_key on public.empreendimento_contrato (empreendimento_id);

create or replace function public.salvar_empreendimento_contrato(p_dados jsonb) returns public.empreendimento_contrato
language plpgsql security definer set search_path = public as $$
declare v public.empreendimento_contrato;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.empreendimento_contrato (empreendimento_id, dados, atualizado_em, atualizado_por)
  values (public.empreendimento_atual(), coalesce(p_dados, '{}'), now(), public.meu_email())
  on conflict (empreendimento_id) do update set dados = excluded.dados, atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  return v;
end;
$$;

-- quadro de áreas: número único dentro do empreendimento
alter table public.unidade_areas drop constraint if exists unidade_areas_pkey;
alter table public.unidade_areas add primary key (empreendimento_id, numero);

create or replace function public.importar_quadro_areas(p_linhas jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then raise exception 'PLANILHA_VAZIA'; end if;
  if exists (select 1 from jsonb_array_elements(p_linhas) l where coalesce(trim(l ->> 'numero'), '') = '') then raise exception 'UNIDADE_SEM_NUMERO'; end if;
  if (select count(distinct trim(l ->> 'numero')) from jsonb_array_elements(p_linhas) l) <> jsonb_array_length(p_linhas) then raise exception 'UNIDADE_REPETIDA'; end if;
  delete from public.unidade_areas where empreendimento_id = v_emp;
  insert into public.unidade_areas (empreendimento_id, numero, torre, pavimento, area_privativa, area_acessoria, area_privativa_total, area_comum,
                                    area_total, fracao_ideal, vagas, escaninho, escaninho_local, escaninho_area)
  select v_emp, trim(l ->> 'numero'), nullif(trim(l ->> 'torre'), ''), nullif(trim(l ->> 'pavimento'), ''),
         (l ->> 'area_privativa')::numeric, (l ->> 'area_acessoria')::numeric, (l ->> 'area_privativa_total')::numeric,
         (l ->> 'area_comum')::numeric, (l ->> 'area_total')::numeric, (l ->> 'fracao_ideal')::numeric,
         nullif(trim(l ->> 'vagas'), ''), nullif(trim(l ->> 'escaninho'), ''), nullif(trim(l ->> 'escaninho_local'), ''),
         (l ->> 'escaninho_area')::numeric
    from jsonb_array_elements(p_linhas) l;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- modelos: um ativo por documento em cada empreendimento
drop index if exists public.modelos_contrato_um_ativo;
create unique index if not exists modelos_contrato_um_ativo on public.modelos_contrato (empreendimento_id, documento) where ativo;

create or replace function public.salvar_modelo_contrato(p_documento text, p_nome text, p_caminho text)
returns public.modelos_contrato language plpgsql security definer set search_path = public as $$
declare v public.modelos_contrato; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.modelos_contrato set ativo = false where empreendimento_id = v_emp and documento = p_documento and ativo;
  insert into public.modelos_contrato (empreendimento_id, documento, nome, caminho, enviado_por)
  values (v_emp, p_documento, left(p_nome, 200), p_caminho, public.meu_email()) returning * into v;
  return v;
end;
$$;

create or replace function public.usar_modelo_padrao(p_documento text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.modelos_contrato set ativo = false where empreendimento_id = public.empreendimento_atual() and documento = p_documento and ativo;
end;
$$;

create or replace function public.salvar_anexo_fixo(p_nome text, p_caminho text, p_arquivo text, p_ordem int)
returns public.contrato_anexos_fixos language plpgsql security definer set search_path = public as $$
declare v public.contrato_anexos_fixos;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.contrato_anexos_fixos (empreendimento_id, nome, caminho, arquivo, ordem, enviado_por)
  values (public.empreendimento_atual(), left(trim(p_nome), 150), p_caminho, left(p_arquivo, 200), coalesce(p_ordem, 100), public.meu_email()) returning * into v;
  return v;
end;
$$;

create or replace function public.alterar_anexo_fixo(p_id uuid, p_nome text, p_ordem int, p_ativo boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contrato_anexos_fixos set nome = coalesce(left(trim(p_nome), 150), nome), ordem = coalesce(p_ordem, ordem), ativo = coalesce(p_ativo, ativo)
   where id = p_id and empreendimento_id = public.empreendimento_atual();
end;
$$;

-- ---------------------------------------------------------------------
-- Leads por empreendimento
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['leads_config', 'leads_chave'] loop
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_id_check');
    execute format('create sequence if not exists public.%I', t || '_id_seq');
    execute format('select setval(%L, greatest((select max(id) from public.%I), 1))', 'public.' || t || '_id_seq', t);
    execute format('alter table public.%I alter column id set default nextval(%L)', t, 'public.' || t || '_id_seq');
  end loop;
  foreach t in array array['leads_config', 'leads_chave', 'leads_imobiliarias', 'leads_corretores', 'leads'] loop
    execute format('alter table public.%I add column if not exists empreendimento_id uuid references public.empreendimentos (id) on delete cascade', t);
    execute format('update public.%I set empreendimento_id = public.empreendimento_padrao() where empreendimento_id is null', t);
    execute format('alter table public.%I alter column empreendimento_id set not null', t);
    execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_atual()', t);
    execute format('drop policy if exists %I on public.%I', t || '_do_empreendimento', t);
    execute format('create policy %I on public.%I as restrictive for select using (empreendimento_id = (select public.empreendimento_atual()))', t || '_do_empreendimento', t);
  end loop;
end $$;
create unique index if not exists leads_config_emp_key on public.leads_config (empreendimento_id);
create unique index if not exists leads_chave_emp_key on public.leads_chave (empreendimento_id);
alter table public.leads_imobiliarias drop constraint if exists leads_imobiliarias_pkey;
alter table public.leads_imobiliarias add primary key (empreendimento_id, imobiliaria_id);
alter table public.leads_corretores drop constraint if exists leads_corretores_pkey;
alter table public.leads_corretores add primary key (empreendimento_id, user_id);
create index if not exists leads_emp_idx on public.leads (empreendimento_id, recebido_em desc);

-- todo empreendimento tem a sua configuração e a sua chave
insert into public.leads_config (empreendimento_id) select id from public.empreendimentos on conflict (empreendimento_id) do nothing;
insert into public.leads_chave (empreendimento_id) select id from public.empreendimentos on conflict (empreendimento_id) do nothing;
create or replace function public.empreendimento_cria_leads() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.leads_config (empreendimento_id) values (new.id) on conflict (empreendimento_id) do nothing;
  insert into public.leads_chave (empreendimento_id) values (new.id) on conflict (empreendimento_id) do nothing;
  return null;
end;
$$;
revoke all on function public.empreendimento_cria_leads() from public, anon, authenticated;
drop trigger if exists empreendimento_cria_leads on public.empreendimentos;
create trigger empreendimento_cria_leads after insert on public.empreendimentos for each row execute function public.empreendimento_cria_leads();

-- prazo e alertas: pela configuração do empreendimento
drop function if exists public.leads_prazo(timestamptz, int);
create or replace function public.leads_prazo(p_inicio timestamptz, p_minutos int, p_emp uuid default null) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare c public.leads_config; t timestamp; resto numeric := p_minutos; abre timestamp; fecha timestamp; dispo numeric; i int := 0;
begin
  select * into c from public.leads_config where empreendimento_id = coalesce(p_emp, public.empreendimento_atual());
  if c.id is null or c.plantao_24h or coalesce(array_length(c.dias_semana, 1), 0) = 0 or c.hora_fim <= c.hora_inicio then
    return p_inicio + make_interval(mins => p_minutos);
  end if;
  t := p_inicio at time zone 'America/Sao_Paulo';
  loop
    i := i + 1;
    exit when i > 40;
    if extract(isodow from t)::int = any (c.dias_semana) then
      abre := date_trunc('day', t) + c.hora_inicio;
      fecha := date_trunc('day', t) + c.hora_fim;
      if t < abre then t := abre; end if;
      if t < fecha then
        dispo := extract(epoch from (fecha - t)) / 60;
        if resto <= dispo then return (t + make_interval(secs => resto * 60)) at time zone 'America/Sao_Paulo'; end if;
        resto := resto - dispo;
      end if;
    end if;
    t := date_trunc('day', t) + interval '1 day';
  end loop;
  return p_inicio + make_interval(mins => p_minutos);
end;
$$;

drop function if exists public.leads_emails_alerta();
create or replace function public.leads_emails_alerta(p_emp uuid default null) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim((select emails_alerta from public.leads_config where empreendimento_id = coalesce(p_emp, public.empreendimento_atual()))), ''),
                  (select string_agg(email, ',') from public.perfis where papel = 'vendas'),
                  (select string_agg(email, ',') from public.perfis where papel = 'admin'));
$$;

/** Escolhe o próximo corretor (do rodízio do empreendimento do lead) e entrega o lead. */
create or replace function public.leads_atribuir(p_lead uuid, p_motivo text default 'Rodízio') returns void
language plpgsql security definer set search_path = public as $$
declare
  l public.leads; c public.leads_config; v_imob uuid; v_corr uuid; v_email text; v_nome text; v_prazo timestamptz;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null then return; end if;
  select * into c from public.leads_config where empreendimento_id = l.empreendimento_id;

  if coalesce(array_length(l.tentados, 1), 0) < c.max_tentativas then
    -- 1) próximo corretor da mesma imobiliária
    if l.imobiliaria_id is not null then
      select lc.user_id into v_corr
        from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
       where lc.empreendimento_id = l.empreendimento_id and lc.participa and p.papel = 'corretor'
         and p.imobiliaria_id = l.imobiliaria_id and not (lc.user_id = any (l.tentados))
       order by lc.ultimo_lead_em nulls first, lc.recebidos limit 1;
      if v_corr is not null then v_imob := l.imobiliaria_id; end if;
    end if;
    -- 2) imobiliária pela cota (quem está mais abaixo da sua proporção)
    if v_corr is null then
      select li.imobiliaria_id into v_imob
        from public.leads_imobiliarias li join public.imobiliarias i on i.id = li.imobiliaria_id and i.ativa
       where li.empreendimento_id = l.empreendimento_id and li.cota > 0 and li.imobiliaria_id is distinct from l.imobiliaria_id
         and exists (select 1 from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
                      where lc.empreendimento_id = l.empreendimento_id and lc.participa and p.papel = 'corretor'
                        and p.imobiliaria_id = li.imobiliaria_id and not (lc.user_id = any (l.tentados)))
       order by (li.recebidos + 1) / li.cota, li.cota desc, random() limit 1;
      if v_imob is not null then
        select lc.user_id into v_corr
          from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
         where lc.empreendimento_id = l.empreendimento_id and lc.participa and p.papel = 'corretor'
           and p.imobiliaria_id = v_imob and not (lc.user_id = any (l.tentados))
         order by lc.ultimo_lead_em nulls first, lc.recebidos limit 1;
        update public.leads_imobiliarias set recebidos = recebidos + 1 where empreendimento_id = l.empreendimento_id and imobiliaria_id = v_imob;
      end if;
    end if;
  end if;

  if v_corr is null then
    update public.leads set status = 'sem_destino', corretor_id = null, prazo_aceite_em = null, atualizado_em = now() where id = l.id;
    perform public.lead_evento(l.id, 'Aguardando a Sec. Vendas', jsonb_build_object('motivo',
      case when coalesce(array_length(l.tentados, 1), 0) >= c.max_tentativas then 'Limite de tentativas atingido' else 'Nenhum corretor disponível no rodízio' end));
    perform public.lead_avisar(l.id, public.leads_emails_alerta(l.empreendimento_id), 'Lead ' || l.codigo || ' sem corretor — distribuir manualmente',
      jsonb_build_array('O lead ' || l.codigo || ' não foi assumido por ninguém do rodízio e aguarda a Sec. Vendas.') || public.lead_resumo(l), 'Distribuir lead');
    return;
  end if;

  v_prazo := public.leads_prazo(now(), c.prazo_aceite_min, l.empreendimento_id);
  update public.leads set status = 'aguardando_aceite', imobiliaria_id = v_imob, corretor_id = v_corr, distribuido_em = now(),
         prazo_aceite_em = v_prazo, aceito_em = null, tentados = array_append(tentados, v_corr), atualizado_em = now()
   where id = l.id returning * into l;
  update public.leads_corretores set ultimo_lead_em = now(), recebidos = recebidos + 1 where empreendimento_id = l.empreendimento_id and user_id = v_corr;
  select email, nome into v_email, v_nome from public.perfis where user_id = v_corr;
  perform public.lead_evento(l.id, 'Enviado ao corretor', jsonb_build_object('corretor', coalesce(v_nome, v_email), 'motivo', p_motivo, 'prazo', v_prazo));
  perform public.lead_avisar(l.id, v_email, 'Novo lead ' || l.codigo || ' — assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    jsonb_build_array('Você recebeu um lead (' || p_motivo || '). Assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI')
      || ' para ver telefone e e-mail; depois disso ele vai para o próximo corretor.') || public.lead_resumo(l), 'Assumir lead');
end;
$$;

/** Entrada da planilha (servidor, com a chave): a chave diz o empreendimento. */
create or replace function public.receber_leads(p_chave text, p_linhas jsonb, p_origem text default 'planilha', p_url text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r jsonb; v_id text; l public.leads; v_dono public.leads; v_tel text; v_email text; v_nome text; c public.leads_config; v_emp uuid;
  novos int := 0; repetidos int := 0; v_corr_pasta uuid; v_imob_pasta uuid;
  chaves_meta text[] := array['id', 'lead_id', 'leadgen_id', 'created_time', 'data_de_criacao', 'ad_id', 'ad_name', 'adset_id', 'adset_name',
    'campaign_id', 'campaign_name', 'form_id', 'form_name', 'is_organic', 'platform', 'plataforma', 'nome_completo', 'full_name', 'nome', 'name',
    'first_name', 'last_name', 'primeiro_nome', 'sobrenome', 'phone_number', 'phone', 'telefone', 'numero_de_telefone', 'celular', 'whatsapp',
    'email', 'e_mail', '_linha', '_rotulos', 'inbox_url', 'lead_status', 'vehicle', 'retailer_item_id'];
begin
  select empreendimento_id into v_emp from public.leads_chave where p_chave is not null and chave = p_chave;
  if v_emp is null then raise exception 'CHAVE_INVALIDA'; end if;
  select * into c from public.leads_config where empreendimento_id = v_emp;
  update public.leads_config set ultimo_recebimento = now(), url_app = coalesce(p_url, url_app) where empreendimento_id = v_emp;
  for r in select * from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) loop
    v_id := nullif(trim(coalesce(r ->> 'id', r ->> 'lead_id', r ->> 'leadgen_id')), '');
    v_id := coalesce(regexp_replace(v_id, '^l:', ''), p_origem || ':' || coalesce(r ->> '_linha', md5(r::text)));
    if exists (select 1 from public.leads where meta_id = v_id) then repetidos := repetidos + 1; continue; end if;
    v_nome := nullif(trim(coalesce(r ->> 'nome_completo', r ->> 'full_name', r ->> 'nome', r ->> 'name',
                 nullif(trim(coalesce(r ->> 'first_name', r ->> 'primeiro_nome', '') || ' ' || coalesce(r ->> 'last_name', r ->> 'sobrenome', '')), ''))), '');
    v_tel := public.so_digitos_tel(coalesce(r ->> 'phone_number', r ->> 'telefone', r ->> 'numero_de_telefone', r ->> 'celular', r ->> 'whatsapp', r ->> 'phone'));
    v_email := nullif(lower(trim(coalesce(r ->> 'email', r ->> 'e_mail', ''))), '');
    insert into public.leads (empreendimento_id, meta_id, origem, campanha, conjunto, anuncio, formulario, plataforma, criado_meta_em, nome, telefone, email, respostas)
    values (v_emp, v_id, coalesce(p_origem, 'planilha'), nullif(r ->> 'campaign_name', ''), nullif(r ->> 'adset_name', ''), nullif(r ->> 'ad_name', ''),
            nullif(r ->> 'form_name', ''), nullif(coalesce(r ->> 'platform', r ->> 'plataforma'), ''),
            case when coalesce(r ->> 'created_time', r ->> 'data_de_criacao', '') ~ '^\d{4}-\d{2}-\d{2}' then (coalesce(r ->> 'created_time', r ->> 'data_de_criacao'))::timestamptz end,
            initcap(v_nome), v_tel, v_email,
            coalesce((select jsonb_object_agg(coalesce(nullif(trim(r -> '_rotulos' ->> k), ''), k), v) from jsonb_each_text(r) as x(k, v) where not (k = any (chaves_meta)) and nullif(trim(v), '') is not null), '{}'::jsonb))
    returning * into l;
    novos := novos + 1;
    perform public.lead_evento(l.id, 'Lead recebido', jsonb_build_object('campanha', l.campanha, 'formulario', l.formulario, 'origem', l.origem));

    if not c.ativo then
      perform public.lead_evento(l.id, 'Aguardando a Sec. Vendas', jsonb_build_object('motivo', 'Rodízio desligado'));
      continue;
    end if;

    -- Cliente que voltou (no mesmo empreendimento): mesmo corretor durante "dono_dias"
    v_dono := null; v_corr_pasta := null; v_imob_pasta := null;
    select * into v_dono from public.leads x
     where x.id <> l.id and x.empreendimento_id = v_emp and x.corretor_id is not null and x.status <> 'perdido'
       and x.recebido_em > now() - make_interval(days => c.dono_dias)
       and ((v_tel is not null and x.telefone = v_tel) or (v_email is not null and lower(x.email) = v_email))
       and exists (select 1 from public.perfis p where p.user_id = x.corretor_id)
     order by x.recebido_em desc limit 1;
    if v_dono.id is null then
      -- ou cliente que já tem pasta neste empreendimento: corretor da pasta
      select coalesce(pa.cadastrado_por_id, pa.criado_por_id), pa.imobiliaria_id into v_corr_pasta, v_imob_pasta
        from public.pastas pa join public.perfis p on p.user_id = coalesce(pa.cadastrado_por_id, pa.criado_por_id) and p.papel = 'corretor'
       where pa.empreendimento_id = v_emp
         and ((v_tel is not null and public.so_digitos_tel(pa.comprador_telefone) = v_tel) or (v_email is not null and lower(pa.comprador_email) = v_email))
       order by pa.criada_em desc limit 1;
    else
      v_corr_pasta := v_dono.corretor_id; v_imob_pasta := v_dono.imobiliaria_id;
    end if;

    if v_corr_pasta is not null then
      update public.leads set retorno_de = v_dono.id, imobiliaria_id = v_imob_pasta, status = 'aguardando_aceite', corretor_id = v_corr_pasta,
             tentados = array[v_corr_pasta], distribuido_em = now(), prazo_aceite_em = public.leads_prazo(now(), c.prazo_aceite_min, v_emp)
       where id = l.id returning * into l;
      perform public.lead_evento(l.id, 'Enviado ao corretor', jsonb_build_object('motivo', 'Cliente já atendido por este corretor',
        'corretor', (select coalesce(nome, email) from public.perfis where user_id = v_corr_pasta), 'prazo', l.prazo_aceite_em));
      perform public.lead_avisar(l.id, (select email from public.perfis where user_id = v_corr_pasta),
        'Cliente seu voltou: lead ' || l.codigo || ' — assuma até ' || to_char(l.prazo_aceite_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
        jsonb_build_array('Um cliente que já é seu preencheu um novo formulário. Assuma até ' || to_char(l.prazo_aceite_em at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI') || '.') || public.lead_resumo(l), 'Assumir lead');
    else
      perform public.leads_atribuir(l.id, 'Rodízio');
    end if;
  end loop;
  return jsonb_build_object('novos', novos, 'repetidos', repetidos);
end;
$$;

/** Rodado a cada minuto pelo servidor, para todos os empreendimentos. */
create or replace function public.processar_leads() returns int
language plpgsql security definer set search_path = public as $$
declare l record; n int := 0;
begin
  for l in select id, corretor_id from public.leads where status = 'aguardando_aceite' and prazo_aceite_em < now() order by prazo_aceite_em limit 200 for update skip locked loop
    perform public.lead_evento(l.id, 'Prazo para assumir esgotado', jsonb_build_object('corretor', (select coalesce(nome, email) from public.perfis where user_id = l.corretor_id)));
    perform public.leads_atribuir(l.id, 'Redistribuído: o anterior não assumiu no prazo');
    n := n + 1;
  end loop;
  -- Assumiu mas não registrou contato no prazo: avisa o gestor da imobiliária (uma vez)
  for l in select x.id, x.codigo, x.imobiliaria_id, x.corretor_id from public.leads x
             join public.leads_config c on c.empreendimento_id = x.empreendimento_id
            where x.status = 'em_atendimento' and x.primeiro_contato_em is null
              and public.leads_prazo(x.aceito_em, c.prazo_contato_min, x.empreendimento_id) < now()
              and not exists (select 1 from public.lead_eventos e where e.lead_id = x.id and e.tipo = 'Sem registro de contato no prazo') limit 200 loop
    perform public.lead_evento(l.id, 'Sem registro de contato no prazo', '{}'::jsonb);
    perform public.lead_avisar(l.id, (select string_agg(email, ',') from public.perfis where papel = 'imobiliaria' and imobiliaria_id = l.imobiliaria_id),
      'Lead ' || l.codigo || ' sem contato registrado',
      jsonb_build_array((select coalesce(nome, email) from public.perfis where user_id = l.corretor_id) || ' assumiu o lead ' || l.codigo || ' e ainda não registrou o primeiro contato.'), 'Abrir lead');
  end loop;
  return n;
end;
$$;

do $$
declare d text;
begin
  -- listar_leads: só os leads do empreendimento atual
  select pg_get_functiondef('public.listar_leads(uuid)'::regprocedure) into d;
  if position('l.empreendimento_id' in d) = 0 then
    d := replace(d, 'where (p_id is null or l.id = p_id)', 'where l.empreendimento_id = public.empreendimento_atual() and (p_id is null or l.id = p_id)');
    execute d;
  end if;
  -- redistribuir_lead: prazo pela configuração do empreendimento do lead
  select pg_get_functiondef('public.redistribuir_lead(uuid, uuid)'::regprocedure) into d;
  d := replace(d, '(select prazo_aceite_min from public.leads_config where id = 1))',
                  '(select prazo_aceite_min from public.leads_config where empreendimento_id = l.empreendimento_id), l.empreendimento_id)');
  execute d;
  -- pasta nova converte só lead do mesmo empreendimento
  select pg_get_functiondef('public.pastas_converte_lead()'::regprocedure) into d;
  if position('new.empreendimento_id' in d) = 0 then
    d := replace(d, 'and (imobiliaria_id = new.imobiliaria_id)', 'and (imobiliaria_id = new.imobiliaria_id) and empreendimento_id = new.empreendimento_id');
    execute d;
  end if;
end $$;

create or replace function public.salvar_config_leads(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.leads_config (empreendimento_id) values (v_emp) on conflict (empreendimento_id) do nothing;
  update public.leads_config set
    ativo = coalesce((p ->> 'ativo')::boolean, ativo),
    prazo_aceite_min = coalesce((p ->> 'prazo_aceite_min')::int, prazo_aceite_min),
    prazo_contato_min = coalesce((p ->> 'prazo_contato_min')::int, prazo_contato_min),
    max_tentativas = coalesce((p ->> 'max_tentativas')::int, max_tentativas),
    dias_semana = coalesce((select array_agg(x::int order by x::int) from jsonb_array_elements_text(p -> 'dias_semana') x), dias_semana),
    hora_inicio = coalesce((p ->> 'hora_inicio')::time, hora_inicio),
    hora_fim = coalesce((p ->> 'hora_fim')::time, hora_fim),
    plantao_24h = coalesce((p ->> 'plantao_24h')::boolean, plantao_24h),
    dono_dias = coalesce((p ->> 'dono_dias')::int, dono_dias),
    emails_alerta = case when p ? 'emails_alerta' then nullif(trim(p ->> 'emails_alerta'), '') else emails_alerta end,
    remetente_email = case when p ? 'remetente_email' then nullif(trim(p ->> 'remetente_email'), '') else remetente_email end,
    remetente_nome = case when p ? 'remetente_nome' then nullif(trim(p ->> 'remetente_nome'), '') else remetente_nome end,
    atualizado_em = now(), atualizado_por = public.meu_email()
  where empreendimento_id = v_emp;
end;
$$;

create or replace function public.salvar_cotas_leads(p_cotas jsonb, p_zerar boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  for r in select (x ->> 'imobiliaria_id')::uuid as imob, greatest(0, coalesce((x ->> 'cota')::numeric, 0)) as cota from jsonb_array_elements(p_cotas) x loop
    insert into public.leads_imobiliarias (empreendimento_id, imobiliaria_id, cota) values (v_emp, r.imob, r.cota)
    on conflict (empreendimento_id, imobiliaria_id) do update set cota = excluded.cota;
  end loop;
  if p_zerar then update public.leads_imobiliarias set recebidos = 0 where empreendimento_id = v_emp; end if;
end;
$$;

create or replace function public.chave_leads(p_nova boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare v text; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.leads_chave (empreendimento_id) values (v_emp) on conflict (empreendimento_id) do nothing;
  if p_nova then update public.leads_chave set chave = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') where empreendimento_id = v_emp; end if;
  select chave into v from public.leads_chave where empreendimento_id = v_emp;
  return v;
end;
$$;

create or replace function public.definir_rodizio_corretor(p_user uuid, p_participa boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_imob uuid;
begin
  select imobiliaria_id into v_imob from public.perfis where user_id = p_user and papel = 'corretor';
  if v_imob is null then raise exception 'CORRETOR_INVALIDO'; end if;
  if not (public.eh_equipe() or (public.eh_gestor() and v_imob = public.minha_imobiliaria())) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.leads_corretores (empreendimento_id, user_id, participa, alterado_por) values (public.empreendimento_atual(), p_user, p_participa, public.meu_email())
  on conflict (empreendimento_id, user_id) do update set participa = excluded.participa, alterado_em = now(), alterado_por = excluded.alterado_por;
end;
$$;

-- Permissões (funções novas ou com assinatura nova)
revoke all on function public.leads_prazo(timestamptz, int, uuid), public.leads_emails_alerta(uuid) from public, anon, authenticated;
grant execute on function public.leads_prazo(timestamptz, int, uuid) to authenticated;

commit;
