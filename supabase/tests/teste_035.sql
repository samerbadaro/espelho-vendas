-- Propostas trazidas da v2 (rodar por último)
\set ON_ERROR_STOP 0

-- séries no formato da proposta a partir da tabela da unidade (fator multiplica o sinal; o financiamento compensa)
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

-- 1) Módulo desligado: corretor não cria proposta; equipe cria
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ begin
  insert into propostas (unidade_id) values ((select id from unidades where numero = '911'));
  raise notice 'FALHOU  corretor criou proposta com módulo desligado';
exception when others then raise notice '%  Módulo desligado: corretor não cria proposta (%)', case when sqlerrm = 'MODULO_DESLIGADO' then 'OK    ' else 'FALHOU' end, sqlerrm; end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare n int; begin
  insert into propostas (unidade_id) values ((select id from unidades where numero = '910'));
  select count(*) into n from propostas;
  raise notice '%  Módulo desligado: equipe cria (rascunho)', case when n = 1 then 'OK    ' else 'FALHOU' end;
exception when others then raise notice 'FALHOU  equipe com módulo desligado (%)', sqlerrm; end $$;
reset role;
update config set modulo_propostas = true;
delete from propostas;

-- 2) Corretor: proposta pela tabela (PV >= 100%, sinal cobre a comissão) é aprovada sozinha
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$
declare
  u911 uuid := (select id from unidades where numero = '911');
  pa uuid := (select id from pastas where comprador_cpf = '99900000028');
  inc uuid := (select id from pastas where comprador_cpf = '99900000029');
  p propostas; un unidades; s jsonb := pg_temp.series_de(u911, 1.02);
begin
  insert into propostas (unidade_id, series) values (u911, s) returning * into p;
  raise notice '%  Corretor cria rascunho com código PR-', case when p.status = 'rascunho' and p.codigo like 'PR-%' and p.criado_por = 'corretor1@teste' then 'OK    ' else 'FALHOU' end;
  begin perform enviar_proposta(p.id); raise notice 'FALHOU  enviou sem pasta';
  exception when others then raise notice '%  Enviar exige pasta (%)', case when sqlerrm = 'PASTA_OBRIGATORIA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  update propostas set pasta_id = inc where id = p.id;
  begin perform enviar_proposta(p.id); raise notice 'FALHOU  aprovou com pasta incompleta';
  exception when others then raise notice '%  Pasta sem documentos aprovados não leva a unidade (%)', case when sqlerrm = 'PASTA_NAO_APROVADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  update propostas set pasta_id = pa where id = p.id;
  p := enviar_proposta(p.id);
  select * into un from unidades where id = u911;
  raise notice '%  PV % pct: aprovada automaticamente', case when p.status = 'aprovada' and p.alcada = 'automatica' then 'OK    ' else 'FALHOU' end, p.resumo ->> 'pv_pct';
  raise notice '%  Unidade 911 vai para Proposta no espelho, com a pasta', case when un.status = 'proposta'
    and exists (select 1 from negociacoes where unidade_id = u911 and ativa and pasta_id = pa) then 'OK    ' else 'FALHOU' end;
  raise notice '%  Banco recalcula o PV (não confia no navegador)', case when (p.resumo ->> 'calculado_pelo_banco')::boolean then 'OK    ' else 'FALHOU' end;
  begin update propostas set observacoes = 'mudei' where id = p.id; raise notice 'FALHOU  editou proposta aprovada';
  exception when others then raise notice '%  Proposta aprovada não é editada pelo corretor (%)', case when sqlerrm = 'PROPOSTA_BLOQUEADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
reset role;

