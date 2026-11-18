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
