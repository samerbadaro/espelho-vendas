-- =====================================================================
-- 029 — Meeting: inscrições (como o Sympla) + confirmação de presença
--  * Cada meeting tem um link público de inscrição (/meeting/<endereço>).
--  * A inscrição pede nome completo, e-mail, celular e imobiliária.
--  * Não aceita e-mail nem celular repetidos no mesmo meeting.
--  * Quem se inscreve já aparece na confirmação de presença (recepção).
--  * A equipe cria e edita os meetings, abre/fecha inscrições, define
--    vagas e encerramento, e vê/exporta os inscritos.
-- Executar uma única vez no SQL Editor do Supabase (projeto de testes).
-- =====================================================================

alter table public.recepcao_eventos
  add column if not exists slug               text,
  add column if not exists local              text,
  add column if not exists descricao          text,
  add column if not exists inscricoes_abertas boolean not null default false,
  add column if not exists vagas              int check (vagas is null or vagas > 0),
  add column if not exists encerra_em         timestamptz,
  add column if not exists atualizado_em      timestamptz not null default now();
update public.recepcao_eventos set slug = substr(replace(id::text, '-', ''), 1, 10) where slug is null;
alter table public.recepcao_eventos alter column slug set default substr(md5(random()::text || clock_timestamp()::text), 1, 10);
alter table public.recepcao_eventos alter column slug set not null;
create unique index if not exists recepcao_eventos_slug_idx on public.recepcao_eventos (slug);
alter table public.recepcao_eventos add constraint recepcao_eventos_slug_formato check (slug ~ '^[a-z0-9][a-z0-9-]{2,59}$');

alter table public.recepcao_participantes
  add column if not exists origem      text not null default 'lista' check (origem in ('lista', 'inscricao', 'na_hora')),
  add column if not exists codigo      text,
  add column if not exists inscrito_em timestamptz;

-- e-mail em minúsculas e telefone só com dígitos (sem o 55 do Brasil)
create or replace function public.normalizar_email(p text) returns text language sql immutable as $$
  select nullif(lower(trim(coalesce(p, ''))), '');
$$;
create or replace function public.normalizar_telefone(p text) returns text language sql immutable as $$
  select nullif(case when length(d) in (12, 13) and d like '55%' then substr(d, 3) else d end, '')
    from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x;
$$;
update public.recepcao_participantes set email = public.normalizar_email(email), telefone = public.normalizar_telefone(telefone);

-- Inscrições: não aceita e-mail nem telefone repetidos no mesmo meeting. A função de inscrição
-- confere contra todos da lista; os índices garantem isso mesmo com duas inscrições simultâneas.
-- (Listas importadas pela equipe podem repetir telefone, ex.: o fixo da imobiliária.)
create unique index if not exists recepcao_participantes_email_unico on public.recepcao_participantes (evento_id, email) where email is not null and origem = 'inscricao';
create unique index if not exists recepcao_participantes_telefone_unico on public.recepcao_participantes (evento_id, telefone) where telefone is not null and origem = 'inscricao';

create or replace function public.recepcao_participantes_normalizar() returns trigger
language plpgsql as $$
begin
  new.email := public.normalizar_email(new.email);
  new.telefone := public.normalizar_telefone(new.telefone);
  new.nome := regexp_replace(trim(new.nome), '\s+', ' ', 'g');
  return new;
end;
$$;
drop trigger if exists recepcao_participantes_normalizar on public.recepcao_participantes;
create trigger recepcao_participantes_normalizar before insert or update on public.recepcao_participantes
  for each row execute function public.recepcao_participantes_normalizar();

-- ---------------------------------------------------------------------
-- Página pública (sem login)
-- ---------------------------------------------------------------------
create or replace function public.meeting_publico(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nome', e.nome, 'data_hora', e.data_hora, 'local', e.local, 'descricao', e.descricao,
    'abertas', e.inscricoes_abertas and (e.encerra_em is null or now() < e.encerra_em)
               and (e.vagas is null or (select count(*) from public.recepcao_participantes p where p.evento_id = e.id) < e.vagas),
    'motivo', case when not e.inscricoes_abertas or (e.encerra_em is not null and now() >= e.encerra_em) then 'encerradas'
                   when e.vagas is not null and (select count(*) from public.recepcao_participantes p where p.evento_id = e.id) >= e.vagas then 'esgotadas' end,
    'vagas_restantes', case when e.vagas is null then null
                            else greatest(0, e.vagas - (select count(*) from public.recepcao_participantes p where p.evento_id = e.id)) end)
  from public.recepcao_eventos e where e.slug = lower(trim(p_slug));
