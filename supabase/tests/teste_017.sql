-- Rodadas de negócios (rodar depois dos outros testes)
\set ON_ERROR_STOP 0
create temp table rid (k text primary key, v uuid);
grant all on rid to authenticated;
set role authenticated;

-- Administrador cria duas rodadas: uma só para a Imobiliária A (limite 2), outra para todas
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
insert into rid select 'so_a', (salvar_rodada(null, 'Rodada Imobiliária A', now() + interval '10 days', 'Stand', null, 2, true, false,
  array['aaaaaaaa-0000-0000-0000-000000000001'::uuid])).id;
insert into rid select 'todas', (salvar_rodada(null, 'Rodada geral', now() + interval '11 days', null, null, 25, true, true, null)).id;
do $$ begin perform salvar_rodada(null, 'Sem imobiliária', now(), null, null, 25, true, false, '{}');
  raise notice 'FALHOU  rodada restrita sem imobiliária';
exception when others then raise notice '%  Rodada restrita exige imobiliárias (%)', case when sqlerrm='IMOBILIARIAS_OBRIGATORIAS' then 'OK    ' else 'FALHOU' end, sqlerrm; end $$;

-- Sec. Vendas não cria rodada
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ begin perform salvar_rodada(null, 'Teste vendas', now(), null, null, 25, true, true, null);
  raise notice 'FALHOU  vendas cria rodada';
exception when others then raise notice '%  Só o administrador cria rodada (%)', case when sqlerrm='SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end $$;

-- Imobiliária B não vê a rodada restrita, vê a geral
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000e', false) \g /dev/null
do $$ begin
  raise notice '%  Imobiliária B vê só a rodada geral', case when (select count(*) from rodadas)=1
    and (select nome from rodadas)='Rodada geral' then 'OK    ' else 'FALHOU' end;
  begin perform confirmar_cliente_rodada((select v from rid where k='so_a'), 'Cliente B', 2);
    raise notice 'FALHOU  B confirma na rodada de A';
  exception when others then raise notice '%  Imobiliária B não confirma na rodada restrita (%)', case when sqlerrm='RODADA_NAO_ENCONTRADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;

-- Corretor 1 confirma; mesmo cliente de novo é barrado; corretor 2 lota a rodada
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ declare i rodada_inscricoes; begin
  i := confirmar_cliente_rodada((select v from rid where k='so_a'), 'João  da Silva', 3, '64999990000');
  raise notice '%  Corretor confirma cliente com 3 pessoas', case when i.pessoas=3 and i.cliente_nome='João da Silva'
    and i.imobiliaria_id='aaaaaaaa-0000-0000-0000-000000000001' then 'OK    ' else 'FALHOU' end;
  begin perform confirmar_cliente_rodada((select v from rid where k='so_a'), 'joão da silva', 1);
    raise notice 'FALHOU  cliente duplicado';
  exception when others then raise notice '%  Mesmo cliente não é confirmado duas vezes (%)', case when sqlerrm='CLIENTE_JA_CONFIRMADO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  begin perform confirmar_cliente_rodada((select v from rid where k='so_a'), 'Maria', 0);
    raise notice 'FALHOU  zero pessoas';
  exception when others then raise notice '%  Quantidade de pessoas precisa ser 1 ou mais (%)', case when sqlerrm='PESSOAS_INVALIDO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', false) \g /dev/null
