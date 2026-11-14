-- =====================================================================
-- 020 — Recepção de eventos (check-in na entrada)
--  * Lista de convidados por evento; a recepção busca pelo nome e confirma
--    a chegada. Quem chegou sai da lista de espera e vai para "Confirmados".
--  * Só a equipe (Sec. Vendas e administrador) acessa.
--  * A lista de cada evento é carregada à parte (dados pessoais não ficam no repositório).
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create table public.recepcao_eventos (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  data_hora  timestamptz,
  criado_em  timestamptz not null default now()
);

create table public.recepcao_participantes (
  id              uuid primary key default gen_random_uuid(),
  evento_id       uuid not null references public.recepcao_eventos(id) on delete cascade,
  nome            text not null check (length(trim(nome)) >= 2),
  email           text,
  imobiliaria     text,
  telefone        text,
  presente        boolean not null default false,
  chegada_em      timestamptz,
  confirmado_por  text,
  incluido_na_hora boolean not null default false,
  criado_em       timestamptz not null default now()
);
create index recepcao_participantes_evento_idx on public.recepcao_participantes (evento_id);

alter table public.recepcao_eventos enable row level security;
alter table public.recepcao_participantes enable row level security;
create policy recepcao_eventos_leitura on public.recepcao_eventos for select using (public.eh_equipe());
create policy recepcao_participantes_leitura on public.recepcao_participantes for select using (public.eh_equipe());
grant select on public.recepcao_eventos, public.recepcao_participantes to authenticated;

-- Confirmar (ou desfazer) a chegada
create or replace function public.marcar_presenca(p_id uuid, p_presente boolean) returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.recepcao_participantes
     set presente = p_presente,
         chegada_em = case when p_presente then coalesce(chegada_em, now()) else null end,
         confirmado_por = case when p_presente then public.meu_email() else null end
   where id = p_id returning * into v;
  if not found then raise exception 'PARTICIPANTE_NAO_ENCONTRADO'; end if;
  return v;
end;
$$;

-- Incluir na hora quem não estava na lista (já entra como presente)
create or replace function public.incluir_participante(p_evento uuid, p_nome text, p_imobiliaria text default null, p_telefone text default null)
returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  insert into public.recepcao_participantes (evento_id, nome, imobiliaria, telefone, presente, chegada_em, confirmado_por, incluido_na_hora)
  values (p_evento, regexp_replace(trim(p_nome), '\s+', ' ', 'g'), nullif(trim(p_imobiliaria), ''),
          nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), ''), true, now(), public.meu_email(), true)
  returning * into v;
  return v;
end;
$$;

revoke all on function public.marcar_presenca(uuid, boolean) from public, anon;
revoke all on function public.incluir_participante(uuid, text, text, text) from public, anon;
grant execute on function public.marcar_presenca(uuid, boolean) to authenticated;
grant execute on function public.incluir_participante(uuid, text, text, text) to authenticated;

-- Várias pessoas na recepção veem a lista atualizada ao mesmo tempo
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.recepcao_participantes;
  end if;
end $$;
