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
