-- Um envelope ativo por unidade (rodar depois do teste_053)
\set ON_ERROR_STOP 0
do $$ begin
  raise notice '%  Envelope ativo é único por proposta', case when (select indexdef from pg_indexes where indexname = 'envelopes_um_ativo') like '%(proposta_id)%' then 'OK    ' else 'FALHOU' end;
end $$;
