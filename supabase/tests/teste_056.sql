-- Contraproposta (rodar depois do teste_055)
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
grant execute on function pg_temp.series_de(uuid, numeric) to authenticated;

do $$ begin
  raise notice '%  Colunas proposta_original e contraproposta', case when (select count(*) from information_schema.columns where table_name = 'propostas' and column_name in ('proposta_original', 'contraproposta')) = 2 then 'OK    ' else 'FALHOU' end;
  raise notice '%  Visitante não chama as funções de contraproposta', case when not has_function_privilege('anon', 'public.contrapropor(uuid,jsonb,text)', 'execute')
    and not has_function_privilege('anon', 'public.contrapropor_grupo(uuid,jsonb,text)', 'execute') and not has_function_privilege('anon', 'public.aceitar_contraproposta(uuid)', 'execute') then 'OK    ' else 'FALHOU' end;
end $$;

update config set modulo_propostas = true where id = 1;
update pastas set status = 'aprovada' where comprador_cpf = '99900000028';
create temp table livres as
  select id, numero, row_number() over (order by numero) as n from unidades
   where status = 'disponivel' and tabela is not null and tipo_preco is not null and peso is not null
     and not exists (select 1 from propostas p where p.unidade_id = unidades.id and p.status not in ('cancelada', 'recusada'))
   order by numero limit 4;
grant select on livres to authenticated;

-- corretor envia três propostas com PV baixo: A e B sozinhas, C+D em grupo
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$
declare pa uuid := (select id from pastas where comprador_cpf = '99900000028'); g uuid := '00000000-0000-0000-0000-000000005600'; p propostas;
begin
  for p in insert into propostas (unidade_id, pasta_id, series) select id, pa, pg_temp.series_de(id, 0.05) from livres where n <= 2 returning * loop
    perform enviar_proposta(p.id);
  end loop;
  insert into propostas (unidade_id, pasta_id, series, grupo_id) select id, pa, pg_temp.series_de(id, 0.05), g from livres where n > 2;
  perform enviar_grupo(g);
  raise notice '%  Três envios com PV baixo ficam com o administrador', case when (select count(*) from propostas where unidade_id in (select id from livres) and status = 'enviada' and alcada = 'admin') = 4 then 'OK    ' else 'FALHOU' end;
end $$;
reset role;

-- Sec. Vendas: não contrapropõe abaixo da sua alçada; contrapropõe com PV de tabela
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$
declare a uuid := (select id from livres where n = 1); p propostas := (select x from propostas x where unidade_id = (select id from livres where n = 1) and status = 'enviada');
  original jsonb := p.series;
begin
  begin perform contrapropor(p.id, jsonb_build_object('series', pg_temp.series_de(a, 0.05)), 'teste'); raise notice 'FALHOU  Sec. Vendas contrapropôs abaixo da alçada';
  exception when others then raise notice '%  Sec. Vendas não contrapropõe abaixo da alçada (%)', case when sqlerrm = 'ALCADA_ADMIN' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  begin perform contrapropor(p.id, jsonb_build_object('series', pg_temp.series_de(a, 1)), ''); raise notice 'FALHOU  contrapropôs sem motivo';
  exception when others then raise notice '%  Contraproposta exige motivo', case when sqlerrm = 'MOTIVO_OBRIGATORIO' then 'OK    ' else 'FALHOU' end; end;
  p := contrapropor(p.id, jsonb_build_object('series', pg_temp.series_de(a, 1)), 'Sinal maior para manter o preço');
  raise notice '%  Devolvida com a contraproposta e a original guardada', case when p.status = 'devolvida' and p.proposta_original -> 'series' = original
    and p.contraproposta -> 'series' = p.series and p.series <> original and p.contraproposta ->> 'por' is not null then 'OK    ' else 'FALHOU' end;
  -- grupo
  p := (select x from propostas x where grupo_id = '00000000-0000-0000-0000-000000005600' limit 1);
  begin perform contrapropor(p.id, jsonb_build_object('series', p.series), 'x'); raise notice 'FALHOU  contrapropôs uma unidade do grupo sozinha';
  exception when others then raise notice '%  Unidade do grupo não é contraproposta sozinha (%)', case when sqlerrm = 'PROPOSTA_EM_GRUPO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  perform contrapropor_grupo('00000000-0000-0000-0000-000000005600',
    (select jsonb_agg(jsonb_build_object('id', x.id, 'dados', jsonb_build_object('series', pg_temp.series_de(x.unidade_id, 1)))) from propostas x where grupo_id = '00000000-0000-0000-0000-000000005600'),
    'Ajuste do conjunto');
  raise notice '%  Contraproposta do grupo devolve as duas', case when (select bool_and(status = 'devolvida' and contraproposta is not null) from propostas where grupo_id = '00000000-0000-0000-0000-000000005600') then 'OK    ' else 'FALHOU' end;
end $$;
reset role;

-- Administrador contrapropõe B com PV baixo (dentro da alçada dele)
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$
declare b uuid := (select id from livres where n = 2); p propostas := (select x from propostas x where unidade_id = (select id from livres where n = 2) and status = 'enviada');
begin
  p := contrapropor(p.id, jsonb_build_object('series', pg_temp.series_de(b, 0.5)), 'Contraproposta do administrador');
  raise notice '%  Administrador contrapropõe abaixo da alçada da Sec. Vendas', case when p.status = 'devolvida' then 'OK    ' else 'FALHOU' end;
end $$;
reset role;

-- Corretor: aceita A sem mexer (aprova na hora); altera B (não aceita); aceita o grupo
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$
declare pa propostas := (select x from propostas x where unidade_id = (select id from livres where n = 1) and status = 'devolvida');
  pb propostas := (select x from propostas x where unidade_id = (select id from livres where n = 2) and status = 'devolvida');
  pg propostas := (select x from propostas x where grupo_id = '00000000-0000-0000-0000-000000005600' order by codigo limit 1);
begin
  perform aceitar_contraproposta(pa.id);
  raise notice '%  Contraproposta aceita: aprovada e unidade em Proposta recebida', case when (select status from propostas where id = pa.id) = 'aprovada'
    and (select status from unidades where id = pa.unidade_id) = 'proposta' then 'OK    ' else 'FALHOU' end;
  update propostas set series = pg_temp.series_de(pb.unidade_id, 0.6) where id = pb.id;
  begin perform aceitar_contraproposta(pb.id); raise notice 'FALHOU  aceitou contraproposta alterada';
  exception when others then raise notice '%  Contraproposta alterada não é aceita direto (%)', case when sqlerrm = 'CONTRAPROPOSTA_ALTERADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  perform aceitar_contraproposta(pg.id);
  raise notice '%  Aceitar uma unidade do grupo aprova o conjunto', case when (select bool_and(status = 'aprovada') from propostas where grupo_id = '00000000-0000-0000-0000-000000005600') then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
