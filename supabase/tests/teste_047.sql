-- Leads: rodízio por cota, prazo, redistribuição, dono do lead, funil (rodar depois do teste_046)
\set ON_ERROR_STOP 0
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000c3', 'corretor3@teste') on conflict do nothing;
insert into perfis (user_id, email, nome, papel, imobiliaria_id) values ('00000000-0000-0000-0000-0000000000c3', 'corretor3@teste', 'Corretor Três', 'corretor', 'bbbbbbbb-0000-0000-0000-000000000002') on conflict do nothing;

-- prazo em horário comercial (seg-sex 8h-18h): sexta 17:55 + 15 min = segunda 08:10
update leads_config set dias_semana = '{1,2,3,4,5}', hora_inicio = '08:00', hora_fim = '18:00', plantao_24h = false;
do $$ begin
  raise notice '%  Prazo pausa fora do horário (sexta 17:55 + 15 min → segunda 08:10)',
    case when leads_prazo('2026-11-20 17:55-03', 15) = '2026-11-23 08:10-03'::timestamptz then 'OK    ' else 'FALHOU ' || leads_prazo('2026-11-20 17:55-03', 15)::text end;
end $$;
update leads_config set plantao_24h = true, max_tentativas = 3;

set role authenticated;
-- gestor da imobiliária A monta a lista
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ begin
  perform definir_rodizio_corretor('00000000-0000-0000-0000-0000000000c1', true);
  perform definir_rodizio_corretor('00000000-0000-0000-0000-0000000000c2', true);
  raise notice 'OK      Gestor coloca os próprios corretores no rodízio';
  begin perform definir_rodizio_corretor('00000000-0000-0000-0000-0000000000c3', true); raise notice 'FALHOU  gestor mexeu em corretor de outra imobiliária';
  exception when others then raise notice 'OK      Gestor não mexe em corretor de outra imobiliária'; end;
  begin perform salvar_cotas_leads('[]'); raise notice 'FALHOU  gestor alterou cotas';
  exception when others then raise notice 'OK      Só o administrador define as cotas'; end;
end $$;
-- administrador: cotas A=2, B=1 e corretor 3 no rodízio
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false) \g /dev/null
do $$ begin
  perform salvar_cotas_leads('[{"imobiliaria_id":"aaaaaaaa-0000-0000-0000-000000000001","cota":2},{"imobiliaria_id":"bbbbbbbb-0000-0000-0000-000000000002","cota":1}]', true);
  perform definir_rodizio_corretor('00000000-0000-0000-0000-0000000000c3', true);
end $$;
-- usuário logado não chama as funções internas
do $$ begin
  begin perform leads_notificacoes_pendentes(5); raise notice 'FALHOU  usuário leu a fila de e-mails';
  exception when others then raise notice 'OK      Fila de e-mails só pelo servidor'; end;
  begin perform processar_leads(); raise notice 'FALHOU  usuário rodou a rotina';
  exception when others then raise notice 'OK      Rotina de prazos só pelo servidor'; end;
  begin perform receber_leads('x', '[]'); raise notice 'FALHOU  usuário comum chamou a entrada';
  exception when others then raise notice 'OK      Entrada de leads só pelo servidor'; end;
end $$;
reset role;

