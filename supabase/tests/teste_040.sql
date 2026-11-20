-- Pessoa Jurídica e módulo de contratos (rodar depois do teste_038)
\set ON_ERROR_STOP 0
do $$ declare v_imob uuid; p uuid; s text; begin
  select id into v_imob from imobiliarias limit 1;
  begin
    insert into pastas (imobiliaria_id, tipo_pessoa, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao)
    values (v_imob, 'pj', 'Representante', '52998224725', '64999990000', 'r@t.com', 'Empresário');
    raise notice 'FALHOU  PJ sem razão social/CNPJ aceita';
  exception when check_violation then raise notice 'OK      PJ exige razão social e CNPJ'; end;
  insert into pastas (imobiliaria_id, tipo_pessoa, empresa_razao_social, empresa_cnpj, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao, estado_civil, conjuge_nome, conjuge_cpf, conjuge_profissao)
  values (v_imob, 'pj', 'Empresa Teste Ltda', '11222333000181', 'Representante', '99900000040', '64999990000', 'r@t.com', 'Empresário', 'casado', 'Esposa', '52998224725', 'X') returning id into p;
  raise notice '%  PJ: cônjuge do representante não entra', case when (select conjuge_nome from pastas where id = p) is null then 'OK    ' else 'FALHOU' end;
  raise notice '%  PJ: documentos exigidos são os da empresa (faltam %)', case when exists (select 1 from tipos_documento where aplica_a = 'pj' and obrigatorio_pj) then 'OK    ' else 'FALHOU' end,
    (select count(*) from tipos_documento t where t.ativo and t.aplica_a in ('pj','ambos') and t.obrigatorio_pj);
  raise notice '%  PJ: certidão de casamento não é exigida', case when not exists (select 1 from tipos_documento t where t.nome = 'Certidão de casamento' and t.aplica_a <> 'pf') then 'OK    ' else 'FALHOU' end;
  update pastas set tipo_pessoa = 'pf' where id = p;
  raise notice '%  Voltar para PF limpa os dados da empresa', case when (select empresa_cnpj from pastas where id = p) is null then 'OK    ' else 'FALHOU' end;
end $$;

create temp table _c as select (select id from pastas where comprador_cpf = '99900000028') as pasta,
  (select id from propostas where pasta_id = (select id from pastas where comprador_cpf = '99900000028') and status = 'aprovada' limit 1) as proposta;
grant select on _c to authenticated;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare c contratos; begin
  begin perform importar_quadro_areas('[{"numero":"101"}]'); raise notice 'FALHOU  Sec. Vendas importou quadro de áreas';
  exception when others then raise notice 'OK      Só administrador importa o quadro de áreas'; end;
  perform salvar_dados_contrato((select pasta from _c), '{"comprador":{"nome":"Fulano"}}', false);
  begin perform registrar_contrato((select pasta from _c), (select proposta from _c), 'quadro_resumo', 'QR', (select pasta from _c)::text || '/a.pdf', '{}');
    raise notice 'FALHOU  emitiu sem dados conferidos';
  exception when others then raise notice '%  Sem dados conferidos não emite (%)', case when sqlerrm = 'DADOS_NAO_CONFERIDOS' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  perform salvar_dados_contrato((select pasta from _c), '{"comprador":{"nome":"Fulano"}}', true);
  begin perform registrar_contrato((select pasta from _c), (select proposta from _c), 'quadro_resumo', 'QR', (select pasta from _c)::text || '/a.pdf', '{}');
    raise notice 'FALHOU  emitiu sem pagamento conferido';
  exception when others then raise notice '%  Sem fluxo conferido não emite (%)', case when sqlerrm = 'PAGAMENTO_NAO_CONFERIDO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  perform conferir_pagamento((select pasta from _c), '[{"nome":"Imob","documento":"11222333000181","valor":1000}]', true);
  c := registrar_contrato((select pasta from _c), (select proposta from _c), 'quadro_resumo', 'Quadro Resumo', (select pasta from _c)::text || '/a.pdf', '{}');
  raise notice '%  Emitido nº % aguardando validação', case when c.numero >= 1001 and c.validacao = 'aguardando' then 'OK    ' else 'FALHOU' end, c.numero;
  c := validar_contrato(c.id);
  raise notice '%  Validado', case when c.validacao = 'validado' then 'OK    ' else 'FALHOU' end;
  c := cancelar_contrato(c.id);
  raise notice '%  Cancelado', case when c.cancelado_em is not null then 'OK    ' else 'FALHOU' end;
  begin perform registrar_contrato((select pasta from _c), (select proposta from _c), 'normas', 'N', 'outra/a.pdf', '{}');
    raise notice 'FALHOU  aceitou caminho de outra pasta';
  exception when others then raise notice 'OK      Arquivo precisa ficar na pasta do cliente'; end;
end $$;
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ begin
  raise notice '%  Administrador importa quadro de áreas (% linhas)', case when importar_quadro_areas('[{"numero":"101","area_privativa":"35.5","fracao_ideal":"0.0012"},{"numero":"102"}]') = 2 then 'OK    ' else 'FALHOU' end, 2;
  begin perform importar_quadro_areas('[{"numero":"101"},{"numero":"101"}]'); raise notice 'FALHOU  aceitou unidade repetida';
  exception when others then raise notice 'OK      Unidade repetida recusada'; end;
  perform salvar_empreendimento_contrato('{"vendedora":{"razao_social":"X"}}');
  raise notice 'OK      Administrador salva dados da incorporação';
end $$;
reset role;

do $$ declare u text; n int; m int; begin
  foreach u in array array['0000000000c1', '00000000000d', '00000000000b'] loop
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-' || u, false);
    execute 'set local role authenticated';
    select count(*) into n from contratos; select count(*) into m from unidade_areas;
    execute 'reset role';
    raise notice '%  % vê contratos/áreas? %/%', case when ((n + m) > 0) = (u = '00000000000b') then 'OK    ' else 'FALHOU' end,
      case u when '0000000000c1' then 'Corretor' when '00000000000d' then 'Imobiliária' else 'Sec. Vendas' end, n, m;
  end loop;
end $$;

-- 042: versões ajustadas
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare c contratos; begin
  c := registrar_contrato((select pasta from _c), (select proposta from _c), 'normas', 'Normas', (select pasta from _c)::text || '/n.pdf', '{}', (select pasta from _c)::text || '/n.docx');
  raise notice '%  Emitido com PDF e Word (versão %)', case when c.caminho_docx is not null and c.versao = 1 and (select count(*) from contrato_versoes where contrato_id = c.id) = 1 then 'OK    ' else 'FALHOU' end, c.versao;
  c := validar_contrato(c.id);
  c := enviar_versao_contrato(c.id, (select pasta from _c)::text || '/n2.docx', null);
  raise notice '%  Ajuste vira versão 2 e volta para aguardando validação', case when c.versao = 2 and c.validacao = 'aguardando' and c.caminho is null then 'OK    ' else 'FALHOU' end;
  begin perform enviar_versao_contrato(c.id, null, null); raise notice 'FALHOU  aceitou ajuste sem arquivo';
  exception when others then raise notice 'OK      Ajuste exige arquivo'; end;
  begin perform enviar_versao_contrato(c.id, 'outra/x.docx', null); raise notice 'FALHOU  aceitou arquivo de outra pasta';
  exception when others then raise notice 'OK      Ajuste só na pasta do cliente'; end;
end $$;
reset role;
