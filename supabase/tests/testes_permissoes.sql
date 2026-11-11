-- Testes de permissão e regras. Rodar em banco de teste local (ver README).
\set ON_ERROR_STOP 0
\pset tuples_only on
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@teste'),
  ('00000000-0000-0000-0000-00000000000b', 'vendas@teste'),
  ('00000000-0000-0000-0000-00000000000c', 'intruso@teste');
insert into public.perfis (user_id, email, papel) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@teste', 'admin'),
  ('00000000-0000-0000-0000-00000000000b', 'vendas@teste', 'vendas');

create temp table r (teste text, ok boolean);
grant all on r to anon, authenticated;

-- 1. Visitante (anon) lê unidades com link público ativo
set role anon;
insert into r select '01 anon lê com público ativo', (select count(*) from unidades) = 173;
-- 2. anon não altera diretamente
do $$ begin update public.unidades set status='vendida';
  insert into r values ('02 anon não faz UPDATE', false);
exception when others then insert into r values ('02 anon não faz UPDATE', true); end $$;
-- 3. anon não chama a função
do $$ begin perform public.alterar_status((select id from unidades limit 1), 'vendida', 1, null);
  insert into r values ('03 anon não chama alterar_status', false);
exception when others then insert into r values ('03 anon não chama alterar_status', true); end $$;
-- 4. anon não vê histórico
do $$ begin perform 1 from public.historico;
  insert into r values ('04 anon não lê histórico', false);
exception when others then insert into r values ('04 anon não lê histórico', true); end $$;
reset role;

-- 5. Usuário logado SEM perfil (intruso) não altera e não vê histórico
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
do $$ begin perform public.alterar_status((select id from unidades where numero='201'), 'vendida', 1, null);
  insert into r values ('05 intruso não altera', false);
exception when others then insert into r values ('05 intruso não altera', sqlerrm = 'SEM_PERMISSAO'); end $$;
insert into r select '06 intruso não vê histórico', (select count(*) from historico) = 0;
do $$ begin update public.unidades set status='vendida' where numero='201';
  insert into r values ('07 intruso não faz UPDATE direto', false);
exception when others then insert into r values ('07 intruso não faz UPDATE direto', true); end $$;

-- 8. Sec. Vendas altera, versão sobe e histórico registra
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
do $$ declare u unidades; begin
  u := public.alterar_status((select id from unidades where numero='201'), 'reservada', 1, null);
  insert into r values ('08 vendas reserva 201', u.status='reservada' and u.versao=2);
end $$;
insert into r select '09 histórico gravado com e-mail',
  exists (select 1 from historico where numero='201' and status_anterior='disponivel'
          and status_novo='reservada' and usuario_email='vendas@teste');
-- 10. Versão antiga -> CONFLITO (outra pessoa já alterou)
do $$ begin perform public.alterar_status((select id from unidades where numero='201'), 'vendida', 1, null);
  insert into r values ('10 versão antiga gera CONFLITO', false);
exception when others then insert into r values ('10 versão antiga gera CONFLITO', sqlerrm='CONFLITO'); end $$;
-- 11. Desfazer reserva sem motivo é bloqueado
do $$ begin perform public.alterar_status((select id from unidades where numero='201'), 'disponivel', 2, '  ');
  insert into r values ('11 liberar sem motivo bloqueado', false);
exception when others then insert into r values ('11 liberar sem motivo bloqueado', sqlerrm='MOTIVO_OBRIGATORIO'); end $$;
-- 12. Com motivo funciona
do $$ declare u unidades; begin
  u := public.alterar_status((select id from unidades where numero='201'), 'disponivel', 2, 'Cliente desistiu');
  insert into r values ('12 liberar com motivo', u.status='disponivel' and u.versao=3);
end $$;
-- 13. Vendas não liga/desliga link público
do $$ begin perform public.definir_publico(false);
  insert into r values ('13 vendas não desliga público', false);
exception when others then insert into r values ('13 vendas não desliga público', sqlerrm='SEM_PERMISSAO'); end $$;

-- 14. Admin desliga o link público
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
do $$ declare c config; begin c := public.definir_publico(false);
  insert into r values ('14 admin desliga público', c.publico_ativo = false); end $$;
insert into r select '15 equipe continua vendo com público desligado', (select count(*) from unidades) = 173;
reset role;

-- 16. anon não vê nada com público desligado
select set_config('request.jwt.claim.sub', '', false);
set role anon;
insert into r select '16 anon não vê com público desligado', (select count(*) from unidades) = 0;
reset role;

-- volta ao estado original
update config set publico_ativo = true;
delete from historico; update unidades set status='disponivel', versao=1;

select (case when ok then 'OK    ' else 'FALHOU' end) || '  ' || teste from r order by teste;
select 'RESUMO: ' || count(*) filter (where ok) || ' de ' || count(*) || ' passaram' from r;
