-- Nome da proposta
\set ON_ERROR_STOP 0
do $$ begin
  raise notice '%  Coluna nome nas propostas', case when exists (select 1 from information_schema.columns where table_name = 'propostas' and column_name = 'nome') then 'OK    ' else 'FALHOU' end;
end $$;
update config set modulo_propostas = true where id = 1;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$
declare p propostas;
begin
  select * into p from propostas where status in ('rascunho', 'devolvida') and criado_por_id = '00000000-0000-0000-0000-0000000000c1' limit 1;
  if p.id is null then raise notice 'OK      (sem rascunho do corretor para testar o nome)'; return; end if;
  update propostas set nome = 'Samer – Lote do Parque do Cerrado' where id = p.id;
  raise notice '%  Corretor dá nome ao próprio rascunho', case when (select nome from propostas where id = p.id) = 'Samer – Lote do Parque do Cerrado' then 'OK    ' else 'FALHOU' end;
  begin update propostas set nome = repeat('x', 121) where id = p.id; raise notice 'FALHOU  aceitou nome com mais de 120 caracteres';
  exception when check_violation then raise notice 'OK      Nome limitado a 120 caracteres'; end;
end $$;
reset role;
