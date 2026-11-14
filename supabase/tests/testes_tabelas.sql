-- Testes do 110 (tabela de vendas com versões, captações e vigência). Banco local, depois de todas as migrações.
\set ON_ERROR_STOP 0
\pset tuples_only on
\set QUIET on
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000c1', 'admin-t@teste'), ('00000000-0000-0000-0000-0000000000c2', 'vendas-t@teste'), ('00000000-0000-0000-0000-0000000000c3', 'corretor-t@teste') on conflict do nothing;
insert into public.imobiliarias (id, nome) values ('cccccccc-2222-0000-0000-000000000001', 'Imob T') on conflict do nothing;
insert into public.perfis (user_id, email, nome, papel, imobiliaria_id) values
  ('00000000-0000-0000-0000-0000000000c1', 'admin-t@teste', 'Admin T', 'admin', null),
  ('00000000-0000-0000-0000-0000000000c2', 'vendas-t@teste', 'Vendas T', 'vendas', null),
  ('00000000-0000-0000-0000-0000000000c3', 'corretor-t@teste', 'Corretor T', 'corretor', 'cccccccc-2222-0000-0000-000000000001') on conflict do nothing;
set session_replication_role = replica;
insert into public.pastas (id, imobiliaria_id, criado_por_id, criado_por, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao, status, codigo_aprovacao, submetida_em)
values ('f1000000-0000-0000-0000-000000000001', 'cccccccc-2222-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000c3', 'corretor-t@teste', 'Tânia Teste', '52998224725', '64999991001', 't@t.com', 'Médica', 'aprovada', 'PA-951', now());
set session_replication_role = origin;

create temp table r (n serial, teste text, ok boolean);
create temp table ctx (k text primary key, v text);
grant all on r, ctx to anon, authenticated; grant usage on sequence r_n_seq to anon, authenticated;
create or replace function pg_temp.como(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false); $$;
create or replace function pg_temp.tenta(sql text, esperado text) returns boolean language plpgsql as $$
begin execute sql; return false; exception when others then return sqlerrm like '%' || esperado || '%'; end $$;
-- proposta igual à tabela (× f), com vencimentos a partir de hoje
create or replace function pg_temp.serie(p_numero text, f numeric, p_tab uuid default null) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('qtd', (e ->> 'qtd')::int, 'periodicidade', e ->> 'periodicidade',
           'vencimento', greatest(public.hoje_brasilia(), (e ->> 'vencimento')::date + 14)::text,
           'valor', ceil((e ->> 'valor')::numeric * f * 100) / 100))
    from jsonb_array_elements(public.series_tabela(coalesce(p_tab, public.tabela_vigente()), (select id from public.unidades where numero = p_numero))) e;
$$;
update tabelas_preco set vigente_desde = now() - interval '30 days';
insert into ctx select 'inicial', tabela_vigente()::text;

insert into r(teste, ok) select 'Tabela inicial vigente com as 173 unidades e 2 captações',
  (select situacao = 'vigente' and unidades = 173 from tabelas_preco_resumo) and (select count(*) = 2 from captacoes);
insert into r(teste, ok) select 'Preço da tabela inicial = R$/m² × peso (unidade 1704)',
  (select abs(preco_tabela_unidade(id) - 448429.59) < 0.01 from unidades where numero = '1704');
insert into r(teste, ok) select 'VPL da tabela igual ao da planilha (1704 = 344.568,65)',
  (select (pv_proposta(id, '[]') ->> 'vpl_tabela')::numeric = 344568.65 from unidades where numero = '1704');
insert into r(teste, ok) select 'Mensais automáticas: 44 em nov/26, 41 em fev/27',
  (select (series_tabela(tabela_vigente(), id, '2026-11-20') -> 2 ->> 'qtd')::int = 44
      and (series_tabela(tabela_vigente(), id, '2027-02-03') -> 2 ->> 'qtd')::int = 41 from unidades where numero = '1704');
insert into r(teste, ok) select 'Semestrais automáticas: 7 em nov/26, 6 em jun/27',
  (select (series_tabela(tabela_vigente(), id, '2026-11-20') -> 3 ->> 'qtd')::int = 7
      and (series_tabela(tabela_vigente(), id, '2027-06-03') -> 3 ->> 'qtd')::int = 6 from unidades where numero = '1704');
