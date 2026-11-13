-- Status Permutante (rodar depois de teste_014.sql)
\set ON_ERROR_STOP 0
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare u unidades; p uuid := (select id from pastas where comprador_cpf='12345678901');
  un uuid := (select id from unidades where numero='1501'); begin
  u := alterar_status(un, 'permutante', (select versao from unidades where id=un), 'Permuta do terreno');
  raise notice '%  Unidade disponível vira permutante', case when u.status='permutante' then 'OK    ' else 'FALHOU' end;
  begin perform mover_etapa(p, 'reserva', un); raise notice 'FALHOU  funil não pega permutante';
  exception when others then raise notice '%  Funil não reserva unidade permutante (%)', case when sqlerrm='UNIDADE_OCUPADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  u := alterar_status(un, 'disponivel', u.versao);
  raise notice '%  Permutante volta para disponível sem motivo, como bloqueada', case when u.status='disponivel' then 'OK    ' else 'FALHOU' end;
  -- unidade em negociação virando permutante pede motivo e encerra a negociação
  u := alterar_status(un, 'reservada', u.versao, p_pasta => p);
  begin perform alterar_status(un, 'permutante', u.versao); raise notice 'FALHOU  permutante sem motivo';
  exception when others then raise notice '%  Negociação para permutante exige motivo (%)', case when sqlerrm='MOTIVO_OBRIGATORIO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  u := alterar_status(un, 'permutante', u.versao, 'Unidade entrou na permuta');
  raise notice '%  Negociação encerrada e unidade fora da pasta', case when u.status='permutante'
    and not exists(select 1 from negociacoes where unidade_id=un and ativa)
    and coalesce((select unidades_numeros from pastas where id=p), '') not like '%1501%' then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
