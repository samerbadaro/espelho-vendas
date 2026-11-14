-- Recepção de eventos
\set ON_ERROR_STOP 0
with ev as (insert into recepcao_eventos (nome, data_hora) values ('Evento de teste', now()) returning id)
insert into recepcao_participantes (evento_id, nome, imobiliaria, telefone)
select ev.id, n, 'Aero', '64999990000' from ev, unnest(array['Adriana Ienerich', 'Bruno Teste']) n;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
do $$ declare p recepcao_participantes; ev uuid := (select id from recepcao_eventos where nome='Evento de teste'); begin
  raise notice '%  Sec. Vendas vê a lista de convidados', case when (select count(*) from recepcao_participantes where evento_id=ev)=2 then 'OK    ' else 'FALHOU' end;
  p := marcar_presenca((select id from recepcao_participantes where nome='Adriana Ienerich' and evento_id=ev), true);
  raise notice '%  Confirmar chegada registra horário e quem confirmou', case when p.presente and p.chegada_em is not null and p.confirmado_por is not null then 'OK    ' else 'FALHOU' end;
  p := marcar_presenca(p.id, false);
  raise notice '%  Desfazer devolve para a lista', case when not p.presente and p.chegada_em is null then 'OK    ' else 'FALHOU' end;
  p := incluir_participante(ev, 'Fulano  de Tal', 'Imobiliária Nova', '(64) 99999-0000');
  raise notice '%  Incluir na hora já entra como presente', case when p.presente and p.incluido_na_hora and p.nome='Fulano de Tal' and p.telefone='64999990000' then 'OK    ' else 'FALHOU' end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false) \g /dev/null
do $$ begin
  raise notice '%  Imobiliária não vê a lista da recepção', case when (select count(*) from recepcao_participantes)=0 then 'OK    ' else 'FALHOU' end;
  begin perform marcar_presenca((select id from recepcao_participantes limit 1), true); raise notice 'OK      Imobiliária não confirma (nada visível)';
  exception when others then raise notice '%  Imobiliária não confirma presença (%)', case when sqlerrm='SEM_PERMISSAO' then 'OK    ' else 'FALHOU' end, sqlerrm; end;
end $$;
reset role;
