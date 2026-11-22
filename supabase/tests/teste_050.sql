-- Desistência do cliente: devolução de Pix e cliente cancelado
\set ON_ERROR_STOP 0
do $$ declare v_imob uuid; p1 uuid; p2 uuid; s text; begin
  select imobiliaria_id into v_imob from perfis where user_id = '00000000-0000-0000-0000-00000000000d';
  insert into pastas (imobiliaria_id, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao)
  values (v_imob, 'Desiste Com Pix', '99900000050', '64999990000', 'p@t.com', 'Médico') returning id into p1;
  insert into documentos (pasta_id, tipo_id, caminho, nome_arquivo, atual)
  select p1, t.id, 'x/' || t.id, 'a.pdf', true from tipos_documento t where t.ativo and t.eh_pix;
  insert into pastas (imobiliaria_id, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao)
  values (v_imob, 'Desiste Sem Pix', '99900000051', '64999990000', 'p@t.com', 'Médico') returning id into p2;
  perform set_config('t.p1', p1::text, false); perform set_config('t.p2', p2::text, false);
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ declare p1 uuid := current_setting('t.p1')::uuid; p2 uuid := current_setting('t.p2')::uuid; r pastas; begin
  begin perform cliente_desistiu(p1, ' '); raise notice 'FALHOU  aceitou desistência sem motivo';
  exception when others then raise notice '%  Motivo obrigatório', case when sqlerrm = 'MOTIVO_OBRIGATORIO' then 'OK    ' else 'FALHOU' end; end;
  r := cliente_desistiu(p1, 'Comprou em outro lugar');
  raise notice '%  Com Pix: vai para devolução do Pix (%)', case when r.status = 'devolucao_pix' then 'OK    ' else 'FALHOU' end, r.status;
  r := cliente_desistiu(p2, 'Sem crédito');
  raise notice '%  Sem Pix: cliente cancelado (%)', case when r.status = 'cancelada' then 'OK    ' else 'FALHOU' end, r.status;
  begin perform confirmar_devolucao_pix(p1, 'ok'); raise notice 'FALHOU  imobiliária confirmou devolução';
  exception when others then raise notice 'OK      Só a equipe confirma a devolução do Pix'; end;
  begin insert into documentos (pasta_id, tipo_id, caminho, nome_arquivo, atual) values (p2, (select id from tipos_documento limit 1), 'y', 'b.pdf', true);
    raise notice 'FALHOU  pasta cancelada recebeu documento';
  exception when others then raise notice 'OK      Pasta cancelada não recebe documentos'; end;
end $$;
reset role;

do $$ declare p1 uuid := current_setting('t.p1')::uuid; s text; begin
  s := recalcular_pasta(p1);
  raise notice '%  Recalcular não tira da devolução (%)', case when (select status from pastas where id = p1) = 'devolucao_pix' then 'OK    ' else 'FALHOU' end, s;
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare p1 uuid := current_setting('t.p1')::uuid; r pastas; begin
  r := confirmar_devolucao_pix(p1, 'Devolvido pelo Itaú');
  raise notice '%  Equipe confirma devolução: cliente cancelado', case when r.status = 'cancelada' and r.pix_devolvido_por is not null then 'OK    ' else 'FALHOU' end;
  begin perform cliente_desistiu(p1, 'de novo'); raise notice 'FALHOU  desistiu duas vezes';
  exception when others then raise notice 'OK      Não registra desistência duas vezes'; end;
end $$;
reset role;

do $$ begin
  raise notice '%  Funções internas fechadas', case when not has_function_privilege('authenticated', 'public.pasta_tem_pix(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.pastas_trava_desistencia()', 'execute') then 'OK    ' else 'FALHOU' end;
end $$;