do $$ declare k text := (select chave from leads_chave); r jsonb; begin
  begin perform receber_leads('errada', '[]'); raise notice 'FALHOU  chave errada aceita';
  exception when others then raise notice 'OK      Chave errada é recusada'; end;
  r := receber_leads(k, '[
    {"id":"l:1001","campaign_name":"Lançamento","form_name":"Morar","full_name":"Ana Souza","phone_number":"p:+5564999990001","email":"ana@x.com","o_imovel_e_para":"Morar","_rotulos":{"o_imovel_e_para":"O imóvel é para:"}},
    {"id":"l:1002","campaign_name":"Lançamento","form_name":"Morar","full_name":"Bruno Lima","phone_number":"p:+5564999990002","email":"bruno@x.com"},
    {"id":"l:1003","campaign_name":"Lançamento","form_name":"Morar","full_name":"Carla Reis","phone_number":"p:+5564999990003","email":"carla@x.com"}
  ]', 'planilha', 'https://homolog.exemplo');
  raise notice '%  3 leads recebidos', case when (r ->> 'novos')::int = 3 then 'OK    ' else 'FALHOU ' || r::text end;
  r := receber_leads(k, '[{"id":"l:1001","full_name":"Ana Souza"}]');
  raise notice '%  Lead repetido (mesmo id do Meta) é ignorado', case when (r ->> 'repetidos')::int = 1 and (r ->> 'novos')::int = 0 then 'OK    ' else 'FALHOU' end;
  raise notice '%  Cota 2:1 → imobiliária A recebe 2, B recebe 1',
    case when (select count(*) from leads where imobiliaria_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 2
          and (select count(*) from leads where imobiliaria_id = 'bbbbbbbb-0000-0000-0000-000000000002') = 1 then 'OK    ' else 'FALHOU' end;
  raise notice '%  Rodízio dentro da imobiliária A (um para cada corretor)',
    case when (select count(distinct corretor_id) from leads where imobiliaria_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 2 then 'OK    ' else 'FALHOU' end;
  raise notice '%  Telefone normalizado (p:+55… → 11 dígitos)', case when (select telefone from leads where meta_id = '1001') = '64999990001' then 'OK    ' else 'FALHOU' end;
  raise notice '%  Perguntas extras vão para as respostas', case when (select respostas ->> 'O imóvel é para:' from leads where meta_id = '1001') = 'Morar' and not (select respostas ? '_rotulos' from leads where meta_id = '1001') then 'OK    ' else 'FALHOU' end;
  raise notice '%  E-mail para cada corretor que recebeu', case when (select count(*) from lead_notificacoes where para like 'corretor%') = 3 then 'OK    ' else 'FALHOU' end;
end $$;

create temp table _l as select id, corretor_id, meta_id from leads;
grant select on _l to authenticated;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false) \g /dev/null
do $$ declare meu uuid := (select id from _l where corretor_id = '00000000-0000-0000-0000-0000000000c1' limit 1);
             outro uuid := (select id from _l where corretor_id = '00000000-0000-0000-0000-0000000000c2' limit 1); n int; begin
  select count(*) into n from listar_leads();
  raise notice '%  Corretor vê só os próprios leads', case when n = 1 then 'OK    ' else 'FALHOU ' || n end;
  raise notice '%  Telefone escondido antes de assumir', case when (select telefone from listar_leads(meu)) is null and (select mascarado from listar_leads(meu)) then 'OK    ' else 'FALHOU' end;
  begin perform count(*) from leads; raise notice '%', case when (select count(*) from leads) = 0 then 'OK      Corretor não lê a tabela direto' else 'FALHOU  corretor leu a tabela' end;
  exception when others then raise notice 'OK      Corretor não lê a tabela direto'; end;
  begin perform assumir_lead(outro); raise notice 'FALHOU  assumiu lead de outro corretor';
  exception when others then raise notice 'OK      Não assume lead de outro corretor'; end;
  begin perform mover_lead(meu, 'visita_agendada'); raise notice 'FALHOU  mexeu no funil antes de assumir';
  exception when others then raise notice 'OK      Funil só depois de assumir'; end;
  perform assumir_lead(meu);
  raise notice '%  Depois de assumir, telefone aparece', case when (select telefone from listar_leads(meu)) is not null then 'OK    ' else 'FALHOU' end;
  perform registrar_contato_lead(meu, 'WhatsApp', 'Primeiro contato');
  begin perform mover_lead(meu, 'perdido'); raise notice 'FALHOU  perdeu sem motivo';
  exception when others then raise notice 'OK      Perdido exige motivo'; end;
  perform mover_lead(meu, 'visita_agendada', null, 'Sábado 10h');
  raise notice '%  Etapa do funil alterada', case when (select status from listar_leads(meu)) = 'visita_agendada' then 'OK    ' else 'FALHOU' end;
end $$;
reset role;

-- prazo esgotado: lead do corretor 2 vai para o corretor 1 (mesma imobiliária), depois para a B, depois Sec. Vendas
do $$ declare l uuid := (select id from _l where corretor_id = '00000000-0000-0000-0000-0000000000c2'); begin
  update leads set prazo_aceite_em = now() - interval '1 minute' where id = l;
  perform processar_leads();
  raise notice '%  Prazo esgotado → próximo corretor da mesma imobiliária', case when (select corretor_id from leads where id = l) = '00000000-0000-0000-0000-0000000000c1' then 'OK    ' else 'FALHOU' end;
  update leads set prazo_aceite_em = now() - interval '1 minute' where id = l;
  perform processar_leads();
  raise notice '%  Sem ninguém na imobiliária → outra imobiliária pela cota', case when (select corretor_id from leads where id = l) = '00000000-0000-0000-0000-0000000000c3' then 'OK    ' else 'FALHOU' end;
  update leads set prazo_aceite_em = now() - interval '1 minute' where id = l;
  perform processar_leads();
  raise notice '%  Limite de tentativas → Sec. Vendas (com aviso)', case when (select status from leads where id = l) = 'sem_destino'
    and exists (select 1 from lead_notificacoes where para = 'vendas@teste' and lead_id = l) then 'OK    ' else 'FALHOU' end;
end $$;

-- cliente que volta vai para o mesmo corretor
do $$ declare r jsonb; begin
  r := receber_leads((select chave from leads_chave), '[{"id":"l:2001","full_name":"Bruno Lima","phone_number":"+55 64 99999-0002","form_name":"Investidor"}]');
  raise notice '%  Cliente que volta vai para o mesmo corretor', case when (select corretor_id from leads where meta_id = '2001') =
    (select corretor_id from leads where meta_id = '1002') and (select retorno_de from leads where meta_id = '2001') is not null then 'OK    ' else 'FALHOU' end;
end $$;

-- Sec. Vendas redistribui manualmente e gestor não manda para outra imobiliária
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ declare l uuid := (select id from _l where corretor_id = '00000000-0000-0000-0000-0000000000c2'); begin
  begin perform redistribuir_lead(l, '00000000-0000-0000-0000-0000000000c3'); raise notice 'FALHOU  gestor mandou lead para outra imobiliária';
  exception when others then raise notice 'OK      Gestor não redistribui para fora da imobiliária'; end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare l uuid := (select id from _l where corretor_id = '00000000-0000-0000-0000-0000000000c2'); begin
  perform redistribuir_lead(l, '00000000-0000-0000-0000-0000000000c2');
  raise notice '%  Sec. Vendas direciona o lead a um corretor', case when (select status from leads where id = l) = 'aguardando_aceite' then 'OK    ' else 'FALHOU' end;
end $$;
reset role;

-- pasta com o mesmo telefone converte o lead
do $$ declare l uuid := (select id from leads where meta_id = '1002'); v_ok boolean; begin
  begin
    insert into pastas (imobiliaria_id, comprador_nome, comprador_cpf, comprador_telefone, comprador_email, comprador_profissao, estado_civil, criado_por_id)
    values ('aaaaaaaa-0000-0000-0000-000000000001', 'Bruno Lima', '52998224725', '64999990002', 'bruno@x.com', 'Engenheiro', 'solteiro', '00000000-0000-0000-0000-0000000000c1');
  exception when others then raise notice 'aviso: %', sqlerrm; end;
  raise notice '%  Pasta com o mesmo telefone converte o lead', case when (select status from leads where id = l) = 'convertido' and (select pasta_id from leads where id = l) is not null then 'OK    ' else 'FALHOU' end;
end $$;
