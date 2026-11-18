-- Recepcionista: só o Meeting (rodar depois de teste_025)
\set ON_ERROR_STOP 0
insert into auth.users (id, email) values ('00000000-0000-0000-0000-000000000032', 'recepcao@teste.com') on conflict do nothing;
insert into perfis (user_id, email, nome, papel) values ('00000000-0000-0000-0000-000000000032', 'recepcao@teste.com', 'Recepção', 'recepcao');
insert into recepcao_eventos (id, nome) values ('00000000-0000-0000-0000-000000000132', 'Evento 032');
insert into recepcao_participantes (evento_id, nome) values ('00000000-0000-0000-0000-000000000132', 'Maria Souza');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000032', false) \g /dev/null
do $$
declare p recepcao_participantes; n int;
begin
  select count(*) into n from recepcao_participantes where evento_id = '00000000-0000-0000-0000-000000000132';
  raise notice '%  Recepcionista vê a lista do Meeting', case when n = 1 then 'OK    ' else 'FALHOU' end;
  select * into p from recepcao_participantes where evento_id = '00000000-0000-0000-0000-000000000132';
  p := marcar_presenca(p.id, true);
  raise notice '%  Recepcionista confirma presença', case when p.presente and p.confirmado_por = 'recepcao@teste.com' then 'OK    ' else 'FALHOU' end;
  p := editar_participante(p.id, 'Maria de Souza', 'Imob Y', null);
  raise notice '%  Recepcionista edita convidado', case when p.nome = 'Maria de Souza' then 'OK    ' else 'FALHOU' end;
  p := incluir_participante('00000000-0000-0000-0000-000000000132', 'Pedro Alves', 'Nova Imob');
  raise notice '%  Recepcionista inclui na hora', case when p.presente and p.incluido_na_hora then 'OK    ' else 'FALHOU' end;
  select count(*) into n from pastas;
  raise notice '%  Recepcionista não vê pastas', case when n = 0 then 'OK    ' else 'FALHOU' end;
  select count(*) into n from rodada_inscricoes;
  raise notice '%  Recepcionista não vê rodadas', case when n = 0 then 'OK    ' else 'FALHOU' end;
  raise notice '%  Recepcionista não é equipe', case when not eh_equipe() then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ declare n int; begin
  select count(*) into n from recepcao_participantes;
  raise notice '%  Imobiliária continua sem ver o Meeting', case when n = 0 then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
