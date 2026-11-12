-- Testes de pastas, documentos e ISOLAMENTO entre imobiliárias. Banco de teste local.
\set ON_ERROR_STOP 0
\pset tuples_only on
\set QUIET on
-- usuários: a=admin, b=vendas, d=imobiliária A, e=imobiliária B
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@teste'),
  ('00000000-0000-0000-0000-00000000000b', 'vendas@teste'),
  ('00000000-0000-0000-0000-00000000000d', 'imob-a@teste'),
  ('00000000-0000-0000-0000-00000000000e', 'imob-b@teste') on conflict do nothing;
insert into public.imobiliarias (id, nome) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Imobiliária A'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Imobiliária B');
insert into public.perfis (user_id, email, papel, imobiliaria_id) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@teste', 'admin', null),
  ('00000000-0000-0000-0000-00000000000b', 'vendas@teste', 'vendas', null),
  ('00000000-0000-0000-0000-00000000000d', 'imob-a@teste', 'imobiliaria', 'aaaaaaaa-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-00000000000e', 'imob-b@teste', 'imobiliaria', 'bbbbbbbb-0000-0000-0000-000000000002')
on conflict do nothing;

create temp table r (n serial, teste text, ok boolean);
create temp table ctx (k text primary key, v text);
grant all on r, ctx to anon, authenticated; grant usage on sequence r_n_seq to anon, authenticated;

