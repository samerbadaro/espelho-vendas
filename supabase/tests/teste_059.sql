-- Tabelas de venda editáveis
\set ON_ERROR_STOP 0
do $$ begin
  raise notice '%  Visitante não salva tabela', case when not has_function_privilege('anon', 'public.salvar_tabela_venda(text,jsonb)', 'execute') then 'OK    ' else 'FALHOU' end;
end $$;
insert into tabelas_venda (nome) values ('TESTE 59') on conflict do nothing;

-- corretor não pode
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ begin
  perform salvar_tabela_venda('TESTE 59', '[{"periodicidade":"Sinal","qtd":1,"percentual":1,"base":"venda","meses":0}]');
  raise notice 'FALHOU  corretor salvou tabela';
exception when others then raise notice '%  Corretor não edita tabela (%)', case when sqlerrm = 'SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end $$;
reset role;

-- administrador
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$
declare n int;
begin
  begin perform salvar_tabela_venda('TESTE 59', '[{"periodicidade":"Sinal","qtd":1,"percentual":0.5,"base":"venda","meses":0}]'); raise notice 'FALHOU  aceitou soma 50%%';
  exception when others then raise notice '%  Soma diferente de 100%% é recusada', case when sqlerrm = 'TABELA_SOMA_INVALIDA' then 'OK    ' else 'FALHOU' end; end;
  n := salvar_tabela_venda('TESTE 59', '[{"rotulo":"Ato","periodicidade":"Sinal","qtd":1,"percentual":0.1,"base":"venda","meses":0},
    {"rotulo":"Única","periodicidade":"Unica","qtd":1,"percentual":0.2,"base":"entrega","meses":-12},
    {"rotulo":"Financiamento","periodicidade":"Financiamento","qtd":1,"percentual":0.7,"base":"entrega","meses":1}]');
  raise notice '%  Administrador salva a tabela inteira', case when n = 3 and (select count(*) from tabelas_series where tabela = 'TESTE 59') = 3
    and (select meses from tabelas_series where tabela = 'TESTE 59' and periodicidade = 'Unica') = -12 then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
delete from tabelas_venda where nome = 'TESTE 59';
