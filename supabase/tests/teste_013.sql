-- Funil ligado ao espelho (rodar depois de testes_pastas.sql). Pasta da A (CPF 12345678901) está aprovada e sem unidade.
\set ON_ERROR_STOP 0
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare p uuid := (select id from pastas where comprador_cpf='12345678901'); u unidades; begin
  -- volta a pasta para Pasta aprovada (libera a 1205 usada no teste_012)
  perform mover_etapa(p, 'aprovada');
  begin perform mover_etapa(p, 'reserva'); raise notice 'FALHOU  Sem unidade não reserva';
  exception when others then raise notice '%  Sem unidade, o funil pede a unidade (%)', case when sqlerrm='SEM_UNIDADE' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  perform mover_etapa(p, 'reserva', (select id from unidades where numero='1001'));
  select * into u from unidades where numero='1001';
  raise notice '%  Reserva no funil: 1001 fica reservada no espelho, negociação ligada à pasta', case when u.status='reservada'
    and exists(select 1 from negociacoes where unidade_id=u.id and ativa and pasta_id=p and cliente='Maria Teste') then 'OK    ' else 'FALHOU' end;
  perform mover_etapa(p, 'contrato_confeccao'); select * into u from unidades where numero='1001';
  raise notice '%  Contrato em confecção: Proposta recebida', case when u.status='proposta' then 'OK    ' else 'FALHOU' end;
  perform mover_etapa(p, 'enviado_assinatura'); select * into u from unidades where numero='1001';
  raise notice '%  Enviado para assinatura: Contrato em assinatura', case when u.status='contrato' then 'OK    ' else 'FALHOU' end;
  perform mover_etapa(p, 'assinado'); select * into u from unidades where numero='1001';
  raise notice '%  Assinado: Vendida, com histórico do espelho', case when u.status='vendida'
    and (select count(*) from historico where numero='1001' and motivo like 'Funil de vendas%')=4 then 'OK    ' else 'FALHOU' end;
  perform mover_etapa(p, 'aprovada'); select * into u from unidades where numero='1001';
  raise notice '%  Voltar para Pasta aprovada libera a 1001 e desvincula a pasta', case when u.status='disponivel'
    and (select unidade_id is null from pastas where id=p) and not exists(select 1 from negociacoes where unidade_id=u.id and ativa) then 'OK    ' else 'FALHOU' end;
  -- unidade ocupada por outra negociação
  perform alterar_status((select id from unidades where numero='1002'), 'bloqueada', (select versao from unidades where numero='1002'), 'Teste');
  begin perform mover_etapa(p, 'reserva', (select id from unidades where numero='1002')); raise notice 'FALHOU  Não pega unidade de outro cliente';
  exception when others then raise notice '%  Não pega unidade bloqueada (%)', case when sqlerrm='UNIDADE_OCUPADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  perform alterar_status((select id from unidades where numero='1002'), 'disponivel', (select versao from unidades where numero='1002'), null);
  perform mover_etapa(p, 'reserva', (select id from unidades where numero='1002'));
  raise notice '%  Depois de liberada, a 1002 é reservada pelo funil', case when exists(select 1 from negociacoes n join unidades un on un.id=n.unidade_id where un.numero='1002' and n.ativa and n.pasta_id=p) then 'OK    ' else 'FALHOU' end;
  -- espelho libera a unidade: pasta volta para Pasta aprovada
  perform alterar_status((select id from unidades where numero='1002'), 'disponivel', (select versao from unidades where numero='1002'), 'Cliente desistiu');
  raise notice '%  Liberar no espelho devolve a pasta para Pasta aprovada', case when (select etapa_venda='aprovada' and unidade_id is null from pastas where id=p) then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ begin perform mover_etapa((select id from pastas where comprador_cpf='12345678901'), 'reserva', (select id from unidades where numero='1003'));
  raise notice 'FALHOU  Imobiliária não move funil';
exception when others then raise notice 'OK      Imobiliária não move o funil nem o espelho (%)', sqlerrm; end $$;
reset role;
