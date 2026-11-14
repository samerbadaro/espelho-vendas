-- Dados de intermediação (rodar depois de teste_022.sql)
\set ON_ERROR_STOP 0
do $$ begin
  raise notice '%  Validação de CPF', case when cpf_valido('529.982.247-25') and not cpf_valido('529.982.247-26') and not cpf_valido('111.111.111-11') then 'OK    ' else 'FALHOU' end;
  raise notice '%  Validação de CNPJ', case when cnpj_valido('11.222.333/0001-81') and not cnpj_valido('11.222.333/0001-82') then 'OK    ' else 'FALHOU' end;
end $$;
set role authenticated;
-- corretor completa o próprio cadastro
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ declare p perfis; begin
  begin perform completar_cadastro('João', '52998224725', 'CRECI 1234'); raise notice 'FALHOU  nome incompleto';
  exception when others then raise notice '%  Exige nome completo (%)', case when sqlerrm='NOME_COMPLETO_OBRIGATORIO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  begin perform completar_cadastro('João Silva', '52998224726', 'CRECI 1234'); raise notice 'FALHOU  CPF inválido';
  exception when others then raise notice '%  CPF inválido é recusado (%)', case when sqlerrm='CPF_INVALIDO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  begin perform completar_cadastro('João Silva', '52998224725', '  '); raise notice 'FALHOU  sem CRECI';
  exception when others then raise notice '%  Exige CRECI (%)', case when sqlerrm='CRECI_OBRIGATORIO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  p := completar_cadastro('João  Silva', '529.982.247-25', 'creci 12345-f');
  raise notice '%  Corretor completa nome, CPF e CRECI', case when p.nome='João Silva' and p.cpf='52998224725' and p.creci='CRECI 12345-F' then 'OK    ' else 'FALHOU' end;
end $$;
-- imobiliária completa também CNPJ e CRECI PJ
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ declare p perfis; begin
  begin perform completar_cadastro('Dona Imob', '52998224725', 'F-1', '11222333000182', 'J-1'); raise notice 'FALHOU  CNPJ inválido';
  exception when others then raise notice '%  CNPJ inválido é recusado (%)', case when sqlerrm='CNPJ_INVALIDO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  p := completar_cadastro('Dona Imob', '52998224725', 'F-1', '11.222.333/0001-81', 'j-999');
  raise notice '%  Imobiliária completa os dados dela e da empresa', case when p.cpf is not null
    and (select cnpj='11222333000181' and creci_pj='J-999' from imobiliarias where id=p.imobiliaria_id) then 'OK    ' else 'FALHOU' end;
  -- imobiliária corrige o CRECI do corretor dela
  p := salvar_dados_login('00000000-0000-0000-0000-0000000000c1', 'João Silva', '52998224725', 'F-777');
  raise notice '%  Imobiliária corrige os dados do seu corretor', case when p.creci='F-777' then 'OK    ' else 'FALHOU' end;
  begin perform salvar_dados_login('00000000-0000-0000-0000-00000000000b', 'Outra Pessoa', '52998224725', 'F-1'); raise notice 'FALHOU  imobiliária alterou outro';
  exception when others then raise notice '%  Imobiliária não altera login que não é seu corretor (%)', case when sqlerrm='SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
-- administrador: CNPJ repetido é barrado; cria imobiliária completa
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ declare i imobiliarias; begin
  begin perform salvar_dados_imobiliaria(null, 'Outra Imob', '11222333000181', 'J-2'); raise notice 'FALHOU  CNPJ repetido';
  exception when others then raise notice '%  CNPJ já usado por outra imobiliária é barrado (%)', case when sqlerrm='CNPJ_EM_USO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
  i := salvar_dados_imobiliaria(null, 'Imob Completa', '11.444.777/0001-61', 'J-3');
  raise notice '%  Administrador cadastra imobiliária com CNPJ e CRECI PJ', case when i.cnpj='11444777000161' then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
-- aprovação do cadastro público leva os dados
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000f9', 'nova@completa.com');
insert into solicitacoes_imobiliaria (user_id, imobiliaria_nome, cnpj, creci, responsavel, responsavel_cpf, responsavel_creci, email, telefone)
values ('00000000-0000-0000-0000-0000000000f9', 'Imob do Link', '45723174000110', 'J-55', 'Paula Link', '52998224725', 'F-55', 'nova@completa.com', '64999990009');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ declare s solicitacoes_imobiliaria; begin
  s := aprovar_solicitacao((select id from solicitacoes_imobiliaria where email='nova@completa.com'));
  raise notice '%  Aprovação leva CNPJ, CRECI PJ, CPF e CRECI PF', case when
    (select cnpj='45723174000110' and creci_pj='J-55' from imobiliarias where id=s.imobiliaria_id)
    and (select cpf='52998224725' and creci='F-55' from perfis where user_id='00000000-0000-0000-0000-0000000000f9') then 'OK    ' else 'FALHOU' end;
end $$;
reset role;
