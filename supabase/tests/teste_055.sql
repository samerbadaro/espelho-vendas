-- Proposta conjunta (rodar depois do teste_035)
\set ON_ERROR_STOP 0

create or replace function pg_temp.series_de(p_unidade uuid, p_fator_sinal numeric) returns jsonb language sql as $$
  with c as (select * from comercial where id = 1),
  b as (
    select s.ordem, s.periodicidade, s.qtd,
           greatest((case s.base when 'venda' then c.mes_tabela else c.mes_entrega end + make_interval(months => s.meses))::date, current_date + 1) as venc,
           s.percentual * preco_tabela_unidade(p_unidade) / s.qtd as valor
      from tabelas_series s, c, unidades u where u.id = p_unidade and s.tabela = u.tabela),
  t as (select sum(valor * qtd) filter (where periodicidade = 'Sinal') * (p_fator_sinal - 1) as extra from b)
  select jsonb_agg(jsonb_build_object('qtd', qtd, 'periodicidade', periodicidade, 'vencimento', venc,
           'valor', round(case when periodicidade = 'Sinal' then valor * p_fator_sinal
                               when periodicidade = 'Financiamento' then valor - (select extra from t) else valor end, 2)) order by ordem)
    from b;
$$;

do $$ begin
  raise notice '%  Coluna grupo_id nas propostas', case when exists (select 1 from information_schema.columns where table_name = 'propostas' and column_name = 'grupo_id') then 'OK    ' else 'FALHOU' end;
  raise notice '%  Visitante não chama enviar_grupo, analisar_grupo nem retirar_do_grupo', case when not has_function_privilege('anon', 'public.enviar_grupo(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.analisar_grupo(uuid,text,text)', 'execute') and not has_function_privilege('anon', 'public.retirar_do_grupo(uuid)', 'execute') then 'OK    ' else 'FALHOU' end;
end $$;

update config set modulo_propostas = true where id = 1;
update pastas set status = 'aprovada' where comprador_cpf = '99900000028';

-- quatro unidades livres com preço para os testes
create temp table livres as
  select id, row_number() over (order by numero) as n from unidades
   where status = 'disponivel' and tabela is not null and tipo_preco is not null and peso is not null
     and not exists (select 1 from propostas p where p.unidade_id = unidades.id and p.status not in ('cancelada', 'recusada'))
   order by numero limit 4;
grant select on livres to authenticated;

-- 1) Grupo com PV de tabela: envio individual bloqueado; envio do grupo leva todas juntas
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$
declare g uuid := gen_random_uuid(); pa uuid := coalesce((select id from pastas where status = 'aprovada' and pode_ver_pasta(id) order by criada_em limit 1), (select id from pastas where comprador_cpf = '99900000028')); p propostas; qtd int;
begin
  insert into propostas (unidade_id, pasta_id, series, grupo_id) select id, pa, pg_temp.series_de(id, 1), g from livres where n <= 2;
  select * into p from propostas where grupo_id = g limit 1;
  begin perform enviar_proposta(p.id); raise notice 'FALHOU  enviou proposta de grupo sozinha';
  exception when others then raise notice '%  Proposta conjunta não é enviada sozinha (%)', case when sqlerrm = 'PROPOSTA_EM_GRUPO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  perform enviar_grupo(g);
  select count(distinct (status, alcada)) into qtd from propostas where grupo_id = g;
  raise notice '%  Envio do grupo: mesma situação e mesma alçada nas duas (%)', case when qtd = 1 then 'OK    ' else 'FALHOU' end,
    (select string_agg(status || '/' || alcada, ', ') from propostas where grupo_id = g);
  raise notice '%  PV do conjunto gravado em cada proposta', case when not exists (select 1 from propostas where grupo_id = g and resumo ->> 'pv_pct_grupo' is null) then 'OK    ' else 'FALHOU' end;
end $$;
reset role;

-- 2) Grupo com PV baixo: Sec. Vendas não aprova; análise individual bloqueada; devolução do grupo
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$
declare g uuid := '00000000-0000-0000-0000-000000005500'; pa uuid := (select id from pastas where comprador_cpf = '99900000028');
begin
  insert into propostas (unidade_id, pasta_id, series, grupo_id) select id, pa, pg_temp.series_de(id, 0.05), g from livres where n > 2;
  perform enviar_grupo(g);
  raise notice '%  PV baixo: as duas ficam na alçada do administrador', case when (select bool_and(status = 'enviada' and alcada = 'admin') from propostas where grupo_id = g) then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$
declare g uuid := '00000000-0000-0000-0000-000000005500'; p propostas := (select x from propostas x where grupo_id = '00000000-0000-0000-0000-000000005500' limit 1);
begin
  begin perform analisar_grupo(g, 'aprovada'); raise notice 'FALHOU  Sec. Vendas aprovou grupo da alçada do admin';
  exception when others then raise notice '%  Sec. Vendas não aprova o grupo abaixo da alçada (%)', case when sqlerrm = 'ALCADA_ADMIN' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  raise notice '%  Nada mudou depois da recusa da alçada', case when (select bool_and(status = 'enviada') from propostas where grupo_id = g) then 'OK    ' else 'FALHOU' end;
  begin perform analisar_proposta(p.id, 'devolvida', 'ajuste'); raise notice 'FALHOU  devolveu uma unidade do grupo sozinha';
  exception when others then raise notice '%  Uma unidade do grupo não é analisada sozinha (%)', case when sqlerrm = 'PROPOSTA_EM_GRUPO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  perform analisar_grupo(g, 'devolvida', 'Aumentar o sinal');
  raise notice '%  Devolução do grupo leva as duas', case when (select bool_and(status = 'devolvida') from propostas where grupo_id = g) then 'OK    ' else 'FALHOU' end;
end $$;
reset role;

-- 3) Corretor tira uma unidade da simulação
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$
declare p propostas := (select x from propostas x where grupo_id = '00000000-0000-0000-0000-000000005500' order by codigo limit 1);
begin
  p := retirar_do_grupo(p.id);
  raise notice '%  Unidade retirada fica cancelada', case when p.status = 'cancelada' then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
