-- Treinamentos: administrador configura horários (rodar depois de teste_030)
\set ON_ERROR_STOP 0
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$
declare t uuid; n int; h uuid; total int;
begin
  select id into t from treinamentos where nome = 'Treinamento Duo Haus';
  select count(*) into total from treinamento_horarios where treinamento_id = t;
  n := adicionar_horarios_treinamento(t, '2026-11-20', '08:00', '10:00', 60, 15);
  raise notice '%  Cria 08h, 09h e 10h no dia 20 (%)', case when n = 3 then 'OK    ' else 'FALHOU' end, n;
  select count(*) into n from treinamento_horarios where treinamento_id = t and limite = 15
    and to_char(inicio at time zone 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI') in ('2026-11-20 08:00', '2026-11-20 09:00', '2026-11-20 10:00');
  raise notice '%  Horários no fuso de Brasília, com o limite escolhido', case when n = 3 then 'OK    ' else 'FALHOU' end;
  n := adicionar_horarios_treinamento(t, '2026-11-20', '08:00', '11:00', 30, 15);
  raise notice '%  Repetir não duplica: só cria os que faltam (%)', case when n = 4 then 'OK    ' else 'FALHOU' end, n;
  n := adicionar_horarios_treinamento(t, '2026-11-20', '16:00', null, 30, 10);
  raise notice '%  Um horário só, sem último horário', case when n = 1 then 'OK    ' else 'FALHOU' end;
  begin perform adicionar_horarios_treinamento(t, '2026-11-20', '12:00', '11:00', 30, 10); raise notice 'FALHOU  fim antes do início';
  exception when others then raise notice '%  Fim antes do início é recusado', case when sqlerrm = 'FIM_ANTES_DO_INICIO' then 'OK    ' else 'FALHOU' end; end;
  begin perform adicionar_horarios_treinamento(t, '2026-11-20', '12:00', '13:00', 30, 0); raise notice 'FALHOU  limite zero';
  exception when others then raise notice '%  Limite zero é recusado', case when sqlerrm = 'LIMITE_INVALIDO' then 'OK    ' else 'FALHOU' end; end;
  select id into h from treinamento_horarios where treinamento_id = t and inicio = '2026-11-20 16:00-03';
  perform remover_horario_treinamento(h);
  raise notice '%  Exclui horário sem inscritos', case when not exists (select 1 from treinamento_horarios where id = h) then 'OK    ' else 'FALHOU' end;
  select id into h from treinamento_horarios where treinamento_id = t and inicio = '2026-11-20 08:00-03';
  perform inscrever_treinamento(h, null, 'Fulano de Teste', 'Imob Teste');
  begin perform remover_horario_treinamento(h); raise notice 'FALHOU  excluiu horário com inscritos';
  exception when others then raise notice '%  Horário com inscritos não é excluído', case when sqlerrm = 'HORARIO_COM_INSCRITOS' then 'OK    ' else 'FALHOU' end; end;
  begin perform ajustar_limite_horario(h, 0); raise notice 'FALHOU  limite abaixo';
  exception when others then raise notice '%  Limite não fica abaixo dos inscritos', case when sqlerrm = 'LIMITE_ABAIXO_DOS_INSCRITOS' then 'OK    ' else 'FALHOU' end; end;
end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ begin
  perform adicionar_horarios_treinamento((select id from treinamentos limit 1), '2026-11-21', '08:00', '09:00', 30, 10);
  raise notice 'FALHOU  vendas criou horário';
exception when others then raise notice '%  Só o administrador configura (%)', case when sqlerrm = 'SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end $$;
reset role;
