-- Testes das propostas (022). Banco de teste local, depois de todas as migrações.
\set ON_ERROR_STOP 0
\pset tuples_only on
\set QUIET on
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin-p@teste'),
  ('00000000-0000-0000-0000-0000000000c1', 'corretor-a@teste'),
  ('00000000-0000-0000-0000-0000000000c2', 'corretor-b@teste') on conflict do nothing;
insert into public.imobiliarias (id, nome) values
  ('aaaaaaaa-1111-0000-0000-000000000001', 'Imob P-A'), ('bbbbbbbb-1111-0000-0000-000000000002', 'Imob P-B') on conflict do nothing;
insert into public.perfis (user_id, email, papel, imobiliaria_id) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin-p@teste', 'admin', null),
  ('00000000-0000-0000-0000-0000000000c1', 'corretor-a@teste', 'corretor', 'aaaaaaaa-1111-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-0000000000c2', 'corretor-b@teste', 'corretor', 'bbbbbbbb-1111-0000-0000-000000000002') on conflict do nothing;

-- pasta aprovada do corretor A (montada direto, sem os gatilhos)
set session_replication_role = replica;
insert into public.pastas (id, imobiliaria_id, criado_por_id, criado_por, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao, status)
values ('cccccccc-0000-0000-0000-000000000001', 'aaaaaaaa-1111-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000c1',
        'corretor-a@teste', 'João Comprador', '52998224725', '64999990000', 'joao@t.com', 'Médico', 'aprovada');
set session_replication_role = origin;

create temp table r (n serial, teste text, ok boolean);
create temp table ctx (k text primary key, v text);
grant all on r, ctx to anon, authenticated; grant usage on sequence r_n_seq to anon, authenticated;
create or replace function pg_temp.como(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false); $$;

-- ===== Corretor A =====
set role authenticated; select pg_temp.como('00000000-0000-0000-0000-0000000000c1');
insert into r(teste, ok) select 'Corretor lê a tabela de vendas', (select count(*) from tabelas_series) = 12 and (select count(*) from precos_tipo) = 2;

do $$ begin
  insert into propostas (unidade_id, series) values ((select id from unidades where numero = '1704'),
    jsonb_build_array(jsonb_build_object('qtd', 1, 'periodicidade', 'Sinal', 'vencimento', ((now() at time zone 'America/Sao_Paulo')::date - 1)::text, 'valor', 1000)));
  insert into r(teste, ok) values ('Vencimento antes de hoje é recusado', false);
exception when others then insert into r(teste, ok) values ('Vencimento antes de hoje é recusado', sqlerrm like '%VENCIMENTO_ANTERIOR%'); end $$;

insert into propostas (unidade_id, series, resumo) values ((select id from unidades where numero = '1704'),
  jsonb_build_array(jsonb_build_object('qtd', 1, 'periodicidade', 'Sinal', 'vencimento', (now() at time zone 'America/Sao_Paulo')::date::text, 'valor', 448430)),
  '{"total": 448430, "pv_pct": 100.5}');
insert into ctx select 'p', id::text from propostas limit 1;
insert into r(teste, ok) select 'Proposta nasce rascunho, da imobiliária e do corretor, com código',
  (select status = 'rascunho' and imobiliaria_id = 'aaaaaaaa-1111-0000-0000-000000000001' and criado_por = 'corretor-a@teste' and codigo ~ '^PR-' from propostas limit 1);

do $$ begin update propostas set status = 'aprovada';
  insert into r(teste, ok) select 'Corretor não muda o status direto', (select status = 'rascunho' from propostas limit 1);
exception when others then insert into r(teste, ok) values ('Corretor não muda o status direto', true); end $$;

do $$ begin perform enviar_proposta((select v::uuid from ctx where k = 'p'));
  insert into r(teste, ok) values ('Enviar sem pasta é recusado', false);
exception when others then insert into r(teste, ok) values ('Enviar sem pasta é recusado', sqlerrm like '%PASTA_OBRIGATORIA%'); end $$;

update propostas set pasta_id = 'cccccccc-0000-0000-0000-000000000001';
select enviar_proposta((select v::uuid from ctx where k = 'p'));
insert into r(teste, ok) select 'Corretor envia a proposta', (select status = 'enviada' and enviada_em is not null from propostas limit 1);

do $$ begin update propostas set observacoes = 'mudança';
  insert into r(teste, ok) values ('Proposta enviada fica bloqueada para o corretor', false);
