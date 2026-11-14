-- Testes de 026 (alçadas), 027 (fila de escolha) e 028 (painéis).
-- Banco de teste local, depois de todas as migrações.
\set ON_ERROR_STOP 0
\pset tuples_only on
\set QUIET on
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a9', 'admin-f@teste'),
  ('00000000-0000-0000-0000-0000000000b9', 'vendas-f@teste'),
  ('00000000-0000-0000-0000-0000000000d1', 'corretor-d@teste'),
  ('00000000-0000-0000-0000-0000000000d2', 'corretor-e@teste') on conflict do nothing;
insert into public.imobiliarias (id, nome) values
  ('dddddddd-1111-0000-0000-000000000001', 'Imob Fila D'), ('eeeeeeee-1111-0000-0000-000000000002', 'Imob Fila E') on conflict do nothing;
insert into public.perfis (user_id, email, nome, papel, imobiliaria_id) values
  ('00000000-0000-0000-0000-0000000000a9', 'admin-f@teste', 'Admin F', 'admin', null),
  ('00000000-0000-0000-0000-0000000000b9', 'vendas-f@teste', 'Vendas F', 'vendas', null),
  ('00000000-0000-0000-0000-0000000000d1', 'corretor-d@teste', 'Diego Corretor', 'corretor', 'dddddddd-1111-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-0000000000d2', 'corretor-e@teste', 'Elisa Corretora', 'corretor', 'eeeeeeee-1111-0000-0000-000000000002') on conflict do nothing;

set session_replication_role = replica;
insert into public.pastas (id, imobiliaria_id, criado_por_id, criado_por, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao, status, codigo_aprovacao, submetida_em)
values ('f0000000-0000-0000-0000-000000000001', 'dddddddd-1111-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000d1', 'corretor-d@teste', 'Ana Primeira', '52998224725', '64999990001', 'a@t.com', 'Médica', 'aprovada', 'PA-901', now() - interval '3 days'),
       ('f0000000-0000-0000-0000-000000000002', 'eeeeeeee-1111-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000d2', 'corretor-e@teste', 'Bruno Segundo', '11144477735', '64999990002', 'b@t.com', 'Advogado', 'aprovada', 'PA-902', now() - interval '2 days'),
       ('f0000000-0000-0000-0000-000000000003', 'dddddddd-1111-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000d1', 'corretor-d@teste', 'Carla Terceira', '39053344705', '64999990003', 'c@t.com', 'Dentista', 'aprovada', 'PA-903', now() - interval '1 day');
set session_replication_role = origin;

create temp table r (n serial, teste text, ok boolean);
create temp table ctx (k text primary key, v text);
grant all on r, ctx to anon, authenticated; grant usage on sequence r_n_seq to anon, authenticated;
create or replace function pg_temp.como(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false); $$;
-- série igual à tabela da unidade, multiplicada por f (f > 1 → PV acima da tabela)
create or replace function pg_temp.serie(p_numero text, f numeric) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object(
    'qtd', s.qtd, 'periodicidade', s.periodicidade,
    'vencimento', greatest((now() at time zone 'America/Sao_Paulo')::date,
                           ((case s.base when 'venda' then c.mes_tabela else c.mes_entrega end) + make_interval(months => s.meses))::date + 14)::text,
    'valor', ceil(s.percentual * public.preco_tabela_unidade(u.id) / s.qtd * f * 100) / 100) order by s.ordem)
  from public.unidades u join public.tabelas_series s on s.tabela = u.tabela cross join public.comercial c
  where u.numero = p_numero;
$$;

-- ===================== 026: alçadas =====================
set role authenticated;
select pg_temp.como('00000000-0000-0000-0000-0000000000d1');
insert into propostas (unidade_id, pasta_id, series, resumo) values
  ((select id from unidades where numero = '1601'), 'f0000000-0000-0000-0000-000000000001', pg_temp.serie('1601', 1.002), '{"pv_pct": 50}'),
  ((select id from unidades where numero = '1602'), 'f0000000-0000-0000-0000-000000000003', pg_temp.serie('1602', 0.99), '{}'),
  ((select id from unidades where numero = '1603'), 'f0000000-0000-0000-0000-000000000003', pg_temp.serie('1603', 0.95), '{}');
