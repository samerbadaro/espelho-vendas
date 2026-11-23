-- Espelho acompanha o envelope (rodar depois do teste_046)
\set ON_ERROR_STOP 0
create temp table _c as select p.id as proposta, p.pasta_id as pasta, p.unidade_id as unidade
  from propostas p where p.pasta_id = (select id from pastas where comprador_cpf = '99900000028') and p.status = 'aprovada' limit 1;
do $$ declare v_env uuid; s text; st text; begin
  -- deixa a unidade em "Proposta recebida" com a negociação da pasta
  perform set_config('espelho.sistema', 'sim', false);
  if (select status from unidades where id = (select unidade from _c)) <> 'proposta' then
    perform alterar_status((select unidade from _c), 'proposta', (select versao from unidades where id = (select unidade from _c)), null, null, null, null, 450000, 99.5, (select pasta from _c));
  end if;
  perform set_config('espelho.sistema', '', false);
  insert into envelopes (pasta_id, proposta_id, status) select pasta, proposta, 'enviado' from _c returning id into v_env;
  s := contrato_espelho(v_env, 'enviado');
  raise notice '%  Envelope enviado: Contrato em assinatura (%)', case when (select status from unidades where id = (select unidade from _c)) = 'contrato' then 'OK    ' else 'FALHOU' end, s;
  s := contrato_espelho(v_env, 'cancelado');
  raise notice '%  Envelope cancelado: volta para Proposta recebida (%)', case when (select status from unidades where id = (select unidade from _c)) = 'proposta' then 'OK    ' else 'FALHOU' end, s;
  s := contrato_espelho(v_env, 'assinado');
  raise notice '%  Todos assinaram: Vendida (%)', case when (select status from unidades where id = (select unidade from _c)) = 'vendida' then 'OK    ' else 'FALHOU' end, s;
  s := contrato_espelho(v_env, 'cancelado');
  raise notice '%  Unidade vendida não volta sozinha (%)', case when (select status from unidades where id = (select unidade from _c)) = 'vendida' then 'OK    ' else 'FALHOU' end, s;
  update envelopes set status = 'cancelado' where id = v_env;
end $$;
do $$ begin
  raise notice '%  Só o servidor chama a função', case when not has_function_privilege('authenticated', 'public.contrato_espelho(uuid,text)', 'execute')
    and has_function_privilege('service_role', 'public.contrato_espelho(uuid,text)', 'execute') then 'OK    ' else 'FALHOU' end;
end $$;