exception when others then insert into r(teste, ok) values ('Proposta enviada fica bloqueada para o corretor', sqlerrm like '%PROPOSTA_BLOQUEADA%'); end $$;

do $$ begin perform analisar_proposta((select v::uuid from ctx where k = 'p'), 'aprovada');
  insert into r(teste, ok) values ('Corretor não aprova', false);
exception when others then insert into r(teste, ok) values ('Corretor não aprova', true); end $$;

-- ===== Corretor B (outra imobiliária) =====
select pg_temp.como('00000000-0000-0000-0000-0000000000c2');
insert into r(teste, ok) select 'Outra imobiliária não vê a proposta', (select count(*) from propostas) = 0;

-- ===== Admin =====
select pg_temp.como('00000000-0000-0000-0000-0000000000a1');
do $$ begin perform analisar_proposta((select v::uuid from ctx where k = 'p'), 'devolvida');
  insert into r(teste, ok) values ('Devolver exige motivo', false);
exception when others then insert into r(teste, ok) values ('Devolver exige motivo', sqlerrm like '%MOTIVO_OBRIGATORIO%'); end $$;
select analisar_proposta((select v::uuid from ctx where k = 'p'), 'devolvida', 'Aumentar o sinal');

select pg_temp.como('00000000-0000-0000-0000-0000000000c1');
update propostas set series = jsonb_build_array(jsonb_build_object('qtd', 1, 'periodicidade', 'Sinal', 'vencimento', (now() at time zone 'America/Sao_Paulo')::date::text, 'valor', 448500)),
  resumo = '{"total": 448500, "pv_pct": 100.6}';
insert into r(teste, ok) select 'Corretor ajusta a proposta devolvida', (select versao > 1 and status = 'devolvida' from propostas limit 1);
select enviar_proposta((select v::uuid from ctx where k = 'p'));

select pg_temp.como('00000000-0000-0000-0000-0000000000a1');
select analisar_proposta((select v::uuid from ctx where k = 'p'), 'aprovada');
insert into r(teste, ok) select 'Admin aprova', (select status = 'aprovada' and analisada_por = 'admin-p@teste' from propostas limit 1);
insert into r(teste, ok) select 'Aprovação leva a unidade para Proposta recebida',
  (select status = 'proposta' from unidades where numero = '1704');
insert into r(teste, ok) select 'Negociação recebe valor e PV da proposta',
  (select valor_venda = 448500 and pv_aprovado = 100.6 and pasta_id = 'cccccccc-0000-0000-0000-000000000001' from negociacoes n join unidades u on u.id = n.unidade_id where u.numero = '1704' and n.ativa);
insert into r(teste, ok) select 'Histórico da proposta registrado', (select count(*) >= 5 from historico_propostas);
reset role;

select format('%s %s', case when ok then 'OK   ' else 'FALHA' end, teste) from r order by n;
select format('%s de %s testes passaram', count(*) filter (where ok), count(*)) from r;

-- ===== 022: permuta exige observação =====
select pg_temp.como('00000000-0000-0000-0000-0000000000c1');
set role authenticated;
insert into propostas (unidade_id, pasta_id, series, resumo) values ((select id from unidades where numero = '1705'), 'cccccccc-0000-0000-0000-000000000001',
  jsonb_build_array(jsonb_build_object('qtd', 1, 'periodicidade', 'Permuta', 'vencimento', ((now() at time zone 'America/Sao_Paulo')::date + 30)::text, 'valor', 100000)), '{"total": 100000}');
insert into ctx select 'perm', id::text from propostas where unidade_id = (select id from unidades where numero = '1705');
do $$ begin perform enviar_proposta((select v::uuid from ctx where k = 'perm'));
  insert into r(teste, ok) values ('Permuta sem observação não é enviada', false);
exception when others then insert into r(teste, ok) values ('Permuta sem observação não é enviada', sqlerrm like '%PERMUTA_SEM_OBSERVACAO%'); end $$;
update propostas set observacoes = 'Veículo Corolla 2022 avaliado em R$ 100 mil' where id = (select v::uuid from ctx where k = 'perm');
select enviar_proposta((select v::uuid from ctx where k = 'perm'));
insert into r(teste, ok) select 'Permuta com observação é enviada', (select status = 'enviada' from propostas where id = (select v::uuid from ctx where k = 'perm'));
reset role;
select format('%s %s', case when ok then 'OK   ' else 'FALHA' end, teste) from r where n > 15 order by n;
select format('%s de %s testes passaram (total)', count(*) filter (where ok), count(*)) from r;
