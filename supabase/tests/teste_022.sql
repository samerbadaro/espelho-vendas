-- Cadastro de imobiliárias pelo link público
\set ON_ERROR_STOP 0
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000f1', 'dono@nova.com'),
  ('00000000-0000-0000-0000-0000000000f2', 'dono@repetida.com'),
  ('00000000-0000-0000-0000-0000000000f3', 'spam@x.com');
insert into solicitacoes_imobiliaria (user_id, imobiliaria_nome, responsavel, email, telefone) values
  ('00000000-0000-0000-0000-0000000000f1', 'Imobiliária Nova', 'Carlos Dono', 'dono@nova.com', '64999990001'),
  ('00000000-0000-0000-0000-0000000000f2', 'Imobiliária A', 'Rita Dona', 'dono@repetida.com', '64999990002'),
  ('00000000-0000-0000-0000-0000000000f3', 'Spam', 'Spam Spam', 'spam@x.com', '64999990003');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f1', false) \g /dev/null
do $$ begin
  raise notice '%  Quem se cadastrou vê só a própria solicitação', case when (select count(*) from solicitacoes_imobiliaria)=1 then 'OK    ' else 'FALHOU' end;
  raise notice '%  Sem aprovação, não tem perfil (sem acesso)', case when not exists(select 1 from perfis where user_id=auth.uid()) then 'OK    ' else 'FALHOU' end;
  begin perform aprovar_solicitacao((select id from solicitacoes_imobiliaria limit 1)); raise notice 'FALHOU  aprovou a si mesmo';
  exception when others then raise notice '%  Não aprova o próprio cadastro (%)', case when sqlerrm='SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ begin
  raise notice '%  Sec. Vendas não vê solicitações', case when (select count(*) from solicitacoes_imobiliaria)=0 then 'OK    ' else 'FALHOU' end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ declare s solicitacoes_imobiliaria; begin
  raise notice '%  Administrador vê todas', case when (select count(*) from solicitacoes_imobiliaria)=3 then 'OK    ' else 'FALHOU' end;
  s := aprovar_solicitacao((select id from solicitacoes_imobiliaria where email='dono@nova.com'));
  raise notice '%  Aprovar cria a imobiliária e o login master', case when s.status='aprovada'
    and exists(select 1 from imobiliarias where nome='Imobiliária Nova' and id=s.imobiliaria_id)
    and exists(select 1 from perfis where user_id='00000000-0000-0000-0000-0000000000f1' and papel='imobiliaria' and imobiliaria_id=s.imobiliaria_id and not trocar_senha) then 'OK    ' else 'FALHOU' end;
  begin perform aprovar_solicitacao(s.id); raise notice 'FALHOU  aprovou duas vezes';
  exception when others then raise notice '%  Não aprova duas vezes (%)', case when sqlerrm='SOLICITACAO_JA_ANALISADA' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  begin perform aprovar_solicitacao((select id from solicitacoes_imobiliaria where email='dono@repetida.com')); raise notice 'FALHOU  nome repetido';
  exception when others then raise notice '%  Nome já existente é barrado (%)', case when sqlerrm='NOME_EM_USO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  s := aprovar_solicitacao((select id from solicitacoes_imobiliaria where email='dono@repetida.com'), null, 'aaaaaaaa-0000-0000-0000-000000000001');
  raise notice '%  Pode vincular a uma imobiliária já cadastrada', case when s.imobiliaria_id='aaaaaaaa-0000-0000-0000-000000000001' then 'OK    ' else 'FALHOU' end;
  begin perform recusar_solicitacao((select id from solicitacoes_imobiliaria where email='spam@x.com'), ''); raise notice 'FALHOU  recusa sem motivo';
  exception when others then raise notice '%  Recusa exige motivo (%)', case when sqlerrm='MOTIVO_OBRIGATORIO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  s := recusar_solicitacao((select id from solicitacoes_imobiliaria where email='spam@x.com'), 'Imobiliária não identificada');
  raise notice '%  Recusar guarda o motivo e não dá acesso', case when s.status='recusada'
    and not exists(select 1 from perfis where user_id='00000000-0000-0000-0000-0000000000f3') then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
