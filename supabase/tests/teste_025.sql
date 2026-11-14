-- Meeting: editar participante (rodar depois de teste_020)
\set ON_ERROR_STOP 0
insert into recepcao_eventos (id, nome) values ('00000000-0000-0000-0000-000000000025', 'Evento 025');
insert into recepcao_participantes (evento_id, nome, imobiliaria, telefone) values ('00000000-0000-0000-0000-000000000025', 'Jo Silva', 'imob x', '64 9999');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$
declare p recepcao_participantes;
begin
  select * into p from recepcao_participantes where evento_id = '00000000-0000-0000-0000-000000000025';
  p := editar_participante(p.id, '  João   da Silva ', ' Imob  X ', '(64) 99999-1111');
  raise notice '%  Editar ajusta nome, imobiliária e telefone sem confirmar', case when p.nome='João da Silva' and p.imobiliaria='Imob X' and p.telefone='64999991111' and not p.presente then 'OK    ' else 'FALHOU' end;
  p := editar_participante(p.id, 'João da Silva', null, null, true);
  raise notice '%  Salvar e confirmar marca presença', case when p.presente and p.chegada_em is not null and p.imobiliaria is null then 'OK    ' else 'FALHOU' end;
  begin perform editar_participante(p.id, 'Jo'); raise notice 'FALHOU  nome curto';
  exception when others then raise notice '%  Nome curto é recusado (%)', case when sqlerrm='NOME_OBRIGATORIO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ begin
  perform editar_participante((select id from recepcao_participantes limit 1), 'Fulano de Tal');
  raise notice 'FALHOU  imobiliária editou';
exception when others then raise notice '%  Só a equipe edita (%)', case when sqlerrm='SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end $$;
reset role;
