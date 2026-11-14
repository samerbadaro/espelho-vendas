-- =====================================================================
-- 027 — Escolha de unidades por lotes de pastas (liga/desliga)
--  * A equipe monta a fila com as pastas aprovadas (ordem de submissão ao
--    incorporador, código PA) e pode ajustar posições.
--  * Com a fila ligada, a cada "intervalo" minutos a partir do "início"
--    mais um lote de "lote" pastas é liberado.
--  * O corretor dono de uma pasta liberada reserva ele mesmo a unidade
--    (vincula a pasta à unidade). Quem perdeu a vez continua podendo
--    reservar depois, entre as unidades que ainda estiverem disponíveis.
--  * Desligada, nada muda: só a equipe reserva, como antes.
-- Executar uma única vez no SQL Editor do Supabase (projeto de testes).
-- =====================================================================

create table public.fila_config (
  id                 int primary key default 1 check (id = 1),
  ativa              boolean not null default false,
  inicio             timestamptz,
  lote               int not null default 10 check (lote between 1 and 500),
  intervalo_min      int not null default 30 check (intervalo_min between 1 and 1440),
  unidades_por_pasta int not null default 1 check (unidades_por_pasta between 1 and 20),
  atualizado_em      timestamptz not null default now(),
  atualizado_por     text
);
insert into public.fila_config default values;

create table public.fila_escolha (
  pasta_id     uuid primary key references public.pastas (id) on delete cascade,
  posicao      int not null check (posicao >= 1),
  incluida_em  timestamptz not null default now()
);
create index fila_escolha_posicao_idx on public.fila_escolha (posicao);

alter table public.fila_config enable row level security;
alter table public.fila_escolha enable row level security;
revoke all on public.fila_config, public.fila_escolha from anon, authenticated;
grant select on public.fila_config to authenticated;
grant select on public.fila_escolha to authenticated;
create policy fila_config_leitura on public.fila_config for select using (auth.uid() is not null);
create policy fila_escolha_leitura on public.fila_escolha for select using (public.eh_equipe());

-- Quantas posições já foram liberadas agora
create or replace function public.fila_liberadas() returns int
language sql stable security definer set search_path = public as $$
  select case when not f.ativa or f.inicio is null or now() < f.inicio then 0
              else f.lote * (floor(extract(epoch from now() - f.inicio) / (f.intervalo_min * 60))::int + 1) end
    from public.fila_config f where f.id = 1;
$$;

-- Momento em que uma posição é liberada
create or replace function public.fila_libera_em(p_posicao int) returns timestamptz
language sql stable security definer set search_path = public as $$
  select f.inicio + make_interval(mins => ((p_posicao - 1) / f.lote) * f.intervalo_min)
    from public.fila_config f where f.id = 1;
$$;

-- Situação geral (qualquer login): ligada, lote, próximo lote...
create or replace function public.fila_situacao() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ativa', f.ativa, 'inicio', f.inicio, 'lote', f.lote, 'intervalo_min', f.intervalo_min,
    'unidades_por_pasta', f.unidades_por_pasta,
    'liberadas', least(public.fila_liberadas(), (select count(*) from public.fila_escolha)),
    'total', (select count(*) from public.fila_escolha),
    'proximo_lote_em', case when f.ativa and f.inicio is not null then
        case when now() < f.inicio then f.inicio
             else f.inicio + make_interval(mins => (floor(extract(epoch from now() - f.inicio) / (f.intervalo_min * 60))::int + 1) * f.intervalo_min) end end,
    'agora', now())
  from public.fila_config f where f.id = 1;
$$;

-- Pastas da fila que o usuário enxerga (equipe: todas; imobiliária: as dela; corretor: as que criou)
create or replace function public.minha_fila() returns table (
  pasta_id uuid, codigo text, comprador text, imobiliaria text, corretor text, posicao int,
  liberada boolean, libera_em timestamptz, reservas int, unidades text[]
)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.codigo_aprovacao, p.codigo), p.comprador_nome, i.nome,
         coalesce(nullif(pf.nome, ''), p.criado_por), f.posicao,
         f.posicao <= public.fila_liberadas(), public.fila_libera_em(f.posicao),
         (select count(*)::int from public.negociacoes n where n.pasta_id = p.id and n.ativa),
         (select array_agg(u.numero order by u.numero) from public.negociacoes n join public.unidades u on u.id = n.unidade_id where n.pasta_id = p.id and n.ativa)
    from public.fila_escolha f
    join public.pastas p on p.id = f.pasta_id
    left join public.imobiliarias i on i.id = p.imobiliaria_id
    left join public.perfis pf on pf.user_id = p.criado_por_id
   where public.acesso_pasta(p.imobiliaria_id, p.criado_por_id)
   order by f.posicao;
$$;