insert into r(teste, ok) select 'Menos parcelas, mesmo total da série (valor da parcela sobe)',
  (select abs((s1 -> 2 ->> 'valor')::numeric * 44 - (s2 -> 2 ->> 'valor')::numeric * 41) < 0.001
     from (select series_tabela(tabela_vigente(), id, '2026-11-20') s1, series_tabela(tabela_vigente(), id, '2027-02-03') s2 from unidades where numero = '1704') x);

set role authenticated;
-- proposta de rascunho na tabela atual
select pg_temp.como('00000000-0000-0000-0000-0000000000c3');
insert into propostas (unidade_id, pasta_id, series) values ((select id from unidades where numero = '1501'), 'f1000000-0000-0000-0000-000000000001', pg_temp.serie('1501', 1.001));
insert into ctx select 'prop', id::text from propostas where unidade_id = (select id from unidades where numero = '1501');
insert into r(teste, ok) select 'Proposta nova fica na tabela vigente', (select tabela_id = (select v::uuid from ctx where k = 'inicial') from propostas where id = (select v::uuid from ctx where k = 'prop'));
insert into r(teste, ok) select 'Corretor não cria tabela', pg_temp.tenta($$select nova_tabela('X', '2026-12-01')$$, 'SEM_PERMISSAO');

select pg_temp.como('00000000-0000-0000-0000-0000000000c2');
insert into r(teste, ok) select 'Sec. Vendas não cria tabela', pg_temp.tenta($$select nova_tabela('X', '2026-12-01')$$, 'SEM_PERMISSAO');

select pg_temp.como('00000000-0000-0000-0000-0000000000c1');
insert into r(teste, ok) select 'Tabela vigente não pode ser alterada', pg_temp.tenta(format('select reajustar_tabela(%L, 0.02)', (select v from ctx where k = 'inicial')), 'TABELA_JA_VIGENTE');
insert into ctx select 'nova', nova_tabela('Tabela 12/2026', '2026-12-01', null, 0.015, array(select id from unidades where andar >= 15))::text;
insert into r(teste, ok) select 'Nova tabela copia a vigente com reajuste só nas escolhidas (+1,5% do 15º andar para cima)',
  (select bool_and(case when u.andar >= 15 then n.preco = round(v.preco * 1.015, 2) else n.preco = v.preco end) and count(*) = 173
     from tabelas_preco_itens n join tabelas_preco_itens v on v.unidade_id = n.unidade_id and v.tabela_id = (select v::uuid from ctx where k = 'inicial')
     join unidades u on u.id = n.unidade_id where n.tabela_id = (select v::uuid from ctx where k = 'nova'));
insert into r(teste, ok) select 'Nova tabela nasce em rascunho, sem mudar a vigente',
  (select situacao = 'rascunho' from tabelas_preco_resumo where id = (select v::uuid from ctx where k = 'nova')) and tabela_vigente() = (select v::uuid from ctx where k = 'inicial');
select reajustar_tabela((select v::uuid from ctx where k = 'nova'), 0.01) \g /dev/null
insert into r(teste, ok) select 'Reajuste de +1% em todas, em cima do rascunho',
  (select n.preco = round(round(v.preco * 1.015, 2) * 1.01, 2) from tabelas_preco_itens n
     join tabelas_preco_itens v on v.unidade_id = n.unidade_id and v.tabela_id = (select v::uuid from ctx where k = 'inicial')
    where n.tabela_id = (select v::uuid from ctx where k = 'nova') and n.unidade_id = (select id from unidades where numero = '1704'));

-- arquivo
insert into r(teste, ok) select 'Arquivo com unidade inexistente e captação 3 não cadastrada é recusado',
  pg_temp.tenta(format($$select importar_tabela(%L, '[{"numero":"9999","preco":100,"captacao":1},{"numero":"201","preco":300000,"captacao":3}]')$$, (select v from ctx where k = 'nova')), 'ARQUIVO_INVALIDO');
