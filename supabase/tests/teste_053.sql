-- Contrato por unidade (rodar depois do teste_046)
\set ON_ERROR_STOP 0
do $$ begin
  raise notice '%  Tabela de conferência por proposta com RLS', case when (select relrowsecurity from pg_class where oid = 'public.pagamento_contrato'::regclass) then 'OK    ' else 'FALHOU' end;
  raise notice '%  conferir_pagamento recebe a proposta', case when exists (select 1 from pg_proc where proname = 'conferir_pagamento' and pg_get_function_arguments(oid) like 'p_proposta uuid%') then 'OK    ' else 'FALHOU' end;
  raise notice '%  Visitante não chama conferir_pagamento', case when not has_function_privilege('anon', 'public.conferir_pagamento(uuid,jsonb,boolean)', 'execute') then 'OK    ' else 'FALHOU' end;
  raise notice '%  Toda proposta com documento emitido e conferência na pasta ganhou a conferência por proposta', case when not exists (
    select 1 from contratos c join dados_contrato d on d.pasta_id = c.pasta_id
     where d.pagamento_conferido_em is not null and c.proposta_id is not null
       and not exists (select 1 from pagamento_contrato p where p.proposta_id = c.proposta_id)) then 'OK    ' else 'FALHOU' end;
  raise notice '%  Emissão confere o pagamento da proposta (não da pasta)', case when position('pagamento_contrato' in pg_get_functiondef('public.registrar_contrato(uuid,uuid,text,text,text,jsonb,text)'::regprocedure)) > 0 then 'OK    ' else 'FALHOU' end;
end $$;
