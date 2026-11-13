-- Reserva no espelho exige pasta aprovada (rodar depois de teste_013.sql).
-- Pasta da Maria (CPF 12345678901) está aprovada e sem unidade; a do CPF 22233344455 está incompleta.
\set ON_ERROR_STOP 0
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$
declare
  p   uuid := (select id from pastas where comprador_cpf='12345678901');
  inc uuid := (select id from pastas where comprador_cpf='22233344455');
  u501 uuid := (select id from unidades where numero='501');
  u unidades; pa pastas;
  ver int;
begin
  ver := (select versao from unidades where id=u501);
  begin perform alterar_status(u501, 'reservada', ver); raise notice 'FALHOU  reservar sem pasta';
  exception when others then raise notice '%  Reservar sem pasta é bloqueado (%)', case when sqlerrm='PASTA_OBRIGATORIA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;

  begin perform alterar_status(u501, 'reservada', ver, p_pasta => inc); raise notice 'FALHOU  pasta incompleta';
  exception when others then raise notice '%  Pasta sem documentação aprovada não reserva (%)', case when sqlerrm='PASTA_NAO_APROVADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;

  begin perform alterar_status(u501, 'proposta', ver, null, null, null, null, 300000, 85); raise notice 'FALHOU  pular para proposta sem pasta';
  exception when others then raise notice '%  Pular para Proposta também exige pasta (%)', case when sqlerrm='PASTA_OBRIGATORIA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;

  u := alterar_status(u501, 'reservada', ver, p_pasta => p);
  select * into pa from pastas where id=p;
  raise notice '%  Reserva com pasta: unidade reservada, dados vêm da pasta, funil em Reserva', case when u.status='reservada'
    and exists(select 1 from negociacoes where unidade_id=u501 and ativa and pasta_id=p and cliente='Maria Teste' and imobiliaria is not null and corretor is not null)
    and pa.etapa_venda='reserva' and pa.unidade_id=u501 then 'OK    ' else 'FALHOU' end;
  raise notice '%  Histórico do espelho guarda a pasta', case when exists(select 1 from historico where unidade_id=u501 and status_novo='reservada' and detalhes ? 'pasta') then 'OK    ' else 'FALHOU' end;

  begin perform alterar_status((select id from unidades where numero='502'), 'reservada', (select versao from unidades where numero='502'), p_pasta => p);
    raise notice 'FALHOU  mesma pasta em duas unidades';
  exception when others then raise notice '%  A mesma pasta não reserva duas unidades (%)', case when sqlerrm='PASTA_JA_TEM_UNIDADE' then 'OK    ' else 'FALHOU' end, sqlerrm; end;

  begin perform alterar_status(u501, 'proposta', u.versao, p_pasta => inc); raise notice 'FALHOU  trocar pasta';
  exception when others then raise notice '%  Não troca a pasta de uma unidade em negociação (%)', case when sqlerrm='UNIDADE_COM_OUTRA_PASTA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;

  begin perform alterar_status(u501, 'proposta', u.versao); raise notice 'FALHOU  proposta sem valor';
  exception when others then raise notice '%  Proposta continua pedindo valor e PV (%)', case when sqlerrm='DADOS_PROPOSTA_OBRIGATORIOS' then 'OK    ' else 'FALHOU' end, sqlerrm; end;

  u := alterar_status(u501, 'proposta', u.versao, null, null, null, null, 300000, 85);
  raise notice '%  Proposta no espelho: funil em Contrato em confecção', case when u.status='proposta'
    and (select etapa_venda from pastas where id=p)='contrato_confeccao' then 'OK    ' else 'FALHOU' end;
  u := alterar_status(u501, 'contrato', u.versao);
  raise notice '%  Contrato no espelho: funil em Enviado para assinatura', case when (select etapa_venda from pastas where id=p)='enviado_assinatura' then 'OK    ' else 'FALHOU' end;
  u := alterar_status(u501, 'vendida', u.versao);
  raise notice '%  Vendida no espelho: funil em Assinado', case when (select etapa_venda from pastas where id=p)='assinado' then 'OK    ' else 'FALHOU' end;

  begin perform alterar_status(u501, 'disponivel', u.versao); raise notice 'FALHOU  liberar sem motivo';
  exception when others then raise notice '%  Liberar sem motivo é bloqueado (%)', case when sqlerrm='MOTIVO_OBRIGATORIO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  u := alterar_status(u501, 'disponivel', u.versao, 'Cliente desistiu');
  raise notice '%  Liberar devolve a pasta para Pasta aprovada, sem unidade', case when u.status='disponivel'
    and (select etapa_venda='aprovada' and unidade_id is null from pastas where id=p)
    and not exists(select 1 from negociacoes where unidade_id=u501 and ativa) then 'OK    ' else 'FALHOU' end;

  u := alterar_status(u501, 'reservada', u.versao, p_pasta => p);
  raise notice '%  Depois de liberada, a pasta pode reservar de novo', case when u.status='reservada' then 'OK    ' else 'FALHOU' end;
end $$;
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ begin
  perform alterar_status((select id from unidades where numero='503'), 'reservada', (select versao from unidades where numero='503'),
                         p_pasta => (select id from pastas where comprador_cpf='12345678901'));
  raise notice 'FALHOU  Imobiliária não reserva';
exception when others then raise notice '%  Imobiliária não reserva no espelho (%)', case when sqlerrm='SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end $$;
reset role;
