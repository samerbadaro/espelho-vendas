-- Testes da 116 (módulos do Duo Haus em vários empreendimentos). Banco local, depois de todas as migrações.
\set ON_ERROR_STOP 0
\pset tuples_only on
\set QUIET on
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000001a1', 'admin-116@teste'), ('00000000-0000-0000-0000-0000000001a2', 'corretor-116@teste') on conflict do nothing;
insert into public.imobiliarias (id, nome) values ('cdcdcdcd-1160-0000-0000-000000000001', 'Imob 116') on conflict do nothing;
insert into public.perfis (user_id, email, nome, papel, imobiliaria_id) values
  ('00000000-0000-0000-0000-0000000001a1', 'admin-116@teste', 'Admin 116', 'admin', null),
  ('00000000-0000-0000-0000-0000000001a2', 'corretor-116@teste', 'Corretor 116', 'corretor', 'cdcdcdcd-1160-0000-0000-000000000001') on conflict do nothing;
create temp table r (n serial, teste text, ok boolean);
create temp table ctx (k text primary key, v text);
grant all on r, ctx to anon, authenticated; grant usage on sequence r_n_seq to anon, authenticated;
create or replace function pg_temp.como(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false); $$;
create or replace function pg_temp.tenta(sql text, esperado text) returns boolean language plpgsql as $$
begin execute sql; return false; exception when others then return sqlerrm like '%' || esperado || '%'; end $$;

set role authenticated;
select pg_temp.como('00000000-0000-0000-0000-0000000001a1');
insert into ctx select 'dh', empreendimento_atual()::text;
insert into ctx select 'te', (salvar_empreendimento(null, 'Empreendimento 116', 'e116', 'EA', true, 1)).id::text;
reset role;

insert into r(teste, ok) select 'Propostas ligadas em todos os empreendimentos', not exists (select 1 from config where not modulo_propostas);
insert into r(teste, ok) select 'Empreendimento novo nasce com configuração e chave de leads',
  exists (select 1 from leads_config where empreendimento_id = (select v::uuid from ctx where k = 'te'))
  and (select count(distinct chave) = count(*) and count(*) = (select count(*) from empreendimentos) from leads_chave);

-- Leads: a chave diz o empreendimento
insert into leads_corretores (empreendimento_id, user_id, participa) values ((select v::uuid from ctx where k = 'te'), '00000000-0000-0000-0000-0000000001a2', true);
insert into leads_imobiliarias (empreendimento_id, imobiliaria_id, cota) values ((select v::uuid from ctx where k = 'te'), 'cdcdcdcd-1160-0000-0000-000000000001', 1);
select receber_leads((select chave from leads_chave where empreendimento_id = (select v::uuid from ctx where k = 'te')),
  '[{"id":"l:116-1","full_name":"Ana Lead","phone_number":"+5564999991160","email":"ana@lead.com","campaign_name":"C1"}]'::jsonb) \g /dev/null
insert into r(teste, ok) select 'Lead recebido pela chave do 116 fica no 116',
  (select empreendimento_id = (select v::uuid from ctx where k = 'te') from leads where meta_id = '116-1');
insert into r(teste, ok) select 'Rodízio do 116 entrega ao corretor do 116',
  (select corretor_id = '00000000-0000-0000-0000-0000000001a2' and status = 'aguardando_aceite' from leads where meta_id = '116-1');
select receber_leads((select chave from leads_chave where empreendimento_id = (select v::uuid from ctx where k = 'dh')),
  '[{"id":"l:116-2","full_name":"Beto Lead","phone_number":"+5564999991161"}]'::jsonb) \g /dev/null
insert into r(teste, ok) select 'Lead do Duo Haus não usa o rodízio do 116 (fica com a Sec. Vendas)',
  (select empreendimento_id = (select v::uuid from ctx where k = 'dh') and status = 'sem_destino' from leads where meta_id = '116-2');
insert into r(teste, ok) select 'Chave inválida é recusada', pg_temp.tenta($$select receber_leads('xyz', '[]'::jsonb)$$, 'CHAVE_INVALIDA');

