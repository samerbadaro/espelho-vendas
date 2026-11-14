-- =====================================================================
-- 026 — Simulador configurável e registros de download
--  * config.simulador: os 4 preços (a partir / médio × Poente / Nascente),
--    a captação mínima e o fluxo padrão de cada posição. Só o admin altera.
--  * simulacoes_log: cada simulação baixada (quem, quando, captação, fluxo).
--  * portal_downloads: cada download do Portal do Corretor (quem, quando, o quê).
--  * Os dois registros só são vistos pela equipe (admin e Sec. Vendas).
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.config add column if not exists simulador jsonb not null default jsonb_build_object(
  'poente', jsonb_build_object('a_partir', 405576.26, 'medio', 427575.76, 'captacao', 30,
            'pct', jsonb_build_object('ato', 4, 'sinal', 4, 'mensais', 6, 'periodicas', 12, 'unica', 4)),
  'nascente', jsonb_build_object('a_partir', 405576.26, 'medio', 427575.76, 'captacao', 35,
            'pct', jsonb_build_object('ato', 4, 'sinal', 4, 'mensais', 6.5, 'periodicas', 15.5, 'unica', 5))
);

create or replace function public.salvar_simulador(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare f text; s numeric;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  foreach f in array array['poente', 'nascente'] loop
    if coalesce((p #>> array[f, 'a_partir'])::numeric, 0) <= 0 or coalesce((p #>> array[f, 'medio'])::numeric, 0) <= 0 then
      raise exception 'PRECO_INVALIDO';
    end if;
    if (p #>> array[f, 'captacao'])::numeric not between 1 and 100 then raise exception 'CAPTACAO_INVALIDA'; end if;
    select sum(v::numeric) into s from jsonb_each_text(p -> f -> 'pct') as x(k, v);
    if s is null or s > 100 or s < (p #>> array[f, 'captacao'])::numeric then raise exception 'FLUXO_PADRAO_INVALIDO'; end if;
  end loop;
  update public.config set simulador = p, atualizado_em = now() where id = 1;
end;
$$;

-- ---------------------------------------------------------------------
create table if not exists public.simulacoes_log (
  id             bigint generated always as identity primary key,
  criado_em      timestamptz not null default now(),
  user_id        uuid default auth.uid(),
  nome           text,
  email          text,
  papel          text,
  imobiliaria    text,
  posicao        text not null,           -- Poente / Nascente
  referencia     text not null,           -- A partir de / Preço médio
  preco          numeric(14,2) not null,
  captacao       numeric(6,2) not null,
  financiamento  numeric(6,2) not null,
  formato        text not null,           -- png / pdf
  fluxo          jsonb not null           -- séries: rótulo, parcelas, valor, %
);
create index if not exists simulacoes_log_data on public.simulacoes_log (criado_em desc);

create table if not exists public.portal_downloads (
  id          bigint generated always as identity primary key,
  criado_em   timestamptz not null default now(),
  user_id     uuid default auth.uid(),
  nome        text,
  email       text,
  papel       text,
  imobiliaria text,
  item_id     uuid references public.portal_itens(id) on delete set null,
  categoria   text,
  titulo      text not null,
  modo        text not null check (modo in ('arquivo', 'link', 'visualizar', 'zip'))
);
create index if not exists portal_downloads_data on public.portal_downloads (criado_em desc);

alter table public.simulacoes_log enable row level security;
alter table public.portal_downloads enable row level security;
revoke all on public.simulacoes_log, public.portal_downloads from anon, authenticated;
grant select on public.simulacoes_log, public.portal_downloads to authenticated;
create policy simulacoes_log_equipe on public.simulacoes_log for select using (public.eh_equipe());
create policy portal_downloads_equipe on public.portal_downloads for select using (public.eh_equipe());

-- quem está logado: nome, papel e imobiliária no momento do registro
create or replace function public.quem_sou()
returns table (nome text, email text, papel text, imobiliaria text)
language sql stable security definer set search_path = public as $$
  select p.nome, p.email, p.papel::text, i.nome
    from public.perfis p left join public.imobiliarias i on i.id = p.imobiliaria_id
   where p.user_id = auth.uid();
$$;
revoke all on function public.quem_sou() from public, anon;

create or replace function public.registrar_simulacao(p_posicao text, p_referencia text, p_preco numeric,
  p_captacao numeric, p_financiamento numeric, p_formato text, p_fluxo jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare q record;
begin
  select * into q from public.quem_sou();
  if not found then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.simulacoes_log (nome, email, papel, imobiliaria, posicao, referencia, preco, captacao, financiamento, formato, fluxo)
  values (q.nome, q.email, q.papel, q.imobiliaria, left(p_posicao, 30), left(p_referencia, 30), p_preco,
          p_captacao, p_financiamento, case when p_formato = 'pdf' then 'pdf' else 'png' end, coalesce(p_fluxo, '[]'::jsonb));
end;
$$;

create or replace function public.registrar_download_portal(p_item uuid, p_modo text, p_titulo text default null, p_categoria text default null)
returns void language plpgsql security definer set search_path = public as $$
declare q record; it public.portal_itens;
begin
  select * into q from public.quem_sou();
  if not found then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_item is not null then select * into it from public.portal_itens where id = p_item; end if;
  insert into public.portal_downloads (nome, email, papel, imobiliaria, item_id, categoria, titulo, modo)
  values (q.nome, q.email, q.papel, q.imobiliaria, it.id, coalesce(it.categoria, p_categoria),
          left(coalesce(it.titulo, p_titulo, 'Arquivo'), 200), case when p_modo in ('arquivo','link','visualizar','zip') then p_modo else 'arquivo' end);
end;
$$;

revoke all on function public.salvar_simulador(jsonb), public.registrar_simulacao(text, text, numeric, numeric, numeric, text, jsonb),
  public.registrar_download_portal(uuid, text, text, text) from public, anon;
grant execute on function public.salvar_simulador(jsonb), public.registrar_simulacao(text, text, numeric, numeric, numeric, text, jsonb),
  public.registrar_download_portal(uuid, text, text, text) to authenticated;
