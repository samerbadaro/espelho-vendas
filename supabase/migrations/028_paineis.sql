-- =====================================================================
-- 028 — Painéis da gestão comercial (somente equipe)
--  Unidades e VGV, vendas por mês (VSO), funil das pastas, ranking de
--  imobiliárias e corretores (unidades e VGV) e análise das propostas.
--  A carteira de recebíveis é montada na tela a partir das propostas
--  aprovadas (fluxo de pagamento de cada uma).
-- Executar uma única vez no SQL Editor do Supabase (projeto de testes).
-- =====================================================================

create or replace function public.paineis() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;

  with
  un as (
    select u.id, u.numero, u.status, public.preco_tabela_unidade(u.id) as preco
      from public.unidades u
  ),
  neg as (
    select n.*, u.status as status_unidade, u.numero
      from public.negociacoes n join public.unidades u on u.id = n.unidade_id
     where n.ativa
  ),
  vendas_mes as (   -- primeira vez que cada unidade chegou a cada etapa, por mês
    select to_char(date_trunc('month', h.criado_em at time zone 'America/Sao_Paulo'), 'YYYY-MM') as mes, h.status_novo, count(distinct h.unidade_id) as n
      from public.historico h
     where h.status_novo in ('reservada', 'proposta', 'contrato', 'vendida')
       and h.criado_em >= date_trunc('month', now()) - interval '11 months'
     group by 1, 2
  ),
  rank_imob as (
    select coalesce(n.imobiliaria, 'Venda direta') as nome,
           count(*) filter (where n.status_unidade = 'reservada') as reservas,
           count(*) filter (where n.status_unidade in ('proposta', 'contrato', 'vendida')) as vendas,
           count(*) filter (where n.status_unidade = 'vendida') as vendidas,
           coalesce(sum(n.valor_venda) filter (where n.status_unidade in ('proposta', 'contrato', 'vendida')), 0) as vgv
      from neg n group by 1
  ),
  pastas_imob as (
    select i.nome, count(*) filter (where p.status = 'aprovada') as aprovadas, count(*) as total
      from public.pastas p join public.imobiliarias i on i.id = p.imobiliaria_id group by 1
  ),
  rank_corretor as (
    select coalesce(n.corretor, '—') as nome, coalesce(n.imobiliaria, 'Venda direta') as imobiliaria,
           count(*) filter (where n.status_unidade = 'reservada') as reservas,
           count(*) filter (where n.status_unidade in ('proposta', 'contrato', 'vendida')) as vendas,
           coalesce(sum(n.valor_venda) filter (where n.status_unidade in ('proposta', 'contrato', 'vendida')), 0) as vgv
      from neg n group by 1, 2
  ),
  props as (
    select * from public.propostas where status <> 'rascunho'
  )
  select jsonb_build_object(
    'gerado_em', now(),
    'unidades', (select jsonb_object_agg(status, jsonb_build_object('n', n, 'vgv_tabela', vgv))
                   from (select status, count(*) n, round(coalesce(sum(preco), 0), 2) vgv from un group by status) x),
    'vgv_tabela_total', (select round(coalesce(sum(preco), 0), 2) from un),
    'vendas', (select jsonb_object_agg(status_unidade, jsonb_build_object('n', n, 'vgv', vgv))
                 from (select status_unidade, count(*) n, round(coalesce(sum(valor_venda), 0), 2) vgv from neg group by 1) x),
    'por_mes', coalesce((select jsonb_agg(jsonb_build_object('mes', mes, 'status', status_novo, 'n', n) order by mes) from vendas_mes), '[]'),
    'funil', jsonb_build_object(
       'pastas', (select count(*) from public.pastas),
       'submetidas', (select count(*) from public.pastas where codigo_aprovacao is not null),
       'aprovadas', (select count(*) from public.pastas where status = 'aprovada'),
       'com_unidade', (select count(distinct pasta_id) from neg where pasta_id is not null),
       'proposta', (select count(*) from neg where status_unidade in ('proposta', 'contrato', 'vendida')),
       'contrato', (select count(*) from neg where status_unidade in ('contrato', 'vendida')),
       'vendida', (select count(*) from neg where status_unidade = 'vendida')),
    'ranking_imobiliarias', coalesce((
       select jsonb_agg(jsonb_build_object('nome', r.nome, 'reservas', r.reservas, 'vendas', r.vendas, 'vendidas', r.vendidas,
                                           'vgv', r.vgv, 'pastas_aprovadas', coalesce(pi.aprovadas, 0), 'pastas', coalesce(pi.total, 0))
                        order by r.vgv desc, r.vendas desc, r.reservas desc)
         from rank_imob r left join pastas_imob pi on pi.nome = r.nome), '[]'),
    'ranking_corretores', coalesce((
       select jsonb_agg(jsonb_build_object('nome', nome, 'imobiliaria', imobiliaria, 'reservas', reservas, 'vendas', vendas, 'vgv', vgv)
                        order by vgv desc, vendas desc, reservas desc)
         from rank_corretor), '[]'),
    'propostas', jsonb_build_object(
       'por_status', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from props group by 1) x), '{}'),
       'automaticas', (select count(*) from props where status = 'aprovada' and analisada_por like 'Aprovação automática%'),
       'pv_medio_aprovadas', (select round(avg((resumo ->> 'pv_pct')::numeric), 2) from props where status = 'aprovada'),
       'horas_medias_analise', (select round(avg(extract(epoch from analisada_em - enviada_em) / 3600)::numeric, 1)
                                  from props where analisada_em is not null and enviada_em is not null
                                   and coalesce(analisada_por, '') not like 'Aprovação automática%'),
       'aguardando_vendas', (select count(*) from props where status = 'enviada' and alcada = 'vendas'),
       'aguardando_admin', (select count(*) from props where status = 'enviada' and alcada = 'admin'),
       'motivos', coalesce((select jsonb_agg(x order by x ->> 'em' desc) from (
          select jsonb_build_object('codigo', codigo, 'status', status, 'motivo', motivo_analise, 'em', analisada_em) x
            from props where status in ('devolvida', 'recusada') and motivo_analise is not null
           order by analisada_em desc limit 8) m), '[]'))
  ) into r;
  return r;
end;
$$;
revoke all on function public.paineis() from public, anon;
grant execute on function public.paineis() to authenticated;
