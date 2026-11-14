-- Testes do 109 (vários empreendimentos, etapa A). Banco local, depois de todas as migrações.
\set ON_ERROR_STOP 0
\pset tuples_only on
\set QUIET on
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000f1', 'admin-e@teste'), ('00000000-0000-0000-0000-0000000000f2', 'vendas-e@teste'), ('00000000-0000-0000-0000-0000000000f3', 'corretor-e@teste') on conflict do nothing;
insert into public.imobiliarias (id, nome) values ('cdcdcdcd-1111-0000-0000-000000000001', 'Imob E') on conflict do nothing;
insert into public.perfis (user_id, email, nome, papel, imobiliaria_id) values
  ('00000000-0000-0000-0000-0000000000f1', 'admin-e@teste', 'Admin E', 'admin', null),
  ('00000000-0000-0000-0000-0000000000f2', 'vendas-e@teste', 'Vendas E', 'vendas', null),
  ('00000000-0000-0000-0000-0000000000f3', 'corretor-e@teste', 'Corretor E', 'corretor', 'cdcdcdcd-1111-0000-0000-000000000001') on conflict do nothing;
create temp table r (n serial, teste text, ok boolean);
grant all on r to anon, authenticated; grant usage on sequence r_n_seq to anon, authenticated;
create or replace function pg_temp.como(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false); $$;
create or replace function pg_temp.tenta(sql text, esperado text) returns boolean language plpgsql as $$
begin execute sql; return false; exception when others then return sqlerrm like '%' || esperado || '%'; end $$;

insert into r(teste, ok) select 'Primeiro empreendimento criado a partir da configuração', (select count(*) = 1 and bool_and(sigla = 'DH') from empreendimentos);
insert into r(teste, ok) select 'Todas as unidades ficaram no empreendimento padrão', (select bool_and(empreendimento_id = empreendimento_padrao()) from unidades);

set role authenticated;
select pg_temp.como('00000000-0000-0000-0000-0000000000f2');
insert into r(teste, ok) select 'Sec. Vendas não cria empreendimento', pg_temp.tenta($$select salvar_empreendimento(null, 'Seven', 'seven', 'SV')$$, 'SEM_PERMISSAO');
select pg_temp.como('00000000-0000-0000-0000-0000000000f1');
select salvar_empreendimento(null, 'Seven – Eixo Elísios', 'seven', 'sv', true, 1) \g /dev/null
insert into r(teste, ok) select 'Administrador cria o segundo empreendimento (sigla em maiúsculas)', (select sigla = 'SV' from empreendimentos where slug = 'seven');
insert into r(teste, ok) select 'Sigla repetida é recusada', pg_temp.tenta($$select salvar_empreendimento(null, 'Outro', 'outro', 'DH')$$, 'ENDERECO_OU_SIGLA_EM_USO');
insert into r(teste, ok) select 'O padrão continua sendo o primeiro (Duo Haus)', (select sigla = 'DH' from empreendimentos where id = empreendimento_padrao());

select pg_temp.como('00000000-0000-0000-0000-0000000000f3');
insert into r(teste, ok) select 'Corretor vê todos os empreendimentos por padrão',
  (select bool_and(acesso_empreendimento(id)) from empreendimentos);
select pg_temp.como('00000000-0000-0000-0000-0000000000f1');
select bloquear_empreendimento('cdcdcdcd-1111-0000-0000-000000000001', (select id from empreendimentos where slug = 'seven'), true) \g /dev/null
select pg_temp.como('00000000-0000-0000-0000-0000000000f3');
insert into r(teste, ok) select 'Bloqueio tira o acesso só daquele empreendimento',
  (select not acesso_empreendimento((select id from empreendimentos where slug = 'seven')) and acesso_empreendimento(empreendimento_padrao()));
select pg_temp.como('00000000-0000-0000-0000-0000000000f2');
insert into r(teste, ok) select 'Equipe continua vendo todos', (select bool_and(acesso_empreendimento(id)) from empreendimentos);
reset role;
insert into unidades (numero, andar, posicao, status, empreendimento_id) values ('S101', 1, 1, 'disponivel', (select id from empreendimentos where slug = 'seven'));
insert into negociacoes (unidade_id, ativa) values ((select id from unidades where numero = 'S101'), true);
insert into r(teste, ok) select 'Negociação herda o empreendimento da unidade',
  (select n.empreendimento_id = u.empreendimento_id from negociacoes n join unidades u on u.id = n.unidade_id where u.numero = 'S101');
select format('%s %s', case when ok then 'OK   ' else 'FALHA' end, teste) from r order by n;
select format('%s de %s testes passaram', count(*) filter (where ok), count(*)) from r;
