-- =====================================================================
-- ATUALIZAÇÃO DA V2 (projeto de TESTES do Supabase) — 14/11/2026
-- Traz as melhorias do Duo Haus e garante as da proposta:
--   019 Rodadas: no máximo 3 pessoas por cliente
--   020 Recepção de eventos (check-in)
--   021 Portal do Corretor (materiais de venda)
--   024 Carta proposta no modelo novo   (pode rodar de novo sem problema)
--   025 Séries Bimestrais, Trimestrais e Permuta (pode rodar de novo)
-- Colar inteiro no SQL Editor do projeto de TESTES e clicar em Run.
-- NÃO rodar no projeto do Duo Haus (lá o 019/020/021 já estão).
-- =====================================================================

-- >>>>> 019_rodadas_limite_3.sql
-- =====================================================================
-- 019 — Rodadas: no máximo 3 pessoas por cliente (o cliente e até 2 acompanhantes)
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create or replace function public.normalizar_convidados(p text[]) returns text[]
language plpgsql immutable as $$
declare v text[] := '{}'; n text;
begin
  foreach n in array coalesce(p, '{}') loop
    n := regexp_replace(trim(coalesce(n, '')), '\s+', ' ', 'g');
    if length(n) < 3 then raise exception 'NOME_CONVIDADO_OBRIGATORIO'; end if;
    if position(' ' in n) = 0 then raise exception 'NOME_COMPLETO_OBRIGATORIO' using hint = n; end if;
    v := v || n;
  end loop;
  if coalesce(array_length(v, 1), 0) < 1 or array_length(v, 1) > 3 then raise exception 'PESSOAS_INVALIDO'; end if;
  return v;
end;
$$;

-- >>>>> 020_recepcao.sql
-- =====================================================================
-- 020 — Recepção de eventos (check-in na entrada)
--  * Lista de convidados por evento; a recepção busca pelo nome e confirma
--    a chegada. Quem chegou sai da lista de espera e vai para "Confirmados".
--  * Só a equipe (Sec. Vendas e administrador) acessa.
--  * A lista de cada evento é carregada à parte (dados pessoais não ficam no repositório).
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create table public.recepcao_eventos (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  data_hora  timestamptz,
  criado_em  timestamptz not null default now()
);

create table public.recepcao_participantes (
  id              uuid primary key default gen_random_uuid(),
  evento_id       uuid not null references public.recepcao_eventos(id) on delete cascade,
  nome            text not null check (length(trim(nome)) >= 2),
  email           text,
  imobiliaria     text,
  telefone        text,
  presente        boolean not null default false,
  chegada_em      timestamptz,
  confirmado_por  text,
  incluido_na_hora boolean not null default false,
  criado_em       timestamptz not null default now()
);
create index recepcao_participantes_evento_idx on public.recepcao_participantes (evento_id);

alter table public.recepcao_eventos enable row level security;
alter table public.recepcao_participantes enable row level security;
create policy recepcao_eventos_leitura on public.recepcao_eventos for select using (public.eh_equipe());
create policy recepcao_participantes_leitura on public.recepcao_participantes for select using (public.eh_equipe());
grant select on public.recepcao_eventos, public.recepcao_participantes to authenticated;

-- Confirmar (ou desfazer) a chegada
create or replace function public.marcar_presenca(p_id uuid, p_presente boolean) returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.recepcao_participantes
     set presente = p_presente,
         chegada_em = case when p_presente then coalesce(chegada_em, now()) else null end,
         confirmado_por = case when p_presente then public.meu_email() else null end
   where id = p_id returning * into v;
  if not found then raise exception 'PARTICIPANTE_NAO_ENCONTRADO'; end if;
  return v;
end;
$$;

-- Incluir na hora quem não estava na lista (já entra como presente)
create or replace function public.incluir_participante(p_evento uuid, p_nome text, p_imobiliaria text default null, p_telefone text default null)
returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  insert into public.recepcao_participantes (evento_id, nome, imobiliaria, telefone, presente, chegada_em, confirmado_por, incluido_na_hora)
  values (p_evento, regexp_replace(trim(p_nome), '\s+', ' ', 'g'), nullif(trim(p_imobiliaria), ''),
          nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), ''), true, now(), public.meu_email(), true)
  returning * into v;
  return v;
end;
$$;

revoke all on function public.marcar_presenca(uuid, boolean) from public, anon;
revoke all on function public.incluir_participante(uuid, text, text, text) from public, anon;
grant execute on function public.marcar_presenca(uuid, boolean) to authenticated;
grant execute on function public.incluir_participante(uuid, text, text, text) to authenticated;

-- Várias pessoas na recepção veem a lista atualizada ao mesmo tempo
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.recepcao_participantes;
  end if;
end $$;

