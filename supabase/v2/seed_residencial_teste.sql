-- =====================================================================
-- Empreendimento hipotético para testar vários empreendimentos (só no projeto de testes)
--  Residencial Teste (RT): 25 pavimentos × 5 unidades = 125 unidades
--   finais 1 e 2: 110 m² · finais 3 e 4: 90 m² · final 5: 77 m²
--  Preços hipotéticos: R$/m² por metragem + 0,4% por andar acima do 1º.
--  Uma captação por metragem. Entrega hipotética: dez/2030.
--  Pode rodar mais de uma vez: se o RT já existir, não faz nada.
-- =====================================================================
do $$
declare
  v_emp uuid; v_base uuid := public.empreendimento_padrao(); v_tab uuid;
begin
  if exists (select 1 from public.empreendimentos where sigla = 'RT') then return; end if;

  insert into public.empreendimentos (slug, sigla, nome, ativo, ordem)
  values ('residencial-teste', 'RT', 'Residencial Teste', true, 1) returning id into v_emp;

  -- identidade (cores do Duo Haus, sem logo), módulos opcionais desligados, 3 cenários no simulador
  insert into public.config
  select (jsonb_populate_record(null::public.config, to_jsonb(c) || jsonb_build_object(
            'id', nextval('public.config_id_seq'), 'empreendimento_id', v_emp, 'nome_empreendimento', 'Residencial Teste',
            'cidade', 'Rio Verde, GO', 'logo_url', null, 'logo_escuro_url', null, 'imagem_login_url', null, 'publico_ativo', false,
            'modulo_pastas', true, 'modulo_funil', true, 'modulo_portal', true, 'modulo_rodadas', false, 'modulo_meeting', false, 'modulo_tv', false,
            'cor_primaria', '#1F3A4D', 'cor_destaque', '#C98A3D', 'cor_apoio', '#E9EEF1', 'atualizado_em', now()))).*
    from public.config c where c.empreendimento_id = v_base;

  insert into public.comercial
  select (jsonb_populate_record(null::public.comercial, to_jsonb(c) || jsonb_build_object(
            'id', nextval('public.comercial_id_seq'), 'empreendimento_id', v_emp,
            'mes_tabela', date_trunc('month', now())::date, 'mes_entrega', '2030-12-01',
            'vendedora', 'Residencial Teste SPE Ltda. (hipotética)', 'vendedora_cnpj', null, 'atualizado_em', now()))).*
    from public.comercial c where c.empreendimento_id = v_base;

  insert into public.fila_config (empreendimento_id) values (v_emp);

  -- unidades
  insert into public.unidades (numero, andar, posicao, status, area_privativa, tipologia, empreendimento_id)
  select (a * 100 + f)::text, a, f, 'disponivel',
         case when f <= 2 then 110 when f <= 4 then 90 else 77 end,
         case when f <= 2 then '110 m²' when f <= 4 then '90 m²' else '77 m²' end,
         v_emp
    from generate_series(1, 25) a, generate_series(1, 5) f;

  -- tabela de vendas vigente com 3 captações
  insert into public.tabelas_preco (empreendimento_id, nome, mes_referencia, vigente_desde, origem, criada_por, ativada_por)
  values (v_emp, 'Tabela ' || to_char(now(), 'MM/YYYY'), date_trunc('month', now())::date, now(), 'inicial', 'sistema', 'sistema')
  returning id into v_tab;
  insert into public.captacoes (tabela_id, numero, nome) values
    (v_tab, 1, 'Captação 110 m²'), (v_tab, 2, 'Captação 90 m²'), (v_tab, 3, 'Captação 77 m²');
  insert into public.captacoes_series (tabela_id, captacao, ordem, rotulo, periodicidade, percentual, qtd, base, meses, fim_meses)
  select v_tab, c.n, s.ordem, s.rotulo, s.per, s.pct[c.n], s.qtd, s.base, s.meses, s.fim
    from (values (1), (2), (3)) c(n),
         (values (1, 'Ato', 'Sinal', array[0.05, 0.04, 0.04], 1, 'venda', 0, null::int),
                 (2, '30 / 60 / 90', 'Sinal', array[0.05, 0.04, 0.04], 3, 'venda', 1, null),
                 (3, 'Mensais', 'Mensais', array[0.10, 0.08, 0.06], null, 'venda', 4, 0),
                 (4, 'Semestrais', 'Semestrais', array[0.10, 0.12, 0.12], null, 'venda', 5, -1),
                 (5, 'Única', 'Unica', array[0.05, 0.04, 0.04], 1, 'entrega', -3, null),
                 (6, 'Financiamento', 'Financiamento', array[0.65, 0.68, 0.70], 1, 'entrega', 1, null))
         s(ordem, rotulo, per, pct, qtd, base, meses, fim);
  insert into public.tabelas_preco_itens (tabela_id, unidade_id, preco, captacao)
  select v_tab, u.id,
         round(u.area_privativa * case when u.posicao <= 2 then 9500 when u.posicao <= 4 then 9800 else 10200 end * (1 + 0.004 * (u.andar - 1)), 0),
         case when u.posicao <= 2 then 1 when u.posicao <= 4 then 2 else 3 end
    from public.unidades u where u.empreendimento_id = v_emp;

  -- simulador: um cenário por metragem, com "a partir de" e "preço médio" da tabela
  update public.config set simulador = jsonb_build_object('cenarios', (
    select jsonb_agg(jsonb_build_object('id', 'm' || x.area, 'nome', x.area || ' m²', 'descricao', x.finais,
             'precos', jsonb_build_array(jsonb_build_object('rotulo', 'A partir de', 'valor', x.minimo), jsonb_build_object('rotulo', 'Preço médio', 'valor', x.medio)),
             'captacao', x.captacao, 'pct', x.pct) order by x.area desc)
      from (select u.area_privativa::int as area, min(i.preco) as minimo, round(avg(i.preco), 2) as medio,
                   case u.area_privativa::int when 110 then 'Finais 1 e 2' when 90 then 'Finais 3 e 4' else 'Final 5' end as finais,
                   case u.area_privativa::int when 110 then 35 when 90 then 32 else 30 end as captacao,
                   case u.area_privativa::int when 110 then '{"ato":5,"sinal":5,"mensais":10,"periodicas":10,"unica":5}'::jsonb
                        when 90 then '{"ato":4,"sinal":4,"mensais":8,"periodicas":12,"unica":4}'::jsonb
                        else '{"ato":4,"sinal":4,"mensais":6,"periodicas":12,"unica":4}'::jsonb end as pct
              from public.unidades u join public.tabelas_preco_itens i on i.unidade_id = u.id and i.tabela_id = v_tab
             group by u.area_privativa) x))
   where empreendimento_id = v_emp;
end $$;

-- vitrine (113): fase e cidade
update public.empreendimentos set fase = 'pre_lancamento', cidade = 'Rio Verde, GO' where sigla = 'RT';
