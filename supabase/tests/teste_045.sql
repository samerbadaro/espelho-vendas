-- Pix do sinal (rodar depois do teste_040)
\set ON_ERROR_STOP 0
do $$ declare v_imob uuid; p uuid; c cobrancas_pix; s text; begin
  select id into v_imob from imobiliarias limit 1;
  insert into pastas (imobiliaria_id, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao)
  values (v_imob, 'Pix Teste', '99900000045', '64999990000', 'p@t.com', 'Médico') returning id into p;
  -- anexa todos os documentos obrigatórios de solteiro
  insert into documentos (pasta_id, tipo_id, caminho, nome_arquivo, atual)
  select p, t.id, 'x/' || t.id, 'a.pdf', true from tipos_documento t where t.ativo and 'solteiro' = any(t.obrigatorio_para);
  s := recalcular_pasta(p);
  raise notice '%  Modo comprovante: com o comprovante anexado fica pronta (%)', case when s = 'pronta' then 'OK    ' else 'FALHOU' end, s;
  update config set pix_modo = 'integrado', pix_valor = 2000 where id = 1;
  s := (select status from pastas where id = p);
  raise notice '%  Modo integrado: sem Pix pago fica incompleta (%)', case when s = 'incompleta' then 'OK    ' else 'FALHOU' end, s;
  delete from documentos where pasta_id = p and tipo_id in (select id from tipos_documento where eh_pix);
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', true);
  c := gerar_cobranca_pix(p);
  raise notice '%  Gera Pix de R$ % pendente', case when c.status = 'pendente' and c.valor = 2000 then 'OK    ' else 'FALHOU' end, c.valor;
  raise notice '%  Gerar de novo devolve o mesmo Pix ainda válido', case when (gerar_cobranca_pix(p)).id = c.id then 'OK    ' else 'FALHOU' end;
  c := simular_pagamento_pix(c.id);
  s := (select status from pastas where id = p);
  raise notice '%  Pago: pasta pronta sem anexar comprovante (%)', case when c.status = 'pago' and s = 'pronta' then 'OK    ' else 'FALHOU' end, s;
  begin perform gerar_cobranca_pix(p); raise notice 'FALHOU  gerou Pix de pasta já paga';
  exception when others then raise notice 'OK      Pasta paga não gera outro Pix'; end;
  update config set pix_provedor = 'itau' where id = 1;
  insert into pastas (imobiliaria_id, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao)
  values (v_imob, 'Pix Teste 2', '99900000046', '64999990000', 'p@t.com', 'Médico') returning id into p;
  begin perform gerar_cobranca_pix(p); raise notice 'FALHOU  gerou Pix com provedor não ligado';
  exception when others then raise notice '%  Provedor real ainda não ligado (%)', case when sqlerrm = 'PROVEDOR_NAO_CONFIGURADO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  update config set pix_modo = 'comprovante', pix_provedor = 'simulado' where id = 1;
end $$;