-- >>>>> 021_portal_corretor.sql
-- =====================================================================
-- 021 — Portal do Corretor
--  * Materiais de venda organizados em categorias (book, plantas, vídeos…).
--  * Cada item é um arquivo enviado ou um link (tour virtual, vídeo no YouTube…).
--  * Sec. Vendas e administrador adicionam e removem; corretores e
--    imobiliárias só visualizam e baixam.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create table public.portal_itens (
  id            uuid primary key default gen_random_uuid(),
  categoria     text not null check (categoria in (
                  'book', 'ficha_tecnica', 'fotos_decorado', 'imagens', 'materiais_apoio',
                  'redes_sociais', 'plantas', 'simulador', 'tour_virtual', 'videos')),
  titulo        text not null check (length(trim(titulo)) >= 2),
  descricao     text,
  link          text check (link is null or link ~* '^https?://'),
  caminho       text,              -- arquivo no bucket "portal"
  nome_arquivo  text,
  tamanho       bigint,
  tipo_mime     text,
  criado_por    text,
  criado_em     timestamptz not null default now(),
  check ((link is not null) <> (caminho is not null))
);
create index portal_itens_categoria_idx on public.portal_itens (categoria);

alter table public.portal_itens enable row level security;

-- Quem enxerga o portal: equipe e quem tem login de imobiliária ou corretor
create or replace function public.acesso_portal() returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe() or public.minha_imobiliaria() is not null;
$$;

create policy portal_leitura on public.portal_itens for select using (public.acesso_portal());
grant select on public.portal_itens to authenticated;

-- Arquivos: bucket privado; downloads por link temporário
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('portal', 'portal', false, 524288000, null)
on conflict (id) do update set public = false;

create policy portal_arquivos_leitura on storage.objects for select to authenticated
  using (bucket_id = 'portal' and public.acesso_portal());
create policy portal_arquivos_envio on storage.objects for insert to authenticated
  with check (bucket_id = 'portal' and public.eh_equipe());
create policy portal_arquivos_remocao on storage.objects for delete to authenticated
  using (bucket_id = 'portal' and public.eh_equipe());

-- Adicionar item (arquivo já enviado ao bucket, ou link)
create or replace function public.adicionar_item_portal(
  p_categoria text, p_titulo text, p_descricao text default null, p_link text default null,
  p_caminho text default null, p_nome_arquivo text default null, p_tamanho bigint default null, p_tipo text default null
) returns public.portal_itens
language plpgsql security definer set search_path = public as $$
declare v public.portal_itens;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_titulo)), 0) < 2 then raise exception 'TITULO_OBRIGATORIO'; end if;
  if (nullif(trim(p_link), '') is null) = (p_caminho is null) then raise exception 'ARQUIVO_OU_LINK'; end if;
  if nullif(trim(p_link), '') is not null and trim(p_link) !~* '^https?://' then raise exception 'LINK_INVALIDO'; end if;
  insert into public.portal_itens (categoria, titulo, descricao, link, caminho, nome_arquivo, tamanho, tipo_mime, criado_por)
  values (p_categoria, trim(p_titulo), nullif(trim(p_descricao), ''), nullif(trim(p_link), ''), p_caminho,
          p_nome_arquivo, p_tamanho, p_tipo, public.meu_email())
  returning * into v;
  return v;
exception when check_violation then
  raise exception 'CATEGORIA_INVALIDA';
end;
$$;

create or replace function public.editar_item_portal(p_id uuid, p_titulo text, p_descricao text default null) returns public.portal_itens
language plpgsql security definer set search_path = public as $$
declare v public.portal_itens;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_titulo)), 0) < 2 then raise exception 'TITULO_OBRIGATORIO'; end if;
  update public.portal_itens set titulo = trim(p_titulo), descricao = nullif(trim(p_descricao), '')
   where id = p_id returning * into v;
  if not found then raise exception 'ITEM_NAO_ENCONTRADO'; end if;
  return v;
end;
$$;

