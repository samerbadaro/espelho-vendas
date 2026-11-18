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
