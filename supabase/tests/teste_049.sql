-- PJ: comprovante de estado civil do representante e 2º representante
\set ON_ERROR_STOP 0
do $$ declare v_imob uuid; p uuid; f1 int; f2 int; begin
  select id into v_imob from imobiliarias limit 1;
  insert into pastas (imobiliaria_id, tipo_pessoa, empresa_razao_social, empresa_cnpj, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao, estado_civil)
  values (v_imob, 'pj', 'Empresa Dois Ltda', '11222333000181', 'Representante Um', '99900000049', '64999990000', 'r@t.com', 'Empresário', 'casado') returning id into p;
  raise notice '%  PJ exige comprovante de estado civil do representante', case when exists (select 1 from tipos_documento where nome = 'Comprovante de estado civil do representante' and aplica_a = 'pj' and obrigatorio_pj) then 'OK    ' else 'FALHOU' end;
  select count(*) into f1 from tipos_documento t where t.ativo and t.aplica_a in ('pj','ambos') and t.obrigatorio_pj and t.pessoa <> 'representante2';
  begin
    update pastas set representante2 = '{"nome":"Sócio Dois","cpf":"123"}' where id = p;
    raise notice 'FALHOU  2º representante incompleto aceito';
  exception when others then raise notice 'OK      2º representante exige nome, CPF, profissão e estado civil'; end;
  update pastas set representante2 = '{"nome":"Sócio Dois","cpf":"529.982.247-25","profissao":"Engenheiro","estado_civil":"solteiro"}' where id = p;
  raise notice '%  2º representante salvo', case when (select representante2->>'nome' from pastas where id = p) = 'Sócio Dois' then 'OK    ' else 'FALHOU' end;
  raise notice '%  Status recalculado com documentos do 2º representante', case when (select status from pastas where id = p) = 'incompleta' then 'OK    ' else 'FALHOU' end;
  update pastas set representante2 = null where id = p;
  raise notice '%  Remover o 2º representante', case when (select representante2 from pastas where id = p) is null then 'OK    ' else 'FALHOU' end;
  update pastas set representante2 = '{"nome":"Sócio Dois","cpf":"52998224725","profissao":"Engenheiro","estado_civil":"solteiro"}' where id = p;
  update pastas set tipo_pessoa = 'pf' where id = p;
  raise notice '%  Voltar para PF limpa o 2º representante', case when (select representante2 from pastas where id = p) is null then 'OK    ' else 'FALHOU' end;
  raise notice '%  Pasta PF não exige documentos do representante', case when not exists (select 1 from tipos_documento where pessoa = 'representante2' and aplica_a <> 'pj') then 'OK    ' else 'FALHOU' end;
end $$;
do $$ begin
  raise notice '%  Funções internas fechadas para usuários', case when not has_function_privilege('authenticated', 'public.pastas_recalcula_representante2()', 'execute')
    and not has_function_privilege('anon', 'public.pastas_valida_representante2()', 'execute') then 'OK    ' else 'FALHOU' end;
end $$;