-- Remove o item; devolve o caminho do arquivo para a tela apagar do bucket
create or replace function public.remover_item_portal(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_caminho text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  delete from public.portal_itens where id = p_id returning caminho into v_caminho;
  if not found then raise exception 'ITEM_NAO_ENCONTRADO'; end if;
  return v_caminho;
end;
$$;

revoke all on function public.adicionar_item_portal(text, text, text, text, text, text, bigint, text) from public, anon;
revoke all on function public.editar_item_portal(uuid, text, text) from public, anon;
revoke all on function public.remover_item_portal(uuid) from public, anon;
grant execute on function public.adicionar_item_portal(text, text, text, text, text, text, bigint, text) to authenticated;
grant execute on function public.editar_item_portal(uuid, text, text) to authenticated;
grant execute on function public.remover_item_portal(uuid) to authenticated;

-- >>>>> 024_carta_modelo.sql
-- =====================================================================
-- 024 — Carta proposta no modelo novo
--  * Campos da carta: vaga, escaninho, coordenação comercial.
--  * Textos de abertura e condições gerais do modelo (foro de Rio Verde).
--  * Nome de quem criou a proposta (sai como corretor na carta).
-- Executar uma única vez no SQL Editor do Supabase (projeto de testes).
-- =====================================================================

alter table public.comercial
  add column if not exists vaga                  text not null default 'Não inclui',
  add column if not exists escaninho             text not null default 'Não inclui',
  add column if not exists coordenacao_comercial text;

update public.comercial set
  forma_sinal = 'PIX',
  coordenacao_comercial = coalesce(coordenacao_comercial, 'Kavaná'),
  texto_abertura = 'Por meio desta, o(s) proponente(s) abaixo qualificado(s) formaliza(m) proposta para aquisição da unidade descrita, nos termos e condições a seguir, para avaliação da vendedora.',
  texto_condicoes = $t$A partir desta data e até o mês da expedição do habite-se, os valores serão reajustados pelo INCC (Índice Nacional de Custo da Construção). A partir do primeiro dia do mês seguinte ao habite-se e até a quitação, os valores serão reajustados mensalmente pelo IGP-M (Índice Geral de Preços do Mercado), acrescidos de juros de 1% (um por cento) ao mês.
Esta proposta será analisada pela vendedora, que poderá recusá-la, ainda que sem motivação.
A concessão do financiamento bancário está sujeita à análise de crédito e aos critérios do banco financiador. É de responsabilidade exclusiva do(s) proponente(s) obter os recursos para a parcela de financiamento, por crédito bancário ou recursos próprios.
Os honorários de intermediação imobiliária serão pagos com o sinal de negócio definido nesta proposta. Os valores de sinal e intermediação devem ser quitados na assinatura desta proposta.
Em caso de recusa desta proposta ou de não compensação do sinal, ela perderá qualquer eficácia jurídica e a unidade ficará liberada para comercialização, sem ônus para o(s) proponente(s).
Questões oriundas desta proposta serão resolvidas preferencialmente por via conciliatória ou arbitral, ficando eleito o foro da comarca de Rio Verde - GO.$t$,
  atualizado_em = now()
where id = 1;

-- Nome de quem criou a proposta
alter table public.propostas add column if not exists criado_por_nome text;
update public.propostas p set criado_por_nome = coalesce(nullif(pf.nome, ''), pf.email)
  from public.perfis pf where pf.user_id = p.criado_por_id and p.criado_por_nome is null;

create or replace function public.propostas_nome_criador() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    select coalesce(nullif(nome, ''), email) into new.criado_por_nome from public.perfis where user_id = auth.uid();
  else
    new.criado_por_nome := old.criado_por_nome;
  end if;
  return new;
end;
$$;
drop trigger if exists propostas_nome_criador on public.propostas;
-- roda depois de propostas_antes (ordem alfabética dos gatilhos)
create trigger propostas_nome_criador before insert or update on public.propostas
  for each row execute function public.propostas_nome_criador();

-- >>>>> 025_novas_series.sql
-- =====================================================================
-- 025 — Novas séries: Bimestrais, Trimestrais e Permuta
--  * Tabelas de venda passam a aceitar as novas periodicidades.
--  * Proposta com Permuta só é enviada com as observações preenchidas
--    (o que entra na permuta: imóvel, carro, serviços...).
-- Executar uma única vez no SQL Editor do Supabase (projeto de testes).
-- =====================================================================

alter table public.tabelas_series drop constraint if exists tabelas_series_periodicidade_check;
alter table public.tabelas_series add constraint tabelas_series_periodicidade_check
  check (periodicidade in ('Sinal', 'Mensais', 'Bimestrais', 'Trimestrais', 'Semestrais', 'Anuais', 'Unica', 'Permuta', 'Financiamento'));

create or replace function public.enviar_proposta(p_id uuid) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare v public.propostas;
begin
  select * into v from public.propostas where id = p_id for update;
  if not found or not public.acesso_pasta(v.imobiliaria_id, v.criado_por_id) then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  if v.status not in ('rascunho', 'devolvida') then raise exception 'PROPOSTA_BLOQUEADA'; end if;
  if v.pasta_id is null then raise exception 'PASTA_OBRIGATORIA' using hint = 'Vincule a pasta do comprador antes de enviar.'; end if;
  if jsonb_array_length(v.series) = 0 then raise exception 'SERIES_INVALIDAS'; end if;
  if exists (select 1 from jsonb_array_elements(v.series) s where s ->> 'periodicidade' = 'Permuta')
     and length(trim(coalesce(v.observacoes, ''))) < 5 then
    raise exception 'PERMUTA_SEM_OBSERVACAO' using hint = 'Descreva a permuta nas observações da proposta.';
  end if;
  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas set status = 'enviada', enviada_em = now(), motivo_analise = null where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);
  return v;
end;
$$;
revoke all on function public.enviar_proposta(uuid) from public, anon;
grant execute on function public.enviar_proposta(uuid) to authenticated;
