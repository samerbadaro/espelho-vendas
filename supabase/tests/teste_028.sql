\set ON_ERROR_STOP 0
-- prepara: uma pasta aprovada do corretor c1 (imobiliária A) reservada numa unidade
do $$ declare v_p uuid; v_u uuid; v_ver int; begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
  insert into pastas (imobiliaria_id, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao, estado_civil, criado_por_id)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'Cliente 028', '99900000028', '64999990028', 't28@x.com', 'Teste', 'solteiro', '00000000-0000-0000-0000-0000000000c1')
  returning id into v_p;
  update pastas set status = 'aprovada', criado_por_id = '00000000-0000-0000-0000-0000000000c1' where id = v_p;
  select id, versao into v_u, v_ver from unidades where status = 'disponivel' order by numero limit 1;
  perform alterar_status(v_u, 'reservada', v_ver, p_pasta => v_p);
end $$;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ begin
  raise notice '%  Corretor vê a negociação da própria pasta', case when exists (select 1 from negociacoes n join pastas p on p.id = n.pasta_id where p.comprador_nome = 'Cliente 028' and n.ativa) then 'OK    ' else 'FALHOU' end;
  begin perform mover_etapa((select id from pastas where comprador_nome = 'Cliente 028'), 'contrato_confeccao', (select unidade_id from negociacoes where ativa limit 1));
    raise notice 'FALHOU  corretor moveu etapa';
  exception when others then raise notice '%  Corretor não move etapa (%)', case when sqlerrm = 'SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', false) \g /dev/null
do $$ begin
  raise notice '%  Outro corretor da mesma imobiliária não vê', case when not exists (select 1 from negociacoes n join pastas p on p.id = n.pasta_id where p.comprador_nome = 'Cliente 028') and (select count(*) from negociacoes where pasta_id = (select id from pastas where comprador_nome='Cliente 028')) = 0 then 'OK    ' else 'FALHOU' end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ begin
  raise notice '%  Imobiliária vê as negociações dos seus corretores', case when exists (select 1 from negociacoes n join pastas p on p.id = n.pasta_id where p.comprador_nome = 'Cliente 028') then 'OK    ' else 'FALHOU' end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000e', false) \g /dev/null
do $$ begin
  raise notice '%  Outra imobiliária não vê nenhuma negociação dela', case when (select count(*) from negociacoes where pasta_id in (select id from pastas)) = 0 and (select count(*) from negociacoes n join pastas p on p.id=n.pasta_id where p.imobiliaria_id='aaaaaaaa-0000-0000-0000-000000000001') = 0 then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