$$;

create or replace function public.inscrever_meeting(p_slug text, p_nome text, p_email text, p_telefone text, p_imobiliaria text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e        public.recepcao_eventos;
  v_nome   text := regexp_replace(trim(coalesce(p_nome, '')), '\s+', ' ', 'g');
  v_email  text := public.normalizar_email(p_email);
  v_tel    text := public.normalizar_telefone(p_telefone);
  v_codigo text;
  v_n      int;
begin
  select * into e from public.recepcao_eventos where slug = lower(trim(p_slug)) for update;
  if not found then raise exception 'MEETING_NAO_ENCONTRADO'; end if;
  if not e.inscricoes_abertas or (e.encerra_em is not null and now() >= e.encerra_em) then raise exception 'INSCRICOES_ENCERRADAS'; end if;
  if e.vagas is not null then
    select count(*) into v_n from public.recepcao_participantes where evento_id = e.id;
    if v_n >= e.vagas then raise exception 'VAGAS_ESGOTADAS'; end if;
  end if;
  if length(v_nome) < 5 or position(' ' in v_nome) = 0 then raise exception 'NOME_COMPLETO_OBRIGATORIO'; end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'EMAIL_INVALIDO'; end if;
  if v_tel is null or length(v_tel) not in (10, 11) then raise exception 'TELEFONE_INVALIDO'; end if;
  if exists (select 1 from public.recepcao_participantes where evento_id = e.id and email = v_email) then raise exception 'EMAIL_JA_INSCRITO'; end if;
  if exists (select 1 from public.recepcao_participantes where evento_id = e.id and telefone = v_tel) then raise exception 'TELEFONE_JA_INSCRITO'; end if;

  v_codigo := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
  insert into public.recepcao_participantes (evento_id, nome, email, telefone, imobiliaria, origem, codigo, inscrito_em)
  values (e.id, v_nome, v_email, v_tel, nullif(trim(coalesce(p_imobiliaria, '')), ''), 'inscricao', v_codigo, now());
  return jsonb_build_object('codigo', v_codigo, 'nome', v_nome, 'meeting', e.nome, 'data_hora', e.data_hora, 'local', e.local);
exception when unique_violation then
  -- duas inscrições iguais ao mesmo tempo
  if sqlerrm like '%email%' then raise exception 'EMAIL_JA_INSCRITO'; else raise exception 'TELEFONE_JA_INSCRITO'; end if;
end;
$$;

revoke all on function public.meeting_publico(text), public.inscrever_meeting(text, text, text, text, text) from public;
grant execute on function public.meeting_publico(text), public.inscrever_meeting(text, text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Gestão (equipe)
-- ---------------------------------------------------------------------
create or replace function public.salvar_meeting(
  p_id uuid, p_nome text, p_slug text, p_data_hora timestamptz default null, p_local text default null,
  p_descricao text default null, p_abertas boolean default false, p_vagas int default null, p_encerra_em timestamptz default null
) returns public.recepcao_eventos
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_eventos; v_slug text := lower(trim(coalesce(p_slug, '')));
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
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

create or replace function public.remover_inscricao(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  delete from public.recepcao_participantes where id = p_id;
end;
$$;

-- Incluir na hora: se o celular já é de uma inscrição, a pessoa já está na lista (busque pelo nome)
create or replace function public.incluir_participante(p_evento uuid, p_nome text, p_imobiliaria text default null, p_telefone text default null)
returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes; v_tel text := public.normalizar_telefone(p_telefone);
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if v_tel is not null and exists (select 1 from public.recepcao_participantes where evento_id = p_evento and telefone = v_tel and origem = 'inscricao') then
    raise exception 'TELEFONE_JA_INSCRITO';
  end if;
  insert into public.recepcao_participantes (evento_id, nome, imobiliaria, telefone, presente, chegada_em, confirmado_por, incluido_na_hora, origem)
  values (p_evento, p_nome, nullif(trim(p_imobiliaria), ''), v_tel, true, now(), public.meu_email(), true, 'na_hora')
  returning * into v;
  return v;
end;
$$;

revoke all on function public.salvar_meeting(uuid, text, text, timestamptz, text, text, boolean, int, timestamptz),
  public.remover_inscricao(uuid) from public, anon;
grant execute on function public.salvar_meeting(uuid, text, text, timestamptz, text, text, boolean, int, timestamptz),
  public.remover_inscricao(uuid) to authenticated;
revoke all on function public.incluir_participante(uuid, text, text, text) from public, anon;
grant execute on function public.incluir_participante(uuid, text, text, text) to authenticated;