do $$ begin
  perform confirmar_cliente_rodada((select v from rid where k='so_a'), 'Ana Paula', 2);
  raise notice '%  Corretor 2 vê só o cliente dele', case when (select count(*) from rodada_inscricoes)=1 then 'OK    ' else 'FALHOU' end;
  raise notice '%  Vagas: 2 clientes, 5 pessoas', case when exists(select 1 from rodadas_vagas() where rodada_id=(select v from rid where k='so_a') and clientes=2 and pessoas=5) then 'OK    ' else 'FALHOU' end;
  begin perform confirmar_cliente_rodada((select v from rid where k='so_a'), 'Carlos Lima', 1);
    raise notice 'FALHOU  passou do limite';
  exception when others then raise notice '%  Rodada lotada não aceita mais clientes (%)', case when sqlerrm='RODADA_LOTADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  begin perform cancelar_cliente_rodada((select id from rodada_inscricoes where cliente_nome='João da Silva'));
    raise notice 'FALHOU  cancelou cliente de outro';
  exception when others then raise notice '%  Corretor não cancela cliente de outro corretor (%)', case when sqlerrm='INSCRICAO_NAO_ENCONTRADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;

-- Imobiliária A (gestora) vê os dois clientes da equipe
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ begin
  raise notice '%  Imobiliária vê os clientes de todos os seus corretores', case when (select count(*) from rodada_inscricoes)=2 then 'OK    ' else 'FALHOU' end;
end $$;

-- Administrador não pode baixar o limite abaixo dos confirmados; aumenta para 3
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ declare r rodadas; begin
  begin perform salvar_rodada((select v from rid where k='so_a'), 'Rodada Imobiliária A', now() + interval '10 days', 'Stand', null, 1, true, false, array['aaaaaaaa-0000-0000-0000-000000000001'::uuid]);
    raise notice 'FALHOU  limite abaixo';
  exception when others then raise notice '%  Limite não fica abaixo dos confirmados (%)', case when sqlerrm='LIMITE_ABAIXO_DOS_CONFIRMADOS' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  r := salvar_rodada((select v from rid where k='so_a'), 'Rodada Imobiliária A', now() + interval '10 days', 'Stand', null, 3, true, false, array['aaaaaaaa-0000-0000-0000-000000000001'::uuid]);
  raise notice '%  Administrador aumenta o limite para 3', case when r.limite_clientes=3 then 'OK    ' else 'FALHOU' end;
end $$;

-- Com o limite maior, o corretor 1 confirma mais um; depois cancela e a vaga volta
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ declare i rodada_inscricoes; begin
  i := confirmar_cliente_rodada((select v from rid where k='so_a'), 'Carlos Lima', 1);
  raise notice '%  Nova vaga aceita o cliente', case when i.id is not null then 'OK    ' else 'FALHOU' end;
  perform cancelar_cliente_rodada(i.id);
  raise notice '%  Cancelar devolve a vaga', case when exists(select 1 from rodadas_vagas() where rodada_id=(select v from rid where k='so_a') and clientes=2) then 'OK    ' else 'FALHOU' end;
  i := editar_cliente_rodada((select id from rodada_inscricoes where cliente_nome='João da Silva'), 'João da Silva', 4, null, 'Vem com os filhos');
  raise notice '%  Corretor altera a quantidade de pessoas', case when i.pessoas=4 then 'OK    ' else 'FALHOU' end;
end $$;

-- Inscrições encerradas: corretor não confirma, Sec. Vendas ainda consegue
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
select salvar_rodada((select v from rid where k='so_a'), 'Rodada Imobiliária A', now() + interval '10 days', 'Stand', null, 3, false, false, array['aaaaaaaa-0000-0000-0000-000000000001'::uuid]) \g /dev/null
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ begin perform confirmar_cliente_rodada((select v from rid where k='so_a'), 'Pedro Alves', 1);
  raise notice 'FALHOU  confirmou com inscrições encerradas';
exception when others then raise notice '%  Inscrições encerradas bloqueiam o corretor (%)', case when sqlerrm='INSCRICOES_ENCERRADAS' then 'OK    ' else 'FALHOU' end, sqlerrm; end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare i rodada_inscricoes; begin
  i := confirmar_cliente_rodada((select v from rid where k='so_a'), 'Pedro Alves', 1, null, null, 'aaaaaaaa-0000-0000-0000-000000000001');
  raise notice '%  Sec. Vendas confirma mesmo com inscrições encerradas', case when i.id is not null then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
