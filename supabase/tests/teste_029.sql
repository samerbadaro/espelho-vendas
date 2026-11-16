\set ON_ERROR_STOP 0
set role authenticated;
-- imobiliária A (gestor d) cadastra uma pasta: fica sem corretor
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ declare v pastas; begin
  insert into pastas (imobiliaria_id, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao, estado_civil)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'Cliente 029', '99900000029', '64999990029', 't29@x.com', 'Teste', 'solteiro') returning * into v;
  raise notice '%  Pasta da imobiliária nasce sem corretor e guarda quem cadastrou', case when v.criado_por_id is null and v.cadastrado_por_id = '00000000-0000-0000-0000-00000000000d' then 'OK    ' else 'FALHOU' end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ begin
  raise notice '%  Corretor não vê pasta ainda não atribuída', case when not exists (select 1 from pastas where comprador_nome='Cliente 029') then 'OK    ' else 'FALHOU' end;
  begin perform atribuir_corretor((select id from pastas limit 1), '00000000-0000-0000-0000-0000000000c1');
    raise notice 'FALHOU  corretor atribuiu';
  exception when others then raise notice '%  Corretor não atribui pasta (%)', case when sqlerrm in ('SEM_PERMISSAO','PASTA_NAO_ENCONTRADA') then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
-- imobiliária atribui ao corretor c1
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ declare v pastas; begin
  v := atribuir_corretor((select id from pastas where comprador_nome='Cliente 029'), '00000000-0000-0000-0000-0000000000c1');
  raise notice '%  Imobiliária atribui ao seu corretor', case when v.criado_por_id = '00000000-0000-0000-0000-0000000000c1' then 'OK    ' else 'FALHOU' end;
  raise notice '%  Troca fica no histórico da pasta', case when exists (select 1 from historico_pastas where pasta_id = v.id and acao = 'Corretor responsável alterado') then 'OK    ' else 'FALHOU' end;
  begin perform atribuir_corretor(v.id, '00000000-0000-0000-0000-0000000000a0');
    raise notice 'FALHOU  atribuiu a quem não é corretor';
  exception when others then raise notice '%  Só aceita corretor da mesma imobiliária (%)', case when sqlerrm='CORRETOR_INVALIDO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ begin
  raise notice '%  Corretor atribuído passa a ver a pasta', case when exists (select 1 from pastas where comprador_nome='Cliente 029') then 'OK    ' else 'FALHOU' end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', false) \g /dev/null
do $$ begin
  raise notice '%  Outro corretor continua sem ver', case when not exists (select 1 from pastas where comprador_nome='Cliente 029') then 'OK    ' else 'FALHOU' end;
end $$;
-- corretor que cadastra é o dono
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', false) \g /dev/null
do $$ declare v pastas; begin
  insert into pastas (imobiliaria_id, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao, estado_civil)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'Cliente 029b', '99900000030', '64999990030', 't30@x.com', 'Teste', 'solteiro') returning * into v;
  raise notice '%  Pasta do corretor nasce dele', case when v.criado_por_id = '00000000-0000-0000-0000-0000000000c2' then 'OK    ' else 'FALHOU' end;
end $$;
-- imobiliária B não atribui pasta da A
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000e', false) \g /dev/null
do $$ begin perform atribuir_corretor((select id from pastas where comprador_nome='Cliente 029' limit 1), null);
  raise notice 'FALHOU  imobiliária B atribuiu';
exception when others then raise notice 'OK      Outra imobiliária não mexe (%)', sqlerrm; end $$;
reset role;
