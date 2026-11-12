-- Regressão: pasta antiga (sem profissão) precisa aceitar documentos. Rodar após as migrações 001–007.
\set ON_ERROR_STOP 0
\pset tuples_only on
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000f1', 'antiga@teste') on conflict do nothing;
insert into imobiliarias (id, nome) values ('cccccccc-0000-0000-0000-000000000003', 'Imobiliária Antiga') on conflict do nothing;
insert into perfis (user_id, email, papel, imobiliaria_id) values ('00000000-0000-0000-0000-0000000000f1', 'antiga@teste', 'imobiliaria', 'cccccccc-0000-0000-0000-000000000003') on conflict do nothing;
-- simula pasta criada antes da 006 (sem telefone/e-mail/profissão)
alter table pastas disable trigger pastas_antes;
insert into pastas (id, imobiliaria_id, comprador_nome, comprador_cpf) values ('dddddddd-0000-0000-0000-000000000004', 'cccccccc-0000-0000-0000-000000000003', 'Pasta Antiga', '98765432100');
alter table pastas enable trigger pastas_antes;
insert into storage.objects (bucket_id, name) values ('documentos', 'cccccccc-0000-0000-0000-000000000003/dddddddd-0000-0000-0000-000000000004/pix.pdf');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f1', false) \g /dev/null
do $$ begin
  perform registrar_documento('dddddddd-0000-0000-0000-000000000004', (select id from tipos_documento where nome='Comprovante do PIX'),
    'cccccccc-0000-0000-0000-000000000003/dddddddd-0000-0000-0000-000000000004/pix.pdf', 'pix.pdf', 1, 'application/pdf');
  raise notice 'OK      Pasta antiga aceita documento';
exception when others then raise notice 'FALHOU  Pasta antiga aceita documento: %', sqlerrm; end $$;
do $$ begin update pastas set comprador_nome='Editada' where id='dddddddd-0000-0000-0000-000000000004';
  raise notice 'FALHOU  Editar pasta antiga sem preencher profissão deveria ser barrado';
exception when others then raise notice 'OK      Editar sem preencher profissão é barrado (%)', sqlerrm; end $$;
do $$ declare n int; begin update pastas set comprador_nome='Editada', comprador_telefone='64999990000', comprador_email='a@b.com', comprador_profissao='Advogada' where id='dddddddd-0000-0000-0000-000000000004';
  get diagnostics n = row_count;
  raise notice '%  Editar preenchendo os campos funciona', case when n=1 then 'OK    ' else 'FALHOU' end;
exception when others then raise notice 'FALHOU  Editar preenchendo os campos: %', sqlerrm; end $$;
reset role;
