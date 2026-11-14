-- Testes do 029 (Meeting: inscrições + recepção). Banco local, depois de todas as migrações.
\set ON_ERROR_STOP 0
\pset tuples_only on
\set QUIET on
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000e1', 'vendas-m@teste'), ('00000000-0000-0000-0000-0000000000e2', 'corretor-m@teste') on conflict do nothing;
insert into public.imobiliarias (id, nome) values ('abababab-1111-0000-0000-000000000001', 'Imob M') on conflict do nothing;
insert into public.perfis (user_id, email, nome, papel, imobiliaria_id) values
  ('00000000-0000-0000-0000-0000000000e1', 'vendas-m@teste', 'Vendas M', 'vendas', null),
  ('00000000-0000-0000-0000-0000000000e2', 'corretor-m@teste', 'Corretor M', 'corretor', 'abababab-1111-0000-0000-000000000001') on conflict do nothing;
create temp table r (n serial, teste text, ok boolean);
grant all on r to anon, authenticated; grant usage on sequence r_n_seq to anon, authenticated;
create or replace function pg_temp.como(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false); $$;
create or replace function pg_temp.tenta(sql text, esperado text) returns boolean language plpgsql as $$
begin execute sql; return false; exception when others then return sqlerrm like '%' || esperado || '%'; end $$;

set role authenticated; select pg_temp.como('00000000-0000-0000-0000-0000000000e2');
insert into r(teste, ok) select 'Corretor não cria meeting', pg_temp.tenta($$select salvar_meeting(null, 'Meeting X', 'meeting-x')$$, 'SEM_PERMISSAO');
select pg_temp.como('00000000-0000-0000-0000-0000000000e1');
select salvar_meeting(null, 'Meeting de lançamento', 'lancamento-duo', now() + interval '3 days', 'Majuli', 'Apresentação do empreendimento', true, 3, null) \g /dev/null
insert into r(teste, ok) select 'Endereço repetido é recusado', pg_temp.tenta($$select salvar_meeting(null, 'Outro', 'lancamento-duo')$$, 'ENDERECO_EM_USO');

-- inscrição pública, sem login
reset role; set role anon; select pg_temp.como('');
insert into r(teste, ok) select 'Visitante vê o meeting aberto', (select (meeting_publico('lancamento-duo') ->> 'abertas')::boolean);
insert into r(teste, ok) select 'Visitante se inscreve e recebe código',
  (select length(inscrever_meeting('lancamento-duo', 'Maria  da Silva', 'Maria@Email.com ', '(64) 99999-1111', 'Kavaná') ->> 'codigo') = 6);
insert into r(teste, ok) select 'E-mail repetido (maiúsculas/espaços) é recusado',
  pg_temp.tenta($$select inscrever_meeting('lancamento-duo', 'Maria Souza', ' maria@email.COM', '64988887777')$$, 'EMAIL_JA_INSCRITO');
insert into r(teste, ok) select 'Celular repetido (com +55) é recusado',
  pg_temp.tenta($$select inscrever_meeting('lancamento-duo', 'Joana Lima', 'joana@email.com', '+55 64 99999-1111')$$, 'TELEFONE_JA_INSCRITO');
insert into r(teste, ok) select 'Nome sem sobrenome é recusado', pg_temp.tenta($$select inscrever_meeting('lancamento-duo', 'Joana', 'joana@email.com', '64977776666')$$, 'NOME_COMPLETO');
insert into r(teste, ok) select 'E-mail inválido é recusado', pg_temp.tenta($$select inscrever_meeting('lancamento-duo', 'Joana Lima', 'joana@', '64977776666')$$, 'EMAIL_INVALIDO');
select inscrever_meeting('lancamento-duo', 'Joana Lima', 'joana@email.com', '64977776666') \g /dev/null
select inscrever_meeting('lancamento-duo', 'Pedro Alves', 'pedro@email.com', '64966665555') \g /dev/null
insert into r(teste, ok) select 'Vagas esgotadas (limite 3)', pg_temp.tenta($$select inscrever_meeting('lancamento-duo', 'Carlos Dias', 'carlos@email.com', '64955554444')$$, 'VAGAS_ESGOTADAS');
insert into r(teste, ok) select 'Página mostra esgotado', (select meeting_publico('lancamento-duo') ->> 'motivo' = 'esgotadas');
insert into r(teste, ok) select 'Visitante não lê a lista de inscritos', (select count(*) = 0 from recepcao_participantes);

-- recepção da equipe vê os inscritos e confirma
reset role; set role authenticated; select pg_temp.como('00000000-0000-0000-0000-0000000000e1');
insert into r(teste, ok) select 'Inscritos aparecem na recepção',
  (select count(*) = 3 and bool_and(origem = 'inscricao' and not presente) from recepcao_participantes p join recepcao_eventos e on e.id = p.evento_id where e.slug = 'lancamento-duo');
insert into r(teste, ok) select 'E-mail e celular gravados normalizados',
  (select email = 'maria@email.com' and telefone = '64999991111' and nome = 'Maria da Silva' from recepcao_participantes where codigo is not null and nome like 'Maria%');
select marcar_presenca((select id from recepcao_participantes where nome = 'Joana Lima'), true) \g /dev/null
insert into r(teste, ok) select 'Recepção confirma a presença do inscrito', (select presente from recepcao_participantes where nome = 'Joana Lima');
insert into r(teste, ok) select 'Incluir na hora com celular já inscrito é recusado',
  pg_temp.tenta($$select incluir_participante((select id from recepcao_eventos where slug = 'lancamento-duo'), 'Outra Pessoa', null, '64999991111')$$, 'TELEFONE_JA_INSCRITO');
select salvar_meeting((select id from recepcao_eventos where slug = 'lancamento-duo'), 'Meeting de lançamento', 'lancamento-duo', now() + interval '3 days', 'Majuli', null, false, null, null) \g /dev/null
reset role; set role anon;
insert into r(teste, ok) select 'Inscrições fechadas pela equipe', pg_temp.tenta($$select inscrever_meeting('lancamento-duo', 'Carlos Dias', 'carlos@email.com', '64955554444')$$, 'INSCRICOES_ENCERRADAS');
reset role;
select format('%s %s', case when ok then 'OK   ' else 'FALHA' end, teste) from r order by n;
select format('%s de %s testes passaram', count(*) filter (where ok), count(*)) from r;
