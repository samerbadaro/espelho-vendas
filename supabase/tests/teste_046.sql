-- Envelope único (rodar depois do teste_045)
\set ON_ERROR_STOP 0
create temp table _e as select (select id from pastas where comprador_cpf = '99900000028') as pasta,
  (select id from propostas where pasta_id = (select id from pastas where comprador_cpf = '99900000028') and status = 'aprovada' limit 1) as proposta;
grant select on _e to authenticated;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare c contratos; begin
  begin perform salvar_anexo_fixo('Memorial', 'fixos/m.pdf', 'm.pdf', 1); raise notice 'FALHOU  Sec. Vendas cadastrou documento fixo';
  exception when others then raise notice 'OK      Só administrador cadastra documento fixo'; end;
  c := registrar_contrato((select pasta from _e), (select proposta from _e), 'carta_proposta', 'Carta Proposta', (select pasta from _e)::text || '/cp.pdf', '{}');
  raise notice '%  Carta proposta registrada como documento', case when c.documento = 'carta_proposta' then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
-- envelope ativo (o servidor grava com a chave secreta)
insert into envelopes (pasta_id, proposta_id, documentos) select pasta, proposta, jsonb_build_array(jsonb_build_object('tipo', 'contrato', 'id', (select id from contratos where documento = 'carta_proposta' limit 1))) from _e;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare id_ uuid := (select id from contratos where documento = 'carta_proposta' limit 1); begin
  begin perform enviar_versao_contrato(id_, null, (select pasta from _e)::text || '/x.pdf'); raise notice 'FALHOU  ajustou documento dentro de envelope';
  exception when others then raise notice 'OK      Documento em envelope ativo não aceita ajuste'; end;
  begin perform cancelar_contrato(id_); raise notice 'FALHOU  cancelou documento dentro de envelope';
  exception when others then raise notice 'OK      Documento em envelope ativo não pode ser cancelado'; end;
end $$;
reset role;
do $$ begin
  begin insert into envelopes (pasta_id, proposta_id) select pasta, proposta from _e; raise notice 'FALHOU  dois envelopes ativos';
  exception when unique_violation then raise notice 'OK      Só um envelope ativo por unidade'; end;
  update envelopes set status = 'cancelado';
  raise notice '%  Envelope cancelado libera o documento', case when not em_envelope_ativo((select id from contratos where documento = 'carta_proposta' limit 1)) then 'OK    ' else 'FALHOU' end;
end $$;
