-- Funil de vendas e download (rodar depois de testes_pastas.sql). A pasta da imobiliária A termina aprovada.
\set ON_ERROR_STOP 0
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ begin perform mover_etapa((select id from pastas where comprador_cpf='12345678901'), 'reserva'); raise notice 'FALHOU  Imobiliária não move etapa';
exception when others then raise notice 'OK      Imobiliária não move etapa (%)', sqlerrm; end $$;
do $$ begin perform registrar_download((select id from pastas where comprador_cpf='12345678901')); raise notice 'FALHOU  Imobiliária não usa download completo';
exception when others then raise notice 'OK      Imobiliária não usa download completo (%)', sqlerrm; end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare p pastas; begin
  p := mover_etapa((select id from pastas where comprador_cpf='12345678901'), 'contrato_confeccao', (select id from unidades where numero='1205'));
  raise notice '%  Equipe move pasta aprovada para Contrato em confecção', case when p.etapa_venda='contrato_confeccao' and exists(select 1 from historico_pastas where acao='Etapa da venda alterada') then 'OK    ' else 'FALHOU' end;
end $$;
do $$ begin perform mover_etapa((select id from pastas where comprador_cpf='22233344455'), 'reserva'); raise notice 'FALHOU  Pasta não aprovada não entra no funil';
exception when others then raise notice '%  Pasta não aprovada não entra no funil (%)', case when sqlerrm='PASTA_NAO_APROVADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end $$;
do $$ declare n int; s text; begin
  select count(*), string_agg(sigla||':'||split_part(nome_pessoa,' ',1), ', ') into n, s from registrar_download((select id from pastas where comprador_cpf='12345678901'));
  raise notice '%  Download lista os documentos atuais com sigla (% arquivos: %)', case when n=4 then 'OK    ' else 'FALHOU' end, n, s;
end $$;
reset role;