-- Configurar (administrador)
create or replace function public.configurar_fila(p_ativa boolean, p_inicio timestamptz, p_lote int, p_intervalo int, p_unidades_por_pasta int default 1)
returns public.fila_config
language plpgsql security definer set search_path = public as $$
declare v public.fila_config;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_ativa and p_inicio is null then raise exception 'INICIO_OBRIGATORIO'; end if;
  update public.fila_config set ativa = p_ativa, inicio = p_inicio, lote = p_lote, intervalo_min = p_intervalo,
         unidades_por_pasta = coalesce(p_unidades_por_pasta, 1), atualizado_em = now(), atualizado_por = public.meu_email()
   where id = 1 returning * into v;
  return v;
end;
$$;

-- Montar / completar a fila: pastas aprovadas que ainda não estão nela, por ordem de submissão (PA)
create or replace function public.montar_fila() returns int
language plpgsql security definer set search_path = public as $$
declare v_ini int; v_n int;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select coalesce(max(posicao), 0) into v_ini from public.fila_escolha;
  insert into public.fila_escolha (pasta_id, posicao)
  select p.id, v_ini + row_number() over (order by p.submetida_em nulls last, p.codigo_aprovacao nulls last, p.criada_em)
    from public.pastas p
   where p.status = 'aprovada' and not exists (select 1 from public.fila_escolha f where f.pasta_id = p.id);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- Mover uma pasta para outra posição (as demais andam uma casa)
create or replace function public.mover_na_fila(p_pasta uuid, p_posicao int) returns void
language plpgsql security definer set search_path = public as $$
declare v_atual int; v_max int; v_nova int;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select posicao into v_atual from public.fila_escolha where pasta_id = p_pasta;
  if v_atual is null then raise exception 'PASTA_FORA_DA_FILA'; end if;
  select max(posicao) into v_max from public.fila_escolha;
  v_nova := greatest(1, least(p_posicao, v_max));
  if v_nova = v_atual then return; end if;
  if v_nova < v_atual then
    update public.fila_escolha set posicao = posicao + 1 where posicao >= v_nova and posicao < v_atual;
  else
    update public.fila_escolha set posicao = posicao - 1 where posicao > v_atual and posicao <= v_nova;
  end if;
  update public.fila_escolha set posicao = v_nova where pasta_id = p_pasta;
end;
$$;

create or replace function public.remover_da_fila(p_pasta uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_pos int;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  delete from public.fila_escolha where pasta_id = p_pasta returning posicao into v_pos;
  if v_pos is not null then update public.fila_escolha set posicao = posicao - 1 where posicao > v_pos; end if;
end;
$$;

-- Corretor (ou imobiliária) reserva a unidade com a pasta liberada
create or replace function public.reservar_pela_fila(p_pasta uuid, p_unidade uuid) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  f public.fila_config;
  p public.pastas;
  u public.unidades;
  v_pos int;
begin
  select * into f from public.fila_config where id = 1;
  if not f.ativa then raise exception 'FILA_DESLIGADA'; end if;
  select * into p from public.pastas where id = p_pasta;
  if not found or not public.acesso_pasta(p.imobiliaria_id, p.criado_por_id) then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if p.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
  select posicao into v_pos from public.fila_escolha where pasta_id = p_pasta;
  if v_pos is null then raise exception 'PASTA_FORA_DA_FILA'; end if;
  if v_pos > public.fila_liberadas() then
    raise exception 'PASTA_AINDA_NAO_LIBERADA' using hint = to_char(public.fila_libera_em(v_pos) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
  end if;
  if (select count(*) from public.negociacoes where pasta_id = p_pasta and ativa) >= f.unidades_por_pasta then
    raise exception 'LIMITE_DE_UNIDADES_DA_PASTA';
  end if;
  select * into u from public.unidades where id = p_unidade for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  if u.status <> 'disponivel' then raise exception 'UNIDADE_INDISPONIVEL' using hint = 'Outra pessoa reservou esta unidade agora há pouco.'; end if;

  perform set_config('espelho.sistema', 'sim', true);
  u := public.alterar_status(p_unidade, 'reservada', u.versao, null, null, null, null, null, null, p_pasta);
  perform set_config('espelho.sistema', '', true);
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Unidade reservada pela fila de escolha', jsonb_build_object('unidade', u.numero, 'posicao', v_pos), public.meu_email());
  return u;
end;
$$;

revoke all on function public.fila_liberadas(), public.fila_libera_em(int), public.fila_situacao(), public.minha_fila(),
  public.configurar_fila(boolean, timestamptz, int, int, int), public.montar_fila(), public.mover_na_fila(uuid, int),
  public.remover_da_fila(uuid), public.reservar_pela_fila(uuid, uuid) from public, anon;
grant execute on function public.fila_liberadas(), public.fila_libera_em(int), public.fila_situacao(), public.minha_fila(),
  public.configurar_fila(boolean, timestamptz, int, int, int), public.montar_fila(), public.mover_na_fila(uuid, int),
  public.remover_da_fila(uuid), public.reservar_pela_fila(uuid, uuid) to authenticated;
