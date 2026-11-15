-- =====================================================================
-- 114 — Meeting na visão do corretor e da imobiliária
--  meus_meetings(): meetings futuros do empreendimento atual (até 6 h
--  depois do início), com situação das inscrições e a inscrição do
--  próprio login (pelo e-mail), sem expor a lista de inscritos.
-- =====================================================================
create or replace function public.meus_meetings() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'slug', e.slug, 'nome', e.nome, 'data_hora', e.data_hora, 'local', e.local, 'descricao', e.descricao,
           'abertas', e.inscricoes_abertas and (e.encerra_em is null or now() < e.encerra_em)
                      and (e.vagas is null or (select count(*) from public.recepcao_participantes p where p.evento_id = e.id) < e.vagas),
           'motivo', case when not e.inscricoes_abertas or (e.encerra_em is not null and now() >= e.encerra_em) then 'encerradas'
                          when e.vagas is not null and (select count(*) from public.recepcao_participantes p where p.evento_id = e.id) >= e.vagas then 'esgotadas' end,
           'encerra_em', e.encerra_em,
           'vagas_restantes', case when e.vagas is null then null
                                   else greatest(0, e.vagas - (select count(*) from public.recepcao_participantes p where p.evento_id = e.id)) end,
           'minha_inscricao', (select jsonb_build_object('codigo', p.codigo, 'presente', p.presente, 'inscrito_em', p.inscrito_em)
                                 from public.recepcao_participantes p
                                where p.evento_id = e.id and p.email = public.normalizar_email(public.meu_email()) limit 1)
         ) order by e.data_hora), '[]')
    from public.recepcao_eventos e
   where auth.uid() is not null
     and e.empreendimento_id = public.empreendimento_atual()
     and (e.data_hora is null or e.data_hora >= now() - interval '6 hours');
$$;
revoke all on function public.meus_meetings() from public, anon;
grant execute on function public.meus_meetings() to authenticated;