select importar_tabela((select v::uuid from ctx where k = 'nova'), '[{"numero":"201","preco":301234.56,"captacao":2,"area":27.5,"tipologia":"Studio"},{"numero":"202","preco":299000,"captacao":1}]') \g /dev/null
insert into r(teste, ok) select 'Arquivo válido grava preço, captação e informações da unidade',
  (select preco = 301234.56 and captacao = 2 from tabelas_preco_itens where tabela_id = (select v::uuid from ctx where k = 'nova') and unidade_id = (select id from unidades where numero = '201'))
  and (select area_privativa = 27.5 and tipologia = 'Studio' from unidades where numero = '201');

-- captações
insert into r(teste, ok) select 'Captação que não soma 100% é recusada',
  pg_temp.tenta(format($$select salvar_captacoes(%L, '[{"numero":1,"nome":"A","series":[{"periodicidade":"Sinal","percentual":0.5,"qtd":1,"base":"venda","meses":0}]}]')$$, (select v from ctx where k = 'nova')), 'CAPTACAO_NAO_SOMA_100');
insert into r(teste, ok) select 'Não remove captação usada por unidades',
  pg_temp.tenta(format($$select salvar_captacoes(%L, '[{"numero":1,"nome":"A","series":[{"periodicidade":"Sinal","percentual":1,"qtd":1,"base":"venda","meses":0}]}]')$$, (select v from ctx where k = 'nova')), 'CAPTACAO_EM_USO');
select salvar_captacoes((select v::uuid from ctx where k = 'nova'), (
  select jsonb_agg(jsonb_build_object('numero', c.numero, 'nome', c.nome, 'series',
           (select jsonb_agg(jsonb_build_object('rotulo', s.rotulo, 'periodicidade', s.periodicidade, 'percentual', s.percentual, 'qtd', s.qtd,
                                                'base', s.base, 'meses', s.meses, 'fim_meses', s.fim_meses) order by s.ordem)
              from captacoes_series s where s.tabela_id = c.tabela_id and s.captacao = c.numero)) order by c.numero)
  || '[{"numero":3,"nome":"Captação 3 – curta","series":[{"rotulo":"Ato","periodicidade":"Sinal","percentual":0.1,"qtd":1,"base":"venda","meses":0},{"rotulo":"Mensais","periodicidade":"Mensais","percentual":0.2,"base":"venda","meses":1,"fim_meses":0},{"rotulo":"Chaves","periodicidade":"Financiamento","percentual":0.7,"qtd":1,"base":"entrega","meses":1}]}]'::jsonb
  from captacoes c where c.tabela_id = (select v::uuid from ctx where k = 'nova'))) \g /dev/null
insert into r(teste, ok) select 'Terceira captação cadastrada', (select count(*) = 3 from captacoes where tabela_id = (select v::uuid from ctx where k = 'nova'));
insert into r(teste, ok) select 'Não aceita uma 4ª captação', pg_temp.tenta(format($$select salvar_captacoes(%L, '[{"numero":4,"series":[]}]')$$, (select v from ctx where k = 'nova')), 'CAPTACOES_1_A_3');

-- vigência
select definir_item_tabela((select v::uuid from ctx where k = 'nova'), (select id from unidades where numero = '1501'), 400000, 3::smallint) \g /dev/null
select ativar_tabela((select v::uuid from ctx where k = 'nova'), hoje_brasilia() + 5) \g /dev/null
insert into r(teste, ok) select 'Data futura agenda a tabela', (select situacao = 'agendada' from tabelas_preco_resumo where id = (select v::uuid from ctx where k = 'nova'));
insert into r(teste, ok) select 'Agendada começa à 0h de Brasília do dia escolhido',
  (select vigente_desde = ((hoje_brasilia() + 5)::timestamp at time zone 'America/Sao_Paulo') from tabelas_preco where id = (select v::uuid from ctx where k = 'nova'));
insert into r(teste, ok) select 'Até a virada, a vigente continua a antiga e a nova é a próxima',
  tabela_vigente() = (select v::uuid from ctx where k = 'inicial') and tabela_proxima() = (select v::uuid from ctx where k = 'nova');
