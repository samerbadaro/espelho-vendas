\set ON_ERROR_STOP 0
-- treinamento de teste com limite 2 num horário futuro e um horário passado
insert into treinamentos (id, nome) values ('00000000-0000-0000-0000-000000000300', 'Treino teste');
insert into treinamento_horarios (id, treinamento_id, inicio, limite) values
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000000300', now() + interval '1 day', 2),
  ('00000000-0000-0000-0000-000000000302', '00000000-0000-0000-0000-000000000300', now() + interval '1 day 30 minutes', 25),
  ('00000000-0000-0000-0000-000000000303', '00000000-0000-0000-0000-000000000300', now() - interval '1 hour', 25);
do $$ begin
  raise notice '%  Agenda de 18 e 19/11 criada (34 horários)', case when (select count(*) from treinamento_horarios h join treinamentos t on t.id = h.treinamento_id where t.nome = 'Treinamento Duo Haus') = 34 then 'OK    ' else 'FALHOU' end;
  raise notice '%  Primeiro às 09:00 e último às 19:00 (Brasília)', case when (select min((inicio at time zone 'America/Sao_Paulo')::time) from treinamento_horarios h join treinamentos t on t.id=h.treinamento_id where t.nome='Treinamento Duo Haus') = '09:00' and (select max((inicio at time zone 'America/Sao_Paulo')::time) from treinamento_horarios h join treinamentos t on t.id=h.treinamento_id where t.nome='Treinamento Duo Haus') = '19:00' then 'OK    ' else 'FALHOU' end;
end $$;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ declare v treinamento_inscricoes; begin
  v := inscrever_treinamento('00000000-0000-0000-0000-000000000301');
  raise notice '%  Corretor se inscreve (nome e imobiliária vêm do cadastro)', case when v.user_id = '00000000-0000-0000-0000-0000000000c1' and v.imobiliaria is not null then 'OK    ' else 'FALHOU' end;
  begin perform inscrever_treinamento('00000000-0000-0000-0000-000000000302'); raise notice 'FALHOU  segunda inscrição';
  exception when others then raise notice '%  Só um horário por corretor (%)', case when sqlerrm = 'JA_INSCRITO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  begin perform inscrever_treinamento('00000000-0000-0000-0000-000000000303'); raise notice 'FALHOU  horário passado';
  exception when others then raise notice '%  Não inscreve em horário que já começou (%)', case when sqlerrm in ('HORARIO_JA_COMECOU','JA_INSCRITO') then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', false) \g /dev/null
do $$ begin perform inscrever_treinamento('00000000-0000-0000-0000-000000000301');
  raise notice '%  Segundo corretor ocupa a última vaga', case when (select inscritos from treinamento_vagas('00000000-0000-0000-0000-000000000300') where horario_id = '00000000-0000-0000-0000-000000000301') = 2 then 'OK    ' else 'FALHOU' end;
  raise notice '%  Corretor não vê nomes dos outros', case when (select count(*) from treinamento_inscricoes) = 1 then 'OK    ' else 'FALHOU' end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ begin
  begin perform inscrever_treinamento('00000000-0000-0000-0000-000000000301'); raise notice 'FALHOU  passou do limite';
  exception when others then raise notice '%  Horário lotado não aceita mais (%)', case when sqlerrm = 'HORARIO_LOTADO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  raise notice '%  Imobiliária vê os inscritos dela', case when (select count(*) from treinamento_inscricoes where horario_id = '00000000-0000-0000-0000-000000000301') = 2 then 'OK    ' else 'FALHOU' end;
  begin perform presenca_treinamento((select id from treinamento_inscricoes limit 1), true); raise notice 'FALHOU  imobiliária confirmou presença';
  exception when others then raise notice '%  Só a equipe confirma presença (%)', case when sqlerrm = 'SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
-- corretor 1 troca de horário: cancela e se inscreve em outro
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ declare v treinamento_inscricoes; begin
  perform cancelar_inscricao_treinamento((select id from treinamento_inscricoes where user_id = auth.uid()));
  v := inscrever_treinamento('00000000-0000-0000-0000-000000000302');
  raise notice '%  Cancela e se inscreve em outro horário', case when v.horario_id = '00000000-0000-0000-0000-000000000302' then 'OK    ' else 'FALHOU' end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', false) \g /dev/null
do $$ begin perform cancelar_inscricao_treinamento((select id from treinamento_inscricoes where user_id = '00000000-0000-0000-0000-0000000000c1' limit 1));
  raise notice 'FALHOU  cancelou a de outro';
exception when others then raise notice 'OK      Não cancela inscrição de outro (%)', sqlerrm; end $$;
-- equipe: inclui nome avulso, confirma presença
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare v treinamento_inscricoes; begin
  v := inscrever_treinamento('00000000-0000-0000-0000-000000000302', null, 'Pedro Avulso', 'Imob Externa');
  v := presenca_treinamento(v.id, true);
  raise notice '%  Equipe inclui na hora e confirma presença', case when v.presente and v.presenca_em is not null and v.imobiliaria = 'Imob Externa' then 'OK    ' else 'FALHOU' end;
  raise notice '%  Equipe vê todos os inscritos', case when (select count(*) from treinamento_inscricoes where treinamento_id = '00000000-0000-0000-0000-000000000300') = 3 then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