create or replace function pg_temp.como(u text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', u, false); $$;

-- ===== Imobiliária A cria pasta =====
set role authenticated; select pg_temp.como('00000000-0000-0000-0000-00000000000d');
insert into pastas (comprador_nome, comprador_cpf, estado_civil) values ('Maria Teste', '12345678901', 'solteiro');
insert into ctx select 'pasta', id::text from pastas where comprador_cpf='12345678901';
insert into r(teste, ok) select 'A cria pasta (incompleta, código P-0001, ligada à A)',
  (select status='incompleta' and codigo='P-0001' and imobiliaria_id='aaaaaaaa-0000-0000-0000-000000000001' from pastas limit 1);
insert into r(teste, ok) select 'Histórico registra criação', exists(select 1 from historico_pastas where acao='Pasta criada' and usuario_email='imob-a@teste');
do $$ begin
  insert into pastas (imobiliaria_id, comprador_nome, comprador_cpf) values ('bbbbbbbb-0000-0000-0000-000000000002', 'Invasor', '99999999999');
  insert into r(teste, ok) values ('A não cria pasta em nome da B', false);
exception when others then insert into r(teste, ok) values ('A não cria pasta em nome da B', true); end $$;
do $$ begin update pastas set status='aprovada';
  insert into r(teste, ok) values ('A não muda status da pasta direto', false);
exception when others then insert into r(teste, ok) values ('A não muda status da pasta direto', true); end $$;
do $$ begin update pastas set imobiliaria_id='bbbbbbbb-0000-0000-0000-000000000002';
  insert into r(teste, ok) values ('A não transfere pasta para outra imobiliária', false);
exception when others then insert into r(teste, ok) values ('A não transfere pasta para outra imobiliária', true); end $$;
do $$ begin update pastas set unidade_id=(select id from unidades limit 1);
  insert into r(teste, ok) values ('A não vincula unidade direto', false);
exception when others then insert into r(teste, ok) values ('A não vincula unidade direto', true); end $$;

-- arquivos da A
insert into storage.objects (bucket_id, name) select 'documentos', 'aaaaaaaa-0000-0000-0000-000000000001/' || v || '/rg.pdf' from ctx where k='pasta';
insert into storage.objects (bucket_id, name) select 'documentos', 'aaaaaaaa-0000-0000-0000-000000000001/' || v || '/end.pdf' from ctx where k='pasta';
insert into storage.objects (bucket_id, name) select 'documentos', 'aaaaaaaa-0000-0000-0000-000000000001/' || v || '/nasc.pdf' from ctx where k='pasta';
insert into storage.objects (bucket_id, name) select 'documentos', 'aaaaaaaa-0000-0000-0000-000000000001/' || v || '/rg2.pdf' from ctx where k='pasta';
insert into r(teste, ok) select 'A envia arquivos para a própria pasta', (select count(*) from storage.objects) = 4;
do $$ declare d documentos; p uuid := (select v::uuid from ctx where k='pasta'); begin
  d := registrar_documento(p, 1, 'aaaaaaaa-0000-0000-0000-000000000001/'||p||'/rg.pdf', 'rg.pdf', 1000, 'application/pdf');
  insert into ctx values ('doc_rg', d.id::text);
  insert into r(teste, ok) select 'Com só o RG a pasta segue incompleta', (select status='incompleta' from pastas where id=p);
  d := registrar_documento(p, 3, 'aaaaaaaa-0000-0000-0000-000000000001/'||p||'/end.pdf', 'end.pdf', 1000, 'application/pdf');
  insert into ctx values ('doc_end', d.id::text);
  d := registrar_documento(p, 4, 'aaaaaaaa-0000-0000-0000-000000000001/'||p||'/nasc.pdf', 'nasc.pdf', 1000, 'application/pdf');
  insert into ctx values ('doc_nasc', d.id::text);
  insert into r(teste, ok) select 'Obrigatórios enviados: aguardando análise', (select status='aguardando_analise' from pastas where id=p);
end $$;
do $$ begin perform registrar_documento((select v::uuid from ctx where k='pasta'), 2, 'aaaaaaaa-0000-0000-0000-000000000001/x/naoexiste.pdf', 'x.pdf', 1, 'application/pdf');
  insert into r(teste, ok) values ('Registro com caminho de outra pasta é recusado', false);
exception when others then insert into r(teste, ok) values ('Registro com caminho de outra pasta é recusado', sqlerrm='CAMINHO_INVALIDO'); end $$;
do $$ begin perform analisar_documento((select v::uuid from ctx where k='doc_rg'), 'aprovado');
  insert into r(teste, ok) values ('Imobiliária não aprova documento', false);
exception when others then insert into r(teste, ok) values ('Imobiliária não aprova documento', sqlerrm='SEM_PERMISSAO'); end $$;
do $$ begin perform vincular_unidade((select v::uuid from ctx where k='pasta'), (select id from unidades limit 1));
  insert into r(teste, ok) values ('Imobiliária não vincula unidade', false);
exception when others then insert into r(teste, ok) values ('Imobiliária não vincula unidade', sqlerrm='SEM_PERMISSAO'); end $$;
do $$ begin perform alterar_status((select id from unidades where numero='301'), 'vendida', 1);
  insert into r(teste, ok) values ('Imobiliária não altera status de unidade', false);
exception when others then insert into r(teste, ok) values ('Imobiliária não altera status de unidade', sqlerrm='SEM_PERMISSAO'); end $$;
insert into r(teste, ok) select 'Imobiliária não lê negociações', (select count(*) from negociacoes) = 0;
insert into r(teste, ok) select 'A vê só a própria imobiliária', (select count(*) from imobiliarias) = 1;
insert into r(teste, ok) select 'A vê só o próprio perfil', (select count(*) from perfis) = 1;
do $$ begin insert into imobiliarias (nome) values ('Nova');
  insert into r(teste, ok) values ('Imobiliária não cadastra imobiliária', false);
exception when others then insert into r(teste, ok) values ('Imobiliária não cadastra imobiliária', true); end $$;
reset role;

-- ===== Imobiliária B tenta acessar dados da A =====
set role authenticated; select pg_temp.como('00000000-0000-0000-0000-00000000000e');
insert into r(teste, ok) select 'B não vê pastas da A', (select count(*) from pastas) = 0;
insert into r(teste, ok) select 'B não vê documentos da A', (select count(*) from documentos) = 0;
insert into r(teste, ok) select 'B não vê histórico da A', (select count(*) from historico_pastas) = 0;
insert into r(teste, ok) select 'B não vê arquivos da A', (select count(*) from storage.objects) = 0;
do $$ declare n int; begin
  update pastas set comprador_nome='Hackeado' where id=(select v::uuid from ctx where k='pasta');
  get diagnostics n = row_count;
  insert into r(teste, ok) values ('B não edita pasta da A', n = 0);
end $$;
do $$ begin
  insert into storage.objects (bucket_id, name) select 'documentos', 'aaaaaaaa-0000-0000-0000-000000000001/' || v || '/plantado.pdf' from ctx where k='pasta';
  insert into r(teste, ok) values ('B não envia arquivo para pasta da A', false);
exception when others then insert into r(teste, ok) values ('B não envia arquivo para pasta da A', true); end $$;
do $$ begin
  insert into storage.objects (bucket_id, name) select 'documentos', 'bbbbbbbb-0000-0000-0000-000000000002/' || v || '/plantado.pdf' from ctx where k='pasta';
  insert into r(teste, ok) values ('B não usa pasta da A com o próprio prefixo', false);
exception when others then insert into r(teste, ok) values ('B não usa pasta da A com o próprio prefixo', true); end $$;
do $$ begin perform registrar_documento((select v::uuid from ctx where k='pasta'), 2, 'aaaaaaaa-0000-0000-0000-000000000001/x/rg.pdf', 'x', 1, 'application/pdf');
  insert into r(teste, ok) values ('B não registra documento na pasta da A', false);
exception when others then insert into r(teste, ok) values ('B não registra documento na pasta da A', sqlerrm='SEM_PERMISSAO'); end $$;
reset role;

-- ===== Sec. Vendas analisa =====
set role authenticated; select pg_temp.como('00000000-0000-0000-0000-00000000000b');
insert into r(teste, ok) select 'Equipe vê pasta da A', (select count(*) from pastas) = 1;
do $$ begin perform analisar_documento((select v::uuid from ctx where k='doc_rg'), 'recusado', '  ');
  insert into r(teste, ok) values ('Recusar sem motivo é bloqueado', false);
exception when others then insert into r(teste, ok) values ('Recusar sem motivo é bloqueado', sqlerrm='MOTIVO_OBRIGATORIO'); end $$;
select analisar_documento((select v::uuid from ctx where k='doc_rg'), 'recusado', 'Foto ilegível') \g /dev/null
insert into r(teste, ok) select 'Recusa deixa a pasta pendente de correção',
  (select status='pendente_correcao' from pastas) and (select motivo_recusa='Foto ilegível' from documentos where id=(select v::uuid from ctx where k='doc_rg'));
reset role;

-- ===== A substitui o recusado =====
set role authenticated; select pg_temp.como('00000000-0000-0000-0000-00000000000d');
do $$ declare d documentos; p uuid := (select v::uuid from ctx where k='pasta'); begin
  d := registrar_documento(p, 1, 'aaaaaaaa-0000-0000-0000-000000000001/'||p||'/rg2.pdf', 'rg2.pdf', 1000, 'application/pdf');
  insert into ctx values ('doc_rg2', d.id::text);
  insert into r(teste, ok) select 'Substituição volta a pasta para aguardando análise', (select status='aguardando_analise' from pastas where id=p);
  insert into r(teste, ok) select 'Versão recusada fica guardada no histórico',
    (select count(*) from documentos where pasta_id=p and tipo_id=1) = 2
    and (select count(*) from documentos where pasta_id=p and tipo_id=1 and atual) = 1;
end $$;
reset role;

set role authenticated; select pg_temp.como('00000000-0000-0000-0000-00000000000b');
select analisar_documento(v::uuid, 'aprovado') from ctx where k in ('doc_rg2', 'doc_end', 'doc_nasc') \g /dev/null
insert into r(teste, ok) select 'Todos obrigatórios aprovados: pasta aprovada', (select status='aprovada' from pastas);
select vincular_unidade((select v::uuid from ctx where k='pasta'), (select id from unidades where numero='1205')) \g /dev/null
insert into r(teste, ok) select 'Equipe vincula unidade', (select u.numero='1205' from pastas p join unidades u on u.id=p.unidade_id);
reset role;

set role authenticated; select pg_temp.como('00000000-0000-0000-0000-00000000000d');
do $$ declare p uuid := (select v::uuid from ctx where k='pasta'); begin
  insert into storage.objects (bucket_id, name) values ('documentos', 'aaaaaaaa-0000-0000-0000-000000000001/'||p||'/rg3.pdf');
  perform registrar_documento(p, 1, 'aaaaaaaa-0000-0000-0000-000000000001/'||p||'/rg3.pdf', 'rg3.pdf', 1, 'application/pdf');
  insert into r(teste, ok) values ('A não substitui documento já aprovado', false);
exception when others then insert into r(teste, ok) values ('A não substitui documento já aprovado', sqlerrm='DOCUMENTO_BLOQUEADO'); end $$;
update pastas set estado_civil='casado', conjuge_nome='João Teste', conjuge_cpf='11122233344';
insert into r(teste, ok) select 'Mudar para casado exige docs do cônjuge (volta a incompleta)', (select status='incompleta' from pastas);
update pastas set estado_civil='solteiro';
insert into r(teste, ok) select 'Voltar para solteiro apaga dados do cônjuge', (select conjuge_nome is null and conjuge_cpf is null from pastas);
reset role;

-- ===== Imobiliária desativada perde o acesso =====
update imobiliarias set ativa=false where nome='Imobiliária A';
set role authenticated; select pg_temp.como('00000000-0000-0000-0000-00000000000d');
insert into r(teste, ok) select 'Imobiliária desativada não vê mais nada', (select count(*) from pastas) = 0 and (select count(*) from storage.objects) = 0;
reset role;
update imobiliarias set ativa=true;

-- ===== Imobiliária vê o espelho mesmo com link público desligado =====
update config set publico_ativo=false;
set role authenticated; select pg_temp.como('00000000-0000-0000-0000-00000000000d');
insert into r(teste, ok) select 'Imobiliária vê espelho com link público desligado', (select count(*) from unidades) = 173;
reset role;
select pg_temp.como('');
set role anon;
do $$ begin perform 1 from pastas; insert into r(teste, ok) values ('Visitante não lê pastas', false);
exception when others then insert into r(teste, ok) values ('Visitante não lê pastas', true); end $$;
reset role;
update config set publico_ativo=true;

select (case when ok then 'OK    ' else 'FALHOU' end) || '  ' || teste from r order by n;
select 'RESUMO: ' || count(*) filter (where ok) || ' de ' || count(*) || ' passaram' from r;