set role authenticated;
select pg_temp.como('00000000-0000-0000-0000-0000000001a1');
insert into r(teste, ok) select 'No Duo Haus, a equipe vê só o lead do Duo Haus', (select count(*) = 1 from listar_leads()) and (select count(*) = 1 from leads);
select salvar_config_leads('{"prazo_aceite_min": 30}'::jsonb) \g /dev/null
select escolher_empreendimento((select v::uuid from ctx where k = 'te')) \g /dev/null
insert into r(teste, ok) select 'No 116, vê só o lead do 116', (select bool_and(codigo is not null) and count(*) = 1 from listar_leads());
insert into r(teste, ok) select 'Configuração de leads é a do empreendimento atual', (select prazo_aceite_min = 15 from leads_config);

-- Contratos: dados, quadro de áreas, modelos e fixos por empreendimento
select salvar_empreendimento_contrato('{"vendedora.razao_social": "SPE 116"}'::jsonb) \g /dev/null
select importar_quadro_areas('[{"numero":"101","area_privativa":110},{"numero":"102","area_privativa":90}]'::jsonb) \g /dev/null
select salvar_modelo_contrato('quadro_resumo', 'Quadro 116', 'modelos/q116.docx') \g /dev/null
select salvar_anexo_fixo('Memorial 116', 'fixos/m116.pdf', 'memorial.pdf', 1) \g /dev/null
select escolher_empreendimento((select v::uuid from ctx where k = 'dh')) \g /dev/null
select salvar_empreendimento_contrato('{"vendedora.razao_social": "SPE Duo"}'::jsonb) \g /dev/null
select importar_quadro_areas('[{"numero":"101","area_privativa":75}]'::jsonb) \g /dev/null
insert into r(teste, ok) select 'Duo Haus lê os próprios dados da vendedora', (select dados ->> 'vendedora.razao_social' = 'SPE Duo' from empreendimento_contrato);
insert into r(teste, ok) select 'Quadro de áreas do Duo Haus não apaga o do 116', (select count(*) = 1 and min(area_privativa) = 75 from unidade_areas);
insert into r(teste, ok) select 'Modelos e fixos do 116 não aparecem no Duo Haus',
  (select count(*) = 0 from modelos_contrato) and (select count(*) = 0 from contrato_anexos_fixos);
reset role;
insert into r(teste, ok) select 'Mesmo número 101 no quadro dos dois empreendimentos', (select count(*) = 2 from unidade_areas where numero = '101');
insert into r(teste, ok) select 'Dados da vendedora do 116 preservados',
  (select dados ->> 'vendedora.razao_social' = 'SPE 116' from empreendimento_contrato where empreendimento_id = (select v::uuid from ctx where k = 'te'));

-- Pix: o modo integrado vale só para o empreendimento configurado
update config set pix_modo = 'integrado' where empreendimento_id = (select v::uuid from ctx where k = 'te');
insert into pastas (comprador_nome, comprador_cpf, estado_civil, comprador_telefone, comprador_email, comprador_profissao, imobiliaria_id, empreendimento_id)
values ('Pix 116', '52998224725', 'solteiro', '64999990000', 'p@t.com', 'Médica', 'cdcdcdcd-1160-0000-0000-000000000001', (select v::uuid from ctx where k = 'te')),
       ('Pix Duo', '52998224725', 'solteiro', '64999990000', 'p@t.com', 'Médica', 'cdcdcdcd-1160-0000-0000-000000000001', (select v::uuid from ctx where k = 'dh'));
insert into r(teste, ok) select 'Pix integrado só no empreendimento que ligou',
  pix_integrado((select id from pastas where comprador_nome = 'Pix 116')) and not pix_integrado((select id from pastas where comprador_nome = 'Pix Duo'));

-- Submissão: regras novas do Duo Haus continuam valendo na v2
update pastas set estado_civil = 'casado', regime_bens = null where comprador_nome = 'Pix Duo';
set role authenticated;
select pg_temp.como('00000000-0000-0000-0000-0000000001a1');
insert into r(teste, ok) select 'Casado sem regime de bens não submete',
  pg_temp.tenta(format('select submeter_pasta(%L)', (select id from pastas where comprador_nome = 'Pix Duo')), 'REGIME_NAO_INFORMADO');
reset role;

select format('%s %s', case when ok then 'OK   ' else 'FALHA' end, teste) from r order by n;
select format('%s de %s testes passaram', count(*) filter (where ok), count(*)) from r;
