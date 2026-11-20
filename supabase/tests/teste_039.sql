-- Regime de bens e participação do cônjuge (como superusuário, regras das funções/gatilhos)
\set ON_ERROR_STOP 0
do $$ declare v_imob uuid; p uuid; s text; r pastas; begin
  select id into v_imob from imobiliarias limit 1;
  insert into pastas (imobiliaria_id, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao, estado_civil, conjuge_nome, conjuge_cpf, conjuge_profissao)
  values (v_imob, 'Casado Teste', '99900000039', '64999990000', 'c@t.com', 'Médico', 'casado', 'Esposa', '52998224725', 'Arquiteta') returning id into p;
  select status into s from pastas where id = p;
  raise notice '%  Casado sem regime: cônjuge exigido como antes (status %)', case when conjuge_no_contrato('casado', null, true) then 'OK    ' else 'FALHOU' end, s;
  update pastas set regime_bens = 'separacao_total', conjuge_participa = false where id = p;
  select * into r from pastas where id = p;
  raise notice '%  Separação total sem participação apaga dados do cônjuge', case when r.conjuge_nome is null and r.conjuge_cpf is null then 'OK    ' else 'FALHOU' end;
  raise notice '%  Documentos do cônjuge deixam de faltar', case when not exists (select 1 from tipos_documento t where t.ativo and 'casado' = any(t.obrigatorio_para) and t.pessoa = 'conjuge' and conjuge_no_contrato(r.estado_civil, r.regime_bens, r.conjuge_participa)) then 'OK    ' else 'FALHOU' end;
  update pastas set regime_bens = 'comunhao_parcial' where id = p;
  select * into r from pastas where id = p;
  raise notice '%  Comunhão parcial força participação do cônjuge', case when r.conjuge_participa and conjuge_no_contrato(r.estado_civil, r.regime_bens, r.conjuge_participa) then 'OK    ' else 'FALHOU' end;
  update pastas set regime_bens = 'separacao_obrigatoria', conjuge_participa = true where id = p;
  select * into r from pastas where id = p;
  raise notice '%  Separação obrigatória com participação mantém o cônjuge', case when conjuge_no_contrato(r.estado_civil, r.regime_bens, r.conjuge_participa) then 'OK    ' else 'FALHOU' end;
  update pastas set estado_civil = 'solteiro' where id = p;
  select * into r from pastas where id = p;
  raise notice '%  Solteiro limpa o regime', case when r.regime_bens is null and r.conjuge_participa then 'OK    ' else 'FALHOU' end;
  update pastas set estado_civil = 'casado', regime_bens = null where id = p;
  begin perform submeter_pasta(p); raise notice 'FALHOU  submeteu sem regime';
  exception when others then raise notice '%  Casado sem regime não submete (%)', case when sqlerrm in ('REGIME_NAO_INFORMADO', 'SEM_PERMISSAO') then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  begin update pastas set regime_bens = 'qualquer' where id = p; raise notice 'FALHOU  aceitou regime inválido';
  exception when check_violation then raise notice 'OK      Regime inválido recusado'; end;
end $$;
