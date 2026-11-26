-- Intermediação como documento do contrato
\set ON_ERROR_STOP 0
do $$ begin
  raise notice '%  contratos aceita o documento intermediacao', case when position('intermediacao' in pg_get_constraintdef((select oid from pg_constraint where conname = 'contratos_documento_check'))) > 0 then 'OK    ' else 'FALHOU' end;
  raise notice '%  e continua aceitando os demais', case when position('carta_proposta' in pg_get_constraintdef((select oid from pg_constraint where conname = 'contratos_documento_check'))) > 0
    and position('quadro_resumo' in pg_get_constraintdef((select oid from pg_constraint where conname = 'contratos_documento_check'))) > 0 then 'OK    ' else 'FALHOU' end;
end $$;
