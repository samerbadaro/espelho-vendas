-- Funil ligado ao espelho (rodar depois de teste_012.sql). Pasta da Maria (CPF 12345678901) aprovada, com a 1205 em Proposta.
\set ON_ERROR_STOP 0
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare p uuid := (select id from pastas where comprador_cpf='12345678901'); u unidades;
  un uuid := (select id from unidades where numero='1001'); begin
  -- volta o card da 1205 para Pasta aprovada (libera a unidade)
  perform mover_etapa(p, 'aprovada', (select id from unidades where numero='1205'));
  raise notice '%  Voltar o card libera a 1205 e a pasta fica sem unidade', case when (select status from unidades where numero='1205')='disponivel'
    and (select unidades_numeros is null from pastas where id=p) then 'OK    ' else 'FALHOU' end;
  begin perform mover_etapa(p, 'reserva'); raise notice 'FALHOU  Sem unidade não reserva';
  exception when others then raise notice '%  Sem unidade, o funil pede a unidade (%)', case when sqlerrm='SEM_UNIDADE' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  perform mover_etapa(p, 'reserva', un);
  select * into u from unidades where id=un;
  raise notice '%  Reserva no funil: 1001 reservada, negociação ligada à pasta', case when u.status='reservada'
    and exists(select 1 from negociacoes where unidade_id=un and ativa and pasta_id=p and cliente='Maria Teste')
    and (select unidades_numeros from pastas where id=p)='1001' then 'OK    ' else 'FALHOU' end;
  perform mover_etapa(p, 'contrato_confeccao', un);
  raise notice '%  Contrato em confecção: Proposta recebida', case when (select status from unidades where id=un)='proposta' then 'OK    ' else 'FALHOU' end;
  perform mover_etapa(p, 'enviado_assinatura', un);
  raise notice '%  Enviado para assinatura: Contrato em assinatura', case when (select status from unidades where id=un)='contrato' then 'OK    ' else 'FALHOU' end;
  perform mover_etapa(p, 'assinado', un);
  raise notice '%  Assinado: Vendida, com histórico do espelho', case when (select status from unidades where id=un)='vendida'
    and (select count(*) from historico where numero='1001' and motivo like 'Funil de vendas%')=4 then 'OK    ' else 'FALHOU' end;
  -- unidade bloqueada não entra
  perform alterar_status((select id from unidades where numero='1002'), 'bloqueada', (select versao from unidades where numero='1002'), 'Teste');
  begin perform mover_etapa(p, 'reserva', (select id from unidades where numero='1002')); raise notice 'FALHOU  Não pega unidade bloqueada';
  exception when others then raise notice '%  Não pega unidade bloqueada (%)', case when sqlerrm='UNIDADE_OCUPADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  perform alterar_status((select id from unidades where numero='1002'), 'disponivel', (select versao from unidades where numero='1002'), null);
  -- segunda unidade para a mesma pasta, andando sozinha
  perform mover_etapa(p, 'reserva', (select id from unidades where numero='1002'));
  raise notice '%  Mesma pasta reserva a 1002 sem mexer na 1001', case when (select status from unidades where numero='1002')='reservada'
    and (select status from unidades where id=un)='vendida' and (select unidades_numeros from pastas where id=p)='1001, 1002' then 'OK    ' else 'FALHOU' end;
  -- liberar a 1002 no espelho: a pasta continua com a 1001
  perform alterar_status((select id from unidades where numero='1002'), 'disponivel', (select versao from unidades where numero='1002'), 'Cliente desistiu');
  raise notice '%  Liberar a 1002 mantém a 1001 na pasta', case when (select unidades_numeros from pastas where id=p)='1001' then 'OK    ' else 'FALHOU' end;
  -- devolve a 1001 para deixar a pasta livre para o próximo teste
  perform mover_etapa(p, 'aprovada', un);
end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ begin perform mover_etapa((select id from pastas where comprador_cpf='12345678901'), 'reserva', (select id from unidades where numero='1003'));
  raise notice 'FALHOU  Imobiliária não move funil';
exception when others then raise notice '%  Imobiliária não move funil (%)', case when sqlerrm='SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end $$;
reset role;
