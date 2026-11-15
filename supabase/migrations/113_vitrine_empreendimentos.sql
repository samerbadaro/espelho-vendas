-- =====================================================================
-- 113 — Vitrine de empreendimentos e empreendimento pelo endereço
--  * Empreendimento ganha fase, cidade e foto da fachada (para os cards).
--  * O empreendimento da aba vem do endereço (/e/<endereço>/painel/...):
--    o navegador manda o cabeçalho "x-empreendimento" em cada pedido e o
--    banco usa esse empreendimento. Sem cabeçalho, vale o último escolhido
--    no perfil (usado também pelas atualizações em tempo real).
--  * vitrine(): resumo de cada empreendimento liberado para o login
--    (fachada, a partir de, entrega, situação do espelho, VSO e avisos) e
--    o consolidado da incorporadora para a equipe.
-- =====================================================================

alter table public.empreendimentos add column if not exists fase text not null default 'lancamento'
  check (fase in ('pre_lancamento', 'lancamento', 'obras', 'entregue'));
alter table public.empreendimentos add column if not exists cidade text;
alter table public.empreendimentos add column if not exists fachada_url text;

update public.empreendimentos e set cidade = coalesce(e.cidade, c.cidade)
  from public.config c where c.empreendimento_id = e.id and e.cidade is null;

create or replace function public.empreendimento_atual() returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select e.id from public.empreendimentos e
      where e.slug = nullif(current_setting('request.headers', true), '')::json ->> 'x-empreendimento'
        and (auth.uid() is null and e.ativo or public.pode_usar_empreendimento(e.id))),
    (select p.empreendimento_atual from public.perfis p
      where p.user_id = auth.uid() and p.empreendimento_atual is not null and public.pode_usar_empreendimento(p.empreendimento_atual)),
    (select e.id from public.empreendimentos e
      where e.ativo and (auth.uid() is null or public.pode_usar_empreendimento(e.id))
      order by e.ordem, e.criado_em limit 1),
    public.empreendimento_padrao());
$$;

create or replace function public.salvar_vitrine(p_emp uuid, p_fase text, p_cidade text, p_fachada text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.empreendimentos set fase = p_fase, cidade = nullif(trim(coalesce(p_cidade, '')), ''),
         fachada_url = nullif(trim(coalesce(p_fachada, '')), '') where id = p_emp;
end;
$$;

create or replace function public.vitrine() returns jsonb
language sql stable security definer set search_path = public as $$
  with
  emps as (
    select e.* from public.empreendimentos e
     where auth.uid() is not null and public.pode_usar_empreendimento(e.id)
  ),
  dados as (
    select e.id, e.slug, e.sigla, e.nome, e.ativo, e.ordem, e.criado_em, e.fase,
           coalesce(e.cidade, c.cidade) as cidade,
           coalesce(e.fachada_url, c.imagem_login_url) as fachada,
           c.logo_url, c.logo_escuro_url, c.cor_primaria, c.cor_destaque,
           co.mes_entrega,
           public.tabela_vigente(e.id) as tabela,
           public.tabela_proxima(e.id) as proxima,
           (select f.ativa from public.fila_config f where f.empreendimento_id = e.id) as fila_ativa,
           (select f.inicio from public.fila_config f where f.empreendimento_id = e.id) as fila_inicio
      from emps e
      left join public.config c on c.empreendimento_id = e.id
      left join public.comercial co on co.empreendimento_id = e.id
  ),
  st as (
    select u.empreendimento_id, u.status, count(*) as n, coalesce(sum(i.preco), 0) as vgv, min(i.preco) as minimo
      from public.unidades u
      join dados d on d.id = u.empreendimento_id
      left join public.tabelas_preco_itens i on i.unidade_id = u.id and i.tabela_id = d.tabela
     group by 1, 2
  ),
  card as (
    select d.*,
           coalesce((select sum(n) from st where st.empreendimento_id = d.id), 0) as total,
           coalesce((select jsonb_object_agg(status, n) from st where st.empreendimento_id = d.id), '{}') as status,
           (select minimo from st where st.empreendimento_id = d.id and status = 'disponivel') as a_partir,
           coalesce((select sum(vgv) from st where st.empreendimento_id = d.id), 0) as vgv_tabela,
           coalesce((select sum(n.valor_venda) from public.negociacoes n join public.unidades u on u.id = n.unidade_id
                      where n.ativa and n.empreendimento_id = d.id and u.status in ('proposta', 'contrato', 'vendida')), 0) as vgv_vendido,
           coalesce((select sum(n) from st where st.empreendimento_id = d.id and status in ('proposta', 'contrato', 'vendida')), 0) as vendas,
           (select t.vigente_desde from public.tabelas_preco t where t.id = d.proxima) as proxima_em,
           (select jsonb_build_object('nome', r.nome, 'data_hora', r.data_hora) from public.recepcao_eventos r
             where r.empreendimento_id = d.id and r.data_hora >= now() order by r.data_hora limit 1) as meeting,
           case when public.eh_admin() then (select count(*) from public.propostas p where p.empreendimento_id = d.id and p.status = 'enviada')
                when public.eh_equipe() then (select count(*) from public.propostas p where p.empreendimento_id = d.id and p.status = 'enviada' and p.alcada = 'vendas')
                else (select count(*) from public.propostas p where p.empreendimento_id = d.id and p.status = 'devolvida'
                        and public.acesso_pasta(p.imobiliaria_id, p.criado_por_id)) end as propostas_pendentes
      from dados d
  )
  select jsonb_build_object(
    'empreendimentos', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'slug', slug, 'sigla', sigla, 'nome', nome, 'ativo', ativo, 'fase', fase, 'cidade', cidade,
        'fachada', fachada, 'logo', logo_url, 'logo_escuro', logo_escuro_url, 'cor_primaria', cor_primaria, 'cor_destaque', cor_destaque,
        'entrega', mes_entrega, 'a_partir', a_partir, 'total', total, 'status', status, 'vendas', vendas,
        'vgv_tabela', round(vgv_tabela, 2), 'vgv_vendido', round(vgv_vendido, 2),
        'fila', case when fila_ativa then fila_inicio end, 'proxima_tabela', proxima_em, 'meeting', meeting,
        'propostas_pendentes', propostas_pendentes) order by ordem, criado_em) from card), '[]'),
    'consolidado', case when public.eh_equipe() then (select jsonb_build_object(
        'empreendimentos', count(*), 'unidades', coalesce(sum(total), 0), 'vendas', coalesce(sum(vendas), 0),
        'disponiveis', coalesce(sum((status ->> 'disponivel')::int), 0),
        'vgv_tabela', round(coalesce(sum(vgv_tabela), 0), 2), 'vgv_vendido', round(coalesce(sum(vgv_vendido), 0), 2)) from card) end
  );
$$;

revoke all on function public.salvar_vitrine(uuid, text, text, text), public.vitrine() from public, anon;
grant execute on function public.salvar_vitrine(uuid, text, text, text), public.vitrine() to authenticated;
