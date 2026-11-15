-- Testes do 112 (dois empreendimentos lado a lado). Banco local, depois de todas as migrações.
\set ON_ERROR_STOP 0
\pset tuples_only on
\set QUIET on
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000e1', 'admin-m@teste'), ('00000000-0000-0000-0000-0000000000e2', 'corretor-m@teste') on conflict do nothing;
insert into public.imobiliarias (id, nome) values ('cdcdcdcd-3333-0000-0000-000000000001', 'Imob M') on conflict do nothing;
insert into public.perfis (user_id, email, nome, papel, imobiliaria_id) values
  ('00000000-0000-0000-0000-0000000000e1', 'admin-m@teste', 'Admin M', 'admin', null),
  ('00000000-0000-0000-0000-0000000000e2', 'corretor-m@teste', 'Corretor M', 'corretor', 'cdcdcdcd-3333-0000-0000-000000000001') on conflict do nothing;
create temp table r (n serial, teste text, ok boolean);
create temp table ctx (k text primary key, v text);
grant all on r, ctx to anon, authenticated; grant usage on sequence r_n_seq to anon, authenticated;
create or replace function pg_temp.como(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false); $$;
create or replace function pg_temp.tenta(sql text, esperado text) returns boolean language plpgsql as $$
begin execute sql; return false; exception when others then return sqlerrm like '%' || esperado || '%'; end $$;

set role authenticated;
select pg_temp.como('00000000-0000-0000-0000-0000000000e1');
insert into ctx select 'dh', empreendimento_atual()::text;
insert into ctx select 'te', (salvar_empreendimento(null, 'Empreendimento Teste', 'teste', 'TE', true, 1)).id::text;
insert into r(teste, ok) select 'Novo empreendimento nasce com configuração, dados comerciais e fila',
  (select count(*) = 1 from config where empreendimento_id = (select v::uuid from ctx where k = 'te')) is not null
  and (select count(*) from public.empreendimentos) = 2;
reset role;
insert into r(teste, ok) select 'Linhas próprias de config, comercial e fila_config',
  (select count(*) = 3 from (select 1 from config where empreendimento_id = (select v::uuid from ctx where k = 'te')
     union all select 1 from comercial where empreendimento_id = (select v::uuid from ctx where k = 'te')
     union all select 1 from fila_config where empreendimento_id = (select v::uuid from ctx where k = 'te')) x);
insert into unidades (numero, andar, posicao, status, area_privativa, empreendimento_id)
select (a * 100 + f)::text, a, f, 'disponivel', 110, (select v::uuid from ctx where k = 'te') from generate_series(1, 3) a, generate_series(1, 5) f;
insert into r(teste, ok) select 'Mesmo número de unidade pode existir nos dois empreendimentos (201)',
  (select count(*) = 2 from unidades where numero = '201');

set role authenticated;
select pg_temp.como('00000000-0000-0000-0000-0000000000e2');
insert into r(teste, ok) select 'Corretor começa no primeiro empreendimento (Duo Haus)',
  empreendimento_atual() = (select v::uuid from ctx where k = 'dh') and (select count(*) = 173 from unidades);
select escolher_empreendimento((select v::uuid from ctx where k = 'te')) \g /dev/null
insert into r(teste, ok) select 'Trocando para o Teste, vê só as 15 unidades dele', (select count(*) = 15 from unidades);
insert into r(teste, ok) select 'Configuração lida é a do empreendimento atual', (select nome_empreendimento = 'Empreendimento Teste' from config);
insert into pastas (comprador_nome, comprador_cpf, estado_civil, comprador_telefone, comprador_email, comprador_profissao) values ('Maria Teste', '52998224725', 'solteiro', '64999990000', 'maria@t.com', 'Médica');
insert into r(teste, ok) select 'Pasta nova no Teste recebe o código TE-P-001', (select codigo = 'TE-P-001' from pastas where comprador_nome = 'Maria Teste');
select escolher_empreendimento((select v::uuid from ctx where k = 'dh')) \g /dev/null
insert into r(teste, ok) select 'De volta ao Duo Haus, a pasta do Teste não aparece', (select count(*) = 0 from pastas where comprador_nome = 'Maria Teste');
reset role;
insert into r(teste, ok) select 'Código de aprovação com a sigla (TE-PA-001)', proximo_codigo((select v::uuid from ctx where k = 'te'), 'PA') = 'TE-PA-001';
insert into r(teste, ok) select 'Pasta do Teste não reserva unidade do Duo Haus',
  pg_temp.tenta(format($$insert into negociacoes (unidade_id, pasta_id, ativa) values ((select id from unidades where numero = '1704'), %L, true)$$,
    (select id from pastas where comprador_nome = 'Maria Teste')), 'PASTA_DE_OUTRO_EMPREENDIMENTO');

set role authenticated;
select pg_temp.como('00000000-0000-0000-0000-0000000000e1');
select escolher_empreendimento((select v::uuid from ctx where k = 'te')) \g /dev/null
select configurar_fila(true, now() - interval '1 hour', 5, 30, 1) \g /dev/null
insert into r(teste, ok) select 'Fila ligada só no Teste', (select ativa from fila_config) and (select (fila_situacao() ->> 'ativa')::boolean);
reset role;
insert into r(teste, ok) select 'Fila do Duo Haus continua desligada', (select not ativa from public.fila_de((select v::uuid from ctx where k = 'dh')));
set role authenticated;
select pg_temp.como('00000000-0000-0000-0000-0000000000e1');
insert into r(teste, ok) select 'Painel consolidado traz os dois empreendimentos',
  jsonb_array_length(paineis(true) -> 'por_empreendimento') = 2 and jsonb_array_length(paineis() -> 'por_empreendimento') = 1;
insert into r(teste, ok) select 'Painel do Teste conta só as 15 unidades', (paineis() #>> '{por_empreendimento,0,unidades}')::int = 15;
select bloquear_empreendimento('cdcdcdcd-3333-0000-0000-000000000001', (select v::uuid from ctx where k = 'te'), true) \g /dev/null
select pg_temp.como('00000000-0000-0000-0000-0000000000e2');
insert into r(teste, ok) select 'Imobiliária bloqueada não entra no Teste',
  pg_temp.tenta(format('select escolher_empreendimento(%L)', (select v from ctx where k = 'te')), 'EMPREENDIMENTO_SEM_ACESSO')
  and (select count(*) = 1 from meus_empreendimentos());
reset role;
select format('%s %s', case when ok then 'OK   ' else 'FALHA' end, teste) from r order by n;
select format('%s de %s testes passaram', count(*) filter (where ok), count(*)) from r;