-- 3) PV baixo: alçada do administrador; Sec. Vendas não aprova, administrador aprova
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$
declare u909 uuid := (select id from unidades where numero = '909'); p propostas;
begin
  -- sinal menor e financiamento maior: PV cai
  insert into propostas (unidade_id, pasta_id, series) values (u909, (select id from pastas where comprador_cpf = '99900000028'), pg_temp.series_de(u909, 0.05)) returning * into p;
  p := enviar_proposta(p.id);
  raise notice '%  PV % pct: fica enviada na alçada do administrador', case when p.status = 'enviada' and p.alcada = 'admin' then 'OK    ' else 'FALHOU' end, p.resumo ->> 'pv_pct';
  raise notice '%  Unidade 909 continua disponível enquanto não aprova', case when (select status from unidades where id = u909) = 'disponivel' then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare p propostas := (select x from propostas x where unidade_id = (select id from unidades where numero = '909')); begin
  begin perform analisar_proposta(p.id, 'aprovada'); raise notice 'FALHOU  Sec. Vendas aprovou alçada do admin';
  exception when others then raise notice '%  Sec. Vendas não aprova abaixo da alçada (%)', case when sqlerrm = 'ALCADA_ADMIN' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  begin perform analisar_proposta(p.id, 'recusada'); raise notice 'FALHOU  recusou sem motivo';
  exception when others then raise notice '%  Recusar exige motivo', case when sqlerrm = 'MOTIVO_OBRIGATORIO' then 'OK    ' else 'FALHOU' end; end;
end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ declare p propostas := (select x from propostas x where unidade_id = (select id from unidades where numero = '909')); begin
  p := analisar_proposta(p.id, 'aprovada');
  raise notice '%  Administrador aprova e a unidade vai para Proposta', case when p.status = 'aprovada' and (select status from unidades where numero = '909') = 'proposta' then 'OK    ' else 'FALHOU' end;
end $$;
reset role;

-- 4) Visibilidade e proteções
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000e', false) \g /dev/null
do $$ declare n int; begin
  select count(*) into n from propostas;
  raise notice '%  Outra imobiliária não vê as propostas', case when n = 0 then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', false) \g /dev/null
do $$ declare n int; begin
  select count(*) into n from propostas;
  raise notice '%  Outro corretor da mesma imobiliária não vê', case when n = 0 then 'OK    ' else 'FALHOU' end;
  begin perform alterar_status((select id from unidades where numero = '908'), 'vendida', (select versao from unidades where numero = '908'));
    raise notice 'FALHOU  corretor mudou status';
  exception when others then raise notice '%  Corretor continua sem mudar o espelho direto', case when sqlerrm = 'SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end; end;
end $$;
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ declare n int; begin
  select count(*) into n from propostas;
  raise notice '%  Imobiliária vê as propostas dos seus corretores (%)', case when n = 2 then 'OK    ' else 'FALHOU' end, n;
end $$;
reset role;
set role anon;
do $$ begin
  perform preco_tabela_unidade('00000000-0000-0000-0000-000000000000');
  raise notice 'FALHOU  anônimo leu preço';
exception when others then raise notice '%  Sem login não consulta preço', case when sqlstate = '42501' then 'OK    ' else 'FALHOU' end; end $$;
reset role;
do $$ begin
  raise notice '%  Função interna de aprovação fechada para todos', case when not has_function_privilege('authenticated', 'aprovar_proposta_interno(uuid, text)', 'execute')
    and not has_function_privilege('anon', 'aprovar_proposta_interno(uuid, text)', 'execute') then 'OK    ' else 'FALHOU' end;
end $$;

-- 5) Empreendimento: o administrador consegue gravar todas as chaves de módulo
do $$ declare faltam text; begin
  select string_agg(column_name, ', ') into faltam from information_schema.columns c
   where table_schema = 'public' and table_name = 'config' and column_name like 'modulo%'
     and not has_column_privilege('authenticated', 'public.config', column_name, 'UPDATE');
  raise notice '%  Todas as chaves de módulo podem ser salvas (%)', case when faltam is null then 'OK    ' else 'FALHOU' end, coalesce(faltam, 'todas');
end $$;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ begin
  update config set modulo_rodadas = false, modulo_propostas = false, atualizado_em = now() where id = 1;
  raise notice 'OK      Administrador desliga Rodadas pela tela de Empreendimento';
exception when others then raise notice 'FALHOU  salvar Empreendimento (%)', sqlerrm; end $$;
reset role;
