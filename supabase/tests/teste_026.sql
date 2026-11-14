\set ON_ERROR_STOP 0
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ declare n int; begin
  perform registrar_simulacao('Poente', 'A partir de', 405576.26, 32, 68, 'png', '[{"s":"Mensais"}]');
  perform registrar_download_portal(null, 'zip', 'Todos (.zip)', 'book');
  select count(*) into n from simulacoes_log;
  raise notice '%  Imobiliária não lê os registros (viu %)', case when n = 0 then 'OK    ' else 'FALHOU' end, n;
  begin perform salvar_simulador('{}'); raise notice 'FALHOU  imobiliária salvou simulador';
  exception when others then raise notice '%  Só admin configura o simulador (%)', case when sqlerrm='SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare r simulacoes_log; d portal_downloads; c jsonb; begin
  select * into r from simulacoes_log order by id desc limit 1;
  raise notice '%  Simulação registrada com quem baixou (%, %)', case when r.captacao = 32 and r.papel = 'imobiliaria' and r.imobiliaria is not null then 'OK    ' else 'FALHOU' end, r.papel, r.imobiliaria;
  select * into d from portal_downloads order by id desc limit 1;
  raise notice '%  Download do portal registrado', case when d.modo = 'zip' and d.categoria = 'book' then 'OK    ' else 'FALHOU' end;
  select simulador into c from config where id = 1;
  raise notice '%  Configuração padrão do simulador', case when (c #>> '{nascente,captacao}')::int = 35 then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
