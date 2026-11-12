-- Testes da 008 (rodar depois de testes_pastas.sql no mesmo banco)
\set ON_ERROR_STOP 0
\pset tuples_only on
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000e', false) \g /dev/null
do $$ begin perform registrar_visualizacao((select id from documentos limit 1));
  raise notice 'FALHOU  B não pode visualizar documento da A';
exception when others then raise notice 'OK      B não pode visualizar documento da A (%)', sqlerrm; end $$;
do $$ begin perform indicadores(); raise notice 'FALHOU  Imobiliária não vê indicadores';
exception when others then raise notice 'OK      Imobiliária não vê indicadores'; end $$;
do $$ declare n int; begin update config set cor_primaria='#000000'; get diagnostics n=row_count;
  raise notice '%  Imobiliária não altera a marca', case when n=0 then 'OK    ' else 'FALHOU' end;
exception when others then raise notice 'OK      Imobiliária não altera a marca'; end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ declare c text; begin c := registrar_visualizacao((select id from documentos where nome_arquivo='pix.pdf' limit 1));
  raise notice '%  A visualiza o próprio documento e fica registrado', case when c like 'aaaaaaaa%' and exists(select 1 from historico_pastas where acao='Documento visualizado' and usuario_email='imob-a@teste') then 'OK    ' else 'FALHOU' end;
exception when others then raise notice 'FALHOU  A visualiza: %', sqlerrm; end $$;
do $$ begin perform 1 from storage.objects where bucket_id='documentos';
  raise notice '%  A não lê arquivos direto no armazenamento', case when (select count(*) from storage.objects where bucket_id='documentos')=0 then 'OK    ' else 'FALHOU' end; end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ declare n int; begin update config set cor_destaque='#123456', modulo_pastas=false; get diagnostics n=row_count;
  raise notice '%  Admin altera a marca e os módulos', case when n=1 then 'OK    ' else 'FALHOU' end; end $$;
do $$ declare j jsonb; begin j := indicadores();
  raise notice '%  Admin vê indicadores (%)', case when (j->'unidades'->>'disponivel') is not null then 'OK    ' else 'FALHOU' end, j; end $$;
reset role;
update config set cor_destaque='#94874A', modulo_pastas=true;