insert into ctx select 'auto', id::text from propostas where unidade_id = (select id from unidades where numero = '1601');
insert into ctx select 'vendas', id::text from propostas where unidade_id = (select id from unidades where numero = '1602');
insert into ctx select 'admin', id::text from propostas where unidade_id = (select id from unidades where numero = '1603');

select enviar_proposta((select v::uuid from ctx where k = 'auto')) \g /dev/null
insert into r(teste, ok) select 'PV ≥ 100% e sinal cobrindo a comissão: aprovada na hora',
  (select status = 'aprovada' and alcada = 'automatica' and analisada_por like 'Aprovação automática%' from propostas where id = (select v::uuid from ctx where k = 'auto'));
insert into r(teste, ok) select 'Banco recalcula o PV (ignora o valor enviado pela tela)',
  (select (resumo ->> 'pv_pct')::numeric >= 100 and (resumo ->> 'calculado_pelo_banco')::boolean from propostas where id = (select v::uuid from ctx where k = 'auto'));
insert into r(teste, ok) select 'Aprovação automática leva a unidade para Proposta recebida',
  (select status = 'proposta' from unidades where numero = '1601');

select enviar_proposta((select v::uuid from ctx where k = 'vendas')) \g /dev/null
select enviar_proposta((select v::uuid from ctx where k = 'admin')) \g /dev/null
insert into r(teste, ok) select 'PV 99%: alçada da Sec. Vendas', (select status = 'enviada' and alcada = 'vendas' from propostas where id = (select v::uuid from ctx where k = 'vendas'));
insert into r(teste, ok) select 'PV 95%: alçada do administrador', (select status = 'enviada' and alcada = 'admin' from propostas where id = (select v::uuid from ctx where k = 'admin'));

select pg_temp.como('00000000-0000-0000-0000-0000000000b9');
select analisar_proposta((select v::uuid from ctx where k = 'vendas'), 'aprovada') \g /dev/null
insert into r(teste, ok) select 'Sec. Vendas aprova dentro da alçada', (select status = 'aprovada' from propostas where id = (select v::uuid from ctx where k = 'vendas'));
do $$ begin perform analisar_proposta((select v::uuid from ctx where k = 'admin'), 'aprovada');
  insert into r(teste, ok) values ('Sec. Vendas não aprova abaixo da alçada', false);
exception when others then insert into r(teste, ok) values ('Sec. Vendas não aprova abaixo da alçada', sqlerrm like '%ALCADA_ADMIN%'); end $$;
select pg_temp.como('00000000-0000-0000-0000-0000000000a9');
select analisar_proposta((select v::uuid from ctx where k = 'admin'), 'aprovada') \g /dev/null
insert into r(teste, ok) select 'Administrador aprova abaixo da alçada', (select status = 'aprovada' from propostas where id = (select v::uuid from ctx where k = 'admin'));

-- corretor não consegue usar o atalho do sistema
select pg_temp.como('00000000-0000-0000-0000-0000000000d2');
do $$ begin perform alterar_status((select id from unidades where numero = '1604'), 'reservada', (select versao from unidades where numero = '1604'), null, null, null, null, null, null, 'f0000000-0000-0000-0000-000000000002');
  insert into r(teste, ok) values ('Corretor continua sem alterar status direto', false);
exception when others then insert into r(teste, ok) values ('Corretor continua sem alterar status direto', sqlerrm like '%SEM_PERMISSAO%'); end $$;

-- ===================== 027: fila =====================
do $$ begin perform reservar_pela_fila('f0000000-0000-0000-0000-000000000002', (select id from unidades where numero = '1605'));
  insert into r(teste, ok) values ('Fila desligada: corretor não reserva', false);
exception when others then insert into r(teste, ok) values ('Fila desligada: corretor não reserva', sqlerrm like '%FILA_DESLIGADA%'); end $$;

select pg_temp.como('00000000-0000-0000-0000-0000000000b9');
do $$ begin perform configurar_fila(true, now(), 1, 30, 1);
  insert into r(teste, ok) values ('Só o administrador configura a fila', false);
exception when others then insert into r(teste, ok) values ('Só o administrador configura a fila', sqlerrm like '%SEM_PERMISSAO%'); end $$;
select montar_fila() \g /dev/null
-- a pasta 2 sobe para o 1º lugar (a 1 já tem unidade aprovada)
select mover_na_fila('f0000000-0000-0000-0000-000000000002', 1) \g /dev/null
insert into r(teste, ok) select 'Montar a fila pela ordem PA e mover posição',
  (select array_agg(pasta_id order by posicao) = array['f0000000-0000-0000-0000-000000000002', 'f0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000003']::uuid[] from fila_escolha where pasta_id::text like 'f0000000%');

