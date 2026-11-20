-- Dados para contrato (rodar depois do teste_035, que aprova uma proposta da pasta 99900000028)
\set ON_ERROR_STOP 0
create temp table _p as select (select id from pastas where comprador_cpf = '99900000028') as aprovada,
                               (select id from pastas where comprador_cpf = '99900000029') as sem_proposta;
grant select on _p to authenticated;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ begin
  perform documentos_para_leitura((select aprovada from _p)); raise notice 'FALHOU  corretor leu documentos';
exception when others then raise notice '%  Corretor não usa a leitura (%)', case when sqlerrm = 'SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end $$;
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare v jsonb; d dados_contrato; begin
  begin perform documentos_para_leitura((select sem_proposta from _p)); raise notice 'FALHOU  leu pasta sem proposta aprovada';
  exception when others then raise notice '%  Sem proposta aprovada, não libera (%)', case when sqlerrm = 'PROPOSTA_NAO_APROVADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  v := documentos_para_leitura((select aprovada from _p));
  raise notice '%  Sec. Vendas recebe dados da pasta e % documento(s)', case when v -> 'pasta' ->> 'codigo' is not null and jsonb_typeof(v -> 'documentos') = 'array' then 'OK    ' else 'FALHOU' end, jsonb_array_length(v -> 'documentos');
  d := gravar_leitura_ia((select aprovada from _p), '{"comprador":{"nome":"Fulano","naturalidade":"Rio Verde/GO"}}', '{"comprador.nome":"RG"}', '[{"nivel":"atencao","texto":"teste"}]', 'modelo-teste', 3, 1000, 200);
  raise notice '%  Leitura gravada como rascunho', case when d.status = 'rascunho' and d.dados -> 'comprador' ->> 'naturalidade' = 'Rio Verde/GO' then 'OK    ' else 'FALHOU' end;
  d := salvar_dados_contrato((select aprovada from _p), '{"comprador":{"nome":"Fulano de Tal","naturalidade":"Rio Verde/GO"}}', true);
  raise notice '%  Sec. Vendas corrige e marca Conferido', case when d.status = 'conferido' and d.conferido_por is not null then 'OK    ' else 'FALHOU' end;
  d := gravar_leitura_ia((select aprovada from _p), '{"comprador":{"nome":"Outro"}}', '{}', '[]', 'modelo-teste', 3, 900, 150);
  raise notice '%  Ler de novo volta para rascunho', case when d.status = 'rascunho' and d.conferido_em is null then 'OK    ' else 'FALHOU' end;
  begin insert into dados_contrato (pasta_id) values ((select sem_proposta from _p)); raise notice 'FALHOU  gravou direto na tabela';
  exception when others then raise notice 'OK      Ninguém grava direto na tabela (só pelas funções)'; end;
end $$;
reset role;

do $$ declare u text; n int; begin
  foreach u in array array['00000000000d', '0000000000c1', '00000000000e', '00000000000b', '00000000000a'] loop
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-' || u, false);
    execute 'set local role authenticated';
    select count(*) into n from dados_contrato;
    execute 'reset role';
    raise notice '%  % vê os dados do contrato? %', case when (n > 0) = (u in ('00000000000b', '00000000000a')) then 'OK    ' else 'FALHOU' end,
      case u when '00000000000d' then 'Imobiliária' when '0000000000c1' then 'Corretor' when '00000000000e' then 'Outra imobiliária'
             when '00000000000b' then 'Sec. Vendas' else 'Administrador' end, case when n > 0 then 'sim' else 'não' end;
  end loop;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
  execute 'set local role authenticated';
  select count(*) into n from ia_leituras;
  execute 'reset role';
  raise notice '%  Registro de custos só para o administrador', case when n = 0 then 'OK    ' else 'FALHOU' end;
end $$;
