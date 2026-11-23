-- Comissão com coordenação de vendas (rodar depois do teste_035)
\set ON_ERROR_STOP 0
do $$ declare c comercial; r jsonb; v_un uuid := (select id from unidades where tabela is not null order by numero limit 1); begin
  select * into c from comercial where id = 1;
  raise notice '%  Parâmetro: imobiliária 5%% + coordenação 0,5%% em 2 parcelas', case when c.comissao_pct = 0.05 and c.coordenacao_pct = 0.005 and c.coordenacao_parcelas = 2 then 'OK    ' else 'FALHOU' end;
  -- sinal de 7,8% (abaixo de 7,86%) não cobre 5,5%; 8% cobre
  r := pv_proposta(v_un, jsonb_build_array(jsonb_build_object('qtd', 1, 'periodicidade', 'Sinal', 'vencimento', current_date + 1, 'valor', 7800),
                                           jsonb_build_object('qtd', 1, 'periodicidade', 'Financiamento', 'vencimento', current_date + 400, 'valor', 92200)));
  raise notice '%  Comissão soma imobiliária e coordenação (5,5%% de 100 mil = %)', case when (r ->> 'comissao')::numeric = 5500 then 'OK    ' else 'FALHOU' end, r ->> 'comissao';
  raise notice '%  Sinal de 7,8%% não cobre a comissão', case when not (r ->> 'comissao_coberta')::boolean then 'OK    ' else 'FALHOU' end;
  r := pv_proposta(v_un, jsonb_build_array(jsonb_build_object('qtd', 1, 'periodicidade', 'Sinal', 'vencimento', current_date + 1, 'valor', 8000),
                                           jsonb_build_object('qtd', 1, 'periodicidade', 'Financiamento', 'vencimento', current_date + 400, 'valor', 92000)));
  raise notice '%  Sinal de 8%% cobre a comissão', case when (r ->> 'comissao_coberta')::boolean then 'OK    ' else 'FALHOU' end;
  begin update comercial set coordenacao_parcelas = 4 where id = 1; raise notice 'FALHOU  aceitou coordenação em 4 parcelas';
  exception when check_violation then raise notice 'OK      Coordenação em no máximo 3 parcelas'; end;
end $$;