select pg_temp.como('00000000-0000-0000-0000-0000000000a9');
select configurar_fila(true, now() - interval '1 minute', 1, 30, 1) \g /dev/null
insert into r(teste, ok) select 'Lote de 1 a cada 30 min: 1 pasta liberada', (select (fila_situacao() ->> 'liberadas')::int = 1);

select pg_temp.como('00000000-0000-0000-0000-0000000000d1');
insert into r(teste, ok) select 'Corretor vê só as pastas dele na fila', (select count(*) = 2 and bool_and(corretor = 'Diego Corretor') from minha_fila());
do $$ begin perform reservar_pela_fila('f0000000-0000-0000-0000-000000000003', (select id from unidades where numero = '1605'));
  insert into r(teste, ok) values ('Pasta fora do lote liberado não reserva', false);
exception when others then insert into r(teste, ok) values ('Pasta fora do lote liberado não reserva', sqlerrm like '%PASTA_AINDA_NAO_LIBERADA%'); end $$;
do $$ begin perform reservar_pela_fila('f0000000-0000-0000-0000-000000000002', (select id from unidades where numero = '1605'));
  insert into r(teste, ok) values ('Corretor não usa pasta de outra imobiliária', false);
exception when others then insert into r(teste, ok) values ('Corretor não usa pasta de outra imobiliária', sqlerrm like '%PASTA_NAO_ENCONTRADA%'); end $$;

select pg_temp.como('00000000-0000-0000-0000-0000000000d2');
select reservar_pela_fila('f0000000-0000-0000-0000-000000000002', (select id from unidades where numero = '1605')) \g /dev/null
insert into r(teste, ok) select 'Pasta liberada: o corretor reserva a unidade',
  (select status = 'reservada' from unidades where numero = '1605') and (select reservas = 1 and unidades = array['1605'] from minha_fila() where pasta_id = 'f0000000-0000-0000-0000-000000000002');
do $$ begin perform reservar_pela_fila('f0000000-0000-0000-0000-000000000002', (select id from unidades where numero = '1606'));
  insert into r(teste, ok) values ('Limite de unidades por pasta', false);
exception when others then insert into r(teste, ok) values ('Limite de unidades por pasta', sqlerrm like '%LIMITE_DE_UNIDADES_DA_PASTA%'); end $$;

-- 2º lote: o início foi há 31 minutos → 2 liberadas; pasta 1 (posição 2) já pode
select pg_temp.como('00000000-0000-0000-0000-0000000000a9');
select configurar_fila(true, now() - interval '31 minutes', 1, 30, 2) \g /dev/null
select pg_temp.como('00000000-0000-0000-0000-0000000000d1');
do $$ begin perform reservar_pela_fila('f0000000-0000-0000-0000-000000000001', (select id from unidades where numero = '1605'));
  insert into r(teste, ok) values ('Unidade já reservada por outro não pode ser pega', false);
exception when others then insert into r(teste, ok) values ('Unidade já reservada por outro não pode ser pega', sqlerrm like '%UNIDADE_INDISPONIVEL%'); end $$;
insert into r(teste, ok) select 'Próximo lote libera a posição seguinte', (select liberada from minha_fila() where posicao = 2);

-- ===================== 028: painéis =====================
do $$ begin perform paineis();
  insert into r(teste, ok) values ('Corretor não vê os painéis', false);
exception when others then insert into r(teste, ok) values ('Corretor não vê os painéis', sqlerrm like '%SEM_PERMISSAO%'); end $$;
select pg_temp.como('00000000-0000-0000-0000-0000000000b9');
insert into r(teste, ok) select 'Painéis: VGV, ranking e propostas',
  (select (p -> 'vendas' -> 'proposta' ->> 'n')::int >= 3 and (p ->> 'vgv_tabela_total')::numeric > 50000000
          and jsonb_array_length(p -> 'ranking_imobiliarias') >= 2 and (p -> 'propostas' ->> 'automaticas')::int >= 1
     from (select paineis() p) x);
reset role;

select format('%s %s', case when ok then 'OK   ' else 'FALHA' end, teste) from r order by n;
select format('%s de %s testes passaram', count(*) filter (where ok), count(*)) from r;
