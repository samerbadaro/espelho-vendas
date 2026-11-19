-- Convite da rodada (rodar depois do teste_017)
\set ON_ERROR_STOP 0
create temp table _r as
  select rodada_id as id from rodada_inscricoes
   where corretor_id = '00000000-0000-0000-0000-0000000000c1' and not cancelada
   group by rodada_id limit 1;
-- o corretor 2 fica sem cliente nesta rodada durante o teste
create temp table _c2 as select id from rodada_inscricoes where rodada_id = (select id from _r) and corretor_id = '00000000-0000-0000-0000-0000000000c2' and not cancelada;
update rodada_inscricoes set cancelada = true where id in (select id from _c2);
grant select on _r to authenticated;
select count(*) as rodada_para_teste from _r;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ declare r uuid := (select id from _r); v text; begin
  insert into storage.objects (bucket_id, name) values ('rodadas', r || '/convite.png');
  v := definir_convite_rodada(r, r || '/convite.png', 'convite.png', 'image/png');
  raise notice '%  Administrador anexa o convite', case when (select convite_caminho from rodadas where id = r) = r || '/convite.png' then 'OK    ' else 'FALHOU' end;
  begin perform definir_convite_rodada(r, 'outra-pasta/x.png', 'x.png', 'image/png'); raise notice 'FALHOU  aceitou caminho de outra rodada';
  exception when others then raise notice '%  Convite precisa estar na pasta da própria rodada', case when sqlerrm = 'CAMINHO_INVALIDO' then 'OK    ' else 'FALHOU' end; end;
end $$;
reset role;

do $$ declare u text; n int; r uuid := (select id from _r);
begin
  foreach u in array array['0000000000c1', '00000000000d', '0000000000c2', '00000000000e', '00000000000b'] loop
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-' || u, false);
    execute 'set local role authenticated';
    select count(*) into n from storage.objects where bucket_id = 'rodadas';
    execute 'reset role';
    raise notice '%  % baixa o convite? %', case when (n = 1) = (u in ('0000000000c1', '00000000000d', '00000000000b')) then 'OK    ' else 'FALHOU' end,
      case u when '0000000000c1' then 'Corretor com cliente confirmado' when '00000000000d' then 'Imobiliária do corretor'
             when '0000000000c2' then 'Corretor sem cliente nesta rodada' when '00000000000e' then 'Outra imobiliária' else 'Sec. Vendas' end,
      case when n = 1 then 'sim' else 'não' end;
  end loop;
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ declare r uuid := (select id from _r); begin
  begin insert into storage.objects (bucket_id, name) values ('rodadas', r || '/falso.png'); raise notice 'FALHOU  corretor enviou convite';
  exception when others then raise notice 'OK      Corretor não envia convite'; end;
  begin perform definir_convite_rodada(r, null); raise notice 'FALHOU  corretor tirou convite';
  exception when others then raise notice '%  Corretor não troca o convite', case when sqlerrm = 'SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end; end;
end $$;
reset role;

-- cancelou o único cliente: perde o acesso ao convite
update rodada_inscricoes set cancelada = true where rodada_id = (select id from _r) and corretor_id = '00000000-0000-0000-0000-0000000000c1';
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ declare n int; begin
  select count(*) into n from storage.objects where bucket_id = 'rodadas';
  raise notice '%  Sem cliente confirmado, o convite some', case when n = 0 then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
update rodada_inscricoes set cancelada = false where rodada_id = (select id from _r) and corretor_id = '00000000-0000-0000-0000-0000000000c1';
update rodada_inscricoes set cancelada = false where id in (select id from _c2);