insert into ctx select 'outra', nova_tabela('Outra', '2027-01-01')::text;
insert into r(teste, ok) select 'Só uma tabela agendada por vez', pg_temp.tenta(format('select ativar_tabela(%L, hoje_brasilia() + 10)', (select v from ctx where k = 'outra')), 'JA_EXISTE_TABELA_AGENDADA');
select pg_temp.como('00000000-0000-0000-0000-0000000000c3');
insert into r(teste, ok) select 'Corretor consulta a próxima tabela, mas não vê rascunhos',
  (select count(*) = 1 from tabelas_preco where id = (select v::uuid from ctx where k = 'nova'))
  and (select count(*) = 0 from tabelas_preco where id = (select v::uuid from ctx where k = 'outra'));

-- virada da tabela (simulada: vigente desde 1 minuto atrás)
reset role;
update tabelas_preco set vigente_desde = now() - interval '1 minute' where id = (select v::uuid from ctx where k = 'nova');
set role authenticated;
select pg_temp.como('00000000-0000-0000-0000-0000000000c3');
insert into r(teste, ok) select 'Na data, a nova passa a valer sozinha e a antiga fica encerrada',
  tabela_vigente() = (select v::uuid from ctx where k = 'nova')
  and (select situacao = 'encerrada' from tabelas_preco_resumo where id = (select v::uuid from ctx where k = 'inicial'));
insert into r(teste, ok) select 'Rascunho na tabela antiga não é enviado depois da virada',
  pg_temp.tenta(format('select enviar_proposta(%L)', (select v from ctx where k = 'prop')), 'TABELA_ENCERRADA');
update propostas set tabela_id = tabela_vigente(), series = pg_temp.serie('1501', 1.001, tabela_vigente()) where id = (select v::uuid from ctx where k = 'prop');
insert into r(teste, ok) select 'Atualizada para a tabela vigente (com o preço novo e a captação 3)',
  (select tabela_id = (select v::uuid from ctx where k = 'nova') and data_proposta = hoje_brasilia() from propostas where id = (select v::uuid from ctx where k = 'prop'));
select enviar_proposta((select v::uuid from ctx where k = 'prop')) \g /dev/null
insert into r(teste, ok) select 'Enviada na tabela nova; PV calculado contra o preço novo',
  (select status in ('enviada', 'aprovada') and (resumo ->> 'preco_tabela')::numeric = 400000 and (resumo ->> 'pv_pct')::numeric >= 100
     from propostas where id = (select v::uuid from ctx where k = 'prop'));
insert into r(teste, ok) select 'Não volta para a tabela antiga',
  pg_temp.tenta(format('update propostas set tabela_id = %L where id = %L', (select v from ctx where k = 'inicial'), (select v from ctx where k = 'prop')), 'TABELA_NAO_VIGENTE')
  or (select status <> 'rascunho' from propostas where id = (select v::uuid from ctx where k = 'prop'));

select pg_temp.como('00000000-0000-0000-0000-0000000000c1');
select ativar_tabela((select v::uuid from ctx where k = 'outra')) \g /dev/null
insert into r(teste, ok) select 'Ativar na hora (botão Ativar)', (select situacao = 'vigente' from tabelas_preco_resumo where id = (select v::uuid from ctx where k = 'outra'));
insert into ctx select 'vazia', id::text from tabelas_preco where false;
reset role;
insert into unidades (numero, andar, posicao, status) values ('9901', 99, 1, 'disponivel');
set role authenticated;
insert into ctx select 'incompleta', nova_tabela('Incompleta', '2027-03-01')::text;
insert into r(teste, ok) select 'Não ativa tabela com unidade sem preço', pg_temp.tenta(format('select ativar_tabela(%L)', (select v from ctx where k = 'incompleta')), 'TABELA_INCOMPLETA');
insert into ctx select 'rasc', nova_tabela('Para excluir', '2027-02-01')::text;
select excluir_tabela((select v::uuid from ctx where k = 'rasc')) \g /dev/null
insert into r(teste, ok) select 'Rascunho excluído', (select count(*) = 0 from tabelas_preco where id = (select v::uuid from ctx where k = 'rasc'));
reset role;
select format('%s %s', case when ok then 'OK   ' else 'FALHA' end, teste) from r order by n;
select format('%s de %s testes passaram', count(*) filter (where ok), count(*)) from r;
