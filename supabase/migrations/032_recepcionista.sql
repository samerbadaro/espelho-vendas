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
