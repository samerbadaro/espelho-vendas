-- =====================================================================
-- INSTALAÇÃO COMPLETA DA V2 (projeto de testes do Supabase)
-- Migrações do Duo Haus (001...) e da v2 (101...) na ordem. Para um projeto NOVO.
-- Gerado a partir de supabase/migrations/ — não editar à mão.
-- =====================================================================


-- >>>>> supabase/migrations/001_estrutura.sql
-- =====================================================================
-- ESPELHO DE VENDAS — estrutura do banco (Supabase / PostgreSQL)
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- Status comerciais possíveis de uma unidade
create type public.status_unidade as enum ('disponivel', 'reservada', 'vendida', 'bloqueada');

-- ---------------------------------------------------------------------
-- Configuração geral (linha única)
-- ---------------------------------------------------------------------
create table public.config (
  id                  int primary key default 1 check (id = 1),
  nome_empreendimento text not null default 'Espelho de Vendas',
  publico_ativo       boolean not null default true,   -- link público ligado/desligado
  atualizado_em       timestamptz not null default now()
);
insert into public.config default values;

-- ---------------------------------------------------------------------
-- Equipe com acesso ao painel (Sec. Vendas e administradores)
-- O login é feito pelo Supabase Auth; só quem tem linha aqui altera algo.
-- ---------------------------------------------------------------------
create table public.perfis (
  user_id   uuid primary key references auth.users (id) on delete cascade,
  email     text not null,
  nome      text,
  papel     text not null check (papel in ('admin', 'vendas')),
  criado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Unidades (sem nenhum dado pessoal de comprador)
-- ---------------------------------------------------------------------
create table public.unidades (
  id             uuid primary key default gen_random_uuid(),
  numero         text not null unique,          -- ex.: 1205
  andar          int  not null,
  posicao        int  not null,                 -- coluna no espelho (final da unidade)
  area_privativa numeric(8, 2),
  tipologia      text,
  status         public.status_unidade not null default 'disponivel',
  versao         int  not null default 1,       -- controle de edição simultânea
  atualizado_em  timestamptz not null default now(),
  unique (andar, posicao)
);

-- ---------------------------------------------------------------------
-- Histórico de toda mudança de status (auditoria)
-- ---------------------------------------------------------------------
create table public.historico (
  id              bigint generated always as identity primary key,
  unidade_id      uuid not null references public.unidades (id),
  numero          text not null,
  status_anterior public.status_unidade,
  status_novo     public.status_unidade not null,
  motivo          text,
  usuario_id      uuid,
  usuario_email   text,
  criado_em       timestamptz not null default now()
);
create index historico_unidade_idx on public.historico (unidade_id, criado_em desc);
create index historico_data_idx    on public.historico (criado_em desc);

-- ---------------------------------------------------------------------
-- Funções auxiliares de permissão
-- ---------------------------------------------------------------------
create function public.eh_equipe() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid());
$$;

create function public.eh_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid() and papel = 'admin');
$$;

-- ---------------------------------------------------------------------
-- Row Level Security: leitura controlada, escrita SOMENTE pelas funções
-- ---------------------------------------------------------------------
alter table public.config    enable row level security;
alter table public.perfis    enable row level security;
alter table public.unidades  enable row level security;
alter table public.historico enable row level security;

revoke all on public.config, public.perfis, public.unidades, public.historico from anon, authenticated;
grant select on public.config, public.unidades to anon, authenticated;
grant select on public.perfis, public.historico to authenticated;

-- Configuração: todos leem (nome do empreendimento e se o link público está ativo)
create policy config_leitura on public.config for select using (true);

-- Unidades: público lê só se o link público estiver ativo; equipe sempre lê
create policy unidades_leitura on public.unidades for select
  using ((select publico_ativo from public.config where id = 1) or public.eh_equipe());

-- Histórico: só a equipe
create policy historico_leitura on public.historico for select using (public.eh_equipe());

-- Perfis: cada um vê o próprio; admin vê todos
create policy perfis_leitura on public.perfis for select
  using (user_id = auth.uid() or public.eh_admin());

-- ---------------------------------------------------------------------
-- Alterar status de uma unidade (única forma de escrita)
--  * exige usuário da equipe
--  * trava a linha (FOR UPDATE) e confere a versão: se outra pessoa
--    alterou antes, retorna erro CONFLITO em vez de sobrescrever
--  * desfazer reserva/venda exige motivo
--  * grava histórico
-- ---------------------------------------------------------------------
create function public.alterar_status(
  p_unidade_id uuid,
  p_status     public.status_unidade,
  p_versao     int,
  p_motivo     text default null
) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  v_unidade public.unidades;
  v_email    text;
  v_anterior public.status_unidade;
  v_motivo  text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.eh_equipe() then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;

  select * into v_unidade from public.unidades where id = p_unidade_id for update;
  if not found then
    raise exception 'UNIDADE_NAO_ENCONTRADA';
  end if;

  if v_unidade.versao <> p_versao then
    raise exception 'CONFLITO' using hint = 'A unidade foi alterada por outra pessoa. Recarregue.';
  end if;

  if v_unidade.status = p_status then
    return v_unidade;
  end if;

  if v_unidade.status in ('reservada', 'vendida') and p_status in ('disponivel', 'bloqueada')
     and v_motivo is null then
    raise exception 'MOTIVO_OBRIGATORIO';
  end if;

  select email into v_email from public.perfis where user_id = auth.uid();
  v_anterior := v_unidade.status;

  update public.unidades
     set status = p_status, versao = versao + 1, atualizado_em = now()
   where id = p_unidade_id
  returning * into v_unidade;

  insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email)
  values (v_unidade.id, v_unidade.numero, v_anterior, p_status, v_motivo, auth.uid(), v_email);

  return v_unidade;
end;
$$;

-- ---------------------------------------------------------------------
-- Ligar/desligar o link público (somente admin)
-- ---------------------------------------------------------------------
create function public.definir_publico(p_ativo boolean) returns public.config
language plpgsql security definer set search_path = public as $$
declare v_config public.config;
begin
  if not public.eh_admin() then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  update public.config set publico_ativo = p_ativo, atualizado_em = now() where id = 1
  returning * into v_config;
  return v_config;
end;
$$;

revoke all on function public.alterar_status(uuid, public.status_unidade, int, text) from public, anon;
revoke all on function public.definir_publico(boolean) from public, anon;
grant execute on function public.alterar_status(uuid, public.status_unidade, int, text) to authenticated;
grant execute on function public.definir_publico(boolean) to authenticated;

-- ---------------------------------------------------------------------
-- Tempo real: avisa as telas quando unidades ou configuração mudam
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.unidades, public.config;
  end if;
end $$;

-- >>>>> supabase/migrations/002_unidades.sql
-- =====================================================================
-- Carga inicial das 173 unidades
--  * 2º andar: finais 01 a 08 (posições 09–11 são o lazer)
--  * 3º ao 17º andar: finais 01 a 11 (numeração sequencial, com 13º andar)
--  * Área privativa por final, conforme a planta enviada
-- Tipologia fica em branco até ser informada.
-- =====================================================================
with areas(posicao, area) as (
  values (1, 34.93), (2, 35.00), (3, 35.00), (4, 34.93), (5, 34.93), (6, 34.93),
         (7, 34.93), (8, 34.99), (9, 34.99), (10, 34.93), (11, 34.92)
)
insert into public.unidades (numero, andar, posicao, area_privativa)
select (andar * 100 + a.posicao)::text, andar, a.posicao, a.area
from generate_series(2, 17) as andar
cross join areas a
where not (andar = 2 and a.posicao > 8)
order by andar, a.posicao;

-- >>>>> supabase/migrations/003_negociacoes.sql
-- =====================================================================
-- 003 — Novos status (Proposta recebida, Contrato em assinatura),
--        dados da negociação por etapa, nome e tipologia.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Novos status, na ordem do funil
-- ---------------------------------------------------------------------
alter type public.status_unidade add value if not exists 'proposta' after 'reservada';
alter type public.status_unidade add value if not exists 'contrato' after 'proposta';

-- ---------------------------------------------------------------------
-- Negociação da unidade (dados SÓ para a equipe logada)
-- Uma negociação ativa por unidade; ao liberar a unidade ela é encerrada
-- e fica guardada para consulta.
-- ---------------------------------------------------------------------
create table public.negociacoes (
  id                   bigint generated always as identity primary key,
  unidade_id           uuid not null references public.unidades (id),
  imobiliaria          text,
  corretor             text,
  cliente              text,
  valor_venda          numeric(14, 2) check (valor_venda > 0),
  pv_aprovado          numeric(6, 2)  check (pv_aprovado >= 0),
  ativa                boolean not null default true,
  motivo_encerramento  text,
  criado_por           text,
  criada_em            timestamptz not null default now(),
  atualizada_em        timestamptz not null default now(),
  encerrada_em         timestamptz
);
create unique index negociacoes_uma_ativa on public.negociacoes (unidade_id) where ativa;

alter table public.negociacoes enable row level security;
revoke all on public.negociacoes from anon, authenticated;
grant select on public.negociacoes to authenticated;
create policy negociacoes_leitura on public.negociacoes for select using (public.eh_equipe());

-- Detalhes informados em cada mudança (para o histórico)
alter table public.historico add column if not exists detalhes jsonb;

-- ---------------------------------------------------------------------
-- Nova versão da função de alteração de status
--  Reservada ............ exige imobiliária, corretor e cliente
--  Proposta recebida .... exige também valor da venda e PV aprovado (%)
--  Contrato / Vendida ... não exige nada
--  Voltar para Disponível ou Bloqueada a partir de qualquer etapa da
--  negociação exige motivo e encerra a negociação.
--  Campos já informados antes são aproveitados (não precisa redigitar).
-- ---------------------------------------------------------------------
drop function if exists public.alterar_status(uuid, public.status_unidade, int, text);

create function public.alterar_status(
  p_unidade_id  uuid,
  p_status      public.status_unidade,
  p_versao      int,
  p_motivo      text    default null,
  p_imobiliaria text    default null,
  p_corretor    text    default null,
  p_cliente     text    default null,
  p_valor       numeric default null,
  p_pv          numeric default null
) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  v_unidade  public.unidades;
  v_neg      public.negociacoes;
  v_email    text;
  v_anterior public.status_unidade;
  v_motivo   text := nullif(trim(coalesce(p_motivo, '')), '');
  v_imob     text;
  v_corretor text;
  v_cliente  text;
  v_valor    numeric;
  v_pv       numeric;
  v_detalhes jsonb;
begin
  if not public.eh_equipe() then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;

  select * into v_unidade from public.unidades where id = p_unidade_id for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  if v_unidade.versao <> p_versao then
    raise exception 'CONFLITO' using hint = 'A unidade foi alterada por outra pessoa. Recarregue.';
  end if;
  if v_unidade.status = p_status then return v_unidade; end if;

  v_anterior := v_unidade.status;
  select email into v_email from public.perfis where user_id = auth.uid();
  select * into v_neg from public.negociacoes where unidade_id = p_unidade_id and ativa for update;

  if p_status in ('disponivel', 'bloqueada') then
    -- saindo da negociação
    if v_anterior not in ('disponivel', 'bloqueada') and v_motivo is null then
      raise exception 'MOTIVO_OBRIGATORIO';
    end if;
    if v_neg.id is not null then
      update public.negociacoes
         set ativa = false, encerrada_em = now(), motivo_encerramento = v_motivo, atualizada_em = now()
       where id = v_neg.id;
    end if;
    v_detalhes := null;
  else
    -- etapa da negociação: aproveita o que já foi informado
    v_imob     := coalesce(nullif(trim(coalesce(p_imobiliaria, '')), ''), v_neg.imobiliaria);
    v_corretor := coalesce(nullif(trim(coalesce(p_corretor, '')), ''),    v_neg.corretor);
    v_cliente  := coalesce(nullif(trim(coalesce(p_cliente, '')), ''),     v_neg.cliente);
    v_valor    := coalesce(p_valor, v_neg.valor_venda);
    v_pv       := coalesce(p_pv, v_neg.pv_aprovado);

    if p_status in ('reservada', 'proposta')
       and (v_imob is null or v_corretor is null or v_cliente is null) then
      raise exception 'DADOS_RESERVA_OBRIGATORIOS';
    end if;
    if p_status = 'proposta' and (v_valor is null or v_pv is null) then
      raise exception 'DADOS_PROPOSTA_OBRIGATORIOS';
    end if;
    if v_valor is not null and v_valor <= 0 then raise exception 'VALOR_INVALIDO'; end if;
    if v_pv is not null and v_pv < 0 then raise exception 'PV_INVALIDO'; end if;

    if v_neg.id is null then
      insert into public.negociacoes (unidade_id, imobiliaria, corretor, cliente, valor_venda, pv_aprovado, criado_por)
      values (p_unidade_id, v_imob, v_corretor, v_cliente, v_valor, v_pv, v_email);
    else
      update public.negociacoes
         set imobiliaria = v_imob, corretor = v_corretor, cliente = v_cliente,
             valor_venda = v_valor, pv_aprovado = v_pv, atualizada_em = now()
       where id = v_neg.id;
    end if;

    v_detalhes := jsonb_strip_nulls(jsonb_build_object(
      'imobiliaria', nullif(trim(coalesce(p_imobiliaria, '')), ''),
      'corretor',    nullif(trim(coalesce(p_corretor, '')), ''),
      'cliente',     nullif(trim(coalesce(p_cliente, '')), ''),
      'valor_venda', p_valor,
      'pv_aprovado', p_pv));
    if v_detalhes = '{}'::jsonb then v_detalhes := null; end if;
  end if;

  update public.unidades
     set status = p_status, versao = versao + 1, atualizado_em = now()
   where id = p_unidade_id
  returning * into v_unidade;

  insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
  values (v_unidade.id, v_unidade.numero, v_anterior, p_status, v_motivo, auth.uid(), v_email, v_detalhes);

  return v_unidade;
end;
$$;

revoke all on function public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric) from public, anon;
grant execute on function public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- Nome do empreendimento e tipologia
-- ---------------------------------------------------------------------
update public.config set nome_empreendimento = 'Duo Haus – Wellness + Life', atualizado_em = now() where id = 1;
update public.unidades set tipologia = 'Studio compacto' where tipologia is null;

-- >>>>> supabase/migrations/004_pastas.sql
-- =====================================================================
-- 004 — Imobiliárias, pastas de compradores e documentos
-- Executar uma única vez no SQL Editor do Supabase.
--
-- Regra central: uma imobiliária NUNCA vê pastas, documentos ou arquivos
-- de outra. Isso é garantido aqui no banco (RLS), não só nas telas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Imobiliárias
-- ---------------------------------------------------------------------
create table public.imobiliarias (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null unique check (length(trim(nome)) > 1),
  ativa     boolean not null default true,
  criada_em timestamptz not null default now()
);

-- Perfis passam a aceitar o papel "imobiliaria" (um login por imobiliária)
alter table public.perfis drop constraint if exists perfis_papel_check;
alter table public.perfis add constraint perfis_papel_check check (papel in ('admin', 'vendas', 'imobiliaria'));
alter table public.perfis add column imobiliaria_id uuid references public.imobiliarias (id);
alter table public.perfis add column trocar_senha boolean not null default false;
alter table public.perfis add constraint perfis_imobiliaria_check
  check ((papel = 'imobiliaria') = (imobiliaria_id is not null));

-- ---------------------------------------------------------------------
-- Funções de permissão
--  eh_equipe(): admin ou Sec. Vendas (NÃO inclui imobiliárias)
--  minha_imobiliaria(): id da imobiliária do usuário logado (se ativa)
-- ---------------------------------------------------------------------
create or replace function public.eh_equipe() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid() and papel in ('admin', 'vendas'));
$$;

create function public.minha_imobiliaria() returns uuid
language sql stable security definer set search_path = public as $$
  select p.imobiliaria_id
    from public.perfis p join public.imobiliarias i on i.id = p.imobiliaria_id
   where p.user_id = auth.uid() and p.papel = 'imobiliaria' and i.ativa;
$$;

create function public.meu_email() returns text
language sql stable security definer set search_path = public as $$
  select email from public.perfis where user_id = auth.uid();
$$;

-- Imobiliárias logadas também veem o espelho, mesmo com o link público fora do ar
drop policy unidades_leitura on public.unidades;
create policy unidades_leitura on public.unidades for select
  using ((select publico_ativo from public.config where id = 1) or public.eh_equipe()
         or public.minha_imobiliaria() is not null);

alter table public.imobiliarias enable row level security;
revoke all on public.imobiliarias from anon, authenticated;
grant select on public.imobiliarias to authenticated;
grant insert (nome, ativa), update (nome, ativa) on public.imobiliarias to authenticated;
create policy imobiliarias_leitura on public.imobiliarias for select
  using (public.eh_equipe() or id = public.minha_imobiliaria());
create policy imobiliarias_inclusao on public.imobiliarias for insert with check (public.eh_admin());
create policy imobiliarias_edicao on public.imobiliarias for update using (public.eh_admin()) with check (public.eh_admin());

-- Admin vê todos os perfis; cada usuário vê o próprio (política já existe)

-- ---------------------------------------------------------------------
-- Pastas de compradores
-- ---------------------------------------------------------------------
create type public.estado_civil as enum ('solteiro', 'casado', 'uniao_estavel', 'divorciado', 'viuvo');
create type public.status_pasta as enum ('incompleta', 'aguardando_analise', 'em_analise', 'pendente_correcao', 'aprovada');

create sequence public.pastas_codigo_seq;

create table public.pastas (
  id                   uuid primary key default gen_random_uuid(),
  codigo               text not null unique default 'P-' || lpad(nextval('public.pastas_codigo_seq')::text, 4, '0'),
  imobiliaria_id       uuid not null default public.minha_imobiliaria() references public.imobiliarias (id),
  unidade_id           uuid references public.unidades (id),
  comprador_nome       text not null check (length(trim(comprador_nome)) > 1),
  comprador_cpf        text not null check (comprador_cpf ~ '^[0-9]{11}$'),
  comprador_nascimento date,
  comprador_telefone   text,
  comprador_email      text,
  estado_civil         public.estado_civil not null default 'solteiro',
  conjuge_nome         text,
  conjuge_cpf          text check (conjuge_cpf is null or conjuge_cpf ~ '^[0-9]{11}$'),
  conjuge_nascimento   date,
  conjuge_telefone     text,
  conjuge_email        text,
  dados_bancarios      text,          -- banco/agência/conta ou chave PIX
  observacoes          text,
  status               public.status_pasta not null default 'incompleta',
  criado_por           text,
  criada_em            timestamptz not null default now(),
  atualizada_em        timestamptz not null default now()
);
create index pastas_imobiliaria_idx on public.pastas (imobiliaria_id);
create index pastas_cpf_idx on public.pastas (comprador_cpf);
create index pastas_unidade_idx on public.pastas (unidade_id);

-- ---------------------------------------------------------------------
-- Tipos de documento (configuráveis sem mexer no código)
--  obrigatorio_para: estados civis em que o documento é obrigatório
--  exibir_para: estados civis em que o campo aparece (vazio = sempre)
--  multiplo: aceita vários arquivos (ex.: "Outros documentos")
-- ---------------------------------------------------------------------
create table public.tipos_documento (
  id               serial primary key,
  nome             text not null,
  pessoa           text not null check (pessoa in ('comprador', 'conjuge', 'geral')),
  obrigatorio_para public.estado_civil[] not null default '{}',
  exibir_para      public.estado_civil[] not null default '{}',
  multiplo         boolean not null default false,
  ordem            int not null default 0,
  ativo            boolean not null default true
);

insert into public.tipos_documento (nome, pessoa, obrigatorio_para, exibir_para, multiplo, ordem) values
  ('RG ou CNH', 'comprador', '{solteiro,casado,uniao_estavel,divorciado,viuvo}', '{}', false, 10),
  ('CPF (se não constar no RG/CNH)', 'comprador', '{}', '{}', false, 20),
  ('Comprovante de endereço', 'comprador', '{solteiro,casado,uniao_estavel,divorciado,viuvo}', '{}', false, 30),
  ('Certidão de nascimento', 'comprador', '{solteiro}', '{solteiro}', false, 40),
  ('Certidão de casamento', 'comprador', '{casado}', '{casado}', false, 41),
  ('Escritura ou declaração de união estável', 'comprador', '{uniao_estavel}', '{uniao_estavel}', false, 42),
  ('Certidão de casamento com averbação do divórcio', 'comprador', '{divorciado}', '{divorciado}', false, 43),
  ('Certidão de casamento e certidão de óbito do cônjuge', 'comprador', '{viuvo}', '{viuvo}', false, 44),
  ('RG ou CNH do cônjuge', 'conjuge', '{casado,uniao_estavel}', '{casado,uniao_estavel}', false, 50),
  ('CPF do cônjuge (se não constar no RG/CNH)', 'conjuge', '{}', '{casado,uniao_estavel}', false, 60),
  ('Comprovante de endereço do cônjuge (se diferente)', 'conjuge', '{}', '{casado,uniao_estavel}', false, 70),
  ('Procuração', 'geral', '{}', '{}', false, 80),
  ('Outros documentos', 'geral', '{}', '{}', true, 90);

-- ---------------------------------------------------------------------
-- Documentos enviados (cada arquivo é uma linha; substituições ficam
-- guardadas com atual = false, para auditoria)
-- ---------------------------------------------------------------------
create type public.status_documento as enum ('enviado', 'em_analise', 'aprovado', 'recusado');

create table public.documentos (
  id            uuid primary key default gen_random_uuid(),
  pasta_id      uuid not null references public.pastas (id),
  tipo_id       int  not null references public.tipos_documento (id),
  caminho       text not null unique,       -- caminho no armazenamento privado
  nome_arquivo  text not null,
  tamanho       bigint,
  mime          text,
  status        public.status_documento not null default 'enviado',
  motivo_recusa text,
  atual         boolean not null default true,
  enviado_por   text,
  enviado_em    timestamptz not null default now(),
  analisado_por text,
  analisado_em  timestamptz
);
create index documentos_pasta_idx on public.documentos (pasta_id, tipo_id);

-- ---------------------------------------------------------------------
-- Histórico das pastas (auditoria; não grava CPF nem dados pessoais)
-- ---------------------------------------------------------------------
create table public.historico_pastas (
  id            bigint generated always as identity primary key,
  pasta_id      uuid not null references public.pastas (id),
  acao          text not null,
  detalhes      jsonb,
  usuario_email text,
  criado_em     timestamptz not null default now()
);
create index historico_pastas_idx on public.historico_pastas (pasta_id, criado_em desc);

-- ---------------------------------------------------------------------
-- Acesso a uma pasta: equipe vê todas; imobiliária só as suas
-- ---------------------------------------------------------------------
create function public.pode_ver_pasta(p_pasta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.pastas p
     where p.id = p_pasta
       and (public.eh_equipe() or p.imobiliaria_id = public.minha_imobiliaria()));
$$;

alter table public.pastas           enable row level security;
alter table public.tipos_documento  enable row level security;
alter table public.documentos       enable row level security;
alter table public.historico_pastas enable row level security;

revoke all on public.pastas, public.tipos_documento, public.documentos, public.historico_pastas from anon, authenticated;
revoke all on sequence public.pastas_codigo_seq from anon;
grant usage on sequence public.pastas_codigo_seq to authenticated;

grant select on public.pastas, public.tipos_documento, public.documentos, public.historico_pastas to authenticated;
-- campos que podem ser preenchidos; status, unidade e código só mudam pelas funções
grant insert (imobiliaria_id, comprador_nome, comprador_cpf, comprador_nascimento, comprador_telefone, comprador_email,
              estado_civil, conjuge_nome, conjuge_cpf, conjuge_nascimento, conjuge_telefone, conjuge_email,
              dados_bancarios, observacoes) on public.pastas to authenticated;
grant update (comprador_nome, comprador_cpf, comprador_nascimento, comprador_telefone, comprador_email,
              estado_civil, conjuge_nome, conjuge_cpf, conjuge_nascimento, conjuge_telefone, conjuge_email,
              dados_bancarios, observacoes) on public.pastas to authenticated;

create policy pastas_leitura on public.pastas for select
  using (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria());
create policy pastas_inclusao on public.pastas for insert
  with check (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria());
create policy pastas_edicao on public.pastas for update
  using (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria())
  with check (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria());

create policy tipos_leitura on public.tipos_documento for select
  using (public.eh_equipe() or public.minha_imobiliaria() is not null);
create policy documentos_leitura on public.documentos for select using (public.pode_ver_pasta(pasta_id));
create policy historico_pastas_leitura on public.historico_pastas for select using (public.pode_ver_pasta(pasta_id));

-- ---------------------------------------------------------------------
-- Status geral da pasta, calculado automaticamente
--  pendente_correcao: algum documento atual recusado
--  incompleta: falta documento obrigatório (ou o do cônjuge, se casado/união)
--  aprovada: todos os obrigatórios aprovados e nada aguardando
--  em_analise: algum documento em análise
--  aguardando_analise: tudo enviado, ninguém analisou ainda
-- ---------------------------------------------------------------------
create function public.recalcular_pasta(p_pasta uuid) returns public.status_pasta
language plpgsql security definer set search_path = public as $$
declare
  v_ec       public.estado_civil;
  v_status   public.status_pasta;
  v_faltando int;
  v_recusado int;
  v_analise  int;
  v_enviado  int;
begin
  select estado_civil into v_ec from public.pastas where id = p_pasta;

  select count(*) into v_recusado from public.documentos where pasta_id = p_pasta and atual and status = 'recusado';
  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo and v_ec = any (t.obrigatorio_para)
     and not exists (select 1 from public.documentos d where d.pasta_id = p_pasta and d.tipo_id = t.id and d.atual);
  select count(*) into v_analise from public.documentos where pasta_id = p_pasta and atual and status = 'em_analise';
  select count(*) into v_enviado from public.documentos where pasta_id = p_pasta and atual and status = 'enviado';

  v_status := case
    when v_recusado > 0 then 'pendente_correcao'
    when v_faltando > 0 then 'incompleta'
    when v_analise > 0 then 'em_analise'
    when v_enviado > 0 then 'aguardando_analise'
    else 'aprovada' end;

  update public.pastas set status = v_status where id = p_pasta and status is distinct from v_status;
  return v_status;
end;
$$;

-- Ao criar/editar a pasta: registra quem, quais campos mudaram e recalcula o status
create function public.pastas_antes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := public.meu_email();
  end if;
  new.atualizada_em := now();
  -- limpa dados do cônjuge quando o estado civil não tem cônjuge
  if new.estado_civil not in ('casado', 'uniao_estavel') then
    new.conjuge_nome := null; new.conjuge_cpf := null; new.conjuge_nascimento := null;
    new.conjuge_telefone := null; new.conjuge_email := null;
  end if;
  return new;
end;
$$;

create function public.pastas_depois() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_campos text[];
begin
  if tg_op = 'INSERT' then
    insert into public.historico_pastas (pasta_id, acao, usuario_email) values (new.id, 'Pasta criada', public.meu_email());
    perform public.recalcular_pasta(new.id);
  else
    select array_agg(n.key order by n.key) into v_campos
      from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value
       and n.key not in ('status', 'atualizada_em', 'unidade_id');
    if v_campos is not null then
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (new.id, 'Dados alterados', jsonb_build_object('campos', v_campos), public.meu_email());
    end if;
    if new.estado_civil is distinct from old.estado_civil then
      perform public.recalcular_pasta(new.id);
    end if;
  end if;
  return null;
end;
$$;

create trigger pastas_antes before insert or update on public.pastas
  for each row execute function public.pastas_antes();
create trigger pastas_depois after insert or update on public.pastas
  for each row execute function public.pastas_depois();

-- ---------------------------------------------------------------------
-- Armazenamento privado dos arquivos
-- Caminho: <imobiliaria_id>/<pasta_id>/<arquivo>
-- Sem link público: cada visualização gera um link temporário, após
-- conferir quem está pedindo.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos', 'documentos', false, 15728640,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
on conflict (id) do update set public = false;

create function public.pode_acessar_arquivo(p_caminho text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_imob uuid; v_pasta uuid;
begin
  v_imob  := split_part(p_caminho, '/', 1)::uuid;
  v_pasta := split_part(p_caminho, '/', 2)::uuid;
  return exists (
    select 1 from public.pastas p
     where p.id = v_pasta and p.imobiliaria_id = v_imob
       and (public.eh_equipe() or p.imobiliaria_id = public.minha_imobiliaria()));
exception when others then
  return false;
end;
$$;

create policy documentos_envio on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and public.pode_acessar_arquivo(name));
create policy documentos_visualizacao on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and public.pode_acessar_arquivo(name));
-- sem políticas de update/delete: arquivos enviados não podem ser apagados nem trocados

-- ---------------------------------------------------------------------
-- Registrar um arquivo enviado
--  * confere acesso à pasta e se o arquivo está mesmo no lugar certo
--  * imobiliária só substitui documento recusado ou ainda não analisado
--  * a versão anterior fica guardada (atual = false)
-- ---------------------------------------------------------------------
create function public.registrar_documento(
  p_pasta uuid, p_tipo int, p_caminho text, p_nome text, p_tamanho bigint, p_mime text
) returns public.documentos
language plpgsql security definer set search_path = public as $$
declare
  v_pasta public.pastas;
  v_tipo  public.tipos_documento;
  v_atual public.documentos;
  v_doc   public.documentos;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not (public.eh_equipe() or v_pasta.imobiliaria_id = public.minha_imobiliaria()) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if p_caminho not like v_pasta.imobiliaria_id::text || '/' || v_pasta.id::text || '/%' then
    raise exception 'CAMINHO_INVALIDO';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'documentos' and name = p_caminho) then
    raise exception 'ARQUIVO_NAO_ENCONTRADO';
  end if;
  select * into v_tipo from public.tipos_documento where id = p_tipo and ativo;
  if not found then raise exception 'TIPO_INVALIDO'; end if;

  if not v_tipo.multiplo then
    select * into v_atual from public.documentos where pasta_id = p_pasta and tipo_id = p_tipo and atual for update;
    if v_atual.id is not null then
      if not public.eh_equipe() and v_atual.status in ('em_analise', 'aprovado') then
        raise exception 'DOCUMENTO_BLOQUEADO';
      end if;
      update public.documentos set atual = false where id = v_atual.id;
    end if;
  end if;

  insert into public.documentos (pasta_id, tipo_id, caminho, nome_arquivo, tamanho, mime, enviado_por)
  values (p_pasta, p_tipo, p_caminho, left(p_nome, 200), p_tamanho, left(p_mime, 100), public.meu_email())
  returning * into v_doc;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, case when v_atual.id is null then 'Documento enviado' else 'Documento substituído' end,
          jsonb_build_object('documento', v_tipo.nome, 'arquivo', left(p_nome, 200)), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- Analisar documento (somente equipe): em análise, aprovado ou recusado
-- ---------------------------------------------------------------------
create function public.analisar_documento(
  p_documento uuid, p_status public.status_documento, p_motivo text default null
) returns public.documentos
language plpgsql security definer set search_path = public as $$
declare
  v_doc    public.documentos;
  v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
  v_nome   text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_status = 'enviado' then raise exception 'STATUS_INVALIDO'; end if;
  if p_status = 'recusado' and v_motivo is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;

  update public.documentos
     set status = p_status,
         motivo_recusa = case when p_status = 'recusado' then v_motivo else null end,
         analisado_por = public.meu_email(), analisado_em = now()
   where id = p_documento and atual
  returning * into v_doc;
  if not found then raise exception 'DOCUMENTO_NAO_ENCONTRADO'; end if;

  select nome into v_nome from public.tipos_documento where id = v_doc.tipo_id;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v_doc.pasta_id,
          case p_status when 'aprovado' then 'Documento aprovado' when 'recusado' then 'Documento recusado' else 'Documento em análise' end,
          jsonb_strip_nulls(jsonb_build_object('documento', v_nome, 'motivo', v_motivo)), public.meu_email());

  perform public.recalcular_pasta(v_doc.pasta_id);
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- Vincular pasta a uma unidade (somente equipe)
-- ---------------------------------------------------------------------
create function public.vincular_unidade(p_pasta uuid, p_unidade uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas; v_numero text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.pastas set unidade_id = p_unidade where id = p_pasta returning * into v_pasta;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  select numero into v_numero from public.unidades where id = p_unidade;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, case when p_unidade is null then 'Unidade desvinculada' else 'Unidade vinculada' end,
          jsonb_strip_nulls(jsonb_build_object('unidade', v_numero)), public.meu_email());
  return v_pasta;
end;
$$;

-- Usuário marca que já trocou a senha provisória
create function public.senha_trocada() returns void
language sql security definer set search_path = public as $$
  update public.perfis set trocar_senha = false where user_id = auth.uid();
$$;

revoke all on function public.recalcular_pasta(uuid) from public, anon, authenticated;
revoke all on function public.registrar_documento(uuid, int, text, text, bigint, text) from public, anon;
revoke all on function public.analisar_documento(uuid, public.status_documento, text) from public, anon;
revoke all on function public.vincular_unidade(uuid, uuid) from public, anon;
revoke all on function public.senha_trocada() from public, anon;
grant execute on function public.registrar_documento(uuid, int, text, text, bigint, text) to authenticated;
grant execute on function public.analisar_documento(uuid, public.status_documento, text) to authenticated;
grant execute on function public.vincular_unidade(uuid, uuid) to authenticated;
grant execute on function public.senha_trocada() to authenticated;

-- >>>>> supabase/migrations/005_corretores.sql
-- =====================================================================
-- 005 — Corretores
--  * Imobiliária (gestor) vê TODAS as pastas da imobiliária e cria os
--    logins dos seus corretores.
--  * Corretor vê SOMENTE as pastas que ele mesmo criou.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- Novo papel
alter table public.perfis drop constraint if exists perfis_papel_check;
alter table public.perfis add constraint perfis_papel_check check (papel in ('admin', 'vendas', 'imobiliaria', 'corretor'));
alter table public.perfis drop constraint if exists perfis_imobiliaria_check;
alter table public.perfis add constraint perfis_imobiliaria_check
  check ((papel in ('imobiliaria', 'corretor')) = (imobiliaria_id is not null));

-- Quem criou a pasta (id do login), para o filtro do corretor
alter table public.pastas add column if not exists criado_por_id uuid;
update public.pastas p set criado_por_id = pf.user_id
  from public.perfis pf where p.criado_por_id is null and pf.email = p.criado_por;
create index if not exists pastas_criador_idx on public.pastas (criado_por_id);

-- ---------------------------------------------------------------------
-- Funções de permissão
-- ---------------------------------------------------------------------
create or replace function public.minha_imobiliaria() returns uuid
language sql stable security definer set search_path = public as $$
  select p.imobiliaria_id
    from public.perfis p join public.imobiliarias i on i.id = p.imobiliaria_id
   where p.user_id = auth.uid() and p.papel in ('imobiliaria', 'corretor') and i.ativa;
$$;

-- gestor = login da imobiliária (vê tudo da imobiliária)
create function public.eh_gestor() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid() and papel = 'imobiliaria');
$$;

-- Regra única de acesso a uma pasta
create function public.acesso_pasta(p_imob uuid, p_criador uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe()
      or (p_imob = public.minha_imobiliaria() and (public.eh_gestor() or p_criador = auth.uid()));
$$;

create or replace function public.pode_ver_pasta(p_pasta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pastas p where p.id = p_pasta and public.acesso_pasta(p.imobiliaria_id, p.criado_por_id));
$$;

create or replace function public.pode_acessar_arquivo(p_caminho text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_imob uuid; v_pasta uuid;
begin
  v_imob  := split_part(p_caminho, '/', 1)::uuid;
  v_pasta := split_part(p_caminho, '/', 2)::uuid;
  return exists (
    select 1 from public.pastas p
     where p.id = v_pasta and p.imobiliaria_id = v_imob
       and public.acesso_pasta(p.imobiliaria_id, p.criado_por_id));
exception when others then
  return false;
end;
$$;

-- ---------------------------------------------------------------------
-- Políticas
-- ---------------------------------------------------------------------
drop policy pastas_leitura on public.pastas;
drop policy pastas_edicao on public.pastas;
create policy pastas_leitura on public.pastas for select
  using (public.acesso_pasta(imobiliaria_id, criado_por_id));
create policy pastas_edicao on public.pastas for update
  using (public.acesso_pasta(imobiliaria_id, criado_por_id))
  with check (public.acesso_pasta(imobiliaria_id, criado_por_id));
-- inclusão continua: só na própria imobiliária (ou equipe)

-- Perfis: cada um vê o próprio; admin vê todos; imobiliária vê os seus corretores
drop policy perfis_leitura on public.perfis;
create policy perfis_leitura on public.perfis for select
  using (user_id = auth.uid() or public.eh_admin()
         or (public.eh_gestor() and imobiliaria_id = public.minha_imobiliaria()));

-- ---------------------------------------------------------------------
-- Registro do criador da pasta
-- ---------------------------------------------------------------------
create or replace function public.pastas_antes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := public.meu_email();
    new.criado_por_id := auth.uid();
  end if;
  new.atualizada_em := now();
  if new.estado_civil not in ('casado', 'uniao_estavel') then
    new.conjuge_nome := null; new.conjuge_cpf := null; new.conjuge_nascimento := null;
    new.conjuge_telefone := null; new.conjuge_email := null;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Envio de documento passa a usar a mesma regra de acesso
-- ---------------------------------------------------------------------
create or replace function public.registrar_documento(
  p_pasta uuid, p_tipo int, p_caminho text, p_nome text, p_tamanho bigint, p_mime text
) returns public.documentos
language plpgsql security definer set search_path = public as $$
declare
  v_pasta public.pastas;
  v_tipo  public.tipos_documento;
  v_atual public.documentos;
  v_doc   public.documentos;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if p_caminho not like v_pasta.imobiliaria_id::text || '/' || v_pasta.id::text || '/%' then
    raise exception 'CAMINHO_INVALIDO';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'documentos' and name = p_caminho) then
    raise exception 'ARQUIVO_NAO_ENCONTRADO';
  end if;
  select * into v_tipo from public.tipos_documento where id = p_tipo and ativo;
  if not found then raise exception 'TIPO_INVALIDO'; end if;

  if not v_tipo.multiplo then
    select * into v_atual from public.documentos where pasta_id = p_pasta and tipo_id = p_tipo and atual for update;
    if v_atual.id is not null then
      if not public.eh_equipe() and v_atual.status in ('em_analise', 'aprovado') then
        raise exception 'DOCUMENTO_BLOQUEADO';
      end if;
      update public.documentos set atual = false where id = v_atual.id;
    end if;
  end if;

  insert into public.documentos (pasta_id, tipo_id, caminho, nome_arquivo, tamanho, mime, enviado_por)
  values (p_pasta, p_tipo, p_caminho, left(p_nome, 200), p_tamanho, left(p_mime, 100), public.meu_email())
  returning * into v_doc;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, case when v_atual.id is null then 'Documento enviado' else 'Documento substituído' end,
          jsonb_build_object('documento', v_tipo.nome, 'arquivo', left(p_nome, 200)), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  return v_doc;
end;
$$;

-- >>>>> supabase/migrations/006_submissao.sql
-- =====================================================================
-- 006 — Submissão ao incorporador, comprovante do PIX e campos obrigatórios
--  * P-001: pasta criada (rascunho da imobiliária/corretor)
--  * PA-001: pasta submetida para aprovação do incorporador
--  * Submeter só é possível com todos os documentos obrigatórios anexados
--  * Campo de dados bancários/PIX removido; entra o anexo "Comprovante do PIX"
--  * Telefone, e-mail e profissão do comprador passam a ser obrigatórios
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Códigos com 3 dígitos (P-001, PA-001); a partir de 1000 segue P-1000
-- ---------------------------------------------------------------------
create function public.formatar_codigo(p_prefixo text, p_numero bigint) returns text
language sql immutable as $$
  select p_prefixo || '-' || case when p_numero < 1000 then lpad(p_numero::text, 3, '0') else p_numero::text end;
$$;
alter table public.pastas alter column codigo set default public.formatar_codigo('P', nextval('public.pastas_codigo_seq'));

create sequence public.pastas_aprovacao_seq;
grant usage on sequence public.pastas_aprovacao_seq to authenticated;

alter table public.pastas add column codigo_aprovacao text unique;
alter table public.pastas add column submetida_em timestamptz;
alter table public.pastas add column submetida_por text;

-- ---------------------------------------------------------------------
-- Status da pasta passa a ser texto (inclui "pronta" = pronta para submeter)
-- ---------------------------------------------------------------------
drop function public.recalcular_pasta(uuid) cascade;
alter table public.pastas alter column status drop default;
alter table public.pastas alter column status type text using status::text;
alter table public.pastas alter column status set default 'incompleta';
alter table public.pastas add constraint pastas_status_check
  check (status in ('incompleta', 'pronta', 'aguardando_analise', 'em_analise', 'pendente_correcao', 'aprovada'));
drop type public.status_pasta;

create function public.recalcular_pasta(p_pasta uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ec        public.estado_civil;
  v_submetida boolean;
  v_status    text;
  v_faltando  int;
  v_recusado  int;
  v_analise   int;
  v_enviado   int;
begin
  select estado_civil, codigo_aprovacao is not null into v_ec, v_submetida from public.pastas where id = p_pasta;

  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo and v_ec = any (t.obrigatorio_para)
     and not exists (select 1 from public.documentos d where d.pasta_id = p_pasta and d.tipo_id = t.id and d.atual);
  select count(*) into v_recusado from public.documentos where pasta_id = p_pasta and atual and status = 'recusado';
  select count(*) into v_analise  from public.documentos where pasta_id = p_pasta and atual and status = 'em_analise';
  select count(*) into v_enviado  from public.documentos where pasta_id = p_pasta and atual and status = 'enviado';

  if not v_submetida then
    v_status := case when v_faltando > 0 then 'incompleta' else 'pronta' end;
  else
    v_status := case
      when v_recusado > 0 then 'pendente_correcao'
      when v_faltando > 0 then 'incompleta'
      when v_analise > 0 then 'em_analise'
      when v_enviado > 0 then 'aguardando_analise'
      else 'aprovada' end;
  end if;

  update public.pastas set status = v_status where id = p_pasta and status is distinct from v_status;
  return v_status;
end;
$$;
revoke all on function public.recalcular_pasta(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Campos do comprador: sai dados bancários/PIX, entra profissão;
-- telefone, e-mail e profissão obrigatórios para pastas novas/editadas
-- ---------------------------------------------------------------------
alter table public.pastas drop column dados_bancarios;
alter table public.pastas add column comprador_profissao text;
alter table public.pastas add constraint pastas_campos_obrigatorios check (
  length(trim(coalesce(comprador_telefone, ''))) >= 10
  and length(trim(coalesce(comprador_email, ''))) > 3
  and length(trim(coalesce(comprador_profissao, ''))) > 1) not valid;
grant insert (comprador_profissao), update (comprador_profissao) on public.pastas to authenticated;

-- Depois de submetida, só a equipe edita os dados da pasta
drop policy pastas_edicao on public.pastas;
create policy pastas_edicao on public.pastas for update
  using (public.acesso_pasta(imobiliaria_id, criado_por_id) and (public.eh_equipe() or codigo_aprovacao is null))
  with check (public.acesso_pasta(imobiliaria_id, criado_por_id) and (public.eh_equipe() or codigo_aprovacao is null));

-- Gatilho que recalcula ao criar a pasta ou mudar o estado civil
create or replace function public.pastas_depois() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_campos text[];
begin
  if tg_op = 'INSERT' then
    insert into public.historico_pastas (pasta_id, acao, usuario_email) values (new.id, 'Pasta criada', public.meu_email());
    perform public.recalcular_pasta(new.id);
  else
    select array_agg(n.key order by n.key) into v_campos
      from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value
       and n.key not in ('status', 'atualizada_em', 'unidade_id', 'codigo_aprovacao', 'submetida_em', 'submetida_por');
    if v_campos is not null then
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (new.id, 'Dados alterados', jsonb_build_object('campos', v_campos), public.meu_email());
    end if;
    if new.estado_civil is distinct from old.estado_civil then
      perform public.recalcular_pasta(new.id);
    end if;
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- "Outros documentos" vira "Comprovante do PIX" (obrigatório, aceita mais de um arquivo)
-- ---------------------------------------------------------------------
update public.tipos_documento
   set nome = 'Comprovante do PIX', obrigatorio_para = '{solteiro,casado,uniao_estavel,divorciado,viuvo}', multiplo = true
 where nome = 'Outros documentos';

-- ---------------------------------------------------------------------
-- Submeter a pasta ao incorporador: gera o código PA
-- ---------------------------------------------------------------------
create function public.submeter_pasta(p_pasta uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas; v_faltando int;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v_pasta.codigo_aprovacao is not null then raise exception 'JA_SUBMETIDA'; end if;
  if length(trim(coalesce(v_pasta.comprador_telefone, ''))) < 10
     or length(trim(coalesce(v_pasta.comprador_email, ''))) <= 3
     or length(trim(coalesce(v_pasta.comprador_profissao, ''))) <= 1 then
    raise exception 'DADOS_INCOMPLETOS';
  end if;
  if public.recalcular_pasta(p_pasta) <> 'pronta' then raise exception 'DOCUMENTOS_FALTANDO'; end if;

  update public.pastas
     set codigo_aprovacao = public.formatar_codigo('PA', nextval('public.pastas_aprovacao_seq')),
         submetida_em = now(), submetida_por = public.meu_email()
   where id = p_pasta
  returning * into v_pasta;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pasta submetida ao incorporador', jsonb_build_object('codigo', v_pasta.codigo_aprovacao), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$$;
revoke all on function public.submeter_pasta(uuid) from public, anon;
grant execute on function public.submeter_pasta(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Análise só depois da submissão
-- ---------------------------------------------------------------------
create or replace function public.analisar_documento(
  p_documento uuid, p_status public.status_documento, p_motivo text default null
) returns public.documentos
language plpgsql security definer set search_path = public as $$
declare
  v_doc    public.documentos;
  v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
  v_nome   text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_status = 'enviado' then raise exception 'STATUS_INVALIDO'; end if;
  if p_status = 'recusado' and v_motivo is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  if not exists (select 1 from public.documentos d join public.pastas p on p.id = d.pasta_id
                  where d.id = p_documento and p.codigo_aprovacao is not null) then
    raise exception 'PASTA_NAO_SUBMETIDA';
  end if;

  update public.documentos
     set status = p_status,
         motivo_recusa = case when p_status = 'recusado' then v_motivo else null end,
         analisado_por = public.meu_email(), analisado_em = now()
   where id = p_documento and atual
  returning * into v_doc;
  if not found then raise exception 'DOCUMENTO_NAO_ENCONTRADO'; end if;

  select nome into v_nome from public.tipos_documento where id = v_doc.tipo_id;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v_doc.pasta_id,
          case p_status when 'aprovado' then 'Documento aprovado' when 'recusado' then 'Documento recusado' else 'Documento em análise' end,
          jsonb_strip_nulls(jsonb_build_object('documento', v_nome, 'motivo', v_motivo)), public.meu_email());

  perform public.recalcular_pasta(v_doc.pasta_id);
  return v_doc;
end;
$$;

-- registrar_documento e analisar chamam recalcular_pasta; recria as permissões
grant execute on function public.analisar_documento(uuid, public.status_documento, text) to authenticated;

-- Recalcula o status de todas as pastas existentes (ainda não submetidas)
select public.recalcular_pasta(id) from public.pastas;

-- >>>>> supabase/migrations/007_correcao_obrigatorios.sql
-- =====================================================================
-- 007 — Correção: telefone, e-mail e profissão obrigatórios só ao CRIAR
-- ou EDITAR os dados da pasta. A atualização automática de status (ao
-- anexar documentos) não pode ser barrada por pastas antigas sem esses dados.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.pastas drop constraint if exists pastas_campos_obrigatorios;

create or replace function public.pastas_antes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := public.meu_email();
    new.criado_por_id := auth.uid();
  end if;

  -- valida os campos obrigatórios quando a pasta é criada ou quando os dados são editados
  if tg_op = 'INSERT'
     or (new.comprador_nome, new.comprador_cpf, new.comprador_nascimento, new.comprador_telefone,
         new.comprador_email, new.comprador_profissao, new.estado_civil, new.observacoes)
        is distinct from
        (old.comprador_nome, old.comprador_cpf, old.comprador_nascimento, old.comprador_telefone,
         old.comprador_email, old.comprador_profissao, old.estado_civil, old.observacoes) then
    if length(trim(coalesce(new.comprador_telefone, ''))) < 10
       or length(trim(coalesce(new.comprador_email, ''))) <= 3
       or length(trim(coalesce(new.comprador_profissao, ''))) <= 1 then
      raise exception 'DADOS_INCOMPLETOS' using hint = 'Telefone, e-mail e profissão do comprador são obrigatórios.';
    end if;
  end if;

  new.atualizada_em := now();
  if new.estado_civil not in ('casado', 'uniao_estavel') then
    new.conjuge_nome := null; new.conjuge_cpf := null; new.conjuge_nascimento := null;
    new.conjuge_telefone := null; new.conjuge_email := null;
  end if;
  return new;
end;
$$;

-- >>>>> supabase/migrations/008_marca_e_visualizacoes.sql
-- =====================================================================
-- 008 — Marca configurável, módulo de pastas opcional e registro de
--        quem visualizou cada documento.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Identidade visual e módulos do empreendimento (editável pelo admin)
-- ---------------------------------------------------------------------
alter table public.config
  add column cor_primaria     text not null default '#23251C' check (cor_primaria ~ '^#[0-9A-Fa-f]{6}$'),
  add column cor_destaque     text not null default '#94874A' check (cor_destaque ~ '^#[0-9A-Fa-f]{6}$'),
  add column logo_url         text,
  add column logo_escuro_url  text,
  add column imagem_login_url text,
  add column cidade           text,
  add column modulo_pastas    boolean not null default true;

grant update (nome_empreendimento, cor_primaria, cor_destaque, logo_url, logo_escuro_url,
              imagem_login_url, cidade, modulo_pastas, atualizado_em) on public.config to authenticated;
create policy config_edicao on public.config for update using (public.eh_admin()) with check (public.eh_admin());

-- Arquivos da marca (logo e imagem do login) são públicos por natureza
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('marca', 'marca', true, 5242880, array['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml'])
on conflict (id) do nothing;
create policy marca_envio on storage.objects for insert to authenticated
  with check (bucket_id = 'marca' and public.eh_admin());

-- ---------------------------------------------------------------------
-- Visualização de documentos: passa obrigatoriamente pelo servidor,
-- que registra quem abriu e gera um link de 1 minuto.
-- Os usuários deixam de poder baixar arquivos diretamente.
-- ---------------------------------------------------------------------
drop policy if exists documentos_visualizacao on storage.objects;

create function public.registrar_visualizacao(p_documento uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_doc public.documentos; v_tipo text;
begin
  select * into v_doc from public.documentos where id = p_documento;
  if not found or not public.pode_ver_pasta(v_doc.pasta_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  select nome into v_tipo from public.tipos_documento where id = v_doc.tipo_id;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v_doc.pasta_id, 'Documento visualizado', jsonb_build_object('documento', v_tipo, 'arquivo', v_doc.nome_arquivo), public.meu_email());
  return v_doc.caminho;
end;
$$;
revoke all on function public.registrar_visualizacao(uuid) from public, anon;
grant execute on function public.registrar_visualizacao(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Indicadores da tela inicial (somente equipe)
-- ---------------------------------------------------------------------
create function public.indicadores() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  return jsonb_build_object(
    'unidades', (select jsonb_object_agg(status, n) from (select status::text, count(*) n from public.unidades group by status) s),
    'pastas',   (select jsonb_object_agg(status, n) from (select status, count(*) n from public.pastas group by status) s),
    'pastas_total', (select count(*) from public.pastas),
    'pastas_submetidas', (select count(*) from public.pastas where codigo_aprovacao is not null),
    'vendas_7_dias', (select count(*) from public.historico where status_novo = 'vendida' and criado_em > now() - interval '7 days'),
    'reservas_7_dias', (select count(*) from public.historico where status_novo = 'reservada' and criado_em > now() - interval '7 days')
  );
end;
$$;
revoke all on function public.indicadores() from public, anon;
grant execute on function public.indicadores() to authenticated;

-- >>>>> supabase/migrations/009_relatorios.sql
-- =====================================================================
-- 009 — Sec. Vendas passa a ver os nomes dos logins (corretores e
-- imobiliárias), para os relatórios e a exportação de pastas.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================
drop policy perfis_leitura on public.perfis;
create policy perfis_leitura on public.perfis for select
  using (user_id = auth.uid() or public.eh_equipe()
         or (public.eh_gestor() and imobiliaria_id = public.minha_imobiliaria()));

-- >>>>> supabase/migrations/010_profissao_conjuge.sql
-- =====================================================================
-- 010 — Profissão do cônjuge
--  * Novo campo, exibido quando o estado civil é casado ou união estável
--  * Para submeter ao incorporador, o cônjuge precisa ter nome, CPF e profissão
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.pastas add column if not exists conjuge_profissao text;
grant insert (conjuge_profissao), update (conjuge_profissao) on public.pastas to authenticated;

-- Limpa a profissão do cônjuge junto com os demais dados quando não há cônjuge
create or replace function public.pastas_antes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := public.meu_email();
    new.criado_por_id := auth.uid();
  end if;

  if tg_op = 'INSERT'
     or (new.comprador_nome, new.comprador_cpf, new.comprador_nascimento, new.comprador_telefone,
         new.comprador_email, new.comprador_profissao, new.estado_civil, new.observacoes)
        is distinct from
        (old.comprador_nome, old.comprador_cpf, old.comprador_nascimento, old.comprador_telefone,
         old.comprador_email, old.comprador_profissao, old.estado_civil, old.observacoes) then
    if length(trim(coalesce(new.comprador_telefone, ''))) < 10
       or length(trim(coalesce(new.comprador_email, ''))) <= 3
       or length(trim(coalesce(new.comprador_profissao, ''))) <= 1 then
      raise exception 'DADOS_INCOMPLETOS' using hint = 'Telefone, e-mail e profissão do comprador são obrigatórios.';
    end if;
  end if;

  new.atualizada_em := now();
  if new.estado_civil not in ('casado', 'uniao_estavel') then
    new.conjuge_nome := null; new.conjuge_cpf := null; new.conjuge_nascimento := null;
    new.conjuge_telefone := null; new.conjuge_email := null; new.conjuge_profissao := null;
  end if;
  return new;
end;
$$;

-- Submissão: exige também os dados principais do cônjuge
create or replace function public.submeter_pasta(p_pasta uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v_pasta.codigo_aprovacao is not null then raise exception 'JA_SUBMETIDA'; end if;
  if length(trim(coalesce(v_pasta.comprador_telefone, ''))) < 10
     or length(trim(coalesce(v_pasta.comprador_email, ''))) <= 3
     or length(trim(coalesce(v_pasta.comprador_profissao, ''))) <= 1 then
    raise exception 'DADOS_INCOMPLETOS';
  end if;
  if v_pasta.estado_civil in ('casado', 'uniao_estavel')
     and (length(trim(coalesce(v_pasta.conjuge_nome, ''))) <= 1
          or v_pasta.conjuge_cpf is null
          or length(trim(coalesce(v_pasta.conjuge_profissao, ''))) <= 1) then
    raise exception 'DADOS_CONJUGE_INCOMPLETOS';
  end if;
  if public.recalcular_pasta(p_pasta) <> 'pronta' then raise exception 'DOCUMENTOS_FALTANDO'; end if;

  update public.pastas
     set codigo_aprovacao = public.formatar_codigo('PA', nextval('public.pastas_aprovacao_seq')),
         submetida_em = now(), submetida_por = public.meu_email()
   where id = p_pasta
  returning * into v_pasta;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pasta submetida ao incorporador', jsonb_build_object('codigo', v_pasta.codigo_aprovacao), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$$;
revoke all on function public.submeter_pasta(uuid) from public, anon;
grant execute on function public.submeter_pasta(uuid) to authenticated;

-- >>>>> supabase/migrations/011_identidade_duohaus.sql
-- =====================================================================
-- 011 — Cor de apoio e fonte configuráveis + identidade do Duo Haus
--  cor_apoio: cor neutra da marca (faixas do prédio, fundos suaves)
--  fonte: família do Google Fonts usada no sistema
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================
alter table public.config
  add column if not exists cor_apoio text not null default '#CFCBC2' check (cor_apoio ~ '^#[0-9A-Fa-f]{6}$'),
  add column if not exists fonte text not null default 'Archivo' check (fonte ~ '^[A-Za-z0-9 ]{2,40}$');
grant update (cor_apoio, fonte) on public.config to authenticated;

-- Identidade visual do Duo Haus – Wellness + Life (book de marca Casa 7)
update public.config set
  cor_primaria     = '#000000',   -- Duo Black
  cor_destaque     = '#F07F40',   -- Duo Laranja
  cor_apoio        = '#D0BFAE',   -- Duo Areia
  fonte            = '42dot Sans',
  logo_url         = '/marca/duohaus-logo.svg',
  logo_escuro_url  = '/marca/duohaus-logo-escuro.svg',
  imagem_login_url = '/marca/duohaus-login.jpg',
  cidade           = coalesce(cidade, 'Rio Verde, GO'),
  atualizado_em    = now()
where id = 1;

-- >>>>> supabase/migrations/012_funil_e_download.sql
-- =====================================================================
-- 012 — Funil de vendas (kanban) e download de todos os documentos
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Etapa da venda, depois da documentação aprovada
-- ---------------------------------------------------------------------
alter table public.pastas
  add column if not exists etapa_venda text not null default 'aprovada'
    check (etapa_venda in ('aprovada', 'reserva', 'contrato_confeccao', 'enviado_assinatura', 'assinado')),
  add column if not exists etapa_atualizada_em timestamptz;

create function public.mover_etapa(p_pasta uuid, p_etapa text) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare
  v_pasta public.pastas;
  v_rotulo text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if v_pasta.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
  if p_etapa not in ('aprovada', 'reserva', 'contrato_confeccao', 'enviado_assinatura', 'assinado') then
    raise exception 'ETAPA_INVALIDA';
  end if;
  if v_pasta.etapa_venda = p_etapa then return v_pasta; end if;

  update public.pastas set etapa_venda = p_etapa, etapa_atualizada_em = now() where id = p_pasta
  returning * into v_pasta;

  v_rotulo := case p_etapa
    when 'aprovada' then 'Pasta aprovada' when 'reserva' then 'Reserva'
    when 'contrato_confeccao' then 'Contrato em confecção' when 'enviado_assinatura' then 'Enviado para assinatura'
    else 'Assinado / Vendido' end;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Etapa da venda alterada', jsonb_build_object('documento', v_rotulo), public.meu_email());
  return v_pasta;
end;
$$;
revoke all on function public.mover_etapa(uuid, text) from public, anon;
grant execute on function public.mover_etapa(uuid, text) to authenticated;

-- O gatilho de histórico não deve registrar a etapa como "dados alterados"
create or replace function public.pastas_depois() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_campos text[];
begin
  if tg_op = 'INSERT' then
    insert into public.historico_pastas (pasta_id, acao, usuario_email) values (new.id, 'Pasta criada', public.meu_email());
    perform public.recalcular_pasta(new.id);
  else
    select array_agg(n.key order by n.key) into v_campos
      from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value
       and n.key not in ('status', 'atualizada_em', 'unidade_id', 'codigo_aprovacao', 'submetida_em', 'submetida_por',
                         'etapa_venda', 'etapa_atualizada_em');
    if v_campos is not null then
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (new.id, 'Dados alterados', jsonb_build_object('campos', v_campos), public.meu_email());
    end if;
    if new.estado_civil is distinct from old.estado_civil then
      perform public.recalcular_pasta(new.id);
    end if;
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- Sigla de cada tipo de documento (usada no nome dos arquivos baixados)
-- ---------------------------------------------------------------------
alter table public.tipos_documento add column if not exists sigla text;
update public.tipos_documento set sigla = case
  when nome like 'RG ou CNH%' then 'IDENTIFICACAO'
  when nome like 'CPF%' then 'CPF'
  when nome like 'Comprovante de endereço%' then 'ENDERECO'
  when nome = 'Certidão de nascimento' then 'CERTIDAO_NASCIMENTO'
  when nome = 'Certidão de casamento' then 'CERTIDAO_CASAMENTO'
  when nome like 'Escritura ou declaração de união estável%' then 'UNIAO_ESTAVEL'
  when nome like '%averbação do divórcio%' then 'CERTIDAO_DIVORCIO'
  when nome like '%óbito%' then 'CERTIDAO_OBITO'
  when nome = 'Procuração' then 'PROCURACAO'
  when nome = 'Comprovante do PIX' then 'PIX'
  else 'DOCUMENTO' end
where sigla is null;

-- ---------------------------------------------------------------------
-- Lista os documentos atuais de uma pasta para o download completo
-- (somente equipe) e registra o download no histórico
-- ---------------------------------------------------------------------
create function public.registrar_download(p_pasta uuid)
returns table (caminho text, nome_arquivo text, sigla text, pessoa text, nome_pessoa text, codigo text, cliente text)
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into v_pasta from public.pastas where id = p_pasta;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;

  insert into public.historico_pastas (pasta_id, acao, usuario_email)
  values (p_pasta, 'Download de todos os documentos', public.meu_email());

  return query
    select d.caminho, d.nome_arquivo, coalesce(t.sigla, 'DOCUMENTO'), t.pessoa,
           case when t.pessoa = 'conjuge' then coalesce(v_pasta.conjuge_nome, 'CONJUGE') else v_pasta.comprador_nome end,
           coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo), v_pasta.comprador_nome
      from public.documentos d join public.tipos_documento t on t.id = d.tipo_id
     where d.pasta_id = p_pasta and d.atual
     order by t.ordem, d.enviado_em;
end;
$$;
revoke all on function public.registrar_download(uuid) from public, anon;
grant execute on function public.registrar_download(uuid) to authenticated;

-- >>>>> supabase/migrations/013_funil_espelho.sql
-- =====================================================================
-- 013 — Funil de vendas ligado ao espelho
--  Pasta aprovada ........... unidade volta a Disponível (se estava com a pasta)
--  Reserva .................. Reservada
--  Contrato em confecção .... Proposta recebida
--  Enviado para assinatura .. Contrato em assinatura
--  Assinado / Vendido ....... Vendida
--  E no sentido contrário: liberar a unidade no espelho devolve a pasta
--  para "Pasta aprovada" no funil.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- A negociação passa a saber de qual pasta veio
alter table public.negociacoes add column if not exists pasta_id uuid references public.pastas (id);
create index if not exists negociacoes_pasta_idx on public.negociacoes (pasta_id) where ativa;

drop function if exists public.mover_etapa(uuid, text);

create function public.mover_etapa(p_pasta uuid, p_etapa text, p_unidade uuid default null) returns public.pastas
language plpgsql security definer set search_path = public as $fn$
declare
  v_pasta    public.pastas;
  v_unidade  public.unidades;
  v_neg      public.negociacoes;
  v_id_unid  uuid;
  v_novo     public.status_unidade;
  v_anterior public.status_unidade;
  v_email    text := public.meu_email();
  v_rotulo   text;
  v_imob     text;
  v_corretor text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_etapa not in ('aprovada', 'reserva', 'contrato_confeccao', 'enviado_assinatura', 'assinado') then
    raise exception 'ETAPA_INVALIDA';
  end if;
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if v_pasta.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;

  v_rotulo := case p_etapa
    when 'aprovada' then 'Pasta aprovada' when 'reserva' then 'Reserva'
    when 'contrato_confeccao' then 'Contrato em confecção' when 'enviado_assinatura' then 'Enviado para assinatura'
    else 'Assinado / Vendido' end;
  v_novo := case p_etapa
    when 'aprovada' then 'disponivel' when 'reserva' then 'reservada' when 'contrato_confeccao' then 'proposta'
    when 'enviado_assinatura' then 'contrato' else 'vendida' end;

  v_id_unid := coalesce(p_unidade, v_pasta.unidade_id);

  -- ---------- volta para "Pasta aprovada": libera a unidade, se ela estava com esta pasta ----------
  if p_etapa = 'aprovada' then
    if v_id_unid is not null then
      select * into v_unidade from public.unidades where id = v_id_unid for update;
      select * into v_neg from public.negociacoes where unidade_id = v_id_unid and ativa for update;
      if v_neg.pasta_id = p_pasta and v_unidade.status <> 'disponivel' then
        v_anterior := v_unidade.status;
        update public.negociacoes set ativa = false, encerrada_em = now(), atualizada_em = now(),
               motivo_encerramento = 'Pasta voltou para "Pasta aprovada" no funil de vendas'
         where id = v_neg.id;
        update public.unidades set status = 'disponivel', versao = versao + 1, atualizado_em = now()
         where id = v_id_unid returning * into v_unidade;
        insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
        values (v_unidade.id, v_unidade.numero, v_anterior, 'disponivel', 'Pasta voltou para "Pasta aprovada" no funil de vendas',
                auth.uid(), v_email, jsonb_build_object('pasta', coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo)));
      end if;
    end if;
    update public.pastas set etapa_venda = 'aprovada', etapa_atualizada_em = now(), unidade_id = null
     where id = p_pasta returning * into v_pasta;
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (p_pasta, 'Etapa da venda alterada', jsonb_build_object('documento', v_rotulo), v_email);
    return v_pasta;
  end if;

  -- ---------- demais etapas: exigem unidade ----------
  if v_id_unid is null then raise exception 'SEM_UNIDADE'; end if;
  select * into v_unidade from public.unidades where id = v_id_unid for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  select * into v_neg from public.negociacoes where unidade_id = v_id_unid and ativa for update;

  -- a unidade precisa estar livre, já estar com esta pasta, ou ter sido reservada no espelho
  -- e vinculada a esta pasta pela equipe (reserva feita antes de a documentação ficar pronta)
  if v_unidade.status = 'bloqueada'
     or (v_unidade.status <> 'disponivel'
         and coalesce(v_neg.pasta_id::text, '') <> p_pasta::text
         and not (v_neg.pasta_id is null and v_pasta.unidade_id is not distinct from v_id_unid)) then
    raise exception 'UNIDADE_OCUPADA' using hint = v_unidade.numero;
  end if;

  -- outra pasta não pode estar na mesma unidade; e esta pasta só ocupa uma unidade
  if v_pasta.unidade_id is not null and v_pasta.unidade_id <> v_id_unid then
    raise exception 'PASTA_JA_TEM_UNIDADE';
  end if;

  select i.nome into v_imob from public.imobiliarias i where i.id = v_pasta.imobiliaria_id;
  select coalesce(nullif(pf.nome, ''), pf.email) into v_corretor from public.perfis pf where pf.user_id = v_pasta.criado_por_id;

  if v_neg.id is null then
    insert into public.negociacoes (unidade_id, pasta_id, imobiliaria, corretor, cliente, criado_por)
    values (v_id_unid, p_pasta, v_imob, coalesce(v_corretor, v_pasta.criado_por), v_pasta.comprador_nome, v_email);
  else
    update public.negociacoes
       set pasta_id = p_pasta, imobiliaria = coalesce(imobiliaria, v_imob),
           corretor = coalesce(corretor, v_corretor, v_pasta.criado_por), cliente = coalesce(cliente, v_pasta.comprador_nome),
           atualizada_em = now()
     where id = v_neg.id;
  end if;

  if v_unidade.status <> v_novo then
    v_anterior := v_unidade.status;
    update public.unidades set status = v_novo, versao = versao + 1, atualizado_em = now()
     where id = v_id_unid returning * into v_unidade;
    insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
    values (v_unidade.id, v_unidade.numero, v_anterior, v_novo, 'Funil de vendas: ' || v_rotulo, auth.uid(), v_email,
            jsonb_build_object('pasta', coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo), 'cliente', v_pasta.comprador_nome));
  end if;

  if v_pasta.unidade_id is null then
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (p_pasta, 'Unidade vinculada', jsonb_build_object('unidade', v_unidade.numero), v_email);
  end if;

  update public.pastas set etapa_venda = p_etapa, etapa_atualizada_em = now(), unidade_id = v_id_unid
   where id = p_pasta returning * into v_pasta;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Etapa da venda alterada', jsonb_build_object('documento', v_rotulo, 'unidade', v_unidade.numero), v_email);
  return v_pasta;
end;
$fn$;
revoke all on function public.mover_etapa(uuid, text, uuid) from public, anon;
grant execute on function public.mover_etapa(uuid, text, uuid) to authenticated;

-- Espelho: liberar a unidade devolve a pasta vinculada para "Pasta aprovada"
create or replace function public.alterar_status(
  p_unidade_id  uuid,
  p_status      public.status_unidade,
  p_versao      int,
  p_motivo      text    default null,
  p_imobiliaria text    default null,
  p_corretor    text    default null,
  p_cliente     text    default null,
  p_valor       numeric default null,
  p_pv          numeric default null
) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  v_unidade  public.unidades;
  v_neg      public.negociacoes;
  v_email    text;
  v_anterior public.status_unidade;
  v_motivo   text := nullif(trim(coalesce(p_motivo, '')), '');
  v_imob     text;
  v_corretor text;
  v_cliente  text;
  v_valor    numeric;
  v_pv       numeric;
  v_detalhes jsonb;
begin
  if not public.eh_equipe() then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;

  select * into v_unidade from public.unidades where id = p_unidade_id for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  if v_unidade.versao <> p_versao then
    raise exception 'CONFLITO' using hint = 'A unidade foi alterada por outra pessoa. Recarregue.';
  end if;
  if v_unidade.status = p_status then return v_unidade; end if;

  v_anterior := v_unidade.status;
  select email into v_email from public.perfis where user_id = auth.uid();
  select * into v_neg from public.negociacoes where unidade_id = p_unidade_id and ativa for update;

  if p_status in ('disponivel', 'bloqueada') then
    -- saindo da negociação
    if v_anterior not in ('disponivel', 'bloqueada') and v_motivo is null then
      raise exception 'MOTIVO_OBRIGATORIO';
    end if;
    if v_neg.id is not null then
      update public.negociacoes
         set ativa = false, encerrada_em = now(), motivo_encerramento = v_motivo, atualizada_em = now()
       where id = v_neg.id;
      -- a pasta ligada a esta negociação volta para "Pasta aprovada" no funil e perde o vínculo com a unidade
      if v_neg.pasta_id is not null then
        update public.pastas set etapa_venda = 'aprovada', etapa_atualizada_em = now(), unidade_id = null
         where id = v_neg.pasta_id;
        insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
        values (v_neg.pasta_id, 'Unidade liberada no espelho',
                jsonb_strip_nulls(jsonb_build_object('unidade', v_unidade.numero, 'motivo', v_motivo)), v_email);
      end if;
    end if;
    v_detalhes := null;
  else
    -- etapa da negociação: aproveita o que já foi informado
    v_imob     := coalesce(nullif(trim(coalesce(p_imobiliaria, '')), ''), v_neg.imobiliaria);
    v_corretor := coalesce(nullif(trim(coalesce(p_corretor, '')), ''),    v_neg.corretor);
    v_cliente  := coalesce(nullif(trim(coalesce(p_cliente, '')), ''),     v_neg.cliente);
    v_valor    := coalesce(p_valor, v_neg.valor_venda);
    v_pv       := coalesce(p_pv, v_neg.pv_aprovado);

    if p_status in ('reservada', 'proposta')
       and (v_imob is null or v_corretor is null or v_cliente is null) then
      raise exception 'DADOS_RESERVA_OBRIGATORIOS';
    end if;
    if p_status = 'proposta' and (v_valor is null or v_pv is null) then
      raise exception 'DADOS_PROPOSTA_OBRIGATORIOS';
    end if;
    if v_valor is not null and v_valor <= 0 then raise exception 'VALOR_INVALIDO'; end if;
    if v_pv is not null and v_pv < 0 then raise exception 'PV_INVALIDO'; end if;

    if v_neg.id is null then
      insert into public.negociacoes (unidade_id, imobiliaria, corretor, cliente, valor_venda, pv_aprovado, criado_por)
      values (p_unidade_id, v_imob, v_corretor, v_cliente, v_valor, v_pv, v_email);
    else
      update public.negociacoes
         set imobiliaria = v_imob, corretor = v_corretor, cliente = v_cliente,
             valor_venda = v_valor, pv_aprovado = v_pv, atualizada_em = now()
       where id = v_neg.id;
    end if;

    v_detalhes := jsonb_strip_nulls(jsonb_build_object(
      'imobiliaria', nullif(trim(coalesce(p_imobiliaria, '')), ''),
      'corretor',    nullif(trim(coalesce(p_corretor, '')), ''),
      'cliente',     nullif(trim(coalesce(p_cliente, '')), ''),
      'valor_venda', p_valor,
      'pv_aprovado', p_pv));
    if v_detalhes = '{}'::jsonb then v_detalhes := null; end if;
  end if;

  update public.unidades
     set status = p_status, versao = versao + 1, atualizado_em = now()
   where id = p_unidade_id
  returning * into v_unidade;

  insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
  values (v_unidade.id, v_unidade.numero, v_anterior, p_status, v_motivo, auth.uid(), v_email, v_detalhes);

  return v_unidade;
end;
$$;
revoke all on function public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric) from public, anon;
grant execute on function public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric) to authenticated;

-- >>>>> supabase/migrations/014_reserva_com_pasta.sql
-- =====================================================================
-- 014 — Reserva no espelho exige pasta com documentação aprovada
--  * Para colocar uma unidade em Reservada, Proposta, Contrato ou Vendida,
--    a negociação precisa estar ligada a uma pasta com "Documentação aprovada".
--  * Imobiliária, corretor e cliente vêm da pasta.
--  * Mudar o status no espelho move a pasta no funil de vendas:
--      Reservada → Reserva · Proposta → Contrato em confecção
--      Contrato → Enviado para assinatura · Vendida → Assinado / Vendido
--  * Liberar a unidade continua devolvendo a pasta para "Pasta aprovada".
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

drop function if exists public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric);

create function public.alterar_status(
  p_unidade_id  uuid,
  p_status      public.status_unidade,
  p_versao      int,
  p_motivo      text    default null,
  p_imobiliaria text    default null,   -- mantidos por compatibilidade; a pasta prevalece
  p_corretor    text    default null,
  p_cliente     text    default null,
  p_valor       numeric default null,
  p_pv          numeric default null,
  p_pasta       uuid    default null
) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  v_unidade  public.unidades;
  v_neg      public.negociacoes;
  v_pasta    public.pastas;
  v_email    text;
  v_anterior public.status_unidade;
  v_motivo   text := nullif(trim(coalesce(p_motivo, '')), '');
  v_imob     text;
  v_corretor text;
  v_cliente  text;
  v_valor    numeric;
  v_pv       numeric;
  v_detalhes jsonb;
  v_etapa    text;
  v_rotulo   text;
  v_codigo   text;
begin
  if not public.eh_equipe() then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;

  select * into v_unidade from public.unidades where id = p_unidade_id for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  if v_unidade.versao <> p_versao then
    raise exception 'CONFLITO' using hint = 'A unidade foi alterada por outra pessoa. Recarregue.';
  end if;
  if v_unidade.status = p_status then return v_unidade; end if;

  v_anterior := v_unidade.status;
  select email into v_email from public.perfis where user_id = auth.uid();
  select * into v_neg from public.negociacoes where unidade_id = p_unidade_id and ativa for update;

  if p_status in ('disponivel', 'bloqueada') then
    -- ---------------- saindo da negociação ----------------
    if v_anterior not in ('disponivel', 'bloqueada') and v_motivo is null then
      raise exception 'MOTIVO_OBRIGATORIO';
    end if;
    if v_neg.id is not null then
      update public.negociacoes
         set ativa = false, encerrada_em = now(), motivo_encerramento = v_motivo, atualizada_em = now()
       where id = v_neg.id;
      if v_neg.pasta_id is not null then
        update public.pastas set etapa_venda = 'aprovada', etapa_atualizada_em = now(), unidade_id = null
         where id = v_neg.pasta_id;
        insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
        values (v_neg.pasta_id, 'Unidade liberada no espelho',
                jsonb_strip_nulls(jsonb_build_object('unidade', v_unidade.numero, 'motivo', v_motivo)), v_email);
      end if;
    end if;
    v_detalhes := null;
  else
    -- ---------------- em negociação: exige pasta aprovada ----------------
    if v_neg.pasta_id is not null then
      if p_pasta is not null and p_pasta <> v_neg.pasta_id then
        raise exception 'UNIDADE_COM_OUTRA_PASTA';
      end if;
      select * into v_pasta from public.pastas where id = v_neg.pasta_id for update;
    else
      if p_pasta is null then raise exception 'PASTA_OBRIGATORIA'; end if;
      select * into v_pasta from public.pastas where id = p_pasta for update;
      if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
      if v_pasta.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
      if v_pasta.unidade_id is not null and v_pasta.unidade_id <> p_unidade_id then
        raise exception 'PASTA_JA_TEM_UNIDADE';
      end if;
      if exists (select 1 from public.negociacoes where pasta_id = p_pasta and ativa and unidade_id <> p_unidade_id) then
        raise exception 'PASTA_JA_TEM_UNIDADE';
      end if;
    end if;

    select i.nome into v_imob from public.imobiliarias i where i.id = v_pasta.imobiliaria_id;
    select coalesce(nullif(pf.nome, ''), pf.email) into v_corretor from public.perfis pf where pf.user_id = v_pasta.criado_por_id;
    v_imob     := coalesce(v_imob, v_neg.imobiliaria);
    v_corretor := coalesce(v_corretor, v_pasta.criado_por, v_neg.corretor);
    v_cliente  := coalesce(v_pasta.comprador_nome, v_neg.cliente);
    v_valor    := coalesce(p_valor, v_neg.valor_venda);
    v_pv       := coalesce(p_pv, v_neg.pv_aprovado);
    v_codigo   := coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo);

    if p_status = 'proposta' and (v_valor is null or v_pv is null) then
      raise exception 'DADOS_PROPOSTA_OBRIGATORIOS';
    end if;
    if v_valor is not null and v_valor <= 0 then raise exception 'VALOR_INVALIDO'; end if;
    if v_pv is not null and v_pv < 0 then raise exception 'PV_INVALIDO'; end if;

    if v_neg.id is null then
      insert into public.negociacoes (unidade_id, pasta_id, imobiliaria, corretor, cliente, valor_venda, pv_aprovado, criado_por)
      values (p_unidade_id, v_pasta.id, v_imob, v_corretor, v_cliente, v_valor, v_pv, v_email);
    else
      update public.negociacoes
         set pasta_id = v_pasta.id, imobiliaria = v_imob, corretor = v_corretor, cliente = v_cliente,
             valor_venda = v_valor, pv_aprovado = v_pv, atualizada_em = now()
       where id = v_neg.id;
    end if;

    -- funil acompanha o espelho
    v_etapa := case p_status when 'reservada' then 'reserva' when 'proposta' then 'contrato_confeccao'
                             when 'contrato' then 'enviado_assinatura' else 'assinado' end;
    v_rotulo := case v_etapa when 'reserva' then 'Reserva' when 'contrato_confeccao' then 'Contrato em confecção'
                             when 'enviado_assinatura' then 'Enviado para assinatura' else 'Assinado / Vendido' end;
    if v_pasta.unidade_id is null then
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (v_pasta.id, 'Unidade vinculada', jsonb_build_object('unidade', v_unidade.numero), v_email);
    end if;
    update public.pastas set etapa_venda = v_etapa, etapa_atualizada_em = now(), unidade_id = p_unidade_id
     where id = v_pasta.id;
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (v_pasta.id, 'Etapa da venda alterada',
            jsonb_build_object('documento', v_rotulo || ' (pelo espelho)', 'unidade', v_unidade.numero), v_email);

    v_detalhes := jsonb_strip_nulls(jsonb_build_object(
      'pasta', v_codigo, 'cliente', v_cliente, 'imobiliaria', v_imob, 'corretor', v_corretor,
      'valor_venda', p_valor, 'pv_aprovado', p_pv));
  end if;

  update public.unidades
     set status = p_status, versao = versao + 1, atualizado_em = now()
   where id = p_unidade_id
  returning * into v_unidade;

  insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
  values (v_unidade.id, v_unidade.numero, v_anterior, p_status, v_motivo, auth.uid(), v_email, v_detalhes);

  return v_unidade;
end;
$$;
revoke all on function public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric, uuid) from public, anon;
grant execute on function public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric, uuid) to authenticated;

-- O vínculo manual entre pasta e unidade deixa de existir: a unidade é ligada à pasta
-- pela reserva no espelho ou pelo funil de vendas, sempre com a negociação junto.
create or replace function public.vincular_unidade(p_pasta uuid, p_unidade uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  raise exception 'VINCULO_PELO_ESPELHO' using hint = 'Reserve a unidade no espelho ou mova a pasta no funil de vendas.';
end;
$$;

-- >>>>> supabase/migrations/015_varias_unidades.sql
-- =====================================================================
-- 015 — Uma pasta, várias unidades
--  * Um cliente (pasta) pode comprar mais de uma unidade.
--  * Cada unidade reservada vira uma negociação própria e um card próprio no
--    funil, que anda sozinho (um contrato pode sair antes do outro).
--  * A pasta aparece em "Pasta aprovada" enquanto não tiver nenhuma unidade.
--  * A etapa de cada card vem do status da unidade no espelho.
--  * pastas.unidades_numeros guarda as unidades da pasta (ex.: "1204, 1205")
--    para listas e relatórios; pastas.unidade_id deixa de ser usado.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.pastas add column if not exists unidades_numeros text;

-- Recalcula as unidades de uma pasta a partir das negociações ativas
create or replace function public.atualizar_unidades_pasta(p_pasta uuid) returns void
language sql security definer set search_path = public as $$
  update public.pastas p
     set unidades_numeros = (
           select string_agg(u.numero, ', ' order by u.andar, u.posicao)
             from public.negociacoes n join public.unidades u on u.id = n.unidade_id
            where n.pasta_id = p.id and n.ativa),
         unidade_id = null
   where p.id = p_pasta;
$$;
revoke all on function public.atualizar_unidades_pasta(uuid) from public, anon, authenticated;

create or replace function public.negociacoes_pasta_depois() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.pasta_id is not null then
    perform public.atualizar_unidades_pasta(old.pasta_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.pasta_id is not null
     and (tg_op = 'INSERT' or new.pasta_id is distinct from old.pasta_id or new.ativa is distinct from old.ativa) then
    perform public.atualizar_unidades_pasta(new.pasta_id);
  end if;
  return null;
end;
$$;
drop trigger if exists negociacoes_pasta_depois on public.negociacoes;
create trigger negociacoes_pasta_depois after insert or update or delete on public.negociacoes
  for each row execute function public.negociacoes_pasta_depois();

-- O histórico da pasta não registra a lista de unidades como "dados alterados"
create or replace function public.pastas_depois() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_campos text[];
begin
  if tg_op = 'INSERT' then
    insert into public.historico_pastas (pasta_id, acao, usuario_email) values (new.id, 'Pasta criada', public.meu_email());
    perform public.recalcular_pasta(new.id);
  else
    select array_agg(n.key order by n.key) into v_campos
      from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value
       and n.key not in ('status', 'atualizada_em', 'unidade_id', 'codigo_aprovacao', 'submetida_em', 'submetida_por',
                         'etapa_venda', 'etapa_atualizada_em', 'unidades_numeros');
    if v_campos is not null then
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (new.id, 'Dados alterados', jsonb_build_object('campos', v_campos), public.meu_email());
    end if;
    if new.estado_civil is distinct from old.estado_civil then
      perform public.recalcular_pasta(new.id);
    end if;
  end if;
  return null;
end;
$$;

-- Preenche o que já existe
select public.atualizar_unidades_pasta(id) from public.pastas;

-- ---------------------------------------------------------------------
-- Funil: mover um card. Card sem unidade (Pasta aprovada) precisa de p_unidade
-- para avançar; card com unidade informa a unidade que está sendo movida.
-- ---------------------------------------------------------------------
drop function if exists public.mover_etapa(uuid, text, uuid);

create function public.mover_etapa(p_pasta uuid, p_etapa text, p_unidade uuid default null) returns public.pastas
language plpgsql security definer set search_path = public as $fn$
declare
  v_pasta    public.pastas;
  v_unidade  public.unidades;
  v_neg      public.negociacoes;
  v_novo     public.status_unidade;
  v_anterior public.status_unidade;
  v_email    text := public.meu_email();
  v_rotulo   text;
  v_imob     text;
  v_corretor text;
  v_codigo   text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_etapa not in ('aprovada', 'reserva', 'contrato_confeccao', 'enviado_assinatura', 'assinado') then
    raise exception 'ETAPA_INVALIDA';
  end if;
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if v_pasta.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
  if p_unidade is null then raise exception 'SEM_UNIDADE'; end if;

  v_codigo := coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo);
  v_rotulo := case p_etapa
    when 'aprovada' then 'Pasta aprovada' when 'reserva' then 'Reserva'
    when 'contrato_confeccao' then 'Contrato em confecção' when 'enviado_assinatura' then 'Enviado para assinatura'
    else 'Assinado / Vendido' end;
  v_novo := case p_etapa
    when 'aprovada' then 'disponivel' when 'reserva' then 'reservada' when 'contrato_confeccao' then 'proposta'
    when 'enviado_assinatura' then 'contrato' else 'vendida' end;

  select * into v_unidade from public.unidades where id = p_unidade for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  select * into v_neg from public.negociacoes where unidade_id = p_unidade and ativa for update;

  -- ---------- volta para "Pasta aprovada": libera esta unidade ----------
  if p_etapa = 'aprovada' then
    if v_neg.pasta_id is distinct from p_pasta then raise exception 'UNIDADE_DE_OUTRA_PASTA'; end if;
    v_anterior := v_unidade.status;
    update public.negociacoes set ativa = false, encerrada_em = now(), atualizada_em = now(),
           motivo_encerramento = 'Card voltou para "Pasta aprovada" no funil de vendas'
     where id = v_neg.id;
    update public.unidades set status = 'disponivel', versao = versao + 1, atualizado_em = now()
     where id = p_unidade returning * into v_unidade;
    insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
    values (v_unidade.id, v_unidade.numero, v_anterior, 'disponivel', 'Card voltou para "Pasta aprovada" no funil de vendas',
            auth.uid(), v_email, jsonb_build_object('pasta', v_codigo));
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (p_pasta, 'Unidade liberada', jsonb_build_object('unidade', v_unidade.numero, 'documento', 'Funil de vendas'), v_email);
    select * into v_pasta from public.pastas where id = p_pasta;
    return v_pasta;
  end if;

  -- ---------- demais etapas ----------
  if v_unidade.status = 'bloqueada'
     or (v_unidade.status <> 'disponivel' and v_neg.pasta_id is distinct from p_pasta) then
    raise exception 'UNIDADE_OCUPADA' using hint = v_unidade.numero;
  end if;

  select i.nome into v_imob from public.imobiliarias i where i.id = v_pasta.imobiliaria_id;
  select coalesce(nullif(pf.nome, ''), pf.email) into v_corretor from public.perfis pf where pf.user_id = v_pasta.criado_por_id;

  if v_neg.id is null then
    insert into public.negociacoes (unidade_id, pasta_id, imobiliaria, corretor, cliente, criado_por)
    values (p_unidade, p_pasta, v_imob, coalesce(v_corretor, v_pasta.criado_por), v_pasta.comprador_nome, v_email);
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (p_pasta, 'Unidade vinculada', jsonb_build_object('unidade', v_unidade.numero), v_email);
  else
    update public.negociacoes set atualizada_em = now() where id = v_neg.id;
  end if;

  if v_unidade.status <> v_novo then
    v_anterior := v_unidade.status;
    update public.unidades set status = v_novo, versao = versao + 1, atualizado_em = now()
     where id = p_unidade returning * into v_unidade;
    insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
    values (v_unidade.id, v_unidade.numero, v_anterior, v_novo, 'Funil de vendas: ' || v_rotulo, auth.uid(), v_email,
            jsonb_build_object('pasta', v_codigo, 'cliente', v_pasta.comprador_nome));
  end if;

  update public.pastas set etapa_atualizada_em = now() where id = p_pasta;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Etapa da venda alterada', jsonb_build_object('documento', v_rotulo, 'unidade', v_unidade.numero), v_email);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$fn$;
revoke all on function public.mover_etapa(uuid, text, uuid) from public, anon;
grant execute on function public.mover_etapa(uuid, text, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Espelho: a mesma pasta pode reservar outras unidades
-- ---------------------------------------------------------------------
create or replace function public.alterar_status(
  p_unidade_id  uuid,
  p_status      public.status_unidade,
  p_versao      int,
  p_motivo      text    default null,
  p_imobiliaria text    default null,
  p_corretor    text    default null,
  p_cliente     text    default null,
  p_valor       numeric default null,
  p_pv          numeric default null,
  p_pasta       uuid    default null
) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  v_unidade  public.unidades;
  v_neg      public.negociacoes;
  v_pasta    public.pastas;
  v_email    text;
  v_anterior public.status_unidade;
  v_motivo   text := nullif(trim(coalesce(p_motivo, '')), '');
  v_imob     text;
  v_corretor text;
  v_cliente  text;
  v_valor    numeric;
  v_pv       numeric;
  v_detalhes jsonb;
  v_rotulo   text;
  v_codigo   text;
begin
  if not public.eh_equipe() then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;

  select * into v_unidade from public.unidades where id = p_unidade_id for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  if v_unidade.versao <> p_versao then
    raise exception 'CONFLITO' using hint = 'A unidade foi alterada por outra pessoa. Recarregue.';
  end if;
  if v_unidade.status = p_status then return v_unidade; end if;

  v_anterior := v_unidade.status;
  select email into v_email from public.perfis where user_id = auth.uid();
  select * into v_neg from public.negociacoes where unidade_id = p_unidade_id and ativa for update;

  if p_status in ('disponivel', 'bloqueada') then
    if v_anterior not in ('disponivel', 'bloqueada') and v_motivo is null then
      raise exception 'MOTIVO_OBRIGATORIO';
    end if;
    if v_neg.id is not null then
      update public.negociacoes
         set ativa = false, encerrada_em = now(), motivo_encerramento = v_motivo, atualizada_em = now()
       where id = v_neg.id;
      if v_neg.pasta_id is not null then
        update public.pastas set etapa_atualizada_em = now() where id = v_neg.pasta_id;
        insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
        values (v_neg.pasta_id, 'Unidade liberada no espelho',
                jsonb_strip_nulls(jsonb_build_object('unidade', v_unidade.numero, 'motivo', v_motivo)), v_email);
      end if;
    end if;
    v_detalhes := null;
  else
    if v_neg.pasta_id is not null then
      if p_pasta is not null and p_pasta <> v_neg.pasta_id then
        raise exception 'UNIDADE_COM_OUTRA_PASTA';
      end if;
      select * into v_pasta from public.pastas where id = v_neg.pasta_id for update;
    else
      if p_pasta is null then raise exception 'PASTA_OBRIGATORIA'; end if;
      select * into v_pasta from public.pastas where id = p_pasta for update;
      if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
      if v_pasta.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
    end if;

    select i.nome into v_imob from public.imobiliarias i where i.id = v_pasta.imobiliaria_id;
    select coalesce(nullif(pf.nome, ''), pf.email) into v_corretor from public.perfis pf where pf.user_id = v_pasta.criado_por_id;
    v_imob     := coalesce(v_imob, v_neg.imobiliaria);
    v_corretor := coalesce(v_corretor, v_pasta.criado_por, v_neg.corretor);
    v_cliente  := coalesce(v_pasta.comprador_nome, v_neg.cliente);
    v_valor    := coalesce(p_valor, v_neg.valor_venda);
    v_pv       := coalesce(p_pv, v_neg.pv_aprovado);
    v_codigo   := coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo);

    if p_status = 'proposta' and (v_valor is null or v_pv is null) then
      raise exception 'DADOS_PROPOSTA_OBRIGATORIOS';
    end if;
    if v_valor is not null and v_valor <= 0 then raise exception 'VALOR_INVALIDO'; end if;
    if v_pv is not null and v_pv < 0 then raise exception 'PV_INVALIDO'; end if;

    if v_neg.id is null then
      insert into public.negociacoes (unidade_id, pasta_id, imobiliaria, corretor, cliente, valor_venda, pv_aprovado, criado_por)
      values (p_unidade_id, v_pasta.id, v_imob, v_corretor, v_cliente, v_valor, v_pv, v_email);
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (v_pasta.id, 'Unidade vinculada', jsonb_build_object('unidade', v_unidade.numero), v_email);
    else
      update public.negociacoes
         set pasta_id = v_pasta.id, imobiliaria = v_imob, corretor = v_corretor, cliente = v_cliente,
             valor_venda = v_valor, pv_aprovado = v_pv, atualizada_em = now()
       where id = v_neg.id;
    end if;

    v_rotulo := case p_status when 'reservada' then 'Reserva' when 'proposta' then 'Contrato em confecção'
                              when 'contrato' then 'Enviado para assinatura' else 'Assinado / Vendido' end;
    update public.pastas set etapa_atualizada_em = now() where id = v_pasta.id;
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (v_pasta.id, 'Etapa da venda alterada',
            jsonb_build_object('documento', v_rotulo || ' (pelo espelho)', 'unidade', v_unidade.numero), v_email);

    v_detalhes := jsonb_strip_nulls(jsonb_build_object(
      'pasta', v_codigo, 'cliente', v_cliente, 'imobiliaria', v_imob, 'corretor', v_corretor,
      'valor_venda', p_valor, 'pv_aprovado', p_pv));
  end if;

  update public.unidades
     set status = p_status, versao = versao + 1, atualizado_em = now()
   where id = p_unidade_id
  returning * into v_unidade;

  insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
  values (v_unidade.id, v_unidade.numero, v_anterior, p_status, v_motivo, auth.uid(), v_email, v_detalhes);

  return v_unidade;
end;
$$;
revoke all on function public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric, uuid) from public, anon;
grant execute on function public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric, uuid) to authenticated;

-- >>>>> supabase/migrations/016_permutante.sql
-- =====================================================================
-- 016 — Novo status de unidade: Permutante
--  Funciona como "Bloqueada": a unidade fica fora da venda, não entra em
--  negociação e não pode ser reservada nem movida pelo funil.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter type public.status_unidade add value if not exists 'permutante';

create or replace function public.mover_etapa(p_pasta uuid, p_etapa text, p_unidade uuid default null) returns public.pastas
language plpgsql security definer set search_path = public as $fn$
declare
  v_pasta    public.pastas;
  v_unidade  public.unidades;
  v_neg      public.negociacoes;
  v_novo     public.status_unidade;
  v_anterior public.status_unidade;
  v_email    text := public.meu_email();
  v_rotulo   text;
  v_imob     text;
  v_corretor text;
  v_codigo   text;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_etapa not in ('aprovada', 'reserva', 'contrato_confeccao', 'enviado_assinatura', 'assinado') then
    raise exception 'ETAPA_INVALIDA';
  end if;
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if v_pasta.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
  if p_unidade is null then raise exception 'SEM_UNIDADE'; end if;

  v_codigo := coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo);
  v_rotulo := case p_etapa
    when 'aprovada' then 'Pasta aprovada' when 'reserva' then 'Reserva'
    when 'contrato_confeccao' then 'Contrato em confecção' when 'enviado_assinatura' then 'Enviado para assinatura'
    else 'Assinado / Vendido' end;
  v_novo := case p_etapa
    when 'aprovada' then 'disponivel' when 'reserva' then 'reservada' when 'contrato_confeccao' then 'proposta'
    when 'enviado_assinatura' then 'contrato' else 'vendida' end;

  select * into v_unidade from public.unidades where id = p_unidade for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  select * into v_neg from public.negociacoes where unidade_id = p_unidade and ativa for update;

  -- ---------- volta para "Pasta aprovada": libera esta unidade ----------
  if p_etapa = 'aprovada' then
    if v_neg.pasta_id is distinct from p_pasta then raise exception 'UNIDADE_DE_OUTRA_PASTA'; end if;
    v_anterior := v_unidade.status;
    update public.negociacoes set ativa = false, encerrada_em = now(), atualizada_em = now(),
           motivo_encerramento = 'Card voltou para "Pasta aprovada" no funil de vendas'
     where id = v_neg.id;
    update public.unidades set status = 'disponivel', versao = versao + 1, atualizado_em = now()
     where id = p_unidade returning * into v_unidade;
    insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
    values (v_unidade.id, v_unidade.numero, v_anterior, 'disponivel', 'Card voltou para "Pasta aprovada" no funil de vendas',
            auth.uid(), v_email, jsonb_build_object('pasta', v_codigo));
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (p_pasta, 'Unidade liberada', jsonb_build_object('unidade', v_unidade.numero, 'documento', 'Funil de vendas'), v_email);
    select * into v_pasta from public.pastas where id = p_pasta;
    return v_pasta;
  end if;

  -- ---------- demais etapas ----------
  if v_unidade.status in ('bloqueada', 'permutante')
     or (v_unidade.status <> 'disponivel' and v_neg.pasta_id is distinct from p_pasta) then
    raise exception 'UNIDADE_OCUPADA' using hint = v_unidade.numero;
  end if;

  select i.nome into v_imob from public.imobiliarias i where i.id = v_pasta.imobiliaria_id;
  select coalesce(nullif(pf.nome, ''), pf.email) into v_corretor from public.perfis pf where pf.user_id = v_pasta.criado_por_id;

  if v_neg.id is null then
    insert into public.negociacoes (unidade_id, pasta_id, imobiliaria, corretor, cliente, criado_por)
    values (p_unidade, p_pasta, v_imob, coalesce(v_corretor, v_pasta.criado_por), v_pasta.comprador_nome, v_email);
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (p_pasta, 'Unidade vinculada', jsonb_build_object('unidade', v_unidade.numero), v_email);
  else
    update public.negociacoes set atualizada_em = now() where id = v_neg.id;
  end if;

  if v_unidade.status <> v_novo then
    v_anterior := v_unidade.status;
    update public.unidades set status = v_novo, versao = versao + 1, atualizado_em = now()
     where id = p_unidade returning * into v_unidade;
    insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
    values (v_unidade.id, v_unidade.numero, v_anterior, v_novo, 'Funil de vendas: ' || v_rotulo, auth.uid(), v_email,
            jsonb_build_object('pasta', v_codigo, 'cliente', v_pasta.comprador_nome));
  end if;

  update public.pastas set etapa_atualizada_em = now() where id = p_pasta;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Etapa da venda alterada', jsonb_build_object('documento', v_rotulo, 'unidade', v_unidade.numero), v_email);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$fn$;
revoke all on function public.mover_etapa(uuid, text, uuid) from public, anon;
grant execute on function public.mover_etapa(uuid, text, uuid) to authenticated;

-- Espelho: liberar para Permutante encerra a negociação, como Bloqueada
create or replace function public.alterar_status(
  p_unidade_id  uuid,
  p_status      public.status_unidade,
  p_versao      int,
  p_motivo      text    default null,
  p_imobiliaria text    default null,
  p_corretor    text    default null,
  p_cliente     text    default null,
  p_valor       numeric default null,
  p_pv          numeric default null,
  p_pasta       uuid    default null
) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  v_unidade  public.unidades;
  v_neg      public.negociacoes;
  v_pasta    public.pastas;
  v_email    text;
  v_anterior public.status_unidade;
  v_motivo   text := nullif(trim(coalesce(p_motivo, '')), '');
  v_imob     text;
  v_corretor text;
  v_cliente  text;
  v_valor    numeric;
  v_pv       numeric;
  v_detalhes jsonb;
  v_rotulo   text;
  v_codigo   text;
begin
  if not public.eh_equipe() then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;

  select * into v_unidade from public.unidades where id = p_unidade_id for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  if v_unidade.versao <> p_versao then
    raise exception 'CONFLITO' using hint = 'A unidade foi alterada por outra pessoa. Recarregue.';
  end if;
  if v_unidade.status = p_status then return v_unidade; end if;

  v_anterior := v_unidade.status;
  select email into v_email from public.perfis where user_id = auth.uid();
  select * into v_neg from public.negociacoes where unidade_id = p_unidade_id and ativa for update;

  if p_status in ('disponivel', 'bloqueada', 'permutante') then
    if v_anterior not in ('disponivel', 'bloqueada', 'permutante') and v_motivo is null then
      raise exception 'MOTIVO_OBRIGATORIO';
    end if;
    if v_neg.id is not null then
      update public.negociacoes
         set ativa = false, encerrada_em = now(), motivo_encerramento = v_motivo, atualizada_em = now()
       where id = v_neg.id;
      if v_neg.pasta_id is not null then
        update public.pastas set etapa_atualizada_em = now() where id = v_neg.pasta_id;
        insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
        values (v_neg.pasta_id, 'Unidade liberada no espelho',
                jsonb_strip_nulls(jsonb_build_object('unidade', v_unidade.numero, 'motivo', v_motivo)), v_email);
      end if;
    end if;
    v_detalhes := null;
  else
    if v_neg.pasta_id is not null then
      if p_pasta is not null and p_pasta <> v_neg.pasta_id then
        raise exception 'UNIDADE_COM_OUTRA_PASTA';
      end if;
      select * into v_pasta from public.pastas where id = v_neg.pasta_id for update;
    else
      if p_pasta is null then raise exception 'PASTA_OBRIGATORIA'; end if;
      select * into v_pasta from public.pastas where id = p_pasta for update;
      if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
      if v_pasta.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
    end if;

    select i.nome into v_imob from public.imobiliarias i where i.id = v_pasta.imobiliaria_id;
    select coalesce(nullif(pf.nome, ''), pf.email) into v_corretor from public.perfis pf where pf.user_id = v_pasta.criado_por_id;
    v_imob     := coalesce(v_imob, v_neg.imobiliaria);
    v_corretor := coalesce(v_corretor, v_pasta.criado_por, v_neg.corretor);
    v_cliente  := coalesce(v_pasta.comprador_nome, v_neg.cliente);
    v_valor    := coalesce(p_valor, v_neg.valor_venda);
    v_pv       := coalesce(p_pv, v_neg.pv_aprovado);
    v_codigo   := coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo);

    if p_status = 'proposta' and (v_valor is null or v_pv is null) then
      raise exception 'DADOS_PROPOSTA_OBRIGATORIOS';
    end if;
    if v_valor is not null and v_valor <= 0 then raise exception 'VALOR_INVALIDO'; end if;
    if v_pv is not null and v_pv < 0 then raise exception 'PV_INVALIDO'; end if;

    if v_neg.id is null then
      insert into public.negociacoes (unidade_id, pasta_id, imobiliaria, corretor, cliente, valor_venda, pv_aprovado, criado_por)
      values (p_unidade_id, v_pasta.id, v_imob, v_corretor, v_cliente, v_valor, v_pv, v_email);
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (v_pasta.id, 'Unidade vinculada', jsonb_build_object('unidade', v_unidade.numero), v_email);
    else
      update public.negociacoes
         set pasta_id = v_pasta.id, imobiliaria = v_imob, corretor = v_corretor, cliente = v_cliente,
             valor_venda = v_valor, pv_aprovado = v_pv, atualizada_em = now()
       where id = v_neg.id;
    end if;

    v_rotulo := case p_status when 'reservada' then 'Reserva' when 'proposta' then 'Contrato em confecção'
                              when 'contrato' then 'Enviado para assinatura' else 'Assinado / Vendido' end;
    update public.pastas set etapa_atualizada_em = now() where id = v_pasta.id;
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (v_pasta.id, 'Etapa da venda alterada',
            jsonb_build_object('documento', v_rotulo || ' (pelo espelho)', 'unidade', v_unidade.numero), v_email);

    v_detalhes := jsonb_strip_nulls(jsonb_build_object(
      'pasta', v_codigo, 'cliente', v_cliente, 'imobiliaria', v_imob, 'corretor', v_corretor,
      'valor_venda', p_valor, 'pv_aprovado', p_pv));
  end if;

  update public.unidades
     set status = p_status, versao = versao + 1, atualizado_em = now()
   where id = p_unidade_id
  returning * into v_unidade;

  insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
  values (v_unidade.id, v_unidade.numero, v_anterior, p_status, v_motivo, auth.uid(), v_email, v_detalhes);

  return v_unidade;
end;
$$;
revoke all on function public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric, uuid) from public, anon;
grant execute on function public.alterar_status(uuid, public.status_unidade, int, text, text, text, text, numeric, numeric, uuid) to authenticated;

-- >>>>> supabase/migrations/017_rodadas.sql
-- =====================================================================
-- 017 — Rodadas de negócios
--  * O administrador cria rodadas (nome, data, local, limite de clientes)
--    para todas as imobiliárias ou só para as escolhidas.
--  * Corretores e imobiliárias liberados confirmam clientes: nome, quantas
--    pessoas vêm e telefone. O limite conta clientes, não pessoas.
--  * Cada um vê só a sua parte: o corretor vê os clientes dele, a imobiliária
--    vê os da equipe dela, a Sec. Vendas e o administrador veem tudo.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create table public.rodadas (
  id                  uuid primary key default gen_random_uuid(),
  nome                text not null check (length(trim(nome)) >= 3),
  data_hora           timestamptz not null,
  local               text,
  observacoes         text,
  limite_clientes     int not null default 25 check (limite_clientes > 0),
  inscricoes_abertas  boolean not null default true,
  todas_imobiliarias  boolean not null default true,
  criado_por          text,
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now()
);

create table public.rodadas_imobiliarias (
  rodada_id      uuid not null references public.rodadas(id) on delete cascade,
  imobiliaria_id uuid not null references public.imobiliarias(id) on delete cascade,
  primary key (rodada_id, imobiliaria_id)
);

create table public.rodada_inscricoes (
  id              uuid primary key default gen_random_uuid(),
  rodada_id       uuid not null references public.rodadas(id) on delete cascade,
  cliente_nome    text not null check (length(trim(cliente_nome)) >= 3),
  pessoas         int not null check (pessoas between 1 and 20),
  telefone        text,
  observacao      text,
  imobiliaria_id  uuid references public.imobiliarias(id),
  corretor_id     uuid,
  corretor_nome   text,
  cancelada       boolean not null default false,
  cancelada_em    timestamptz,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);
create index rodada_inscricoes_rodada_idx on public.rodada_inscricoes (rodada_id) where not cancelada;
-- o mesmo cliente não é confirmado duas vezes na mesma rodada
create unique index rodada_inscricoes_cliente_unico
  on public.rodada_inscricoes (rodada_id, lower(regexp_replace(trim(cliente_nome), '\s+', ' ', 'g')))
  where not cancelada;

alter table public.rodadas enable row level security;
alter table public.rodadas_imobiliarias enable row level security;
alter table public.rodada_inscricoes enable row level security;

-- A rodada está liberada para quem está logado?
create or replace function public.rodada_liberada(p_rodada uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe() or exists (
    select 1 from public.rodadas r
     where r.id = p_rodada
       and public.minha_imobiliaria() is not null
       and (r.todas_imobiliarias
            or exists (select 1 from public.rodadas_imobiliarias ri
                        where ri.rodada_id = r.id and ri.imobiliaria_id = public.minha_imobiliaria())));
$$;

create policy rodadas_leitura on public.rodadas for select using (public.rodada_liberada(id));
create policy rodadas_imobs_leitura on public.rodadas_imobiliarias for select using (public.eh_equipe());
create policy inscricoes_leitura on public.rodada_inscricoes for select using (
  public.eh_equipe()
  or (imobiliaria_id = public.minha_imobiliaria() and (public.eh_gestor() or corretor_id = auth.uid()))
);
-- escrita só pelas funções abaixo

-- ---------------------------------------------------------------------
-- Administrador: criar ou editar rodada
-- ---------------------------------------------------------------------
create or replace function public.salvar_rodada(
  p_id uuid, p_nome text, p_data_hora timestamptz, p_local text, p_observacoes text,
  p_limite int, p_abertas boolean, p_todas boolean, p_imobiliarias uuid[]
) returns public.rodadas
language plpgsql security definer set search_path = public as $$
declare v public.rodadas; v_ocupadas int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if p_data_hora is null then raise exception 'DATA_OBRIGATORIA'; end if;
  if p_limite is null or p_limite < 1 then raise exception 'LIMITE_INVALIDO'; end if;
  if not p_todas and coalesce(array_length(p_imobiliarias, 1), 0) = 0 then raise exception 'IMOBILIARIAS_OBRIGATORIAS'; end if;

  if p_id is null then
    insert into public.rodadas (nome, data_hora, local, observacoes, limite_clientes, inscricoes_abertas, todas_imobiliarias, criado_por)
    values (trim(p_nome), p_data_hora, nullif(trim(p_local), ''), nullif(trim(p_observacoes), ''), p_limite, p_abertas, p_todas, public.meu_email())
    returning * into v;
  else
    select count(*) into v_ocupadas from public.rodada_inscricoes where rodada_id = p_id and not cancelada;
    if p_limite < v_ocupadas then raise exception 'LIMITE_ABAIXO_DOS_CONFIRMADOS' using hint = v_ocupadas::text; end if;
    update public.rodadas
       set nome = trim(p_nome), data_hora = p_data_hora, local = nullif(trim(p_local), ''),
           observacoes = nullif(trim(p_observacoes), ''), limite_clientes = p_limite,
           inscricoes_abertas = p_abertas, todas_imobiliarias = p_todas, atualizado_em = now()
     where id = p_id returning * into v;
    if not found then raise exception 'RODADA_NAO_ENCONTRADA'; end if;
  end if;

  delete from public.rodadas_imobiliarias where rodada_id = v.id;
  if not p_todas then
    insert into public.rodadas_imobiliarias (rodada_id, imobiliaria_id)
    select v.id, unnest(p_imobiliarias) on conflict do nothing;
  end if;
  return v;
end;
$$;

create or replace function public.excluir_rodada(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  delete from public.rodadas where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Vagas de cada rodada visível (o corretor não lê as inscrições dos outros)
-- ---------------------------------------------------------------------
create or replace function public.rodadas_vagas() returns table (rodada_id uuid, clientes int, pessoas int)
language sql stable security definer set search_path = public as $$
  select r.id, count(i.id)::int, coalesce(sum(i.pessoas), 0)::int
    from public.rodadas r
    left join public.rodada_inscricoes i on i.rodada_id = r.id and not i.cancelada
   where public.rodada_liberada(r.id)
   group by r.id;
$$;

-- ---------------------------------------------------------------------
-- Confirmar cliente (corretor, imobiliária ou equipe)
-- ---------------------------------------------------------------------
create or replace function public.confirmar_cliente_rodada(
  p_rodada uuid, p_cliente text, p_pessoas int, p_telefone text default null, p_observacao text default null,
  p_imobiliaria uuid default null
) returns public.rodada_inscricoes
language plpgsql security definer set search_path = public as $$
declare
  v_rodada public.rodadas;
  v_imob   uuid;
  v_nome   text;
  v_ocup   int;
  v        public.rodada_inscricoes;
begin
  select * into v_rodada from public.rodadas where id = p_rodada for update;   -- trava a rodada: o limite não estoura
  if not found or not public.rodada_liberada(p_rodada) then raise exception 'RODADA_NAO_ENCONTRADA'; end if;
  if not public.eh_equipe() and not v_rodada.inscricoes_abertas then raise exception 'INSCRICOES_ENCERRADAS'; end if;
  if not public.eh_equipe() and v_rodada.data_hora < now() then raise exception 'RODADA_JA_ACONTECEU'; end if;
  if coalesce(length(trim(p_cliente)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if p_pessoas is null or p_pessoas < 1 or p_pessoas > 20 then raise exception 'PESSOAS_INVALIDO'; end if;

  select count(*) into v_ocup from public.rodada_inscricoes where rodada_id = p_rodada and not cancelada;
  if v_ocup >= v_rodada.limite_clientes then raise exception 'RODADA_LOTADA'; end if;

  v_imob := case when public.eh_equipe() then p_imobiliaria else public.minha_imobiliaria() end;
  select coalesce(nullif(nome, ''), email) into v_nome from public.perfis where user_id = auth.uid();

  begin
    insert into public.rodada_inscricoes (rodada_id, cliente_nome, pessoas, telefone, observacao, imobiliaria_id, corretor_id, corretor_nome)
    values (p_rodada, regexp_replace(trim(p_cliente), '\s+', ' ', 'g'), p_pessoas, nullif(trim(p_telefone), ''),
            nullif(trim(p_observacao), ''), v_imob, auth.uid(), v_nome)
    returning * into v;
  exception when unique_violation then
    raise exception 'CLIENTE_JA_CONFIRMADO';
  end;
  return v;
end;
$$;

-- Quem pode mexer numa confirmação: equipe, a imobiliária dona ou o corretor que confirmou
create or replace function public.pode_alterar_inscricao(p public.rodada_inscricoes) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe()
      or (p.imobiliaria_id = public.minha_imobiliaria() and (public.eh_gestor() or p.corretor_id = auth.uid()));
$$;

create or replace function public.editar_cliente_rodada(
  p_id uuid, p_cliente text, p_pessoas int, p_telefone text default null, p_observacao text default null
) returns public.rodada_inscricoes
language plpgsql security definer set search_path = public as $$
declare v public.rodada_inscricoes; v_rodada public.rodadas;
begin
  select * into v from public.rodada_inscricoes where id = p_id for update;
  if not found or v.cancelada or not public.pode_alterar_inscricao(v) then raise exception 'INSCRICAO_NAO_ENCONTRADA'; end if;
  select * into v_rodada from public.rodadas where id = v.rodada_id;
  if not public.eh_equipe() and (not v_rodada.inscricoes_abertas or v_rodada.data_hora < now()) then
    raise exception 'INSCRICOES_ENCERRADAS';
  end if;
  if coalesce(length(trim(p_cliente)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if p_pessoas is null or p_pessoas < 1 or p_pessoas > 20 then raise exception 'PESSOAS_INVALIDO'; end if;
  begin
    update public.rodada_inscricoes
       set cliente_nome = regexp_replace(trim(p_cliente), '\s+', ' ', 'g'), pessoas = p_pessoas,
           telefone = nullif(trim(p_telefone), ''), observacao = nullif(trim(p_observacao), ''), atualizado_em = now()
     where id = p_id returning * into v;
  exception when unique_violation then
    raise exception 'CLIENTE_JA_CONFIRMADO';
  end;
  return v;
end;
$$;

create or replace function public.cancelar_cliente_rodada(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v public.rodada_inscricoes;
begin
  select * into v from public.rodada_inscricoes where id = p_id for update;
  if not found or v.cancelada or not public.pode_alterar_inscricao(v) then raise exception 'INSCRICAO_NAO_ENCONTRADA'; end if;
  update public.rodada_inscricoes set cancelada = true, cancelada_em = now(), atualizado_em = now() where id = p_id;
end;
$$;

revoke all on function public.salvar_rodada(uuid, text, timestamptz, text, text, int, boolean, boolean, uuid[]) from public, anon;
revoke all on function public.excluir_rodada(uuid) from public, anon;
revoke all on function public.rodadas_vagas() from public, anon;
revoke all on function public.confirmar_cliente_rodada(uuid, text, int, text, text, uuid) from public, anon;
revoke all on function public.editar_cliente_rodada(uuid, text, int, text, text) from public, anon;
revoke all on function public.cancelar_cliente_rodada(uuid) from public, anon;
grant execute on function public.salvar_rodada(uuid, text, timestamptz, text, text, int, boolean, boolean, uuid[]) to authenticated;
grant execute on function public.excluir_rodada(uuid) to authenticated;
grant execute on function public.rodadas_vagas() to authenticated;
grant execute on function public.confirmar_cliente_rodada(uuid, text, int, text, text, uuid) to authenticated;
grant execute on function public.editar_cliente_rodada(uuid, text, int, text, text) to authenticated;
grant execute on function public.cancelar_cliente_rodada(uuid) to authenticated;
grant select on public.rodadas, public.rodadas_imobiliarias, public.rodada_inscricoes to authenticated;

-- Lista de confirmados atualiza sozinha na tela
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.rodada_inscricoes;
  end if;
end $$;

-- >>>>> supabase/migrations/018_rodadas_convidados.sql
-- =====================================================================
-- 018 — Rodadas: nome completo de cada convidado
--  * O corretor informa quantas pessoas vêm e o nome completo de cada uma.
--    O primeiro nome é o do cliente; os demais são acompanhantes.
--  * Só quem confirmou (o corretor) edita ou cancela. A imobiliária vê os
--    convidados dos seus corretores; Sec. Vendas e administrador veem e
--    alteram tudo.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.rodada_inscricoes add column if not exists convidados text[];
update public.rodada_inscricoes set convidados = array[cliente_nome] where convidados is null;

-- Limpa e confere a lista de nomes
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
  if coalesce(array_length(v, 1), 0) < 1 or array_length(v, 1) > 20 then raise exception 'PESSOAS_INVALIDO'; end if;
  return v;
end;
$$;

create or replace function public.pode_alterar_inscricao(p public.rodada_inscricoes) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe() or p.corretor_id = auth.uid();
$$;

drop function if exists public.confirmar_cliente_rodada(uuid, text, int, text, text, uuid);
drop function if exists public.editar_cliente_rodada(uuid, text, int, text, text);

create function public.confirmar_cliente_rodada(
  p_rodada uuid, p_convidados text[], p_telefone text default null, p_observacao text default null,
  p_imobiliaria uuid default null
) returns public.rodada_inscricoes
language plpgsql security definer set search_path = public as $$
declare
  v_rodada public.rodadas;
  v_lista  text[] := public.normalizar_convidados(p_convidados);
  v_imob   uuid;
  v_nome   text;
  v_ocup   int;
  v        public.rodada_inscricoes;
begin
  select * into v_rodada from public.rodadas where id = p_rodada for update;
  if not found or not public.rodada_liberada(p_rodada) then raise exception 'RODADA_NAO_ENCONTRADA'; end if;
  if not public.eh_equipe() and not v_rodada.inscricoes_abertas then raise exception 'INSCRICOES_ENCERRADAS'; end if;
  if not public.eh_equipe() and v_rodada.data_hora < now() then raise exception 'RODADA_JA_ACONTECEU'; end if;

  select count(*) into v_ocup from public.rodada_inscricoes where rodada_id = p_rodada and not cancelada;
  if v_ocup >= v_rodada.limite_clientes then raise exception 'RODADA_LOTADA'; end if;

  v_imob := case when public.eh_equipe() then p_imobiliaria else public.minha_imobiliaria() end;
  select coalesce(nullif(nome, ''), email) into v_nome from public.perfis where user_id = auth.uid();

  begin
    insert into public.rodada_inscricoes (rodada_id, cliente_nome, pessoas, convidados, telefone, observacao, imobiliaria_id, corretor_id, corretor_nome)
    values (p_rodada, v_lista[1], array_length(v_lista, 1), v_lista, nullif(trim(p_telefone), ''),
            nullif(trim(p_observacao), ''), v_imob, auth.uid(), v_nome)
    returning * into v;
  exception when unique_violation then
    raise exception 'CLIENTE_JA_CONFIRMADO';
  end;
  return v;
end;
$$;

create function public.editar_cliente_rodada(
  p_id uuid, p_convidados text[], p_telefone text default null, p_observacao text default null
) returns public.rodada_inscricoes
language plpgsql security definer set search_path = public as $$
declare v public.rodada_inscricoes; v_rodada public.rodadas; v_lista text[] := public.normalizar_convidados(p_convidados);
begin
  select * into v from public.rodada_inscricoes where id = p_id for update;
  if not found or v.cancelada or not public.pode_alterar_inscricao(v) then raise exception 'INSCRICAO_NAO_ENCONTRADA'; end if;
  select * into v_rodada from public.rodadas where id = v.rodada_id;
  if not public.eh_equipe() and (not v_rodada.inscricoes_abertas or v_rodada.data_hora < now()) then
    raise exception 'INSCRICOES_ENCERRADAS';
  end if;
  begin
    update public.rodada_inscricoes
       set cliente_nome = v_lista[1], pessoas = array_length(v_lista, 1), convidados = v_lista,
           telefone = nullif(trim(p_telefone), ''), observacao = nullif(trim(p_observacao), ''), atualizado_em = now()
     where id = p_id returning * into v;
  exception when unique_violation then
    raise exception 'CLIENTE_JA_CONFIRMADO';
  end;
  return v;
end;
$$;

revoke all on function public.confirmar_cliente_rodada(uuid, text[], text, text, uuid) from public, anon;
revoke all on function public.editar_cliente_rodada(uuid, text[], text, text) from public, anon;
grant execute on function public.confirmar_cliente_rodada(uuid, text[], text, text, uuid) to authenticated;
grant execute on function public.editar_cliente_rodada(uuid, text[], text, text) to authenticated;

-- >>>>> supabase/migrations/019_rodadas_limite_3.sql
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

-- >>>>> supabase/migrations/020_recepcao.sql
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

-- >>>>> supabase/migrations/021_portal_corretor.sql
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

-- >>>>> supabase/migrations/022_cadastro_imobiliaria.sql
-- =====================================================================
-- 022 — Cadastro de imobiliárias pelo link público
--  * O dono da imobiliária preenche o cadastro em /cadastro e cria a
--    própria senha. O login nasce sem acesso a nada.
--  * O administrador aprova (cria a imobiliária e libera o login master)
--    ou recusa, com motivo.
--  * A criação do login é feita pelo servidor (Cloudflare), com a chave
--    secreta; a senha escolhida nunca é guardada pelo sistema.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create table public.solicitacoes_imobiliaria (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null unique references auth.users (id) on delete cascade,
  imobiliaria_nome  text not null check (length(trim(imobiliaria_nome)) >= 2),
  cnpj              text,
  creci             text,
  cidade            text,
  responsavel       text not null check (length(trim(responsavel)) >= 3),
  email             text not null,
  telefone          text not null,
  status            text not null default 'pendente' check (status in ('pendente', 'aprovada', 'recusada')),
  motivo            text,
  imobiliaria_id    uuid references public.imobiliarias (id),
  ip                text,
  criada_em         timestamptz not null default now(),
  analisada_em      timestamptz,
  analisada_por     text
);
create index solicitacoes_imobiliaria_status_idx on public.solicitacoes_imobiliaria (status, criada_em);

alter table public.solicitacoes_imobiliaria enable row level security;
-- o administrador vê todas; quem se cadastrou vê só a própria (para saber se foi aprovada)
create policy solicitacoes_leitura on public.solicitacoes_imobiliaria for select
  using (public.eh_admin() or user_id = auth.uid());
grant select on public.solicitacoes_imobiliaria to authenticated;
-- escrita: o servidor (chave secreta) e as funções abaixo

-- ---------------------------------------------------------------------
-- Aprovar: cria a imobiliária (ou usa uma existente) e libera o login master
-- ---------------------------------------------------------------------
create or replace function public.aprovar_solicitacao(
  p_id uuid, p_nome_imobiliaria text default null, p_imobiliaria_existente uuid default null
) returns public.solicitacoes_imobiliaria
language plpgsql security definer set search_path = public as $$
declare v public.solicitacoes_imobiliaria; v_imob uuid; v_nome text;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into v from public.solicitacoes_imobiliaria where id = p_id for update;
  if not found then raise exception 'SOLICITACAO_NAO_ENCONTRADA'; end if;
  if v.status <> 'pendente' then raise exception 'SOLICITACAO_JA_ANALISADA'; end if;
  if exists (select 1 from public.perfis where user_id = v.user_id) then raise exception 'JA_TEM_ACESSO'; end if;

  if p_imobiliaria_existente is not null then
    select id into v_imob from public.imobiliarias where id = p_imobiliaria_existente;
    if not found then raise exception 'IMOBILIARIA_NAO_ENCONTRADA'; end if;
    update public.imobiliarias set ativa = true where id = v_imob;
  else
    v_nome := regexp_replace(trim(coalesce(nullif(trim(p_nome_imobiliaria), ''), v.imobiliaria_nome)), '\s+', ' ', 'g');
    if exists (select 1 from public.imobiliarias where lower(nome) = lower(v_nome)) then raise exception 'NOME_EM_USO'; end if;
    insert into public.imobiliarias (nome) values (v_nome) returning id into v_imob;
  end if;

  insert into public.perfis (user_id, email, nome, papel, imobiliaria_id, trocar_senha)
  values (v.user_id, v.email, v.responsavel, 'imobiliaria', v_imob, false);

  update public.solicitacoes_imobiliaria
     set status = 'aprovada', imobiliaria_id = v_imob, analisada_em = now(), analisada_por = public.meu_email(), motivo = null
   where id = p_id returning * into v;
  return v;
end;
$$;

create or replace function public.recusar_solicitacao(p_id uuid, p_motivo text) returns public.solicitacoes_imobiliaria
language plpgsql security definer set search_path = public as $$
declare v public.solicitacoes_imobiliaria;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_motivo)), 0) < 3 then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  update public.solicitacoes_imobiliaria
     set status = 'recusada', motivo = trim(p_motivo), analisada_em = now(), analisada_por = public.meu_email()
   where id = p_id and status = 'pendente' returning * into v;
  if not found then raise exception 'SOLICITACAO_JA_ANALISADA'; end if;
  return v;
end;
$$;

revoke all on function public.aprovar_solicitacao(uuid, text, uuid) from public, anon;
revoke all on function public.recusar_solicitacao(uuid, text) from public, anon;
grant execute on function public.aprovar_solicitacao(uuid, text, uuid) to authenticated;
grant execute on function public.recusar_solicitacao(uuid, text) to authenticated;

-- >>>>> supabase/migrations/023_dados_intermediacao.sql
-- =====================================================================
-- 023 — Dados de intermediação obrigatórios
--  * Imobiliária: CNPJ e CRECI PJ.
--  * Login da imobiliária (responsável) e corretor: nome completo, CPF,
--    CRECI PF e e-mail. O corretor usa o CNPJ e o CRECI PJ da imobiliária.
--  * Quem já tem login e está sem esses dados preenche no próximo acesso.
--  * Base para o contrato de intermediação gerado pela ferramenta no futuro.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- ---------- validação de CPF e CNPJ (dígitos verificadores)
create or replace function public.cpf_valido(p text) returns boolean
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g'); s int; r int; i int;
begin
  if length(d) <> 11 or d ~ '^(\d)\1{10}$' then return false; end if;
  s := 0; for i in 1..9 loop s := s + substr(d, i, 1)::int * (11 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  if r <> substr(d, 10, 1)::int then return false; end if;
  s := 0; for i in 1..10 loop s := s + substr(d, i, 1)::int * (12 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  return r = substr(d, 11, 1)::int;
end;
$$;

create or replace function public.cnpj_valido(p text) returns boolean
language plpgsql immutable as $$
declare
  d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  p1 int[] := array[5,4,3,2,9,8,7,6,5,4,3,2];
  p2 int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2];
  s int; r int; i int;
begin
  if length(d) <> 14 or d ~ '^(\d)\1{13}$' then return false; end if;
  s := 0; for i in 1..12 loop s := s + substr(d, i, 1)::int * p1[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  if r <> substr(d, 13, 1)::int then return false; end if;
  s := 0; for i in 1..13 loop s := s + substr(d, i, 1)::int * p2[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  return r = substr(d, 14, 1)::int;
end;
$$;

-- ---------- novas colunas (antigas ficam vazias até serem completadas)
alter table public.imobiliarias add column if not exists cnpj text check (cnpj is null or public.cnpj_valido(cnpj));
alter table public.imobiliarias add column if not exists creci_pj text;
create unique index if not exists imobiliarias_cnpj_unico on public.imobiliarias (cnpj) where cnpj is not null;

alter table public.perfis add column if not exists cpf text check (cpf is null or public.cpf_valido(cpf));
alter table public.perfis add column if not exists creci text;

alter table public.solicitacoes_imobiliaria add column if not exists responsavel_cpf text;
alter table public.solicitacoes_imobiliaria add column if not exists responsavel_creci text;

-- normaliza o CRECI: maiúsculas, sem espaços duplicados
create or replace function public.normalizar_creci(p text) returns text
language sql immutable as $$ select nullif(upper(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g')), '') $$;

-- ---------- o próprio usuário completa o cadastro (imobiliária ou corretor)
create or replace function public.completar_cadastro(
  p_nome text, p_cpf text, p_creci text, p_cnpj text default null, p_creci_pj text default null
) returns public.perfis
language plpgsql security definer set search_path = public as $$
declare v public.perfis; v_nome text := regexp_replace(trim(coalesce(p_nome, '')), '\s+', ' ', 'g');
  v_cnpj text := nullif(regexp_replace(coalesce(p_cnpj, ''), '\D', '', 'g'), '');
begin
  select * into v from public.perfis where user_id = auth.uid() for update;
  if not found or v.papel not in ('imobiliaria', 'corretor') then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if position(' ' in v_nome) = 0 then raise exception 'NOME_COMPLETO_OBRIGATORIO'; end if;
  if not public.cpf_valido(p_cpf) then raise exception 'CPF_INVALIDO'; end if;
  if public.normalizar_creci(p_creci) is null then raise exception 'CRECI_OBRIGATORIO'; end if;

  if v.papel = 'imobiliaria' then
    if not public.cnpj_valido(v_cnpj) then raise exception 'CNPJ_INVALIDO'; end if;
    if public.normalizar_creci(p_creci_pj) is null then raise exception 'CRECI_PJ_OBRIGATORIO'; end if;
    if exists (select 1 from public.imobiliarias where cnpj = v_cnpj and id <> v.imobiliaria_id) then raise exception 'CNPJ_EM_USO'; end if;
    update public.imobiliarias set cnpj = v_cnpj, creci_pj = public.normalizar_creci(p_creci_pj) where id = v.imobiliaria_id;
  end if;

  update public.perfis
     set nome = v_nome, cpf = regexp_replace(p_cpf, '\D', '', 'g'), creci = public.normalizar_creci(p_creci)
   where user_id = auth.uid() returning * into v;
  return v;
end;
$$;

-- ---------- administrador corrige os dados de uma imobiliária
create or replace function public.salvar_dados_imobiliaria(p_id uuid, p_nome text, p_cnpj text, p_creci_pj text)
returns public.imobiliarias
language plpgsql security definer set search_path = public as $$
declare v public.imobiliarias; v_cnpj text := regexp_replace(coalesce(p_cnpj, ''), '\D', '', 'g');
  v_nome text := regexp_replace(trim(coalesce(p_nome, '')), '\s+', ' ', 'g');
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if length(v_nome) < 2 then raise exception 'NOME_OBRIGATORIO'; end if;
  if not public.cnpj_valido(v_cnpj) then raise exception 'CNPJ_INVALIDO'; end if;
  if public.normalizar_creci(p_creci_pj) is null then raise exception 'CRECI_PJ_OBRIGATORIO'; end if;
  if exists (select 1 from public.imobiliarias where lower(nome) = lower(v_nome) and id is distinct from p_id) then raise exception 'NOME_EM_USO'; end if;
  if exists (select 1 from public.imobiliarias where cnpj = v_cnpj and id is distinct from p_id) then raise exception 'CNPJ_EM_USO'; end if;
  if p_id is null then
    insert into public.imobiliarias (nome, cnpj, creci_pj) values (v_nome, v_cnpj, public.normalizar_creci(p_creci_pj)) returning * into v;
  else
    update public.imobiliarias set nome = v_nome, cnpj = v_cnpj, creci_pj = public.normalizar_creci(p_creci_pj)
     where id = p_id returning * into v;
    if not found then raise exception 'IMOBILIARIA_NAO_ENCONTRADA'; end if;
  end if;
  return v;
end;
$$;

-- ---------- administrador (qualquer login) ou imobiliária (seus corretores) corrige nome, CPF e CRECI
create or replace function public.salvar_dados_login(p_user uuid, p_nome text, p_cpf text, p_creci text) returns public.perfis
language plpgsql security definer set search_path = public as $$
declare v public.perfis; v_nome text := regexp_replace(trim(coalesce(p_nome, '')), '\s+', ' ', 'g');
begin
  select * into v from public.perfis where user_id = p_user for update;
  if not found then raise exception 'LOGIN_NAO_ENCONTRADO'; end if;
  if not (public.eh_admin()
          or (public.eh_gestor() and v.papel = 'corretor' and v.imobiliaria_id = public.minha_imobiliaria())) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v.papel in ('imobiliaria', 'corretor') then
    if position(' ' in v_nome) = 0 then raise exception 'NOME_COMPLETO_OBRIGATORIO'; end if;
    if not public.cpf_valido(p_cpf) then raise exception 'CPF_INVALIDO'; end if;
    if public.normalizar_creci(p_creci) is null then raise exception 'CRECI_OBRIGATORIO'; end if;
  end if;
  update public.perfis
     set nome = nullif(v_nome, ''), cpf = nullif(regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g'), ''), creci = public.normalizar_creci(p_creci)
   where user_id = p_user returning * into v;
  return v;
end;
$$;

-- ---------- aprovação do cadastro público passa a levar CPF, CRECI, CNPJ e CRECI PJ
create or replace function public.aprovar_solicitacao(
  p_id uuid, p_nome_imobiliaria text default null, p_imobiliaria_existente uuid default null
) returns public.solicitacoes_imobiliaria
language plpgsql security definer set search_path = public as $$
declare v public.solicitacoes_imobiliaria; v_imob uuid; v_nome text;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into v from public.solicitacoes_imobiliaria where id = p_id for update;
  if not found then raise exception 'SOLICITACAO_NAO_ENCONTRADA'; end if;
  if v.status <> 'pendente' then raise exception 'SOLICITACAO_JA_ANALISADA'; end if;
  if exists (select 1 from public.perfis where user_id = v.user_id) then raise exception 'JA_TEM_ACESSO'; end if;

  if p_imobiliaria_existente is not null then
    select id into v_imob from public.imobiliarias where id = p_imobiliaria_existente;
    if not found then raise exception 'IMOBILIARIA_NAO_ENCONTRADA'; end if;
    update public.imobiliarias
       set ativa = true,
           cnpj = coalesce(cnpj, case when public.cnpj_valido(v.cnpj) and not exists (select 1 from public.imobiliarias o where o.cnpj = v.cnpj) then v.cnpj end),
           creci_pj = coalesce(creci_pj, public.normalizar_creci(v.creci))
     where id = v_imob;
  else
    v_nome := regexp_replace(trim(coalesce(nullif(trim(p_nome_imobiliaria), ''), v.imobiliaria_nome)), '\s+', ' ', 'g');
    if exists (select 1 from public.imobiliarias where lower(nome) = lower(v_nome)) then raise exception 'NOME_EM_USO'; end if;
    if v.cnpj is not null and exists (select 1 from public.imobiliarias where cnpj = v.cnpj) then raise exception 'CNPJ_EM_USO'; end if;
    insert into public.imobiliarias (nome, cnpj, creci_pj)
    values (v_nome, case when public.cnpj_valido(v.cnpj) then v.cnpj end, public.normalizar_creci(v.creci))
    returning id into v_imob;
  end if;

  insert into public.perfis (user_id, email, nome, papel, imobiliaria_id, trocar_senha, cpf, creci)
  values (v.user_id, v.email, v.responsavel, 'imobiliaria', v_imob, false,
          case when public.cpf_valido(v.responsavel_cpf) then v.responsavel_cpf end, public.normalizar_creci(v.responsavel_creci));

  update public.solicitacoes_imobiliaria
     set status = 'aprovada', imobiliaria_id = v_imob, analisada_em = now(), analisada_por = public.meu_email(), motivo = null
   where id = p_id returning * into v;
  return v;
end;
$$;

revoke all on function public.completar_cadastro(text, text, text, text, text) from public, anon;
revoke all on function public.salvar_dados_imobiliaria(uuid, text, text, text) from public, anon;
revoke all on function public.salvar_dados_login(uuid, text, text, text) from public, anon;
grant execute on function public.completar_cadastro(text, text, text, text, text) to authenticated;
grant execute on function public.salvar_dados_imobiliaria(uuid, text, text, text) to authenticated;
grant execute on function public.salvar_dados_login(uuid, text, text, text) to authenticated;

-- >>>>> supabase/migrations/024_modulos.sql
-- =====================================================================
-- 024 — Ligar e desligar cada módulo do sistema (tela Empreendimento)
--  * Antes só as Pastas podiam ser desligadas. Agora cada estrutura tem
--    o seu interruptor. Desligar só esconde: nenhum dado é apagado.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.config
  add column if not exists modulo_funil      boolean not null default true,
  add column if not exists modulo_portal     boolean not null default true,
  add column if not exists modulo_rodadas    boolean not null default true,
  add column if not exists modulo_meeting    boolean not null default true,
  add column if not exists modulo_tv         boolean not null default true,
  add column if not exists modulo_cadastro   boolean not null default true,
  add column if not exists modulo_espelho_parceiros boolean not null default true;

comment on column public.config.modulo_funil is 'Funil de vendas (depende das Pastas)';
comment on column public.config.modulo_espelho_parceiros is 'Espelho visível para imobiliárias e corretores no painel';
comment on column public.config.modulo_cadastro is 'Página pública /cadastro para imobiliárias pedirem acesso';

grant update (modulo_funil, modulo_portal, modulo_rodadas, modulo_meeting, modulo_tv,
              modulo_cadastro, modulo_espelho_parceiros) on public.config to authenticated;

-- >>>>> supabase/migrations/025_meeting_editar.sql
-- =====================================================================
-- 025 — Meeting: editar nome, imobiliária e telefone de um convidado
--  * A equipe corrige os dados na recepção, antes ou depois de confirmar.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create or replace function public.editar_participante(p_id uuid, p_nome text, p_imobiliaria text default null,
                                                      p_telefone text default null, p_confirmar boolean default false)
returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  update public.recepcao_participantes
     set nome = regexp_replace(trim(p_nome), '\s+', ' ', 'g'),
         imobiliaria = nullif(regexp_replace(trim(coalesce(p_imobiliaria, '')), '\s+', ' ', 'g'), ''),
         telefone = nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), ''),
         presente = presente or p_confirmar,
         chegada_em = case when p_confirmar and not presente then now() else chegada_em end,
         confirmado_por = case when p_confirmar and not presente then public.meu_email() else confirmado_por end
   where id = p_id returning * into v;
  if not found then raise exception 'PARTICIPANTE_NAO_ENCONTRADO'; end if;
  return v;
end;
$$;

revoke all on function public.editar_participante(uuid, text, text, text, boolean) from public, anon;
grant execute on function public.editar_participante(uuid, text, text, text, boolean) to authenticated;

-- >>>>> supabase/migrations/026_simulador_logs.sql
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

-- >>>>> supabase/migrations/027_rodadas_vagas_pessoas.sql
-- =====================================================================
-- 027 — Rodadas: o limite passa a contar PESSOAS (cliente + acompanhantes)
--  * Um cliente com 2 acompanhantes ocupa 3 vagas.
--  * Confirmar ou editar só passa se couber no limite; senão VAGAS_INSUFICIENTES
--    (o hint diz quantas vagas restam).
--  * O nome do corretor nas confirmações é o nome do cadastro, nunca o e-mail.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create or replace function public.confirmar_cliente_rodada(
  p_rodada uuid, p_convidados text[], p_telefone text default null, p_observacao text default null,
  p_imobiliaria uuid default null
) returns public.rodada_inscricoes
language plpgsql security definer set search_path = public as $$
declare
  v_rodada public.rodadas;
  v_lista  text[] := public.normalizar_convidados(p_convidados);
  v_imob   uuid;
  v_nome   text;
  v_ocup   int;
  v        public.rodada_inscricoes;
begin
  select * into v_rodada from public.rodadas where id = p_rodada for update;
  if not found or not public.rodada_liberada(p_rodada) then raise exception 'RODADA_NAO_ENCONTRADA'; end if;
  if not public.eh_equipe() and not v_rodada.inscricoes_abertas then raise exception 'INSCRICOES_ENCERRADAS'; end if;
  if not public.eh_equipe() and v_rodada.data_hora < now() then raise exception 'RODADA_JA_ACONTECEU'; end if;

  select coalesce(sum(pessoas), 0) into v_ocup from public.rodada_inscricoes where rodada_id = p_rodada and not cancelada;
  if v_ocup >= v_rodada.limite_clientes then raise exception 'RODADA_LOTADA'; end if;
  if v_ocup + array_length(v_lista, 1) > v_rodada.limite_clientes then
    raise exception 'VAGAS_INSUFICIENTES' using hint = (v_rodada.limite_clientes - v_ocup)::text;
  end if;

  v_imob := case when public.eh_equipe() then p_imobiliaria else public.minha_imobiliaria() end;
  select nullif(trim(nome), '') into v_nome from public.perfis where user_id = auth.uid();

  begin
    insert into public.rodada_inscricoes (rodada_id, cliente_nome, pessoas, convidados, telefone, observacao, imobiliaria_id, corretor_id, corretor_nome)
    values (p_rodada, v_lista[1], array_length(v_lista, 1), v_lista, nullif(trim(p_telefone), ''),
            nullif(trim(p_observacao), ''), v_imob, auth.uid(), v_nome)
    returning * into v;
  exception when unique_violation then
    raise exception 'CLIENTE_JA_CONFIRMADO';
  end;
  return v;
end;
$$;

create or replace function public.editar_cliente_rodada(
  p_id uuid, p_convidados text[], p_telefone text default null, p_observacao text default null
) returns public.rodada_inscricoes
language plpgsql security definer set search_path = public as $$
declare v public.rodada_inscricoes; v_rodada public.rodadas; v_lista text[] := public.normalizar_convidados(p_convidados); v_outros int;
begin
  select * into v from public.rodada_inscricoes where id = p_id for update;
  if not found or v.cancelada or not public.pode_alterar_inscricao(v) then raise exception 'INSCRICAO_NAO_ENCONTRADA'; end if;
  select * into v_rodada from public.rodadas where id = v.rodada_id for update;
  if not public.eh_equipe() and (not v_rodada.inscricoes_abertas or v_rodada.data_hora < now()) then
    raise exception 'INSCRICOES_ENCERRADAS';
  end if;
  if array_length(v_lista, 1) > v.pessoas then
    select coalesce(sum(pessoas), 0) into v_outros from public.rodada_inscricoes
     where rodada_id = v.rodada_id and not cancelada and id <> p_id;
    if v_outros + array_length(v_lista, 1) > v_rodada.limite_clientes then
      raise exception 'VAGAS_INSUFICIENTES' using hint = greatest(0, v_rodada.limite_clientes - v_outros - v.pessoas)::text;
    end if;
  end if;
  begin
    update public.rodada_inscricoes
       set cliente_nome = v_lista[1], pessoas = array_length(v_lista, 1), convidados = v_lista,
           telefone = nullif(trim(p_telefone), ''), observacao = nullif(trim(p_observacao), ''), atualizado_em = now()
     where id = p_id returning * into v;
  exception when unique_violation then
    raise exception 'CLIENTE_JA_CONFIRMADO';
  end;
  return v;
end;
$$;

-- o limite da rodada não pode ficar abaixo das pessoas já confirmadas
create or replace function public.salvar_rodada(
  p_id uuid, p_nome text, p_data_hora timestamptz, p_local text, p_observacoes text,
  p_limite int, p_abertas boolean, p_todas boolean, p_imobiliarias uuid[]
) returns public.rodadas
language plpgsql security definer set search_path = public as $$
declare v public.rodadas; v_ocupadas int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if p_data_hora is null then raise exception 'DATA_OBRIGATORIA'; end if;
  if p_limite is null or p_limite < 1 then raise exception 'LIMITE_INVALIDO'; end if;
  if not p_todas and coalesce(array_length(p_imobiliarias, 1), 0) = 0 then raise exception 'IMOBILIARIAS_OBRIGATORIAS'; end if;

  if p_id is null then
    insert into public.rodadas (nome, data_hora, local, observacoes, limite_clientes, inscricoes_abertas, todas_imobiliarias, criado_por)
    values (trim(p_nome), p_data_hora, nullif(trim(p_local), ''), nullif(trim(p_observacoes), ''), p_limite, p_abertas, p_todas, public.meu_email())
    returning * into v;
  else
    select coalesce(sum(pessoas), 0) into v_ocupadas from public.rodada_inscricoes where rodada_id = p_id and not cancelada;
    if p_limite < v_ocupadas then raise exception 'LIMITE_ABAIXO_DOS_CONFIRMADOS' using hint = v_ocupadas::text; end if;
    update public.rodadas
       set nome = trim(p_nome), data_hora = p_data_hora, local = nullif(trim(p_local), ''),
           observacoes = nullif(trim(p_observacoes), ''), limite_clientes = p_limite,
           inscricoes_abertas = p_abertas, todas_imobiliarias = p_todas, atualizado_em = now()
     where id = p_id returning * into v;
    if not found then raise exception 'RODADA_NAO_ENCONTRADA'; end if;
  end if;

  delete from public.rodadas_imobiliarias where rodada_id = v.id;
  if not p_todas then
    insert into public.rodadas_imobiliarias (rodada_id, imobiliaria_id)
    select v.id, unnest(p_imobiliarias) on conflict do nothing;
  end if;
  return v;
end;
$$;

-- confirmações antigas que guardaram o e-mail no lugar do nome do corretor
update public.rodada_inscricoes i
   set corretor_nome = nullif(trim(p.nome), '')
  from public.perfis p
 where p.user_id = i.corretor_id and i.corretor_nome like '%@%';

comment on column public.rodadas.limite_clientes is 'Limite de PESSOAS (cliente + acompanhantes) desde a migração 027';

-- >>>>> supabase/migrations/028_funil_parceiros.sql
-- =====================================================================
-- 028 — Funil de vendas para imobiliárias e corretores (só leitura)
--  * O corretor vê as negociações das pastas dele; a imobiliária, as de
--    todos os seus corretores (mesma regra de acesso das pastas).
--  * Mover etapa continua só com a equipe (mover_etapa já exige eh_equipe).
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

drop policy if exists negociacoes_parceiros on public.negociacoes;
create policy negociacoes_parceiros on public.negociacoes for select
  using (pasta_id is not null and public.pode_ver_pasta(pasta_id));

-- >>>>> supabase/migrations/029_corretor_responsavel.sql
-- =====================================================================
-- 029 — Corretor responsável pela pasta
--  * A pasta pertence ao corretor atribuído, não a quem a cadastrou.
--    pastas.criado_por_id passa a significar "corretor responsável" (é ele
--    que todas as regras de acesso já usam); quem cadastrou fica guardado
--    em pastas.cadastrado_por_id.
--  * O corretor vê as pastas atribuídas a ele (lista, funil e andamento);
--    a imobiliária continua vendo todas as suas.
--  * Equipe e imobiliária (para as suas pastas) atribuem ou trocam o corretor.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.pastas add column if not exists cadastrado_por_id uuid;
update public.pastas set cadastrado_por_id = criado_por_id where cadastrado_por_id is null;
comment on column public.pastas.criado_por_id is 'Corretor responsável (dono da pasta para as regras de acesso)';
comment on column public.pastas.cadastrado_por_id is 'Login que cadastrou a pasta';

-- pastas cadastradas pela equipe ou pela imobiliária não têm corretor até alguém atribuir
update public.pastas p set criado_por_id = null
  from public.perfis f
 where f.user_id = p.criado_por_id and f.papel <> 'corretor';

create or replace function public.pastas_cadastro() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_papel text;
begin
  new.cadastrado_por_id := auth.uid();
  select papel into v_papel from public.perfis where user_id = auth.uid();
  -- só um corretor vira dono automático da pasta que ele mesmo cadastra
  if coalesce(v_papel, '') <> 'corretor' then new.criado_por_id := null; end if;
  return new;
end;
$$;
drop trigger if exists pastas_cadastro on public.pastas;
create trigger pastas_cadastro before insert on public.pastas
  for each row execute function public.pastas_cadastro();   -- roda depois de pastas_antes (ordem alfabética)

create or replace function public.atribuir_corretor(p_pasta uuid, p_corretor uuid)
returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v public.pastas; v_antes text; v_depois text;
begin
  select * into v from public.pastas where id = p_pasta for update;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if not (public.eh_equipe() or (public.eh_gestor() and v.imobiliaria_id = public.minha_imobiliaria())) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if p_corretor is not null and not exists (
    select 1 from public.perfis where user_id = p_corretor and papel = 'corretor' and imobiliaria_id = v.imobiliaria_id
  ) then raise exception 'CORRETOR_INVALIDO'; end if;
  if v.criado_por_id is not distinct from p_corretor then return v; end if;

  select coalesce(nullif(nome, ''), email) into v_antes from public.perfis where user_id = v.criado_por_id;
  select coalesce(nullif(nome, ''), email) into v_depois from public.perfis where user_id = p_corretor;
  update public.pastas set criado_por_id = p_corretor where id = p_pasta returning * into v;
  update public.negociacoes set corretor = v_depois where pasta_id = p_pasta and ativa;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Corretor responsável alterado',
          jsonb_build_object('corretor', coalesce(v_antes, 'sem corretor') || ' → ' || coalesce(v_depois, 'sem corretor')),
          public.meu_email());
  return v;
end;
$$;
revoke all on function public.atribuir_corretor(uuid, uuid) from public, anon;
grant execute on function public.atribuir_corretor(uuid, uuid) to authenticated;

-- >>>>> supabase/migrations/030_treinamentos.sql
-- =====================================================================
-- 030 — Treinamentos com agenda de horários
--  * Um treinamento tem vários horários (início de 30 em 30 minutos), cada
--    um com limite de pessoas (25). Lotou, não aceita mais inscrição.
--  * Cada corretor (ou login de imobiliária) se inscreve em UM horário do
--    treinamento. Para trocar, cancela a inscrição e se inscreve em outro.
--  * Visível para todas as imobiliárias. A equipe vê todos os inscritos,
--    inclui alguém na hora e confirma a presença; a imobiliária vê os seus.
--  * Já cria o treinamento de 18 e 19/11/2026: 09:00 a 11:30 e 14:00 a 19:00.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.config add column if not exists modulo_treinamentos boolean not null default true;
grant update (modulo_treinamentos) on public.config to authenticated;

create table if not exists public.treinamentos (
  id                  uuid primary key default gen_random_uuid(),
  nome                text not null,
  local               text,
  inscricoes_abertas  boolean not null default true,
  criado_em           timestamptz not null default now()
);

create table if not exists public.treinamento_horarios (
  id              uuid primary key default gen_random_uuid(),
  treinamento_id  uuid not null references public.treinamentos(id) on delete cascade,
  inicio          timestamptz not null,
  limite          int not null default 25 check (limite > 0),
  unique (treinamento_id, inicio)
);

create table if not exists public.treinamento_inscricoes (
  id              uuid primary key default gen_random_uuid(),
  treinamento_id  uuid not null references public.treinamentos(id) on delete cascade,
  horario_id      uuid not null references public.treinamento_horarios(id) on delete cascade,
  user_id         uuid,                       -- login de quem participa (nulo para quem a equipe incluiu na hora)
  nome            text not null,
  email           text,
  papel           text,
  imobiliaria_id  uuid references public.imobiliarias(id) on delete set null,
  imobiliaria     text,
  presente        boolean not null default false,
  presenca_em     timestamptz,
  presenca_por    text,
  incluido_por    text,
  criado_em       timestamptz not null default now()
);
-- um horário por pessoa em cada treinamento
create unique index if not exists treinamento_inscricoes_um_por_pessoa
  on public.treinamento_inscricoes (treinamento_id, user_id) where user_id is not null;
create index if not exists treinamento_inscricoes_horario on public.treinamento_inscricoes (horario_id);

alter table public.treinamentos enable row level security;
alter table public.treinamento_horarios enable row level security;
alter table public.treinamento_inscricoes enable row level security;
grant select on public.treinamentos, public.treinamento_horarios, public.treinamento_inscricoes to authenticated;
create policy treinamentos_leitura on public.treinamentos for select using (auth.uid() is not null);
create policy treinamento_horarios_leitura on public.treinamento_horarios for select using (auth.uid() is not null);
create policy treinamento_inscricoes_leitura on public.treinamento_inscricoes for select using (
  public.eh_equipe()
  or user_id = auth.uid()
  or (public.eh_gestor() and imobiliaria_id = public.minha_imobiliaria())
);

-- vagas de cada horário (todos veem a contagem, não os nomes)
create or replace function public.treinamento_vagas(p_treinamento uuid)
returns table (horario_id uuid, inscritos int, presentes int)
language sql stable security definer set search_path = public as $$
  select h.id, count(i.id)::int, count(i.id) filter (where i.presente)::int
    from public.treinamento_horarios h
    left join public.treinamento_inscricoes i on i.horario_id = h.id
   where h.treinamento_id = p_treinamento and auth.uid() is not null
   group by h.id;
$$;

-- inscrever: o próprio corretor/imobiliária; a equipe pode incluir um login (p_user) ou um nome avulso
create or replace function public.inscrever_treinamento(p_horario uuid, p_user uuid default null,
  p_nome text default null, p_imobiliaria text default null)
returns public.treinamento_inscricoes
language plpgsql security definer set search_path = public as $$
declare
  h public.treinamento_horarios; t public.treinamentos; v public.treinamento_inscricoes;
  alvo uuid; pf public.perfis; imob_nome text; ocupadas int; equipe boolean := public.eh_equipe();
begin
  select * into h from public.treinamento_horarios where id = p_horario for update;
  if not found then raise exception 'HORARIO_NAO_ENCONTRADO'; end if;
  select * into t from public.treinamentos where id = h.treinamento_id;
  if not equipe then
    if not t.inscricoes_abertas then raise exception 'INSCRICOES_ENCERRADAS'; end if;
    if h.inicio <= now() then raise exception 'HORARIO_JA_COMECOU'; end if;
  end if;

  alvo := case when equipe then p_user else auth.uid() end;
  if not equipe and (p_user is not null and p_user <> auth.uid()) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;

  if alvo is not null then
    select * into pf from public.perfis where user_id = alvo;
    if not found or pf.papel not in ('corretor', 'imobiliaria') then raise exception 'SO_CORRETOR'; end if;
    if exists (select 1 from public.treinamento_inscricoes where treinamento_id = h.treinamento_id and user_id = alvo) then
      raise exception 'JA_INSCRITO';
    end if;
    select nome into imob_nome from public.imobiliarias where id = pf.imobiliaria_id;
  elsif not equipe or coalesce(length(trim(p_nome)), 0) < 3 then
    raise exception 'NOME_OBRIGATORIO';
  end if;

  select count(*) into ocupadas from public.treinamento_inscricoes where horario_id = p_horario;
  if ocupadas >= h.limite then raise exception 'HORARIO_LOTADO'; end if;

  insert into public.treinamento_inscricoes (treinamento_id, horario_id, user_id, nome, email, papel, imobiliaria_id, imobiliaria, incluido_por)
  values (h.treinamento_id, p_horario, alvo,
          coalesce(nullif(trim(pf.nome), ''), trim(p_nome), pf.email), pf.email, pf.papel,
          pf.imobiliaria_id, coalesce(imob_nome, nullif(trim(p_imobiliaria), '')),
          case when equipe then public.meu_email() end)
  returning * into v;
  return v;
exception when unique_violation then
  raise exception 'JA_INSCRITO';
end;
$$;

-- cancelar: a própria pessoa (antes do horário) ou a equipe
create or replace function public.cancelar_inscricao_treinamento(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v public.treinamento_inscricoes; h public.treinamento_horarios;
begin
  select * into v from public.treinamento_inscricoes where id = p_id for update;
  if not found then raise exception 'INSCRICAO_NAO_ENCONTRADA'; end if;
  if not public.eh_equipe() then
    if v.user_id is distinct from auth.uid() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
    select * into h from public.treinamento_horarios where id = v.horario_id;
    if h.inicio <= now() then raise exception 'HORARIO_JA_COMECOU'; end if;
    if v.presente then raise exception 'PRESENCA_JA_CONFIRMADA'; end if;
  end if;
  delete from public.treinamento_inscricoes where id = p_id;
end;
$$;

-- presença: só a equipe
create or replace function public.presenca_treinamento(p_id uuid, p_presente boolean)
returns public.treinamento_inscricoes language plpgsql security definer set search_path = public as $$
declare v public.treinamento_inscricoes;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.treinamento_inscricoes
     set presente = p_presente,
         presenca_em = case when p_presente then now() end,
         presenca_por = case when p_presente then public.meu_email() end
   where id = p_id returning * into v;
  if not found then raise exception 'INSCRICAO_NAO_ENCONTRADA'; end if;
  return v;
end;
$$;

-- abrir ou fechar inscrições, e mudar o limite de um horário (administrador)
create or replace function public.ajustar_treinamento(p_treinamento uuid, p_abertas boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.treinamentos set inscricoes_abertas = p_abertas where id = p_treinamento;
end;
$$;
create or replace function public.ajustar_limite_horario(p_horario uuid, p_limite int)
returns void language plpgsql security definer set search_path = public as $$
declare ocupadas int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select count(*) into ocupadas from public.treinamento_inscricoes where horario_id = p_horario;
  if p_limite < greatest(1, ocupadas) then raise exception 'LIMITE_ABAIXO_DOS_INSCRITOS' using hint = ocupadas::text; end if;
  update public.treinamento_horarios set limite = p_limite where id = p_horario;
end;
$$;

revoke all on function public.treinamento_vagas(uuid), public.inscrever_treinamento(uuid, uuid, text, text),
  public.cancelar_inscricao_treinamento(uuid), public.presenca_treinamento(uuid, boolean),
  public.ajustar_treinamento(uuid, boolean), public.ajustar_limite_horario(uuid, int) from public, anon;
grant execute on function public.treinamento_vagas(uuid), public.inscrever_treinamento(uuid, uuid, text, text),
  public.cancelar_inscricao_treinamento(uuid), public.presenca_treinamento(uuid, boolean),
  public.ajustar_treinamento(uuid, boolean), public.ajustar_limite_horario(uuid, int) to authenticated;

-- ---------------------------------------------------------------------
-- Treinamento de 18 e 19/11/2026 (horário de Brasília)
-- ---------------------------------------------------------------------
do $$
declare t uuid; d date; hr time;
begin
  if exists (select 1 from public.treinamentos where nome = 'Treinamento Duo Haus') then return; end if;
  insert into public.treinamentos (nome) values ('Treinamento Duo Haus') returning id into t;
  foreach d in array array['2026-11-18'::date, '2026-11-19'::date] loop
    for hr in select generate_series('2000-01-01 09:00'::timestamp, '2000-01-01 11:30', interval '30 minutes')::time
              union all
              select generate_series('2000-01-01 14:00'::timestamp, '2000-01-01 19:00', interval '30 minutes')::time loop
      insert into public.treinamento_horarios (treinamento_id, inicio, limite)
      values (t, (d + hr) at time zone 'America/Sao_Paulo', 25);
    end loop;
  end loop;
end $$;

-- >>>>> supabase/migrations/031_treinamentos_ajuste.sql
-- =====================================================================
-- 031 — Ajuste da agenda de treinamentos
--  * Quarta, 18/11: começa às 14:00 (saem os horários da manhã).
--  * Quinta, 19/11: continua começando às 09:00.
--  * Todas as turmas passam a ter 20 pessoas.
--  * Segurança: horário da manhã de 18/11 que já tenha inscritos NÃO é
--    apagado (o script avisa quantos são); turma que já passou de 20
--    inscritos fica com o limite igual ao número de inscritos.
-- Rodar depois do 030, uma única vez, no SQL Editor do Supabase.
-- =====================================================================
alter table public.treinamento_horarios alter column limite set default 20;

do $$
declare t uuid; com_inscritos int; apagados int;
begin
  select id into t from public.treinamentos where nome = 'Treinamento Duo Haus';
  if t is null then raise exception 'Rode primeiro o 030_treinamentos.sql.'; end if;

  -- manhã de 18/11
  select count(distinct h.id) into com_inscritos
    from public.treinamento_horarios h join public.treinamento_inscricoes i on i.horario_id = h.id
   where h.treinamento_id = t
     and (h.inicio at time zone 'America/Sao_Paulo')::date = '2026-11-18'
     and (h.inicio at time zone 'America/Sao_Paulo')::time < '14:00';
  delete from public.treinamento_horarios h
   where h.treinamento_id = t
     and (h.inicio at time zone 'America/Sao_Paulo')::date = '2026-11-18'
     and (h.inicio at time zone 'America/Sao_Paulo')::time < '14:00'
     and not exists (select 1 from public.treinamento_inscricoes i where i.horario_id = h.id);
  get diagnostics apagados = row_count;

  -- 20 pessoas por turma
  update public.treinamento_horarios h
     set limite = greatest(20, (select count(*) from public.treinamento_inscricoes i where i.horario_id = h.id))
   where h.treinamento_id = t;

  raise notice 'Horários da manhã de 18/11 removidos: %.', apagados;
  if com_inscritos > 0 then
    raise notice 'ATENÇÃO: % horário(s) da manhã de 18/11 já tinham inscritos e foram mantidos. Remova as inscrições na tela de Treinamentos e rode este arquivo de novo.', com_inscritos;
  end if;
end $$;

-- >>>>> supabase/migrations/032_recepcionista.sql
-- =====================================================================
-- 032 — Perfil Recepcionista
--  * Novo papel 'recepcao': acesso somente ao Meeting.
--  * No Meeting pode tudo o que a equipe pode: ver a lista, confirmar
--    presença, incluir quem não estava na lista e editar dados.
--  * Não vê pastas, espelho, funil, rodadas, portal nem configurações.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.perfis drop constraint if exists perfis_papel_check;
alter table public.perfis add constraint perfis_papel_check
  check (papel in ('admin', 'vendas', 'imobiliaria', 'corretor', 'recepcao'));

-- Quem opera o Meeting: equipe de vendas ou recepcionista
create or replace function public.pode_meeting() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid() and papel in ('admin', 'vendas', 'recepcao'));
$$;
revoke all on function public.pode_meeting() from public, anon;
grant execute on function public.pode_meeting() to authenticated;

drop policy if exists recepcao_eventos_leitura on public.recepcao_eventos;
drop policy if exists recepcao_participantes_leitura on public.recepcao_participantes;
create policy recepcao_eventos_leitura on public.recepcao_eventos for select using (public.pode_meeting());
create policy recepcao_participantes_leitura on public.recepcao_participantes for select using (public.pode_meeting());

create or replace function public.marcar_presenca(p_id uuid, p_presente boolean) returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes;
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.recepcao_participantes
     set presente = p_presente,
         chegada_em = case when p_presente then coalesce(chegada_em, now()) else null end,
         confirmado_por = case when p_presente then public.meu_email() else null end
   where id = p_id returning * into v;
  if not found then raise exception 'PARTICIPANTE_NAO_ENCONTRADO'; end if;
  return v;
end;
$$;

create or replace function public.incluir_participante(p_evento uuid, p_nome text, p_imobiliaria text default null, p_telefone text default null)
returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes;
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  insert into public.recepcao_participantes (evento_id, nome, imobiliaria, telefone, presente, chegada_em, confirmado_por, incluido_na_hora)
  values (p_evento, regexp_replace(trim(p_nome), '\s+', ' ', 'g'), nullif(trim(p_imobiliaria), ''),
          nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), ''), true, now(), public.meu_email(), true)
  returning * into v;
  return v;
end;
$$;

create or replace function public.editar_participante(p_id uuid, p_nome text, p_imobiliaria text default null,
                                                      p_telefone text default null, p_confirmar boolean default false)
returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes;
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  update public.recepcao_participantes
     set nome = regexp_replace(trim(p_nome), '\s+', ' ', 'g'),
         imobiliaria = nullif(regexp_replace(trim(coalesce(p_imobiliaria, '')), '\s+', ' ', 'g'), ''),
         telefone = nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), ''),
         presente = presente or p_confirmar,
         chegada_em = case when p_confirmar and not presente then now() else chegada_em end,
         confirmado_por = case when p_confirmar and not presente then public.meu_email() else confirmado_por end
   where id = p_id returning * into v;
  if not found then raise exception 'PARTICIPANTE_NAO_ENCONTRADO'; end if;
  return v;
end;
$$;

-- >>>>> supabase/migrations/033_treinamentos_horarios.sql
-- =====================================================================
-- 033 — Treinamentos: o administrador configura os horários
--  * Adicionar horários: um dia, das HH:MM às HH:MM, a cada N minutos,
--    com o limite de pessoas (os que já existem são mantidos).
--  * Remover um horário: só se ninguém estiver inscrito nele.
--  * O limite de cada turma continua em ajustar_limite_horario (030).
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create or replace function public.adicionar_horarios_treinamento(p_treinamento uuid, p_dia date, p_inicio time,
                                                                 p_fim time, p_intervalo int, p_limite int)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_dia is null or p_inicio is null then raise exception 'HORARIO_INVALIDO'; end if;
  if p_fim is null then p_fim := p_inicio; end if;
  if p_fim < p_inicio then raise exception 'FIM_ANTES_DO_INICIO'; end if;
  if coalesce(p_intervalo, 0) < 5 or p_intervalo > 480 then raise exception 'INTERVALO_INVALIDO'; end if;
  if coalesce(p_limite, 0) < 1 or p_limite > 1000 then raise exception 'LIMITE_INVALIDO'; end if;
  if not exists (select 1 from public.treinamentos where id = p_treinamento) then raise exception 'TREINAMENTO_NAO_ENCONTRADO'; end if;
  insert into public.treinamento_horarios (treinamento_id, inicio, limite)
  select p_treinamento, h at time zone 'America/Sao_Paulo', p_limite
    from generate_series(p_dia + p_inicio, p_dia + p_fim, make_interval(mins => p_intervalo)) as h
  on conflict (treinamento_id, inicio) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.remover_horario_treinamento(p_horario uuid)
returns void language plpgsql security definer set search_path = public as $$
declare ocupadas int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select count(*) into ocupadas from public.treinamento_inscricoes where horario_id = p_horario;
  if ocupadas > 0 then raise exception 'HORARIO_COM_INSCRITOS' using hint = ocupadas::text; end if;
  delete from public.treinamento_horarios where id = p_horario;
  if not found then raise exception 'HORARIO_NAO_ENCONTRADO'; end if;
end;
$$;

revoke all on function public.adicionar_horarios_treinamento(uuid, date, time, time, int, int),
  public.remover_horario_treinamento(uuid) from public, anon;
grant execute on function public.adicionar_horarios_treinamento(uuid, date, time, time, int, int),
  public.remover_horario_treinamento(uuid) to authenticated;

-- >>>>> supabase/migrations/034_portal_premiacao.sql
-- =====================================================================
-- 034 — Portal do Corretor: categoria "Regras da premiação"
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================
alter table public.portal_itens drop constraint if exists portal_itens_categoria_check;
alter table public.portal_itens add constraint portal_itens_categoria_check check (categoria in (
  'book', 'ficha_tecnica', 'fotos_decorado', 'imagens', 'materiais_apoio', 'redes_sociais',
  'plantas', 'premiacao', 'simulador', 'tour_virtual', 'videos'));

-- >>>>> supabase/migrations/035_propostas.sql
-- =====================================================================
-- 035 — Propostas (trazidas da v2, já validadas no ambiente de testes)
--  Junta, nesta ordem, as migrações 101 a 105 da v2:
--   101 propostas, tabelas de venda e preço por tipo
--   102 dados comerciais do Duo Haus (preço do m², tabelas, peso das unidades)
--   103 carta proposta no modelo novo
--   104 séries Bimestrais, Trimestrais e Permuta
--   105 alçadas de aprovação e PV calculado pelo banco
--  Fica fora: fila de escolha, painéis, meeting público e vários empreendimentos.
--
--  O que muda no que já existe (nada além disto):
--   * unidades: 3 colunas novas (tipo_preco, peso, tabela), só preenchidas.
--   * alterar_status: idêntica à 016, com UMA linha a mais, que deixa a
--     aprovação automática da proposta mudar o status (o navegador não
--     consegue ligar essa chave).
--   * config.modulo_propostas: começa DESLIGADO. Enquanto estiver desligado,
--     ninguém de fora da equipe cria proposta.
--
-- Executar uma única vez no SQL Editor do Supabase, DEPOIS do backup
-- (035_backup_antes.sql).
-- =====================================================================

begin;  -- tudo ou nada: se qualquer passo falhar, nada fica gravado

alter table public.config add column if not exists modulo_propostas boolean not null default false;


-- ####################################################################
-- origem: v2/101_propostas.sql
-- ####################################################################
-- =====================================================================
-- 101 — Propostas (v2)
--  * Parâmetros comerciais do empreendimento (mês da tabela, entrega,
--    taxa do VPL, comissão, textos da carta proposta).
--  * Preço do m² por tipo, peso e tabela de cada unidade.
--  * Tabelas de venda (séries com % e calendário).
--  * Propostas: rascunho → enviada → aprovada / recusada / devolvida.
--    A aprovação leva a unidade para "Proposta recebida" no espelho.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Parâmetros comerciais (linha única)
-- ---------------------------------------------------------------------
create table public.comercial (
  id                 int primary key default 1 check (id = 1),
  mes_tabela         date not null default date_trunc('month', now())::date,  -- 1º dia do mês
  mes_entrega        date not null default (date_trunc('month', now()) + interval '48 months')::date,
  taxa_vp            numeric(8, 6) not null default 0.007 check (taxa_vp >= 0 and taxa_vp < 0.1),   -- ao mês
  comissao_pct       numeric(8, 6) not null default 0.05 check (comissao_pct >= 0 and comissao_pct < 0.3),
  parte_sinal        numeric(8, 6) not null default 0.7 check (parte_sinal > 0 and parte_sinal <= 1), -- do sinal para a comissão
  limite_captacao    numeric(8, 6) not null default -0.15,
  dias_vencimento    int[] not null default '{5,10,15,20}',
  vendedora          text,          -- razão social da SPE (carta proposta)
  vendedora_cnpj     text,
  cidade_carta       text,          -- local de assinatura da carta
  forma_sinal        text not null default 'PIX / transferência',
  forma_parcelas     text not null default 'Boleto',
  validade_dias      int not null default 5 check (validade_dias between 1 and 60),
  texto_abertura     text not null default 'Através desta o(s) Proponente(s) abaixo qualificado(s) formaliza(m) proposta para aquisição do imóvel descrito, cujos termos e condições seguem para avaliação da Vendedora.',
  texto_condicoes    text not null default '',
  atualizado_em      timestamptz not null default now()
);
insert into public.comercial default values;

create table public.precos_tipo (
  tipo     text primary key,
  preco_m2 numeric(12, 2) not null check (preco_m2 > 0)
);

create table public.tabelas_venda (
  nome text primary key
);

create table public.tabelas_series (
  id           serial primary key,
  tabela       text not null references public.tabelas_venda (nome) on update cascade on delete cascade,
  ordem        int not null,
  rotulo       text not null,
  periodicidade text not null check (periodicidade in ('Sinal', 'Mensais', 'Semestrais', 'Anuais', 'Unica', 'Financiamento')),
  qtd          int not null check (qtd >= 1),
  percentual   numeric(10, 8) not null check (percentual >= 0 and percentual <= 1),  -- da série inteira
  base         text not null check (base in ('venda', 'entrega')),
  meses        int not null,                                                          -- a partir da base
  unique (tabela, ordem)
);

alter table public.unidades
  add column if not exists tipo_preco text references public.precos_tipo (tipo) on update cascade,
  add column if not exists peso       numeric(10, 6) check (peso > 0),
  add column if not exists tabela     text references public.tabelas_venda (nome) on update cascade;

-- leitura: qualquer login (corretores precisam da tabela para montar a proposta)
alter table public.comercial      enable row level security;
alter table public.precos_tipo    enable row level security;
alter table public.tabelas_venda  enable row level security;
alter table public.tabelas_series enable row level security;
revoke all on public.comercial, public.precos_tipo, public.tabelas_venda, public.tabelas_series from anon, authenticated;
grant select on public.comercial, public.precos_tipo, public.tabelas_venda, public.tabelas_series to authenticated;
grant insert, update, delete on public.precos_tipo, public.tabelas_venda, public.tabelas_series to authenticated;
grant update on public.comercial to authenticated;
grant usage on sequence public.tabelas_series_id_seq to authenticated;
create policy comercial_leitura on public.comercial for select using (auth.uid() is not null);
create policy comercial_edicao on public.comercial for update using (public.eh_admin()) with check (public.eh_admin());
create policy precos_leitura on public.precos_tipo for select using (auth.uid() is not null);
create policy precos_edicao on public.precos_tipo for all using (public.eh_admin()) with check (public.eh_admin());
create policy tabelas_leitura on public.tabelas_venda for select using (auth.uid() is not null);
create policy tabelas_edicao on public.tabelas_venda for all using (public.eh_admin()) with check (public.eh_admin());
create policy series_leitura on public.tabelas_series for select using (auth.uid() is not null);
create policy series_edicao on public.tabelas_series for all using (public.eh_admin()) with check (public.eh_admin());

-- ---------------------------------------------------------------------
-- Propostas
-- ---------------------------------------------------------------------
create sequence public.propostas_codigo_seq;

create table public.propostas (
  id              uuid primary key default gen_random_uuid(),
  codigo          text not null unique default 'PR-' || lpad(nextval('public.propostas_codigo_seq')::text, 4, '0'),
  unidade_id      uuid not null references public.unidades (id),
  pasta_id        uuid references public.pastas (id),
  imobiliaria_id  uuid references public.imobiliarias (id) default public.minha_imobiliaria(),
  criado_por_id   uuid default auth.uid(),
  criado_por      text,
  data_proposta   date not null default (now() at time zone 'America/Sao_Paulo')::date,
  status          text not null default 'rascunho'
                  check (status in ('rascunho', 'enviada', 'aprovada', 'recusada', 'devolvida', 'cancelada')),
  series          jsonb not null default '[]',   -- [{qtd, periodicidade, vencimento, valor}]
  resumo          jsonb not null default '{}',   -- valores calculados na tela (tabela × proposta, comissão)
  observacoes     text,
  comissao_pct    numeric(8, 6),
  parte_sinal     numeric(8, 6),
  motivo_analise  text,
  analisada_por   text,
  analisada_em    timestamptz,
  enviada_em      timestamptz,
  versao          int not null default 1,
  criada_em       timestamptz not null default now(),
  atualizada_em   timestamptz not null default now()
);
create index propostas_unidade_idx on public.propostas (unidade_id);
create index propostas_pasta_idx on public.propostas (pasta_id);
create index propostas_imob_idx on public.propostas (imobiliaria_id, criado_por_id);

create table public.historico_propostas (
  id            bigint generated always as identity primary key,
  proposta_id   uuid not null references public.propostas (id) on delete cascade,
  acao          text not null,
  detalhes      jsonb,
  usuario_email text,
  criado_em     timestamptz not null default now()
);
create index historico_propostas_idx on public.historico_propostas (proposta_id, criado_em desc);

-- Regras aplicadas em toda gravação
create function public.propostas_antes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_serie jsonb;
  v_email text;
begin
  select email into v_email from public.perfis where user_id = auth.uid();
  if tg_op = 'INSERT' then
    new.data_proposta := (now() at time zone 'America/Sao_Paulo')::date;  -- dia da criação, no horário de Brasília
    new.criado_por_id := auth.uid();
    new.criado_por := v_email;
    new.status := 'rascunho';
    if not public.eh_equipe() then new.imobiliaria_id := public.minha_imobiliaria(); end if;
  else
    -- campos que só mudam pelas funções de envio e análise
    if current_setting('propostas.funcao', true) is distinct from 'sim' then
      new.status := old.status; new.motivo_analise := old.motivo_analise;
      new.analisada_por := old.analisada_por; new.analisada_em := old.analisada_em; new.enviada_em := old.enviada_em;
      if old.status not in ('rascunho', 'devolvida') and not public.eh_equipe() then
        raise exception 'PROPOSTA_BLOQUEADA' using hint = 'Só é possível editar rascunhos ou propostas devolvidas.';
      end if;
    end if;
    new.data_proposta := old.data_proposta;
    new.criado_por_id := old.criado_por_id; new.criado_por := old.criado_por;
    new.imobiliaria_id := case when public.eh_equipe() then new.imobiliaria_id else old.imobiliaria_id end;
    new.versao := old.versao + 1;
    new.atualizada_em := now();
  end if;

  if new.pasta_id is not null and not public.pode_ver_pasta(new.pasta_id) then
    raise exception 'PASTA_NAO_ENCONTRADA';
  end if;
  if jsonb_typeof(new.series) <> 'array' then raise exception 'SERIES_INVALIDAS'; end if;
  -- nenhum vencimento antes da data da proposta (hoje, ou a data em que ela foi salva)
  for v_serie in select * from jsonb_array_elements(new.series) loop
    if (v_serie ->> 'vencimento')::date < new.data_proposta then
      raise exception 'VENCIMENTO_ANTERIOR' using hint = 'Nenhum vencimento pode ser anterior à data da proposta.';
    end if;
    if coalesce((v_serie ->> 'qtd')::int, 0) < 1 or coalesce((v_serie ->> 'valor')::numeric, 0) <= 0 then
      raise exception 'SERIE_INVALIDA';
    end if;
  end loop;
  return new;
end;
$$;
create trigger propostas_antes before insert or update on public.propostas
  for each row execute function public.propostas_antes();

create function public.propostas_depois() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.historico_propostas (proposta_id, acao, detalhes, usuario_email)
  values (new.id,
          case when tg_op = 'INSERT' then 'Proposta criada'
               when new.status <> old.status then 'Status: ' || new.status
               else 'Proposta editada' end,
          jsonb_strip_nulls(jsonb_build_object(
            'total', new.resumo -> 'total', 'pv', new.resumo -> 'pv_pct', 'motivo', new.motivo_analise)),
          (select email from public.perfis where user_id = auth.uid()));
  return new;
end;
$$;
create trigger propostas_depois after insert or update on public.propostas
  for each row execute function public.propostas_depois();

alter table public.propostas enable row level security;
alter table public.historico_propostas enable row level security;
revoke all on public.propostas, public.historico_propostas from anon, authenticated;
grant select, insert, update on public.propostas to authenticated;
grant usage on sequence public.propostas_codigo_seq to authenticated;
grant select on public.historico_propostas to authenticated;
create policy propostas_leitura on public.propostas for select
  using (public.acesso_pasta(imobiliaria_id, criado_por_id));
create policy propostas_inclusao on public.propostas for insert
  with check (public.eh_equipe() or public.minha_imobiliaria() is not null);
create policy propostas_edicao on public.propostas for update
  using (public.acesso_pasta(imobiliaria_id, criado_por_id))
  with check (public.acesso_pasta(imobiliaria_id, criado_por_id));
create policy historico_propostas_leitura on public.historico_propostas for select
  using (exists (select 1 from public.propostas p where p.id = proposta_id and public.acesso_pasta(p.imobiliaria_id, p.criado_por_id)));

-- ---------------------------------------------------------------------
-- Enviar para análise (corretor, imobiliária ou equipe)
-- ---------------------------------------------------------------------
create function public.enviar_proposta(p_id uuid) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare v public.propostas;
begin
  select * into v from public.propostas where id = p_id for update;
  if not found or not public.acesso_pasta(v.imobiliaria_id, v.criado_por_id) then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  if v.status not in ('rascunho', 'devolvida') then raise exception 'PROPOSTA_BLOQUEADA'; end if;
  if v.pasta_id is null then raise exception 'PASTA_OBRIGATORIA' using hint = 'Vincule a pasta do comprador antes de enviar.'; end if;
  if jsonb_array_length(v.series) = 0 then raise exception 'SERIES_INVALIDAS'; end if;
  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas set status = 'enviada', enviada_em = now(), motivo_analise = null where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);
  return v;
end;
$$;

-- ---------------------------------------------------------------------
-- Análise (somente equipe): aprovar, recusar ou devolver para ajuste.
-- Aprovar leva a unidade para "Proposta recebida" no espelho, com o
-- valor total e o PV (% do VPL da tabela).
-- ---------------------------------------------------------------------
create function public.analisar_proposta(p_id uuid, p_decisao text, p_motivo text default null) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v public.propostas;
  u public.unidades;
  v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_decisao not in ('aprovada', 'recusada', 'devolvida', 'cancelada') then raise exception 'DECISAO_INVALIDA'; end if;
  select * into v from public.propostas where id = p_id for update;
  if not found then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  if p_decisao in ('recusada', 'devolvida', 'cancelada') and v_motivo is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  if p_decisao in ('aprovada', 'recusada', 'devolvida') and v.status <> 'enviada' then raise exception 'PROPOSTA_NAO_ENVIADA'; end if;

  if p_decisao = 'aprovada' then
    -- uma proposta aprovada por unidade
    if exists (select 1 from public.propostas where unidade_id = v.unidade_id and status = 'aprovada' and id <> v.id) then
      raise exception 'UNIDADE_COM_PROPOSTA_APROVADA';
    end if;
    select * into u from public.unidades where id = v.unidade_id;
    if u.status in ('disponivel', 'reservada') then
      perform public.alterar_status(u.id, 'proposta', u.versao, null, null, null, null,
        (v.resumo ->> 'total')::numeric, round((v.resumo ->> 'pv_pct')::numeric, 2), v.pasta_id);
    elsif u.status <> 'proposta' then
      raise exception 'UNIDADE_INDISPONIVEL' using hint = 'A unidade está em outra etapa no espelho.';
    end if;
  end if;

  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas
     set status = p_decisao, motivo_analise = v_motivo,
         analisada_por = (select email from public.perfis where user_id = auth.uid()), analisada_em = now()
   where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);
  return v;
end;
$$;

revoke all on function public.enviar_proposta(uuid), public.analisar_proposta(uuid, text, text) from public, anon;
grant execute on function public.enviar_proposta(uuid), public.analisar_proposta(uuid, text, text) to authenticated;

-- ####################################################################
-- origem: v2/102_dados_comerciais_duohaus.sql
-- ####################################################################
-- =====================================================================
-- 102 — Dados comerciais do Duo Haus (planilha Compacto_Studio.xlsm)
--  * Mês da tabela nov/2026, entrega out/2030, VPL a 0,7% a.m.
--  * R$/m²: tipo I (poente) 11.900; tipo II (nascente) 12.500
--  * Tabela 1 e Tabela 2, com o calendário usado na aba PV
--  * Peso e tabela de cada unidade.
--    A planilha numera os andares de 2 a 18 sem o 13º; o espelho vai de 2 a 17
--    com o 13º. Aqui a correspondência é pela ordem do andar (14º da planilha
--    = 13º do espelho ... 18º da planilha = 17º do espelho).
-- Pode ser rodado de novo para recarregar os valores.
-- =====================================================================

update public.comercial set
  mes_tabela = '2026-11-01', mes_entrega = '2030-10-01', taxa_vp = 0.007,
  comissao_pct = 0.0525, parte_sinal = 0.7, limite_captacao = -0.15,
  cidade_carta = 'Rio Verde - GO',
  texto_condicoes = $t$1. A partir desta data, até o mês da liberação do Habite-se, os valores serão reajustados pelo INCC (Índice Nacional da Construção Civil). A partir do 1º dia do mês seguinte à expedição do Habite-se, até a quitação, os valores serão reajustados mensalmente pelo IGP-M, acrescidos de juros de 1% ao mês.
2. Esta proposta será analisada pela Vendedora, que poderá recusá-la, ainda que imotivadamente.
3. A concessão do financiamento bancário está sujeita à análise de crédito e aos critérios do banco financiador. É de exclusiva responsabilidade do(s) Proponente(s) obter os recursos para a parcela de financiamento, por crédito bancário ou recursos próprios.
4. Os honorários de intermediação imobiliária serão pagos com o sinal de negócio definido nesta proposta. Em caso de recusa da proposta ou de não compensação do sinal, esta proposta perde a eficácia e a unidade fica liberada para comercialização.$t$,
  atualizado_em = now()
where id = 1;

insert into public.precos_tipo (tipo, preco_m2) values ('I', 11900), ('II', 12500)
on conflict (tipo) do update set preco_m2 = excluded.preco_m2;

insert into public.tabelas_venda (nome) values ('TABELA 1'), ('TABELA 2') on conflict do nothing;
delete from public.tabelas_series where tabela in ('TABELA 1', 'TABELA 2');
insert into public.tabelas_series (tabela, ordem, rotulo, periodicidade, qtd, percentual, base, meses) values
  ('TABELA 1', 1, 'Ato', 'Sinal', 1, 0.04, 'venda', 0),
  ('TABELA 1', 2, '30 / 60 / 90', 'Sinal', 3, 0.04, 'venda', 1),
  ('TABELA 1', 3, 'Mensais', 'Mensais', 44, 0.06, 'venda', 4),
  ('TABELA 1', 4, 'Semestrais', 'Semestrais', 7, 0.12, 'venda', 5),
  ('TABELA 1', 5, 'Única', 'Unica', 1, 0.04, 'entrega', -3),
  ('TABELA 1', 6, 'Financiamento', 'Financiamento', 1, 0.70, 'entrega', 1),
  ('TABELA 2', 1, 'Ato', 'Sinal', 1, 0.04, 'venda', 0),
  ('TABELA 2', 2, '30 / 60 / 90', 'Sinal', 3, 0.04, 'venda', 1),
  ('TABELA 2', 3, 'Mensais', 'Mensais', 44, 0.065, 'venda', 4),
  ('TABELA 2', 4, 'Semestrais', 'Semestrais', 7, 0.155, 'venda', 5),
  ('TABELA 2', 5, 'Única', 'Unica', 1, 0.05, 'entrega', -3),
  ('TABELA 2', 6, 'Financiamento', 'Financiamento', 1, 0.65, 'entrega', 1);

update public.unidades u set tipo_preco = d.tipo, peso = d.peso, tabela = d.tabela
from (values
  ('201', 'I', 0.92, 'TABELA 1'),
  ('202', 'I', 0.92, 'TABELA 1'),
  ('203', 'II', 0.92, 'TABELA 2'),
  ('204', 'II', 0.92, 'TABELA 2'),
  ('205', 'II', 0.92, 'TABELA 2'),
  ('206', 'II', 0.92, 'TABELA 2'),
  ('207', 'II', 0.92, 'TABELA 2'),
  ('208', 'II', 0.92, 'TABELA 2'),
  ('301', 'I', 0.925, 'TABELA 1'),
  ('302', 'I', 0.925, 'TABELA 1'),
  ('303', 'II', 0.925, 'TABELA 2'),
  ('304', 'II', 0.925, 'TABELA 2'),
  ('305', 'II', 0.925, 'TABELA 2'),
  ('306', 'II', 0.925, 'TABELA 2'),
  ('307', 'II', 0.925, 'TABELA 2'),
  ('308', 'II', 0.925, 'TABELA 2'),
  ('309', 'I', 0.925, 'TABELA 1'),
  ('310', 'I', 0.925, 'TABELA 1'),
  ('311', 'I', 0.925, 'TABELA 1'),
  ('401', 'I', 0.9275, 'TABELA 1'),
  ('402', 'I', 0.9275, 'TABELA 1'),
  ('403', 'II', 0.9275, 'TABELA 2'),
  ('404', 'II', 0.9275, 'TABELA 2'),
  ('405', 'II', 0.9275, 'TABELA 2'),
  ('406', 'II', 0.9275, 'TABELA 2'),
  ('407', 'II', 0.9275, 'TABELA 2'),
  ('408', 'II', 0.9275, 'TABELA 2'),
  ('409', 'I', 0.9275, 'TABELA 1'),
  ('410', 'I', 0.9275, 'TABELA 1'),
  ('411', 'I', 0.9275, 'TABELA 1'),
  ('501', 'I', 0.93, 'TABELA 1'),
  ('502', 'I', 0.93, 'TABELA 1'),
  ('503', 'II', 0.93, 'TABELA 2'),
  ('504', 'II', 0.93, 'TABELA 2'),
  ('505', 'II', 0.93, 'TABELA 2'),
  ('506', 'II', 0.93, 'TABELA 2'),
  ('507', 'II', 0.93, 'TABELA 2'),
  ('508', 'II', 0.93, 'TABELA 2'),
  ('509', 'I', 0.93, 'TABELA 1'),
  ('510', 'I', 0.93, 'TABELA 1'),
  ('511', 'I', 0.93, 'TABELA 1'),
  ('601', 'I', 0.9325, 'TABELA 1'),
  ('602', 'I', 0.9325, 'TABELA 1'),
  ('603', 'II', 0.9325, 'TABELA 2'),
  ('604', 'II', 0.9325, 'TABELA 2'),
  ('605', 'II', 0.9325, 'TABELA 2'),
  ('606', 'II', 0.9325, 'TABELA 2'),
  ('607', 'II', 0.9325, 'TABELA 2'),
  ('608', 'II', 0.9325, 'TABELA 2'),
  ('609', 'I', 0.9325, 'TABELA 1'),
  ('610', 'I', 0.9325, 'TABELA 1'),
  ('611', 'I', 0.9325, 'TABELA 1'),
  ('701', 'I', 0.935, 'TABELA 1'),
  ('702', 'I', 0.935, 'TABELA 1'),
  ('703', 'II', 0.935, 'TABELA 2'),
  ('704', 'II', 0.935, 'TABELA 2'),
  ('705', 'II', 0.935, 'TABELA 2'),
  ('706', 'II', 0.935, 'TABELA 2'),
  ('707', 'II', 0.935, 'TABELA 2'),
  ('708', 'II', 0.935, 'TABELA 2'),
  ('709', 'I', 0.935, 'TABELA 1'),
  ('710', 'I', 0.935, 'TABELA 1'),
  ('711', 'I', 0.935, 'TABELA 1'),
  ('801', 'I', 0.9375, 'TABELA 1'),
  ('802', 'I', 0.9375, 'TABELA 1'),
  ('803', 'II', 0.9375, 'TABELA 2'),
  ('804', 'II', 0.9375, 'TABELA 2'),
  ('805', 'II', 0.9375, 'TABELA 2'),
  ('806', 'II', 0.9375, 'TABELA 2'),
  ('807', 'II', 0.9375, 'TABELA 2'),
  ('808', 'II', 0.9375, 'TABELA 2'),
  ('809', 'I', 0.9375, 'TABELA 1'),
  ('810', 'I', 0.9375, 'TABELA 1'),
  ('811', 'I', 0.9375, 'TABELA 1'),
  ('901', 'I', 0.94, 'TABELA 1'),
  ('902', 'I', 0.94, 'TABELA 1'),
  ('903', 'II', 0.94, 'TABELA 2'),
  ('904', 'II', 0.94, 'TABELA 2'),
  ('905', 'II', 0.94, 'TABELA 2'),
  ('906', 'II', 0.94, 'TABELA 2'),
  ('907', 'II', 0.94, 'TABELA 2'),
  ('908', 'II', 0.94, 'TABELA 2'),
  ('909', 'I', 0.94, 'TABELA 1'),
  ('910', 'I', 0.94, 'TABELA 1'),
  ('911', 'I', 0.94, 'TABELA 1'),
  ('1001', 'I', 0.9425, 'TABELA 1'),
  ('1002', 'I', 0.9425, 'TABELA 1'),
  ('1003', 'II', 0.9425, 'TABELA 2'),
  ('1004', 'II', 0.9425, 'TABELA 2'),
  ('1005', 'II', 0.9425, 'TABELA 2'),
  ('1006', 'II', 0.9425, 'TABELA 2'),
  ('1007', 'II', 0.9425, 'TABELA 2'),
  ('1008', 'II', 0.9425, 'TABELA 2'),
  ('1009', 'I', 0.9425, 'TABELA 1'),
  ('1010', 'I', 0.9425, 'TABELA 1'),
  ('1011', 'I', 0.9425, 'TABELA 1'),
  ('1101', 'I', 0.945, 'TABELA 1'),
  ('1102', 'I', 0.945, 'TABELA 1'),
  ('1103', 'II', 0.945, 'TABELA 2'),
  ('1104', 'II', 0.945, 'TABELA 2'),
  ('1105', 'II', 0.945, 'TABELA 2'),
  ('1106', 'II', 0.945, 'TABELA 2'),
  ('1107', 'II', 0.945, 'TABELA 2'),
  ('1108', 'II', 0.945, 'TABELA 2'),
  ('1109', 'I', 0.945, 'TABELA 1'),
  ('1110', 'I', 0.945, 'TABELA 1'),
  ('1111', 'I', 0.945, 'TABELA 1'),
  ('1201', 'I', 0.9475, 'TABELA 1'),
  ('1202', 'I', 0.9475, 'TABELA 1'),
  ('1203', 'II', 0.9475, 'TABELA 2'),
  ('1204', 'II', 0.9475, 'TABELA 2'),
  ('1205', 'II', 0.9475, 'TABELA 2'),
  ('1206', 'II', 0.9475, 'TABELA 2'),
  ('1207', 'II', 0.9475, 'TABELA 2'),
  ('1208', 'II', 0.9475, 'TABELA 2'),
  ('1209', 'I', 0.9475, 'TABELA 1'),
  ('1210', 'I', 0.9475, 'TABELA 1'),
  ('1211', 'I', 0.9475, 'TABELA 1'),
  ('1301', 'I', 0.95, 'TABELA 1'),
  ('1302', 'I', 0.95, 'TABELA 1'),
  ('1303', 'II', 0.95, 'TABELA 2'),
  ('1304', 'II', 0.95, 'TABELA 2'),
  ('1305', 'II', 0.95, 'TABELA 2'),
  ('1306', 'II', 0.95, 'TABELA 2'),
  ('1307', 'II', 0.95, 'TABELA 2'),
  ('1308', 'II', 0.95, 'TABELA 2'),
  ('1309', 'I', 0.95, 'TABELA 1'),
  ('1310', 'I', 0.95, 'TABELA 1'),
  ('1311', 'I', 0.95, 'TABELA 1'),
  ('1401', 'I', 0.9525, 'TABELA 1'),
  ('1402', 'I', 0.9525, 'TABELA 1'),
  ('1403', 'II', 0.9525, 'TABELA 2'),
  ('1404', 'II', 0.9525, 'TABELA 2'),
  ('1405', 'II', 0.9525, 'TABELA 2'),
  ('1406', 'II', 0.9525, 'TABELA 2'),
  ('1407', 'II', 0.9525, 'TABELA 2'),
  ('1408', 'II', 0.9525, 'TABELA 2'),
  ('1409', 'I', 0.9525, 'TABELA 1'),
  ('1410', 'I', 0.9525, 'TABELA 1'),
  ('1411', 'I', 0.9525, 'TABELA 1'),
  ('1501', 'I', 0.9575, 'TABELA 1'),
  ('1502', 'I', 0.9575, 'TABELA 1'),
  ('1503', 'II', 0.9575, 'TABELA 2'),
  ('1504', 'II', 0.9575, 'TABELA 2'),
  ('1505', 'II', 0.9575, 'TABELA 2'),
  ('1506', 'II', 0.9575, 'TABELA 2'),
  ('1507', 'II', 0.9575, 'TABELA 2'),
  ('1508', 'II', 0.9575, 'TABELA 2'),
  ('1509', 'I', 0.9575, 'TABELA 1'),
  ('1510', 'I', 0.9575, 'TABELA 1'),
  ('1511', 'I', 0.9575, 'TABELA 1'),
  ('1601', 'I', 0.9625, 'TABELA 1'),
  ('1602', 'I', 0.9625, 'TABELA 1'),
  ('1603', 'II', 0.9625, 'TABELA 2'),
  ('1604', 'II', 0.9625, 'TABELA 2'),
  ('1605', 'II', 0.9625, 'TABELA 2'),
  ('1606', 'II', 0.9625, 'TABELA 2'),
  ('1607', 'II', 0.9625, 'TABELA 2'),
  ('1608', 'II', 0.9625, 'TABELA 2'),
  ('1609', 'I', 0.9625, 'TABELA 1'),
  ('1610', 'I', 0.9625, 'TABELA 1'),
  ('1611', 'I', 0.9625, 'TABELA 1'),
  ('1701', 'I', 0.9675, 'TABELA 1'),
  ('1702', 'I', 0.9675, 'TABELA 1'),
  ('1703', 'II', 0.9675, 'TABELA 2'),
  ('1704', 'II', 0.9675, 'TABELA 2'),
  ('1705', 'II', 0.9675, 'TABELA 2'),
  ('1706', 'II', 0.9675, 'TABELA 2'),
  ('1707', 'II', 0.9675, 'TABELA 2'),
  ('1708', 'II', 0.9675, 'TABELA 2'),
  ('1709', 'I', 0.9675, 'TABELA 1'),
  ('1710', 'I', 0.9675, 'TABELA 1'),
  ('1711', 'I', 0.9675, 'TABELA 1')
) as d(numero, tipo, peso, tabela)
where u.numero = d.numero;

-- conferência: todas as unidades do espelho precisam ter recebido preço
do $$
declare faltam text;
begin
  select string_agg(numero, ', ' order by numero) into faltam from public.unidades where tipo_preco is null or peso is null or tabela is null;
  if faltam is not null then
    raise exception 'UNIDADES_SEM_PRECO: %', faltam using hint = 'Nada foi gravado. Envie esta mensagem para o suporte.';
  end if;
end $$;

-- ####################################################################
-- origem: v2/103_carta_modelo.sql
-- ####################################################################
-- =====================================================================
-- 103 — Carta proposta no modelo novo
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

-- ####################################################################
-- origem: v2/104_novas_series.sql
-- ####################################################################
-- =====================================================================
-- 104 — Novas séries: Bimestrais, Trimestrais e Permuta
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

-- ####################################################################
-- origem: v2/105_alcadas_pv_banco.sql
-- ####################################################################
-- =====================================================================
-- 105 — Alçadas de aprovação e PV calculado pelo banco
--  * O banco recalcula o preço de tabela, o VPL da tabela e o da proposta
--    no envio (não depende mais do cálculo feito no navegador).
--  * Alçadas: PV ≥ limite automático e sinal cobrindo a comissão → aprovada
--    na hora; PV ≥ limite da Sec. Vendas → Sec. Vendas aprova; abaixo disso
--    só o administrador aprova. Limites ajustáveis na tabela "comercial".
-- Executar uma única vez no SQL Editor do Supabase (projeto de testes).
-- =====================================================================

alter table public.comercial
  add column if not exists alcada_automatica boolean not null default true,
  add column if not exists alcada_auto_pv    numeric(6, 2) not null default 100,   -- PV (% do VPL da tabela) para aprovar sozinho
  add column if not exists alcada_vendas_pv  numeric(6, 2) not null default 98;    -- a partir daqui a Sec. Vendas aprova; abaixo, só o administrador

alter table public.propostas add column if not exists alcada text check (alcada in ('automatica', 'vendas', 'admin'));

-- ---------------------------------------------------------------------
-- Cálculo (mesma regra do motor da tela, conferido contra a planilha)
-- ---------------------------------------------------------------------
create or replace function public.preco_tabela_unidade(p_unidade uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select pt.preco_m2 * u.peso * u.area_privativa
         / (select avg(x.peso) from public.unidades x where x.tipo_preco = u.tipo_preco and x.peso is not null)
    from public.unidades u join public.precos_tipo pt on pt.tipo = u.tipo_preco
   where u.id = p_unidade;
$$;

create or replace function public.passo_meses(p text) returns int language sql immutable as $$
  select case p when 'Bimestrais' then 2 when 'Trimestrais' then 3 when 'Semestrais' then 6 when 'Anuais' then 12 else 1 end;
$$;

-- meses entre duas datas (pelo mês, ignorando o dia)
create or replace function public.meses_entre(de date, ate date) returns int language sql immutable as $$
  select (extract(year from ate)::int * 12 + extract(month from ate)::int) - (extract(year from de)::int * 12 + extract(month from de)::int);
$$;

create or replace function public.pv_proposta(p_unidade uuid, p_series jsonb, p_comissao numeric default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c        public.comercial;
  u        public.unidades;
  v_preco  numeric;
  v_mes_sec int;
  v_vpl_t  numeric := 0;
  v_vpl_p  numeric := 0;
  v_total  numeric := 0;
  v_sinal  numeric := 0;
  v_com    numeric;
  s        record;
  k        int;
  v_mes    int;
  v_base   date;
begin
  select * into c from public.comercial where id = 1;
  select * into u from public.unidades where id = p_unidade;
  v_preco := public.preco_tabela_unidade(p_unidade);
  if v_preco is null or u.tabela is null then raise exception 'UNIDADE_SEM_PRECO'; end if;
  v_mes_sec := public.meses_entre(c.mes_tabela, c.mes_entrega) + 1;   -- financiamento: mês seguinte à entrega

  -- tabela
  for s in select * from public.tabelas_series where tabela = u.tabela loop
    v_base := case s.base when 'venda' then c.mes_tabela else c.mes_entrega end;
    for k in 0 .. s.qtd - 1 loop
      v_mes := case when s.periodicidade = 'Financiamento' then v_mes_sec
                    else public.meses_entre(c.mes_tabela, (v_base + make_interval(months => s.meses + k * public.passo_meses(s.periodicidade)))::date) end;
      v_vpl_t := v_vpl_t + (s.percentual * v_preco / s.qtd) / power(1 + c.taxa_vp, v_mes);
    end loop;
  end loop;

  -- proposta
  for s in select (e ->> 'qtd')::int as qtd, e ->> 'periodicidade' as periodicidade, (e ->> 'vencimento')::date as vencimento,
                  round((e ->> 'valor')::numeric, 2) as valor
             from jsonb_array_elements(p_series) e loop
    for k in 0 .. s.qtd - 1 loop
      v_mes := case when s.periodicidade = 'Financiamento' then v_mes_sec
                    else public.meses_entre(c.mes_tabela, (s.vencimento + make_interval(months => k * public.passo_meses(s.periodicidade)))::date) end;
      v_vpl_p := v_vpl_p + s.valor / power(1 + c.taxa_vp, v_mes);
      v_total := v_total + s.valor;
      if s.periodicidade = 'Sinal' then v_sinal := v_sinal + s.valor; end if;
    end loop;
  end loop;

  v_com := round(v_total * coalesce(p_comissao, c.comissao_pct), 2);
  return jsonb_build_object(
    'preco_tabela', round(v_preco, 2), 'total', round(v_total, 2),
    'vpl_tabela', round(v_vpl_t, 2), 'vpl_proposta', round(v_vpl_p, 2),
    'diferenca_vpl', round(v_vpl_p - v_vpl_t, 2),
    'pv_pct', round(v_vpl_p / nullif(v_vpl_t, 0) * 100, 2),
    'sinal', round(v_sinal, 2), 'comissao', v_com,
    'comissao_coberta', v_sinal * c.parte_sinal + 0.01 >= v_com,
    'calculado_pelo_banco', true);
end;
$$;
grant execute on function public.pv_proposta(uuid, jsonb, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- alterar_status: igual ao 016, aceitando chamadas internas do sistema
-- ---------------------------------------------------------------------
create or replace function public.alterar_status(
  p_unidade_id  uuid,
  p_status      public.status_unidade,
  p_versao      int,
  p_motivo      text    default null,
  p_imobiliaria text    default null,
  p_corretor    text    default null,
  p_cliente     text    default null,
  p_valor       numeric default null,
  p_pv          numeric default null,
  p_pasta       uuid    default null
) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  v_unidade  public.unidades;
  v_neg      public.negociacoes;
  v_pasta    public.pastas;
  v_email    text;
  v_anterior public.status_unidade;
  v_motivo   text := nullif(trim(coalesce(p_motivo, '')), '');
  v_imob     text;
  v_corretor text;
  v_cliente  text;
  v_valor    numeric;
  v_pv       numeric;
  v_detalhes jsonb;
  v_rotulo   text;
  v_codigo   text;
begin
  -- equipe, ou o próprio sistema (aprovação automática da proposta, reserva pela fila)
  if not public.eh_equipe() and current_setting('espelho.sistema', true) is distinct from 'sim' then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;

  select * into v_unidade from public.unidades where id = p_unidade_id for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  if v_unidade.versao <> p_versao then
    raise exception 'CONFLITO' using hint = 'A unidade foi alterada por outra pessoa. Recarregue.';
  end if;
  if v_unidade.status = p_status then return v_unidade; end if;

  v_anterior := v_unidade.status;
  select email into v_email from public.perfis where user_id = auth.uid();
  select * into v_neg from public.negociacoes where unidade_id = p_unidade_id and ativa for update;

  if p_status in ('disponivel', 'bloqueada', 'permutante') then
    if v_anterior not in ('disponivel', 'bloqueada', 'permutante') and v_motivo is null then
      raise exception 'MOTIVO_OBRIGATORIO';
    end if;
    if v_neg.id is not null then
      update public.negociacoes
         set ativa = false, encerrada_em = now(), motivo_encerramento = v_motivo, atualizada_em = now()
       where id = v_neg.id;
      if v_neg.pasta_id is not null then
        update public.pastas set etapa_atualizada_em = now() where id = v_neg.pasta_id;
        insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
        values (v_neg.pasta_id, 'Unidade liberada no espelho',
                jsonb_strip_nulls(jsonb_build_object('unidade', v_unidade.numero, 'motivo', v_motivo)), v_email);
      end if;
    end if;
    v_detalhes := null;
  else
    if v_neg.pasta_id is not null then
      if p_pasta is not null and p_pasta <> v_neg.pasta_id then
        raise exception 'UNIDADE_COM_OUTRA_PASTA';
      end if;
      select * into v_pasta from public.pastas where id = v_neg.pasta_id for update;
    else
      if p_pasta is null then raise exception 'PASTA_OBRIGATORIA'; end if;
      select * into v_pasta from public.pastas where id = p_pasta for update;
      if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
      if v_pasta.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
    end if;

    select i.nome into v_imob from public.imobiliarias i where i.id = v_pasta.imobiliaria_id;
    select coalesce(nullif(pf.nome, ''), pf.email) into v_corretor from public.perfis pf where pf.user_id = v_pasta.criado_por_id;
    v_imob     := coalesce(v_imob, v_neg.imobiliaria);
    v_corretor := coalesce(v_corretor, v_pasta.criado_por, v_neg.corretor);
    v_cliente  := coalesce(v_pasta.comprador_nome, v_neg.cliente);
    v_valor    := coalesce(p_valor, v_neg.valor_venda);
    v_pv       := coalesce(p_pv, v_neg.pv_aprovado);
    v_codigo   := coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo);

    if p_status = 'proposta' and (v_valor is null or v_pv is null) then
      raise exception 'DADOS_PROPOSTA_OBRIGATORIOS';
    end if;
    if v_valor is not null and v_valor <= 0 then raise exception 'VALOR_INVALIDO'; end if;
    if v_pv is not null and v_pv < 0 then raise exception 'PV_INVALIDO'; end if;

    if v_neg.id is null then
      insert into public.negociacoes (unidade_id, pasta_id, imobiliaria, corretor, cliente, valor_venda, pv_aprovado, criado_por)
      values (p_unidade_id, v_pasta.id, v_imob, v_corretor, v_cliente, v_valor, v_pv, v_email);
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (v_pasta.id, 'Unidade vinculada', jsonb_build_object('unidade', v_unidade.numero), v_email);
    else
      update public.negociacoes
         set pasta_id = v_pasta.id, imobiliaria = v_imob, corretor = v_corretor, cliente = v_cliente,
             valor_venda = v_valor, pv_aprovado = v_pv, atualizada_em = now()
       where id = v_neg.id;
    end if;

    v_rotulo := case p_status when 'reservada' then 'Reserva' when 'proposta' then 'Contrato em confecção'
                              when 'contrato' then 'Enviado para assinatura' else 'Assinado / Vendido' end;
    update public.pastas set etapa_atualizada_em = now() where id = v_pasta.id;
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (v_pasta.id, 'Etapa da venda alterada',
            jsonb_build_object('documento', v_rotulo || ' (pelo espelho)', 'unidade', v_unidade.numero), v_email);

    v_detalhes := jsonb_strip_nulls(jsonb_build_object(
      'pasta', v_codigo, 'cliente', v_cliente, 'imobiliaria', v_imob, 'corretor', v_corretor,
      'valor_venda', p_valor, 'pv_aprovado', p_pv));
  end if;

  update public.unidades
     set status = p_status, versao = versao + 1, atualizado_em = now()
   where id = p_unidade_id
  returning * into v_unidade;

  insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_id, usuario_email, detalhes)
  values (v_unidade.id, v_unidade.numero, v_anterior, p_status, v_motivo, auth.uid(), v_email, v_detalhes);

  return v_unidade;
end;
$$;

-- ---------------------------------------------------------------------
-- Aprovação (interna): leva a unidade para "Proposta recebida"
-- ---------------------------------------------------------------------
create or replace function public.aprovar_proposta_interno(p_id uuid, p_aprovador text) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v public.propostas;
  u public.unidades;
begin
  select * into v from public.propostas where id = p_id for update;
  if exists (select 1 from public.propostas where unidade_id = v.unidade_id and status = 'aprovada' and id <> v.id) then
    raise exception 'UNIDADE_COM_PROPOSTA_APROVADA';
  end if;
  select * into u from public.unidades where id = v.unidade_id;
  perform set_config('espelho.sistema', 'sim', true);
  if u.status in ('disponivel', 'reservada') then
    perform public.alterar_status(u.id, 'proposta', u.versao, null, null, null, null,
      (v.resumo ->> 'total')::numeric, round((v.resumo ->> 'pv_pct')::numeric, 2), v.pasta_id);
  elsif u.status <> 'proposta' then
    perform set_config('espelho.sistema', '', true);
    raise exception 'UNIDADE_INDISPONIVEL' using hint = 'A unidade está em outra etapa no espelho.';
  end if;
  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas
     set status = 'aprovada', motivo_analise = null, analisada_por = p_aprovador, analisada_em = now()
   where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);
  perform set_config('espelho.sistema', '', true);
  return v;
end;
$$;
revoke all on function public.aprovar_proposta_interno(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Enviar: o banco recalcula o PV e define a alçada
-- ---------------------------------------------------------------------
create or replace function public.enviar_proposta(p_id uuid) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v   public.propostas;
  c   public.comercial;
  r   jsonb;
  v_alcada text;
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

  select * into c from public.comercial where id = 1;
  r := public.pv_proposta(v.unidade_id, v.series, v.comissao_pct);
  v_alcada := case
    when c.alcada_automatica and (r ->> 'pv_pct')::numeric >= c.alcada_auto_pv and (r ->> 'comissao_coberta')::boolean then 'automatica'
    when (r ->> 'pv_pct')::numeric >= c.alcada_vendas_pv then 'vendas'
    else 'admin' end;

  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas
     set status = 'enviada', enviada_em = now(), motivo_analise = null, alcada = v_alcada,
         resumo = coalesce(resumo, '{}') || r
   where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);

  if v_alcada = 'automatica' then
    v := public.aprovar_proposta_interno(p_id, 'Aprovação automática (PV ' || (r ->> 'pv_pct') || '%)');
  end if;
  return v;
end;
$$;
revoke all on function public.enviar_proposta(uuid) from public, anon;
grant execute on function public.enviar_proposta(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Análise pela equipe, respeitando a alçada
-- ---------------------------------------------------------------------
create or replace function public.analisar_proposta(p_id uuid, p_decisao text, p_motivo text default null) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v public.propostas;
  v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_decisao not in ('aprovada', 'recusada', 'devolvida', 'cancelada') then raise exception 'DECISAO_INVALIDA'; end if;
  select * into v from public.propostas where id = p_id for update;
  if not found then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  if p_decisao in ('recusada', 'devolvida', 'cancelada') and v_motivo is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  if p_decisao in ('aprovada', 'recusada', 'devolvida') and v.status <> 'enviada' then raise exception 'PROPOSTA_NAO_ENVIADA'; end if;

  if p_decisao = 'aprovada' then
    if v.alcada = 'admin' and not public.eh_admin() then
      raise exception 'ALCADA_ADMIN' using hint = 'PV abaixo do limite da Sec. Vendas: só o administrador aprova.';
    end if;
    return public.aprovar_proposta_interno(p_id, (select email from public.perfis where user_id = auth.uid()));
  end if;

  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas
     set status = p_decisao, motivo_analise = v_motivo,
         analisada_por = (select email from public.perfis where user_id = auth.uid()), analisada_em = now()
   where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);
  return v;
end;
$$;
revoke all on function public.analisar_proposta(uuid, text, text) from public, anon;
grant execute on function public.analisar_proposta(uuid, text, text) to authenticated;

-- ####################################################################
-- Chave liga/desliga: com o módulo desligado, só a equipe cria proposta
-- ####################################################################
create or replace function public.propostas_modulo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_equipe() and not coalesce((select modulo_propostas from public.config where id = 1), false) then
    raise exception 'MODULO_DESLIGADO' using hint = 'As propostas ainda não estão liberadas.';
  end if;
  return new;
end;
$$;
drop trigger if exists propostas_0_modulo on public.propostas;
-- "0" no nome: roda antes dos outros gatilhos (ordem alfabética)
create trigger propostas_0_modulo before insert on public.propostas
  for each row execute function public.propostas_modulo();

-- preços só para quem tem login (a v2 deixava estas funções abertas)
revoke all on function public.pv_proposta(uuid, jsonb, numeric), public.preco_tabela_unidade(uuid) from public, anon;
grant execute on function public.pv_proposta(uuid, jsonb, numeric), public.preco_tabela_unidade(uuid) to authenticated;

commit;

-- >>>>> supabase/migrations/036_propostas_permissao.sql
-- =====================================================================
-- 036 — Corrige o salvar de Empreendimento depois do 035
-- O 035 criou a chave "modulo_propostas", mas não liberou a gravação dela.
-- Como a tela de Empreendimento salva todas as chaves juntas, qualquer
-- mudança de módulo dava erro. Executar uma única vez no SQL Editor.
-- =====================================================================
grant update (modulo_propostas) on public.config to authenticated;

-- >>>>> supabase/migrations/037_rodadas_convite.sql
-- =====================================================================
-- 037 — Convite da rodada de negócios
--  * O administrador anexa o convite (imagem ou PDF) à rodada.
--  * Quem pode baixar: a equipe, e o corretor ou a imobiliária que tem pelo
--    menos um cliente confirmado (não cancelado) naquela rodada.
--  * Arquivo em bucket privado ("rodadas"), baixado por link temporário.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.rodadas
  add column if not exists convite_caminho text,
  add column if not exists convite_nome    text,
  add column if not exists convite_tipo    text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rodadas', 'rodadas', false, 20971520, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false;

-- Pode baixar o convite desta rodada?
create or replace function public.pode_baixar_convite(p_rodada uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe() or exists (
    select 1 from public.rodada_inscricoes i
     where i.rodada_id = p_rodada and not i.cancelada
       and i.imobiliaria_id = public.minha_imobiliaria()
       and (public.eh_gestor() or i.corretor_id = auth.uid()));
$$;

-- Arquivo "<id da rodada>/<nome>" no bucket
create or replace function public.convite_liberado(p_nome text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_id text := split_part(p_nome, '/', 1);
begin
  if v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  return public.pode_baixar_convite(v_id::uuid);
end;
$$;
revoke all on function public.pode_baixar_convite(uuid), public.convite_liberado(text) from public, anon;
grant execute on function public.pode_baixar_convite(uuid), public.convite_liberado(text) to authenticated;

drop policy if exists rodadas_convite_leitura on storage.objects;
drop policy if exists rodadas_convite_envio on storage.objects;
drop policy if exists rodadas_convite_remocao on storage.objects;
create policy rodadas_convite_leitura on storage.objects for select to authenticated
  using (bucket_id = 'rodadas' and public.convite_liberado(name));
create policy rodadas_convite_envio on storage.objects for insert to authenticated
  with check (bucket_id = 'rodadas' and public.eh_admin());
create policy rodadas_convite_remocao on storage.objects for delete to authenticated
  using (bucket_id = 'rodadas' and public.eh_admin());

-- Grava (ou tira) o convite da rodada; devolve o arquivo anterior para a tela apagar
create or replace function public.definir_convite_rodada(p_rodada uuid, p_caminho text, p_nome text default null, p_tipo text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_antigo text;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select convite_caminho into v_antigo from public.rodadas where id = p_rodada for update;
  if not found then raise exception 'RODADA_NAO_ENCONTRADA'; end if;
  if p_caminho is not null and split_part(p_caminho, '/', 1) <> p_rodada::text then raise exception 'CAMINHO_INVALIDO'; end if;
  update public.rodadas
     set convite_caminho = p_caminho,
         convite_nome = case when p_caminho is null then null else left(coalesce(p_nome, 'convite'), 200) end,
         convite_tipo = case when p_caminho is null then null else p_tipo end
   where id = p_rodada;
  return case when v_antigo is distinct from p_caminho then v_antigo end;
end;
$$;
revoke all on function public.definir_convite_rodada(uuid, text, text, text) from public, anon;
grant execute on function public.definir_convite_rodada(uuid, text, text, text) to authenticated;

-- >>>>> supabase/migrations/038_dados_contrato.sql
-- =====================================================================
-- 038 — Dados para contrato (leitura dos documentos com IA)
--  * Depois que a pasta tem proposta APROVADA, a equipe (administrador e
--    Sec. Vendas) abre "Dados para contrato" e pede para a IA ler os
--    documentos da pasta. A IA sugere; a equipe confere e marca "Conferido".
--  * Corretor e imobiliária não veem estes dados.
--  * Cada leitura fica registrada (quem, quando, modelo e tokens).
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create table if not exists public.dados_contrato (
  pasta_id      uuid primary key references public.pastas(id) on delete cascade,
  dados         jsonb not null default '{}'::jsonb,
  fontes        jsonb not null default '{}'::jsonb,
  alertas       jsonb not null default '[]'::jsonb,
  status        text not null default 'rascunho' check (status in ('rascunho', 'conferido')),
  lido_em       timestamptz,
  lido_por      text,
  conferido_em  timestamptz,
  conferido_por text,
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
alter table public.dados_contrato enable row level security;
drop policy if exists dados_contrato_equipe on public.dados_contrato;
create policy dados_contrato_equipe on public.dados_contrato for select using (public.eh_equipe());
revoke all on public.dados_contrato from anon, authenticated;
grant select on public.dados_contrato to authenticated;

create table if not exists public.ia_leituras (
  id              bigint generated always as identity primary key,
  pasta_id        uuid references public.pastas(id) on delete set null,
  usuario_email   text,
  modelo          text,
  documentos      int,
  tokens_entrada  int,
  tokens_saida    int,
  criado_em       timestamptz not null default now()
);
alter table public.ia_leituras enable row level security;
drop policy if exists ia_leituras_admin on public.ia_leituras;
create policy ia_leituras_admin on public.ia_leituras for select using (public.eh_admin());
revoke all on public.ia_leituras from anon, authenticated;
grant select on public.ia_leituras to authenticated;

-- A pasta já tem proposta aprovada?
create or replace function public.contrato_liberado(p_pasta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.propostas where pasta_id = p_pasta and status = 'aprovada');
$$;

-- O que a IA precisa: dados digitados na pasta + lista de documentos atuais (só equipe, só com proposta aprovada)
create or replace function public.documentos_para_leitura(p_pasta uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  select jsonb_build_object(
    'pasta', jsonb_build_object('codigo', p.codigo, 'estado_civil', p.estado_civil,
      'comprador', jsonb_build_object('nome', p.comprador_nome, 'cpf', p.comprador_cpf, 'nascimento', p.comprador_nascimento,
                                      'email', p.comprador_email, 'telefone', p.comprador_telefone, 'profissao', p.comprador_profissao),
      'conjuge', jsonb_build_object('nome', p.conjuge_nome, 'cpf', p.conjuge_cpf, 'nascimento', p.conjuge_nascimento,
                                    'email', p.conjuge_email, 'telefone', p.conjuge_telefone, 'profissao', p.conjuge_profissao)),
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'caminho', d.caminho, 'arquivo', d.nome_arquivo,
                                 'mime', d.mime, 'tipo', t.nome, 'pessoa', t.pessoa) order by t.ordem, d.enviado_em)
                              from public.documentos d join public.tipos_documento t on t.id = d.tipo_id
                             where d.pasta_id = p.id and d.atual and d.status <> 'recusado'), '[]'::jsonb))
    into v from public.pastas p where p.id = p_pasta;
  if v is null then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  return v;
end;
$$;

-- Grava o resultado da leitura (substitui a sugestão anterior; volta para "rascunho")
create or replace function public.gravar_leitura_ia(p_pasta uuid, p_dados jsonb, p_fontes jsonb, p_alertas jsonb,
                                                    p_modelo text, p_documentos int, p_tokens_entrada int, p_tokens_saida int)
returns public.dados_contrato language plpgsql security definer set search_path = public as $$
declare v public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  insert into public.dados_contrato as d (pasta_id, dados, fontes, alertas, status, lido_em, lido_por, atualizado_em, atualizado_por)
  values (p_pasta, coalesce(p_dados, '{}'), coalesce(p_fontes, '{}'), coalesce(p_alertas, '[]'), 'rascunho', now(), public.meu_email(), now(), public.meu_email())
  on conflict (pasta_id) do update set dados = excluded.dados, fontes = excluded.fontes, alertas = excluded.alertas,
     status = 'rascunho', lido_em = now(), lido_por = public.meu_email(), conferido_em = null, conferido_por = null,
     atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  insert into public.ia_leituras (pasta_id, usuario_email, modelo, documentos, tokens_entrada, tokens_saida)
  values (p_pasta, public.meu_email(), left(p_modelo, 60), p_documentos, p_tokens_entrada, p_tokens_saida);
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Documentos lidos com IA', jsonb_build_object('documentos', p_documentos), public.meu_email());
  return v;
end;
$$;

-- A equipe corrige os campos e, se quiser, marca como conferido
create or replace function public.salvar_dados_contrato(p_pasta uuid, p_dados jsonb, p_conferido boolean default false)
returns public.dados_contrato language plpgsql security definer set search_path = public as $$
declare v public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  insert into public.dados_contrato as d (pasta_id, dados, status, conferido_em, conferido_por, atualizado_em, atualizado_por)
  values (p_pasta, coalesce(p_dados, '{}'), case when p_conferido then 'conferido' else 'rascunho' end,
          case when p_conferido then now() end, case when p_conferido then public.meu_email() end, now(), public.meu_email())
  on conflict (pasta_id) do update set dados = excluded.dados, status = excluded.status,
     conferido_em = excluded.conferido_em, conferido_por = excluded.conferido_por,
     atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  if p_conferido then
    insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
    values (p_pasta, 'Dados para contrato conferidos', null, public.meu_email());
  end if;
  return v;
end;
$$;

revoke all on function public.contrato_liberado(uuid), public.documentos_para_leitura(uuid),
  public.gravar_leitura_ia(uuid, jsonb, jsonb, jsonb, text, int, int, int), public.salvar_dados_contrato(uuid, jsonb, boolean) from public, anon;
grant execute on function public.contrato_liberado(uuid), public.documentos_para_leitura(uuid),
  public.gravar_leitura_ia(uuid, jsonb, jsonb, jsonb, text, int, int, int), public.salvar_dados_contrato(uuid, jsonb, boolean) to authenticated;

-- >>>>> supabase/migrations/039_regime_bens.sql
-- =====================================================================
-- 039 — Regime de bens e participação do cônjuge
--  * Casado(a) ou união estável: informar o regime de bens.
--  * Separação total ou obrigatória: o cliente escolhe se o cônjuge
--    participa do contrato. Se não participa, os dados e documentos do
--    cônjuge deixam de ser exigidos (a certidão de casamento continua).
--  * Pastas antigas sem regime seguem exigindo o cônjuge, como hoje;
--    o regime passa a ser exigido ao submeter.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================
begin;

alter table public.pastas add column if not exists regime_bens text
  check (regime_bens is null or regime_bens in ('comunhao_parcial', 'comunhao_universal', 'separacao_total', 'separacao_obrigatoria', 'participacao_aquestos'));
alter table public.pastas add column if not exists conjuge_participa boolean not null default true;
grant insert (regime_bens, conjuge_participa), update (regime_bens, conjuge_participa) on public.pastas to authenticated;

-- O cônjuge entra no contrato (dados e documentos exigidos)?
create or replace function public.conjuge_no_contrato(p_ec public.estado_civil, p_regime text, p_participa boolean)
returns boolean language sql immutable as $$
  select p_ec in ('casado', 'uniao_estavel')
     and (coalesce(p_regime, '') not in ('separacao_total', 'separacao_obrigatoria') or coalesce(p_participa, true));
$$;
grant execute on function public.conjuge_no_contrato(public.estado_civil, text, boolean) to authenticated;

create or replace function public.pastas_antes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := public.meu_email();
    new.criado_por_id := auth.uid();
  end if;

  if tg_op = 'INSERT'
     or (new.comprador_nome, new.comprador_cpf, new.comprador_nascimento, new.comprador_telefone,
         new.comprador_email, new.comprador_profissao, new.estado_civil, new.observacoes)
        is distinct from
        (old.comprador_nome, old.comprador_cpf, old.comprador_nascimento, old.comprador_telefone,
         old.comprador_email, old.comprador_profissao, old.estado_civil, old.observacoes) then
    if length(trim(coalesce(new.comprador_telefone, ''))) < 10
       or length(trim(coalesce(new.comprador_email, ''))) <= 3
       or length(trim(coalesce(new.comprador_profissao, ''))) <= 1 then
      raise exception 'DADOS_INCOMPLETOS' using hint = 'Telefone, e-mail e profissão do comprador são obrigatórios.';
    end if;
  end if;

  new.atualizada_em := now();
  if new.estado_civil not in ('casado', 'uniao_estavel') then new.regime_bens := null; end if;
  if coalesce(new.regime_bens, '') not in ('separacao_total', 'separacao_obrigatoria') then new.conjuge_participa := true; end if;
  if not public.conjuge_no_contrato(new.estado_civil, new.regime_bens, new.conjuge_participa) then
    new.conjuge_nome := null; new.conjuge_cpf := null; new.conjuge_nascimento := null;
    new.conjuge_telefone := null; new.conjuge_email := null; new.conjuge_profissao := null;
  end if;
  return new;
end;
$$;

create or replace function public.recalcular_pasta(p_pasta uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ec        public.estado_civil;
  v_conjuge   boolean;
  v_submetida boolean;
  v_status    text;
  v_faltando  int;
  v_recusado  int;
  v_analise   int;
  v_enviado   int;
begin
  select estado_civil, public.conjuge_no_contrato(estado_civil, regime_bens, conjuge_participa), codigo_aprovacao is not null
    into v_ec, v_conjuge, v_submetida from public.pastas where id = p_pasta;

  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo and v_ec = any (t.obrigatorio_para)
     and (t.pessoa <> 'conjuge' or v_conjuge)
     and not exists (select 1 from public.documentos d where d.pasta_id = p_pasta and d.tipo_id = t.id and d.atual);
  select count(*) into v_recusado from public.documentos where pasta_id = p_pasta and atual and status = 'recusado';
  select count(*) into v_analise  from public.documentos where pasta_id = p_pasta and atual and status = 'em_analise';
  select count(*) into v_enviado  from public.documentos where pasta_id = p_pasta and atual and status = 'enviado';

  if not v_submetida then
    v_status := case when v_faltando > 0 then 'incompleta' else 'pronta' end;
  else
    v_status := case
      when v_recusado > 0 then 'pendente_correcao'
      when v_faltando > 0 then 'incompleta'
      when v_analise > 0 then 'em_analise'
      when v_enviado > 0 then 'aguardando_analise'
      else 'aprovada' end;
  end if;

  update public.pastas set status = v_status where id = p_pasta and status is distinct from v_status;
  return v_status;
end;
$$;

create or replace function public.submeter_pasta(p_pasta uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v_pasta.codigo_aprovacao is not null then raise exception 'JA_SUBMETIDA'; end if;
  if length(trim(coalesce(v_pasta.comprador_telefone, ''))) < 10
     or length(trim(coalesce(v_pasta.comprador_email, ''))) <= 3
     or length(trim(coalesce(v_pasta.comprador_profissao, ''))) <= 1 then
    raise exception 'DADOS_INCOMPLETOS';
  end if;
  if v_pasta.estado_civil in ('casado', 'uniao_estavel') and v_pasta.regime_bens is null then
    raise exception 'REGIME_NAO_INFORMADO';
  end if;
  if public.conjuge_no_contrato(v_pasta.estado_civil, v_pasta.regime_bens, v_pasta.conjuge_participa)
     and (length(trim(coalesce(v_pasta.conjuge_nome, ''))) <= 1
          or v_pasta.conjuge_cpf is null
          or length(trim(coalesce(v_pasta.conjuge_profissao, ''))) <= 1) then
    raise exception 'DADOS_CONJUGE_INCOMPLETOS';
  end if;
  if public.recalcular_pasta(p_pasta) <> 'pronta' then raise exception 'DOCUMENTOS_FALTANDO'; end if;

  update public.pastas
     set codigo_aprovacao = public.formatar_codigo('PA', nextval('public.pastas_aprovacao_seq')),
         submetida_em = now(), submetida_por = public.meu_email()
   where id = p_pasta
  returning * into v_pasta;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pasta submetida ao incorporador', jsonb_build_object('codigo', v_pasta.codigo_aprovacao), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$$;

create or replace function public.pastas_depois() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_campos text[];
begin
  if tg_op = 'INSERT' then
    insert into public.historico_pastas (pasta_id, acao, usuario_email) values (new.id, 'Pasta criada', public.meu_email());
    perform public.recalcular_pasta(new.id);
  else
    select array_agg(n.key order by n.key) into v_campos
      from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value
       and n.key not in ('status', 'atualizada_em', 'unidade_id', 'codigo_aprovacao', 'submetida_em', 'submetida_por',
                         'etapa_venda', 'etapa_atualizada_em', 'unidades_numeros');
    if v_campos is not null then
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (new.id, 'Dados alterados', jsonb_build_object('campos', v_campos), public.meu_email());
    end if;
    if (new.estado_civil, new.regime_bens, new.conjuge_participa) is distinct from (old.estado_civil, old.regime_bens, old.conjuge_participa) then
      perform public.recalcular_pasta(new.id);
    end if;
  end if;
  return null;
end;
$$;

-- Leitura com IA: passa também o regime e se o cônjuge participa
create or replace function public.documentos_para_leitura(p_pasta uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  select jsonb_build_object(
    'pasta', jsonb_build_object('codigo', p.codigo, 'estado_civil', p.estado_civil, 'regime_bens', p.regime_bens,
      'conjuge_no_contrato', public.conjuge_no_contrato(p.estado_civil, p.regime_bens, p.conjuge_participa),
      'comprador', jsonb_build_object('nome', p.comprador_nome, 'cpf', p.comprador_cpf, 'nascimento', p.comprador_nascimento,
                                      'email', p.comprador_email, 'telefone', p.comprador_telefone, 'profissao', p.comprador_profissao),
      'conjuge', jsonb_build_object('nome', p.conjuge_nome, 'cpf', p.conjuge_cpf, 'nascimento', p.conjuge_nascimento,
                                    'email', p.conjuge_email, 'telefone', p.conjuge_telefone, 'profissao', p.conjuge_profissao)),
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'caminho', d.caminho, 'arquivo', d.nome_arquivo,
                                 'mime', d.mime, 'tipo', t.nome, 'pessoa', t.pessoa) order by t.ordem, d.enviado_em)
                              from public.documentos d join public.tipos_documento t on t.id = d.tipo_id
                             where d.pasta_id = p.id and d.atual and d.status <> 'recusado'), '[]'::jsonb))
    into v from public.pastas p where p.id = p_pasta;
  if v is null then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  return v;
end;
$$;

commit;

-- >>>>> supabase/migrations/040_pessoa_juridica.sql
-- =====================================================================
-- 040 — Comprador Pessoa Jurídica
--  * A pasta passa a ter tipo_pessoa: 'pf' (padrão) ou 'pj'.
--  * PJ: razão social e CNPJ da empresa; os campos do comprador
--    (nome, CPF, nascimento, telefone, e-mail, profissão, estado civil)
--    passam a ser do REPRESENTANTE LEGAL. Cônjuge não entra no contrato.
--  * Documentos por tipo: contrato social, cartão CNPJ e comprovante de
--    endereço da empresa para PJ; certidões de estado civil só para PF.
-- Executar uma única vez no SQL Editor do Supabase (depois da 039).
-- =====================================================================
begin;

alter table public.pastas add column if not exists tipo_pessoa text not null default 'pf' check (tipo_pessoa in ('pf', 'pj'));
alter table public.pastas add column if not exists empresa_razao_social text;
alter table public.pastas add column if not exists empresa_cnpj text check (empresa_cnpj is null or empresa_cnpj ~ '^[0-9]{14}$');
alter table public.pastas drop constraint if exists pastas_pj_completa;
alter table public.pastas add constraint pastas_pj_completa check (
  tipo_pessoa = 'pf' or (length(trim(coalesce(empresa_razao_social, ''))) > 1 and empresa_cnpj is not null));
grant insert (tipo_pessoa, empresa_razao_social, empresa_cnpj), update (tipo_pessoa, empresa_razao_social, empresa_cnpj) on public.pastas to authenticated;

-- Documentos: a quem se aplicam e se são obrigatórios para PJ
alter table public.tipos_documento add column if not exists aplica_a text not null default 'pf' check (aplica_a in ('pf', 'pj', 'ambos'));
alter table public.tipos_documento add column if not exists obrigatorio_pj boolean not null default false;
update public.tipos_documento set aplica_a = 'ambos', obrigatorio_pj = true  where nome in ('RG ou CNH', 'Comprovante de endereço', 'Comprovante do PIX');
update public.tipos_documento set aplica_a = 'ambos', obrigatorio_pj = false where nome in ('CPF (se não constar no RG/CNH)', 'Procuração');
insert into public.tipos_documento (nome, pessoa, aplica_a, obrigatorio_pj, ordem, sigla)
select v.nome, 'comprador', 'pj', v.obrig, v.ordem, v.sigla
  from (values ('Contrato social e última alteração', true, 1, 'CONTRATO_SOCIAL'),
               ('Cartão CNPJ', true, 2, 'CARTAO_CNPJ'),
               ('Comprovante de endereço da empresa', true, 3, 'ENDERECO_EMPRESA')) v(nome, obrig, ordem, sigla)
 where not exists (select 1 from public.tipos_documento t where t.nome = v.nome);

-- O cônjuge entra no contrato? (PJ: nunca)
drop function if exists public.conjuge_no_contrato(public.estado_civil, text, boolean);
create or replace function public.conjuge_no_contrato(p_ec public.estado_civil, p_regime text, p_participa boolean, p_tipo text default 'pf')
returns boolean language sql immutable as $$
  select coalesce(p_tipo, 'pf') = 'pf' and p_ec in ('casado', 'uniao_estavel')
     and (coalesce(p_regime, '') not in ('separacao_total', 'separacao_obrigatoria') or coalesce(p_participa, true));
$$;
grant execute on function public.conjuge_no_contrato(public.estado_civil, text, boolean, text) to authenticated;

create or replace function public.pastas_antes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := public.meu_email();
    new.criado_por_id := auth.uid();
  end if;

  if tg_op = 'INSERT'
     or (new.comprador_nome, new.comprador_cpf, new.comprador_nascimento, new.comprador_telefone,
         new.comprador_email, new.comprador_profissao, new.estado_civil, new.observacoes)
        is distinct from
        (old.comprador_nome, old.comprador_cpf, old.comprador_nascimento, old.comprador_telefone,
         old.comprador_email, old.comprador_profissao, old.estado_civil, old.observacoes) then
    if length(trim(coalesce(new.comprador_telefone, ''))) < 10
       or length(trim(coalesce(new.comprador_email, ''))) <= 3
       or length(trim(coalesce(new.comprador_profissao, ''))) <= 1 then
      raise exception 'DADOS_INCOMPLETOS' using hint = 'Telefone, e-mail e profissão do comprador são obrigatórios.';
    end if;
  end if;

  new.atualizada_em := now();
  if new.tipo_pessoa = 'pf' then new.empresa_razao_social := null; new.empresa_cnpj := null; end if;
  if new.estado_civil not in ('casado', 'uniao_estavel') then new.regime_bens := null; end if;
  if coalesce(new.regime_bens, '') not in ('separacao_total', 'separacao_obrigatoria') then new.conjuge_participa := true; end if;
  if not public.conjuge_no_contrato(new.estado_civil, new.regime_bens, new.conjuge_participa, new.tipo_pessoa) then
    new.conjuge_nome := null; new.conjuge_cpf := null; new.conjuge_nascimento := null;
    new.conjuge_telefone := null; new.conjuge_email := null; new.conjuge_profissao := null;
  end if;
  return new;
end;
$$;

create or replace function public.recalcular_pasta(p_pasta uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ec        public.estado_civil;
  v_tipo      text;
  v_conjuge   boolean;
  v_submetida boolean;
  v_status    text;
  v_faltando  int;
  v_recusado  int;
  v_analise   int;
  v_enviado   int;
begin
  select estado_civil, tipo_pessoa, public.conjuge_no_contrato(estado_civil, regime_bens, conjuge_participa, tipo_pessoa), codigo_aprovacao is not null
    into v_ec, v_tipo, v_conjuge, v_submetida from public.pastas where id = p_pasta;

  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo
     and case when v_tipo = 'pj' then t.aplica_a in ('pj', 'ambos') and t.obrigatorio_pj
              else t.aplica_a in ('pf', 'ambos') and v_ec = any (t.obrigatorio_para) and (t.pessoa <> 'conjuge' or v_conjuge) end
     and not exists (select 1 from public.documentos d where d.pasta_id = p_pasta and d.tipo_id = t.id and d.atual);
  select count(*) into v_recusado from public.documentos where pasta_id = p_pasta and atual and status = 'recusado';
  select count(*) into v_analise  from public.documentos where pasta_id = p_pasta and atual and status = 'em_analise';
  select count(*) into v_enviado  from public.documentos where pasta_id = p_pasta and atual and status = 'enviado';

  if not v_submetida then
    v_status := case when v_faltando > 0 then 'incompleta' else 'pronta' end;
  else
    v_status := case
      when v_recusado > 0 then 'pendente_correcao'
      when v_faltando > 0 then 'incompleta'
      when v_analise > 0 then 'em_analise'
      when v_enviado > 0 then 'aguardando_analise'
      else 'aprovada' end;
  end if;

  update public.pastas set status = v_status where id = p_pasta and status is distinct from v_status;
  return v_status;
end;
$$;

create or replace function public.submeter_pasta(p_pasta uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v_pasta.codigo_aprovacao is not null then raise exception 'JA_SUBMETIDA'; end if;
  if length(trim(coalesce(v_pasta.comprador_telefone, ''))) < 10
     or length(trim(coalesce(v_pasta.comprador_email, ''))) <= 3
     or length(trim(coalesce(v_pasta.comprador_profissao, ''))) <= 1 then
    raise exception 'DADOS_INCOMPLETOS';
  end if;
  if v_pasta.tipo_pessoa = 'pf' and v_pasta.estado_civil in ('casado', 'uniao_estavel') and v_pasta.regime_bens is null then
    raise exception 'REGIME_NAO_INFORMADO';
  end if;
  if public.conjuge_no_contrato(v_pasta.estado_civil, v_pasta.regime_bens, v_pasta.conjuge_participa, v_pasta.tipo_pessoa)
     and (length(trim(coalesce(v_pasta.conjuge_nome, ''))) <= 1
          or v_pasta.conjuge_cpf is null
          or length(trim(coalesce(v_pasta.conjuge_profissao, ''))) <= 1) then
    raise exception 'DADOS_CONJUGE_INCOMPLETOS';
  end if;
  if public.recalcular_pasta(p_pasta) <> 'pronta' then raise exception 'DOCUMENTOS_FALTANDO'; end if;

  update public.pastas
     set codigo_aprovacao = public.formatar_codigo('PA', nextval('public.pastas_aprovacao_seq')),
         submetida_em = now(), submetida_por = public.meu_email()
   where id = p_pasta
  returning * into v_pasta;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pasta submetida ao incorporador', jsonb_build_object('codigo', v_pasta.codigo_aprovacao), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$$;

create or replace function public.pastas_depois() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_campos text[];
begin
  if tg_op = 'INSERT' then
    insert into public.historico_pastas (pasta_id, acao, usuario_email) values (new.id, 'Pasta criada', public.meu_email());
    perform public.recalcular_pasta(new.id);
  else
    select array_agg(n.key order by n.key) into v_campos
      from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value
       and n.key not in ('status', 'atualizada_em', 'unidade_id', 'codigo_aprovacao', 'submetida_em', 'submetida_por',
                         'etapa_venda', 'etapa_atualizada_em', 'unidades_numeros');
    if v_campos is not null then
      insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
      values (new.id, 'Dados alterados', jsonb_build_object('campos', v_campos), public.meu_email());
    end if;
    if (new.estado_civil, new.regime_bens, new.conjuge_participa, new.tipo_pessoa)
       is distinct from (old.estado_civil, old.regime_bens, old.conjuge_participa, old.tipo_pessoa) then
      perform public.recalcular_pasta(new.id);
    end if;
  end if;
  return null;
end;
$$;

-- Leitura com IA: inclui empresa (PJ)
create or replace function public.documentos_para_leitura(p_pasta uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  select jsonb_build_object(
    'pasta', jsonb_build_object('codigo', p.codigo, 'tipo_pessoa', p.tipo_pessoa, 'estado_civil', p.estado_civil, 'regime_bens', p.regime_bens,
      'conjuge_no_contrato', public.conjuge_no_contrato(p.estado_civil, p.regime_bens, p.conjuge_participa, p.tipo_pessoa),
      'empresa', case when p.tipo_pessoa = 'pj' then jsonb_build_object('razao_social', p.empresa_razao_social, 'cnpj', p.empresa_cnpj) end,
      'comprador', jsonb_build_object('nome', p.comprador_nome, 'cpf', p.comprador_cpf, 'nascimento', p.comprador_nascimento,
                                      'email', p.comprador_email, 'telefone', p.comprador_telefone, 'profissao', p.comprador_profissao),
      'conjuge', jsonb_build_object('nome', p.conjuge_nome, 'cpf', p.conjuge_cpf, 'nascimento', p.conjuge_nascimento,
                                    'email', p.conjuge_email, 'telefone', p.conjuge_telefone, 'profissao', p.conjuge_profissao)),
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'caminho', d.caminho, 'arquivo', d.nome_arquivo,
                                 'mime', d.mime, 'tipo', t.nome, 'pessoa', t.pessoa) order by t.ordem, d.enviado_em)
                              from public.documentos d join public.tipos_documento t on t.id = d.tipo_id
                             where d.pasta_id = p.id and d.atual and d.status <> 'recusado'), '[]'::jsonb))
    into v from public.pastas p where p.id = p_pasta;
  if v is null then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  return v;
end;
$$;

commit;

-- >>>>> supabase/migrations/041_contratos.sql
-- =====================================================================
-- 041 — Módulo de contratos
--  * empreendimento_contrato: dados da vendedora e do empreendimento usados
--    no Quadro Resumo (uma linha; edita só o administrador).
--  * unidade_areas: quadro de áreas por unidade (importado da planilha no
--    cadastro do empreendimento; substitui o quadro inteiro).
--  * dados_contrato ganha comissão (beneficiários) e conferência do fluxo
--    de pagamento.
--  * contratos: cada PDF emitido (Quadro Resumo, Normas), com número,
--    validação, assinatura (D4Sign na próxima fase) e cancelamento.
--  * Tudo restrito à equipe (administrador e Sec. Vendas).
-- Executar uma única vez no SQL Editor do Supabase (depois da 040).
-- =====================================================================
begin;

-- Dados da vendedora / empreendimento --------------------------------
create table if not exists public.empreendimento_contrato (
  id             smallint primary key default 1 check (id = 1),
  dados          jsonb not null default '{}'::jsonb,
  atualizado_em  timestamptz not null default now(),
  atualizado_por text
);
alter table public.empreendimento_contrato enable row level security;
drop policy if exists empreendimento_contrato_equipe on public.empreendimento_contrato;
create policy empreendimento_contrato_equipe on public.empreendimento_contrato for select using (public.eh_equipe());
revoke all on public.empreendimento_contrato from anon, authenticated;
grant select on public.empreendimento_contrato to authenticated;

create or replace function public.salvar_empreendimento_contrato(p_dados jsonb) returns public.empreendimento_contrato
language plpgsql security definer set search_path = public as $$
declare v public.empreendimento_contrato;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.empreendimento_contrato (id, dados, atualizado_em, atualizado_por)
  values (1, coalesce(p_dados, '{}'), now(), public.meu_email())
  on conflict (id) do update set dados = excluded.dados, atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  return v;
end;
$$;

-- Quadro de áreas -------------------------------------------------------
create table if not exists public.unidade_areas (
  numero               text primary key,
  torre                text,
  pavimento            text,
  area_privativa       numeric(12,4),
  area_acessoria       numeric(12,4),
  area_privativa_total numeric(12,4),
  area_comum           numeric(12,4),
  area_total           numeric(12,4),
  fracao_ideal         numeric(14,10),
  vagas                text,
  escaninho            text,
  escaninho_local      text,
  escaninho_area       numeric(10,4),
  atualizado_em        timestamptz not null default now()
);
alter table public.unidade_areas enable row level security;
drop policy if exists unidade_areas_equipe on public.unidade_areas;
create policy unidade_areas_equipe on public.unidade_areas for select using (public.eh_equipe());
revoke all on public.unidade_areas from anon, authenticated;
grant select on public.unidade_areas to authenticated;

-- Substitui o quadro inteiro. p_linhas = [{numero, torre, pavimento, area_privativa, ...}]
create or replace function public.importar_quadro_areas(p_linhas jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then raise exception 'PLANILHA_VAZIA'; end if;
  if exists (select 1 from jsonb_array_elements(p_linhas) l where coalesce(trim(l ->> 'numero'), '') = '') then raise exception 'UNIDADE_SEM_NUMERO'; end if;
  if (select count(distinct trim(l ->> 'numero')) from jsonb_array_elements(p_linhas) l) <> jsonb_array_length(p_linhas) then raise exception 'UNIDADE_REPETIDA'; end if;
  delete from public.unidade_areas where true;
  insert into public.unidade_areas (numero, torre, pavimento, area_privativa, area_acessoria, area_privativa_total, area_comum,
                                    area_total, fracao_ideal, vagas, escaninho, escaninho_local, escaninho_area)
  select trim(l ->> 'numero'), nullif(trim(l ->> 'torre'), ''), nullif(trim(l ->> 'pavimento'), ''),
         (l ->> 'area_privativa')::numeric, (l ->> 'area_acessoria')::numeric, (l ->> 'area_privativa_total')::numeric,
         (l ->> 'area_comum')::numeric, (l ->> 'area_total')::numeric, (l ->> 'fracao_ideal')::numeric,
         nullif(trim(l ->> 'vagas'), ''), nullif(trim(l ->> 'escaninho'), ''), nullif(trim(l ->> 'escaninho_local'), ''),
         (l ->> 'escaninho_area')::numeric
    from jsonb_array_elements(p_linhas) l;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Comissão e conferência do pagamento ---------------------------------
alter table public.dados_contrato add column if not exists comissao jsonb not null default '[]'::jsonb;
alter table public.dados_contrato add column if not exists pagamento_conferido_em timestamptz;
alter table public.dados_contrato add column if not exists pagamento_conferido_por text;

create or replace function public.conferir_pagamento(p_pasta uuid, p_comissao jsonb, p_conferido boolean)
returns public.dados_contrato language plpgsql security definer set search_path = public as $$
declare v public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not public.contrato_liberado(p_pasta) then raise exception 'PROPOSTA_NAO_APROVADA'; end if;
  insert into public.dados_contrato as d (pasta_id, comissao, pagamento_conferido_em, pagamento_conferido_por, atualizado_em, atualizado_por)
  values (p_pasta, coalesce(p_comissao, '[]'), case when p_conferido then now() end, case when p_conferido then public.meu_email() end, now(), public.meu_email())
  on conflict (pasta_id) do update set comissao = excluded.comissao,
     pagamento_conferido_em = excluded.pagamento_conferido_em, pagamento_conferido_por = excluded.pagamento_conferido_por,
     atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  if p_conferido then
    insert into public.historico_pastas (pasta_id, acao, usuario_email) values (p_pasta, 'Fluxo de pagamento conferido para o contrato', public.meu_email());
  end if;
  return v;
end;
$$;

-- Contratos emitidos ------------------------------------------------------
create table if not exists public.contratos (
  id             uuid primary key default gen_random_uuid(),
  numero         bigint generated always as identity (start with 1001) unique,
  pasta_id       uuid not null references public.pastas(id) on delete cascade,
  proposta_id    uuid references public.propostas(id) on delete set null,
  documento      text not null check (documento in ('quadro_resumo', 'normas')),
  nome           text not null,
  caminho        text not null,
  dados          jsonb,
  validacao      text not null default 'aguardando' check (validacao in ('aguardando', 'validado')),
  assinatura     text not null default 'nao_enviado' check (assinatura in ('nao_enviado', 'enviado', 'assinado', 'recusado')),
  gerado_em      timestamptz not null default now(),
  gerado_por     text,
  validado_em    timestamptz,
  validado_por   text,
  cancelado_em   timestamptz,
  cancelado_por  text
);
create index if not exists contratos_pasta_idx on public.contratos (pasta_id);
alter table public.contratos enable row level security;
drop policy if exists contratos_equipe on public.contratos;
create policy contratos_equipe on public.contratos for select using (public.eh_equipe());
revoke all on public.contratos from anon, authenticated;
grant select on public.contratos to authenticated;

create or replace function public.registrar_contrato(p_pasta uuid, p_proposta uuid, p_documento text, p_nome text, p_caminho text, p_dados jsonb)
returns public.contratos language plpgsql security definer set search_path = public as $$
declare v public.contratos; d public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not exists (select 1 from public.propostas where id = p_proposta and pasta_id = p_pasta and status = 'aprovada') then
    raise exception 'PROPOSTA_NAO_APROVADA';
  end if;
  select * into d from public.dados_contrato where pasta_id = p_pasta;
  if d.status is distinct from 'conferido' then raise exception 'DADOS_NAO_CONFERIDOS'; end if;
  if d.pagamento_conferido_em is null then raise exception 'PAGAMENTO_NAO_CONFERIDO'; end if;
  if p_caminho !~ ('^' || p_pasta::text || '/') then raise exception 'CAMINHO_INVALIDO'; end if;
  insert into public.contratos (pasta_id, proposta_id, documento, nome, caminho, dados, gerado_por)
  values (p_pasta, p_proposta, p_documento, left(p_nome, 200), p_caminho, p_dados, public.meu_email())
  returning * into v;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Contrato emitido', jsonb_build_object('numero', v.numero, 'documento', v.nome), public.meu_email());
  return v;
end;
$$;

create or replace function public.validar_contrato(p_id uuid) returns public.contratos
language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contratos set validacao = 'validado', validado_em = now(), validado_por = public.meu_email()
   where id = p_id and cancelado_em is null returning * into v;
  if v.id is null then raise exception 'CONTRATO_NAO_ENCONTRADO'; end if;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato validado', jsonb_build_object('numero', v.numero), public.meu_email());
  return v;
end;
$$;

create or replace function public.cancelar_contrato(p_id uuid) returns public.contratos
language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contratos set cancelado_em = now(), cancelado_por = public.meu_email()
   where id = p_id and cancelado_em is null and assinatura <> 'assinado' returning * into v;
  if v.id is null then raise exception 'NAO_PODE_CANCELAR'; end if;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato cancelado', jsonb_build_object('numero', v.numero), public.meu_email());
  return v;
end;
$$;

-- Arquivos: bucket privado, só a equipe lê e grava ("<pasta>/<arquivo>.pdf")
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('contratos', 'contratos', false, 26214400, array['application/pdf'])
on conflict (id) do update set public = false;
drop policy if exists contratos_leitura on storage.objects;
drop policy if exists contratos_envio on storage.objects;
create policy contratos_leitura on storage.objects for select to authenticated using (bucket_id = 'contratos' and public.eh_equipe());
create policy contratos_envio on storage.objects for insert to authenticated with check (bucket_id = 'contratos' and public.eh_equipe());

revoke all on function public.salvar_empreendimento_contrato(jsonb), public.importar_quadro_areas(jsonb),
  public.conferir_pagamento(uuid, jsonb, boolean), public.registrar_contrato(uuid, uuid, text, text, text, jsonb),
  public.validar_contrato(uuid), public.cancelar_contrato(uuid) from public, anon;
grant execute on function public.salvar_empreendimento_contrato(jsonb), public.importar_quadro_areas(jsonb),
  public.conferir_pagamento(uuid, jsonb, boolean), public.registrar_contrato(uuid, uuid, text, text, text, jsonb),
  public.validar_contrato(uuid), public.cancelar_contrato(uuid) to authenticated;

commit;

-- >>>>> supabase/migrations/042_contratos_versoes.sql
-- =====================================================================
-- 042 — Contratos: Word editável e versões ajustadas
--  * Cada documento emitido guarda o PDF e o Word (.docx) gerados.
--  * A equipe baixa o Word, ajusta e envia de volta (.docx e/ou .pdf):
--    vira uma nova versão, a validação volta para "aguardando" e é essa
--    versão que segue para a D4Sign (que converte o Word em PDF).
--  * Só dá para ajustar enquanto o documento não foi enviado para assinatura.
-- Executar uma única vez no SQL Editor do Supabase (depois da 041).
-- =====================================================================
begin;

alter table public.contratos alter column caminho drop not null;
alter table public.contratos add column if not exists caminho_docx text;
alter table public.contratos add column if not exists versao int not null default 1;

create table if not exists public.contrato_versoes (
  id           bigint generated always as identity primary key,
  contrato_id  uuid not null references public.contratos(id) on delete cascade,
  versao       int not null,
  caminho_pdf  text,
  caminho_docx text,
  origem       text not null check (origem in ('sistema', 'ajuste')),
  criado_em    timestamptz not null default now(),
  criado_por   text,
  unique (contrato_id, versao)
);
alter table public.contrato_versoes enable row level security;
drop policy if exists contrato_versoes_equipe on public.contrato_versoes;
create policy contrato_versoes_equipe on public.contrato_versoes for select using (public.eh_equipe());
revoke all on public.contrato_versoes from anon, authenticated;
grant select on public.contrato_versoes to authenticated;

update storage.buckets set allowed_mime_types = array['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document']
 where id = 'contratos';

drop function if exists public.registrar_contrato(uuid, uuid, text, text, text, jsonb);
create or replace function public.registrar_contrato(p_pasta uuid, p_proposta uuid, p_documento text, p_nome text, p_caminho text, p_dados jsonb, p_caminho_docx text default null)
returns public.contratos language plpgsql security definer set search_path = public as $$
declare v public.contratos; d public.dados_contrato;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if not exists (select 1 from public.propostas where id = p_proposta and pasta_id = p_pasta and status = 'aprovada') then
    raise exception 'PROPOSTA_NAO_APROVADA';
  end if;
  select * into d from public.dados_contrato where pasta_id = p_pasta;
  if d.status is distinct from 'conferido' then raise exception 'DADOS_NAO_CONFERIDOS'; end if;
  if d.pagamento_conferido_em is null then raise exception 'PAGAMENTO_NAO_CONFERIDO'; end if;
  if p_caminho !~ ('^' || p_pasta::text || '/') or (p_caminho_docx is not null and p_caminho_docx !~ ('^' || p_pasta::text || '/')) then
    raise exception 'CAMINHO_INVALIDO';
  end if;
  insert into public.contratos (pasta_id, proposta_id, documento, nome, caminho, caminho_docx, dados, gerado_por)
  values (p_pasta, p_proposta, p_documento, left(p_nome, 200), p_caminho, p_caminho_docx, p_dados, public.meu_email())
  returning * into v;
  insert into public.contrato_versoes (contrato_id, versao, caminho_pdf, caminho_docx, origem, criado_por)
  values (v.id, 1, p_caminho, p_caminho_docx, 'sistema', public.meu_email());
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Contrato emitido', jsonb_build_object('numero', v.numero, 'documento', v.nome), public.meu_email());
  return v;
end;
$$;

-- Nova versão ajustada (Word e/ou PDF). Volta a validação para "aguardando".
create or replace function public.enviar_versao_contrato(p_id uuid, p_caminho_docx text, p_caminho_pdf text)
returns public.contratos language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_caminho_docx is null and p_caminho_pdf is null then raise exception 'ARQUIVO_OBRIGATORIO'; end if;
  select * into v from public.contratos where id = p_id for update;
  if v.id is null or v.cancelado_em is not null then raise exception 'CONTRATO_NAO_ENCONTRADO'; end if;
  if v.assinatura <> 'nao_enviado' then raise exception 'JA_ENVIADO_PARA_ASSINATURA'; end if;
  if (p_caminho_docx is not null and p_caminho_docx !~ ('^' || v.pasta_id::text || '/'))
     or (p_caminho_pdf is not null and p_caminho_pdf !~ ('^' || v.pasta_id::text || '/')) then
    raise exception 'CAMINHO_INVALIDO';
  end if;
  update public.contratos
     set versao = versao + 1, caminho_docx = p_caminho_docx, caminho = p_caminho_pdf,
         validacao = 'aguardando', validado_em = null, validado_por = null
   where id = p_id returning * into v;
  insert into public.contrato_versoes (contrato_id, versao, caminho_pdf, caminho_docx, origem, criado_por)
  values (v.id, v.versao, p_caminho_pdf, p_caminho_docx, 'ajuste', public.meu_email());
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato ajustado', jsonb_build_object('numero', v.numero, 'versao', v.versao), public.meu_email());
  return v;
end;
$$;

revoke all on function public.registrar_contrato(uuid, uuid, text, text, text, jsonb, text), public.enviar_versao_contrato(uuid, text, text) from public, anon;
grant execute on function public.registrar_contrato(uuid, uuid, text, text, text, jsonb, text), public.enviar_versao_contrato(uuid, text, text) to authenticated;

commit;

-- >>>>> supabase/migrations/043_modelos_contrato.sql
-- =====================================================================
-- 043 — Modelos de contrato em Word (com marcadores)
--  * O administrador envia o Word do jurídico com marcadores ({comprador.nome}…)
--    para cada documento (Quadro Resumo, Normas Contratuais).
--  * Só um modelo ativo por documento; os anteriores ficam no histórico.
--  * Sem modelo enviado, o sistema usa o modelo padrão.
-- Executar uma única vez no SQL Editor do Supabase (depois da 042).
-- =====================================================================
begin;

create table if not exists public.modelos_contrato (
  id          uuid primary key default gen_random_uuid(),
  documento   text not null check (documento in ('quadro_resumo', 'normas')),
  nome        text not null,
  caminho     text not null check (caminho ~ '^modelos/'),
  ativo       boolean not null default true,
  enviado_em  timestamptz not null default now(),
  enviado_por text
);
create unique index if not exists modelos_contrato_um_ativo on public.modelos_contrato (documento) where ativo;
alter table public.modelos_contrato enable row level security;
drop policy if exists modelos_contrato_equipe on public.modelos_contrato;
create policy modelos_contrato_equipe on public.modelos_contrato for select using (public.eh_equipe());
revoke all on public.modelos_contrato from anon, authenticated;
grant select on public.modelos_contrato to authenticated;

-- Ativa um modelo novo (o anterior do mesmo documento sai de uso)
create or replace function public.salvar_modelo_contrato(p_documento text, p_nome text, p_caminho text)
returns public.modelos_contrato language plpgsql security definer set search_path = public as $$
declare v public.modelos_contrato;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.modelos_contrato set ativo = false where documento = p_documento and ativo;
  insert into public.modelos_contrato (documento, nome, caminho, enviado_por)
  values (p_documento, left(p_nome, 200), p_caminho, public.meu_email()) returning * into v;
  return v;
end;
$$;

-- Volta para o modelo padrão do sistema
create or replace function public.usar_modelo_padrao(p_documento text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.modelos_contrato set ativo = false where documento = p_documento and ativo;
end;
$$;

revoke all on function public.salvar_modelo_contrato(text, text, text), public.usar_modelo_padrao(text) from public, anon;
grant execute on function public.salvar_modelo_contrato(text, text, text), public.usar_modelo_padrao(text) to authenticated;

commit;

-- >>>>> supabase/migrations/044_d4sign.sql
-- =====================================================================
-- 044 — Assinatura eletrônica (D4Sign)
--  * contratos: identificador na D4Sign, datas de envio/assinatura e PDF assinado.
--  * Novas situações: 'preparado' (na D4Sign, aguardando conferência da prévia)
--    e 'cancelado' (cancelado na D4Sign).
--  * contrato_assinantes: quem assina, em que ordem, por e-mail ou WhatsApp, e se já assinou.
--  * Quem grava é o servidor (com a chave secreta), depois de conferir o login da equipe.
-- Executar uma única vez no SQL Editor do Supabase (depois da 043).
-- =====================================================================
begin;

alter table public.contratos add column if not exists d4sign_uuid text unique;
alter table public.contratos add column if not exists enviado_assinatura_em timestamptz;
alter table public.contratos add column if not exists assinado_em timestamptz;
alter table public.contratos add column if not exists caminho_assinado text;
alter table public.contratos drop constraint if exists contratos_assinatura_check;
alter table public.contratos add constraint contratos_assinatura_check
  check (assinatura in ('nao_enviado', 'preparado', 'enviado', 'assinado', 'recusado', 'cancelado'));

create table if not exists public.contrato_assinantes (
  id           bigint generated always as identity primary key,
  contrato_id  uuid not null references public.contratos(id) on delete cascade,
  ordem        int not null default 1,
  papel        text not null,
  nome         text,
  email        text not null,
  whatsapp     text,
  canal        text not null default 'email' check (canal in ('email', 'whatsapp')),
  key_signer   text,
  assinado     boolean not null default false,
  assinado_em  timestamptz,
  atualizado_em timestamptz not null default now()
);
create index if not exists contrato_assinantes_contrato_idx on public.contrato_assinantes (contrato_id);
alter table public.contrato_assinantes enable row level security;
drop policy if exists contrato_assinantes_equipe on public.contrato_assinantes;
create policy contrato_assinantes_equipe on public.contrato_assinantes for select using (public.eh_equipe());
revoke all on public.contrato_assinantes from anon, authenticated;
grant select on public.contrato_assinantes to authenticated;

-- Cancelar pelo sistema só antes de ir para a D4Sign (depois, cancela pela integração)
create or replace function public.cancelar_contrato(p_id uuid) returns public.contratos
language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contratos set cancelado_em = now(), cancelado_por = public.meu_email()
   where id = p_id and cancelado_em is null and assinatura = 'nao_enviado' returning * into v;
  if v.id is null then raise exception 'NAO_PODE_CANCELAR'; end if;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato cancelado', jsonb_build_object('numero', v.numero), public.meu_email());
  return v;
end;
$$;

commit;

-- >>>>> supabase/migrations/045_pix_sinal.sql
-- =====================================================================
-- 045 — Pix do sinal na pasta: comprovante anexado OU Pix gerado pelo sistema
--  * config.pix_modo: 'comprovante' (padrão, como hoje: anexa o comprovante)
--    ou 'integrado' (o sistema gera um Pix de valor fixo e dá baixa sozinho).
--  * config.pix_valor / pix_validade_horas / pix_provedor ('simulado' para testes;
--    'itau', 'infinitepay', 'mercadopago' quando a integração for ligada).
--  * No modo integrado, o "Comprovante do PIX" deixa de ser exigido e a pasta só
--    fica pronta com um Pix pago.
-- Executar uma única vez no SQL Editor do Supabase (depois da 044).
-- =====================================================================
begin;

alter table public.config add column if not exists pix_modo text not null default 'comprovante' check (pix_modo in ('comprovante', 'integrado'));
alter table public.config add column if not exists pix_valor numeric(12,2) not null default 2000 check (pix_valor > 0);
alter table public.config add column if not exists pix_validade_horas int not null default 48 check (pix_validade_horas between 1 and 720);
alter table public.config add column if not exists pix_provedor text not null default 'simulado' check (pix_provedor in ('simulado', 'itau', 'infinitepay', 'mercadopago'));
grant update (pix_modo, pix_valor, pix_validade_horas, pix_provedor) on public.config to authenticated;

alter table public.tipos_documento add column if not exists eh_pix boolean not null default false;
update public.tipos_documento set eh_pix = true where nome = 'Comprovante do PIX';

create table if not exists public.cobrancas_pix (
  id                uuid primary key default gen_random_uuid(),
  pasta_id          uuid not null references public.pastas(id) on delete cascade,
  valor             numeric(12,2) not null,
  provedor          text not null,
  txid              text not null unique,
  copia_cola        text not null,
  status            text not null default 'pendente' check (status in ('pendente', 'pago', 'cancelado')),
  expira_em         timestamptz not null,
  pago_em           timestamptz,
  pagador_nome      text,
  pagador_documento text,
  e2e_id            text,
  criado_em         timestamptz not null default now(),
  criado_por        text
);
create index if not exists cobrancas_pix_pasta_idx on public.cobrancas_pix (pasta_id);
alter table public.cobrancas_pix enable row level security;
drop policy if exists cobrancas_pix_leitura on public.cobrancas_pix;
create policy cobrancas_pix_leitura on public.cobrancas_pix for select using (public.pode_ver_pasta(pasta_id));
revoke all on public.cobrancas_pix from anon, authenticated;
grant select on public.cobrancas_pix to authenticated;

-- Pix pago nesta pasta?
create or replace function public.pix_pago(p_pasta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.cobrancas_pix where pasta_id = p_pasta and status = 'pago');
$$;

-- Gera (ou devolve o que ainda vale) o Pix do sinal. Provedores reais entram pelo servidor.
create or replace function public.gerar_cobranca_pix(p_pasta uuid) returns public.cobrancas_pix
language plpgsql security definer set search_path = public as $$
declare v public.cobrancas_pix; c public.config; t text;
begin
  if not public.pode_ver_pasta(p_pasta) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into c from public.config where id = 1;
  if c.pix_modo <> 'integrado' then raise exception 'PIX_NAO_INTEGRADO'; end if;
  if public.pix_pago(p_pasta) then raise exception 'PIX_JA_PAGO'; end if;
  select * into v from public.cobrancas_pix where pasta_id = p_pasta and status = 'pendente' and expira_em > now() order by criado_em desc limit 1;
  if v.id is not null then return v; end if;
  if c.pix_provedor <> 'simulado' then raise exception 'PROVEDOR_NAO_CONFIGURADO'; end if;
  t := 'SIM' || upper(replace(gen_random_uuid()::text, '-', ''));
  insert into public.cobrancas_pix (pasta_id, valor, provedor, txid, copia_cola, expira_em, criado_por)
  values (p_pasta, c.pix_valor, 'simulado', left(t, 35),
          'PIX DE TESTE - NAO PAGAR - ' || left(t, 35) || ' - R$ ' || to_char(c.pix_valor, 'FM999G999D00'),
          now() + make_interval(hours => c.pix_validade_horas), public.meu_email())
  returning * into v;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pix do sinal gerado', jsonb_build_object('valor', v.valor, 'expira_em', v.expira_em), public.meu_email());
  return v;
end;
$$;

-- Só para testes (provedor simulado): a equipe marca como pago.
create or replace function public.simular_pagamento_pix(p_cobranca uuid) returns public.cobrancas_pix
language plpgsql security definer set search_path = public as $$
declare v public.cobrancas_pix; p public.pastas;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into v from public.cobrancas_pix where id = p_cobranca for update;
  if v.id is null or v.provedor <> 'simulado' then raise exception 'SO_EM_TESTE'; end if;
  if v.status <> 'pendente' then raise exception 'PIX_NAO_PENDENTE'; end if;
  select * into p from public.pastas where id = v.pasta_id;
  update public.cobrancas_pix
     set status = 'pago', pago_em = now(), pagador_nome = p.comprador_nome,
         pagador_documento = coalesce(p.empresa_cnpj, p.comprador_cpf), e2e_id = 'E' || upper(left(replace(gen_random_uuid()::text, '-', ''), 31))
   where id = p_cobranca returning * into v;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Pix do sinal pago', jsonb_build_object('valor', v.valor, 'simulado', true), public.meu_email());
  perform public.recalcular_pasta(v.pasta_id);
  return v;
end;
$$;

create or replace function public.recalcular_pasta(p_pasta uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ec        public.estado_civil;
  v_tipo      text;
  v_conjuge   boolean;
  v_submetida boolean;
  v_integrado boolean := coalesce((select pix_modo = 'integrado' from public.config where id = 1), false);
  v_status    text;
  v_faltando  int;
  v_recusado  int;
  v_analise   int;
  v_enviado   int;
begin
  select estado_civil, tipo_pessoa, public.conjuge_no_contrato(estado_civil, regime_bens, conjuge_participa, tipo_pessoa), codigo_aprovacao is not null
    into v_ec, v_tipo, v_conjuge, v_submetida from public.pastas where id = p_pasta;

  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo
     and not (v_integrado and t.eh_pix)
     and case when v_tipo = 'pj' then t.aplica_a in ('pj', 'ambos') and t.obrigatorio_pj
              else t.aplica_a in ('pf', 'ambos') and v_ec = any (t.obrigatorio_para) and (t.pessoa <> 'conjuge' or v_conjuge) end
     and not exists (select 1 from public.documentos d where d.pasta_id = p_pasta and d.tipo_id = t.id and d.atual);
  if v_integrado and not public.pix_pago(p_pasta) then v_faltando := v_faltando + 1; end if;
  select count(*) into v_recusado from public.documentos where pasta_id = p_pasta and atual and status = 'recusado';
  select count(*) into v_analise  from public.documentos where pasta_id = p_pasta and atual and status = 'em_analise';
  select count(*) into v_enviado  from public.documentos where pasta_id = p_pasta and atual and status = 'enviado';

  if not v_submetida then
    v_status := case when v_faltando > 0 then 'incompleta' else 'pronta' end;
  else
    v_status := case
      when v_recusado > 0 then 'pendente_correcao'
      when v_faltando > 0 then 'incompleta'
      when v_analise > 0 then 'em_analise'
      when v_enviado > 0 then 'aguardando_analise'
      else 'aprovada' end;
  end if;

  update public.pastas set status = v_status where id = p_pasta and status is distinct from v_status;
  return v_status;
end;
$$;

create or replace function public.submeter_pasta(p_pasta uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v_pasta.codigo_aprovacao is not null then raise exception 'JA_SUBMETIDA'; end if;
  if length(trim(coalesce(v_pasta.comprador_telefone, ''))) < 10
     or length(trim(coalesce(v_pasta.comprador_email, ''))) <= 3
     or length(trim(coalesce(v_pasta.comprador_profissao, ''))) <= 1 then
    raise exception 'DADOS_INCOMPLETOS';
  end if;
  if v_pasta.tipo_pessoa = 'pf' and v_pasta.estado_civil in ('casado', 'uniao_estavel') and v_pasta.regime_bens is null then
    raise exception 'REGIME_NAO_INFORMADO';
  end if;
  if public.conjuge_no_contrato(v_pasta.estado_civil, v_pasta.regime_bens, v_pasta.conjuge_participa, v_pasta.tipo_pessoa)
     and (length(trim(coalesce(v_pasta.conjuge_nome, ''))) <= 1
          or v_pasta.conjuge_cpf is null
          or length(trim(coalesce(v_pasta.conjuge_profissao, ''))) <= 1) then
    raise exception 'DADOS_CONJUGE_INCOMPLETOS';
  end if;
  if coalesce((select pix_modo = 'integrado' from public.config where id = 1), false) and not public.pix_pago(p_pasta) then
    raise exception 'PIX_PENDENTE';
  end if;
  if public.recalcular_pasta(p_pasta) <> 'pronta' then raise exception 'DOCUMENTOS_FALTANDO'; end if;

  update public.pastas
     set codigo_aprovacao = public.formatar_codigo('PA', nextval('public.pastas_aprovacao_seq')),
         submetida_em = now(), submetida_por = public.meu_email()
   where id = p_pasta
  returning * into v_pasta;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pasta submetida ao incorporador', jsonb_build_object('codigo', v_pasta.codigo_aprovacao), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$$;

-- Ao trocar o modo do Pix, recalcula as pastas ainda não submetidas
create or replace function public.config_pix_mudou() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.pix_modo is distinct from old.pix_modo then
    for r in select id from public.pastas where codigo_aprovacao is null loop perform public.recalcular_pasta(r.id); end loop;
  end if;
  return null;
end;
$$;
drop trigger if exists config_pix_mudou on public.config;
create trigger config_pix_mudou after update of pix_modo on public.config for each row execute function public.config_pix_mudou();

revoke all on function public.pix_pago(uuid), public.gerar_cobranca_pix(uuid), public.simular_pagamento_pix(uuid) from public, anon;
grant execute on function public.pix_pago(uuid), public.gerar_cobranca_pix(uuid), public.simular_pagamento_pix(uuid) to authenticated;

commit;

-- >>>>> supabase/migrations/046_envelope_assinatura.sql
-- =====================================================================
-- 046 — Envelope único de assinatura por pasta
--  * Boas práticas: um envelope por venda. O Quadro Resumo é o documento
--    principal; Normas, Carta Proposta e os documentos fixos do empreendimento
--    (memorial, plantas, convenção…) vão como anexos do mesmo envelope.
--  * contrato_anexos_fixos: documentos fixos cadastrados pelo administrador.
--  * envelopes: o que foi enviado (versões congeladas), situação e pacote assinado.
--  * envelope_assinantes: quem assina, ordem, canal, se já assinou.
--  * Enquanto há envelope ativo, os documentos ficam travados (sem ajuste).
--  * Substitui a assinatura por documento da 044 (contrato_assinantes sai).
-- Executar uma única vez no SQL Editor do Supabase (depois da 045).
-- =====================================================================
begin;

-- Carta proposta também é emitida no módulo
alter table public.contratos drop constraint if exists contratos_documento_check;
alter table public.contratos add constraint contratos_documento_check check (documento in ('quadro_resumo', 'normas', 'carta_proposta'));

-- Documentos fixos do empreendimento
create table if not exists public.contrato_anexos_fixos (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  caminho     text not null check (caminho ~ '^fixos/'),
  arquivo     text,
  ordem       int not null default 100,
  ativo       boolean not null default true,
  enviado_em  timestamptz not null default now(),
  enviado_por text
);
alter table public.contrato_anexos_fixos enable row level security;
drop policy if exists contrato_anexos_fixos_equipe on public.contrato_anexos_fixos;
create policy contrato_anexos_fixos_equipe on public.contrato_anexos_fixos for select using (public.eh_equipe());
revoke all on public.contrato_anexos_fixos from anon, authenticated;
grant select on public.contrato_anexos_fixos to authenticated;

create or replace function public.salvar_anexo_fixo(p_nome text, p_caminho text, p_arquivo text, p_ordem int)
returns public.contrato_anexos_fixos language plpgsql security definer set search_path = public as $$
declare v public.contrato_anexos_fixos;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.contrato_anexos_fixos (nome, caminho, arquivo, ordem, enviado_por)
  values (left(trim(p_nome), 150), p_caminho, left(p_arquivo, 200), coalesce(p_ordem, 100), public.meu_email()) returning * into v;
  return v;
end;
$$;
create or replace function public.alterar_anexo_fixo(p_id uuid, p_nome text, p_ordem int, p_ativo boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contrato_anexos_fixos set nome = coalesce(left(trim(p_nome), 150), nome), ordem = coalesce(p_ordem, ordem), ativo = coalesce(p_ativo, ativo) where id = p_id;
end;
$$;

-- Envelopes
create table if not exists public.envelopes (
  id               uuid primary key default gen_random_uuid(),
  pasta_id         uuid not null references public.pastas(id) on delete cascade,
  proposta_id      uuid references public.propostas(id) on delete set null,
  d4sign_uuid      text unique,
  status           text not null default 'preparado' check (status in ('preparado', 'enviado', 'assinado', 'cancelado')),
  documentos       jsonb not null default '[]'::jsonb,   -- [{tipo, id, nome, versao, arquivo, d4sign_uuid}]
  criado_em        timestamptz not null default now(),
  criado_por       text,
  enviado_em       timestamptz,
  assinado_em      timestamptz,
  caminho_assinado text,
  cancelado_em     timestamptz,
  cancelado_por    text
);
create unique index if not exists envelopes_um_ativo on public.envelopes (pasta_id) where status in ('preparado', 'enviado');
alter table public.envelopes enable row level security;
drop policy if exists envelopes_equipe on public.envelopes;
create policy envelopes_equipe on public.envelopes for select using (public.eh_equipe());
revoke all on public.envelopes from anon, authenticated;
grant select on public.envelopes to authenticated;

create table if not exists public.envelope_assinantes (
  id            bigint generated always as identity primary key,
  envelope_id   uuid not null references public.envelopes(id) on delete cascade,
  ordem         int not null default 1,
  papel         text not null,
  nome          text,
  email         text not null,
  whatsapp      text,
  canal         text not null default 'email' check (canal in ('email', 'whatsapp')),
  key_signer    text,
  assinado      boolean not null default false,
  assinado_em   timestamptz,
  atualizado_em timestamptz not null default now()
);
create index if not exists envelope_assinantes_env_idx on public.envelope_assinantes (envelope_id);
alter table public.envelope_assinantes enable row level security;
drop policy if exists envelope_assinantes_equipe on public.envelope_assinantes;
create policy envelope_assinantes_equipe on public.envelope_assinantes for select using (public.eh_equipe());
revoke all on public.envelope_assinantes from anon, authenticated;
grant select on public.envelope_assinantes to authenticated;

-- A assinatura passa a ser por envelope
drop table if exists public.contrato_assinantes;

-- Ajuste de versão bloqueado enquanto o documento estiver num envelope ativo
create or replace function public.em_envelope_ativo(p_contrato uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.envelopes e, jsonb_array_elements(e.documentos) d
                  where e.status in ('preparado', 'enviado') and d ->> 'tipo' = 'contrato' and d ->> 'id' = p_contrato::text);
$$;

create or replace function public.enviar_versao_contrato(p_id uuid, p_caminho_docx text, p_caminho_pdf text)
returns public.contratos language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_caminho_docx is null and p_caminho_pdf is null then raise exception 'ARQUIVO_OBRIGATORIO'; end if;
  select * into v from public.contratos where id = p_id for update;
  if v.id is null or v.cancelado_em is not null then raise exception 'CONTRATO_NAO_ENCONTRADO'; end if;
  if public.em_envelope_ativo(p_id) or v.assinatura = 'assinado' then raise exception 'JA_ENVIADO_PARA_ASSINATURA'; end if;
  if (p_caminho_docx is not null and p_caminho_docx !~ ('^' || v.pasta_id::text || '/'))
     or (p_caminho_pdf is not null and p_caminho_pdf !~ ('^' || v.pasta_id::text || '/')) then
    raise exception 'CAMINHO_INVALIDO';
  end if;
  update public.contratos
     set versao = versao + 1, caminho_docx = p_caminho_docx, caminho = p_caminho_pdf,
         validacao = 'aguardando', validado_em = null, validado_por = null
   where id = p_id returning * into v;
  insert into public.contrato_versoes (contrato_id, versao, caminho_pdf, caminho_docx, origem, criado_por)
  values (v.id, v.versao, p_caminho_pdf, p_caminho_docx, 'ajuste', public.meu_email());
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato ajustado', jsonb_build_object('numero', v.numero, 'versao', v.versao), public.meu_email());
  return v;
end;
$$;

create or replace function public.cancelar_contrato(p_id uuid) returns public.contratos
language plpgsql security definer set search_path = public as $$
declare v public.contratos;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if public.em_envelope_ativo(p_id) then raise exception 'EM_ENVELOPE'; end if;
  update public.contratos set cancelado_em = now(), cancelado_por = public.meu_email()
   where id = p_id and cancelado_em is null and assinatura <> 'assinado' returning * into v;
  if v.id is null then raise exception 'NAO_PODE_CANCELAR'; end if;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (v.pasta_id, 'Contrato cancelado', jsonb_build_object('numero', v.numero), public.meu_email());
  return v;
end;
$$;

revoke all on function public.salvar_anexo_fixo(text, text, text, int), public.alterar_anexo_fixo(uuid, text, int, boolean), public.em_envelope_ativo(uuid) from public, anon;
grant execute on function public.salvar_anexo_fixo(text, text, text, int), public.alterar_anexo_fixo(uuid, text, int, boolean), public.em_envelope_ativo(uuid) to authenticated;

commit;

-- >>>>> supabase/migrations/047_leads.sql
-- =====================================================================
-- 047 — Leads (campanhas do Meta) com rodízio, prazo e funil
--  * Entrada: planilha do Google preenchida pelo Meta → script da planilha
--    → /api/leads/entrada (chave secreta) → receber_leads().
--  * Distribuição em dois níveis: imobiliária por cota (peso) e, dentro
--    dela, rodízio entre os corretores que o gestor colocou na lista.
--  * Prazo para "Assumir" (padrão 15 min) contado só no horário comercial;
--    estourou → próximo corretor da mesma imobiliária (depois, outra
--    imobiliária); depois de N tentativas → Sec. Vendas decide.
--  * Cliente que volta (mesmo telefone/e-mail) vai para o mesmo corretor
--    durante X dias. Pasta criada com o mesmo telefone/e-mail converte o lead.
--  * Telefone e e-mail só aparecem para o corretor depois de assumir.
-- Executar uma única vez no SQL Editor do Supabase (depois da 046).
-- =====================================================================
begin;

alter table public.config add column if not exists modulo_leads boolean not null default false;
grant update (modulo_leads) on public.config to authenticated;

-- Configuração ---------------------------------------------------------
create table if not exists public.leads_config (
  id                 int primary key default 1 check (id = 1),
  ativo              boolean not null default true,
  prazo_aceite_min   int not null default 15 check (prazo_aceite_min between 1 and 1440),
  prazo_contato_min  int not null default 120 check (prazo_contato_min between 5 and 10080),
  max_tentativas     int not null default 3 check (max_tentativas between 1 and 20),
  dias_semana        int[] not null default '{1,2,3,4,5,6}',
  hora_inicio        time not null default '08:00',
  hora_fim           time not null default '18:00',
  plantao_24h        boolean not null default false,
  dono_dias          int not null default 90 check (dono_dias between 0 and 730),
  emails_alerta      text,
  remetente_email    text,
  remetente_nome     text default 'Leads',
  url_app            text,
  ultimo_recebimento timestamptz,
  atualizado_em      timestamptz not null default now(),
  atualizado_por     text
);
insert into public.leads_config (id) values (1) on conflict do nothing;
alter table public.leads_config enable row level security;
drop policy if exists leads_config_leitura on public.leads_config;
create policy leads_config_leitura on public.leads_config for select using (public.eh_equipe() or public.minha_imobiliaria() is not null);
revoke all on public.leads_config from anon, authenticated;
grant select on public.leads_config to authenticated;

-- Chave da planilha (só o administrador vê, pela função)
create table if not exists public.leads_chave (
  id    int primary key default 1 check (id = 1),
  chave text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
);
insert into public.leads_chave (id) values (1) on conflict do nothing;
alter table public.leads_chave enable row level security;
revoke all on public.leads_chave from anon, authenticated;

-- Cotas por imobiliária e lista de corretores no rodízio
create table if not exists public.leads_imobiliarias (
  imobiliaria_id uuid primary key references public.imobiliarias(id) on delete cascade,
  cota           numeric(6, 2) not null default 0 check (cota >= 0),
  recebidos      int not null default 0
);
alter table public.leads_imobiliarias enable row level security;
drop policy if exists leads_imobiliarias_leitura on public.leads_imobiliarias;
create policy leads_imobiliarias_leitura on public.leads_imobiliarias for select using (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria());
revoke all on public.leads_imobiliarias from anon, authenticated;
grant select on public.leads_imobiliarias to authenticated;

create table if not exists public.leads_corretores (
  user_id        uuid primary key references public.perfis(user_id) on delete cascade,
  participa      boolean not null default false,
  ultimo_lead_em timestamptz,
  recebidos      int not null default 0,
  alterado_em    timestamptz not null default now(),
  alterado_por   text
);
alter table public.leads_corretores enable row level security;
drop policy if exists leads_corretores_leitura on public.leads_corretores;
create policy leads_corretores_leitura on public.leads_corretores for select using (
  public.eh_equipe() or user_id = auth.uid()
  or exists (select 1 from public.perfis p where p.user_id = leads_corretores.user_id and p.imobiliaria_id = public.minha_imobiliaria()));
revoke all on public.leads_corretores from anon, authenticated;
grant select on public.leads_corretores to authenticated;

-- Leads ------------------------------------------------------------------
create sequence if not exists public.leads_codigo_seq;
create table if not exists public.leads (
  id                  uuid primary key default gen_random_uuid(),
  codigo              text not null unique default 'L-' || lpad(nextval('public.leads_codigo_seq')::text, 5, '0'),
  meta_id             text not null unique,
  origem              text not null default 'meta',
  campanha            text, conjunto text, anuncio text, formulario text, plataforma text,
  criado_meta_em      timestamptz,
  recebido_em         timestamptz not null default now(),
  nome                text,
  telefone            text,
  email               text,
  respostas           jsonb not null default '{}'::jsonb,
  status              text not null default 'sem_destino' check (status in (
                        'aguardando_aceite', 'em_atendimento', 'visita_agendada', 'visita_realizada', 'proposta',
                        'convertido', 'perdido', 'sem_destino')),
  imobiliaria_id      uuid references public.imobiliarias(id) on delete set null,
  corretor_id         uuid references public.perfis(user_id) on delete set null,
  distribuido_em      timestamptz,
  prazo_aceite_em     timestamptz,
  aceito_em           timestamptz,
  primeiro_contato_em timestamptz,
  tentados            uuid[] not null default '{}',
  motivo_perda        text,
  observacao          text,
  pasta_id            uuid references public.pastas(id) on delete set null,
  convertido_em       timestamptz,
  retorno_de          uuid references public.leads(id) on delete set null,
  atualizado_em       timestamptz not null default now()
);
create index if not exists leads_status_idx on public.leads (status, prazo_aceite_em);
create index if not exists leads_corretor_idx on public.leads (corretor_id);
create index if not exists leads_imob_idx on public.leads (imobiliaria_id);
create index if not exists leads_tel_idx on public.leads (telefone);
create index if not exists leads_email_idx on public.leads (lower(email));
alter table public.leads enable row level security;
-- Leitura direta só equipe e gestor da imobiliária; corretor lê por listar_leads() (dados mascarados até assumir)
drop policy if exists leads_leitura on public.leads;
create policy leads_leitura on public.leads for select using (public.eh_equipe() or (imobiliaria_id is not null and imobiliaria_id = public.minha_imobiliaria() and public.eh_gestor()));
revoke all on public.leads from anon, authenticated;
grant select on public.leads to authenticated;

create table if not exists public.lead_eventos (
  id            bigint generated always as identity primary key,
  lead_id       uuid not null references public.leads(id) on delete cascade,
  tipo          text not null,
  detalhes      jsonb not null default '{}'::jsonb,
  usuario_email text,
  criado_em     timestamptz not null default now()
);
create index if not exists lead_eventos_lead_idx on public.lead_eventos (lead_id, criado_em);
alter table public.lead_eventos enable row level security;
revoke all on public.lead_eventos from anon, authenticated;

create table if not exists public.lead_notificacoes (
  id         bigint generated always as identity primary key,
  lead_id    uuid references public.leads(id) on delete cascade,
  para       text not null,
  assunto    text not null,
  linhas     jsonb not null default '[]'::jsonb,   -- ["texto", ...]
  botao      text,                                  -- rótulo do botão
  caminho    text,                                  -- /painel/leads/<id>
  status     text not null default 'pendente' check (status in ('pendente', 'enviado', 'erro')),
  tentativas int not null default 0,
  erro       text,
  criado_em  timestamptz not null default now(),
  enviado_em timestamptz
);
create index if not exists lead_notificacoes_pend_idx on public.lead_notificacoes (status, criado_em);
alter table public.lead_notificacoes enable row level security;
revoke all on public.lead_notificacoes from anon, authenticated;

-- Auxiliares ----------------------------------------------------------------
create or replace function public.so_digitos_tel(t text) returns text
language sql immutable as $$
  select case when d = '' then null when length(d) >= 12 and d like '55%' then right(d, 11) else d end
    from (select regexp_replace(coalesce(t, ''), '\D', '', 'g') as d) x;
$$;

/** Soma minutos contando só o horário comercial (fuso de Brasília). */
create or replace function public.leads_prazo(p_inicio timestamptz, p_minutos int) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare c public.leads_config; t timestamp; resto numeric := p_minutos; abre timestamp; fecha timestamp; dispo numeric; i int := 0;
begin
  select * into c from public.leads_config where id = 1;
  if c.plantao_24h or coalesce(array_length(c.dias_semana, 1), 0) = 0 or c.hora_fim <= c.hora_inicio then
    return p_inicio + make_interval(mins => p_minutos);
  end if;
  t := p_inicio at time zone 'America/Sao_Paulo';
  loop
    i := i + 1;
    exit when i > 40;
    if extract(isodow from t)::int = any (c.dias_semana) then
      abre := date_trunc('day', t) + c.hora_inicio;
      fecha := date_trunc('day', t) + c.hora_fim;
      if t < abre then t := abre; end if;
      if t < fecha then
        dispo := extract(epoch from (fecha - t)) / 60;
        if resto <= dispo then return (t + make_interval(secs => resto * 60)) at time zone 'America/Sao_Paulo'; end if;
        resto := resto - dispo;
      end if;
    end if;
    t := date_trunc('day', t) + interval '1 day';
  end loop;
  return p_inicio + make_interval(mins => p_minutos);
end;
$$;

create or replace function public.lead_evento(p_lead uuid, p_tipo text, p_detalhes jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.lead_eventos (lead_id, tipo, detalhes, usuario_email) values (p_lead, p_tipo, coalesce(p_detalhes, '{}'::jsonb), coalesce(public.meu_email(), 'sistema'));
$$;

/** Avisos por e-mail (o servidor envia a cada minuto). */
create or replace function public.lead_avisar(p_lead uuid, p_para text, p_assunto text, p_linhas jsonb, p_botao text default 'Abrir lead') returns void
language sql security definer set search_path = public as $$
  insert into public.lead_notificacoes (lead_id, para, assunto, linhas, botao, caminho)
  select p_lead, trim(e), p_assunto, p_linhas, p_botao, '/painel/leads/' || p_lead
    from unnest(string_to_array(p_para, ',')) e where trim(e) ~ '^[^\s@,]+@[^\s@,]+$';
$$;

create or replace function public.leads_emails_alerta() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim((select emails_alerta from public.leads_config where id = 1)), ''),
                  (select string_agg(email, ',') from public.perfis where papel = 'vendas'),
                  (select string_agg(email, ',') from public.perfis where papel = 'admin'));
$$;

/** Resumo das respostas para o e-mail (sem dados de contato). */
create or replace function public.lead_resumo(l public.leads) returns jsonb
language sql stable as $$
  select jsonb_build_array(
    'Lead ' || l.codigo || coalesce(' · ' || nullif(split_part(coalesce(l.nome, ''), ' ', 1), ''), ''),
    'Campanha: ' || coalesce(l.campanha, '—') || coalesce(' · ' || l.formulario, ''))
  || coalesce((select jsonb_agg(case when k ~ '_' then initcap(replace(k, '_', ' ')) else k end || ': ' || v) from jsonb_each_text(l.respostas) as r(k, v) where length(v) between 1 and 120), '[]'::jsonb);
$$;

/** Escolhe o próximo corretor e entrega o lead (ou manda para a Sec. Vendas). */
create or replace function public.leads_atribuir(p_lead uuid, p_motivo text default 'Rodízio') returns void
language plpgsql security definer set search_path = public as $$
declare
  l public.leads; c public.leads_config; v_imob uuid; v_corr uuid; v_email text; v_nome text; v_prazo timestamptz;
begin
  select * into c from public.leads_config where id = 1;
  select * into l from public.leads where id = p_lead for update;
  if l.id is null then return; end if;

  if coalesce(array_length(l.tentados, 1), 0) < c.max_tentativas then
    -- 1) próximo corretor da mesma imobiliária
    if l.imobiliaria_id is not null then
      select lc.user_id into v_corr
        from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
       where lc.participa and p.papel = 'corretor' and p.imobiliaria_id = l.imobiliaria_id and not (lc.user_id = any (l.tentados))
       order by lc.ultimo_lead_em nulls first, lc.recebidos limit 1;
      if v_corr is not null then v_imob := l.imobiliaria_id; end if;
    end if;
    -- 2) imobiliária pela cota (quem está mais abaixo da sua proporção)
    if v_corr is null then
      select li.imobiliaria_id into v_imob
        from public.leads_imobiliarias li join public.imobiliarias i on i.id = li.imobiliaria_id and i.ativa
       where li.cota > 0 and li.imobiliaria_id is distinct from l.imobiliaria_id
         and exists (select 1 from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
                      where lc.participa and p.papel = 'corretor' and p.imobiliaria_id = li.imobiliaria_id and not (lc.user_id = any (l.tentados)))
       order by (li.recebidos + 1) / li.cota, li.cota desc, random() limit 1;
      if v_imob is null and l.imobiliaria_id is null then v_imob := null; end if;
      if v_imob is not null then
        select lc.user_id into v_corr
          from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
         where lc.participa and p.papel = 'corretor' and p.imobiliaria_id = v_imob and not (lc.user_id = any (l.tentados))
         order by lc.ultimo_lead_em nulls first, lc.recebidos limit 1;
        update public.leads_imobiliarias set recebidos = recebidos + 1 where imobiliaria_id = v_imob;
      end if;
    end if;
  end if;

  if v_corr is null then
    update public.leads set status = 'sem_destino', corretor_id = null, prazo_aceite_em = null, atualizado_em = now() where id = l.id;
    perform public.lead_evento(l.id, 'Aguardando a Sec. Vendas', jsonb_build_object('motivo',
      case when coalesce(array_length(l.tentados, 1), 0) >= c.max_tentativas then 'Limite de tentativas atingido' else 'Nenhum corretor disponível no rodízio' end));
    perform public.lead_avisar(l.id, public.leads_emails_alerta(), 'Lead ' || l.codigo || ' sem corretor — distribuir manualmente',
      jsonb_build_array('O lead ' || l.codigo || ' não foi assumido por ninguém do rodízio e aguarda a Sec. Vendas.') || public.lead_resumo(l), 'Distribuir lead');
    return;
  end if;

  v_prazo := public.leads_prazo(now(), c.prazo_aceite_min);
  update public.leads set status = 'aguardando_aceite', imobiliaria_id = v_imob, corretor_id = v_corr, distribuido_em = now(),
         prazo_aceite_em = v_prazo, aceito_em = null, tentados = array_append(tentados, v_corr), atualizado_em = now()
   where id = l.id returning * into l;
  update public.leads_corretores set ultimo_lead_em = now(), recebidos = recebidos + 1 where user_id = v_corr;
  select email, nome into v_email, v_nome from public.perfis where user_id = v_corr;
  perform public.lead_evento(l.id, 'Enviado ao corretor', jsonb_build_object('corretor', coalesce(v_nome, v_email), 'motivo', p_motivo, 'prazo', v_prazo));
  perform public.lead_avisar(l.id, v_email, 'Novo lead ' || l.codigo || ' — assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    jsonb_build_array('Você recebeu um lead (' || p_motivo || '). Assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI')
      || ' para ver telefone e e-mail; depois disso ele vai para o próximo corretor.') || public.lead_resumo(l), 'Assumir lead');
end;
$$;

/** Entrada da planilha (chamada só pelo servidor, com a chave). */
create or replace function public.receber_leads(p_chave text, p_linhas jsonb, p_origem text default 'planilha', p_url text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r jsonb; v_id text; l public.leads; v_dono public.leads; v_tel text; v_email text; v_nome text; c public.leads_config;
  novos int := 0; repetidos int := 0; v_corr_pasta uuid; v_imob_pasta uuid;
  chaves_meta text[] := array['id', 'lead_id', 'leadgen_id', 'created_time', 'data_de_criacao', 'ad_id', 'ad_name', 'adset_id', 'adset_name',
    'campaign_id', 'campaign_name', 'form_id', 'form_name', 'is_organic', 'platform', 'plataforma', 'nome_completo', 'full_name', 'nome', 'name',
    'first_name', 'last_name', 'primeiro_nome', 'sobrenome', 'phone_number', 'phone', 'telefone', 'numero_de_telefone', 'celular', 'whatsapp',
    'email', 'e_mail', '_linha', '_rotulos', 'inbox_url', 'lead_status', 'vehicle', 'retailer_item_id'];
begin
  if p_chave is null or p_chave <> (select chave from public.leads_chave where id = 1) then raise exception 'CHAVE_INVALIDA'; end if;
  select * into c from public.leads_config where id = 1;
  update public.leads_config set ultimo_recebimento = now(), url_app = coalesce(p_url, url_app) where id = 1;
  for r in select * from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) loop
    v_id := nullif(trim(coalesce(r ->> 'id', r ->> 'lead_id', r ->> 'leadgen_id')), '');
    v_id := coalesce(regexp_replace(v_id, '^l:', ''), p_origem || ':' || coalesce(r ->> '_linha', md5(r::text)));
    if exists (select 1 from public.leads where meta_id = v_id) then repetidos := repetidos + 1; continue; end if;
    v_nome := nullif(trim(coalesce(r ->> 'nome_completo', r ->> 'full_name', r ->> 'nome', r ->> 'name',
                 nullif(trim(coalesce(r ->> 'first_name', r ->> 'primeiro_nome', '') || ' ' || coalesce(r ->> 'last_name', r ->> 'sobrenome', '')), ''))), '');
    v_tel := public.so_digitos_tel(coalesce(r ->> 'phone_number', r ->> 'telefone', r ->> 'numero_de_telefone', r ->> 'celular', r ->> 'whatsapp', r ->> 'phone'));
    v_email := nullif(lower(trim(coalesce(r ->> 'email', r ->> 'e_mail', ''))), '');
    insert into public.leads (meta_id, origem, campanha, conjunto, anuncio, formulario, plataforma, criado_meta_em, nome, telefone, email, respostas)
    values (v_id, coalesce(p_origem, 'planilha'), nullif(r ->> 'campaign_name', ''), nullif(r ->> 'adset_name', ''), nullif(r ->> 'ad_name', ''),
            nullif(r ->> 'form_name', ''), nullif(coalesce(r ->> 'platform', r ->> 'plataforma'), ''),
            case when coalesce(r ->> 'created_time', r ->> 'data_de_criacao', '') ~ '^\d{4}-\d{2}-\d{2}' then (coalesce(r ->> 'created_time', r ->> 'data_de_criacao'))::timestamptz end,
            initcap(v_nome), v_tel, v_email,
            coalesce((select jsonb_object_agg(coalesce(nullif(trim(r -> '_rotulos' ->> k), ''), k), v) from jsonb_each_text(r) as x(k, v) where not (k = any (chaves_meta)) and nullif(trim(v), '') is not null), '{}'::jsonb))
    returning * into l;
    novos := novos + 1;
    perform public.lead_evento(l.id, 'Lead recebido', jsonb_build_object('campanha', l.campanha, 'formulario', l.formulario, 'origem', l.origem));

    if not c.ativo then
      perform public.lead_evento(l.id, 'Aguardando a Sec. Vendas', jsonb_build_object('motivo', 'Rodízio desligado'));
      continue;
    end if;

    -- Cliente que voltou: mesmo corretor durante "dono_dias"
    select * into v_dono from public.leads x
     where x.id <> l.id and x.corretor_id is not null and x.status <> 'perdido'
       and x.recebido_em > now() - make_interval(days => c.dono_dias)
       and ((v_tel is not null and x.telefone = v_tel) or (v_email is not null and lower(x.email) = v_email))
       and exists (select 1 from public.perfis p where p.user_id = x.corretor_id)
     order by x.recebido_em desc limit 1;
    if v_dono.id is null then
      -- ou cliente que já tem pasta: corretor da pasta
      select coalesce(pa.cadastrado_por_id, pa.criado_por_id), pa.imobiliaria_id into v_corr_pasta, v_imob_pasta
        from public.pastas pa join public.perfis p on p.user_id = coalesce(pa.cadastrado_por_id, pa.criado_por_id) and p.papel = 'corretor'
       where (v_tel is not null and public.so_digitos_tel(pa.comprador_telefone) = v_tel) or (v_email is not null and lower(pa.comprador_email) = v_email)
       order by pa.criada_em desc limit 1;
    else
      v_corr_pasta := v_dono.corretor_id; v_imob_pasta := v_dono.imobiliaria_id;
    end if;

    if v_corr_pasta is not null then
      update public.leads set retorno_de = v_dono.id, imobiliaria_id = v_imob_pasta, status = 'aguardando_aceite', corretor_id = v_corr_pasta,
             tentados = array[v_corr_pasta], distribuido_em = now(), prazo_aceite_em = public.leads_prazo(now(), c.prazo_aceite_min)
       where id = l.id returning * into l;
      perform public.lead_evento(l.id, 'Enviado ao corretor', jsonb_build_object('motivo', 'Cliente já atendido por este corretor',
        'corretor', (select coalesce(nome, email) from public.perfis where user_id = v_corr_pasta), 'prazo', l.prazo_aceite_em));
      perform public.lead_avisar(l.id, (select email from public.perfis where user_id = v_corr_pasta),
        'Cliente seu voltou: lead ' || l.codigo || ' — assuma até ' || to_char(l.prazo_aceite_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
        jsonb_build_array('Um cliente que já é seu preencheu um novo formulário. Assuma até ' || to_char(l.prazo_aceite_em at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI') || '.') || public.lead_resumo(l), 'Assumir lead');
    else
      perform public.leads_atribuir(l.id, 'Rodízio');
    end if;
  end loop;
  return jsonb_build_object('novos', novos, 'repetidos', repetidos);
end;
$$;

/** Rodado a cada minuto pelo servidor: prazos vencidos voltam ao rodízio. */
create or replace function public.processar_leads() returns int
language plpgsql security definer set search_path = public as $$
declare l record; n int := 0; c public.leads_config;
begin
  select * into c from public.leads_config where id = 1;
  for l in select id, corretor_id from public.leads where status = 'aguardando_aceite' and prazo_aceite_em < now() order by prazo_aceite_em limit 200 for update skip locked loop
    perform public.lead_evento(l.id, 'Prazo para assumir esgotado', jsonb_build_object('corretor', (select coalesce(nome, email) from public.perfis where user_id = l.corretor_id)));
    perform public.leads_atribuir(l.id, 'Redistribuído: o anterior não assumiu no prazo');
    n := n + 1;
  end loop;
  -- Assumiu mas não registrou contato no prazo: avisa o gestor da imobiliária (uma vez)
  for l in select x.id, x.codigo, x.imobiliaria_id, x.corretor_id from public.leads x
            where x.status = 'em_atendimento' and x.primeiro_contato_em is null
              and public.leads_prazo(x.aceito_em, c.prazo_contato_min) < now()
              and not exists (select 1 from public.lead_eventos e where e.lead_id = x.id and e.tipo = 'Sem registro de contato no prazo') limit 200 loop
    perform public.lead_evento(l.id, 'Sem registro de contato no prazo', '{}'::jsonb);
    perform public.lead_avisar(l.id, (select string_agg(email, ',') from public.perfis where papel = 'imobiliaria' and imobiliaria_id = l.imobiliaria_id),
      'Lead ' || l.codigo || ' sem contato registrado',
      jsonb_build_array((select coalesce(nome, email) from public.perfis where user_id = l.corretor_id) || ' assumiu o lead ' || l.codigo || ' e ainda não registrou o primeiro contato.'), 'Abrir lead');
  end loop;
  return n;
end;
$$;

/** Notificações pendentes (servidor). */
create or replace function public.leads_notificacoes_pendentes(p_limite int default 50) returns setof public.lead_notificacoes
language sql security definer set search_path = public as $$
  select * from public.lead_notificacoes where status = 'pendente' or (status = 'erro' and tentativas < 3 and criado_em > now() - interval '1 day')
   order by criado_em limit p_limite;
$$;
create or replace function public.leads_marcar_notificacao(p_id bigint, p_ok boolean, p_erro text default null) returns void
language sql security definer set search_path = public as $$
  update public.lead_notificacoes set status = case when p_ok then 'enviado' else 'erro' end, tentativas = tentativas + 1,
         enviado_em = case when p_ok then now() end, erro = left(p_erro, 300) where id = p_id;
$$;

-- Leitura -------------------------------------------------------------------
create or replace function public.pode_ver_lead(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.leads l where l.id = p_id and (
    public.eh_equipe() or l.corretor_id = auth.uid()
    or (public.eh_gestor() and l.imobiliaria_id = public.minha_imobiliaria())));
$$;
drop policy if exists lead_eventos_leitura on public.lead_eventos;
create policy lead_eventos_leitura on public.lead_eventos for select using (public.pode_ver_lead(lead_id));
grant select on public.lead_eventos to authenticated;

create or replace function public.listar_leads(p_id uuid default null)
returns table (id uuid, codigo text, status text, campanha text, conjunto text, anuncio text, formulario text, plataforma text,
               recebido_em timestamptz, nome text, telefone text, email text, respostas jsonb, imobiliaria_id uuid, imobiliaria text,
               corretor_id uuid, corretor text, distribuido_em timestamptz, prazo_aceite_em timestamptz, aceito_em timestamptz,
               primeiro_contato_em timestamptz, tentativas int, motivo_perda text, observacao text, pasta_id uuid, pasta_codigo text,
               convertido_em timestamptz, retorno boolean, mascarado boolean)
language sql stable security definer set search_path = public as $$
  with eu as (select papel, imobiliaria_id from public.perfis where user_id = auth.uid())
  select l.id, l.codigo, l.status, l.campanha, l.conjunto, l.anuncio, l.formulario, l.plataforma, l.recebido_em,
         case when m.mask then split_part(coalesce(l.nome, ''), ' ', 1) else l.nome end,
         case when m.mask then null else l.telefone end,
         case when m.mask then null else l.email end,
         l.respostas, l.imobiliaria_id, i.nome, l.corretor_id, coalesce(p.nome, p.email), l.distribuido_em, l.prazo_aceite_em, l.aceito_em,
         l.primeiro_contato_em, coalesce(array_length(l.tentados, 1), 0), l.motivo_perda, l.observacao, l.pasta_id, pa.codigo, l.convertido_em,
         l.retorno_de is not null, m.mask
    from public.leads l
    cross join eu
    left join public.imobiliarias i on i.id = l.imobiliaria_id
    left join public.perfis p on p.user_id = l.corretor_id
    left join public.pastas pa on pa.id = l.pasta_id
    cross join lateral (select (eu.papel = 'corretor' and l.status = 'aguardando_aceite') as mask) m
   where (p_id is null or l.id = p_id)
     and (eu.papel in ('admin', 'vendas')
          or (eu.papel = 'imobiliaria' and l.imobiliaria_id = eu.imobiliaria_id)
          or (eu.papel = 'corretor' and l.corretor_id = auth.uid()))
   order by l.recebido_em desc
   limit 2000;
$$;

-- Ações -----------------------------------------------------------------------
create or replace function public.assumir_lead(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_id for update;
  if l.id is null or l.corretor_id is distinct from auth.uid() then raise exception 'LEAD_NAO_E_SEU'; end if;
  if l.status <> 'aguardando_aceite' then raise exception 'LEAD_JA_ASSUMIDO'; end if;
  update public.leads set status = 'em_atendimento', aceito_em = now(), prazo_aceite_em = null, atualizado_em = now() where id = p_id;
  perform public.lead_evento(p_id, 'Assumido', jsonb_build_object('minutos', round(extract(epoch from (now() - l.distribuido_em)) / 60)));
end;
$$;

create or replace function public.pode_mexer_lead(l public.leads) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe() or (l.corretor_id = auth.uid() and l.status <> 'aguardando_aceite')
      or (public.eh_gestor() and l.imobiliaria_id = public.minha_imobiliaria());
$$;

create or replace function public.registrar_contato_lead(p_id uuid, p_canal text, p_nota text) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_id for update;
  if l.id is null or not public.pode_mexer_lead(l) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.leads set primeiro_contato_em = coalesce(primeiro_contato_em, now()), atualizado_em = now() where id = p_id;
  perform public.lead_evento(p_id, 'Contato', jsonb_build_object('canal', left(p_canal, 30), 'nota', left(nullif(trim(p_nota), ''), 1000)));
end;
$$;

create or replace function public.mover_lead(p_id uuid, p_status text, p_motivo text default null, p_obs text default null) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_id for update;
  if l.id is null or not public.pode_mexer_lead(l) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_status not in ('em_atendimento', 'visita_agendada', 'visita_realizada', 'proposta', 'perdido') then raise exception 'ETAPA_INVALIDA'; end if;
  if l.status in ('aguardando_aceite', 'sem_destino') then raise exception 'LEAD_SEM_ATENDIMENTO'; end if;
  if l.status in ('perdido', 'convertido') and not (public.eh_equipe() or public.eh_gestor()) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_status = 'perdido' and nullif(trim(p_motivo), '') is null then raise exception 'MOTIVO_OBRIGATORIO'; end if;
  update public.leads set status = p_status, motivo_perda = case when p_status = 'perdido' then left(trim(p_motivo), 120) end,
         observacao = coalesce(nullif(trim(p_obs), ''), observacao), atualizado_em = now() where id = p_id;
  perform public.lead_evento(p_id, case when p_status = 'perdido' then 'Perdido' when l.status in ('perdido', 'convertido') then 'Reaberto' else 'Etapa alterada' end,
    jsonb_build_object('de', l.status, 'para', p_status, 'motivo', nullif(trim(p_motivo), ''), 'obs', nullif(trim(p_obs), '')));
end;
$$;

/** Redistribuir: equipe (qualquer corretor ou rodízio) e gestor (só a própria equipe). */
create or replace function public.redistribuir_lead(p_id uuid, p_corretor uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads; v_imob uuid; v_email text; v_prazo timestamptz;
begin
  select * into l from public.leads where id = p_id for update;
  if l.id is null then raise exception 'LEAD_NAO_ENCONTRADO'; end if;
  if l.status in ('convertido') then raise exception 'LEAD_CONVERTIDO'; end if;
  if not public.eh_equipe() and not (public.eh_gestor() and l.imobiliaria_id = public.minha_imobiliaria()) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_corretor is null then
    if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
    update public.leads set tentados = '{}', corretor_id = null where id = p_id;
    perform public.lead_evento(p_id, 'Devolvido ao rodízio', '{}'::jsonb);
    perform public.leads_atribuir(p_id, 'Rodízio (redistribuído pela equipe)');
    return;
  end if;
  select imobiliaria_id, email into v_imob, v_email from public.perfis where user_id = p_corretor and papel = 'corretor';
  if v_imob is null then raise exception 'CORRETOR_INVALIDO'; end if;
  if not public.eh_equipe() and v_imob <> public.minha_imobiliaria() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  v_prazo := public.leads_prazo(now(), (select prazo_aceite_min from public.leads_config where id = 1));
  update public.leads set imobiliaria_id = v_imob, corretor_id = p_corretor, status = 'aguardando_aceite', distribuido_em = now(),
         prazo_aceite_em = v_prazo, aceito_em = null, tentados = array_append(tentados, p_corretor), atualizado_em = now()
   where id = p_id returning * into l;
  perform public.lead_evento(p_id, 'Enviado ao corretor', jsonb_build_object('motivo', 'Escolhido manualmente',
    'corretor', (select coalesce(nome, email) from public.perfis where user_id = p_corretor), 'prazo', v_prazo));
  perform public.lead_avisar(p_id, v_email, 'Novo lead ' || l.codigo || ' — assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    jsonb_build_array('Um lead foi direcionado a você. Assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI') || '.') || public.lead_resumo(l), 'Assumir lead');
end;
$$;

create or replace function public.vincular_pasta_lead(p_lead uuid, p_pasta uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null or not (public.eh_equipe() or l.corretor_id = auth.uid() or (public.eh_gestor() and l.imobiliaria_id = public.minha_imobiliaria())) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if not exists (select 1 from public.pastas where id = p_pasta and (public.eh_equipe() or imobiliaria_id = coalesce(public.minha_imobiliaria(), l.imobiliaria_id))) then
    raise exception 'PASTA_INVALIDA';
  end if;
  update public.leads set status = 'convertido', pasta_id = p_pasta, convertido_em = now(), motivo_perda = null,
         aceito_em = coalesce(aceito_em, now()), primeiro_contato_em = coalesce(primeiro_contato_em, now()), atualizado_em = now() where id = p_lead;
  perform public.lead_evento(p_lead, 'Convertido em pasta', jsonb_build_object('pasta', (select codigo from public.pastas where id = p_pasta)));
end;
$$;

-- Pasta nova com o mesmo telefone/e-mail de um lead em atendimento converte o lead
create or replace function public.pastas_converte_lead() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_tel text := public.so_digitos_tel(new.comprador_telefone); v_email text := lower(nullif(trim(new.comprador_email), '')); l record;
begin
  if v_tel is null and v_email is null then return null; end if;
  for l in select id from public.leads
            where status not in ('convertido', 'perdido', 'sem_destino') and pasta_id is null
              and (imobiliaria_id = new.imobiliaria_id)
              and ((v_tel is not null and telefone = v_tel) or (v_email is not null and lower(email) = v_email)) loop
    update public.leads set status = 'convertido', pasta_id = new.id, convertido_em = now(), aceito_em = coalesce(aceito_em, now()),
           primeiro_contato_em = coalesce(primeiro_contato_em, now()), atualizado_em = now() where id = l.id;
    perform public.lead_evento(l.id, 'Convertido em pasta', jsonb_build_object('pasta', new.codigo, 'automatico', true));
  end loop;
  return null;
end;
$$;
drop trigger if exists pastas_converte_lead on public.pastas;
create trigger pastas_converte_lead after insert on public.pastas for each row execute function public.pastas_converte_lead();

-- Configuração (administrador) e lista do rodízio (gestor) -----------------------
create or replace function public.salvar_config_leads(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.leads_config set
    ativo = coalesce((p ->> 'ativo')::boolean, ativo),
    prazo_aceite_min = coalesce((p ->> 'prazo_aceite_min')::int, prazo_aceite_min),
    prazo_contato_min = coalesce((p ->> 'prazo_contato_min')::int, prazo_contato_min),
    max_tentativas = coalesce((p ->> 'max_tentativas')::int, max_tentativas),
    dias_semana = coalesce((select array_agg(x::int order by x::int) from jsonb_array_elements_text(p -> 'dias_semana') x), dias_semana),
    hora_inicio = coalesce((p ->> 'hora_inicio')::time, hora_inicio),
    hora_fim = coalesce((p ->> 'hora_fim')::time, hora_fim),
    plantao_24h = coalesce((p ->> 'plantao_24h')::boolean, plantao_24h),
    dono_dias = coalesce((p ->> 'dono_dias')::int, dono_dias),
    emails_alerta = case when p ? 'emails_alerta' then nullif(trim(p ->> 'emails_alerta'), '') else emails_alerta end,
    remetente_email = case when p ? 'remetente_email' then nullif(trim(p ->> 'remetente_email'), '') else remetente_email end,
    remetente_nome = case when p ? 'remetente_nome' then nullif(trim(p ->> 'remetente_nome'), '') else remetente_nome end,
    atualizado_em = now(), atualizado_por = public.meu_email()
  where id = 1;
end;
$$;

create or replace function public.salvar_cotas_leads(p_cotas jsonb, p_zerar boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  for r in select (x ->> 'imobiliaria_id')::uuid as imob, greatest(0, coalesce((x ->> 'cota')::numeric, 0)) as cota from jsonb_array_elements(p_cotas) x loop
    insert into public.leads_imobiliarias (imobiliaria_id, cota) values (r.imob, r.cota)
    on conflict (imobiliaria_id) do update set cota = excluded.cota;
  end loop;
  if p_zerar then update public.leads_imobiliarias set recebidos = 0 where true; end if;
end;
$$;

create or replace function public.chave_leads(p_nova boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_nova then update public.leads_chave set chave = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') where id = 1; end if;
  select chave into v from public.leads_chave where id = 1;
  return v;
end;
$$;

create or replace function public.definir_rodizio_corretor(p_user uuid, p_participa boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_imob uuid;
begin
  select imobiliaria_id into v_imob from public.perfis where user_id = p_user and papel = 'corretor';
  if v_imob is null then raise exception 'CORRETOR_INVALIDO'; end if;
  if not (public.eh_equipe() or (public.eh_gestor() and v_imob = public.minha_imobiliaria())) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.leads_corretores (user_id, participa, alterado_por) values (p_user, p_participa, public.meu_email())
  on conflict (user_id) do update set participa = excluded.participa, alterado_em = now(), alterado_por = excluded.alterado_por;
end;
$$;

-- Permissões ---------------------------------------------------------------------
revoke all on function public.so_digitos_tel(text), public.leads_prazo(timestamptz, int), public.lead_evento(uuid, text, jsonb),
  public.lead_avisar(uuid, text, text, jsonb, text), public.leads_emails_alerta(), public.lead_resumo(public.leads), public.leads_atribuir(uuid, text),
  public.receber_leads(text, jsonb, text, text), public.processar_leads(), public.leads_notificacoes_pendentes(int), public.leads_marcar_notificacao(bigint, boolean, text),
  public.pode_ver_lead(uuid), public.listar_leads(uuid), public.assumir_lead(uuid), public.pode_mexer_lead(public.leads), public.registrar_contato_lead(uuid, text, text),
  public.mover_lead(uuid, text, text, text), public.redistribuir_lead(uuid, uuid), public.vincular_pasta_lead(uuid, uuid), public.pastas_converte_lead(),
  public.salvar_config_leads(jsonb), public.salvar_cotas_leads(jsonb, boolean), public.chave_leads(boolean), public.definir_rodizio_corretor(uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.receber_leads(text, jsonb, text, text), public.processar_leads(), public.leads_notificacoes_pendentes(int),
  public.leads_marcar_notificacao(bigint, boolean, text) to service_role;
grant execute on function public.pode_ver_lead(uuid), public.listar_leads(uuid), public.assumir_lead(uuid), public.registrar_contato_lead(uuid, text, text),
  public.mover_lead(uuid, text, text, text), public.redistribuir_lead(uuid, uuid), public.vincular_pasta_lead(uuid, uuid), public.salvar_config_leads(jsonb),
  public.salvar_cotas_leads(jsonb, boolean), public.chave_leads(boolean), public.definir_rodizio_corretor(uuid, boolean), public.leads_prazo(timestamptz, int)
  to authenticated;

commit;

-- >>>>> supabase/migrations/048_manual_videos.sql
-- =====================================================================
-- 048 — Vídeos do manual
--  * Um vídeo (link do YouTube, Vimeo, Loom ou Google Drive) por capítulo
--    do manual. O texto do manual fica no código (src/manual/conteudo.ts).
--  * Todos os logados leem; só o administrador cadastra ou remove.
-- Executar uma única vez no SQL Editor do Supabase (depois da 047).
-- =====================================================================
begin;

create table if not exists public.manual_videos (
  capitulo       text primary key check (capitulo ~ '^[a-z0-9-]{2,60}$'),
  url            text not null check (url ~ '^https://'),
  titulo         text,
  atualizado_em  timestamptz not null default now(),
  atualizado_por text
);
alter table public.manual_videos enable row level security;
drop policy if exists manual_videos_leitura on public.manual_videos;
create policy manual_videos_leitura on public.manual_videos for select using (auth.uid() is not null);
revoke all on public.manual_videos from anon, authenticated;
grant select on public.manual_videos to authenticated;

create or replace function public.salvar_video_manual(p_capitulo text, p_url text, p_titulo text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if nullif(trim(p_url), '') is null then
    delete from public.manual_videos where capitulo = p_capitulo;
    return;
  end if;
  if trim(p_url) !~ '^https://' then raise exception 'LINK_INVALIDO'; end if;
  insert into public.manual_videos (capitulo, url, titulo, atualizado_por)
  values (p_capitulo, left(trim(p_url), 500), left(nullif(trim(p_titulo), ''), 150), public.meu_email())
  on conflict (capitulo) do update set url = excluded.url, titulo = excluded.titulo, atualizado_em = now(), atualizado_por = excluded.atualizado_por;
end;
$$;
revoke all on function public.salvar_video_manual(text, text, text) from public, anon;
grant execute on function public.salvar_video_manual(text, text, text) to authenticated;

commit;

-- >>>>> supabase/migrations/106_fila_escolha.sql
-- =====================================================================
-- 106 — Escolha de unidades por lotes de pastas (liga/desliga)
--  * A equipe monta a fila com as pastas aprovadas (ordem de submissão ao
--    incorporador, código PA) e pode ajustar posições.
--  * Com a fila ligada, a cada "intervalo" minutos a partir do "início"
--    mais um lote de "lote" pastas é liberado.
--  * O corretor dono de uma pasta liberada reserva ele mesmo a unidade
--    (vincula a pasta à unidade). Quem perdeu a vez continua podendo
--    reservar depois, entre as unidades que ainda estiverem disponíveis.
--  * Desligada, nada muda: só a equipe reserva, como antes.
-- Executar uma única vez no SQL Editor do Supabase (projeto de testes).
-- =====================================================================

create table public.fila_config (
  id                 int primary key default 1 check (id = 1),
  ativa              boolean not null default false,
  inicio             timestamptz,
  lote               int not null default 10 check (lote between 1 and 500),
  intervalo_min      int not null default 30 check (intervalo_min between 1 and 1440),
  unidades_por_pasta int not null default 1 check (unidades_por_pasta between 1 and 20),
  atualizado_em      timestamptz not null default now(),
  atualizado_por     text
);
insert into public.fila_config default values;

create table public.fila_escolha (
  pasta_id     uuid primary key references public.pastas (id) on delete cascade,
  posicao      int not null check (posicao >= 1),
  incluida_em  timestamptz not null default now()
);
create index fila_escolha_posicao_idx on public.fila_escolha (posicao);

alter table public.fila_config enable row level security;
alter table public.fila_escolha enable row level security;
revoke all on public.fila_config, public.fila_escolha from anon, authenticated;
grant select on public.fila_config to authenticated;
grant select on public.fila_escolha to authenticated;
create policy fila_config_leitura on public.fila_config for select using (auth.uid() is not null);
create policy fila_escolha_leitura on public.fila_escolha for select using (public.eh_equipe());

-- Quantas posições já foram liberadas agora
create or replace function public.fila_liberadas() returns int
language sql stable security definer set search_path = public as $$
  select case when not f.ativa or f.inicio is null or now() < f.inicio then 0
              else f.lote * (floor(extract(epoch from now() - f.inicio) / (f.intervalo_min * 60))::int + 1) end
    from public.fila_config f where f.id = 1;
$$;

-- Momento em que uma posição é liberada
create or replace function public.fila_libera_em(p_posicao int) returns timestamptz
language sql stable security definer set search_path = public as $$
  select f.inicio + make_interval(mins => ((p_posicao - 1) / f.lote) * f.intervalo_min)
    from public.fila_config f where f.id = 1;
$$;

-- Situação geral (qualquer login): ligada, lote, próximo lote...
create or replace function public.fila_situacao() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ativa', f.ativa, 'inicio', f.inicio, 'lote', f.lote, 'intervalo_min', f.intervalo_min,
    'unidades_por_pasta', f.unidades_por_pasta,
    'liberadas', least(public.fila_liberadas(), (select count(*) from public.fila_escolha)),
    'total', (select count(*) from public.fila_escolha),
    'proximo_lote_em', case when f.ativa and f.inicio is not null then
        case when now() < f.inicio then f.inicio
             else f.inicio + make_interval(mins => (floor(extract(epoch from now() - f.inicio) / (f.intervalo_min * 60))::int + 1) * f.intervalo_min) end end,
    'agora', now())
  from public.fila_config f where f.id = 1;
$$;

-- Pastas da fila que o usuário enxerga (equipe: todas; imobiliária: as dela; corretor: as que criou)
create or replace function public.minha_fila() returns table (
  pasta_id uuid, codigo text, comprador text, imobiliaria text, corretor text, posicao int,
  liberada boolean, libera_em timestamptz, reservas int, unidades text[]
)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.codigo_aprovacao, p.codigo), p.comprador_nome, i.nome,
         coalesce(nullif(pf.nome, ''), p.criado_por), f.posicao,
         f.posicao <= public.fila_liberadas(), public.fila_libera_em(f.posicao),
         (select count(*)::int from public.negociacoes n where n.pasta_id = p.id and n.ativa),
         (select array_agg(u.numero order by u.numero) from public.negociacoes n join public.unidades u on u.id = n.unidade_id where n.pasta_id = p.id and n.ativa)
    from public.fila_escolha f
    join public.pastas p on p.id = f.pasta_id
    left join public.imobiliarias i on i.id = p.imobiliaria_id
    left join public.perfis pf on pf.user_id = p.criado_por_id
   where public.acesso_pasta(p.imobiliaria_id, p.criado_por_id)
   order by f.posicao;
$$;

-- Configurar (administrador)
create or replace function public.configurar_fila(p_ativa boolean, p_inicio timestamptz, p_lote int, p_intervalo int, p_unidades_por_pasta int default 1)
returns public.fila_config
language plpgsql security definer set search_path = public as $$
declare v public.fila_config;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_ativa and p_inicio is null then raise exception 'INICIO_OBRIGATORIO'; end if;
  update public.fila_config set ativa = p_ativa, inicio = p_inicio, lote = p_lote, intervalo_min = p_intervalo,
         unidades_por_pasta = coalesce(p_unidades_por_pasta, 1), atualizado_em = now(), atualizado_por = public.meu_email()
   where id = 1 returning * into v;
  return v;
end;
$$;

-- Montar / completar a fila: pastas aprovadas que ainda não estão nela, por ordem de submissão (PA)
create or replace function public.montar_fila() returns int
language plpgsql security definer set search_path = public as $$
declare v_ini int; v_n int;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select coalesce(max(posicao), 0) into v_ini from public.fila_escolha;
  insert into public.fila_escolha (pasta_id, posicao)
  select p.id, v_ini + row_number() over (order by p.submetida_em nulls last, p.codigo_aprovacao nulls last, p.criada_em)
    from public.pastas p
   where p.status = 'aprovada' and not exists (select 1 from public.fila_escolha f where f.pasta_id = p.id);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- Mover uma pasta para outra posição (as demais andam uma casa)
create or replace function public.mover_na_fila(p_pasta uuid, p_posicao int) returns void
language plpgsql security definer set search_path = public as $$
declare v_atual int; v_max int; v_nova int;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select posicao into v_atual from public.fila_escolha where pasta_id = p_pasta;
  if v_atual is null then raise exception 'PASTA_FORA_DA_FILA'; end if;
  select max(posicao) into v_max from public.fila_escolha;
  v_nova := greatest(1, least(p_posicao, v_max));
  if v_nova = v_atual then return; end if;
  if v_nova < v_atual then
    update public.fila_escolha set posicao = posicao + 1 where posicao >= v_nova and posicao < v_atual;
  else
    update public.fila_escolha set posicao = posicao - 1 where posicao > v_atual and posicao <= v_nova;
  end if;
  update public.fila_escolha set posicao = v_nova where pasta_id = p_pasta;
end;
$$;

create or replace function public.remover_da_fila(p_pasta uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_pos int;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  delete from public.fila_escolha where pasta_id = p_pasta returning posicao into v_pos;
  if v_pos is not null then update public.fila_escolha set posicao = posicao - 1 where posicao > v_pos; end if;
end;
$$;

-- Corretor (ou imobiliária) reserva a unidade com a pasta liberada
create or replace function public.reservar_pela_fila(p_pasta uuid, p_unidade uuid) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  f public.fila_config;
  p public.pastas;
  u public.unidades;
  v_pos int;
begin
  select * into f from public.fila_config where id = 1;
  if not f.ativa then raise exception 'FILA_DESLIGADA'; end if;
  select * into p from public.pastas where id = p_pasta;
  if not found or not public.acesso_pasta(p.imobiliaria_id, p.criado_por_id) then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if p.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
  select posicao into v_pos from public.fila_escolha where pasta_id = p_pasta;
  if v_pos is null then raise exception 'PASTA_FORA_DA_FILA'; end if;
  if v_pos > public.fila_liberadas() then
    raise exception 'PASTA_AINDA_NAO_LIBERADA' using hint = to_char(public.fila_libera_em(v_pos) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
  end if;
  if (select count(*) from public.negociacoes where pasta_id = p_pasta and ativa) >= f.unidades_por_pasta then
    raise exception 'LIMITE_DE_UNIDADES_DA_PASTA';
  end if;
  select * into u from public.unidades where id = p_unidade for update;
  if not found then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  if u.status <> 'disponivel' then raise exception 'UNIDADE_INDISPONIVEL' using hint = 'Outra pessoa reservou esta unidade agora há pouco.'; end if;

  perform set_config('espelho.sistema', 'sim', true);
  u := public.alterar_status(p_unidade, 'reservada', u.versao, null, null, null, null, null, null, p_pasta);
  perform set_config('espelho.sistema', '', true);
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Unidade reservada pela fila de escolha', jsonb_build_object('unidade', u.numero, 'posicao', v_pos), public.meu_email());
  return u;
end;
$$;

revoke all on function public.fila_liberadas(), public.fila_libera_em(int), public.fila_situacao(), public.minha_fila(),
  public.configurar_fila(boolean, timestamptz, int, int, int), public.montar_fila(), public.mover_na_fila(uuid, int),
  public.remover_da_fila(uuid), public.reservar_pela_fila(uuid, uuid) from public, anon;
grant execute on function public.fila_liberadas(), public.fila_libera_em(int), public.fila_situacao(), public.minha_fila(),
  public.configurar_fila(boolean, timestamptz, int, int, int), public.montar_fila(), public.mover_na_fila(uuid, int),
  public.remover_da_fila(uuid), public.reservar_pela_fila(uuid, uuid) to authenticated;

-- >>>>> supabase/migrations/107_paineis.sql
-- =====================================================================
-- 107 — Painéis da gestão comercial (somente equipe)
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

-- >>>>> supabase/migrations/108_meeting.sql
-- =====================================================================
-- 108 — Meeting: inscrições (como o Sympla) + confirmação de presença
--  * Cada meeting tem um link público de inscrição (/meeting/<endereço>).
--  * A inscrição pede nome completo, e-mail, celular e imobiliária.
--  * Não aceita e-mail nem celular repetidos no mesmo meeting.
--  * Quem se inscreve já aparece na confirmação de presença (recepção).
--  * A equipe cria e edita os meetings, abre/fecha inscrições, define
--    vagas e encerramento, e vê/exporta os inscritos.
-- Executar uma única vez no SQL Editor do Supabase (projeto de testes).
-- =====================================================================

alter table public.recepcao_eventos
  add column if not exists slug               text,
  add column if not exists local              text,
  add column if not exists descricao          text,
  add column if not exists inscricoes_abertas boolean not null default false,
  add column if not exists vagas              int check (vagas is null or vagas > 0),
  add column if not exists encerra_em         timestamptz,
  add column if not exists atualizado_em      timestamptz not null default now();
update public.recepcao_eventos set slug = substr(replace(id::text, '-', ''), 1, 10) where slug is null;
alter table public.recepcao_eventos alter column slug set default substr(md5(random()::text || clock_timestamp()::text), 1, 10);
alter table public.recepcao_eventos alter column slug set not null;
create unique index if not exists recepcao_eventos_slug_idx on public.recepcao_eventos (slug);
alter table public.recepcao_eventos add constraint recepcao_eventos_slug_formato check (slug ~ '^[a-z0-9][a-z0-9-]{2,59}$');

alter table public.recepcao_participantes
  add column if not exists origem      text not null default 'lista' check (origem in ('lista', 'inscricao', 'na_hora')),
  add column if not exists codigo      text,
  add column if not exists inscrito_em timestamptz;

-- e-mail em minúsculas e telefone só com dígitos (sem o 55 do Brasil)
create or replace function public.normalizar_email(p text) returns text language sql immutable as $$
  select nullif(lower(trim(coalesce(p, ''))), '');
$$;
create or replace function public.normalizar_telefone(p text) returns text language sql immutable as $$
  select nullif(case when length(d) in (12, 13) and d like '55%' then substr(d, 3) else d end, '')
    from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x;
$$;
update public.recepcao_participantes set email = public.normalizar_email(email), telefone = public.normalizar_telefone(telefone);

-- Inscrições: não aceita e-mail nem telefone repetidos no mesmo meeting. A função de inscrição
-- confere contra todos da lista; os índices garantem isso mesmo com duas inscrições simultâneas.
-- (Listas importadas pela equipe podem repetir telefone, ex.: o fixo da imobiliária.)
create unique index if not exists recepcao_participantes_email_unico on public.recepcao_participantes (evento_id, email) where email is not null and origem = 'inscricao';
create unique index if not exists recepcao_participantes_telefone_unico on public.recepcao_participantes (evento_id, telefone) where telefone is not null and origem = 'inscricao';

create or replace function public.recepcao_participantes_normalizar() returns trigger
language plpgsql as $$
begin
  new.email := public.normalizar_email(new.email);
  new.telefone := public.normalizar_telefone(new.telefone);
  new.nome := regexp_replace(trim(new.nome), '\s+', ' ', 'g');
  return new;
end;
$$;
drop trigger if exists recepcao_participantes_normalizar on public.recepcao_participantes;
create trigger recepcao_participantes_normalizar before insert or update on public.recepcao_participantes
  for each row execute function public.recepcao_participantes_normalizar();

-- ---------------------------------------------------------------------
-- Página pública (sem login)
-- ---------------------------------------------------------------------
create or replace function public.meeting_publico(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nome', e.nome, 'data_hora', e.data_hora, 'local', e.local, 'descricao', e.descricao,
    'abertas', e.inscricoes_abertas and (e.encerra_em is null or now() < e.encerra_em)
               and (e.vagas is null or (select count(*) from public.recepcao_participantes p where p.evento_id = e.id) < e.vagas),
    'motivo', case when not e.inscricoes_abertas or (e.encerra_em is not null and now() >= e.encerra_em) then 'encerradas'
                   when e.vagas is not null and (select count(*) from public.recepcao_participantes p where p.evento_id = e.id) >= e.vagas then 'esgotadas' end,
    'vagas_restantes', case when e.vagas is null then null
                            else greatest(0, e.vagas - (select count(*) from public.recepcao_participantes p where p.evento_id = e.id)) end)
  from public.recepcao_eventos e where e.slug = lower(trim(p_slug));
$$;

create or replace function public.inscrever_meeting(p_slug text, p_nome text, p_email text, p_telefone text, p_imobiliaria text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e        public.recepcao_eventos;
  v_nome   text := regexp_replace(trim(coalesce(p_nome, '')), '\s+', ' ', 'g');
  v_email  text := public.normalizar_email(p_email);
  v_tel    text := public.normalizar_telefone(p_telefone);
  v_codigo text;
  v_n      int;
begin
  select * into e from public.recepcao_eventos where slug = lower(trim(p_slug)) for update;
  if not found then raise exception 'MEETING_NAO_ENCONTRADO'; end if;
  if not e.inscricoes_abertas or (e.encerra_em is not null and now() >= e.encerra_em) then raise exception 'INSCRICOES_ENCERRADAS'; end if;
  if e.vagas is not null then
    select count(*) into v_n from public.recepcao_participantes where evento_id = e.id;
    if v_n >= e.vagas then raise exception 'VAGAS_ESGOTADAS'; end if;
  end if;
  if length(v_nome) < 5 or position(' ' in v_nome) = 0 then raise exception 'NOME_COMPLETO_OBRIGATORIO'; end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'EMAIL_INVALIDO'; end if;
  if v_tel is null or length(v_tel) not in (10, 11) then raise exception 'TELEFONE_INVALIDO'; end if;
  if exists (select 1 from public.recepcao_participantes where evento_id = e.id and email = v_email) then raise exception 'EMAIL_JA_INSCRITO'; end if;
  if exists (select 1 from public.recepcao_participantes where evento_id = e.id and telefone = v_tel) then raise exception 'TELEFONE_JA_INSCRITO'; end if;

  v_codigo := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
  insert into public.recepcao_participantes (evento_id, nome, email, telefone, imobiliaria, origem, codigo, inscrito_em)
  values (e.id, v_nome, v_email, v_tel, nullif(trim(coalesce(p_imobiliaria, '')), ''), 'inscricao', v_codigo, now());
  return jsonb_build_object('codigo', v_codigo, 'nome', v_nome, 'meeting', e.nome, 'data_hora', e.data_hora, 'local', e.local);
exception when unique_violation then
  -- duas inscrições iguais ao mesmo tempo
  if sqlerrm like '%email%' then raise exception 'EMAIL_JA_INSCRITO'; else raise exception 'TELEFONE_JA_INSCRITO'; end if;
end;
$$;

revoke all on function public.meeting_publico(text), public.inscrever_meeting(text, text, text, text, text) from public;
grant execute on function public.meeting_publico(text), public.inscrever_meeting(text, text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Gestão (equipe)
-- ---------------------------------------------------------------------
create or replace function public.salvar_meeting(
  p_id uuid, p_nome text, p_slug text, p_data_hora timestamptz default null, p_local text default null,
  p_descricao text default null, p_abertas boolean default false, p_vagas int default null, p_encerra_em timestamptz default null
) returns public.recepcao_eventos
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_eventos; v_slug text := lower(trim(coalesce(p_slug, '')));
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if v_slug !~ '^[a-z0-9][a-z0-9-]{2,59}$' then raise exception 'ENDERECO_INVALIDO'; end if;
  if exists (select 1 from public.recepcao_eventos where slug = v_slug and id is distinct from p_id) then raise exception 'ENDERECO_EM_USO'; end if;
  if p_id is null then
    insert into public.recepcao_eventos (nome, slug, data_hora, local, descricao, inscricoes_abertas, vagas, encerra_em)
    values (trim(p_nome), v_slug, p_data_hora, nullif(trim(p_local), ''), nullif(trim(p_descricao), ''), p_abertas, p_vagas, p_encerra_em)
    returning * into v;
  else
    update public.recepcao_eventos
       set nome = trim(p_nome), slug = v_slug, data_hora = p_data_hora, local = nullif(trim(p_local), ''),
           descricao = nullif(trim(p_descricao), ''), inscricoes_abertas = p_abertas, vagas = p_vagas,
           encerra_em = p_encerra_em, atualizado_em = now()
     where id = p_id returning * into v;
    if not found then raise exception 'MEETING_NAO_ENCONTRADO'; end if;
  end if;
  return v;
end;
$$;

create or replace function public.remover_inscricao(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  delete from public.recepcao_participantes where id = p_id;
end;
$$;

-- Incluir na hora: se o celular já é de uma inscrição, a pessoa já está na lista (busque pelo nome)
create or replace function public.incluir_participante(p_evento uuid, p_nome text, p_imobiliaria text default null, p_telefone text default null)
returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes; v_tel text := public.normalizar_telefone(p_telefone);
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if v_tel is not null and exists (select 1 from public.recepcao_participantes where evento_id = p_evento and telefone = v_tel and origem = 'inscricao') then
    raise exception 'TELEFONE_JA_INSCRITO';
  end if;
  insert into public.recepcao_participantes (evento_id, nome, imobiliaria, telefone, presente, chegada_em, confirmado_por, incluido_na_hora, origem)
  values (p_evento, p_nome, nullif(trim(p_imobiliaria), ''), v_tel, true, now(), public.meu_email(), true, 'na_hora')
  returning * into v;
  return v;
end;
$$;

revoke all on function public.salvar_meeting(uuid, text, text, timestamptz, text, text, boolean, int, timestamptz),
  public.remover_inscricao(uuid) from public, anon;
grant execute on function public.salvar_meeting(uuid, text, text, timestamptz, text, text, boolean, int, timestamptz),
  public.remover_inscricao(uuid) to authenticated;
revoke all on function public.incluir_participante(uuid, text, text, text) from public, anon;
grant execute on function public.incluir_participante(uuid, text, text, text) to authenticated;

-- >>>>> supabase/migrations/109_empreendimentos.sql
-- =====================================================================
-- 109 — Vários empreendimentos na mesma incorporadora (Fase 1, etapa A)
--  * Tabela de empreendimentos (nome, endereço, sigla, ordem, ativo).
--  * O primeiro empreendimento nasce da configuração atual (Duo Haus).
--  * Campo "empreendimento" nas tabelas de dados de cada lançamento,
--    preenchido automaticamente com o empreendimento padrão. Nada muda
--    nas telas nesta etapa: tudo continua funcionando como antes.
--  * Restrição de acesso: o administrador pode bloquear um empreendimento
--    para uma imobiliária (padrão: ela vê todos).
--  Decisões (14/11/2026): um banco por incorporadora; imobiliárias veem
--  todos os empreendimentos com restrição opcional; pastas numeradas por
--  empreendimento com sigla (DH-PA-001).
-- =====================================================================

create table if not exists public.empreendimentos (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  sigla      text not null unique check (sigla ~ '^[A-Z0-9]{2,4}$'),
  nome       text not null check (length(trim(nome)) >= 2),
  ativo      boolean not null default true,
  ordem      int not null default 0,
  criado_em  timestamptz not null default now()
);

insert into public.empreendimentos (slug, sigla, nome)
select 'duohaus', 'DH', coalesce(nullif(trim(c.nome_empreendimento), ''), 'Empreendimento')
  from public.config c where c.id = 1
   and not exists (select 1 from public.empreendimentos);

-- empreendimento usado quando nenhum é informado (o primeiro, por ordem)
create or replace function public.empreendimento_padrao() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.empreendimentos order by ordem, criado_em limit 1;
$$;
grant execute on function public.empreendimento_padrao() to anon, authenticated;

-- campo "empreendimento" nas tabelas de dados de lançamento
do $$
declare t text;
begin
  foreach t in array array['unidades', 'negociacoes', 'historico', 'pastas', 'rodadas', 'recepcao_eventos',
                           'portal_itens', 'portal_downloads', 'simulacoes_log', 'propostas'] loop
    if to_regclass('public.' || t) is not null then
      execute format('alter table public.%I add column if not exists empreendimento_id uuid references public.empreendimentos (id)', t);
      execute format('update public.%I set empreendimento_id = public.empreendimento_padrao() where empreendimento_id is null', t);
      execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_padrao()', t);
      execute format('alter table public.%I alter column empreendimento_id set not null', t);
      execute format('create index if not exists %I on public.%I (empreendimento_id)', t || '_empreendimento_idx', t);
    end if;
  end loop;
end $$;

-- negociação e histórico seguem o empreendimento da unidade
create or replace function public.herdar_empreendimento_da_unidade() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.unidade_id is not null then
    select empreendimento_id into new.empreendimento_id from public.unidades where id = new.unidade_id;
  end if;
  return new;
end;
$$;
drop trigger if exists negociacoes_empreendimento on public.negociacoes;
create trigger negociacoes_empreendimento before insert on public.negociacoes
  for each row execute function public.herdar_empreendimento_da_unidade();
drop trigger if exists historico_empreendimento on public.historico;
create trigger historico_empreendimento before insert on public.historico
  for each row execute function public.herdar_empreendimento_da_unidade();
drop trigger if exists propostas_empreendimento on public.propostas;
create trigger propostas_empreendimento before insert on public.propostas
  for each row execute function public.herdar_empreendimento_da_unidade();

-- restrição opcional: imobiliária sem acesso a um empreendimento
create table if not exists public.imobiliarias_bloqueios (
  imobiliaria_id    uuid not null references public.imobiliarias (id) on delete cascade,
  empreendimento_id uuid not null references public.empreendimentos (id) on delete cascade,
  criado_em         timestamptz not null default now(),
  criado_por        text,
  primary key (imobiliaria_id, empreendimento_id)
);

-- quem enxerga cada empreendimento: equipe vê todos; imobiliária/corretor, os não bloqueados
create or replace function public.acesso_empreendimento(p_empreendimento uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe()
      or (auth.uid() is not null and not exists (
            select 1 from public.imobiliarias_bloqueios b
             where b.empreendimento_id = p_empreendimento and b.imobiliaria_id = public.minha_imobiliaria()));
$$;
grant execute on function public.acesso_empreendimento(uuid) to authenticated;

alter table public.empreendimentos enable row level security;
alter table public.imobiliarias_bloqueios enable row level security;
revoke all on public.empreendimentos, public.imobiliarias_bloqueios from anon, authenticated;
grant select on public.empreendimentos to anon, authenticated;
grant select on public.imobiliarias_bloqueios to authenticated;
create policy empreendimentos_leitura on public.empreendimentos for select using (true);
create policy bloqueios_leitura on public.imobiliarias_bloqueios for select
  using (public.eh_equipe() or imobiliaria_id = public.minha_imobiliaria());

-- administrador cadastra empreendimentos e define bloqueios
create or replace function public.salvar_empreendimento(p_id uuid, p_nome text, p_slug text, p_sigla text,
  p_ativo boolean default true, p_ordem int default 0) returns public.empreendimentos
language plpgsql security definer set search_path = public as $$
declare v public.empreendimentos;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_id is null then
    insert into public.empreendimentos (nome, slug, sigla, ativo, ordem)
    values (trim(p_nome), lower(trim(p_slug)), upper(trim(p_sigla)), p_ativo, p_ordem) returning * into v;
  else
    update public.empreendimentos set nome = trim(p_nome), slug = lower(trim(p_slug)), sigla = upper(trim(p_sigla)),
           ativo = p_ativo, ordem = p_ordem where id = p_id returning * into v;
    if not found then raise exception 'EMPREENDIMENTO_NAO_ENCONTRADO'; end if;
  end if;
  return v;
exception when unique_violation then raise exception 'ENDERECO_OU_SIGLA_EM_USO';
end;
$$;

create or replace function public.bloquear_empreendimento(p_imobiliaria uuid, p_empreendimento uuid, p_bloquear boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_bloquear then
    insert into public.imobiliarias_bloqueios (imobiliaria_id, empreendimento_id, criado_por)
    values (p_imobiliaria, p_empreendimento, public.meu_email()) on conflict do nothing;
  else
    delete from public.imobiliarias_bloqueios where imobiliaria_id = p_imobiliaria and empreendimento_id = p_empreendimento;
  end if;
end;
$$;

revoke all on function public.salvar_empreendimento(uuid, text, text, text, boolean, int),
  public.bloquear_empreendimento(uuid, uuid, boolean) from public, anon;
grant execute on function public.salvar_empreendimento(uuid, text, text, text, boolean, int),
  public.bloquear_empreendimento(uuid, uuid, boolean) to authenticated;

-- >>>>> supabase/migrations/110_tabelas_preco.sql
-- =====================================================================
-- 110 — Tabela de vendas com versões e captações
--  * Cada tabela (versão) tem o preço de cada unidade e até 3 captações
--    (fluxos de pagamento em %). Cada unidade aponta para uma captação.
--  * Quantidade de parcelas automática: mensais, semestrais etc. vão até
--    a entrega (com folga configurável), recalculadas pelo mês da venda.
--    Uma tabela de nov/26 usada em fev/27 tem menos mensais, de valor maior.
--  * Vigência sem rotina agendada: a tabela vigente é a última com
--    "vigente_desde" já alcançado. Pode-se agendar a próxima (a partir do
--    dia X, à 0h de Brasília) ou ativar na hora. Até a virada, a tabela
--    nova fica disponível para consulta.
--  * Reajuste por % (todas ou unidades escolhidas) e carga por arquivo,
--    sempre numa tabela em rascunho ou agendada.
--  * A proposta guarda a tabela em que foi feita; só é enviada enquanto
--    essa tabela estiver vigente.
--  A primeira tabela nasce dos preços atuais (R$/m² × peso) e das
--  tabelas 1 e 2, que viram as captações 1 e 2.
-- =====================================================================

create table if not exists public.tabelas_preco (
  id                uuid primary key default gen_random_uuid(),
  empreendimento_id uuid not null default public.empreendimento_padrao() references public.empreendimentos (id),
  nome              text not null check (length(trim(nome)) >= 2),
  mes_referencia    date not null check (extract(day from mes_referencia) = 1),
  vigente_desde     timestamptz,          -- vazio = rascunho
  origem            text not null default 'manual' check (origem in ('inicial', 'arquivo', 'reajuste', 'copia', 'manual')),
  observacao        text,
  base_id           uuid references public.tabelas_preco (id) on delete set null,
  criada_por        text,
  criada_em         timestamptz not null default now(),
  ativada_por       text,
  atualizada_em     timestamptz not null default now()
);
create index if not exists tabelas_preco_emp_idx on public.tabelas_preco (empreendimento_id, vigente_desde);

create table if not exists public.captacoes (
  tabela_id uuid not null references public.tabelas_preco (id) on delete cascade,
  numero    smallint not null check (numero between 1 and 3),
  nome      text not null,
  primary key (tabela_id, numero)
);

create table if not exists public.captacoes_series (
  id            serial primary key,
  tabela_id     uuid not null,
  captacao      smallint not null,
  ordem         int not null,
  rotulo        text not null,
  periodicidade text not null check (periodicidade in ('Sinal', 'Mensais', 'Bimestrais', 'Trimestrais', 'Semestrais', 'Anuais', 'Unica', 'Financiamento')),
  percentual    numeric(10, 8) not null check (percentual > 0 and percentual <= 1),
  qtd           int check (qtd >= 1),       -- vazio = automática até a entrega
  base          text not null check (base in ('venda', 'entrega')),
  meses         int not null,                -- 1ª parcela: meses a partir da base
  fim_meses     int,                         -- automática: última parcela até entrega + fim_meses
  foreign key (tabela_id, captacao) references public.captacoes (tabela_id, numero) on delete cascade,
  unique (tabela_id, captacao, ordem),
  check (qtd is not null or fim_meses is not null)
);

create table if not exists public.tabelas_preco_itens (
  tabela_id  uuid not null references public.tabelas_preco (id) on delete cascade,
  unidade_id uuid not null references public.unidades (id) on delete cascade,
  preco      numeric(14, 2) not null check (preco > 0),
  captacao   smallint not null check (captacao between 1 and 3),
  primary key (tabela_id, unidade_id)
);

alter table public.propostas add column if not exists tabela_id uuid references public.tabelas_preco (id);

-- ---------------------------------------------------------------------
-- Vigência
-- ---------------------------------------------------------------------
create or replace function public.tabela_vigente(p_emp uuid default null) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.tabelas_preco
   where empreendimento_id = coalesce(p_emp, public.empreendimento_padrao()) and vigente_desde <= now()
   order by vigente_desde desc, criada_em desc limit 1;
$$;

create or replace function public.tabela_proxima(p_emp uuid default null) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.tabelas_preco
   where empreendimento_id = coalesce(p_emp, public.empreendimento_padrao()) and vigente_desde > now()
   order by vigente_desde limit 1;
$$;

create or replace function public.situacao_tabela(p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when t.vigente_desde is null then 'rascunho'
              when t.vigente_desde > now() then 'agendada'
              when t.id = public.tabela_vigente(t.empreendimento_id) then 'vigente'
              else 'encerrada' end
    from public.tabelas_preco t where t.id = p_id;
$$;

create or replace function public.hoje_brasilia() returns date
language sql stable set search_path = public as $$ select (now() at time zone 'America/Sao_Paulo')::date; $$;

-- ---------------------------------------------------------------------
-- Fluxo da tabela para uma unidade, no mês da venda
-- ---------------------------------------------------------------------
create or replace function public.mes_venda_tabela(p_tabela uuid, p_data date) returns date
language sql stable security definer set search_path = public as $$
  select greatest(t.mes_referencia, date_trunc('month', coalesce(p_data, public.hoje_brasilia()))::date)
    from public.tabelas_preco t where t.id = p_tabela;
$$;

create or replace function public.series_tabela(p_tabela uuid, p_unidade uuid, p_data date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  with i as (select * from public.tabelas_preco_itens where tabela_id = p_tabela and unidade_id = p_unidade),
       m as (select public.mes_venda_tabela(p_tabela, p_data) as venda, (select mes_entrega from public.comercial where id = 1) as entrega),
       s as (
         select cs.*, i.preco,
                ((case cs.base when 'venda' then m.venda else m.entrega end) + make_interval(months => cs.meses))::date as inicio,
                m.entrega
           from public.captacoes_series cs join i on cs.tabela_id = i.tabela_id and cs.captacao = i.captacao, m
       ),
       q as (
         select s.*, coalesce(s.qtd, greatest(1,
                  floor(public.meses_entre(s.inicio, (s.entrega + make_interval(months => s.fim_meses))::date)::numeric
                        / public.passo_meses(s.periodicidade))::int + 1)) as n
           from s
       )
  select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'qtd', n, 'periodicidade', periodicidade,
                                               'vencimento', inicio, 'valor', percentual * preco / n) order by ordem), '[]')
    from q;
$$;

-- preço da unidade numa tabela (padrão: a vigente do empreendimento da unidade)
drop function if exists public.preco_tabela_unidade(uuid);
create or replace function public.preco_tabela_unidade(p_unidade uuid, p_tabela uuid default null) returns numeric
language sql stable security definer set search_path = public as $$
  select i.preco from public.unidades u
    join public.tabelas_preco_itens i on i.unidade_id = u.id
                                     and i.tabela_id = coalesce(p_tabela, public.tabela_vigente(u.empreendimento_id))
   where u.id = p_unidade;
$$;

-- PV calculado pelo banco: tabela da proposta, no mês da venda
drop function if exists public.pv_proposta(uuid, jsonb, numeric);
create or replace function public.pv_proposta(p_unidade uuid, p_series jsonb, p_comissao numeric default null,
  p_tabela uuid default null, p_data date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c        public.comercial;
  v_tab    uuid;
  v_preco  numeric;
  v_venda  date;
  v_mes_sec int;
  v_vpl_t  numeric := 0;
  v_vpl_p  numeric := 0;
  v_total  numeric := 0;
  v_sinal  numeric := 0;
  v_com    numeric;
  s        record;
  k        int;
  v_mes    int;
begin
  select * into c from public.comercial where id = 1;
  v_tab := coalesce(p_tabela, public.tabela_vigente((select empreendimento_id from public.unidades where id = p_unidade)));
  v_preco := public.preco_tabela_unidade(p_unidade, v_tab);
  if v_preco is null then raise exception 'UNIDADE_SEM_PRECO'; end if;
  v_venda := public.mes_venda_tabela(v_tab, p_data);
  v_mes_sec := public.meses_entre(v_venda, c.mes_entrega) + 1;   -- financiamento: mês seguinte à entrega

  for k in 0 .. 1 loop
    for s in select (e ->> 'qtd')::int as qtd, e ->> 'periodicidade' as periodicidade, (e ->> 'vencimento')::date as vencimento,
                    (e ->> 'valor')::numeric as valor
               from jsonb_array_elements(case k when 0 then public.series_tabela(v_tab, p_unidade, p_data) else p_series end) e loop
      for v_mes in 0 .. s.qtd - 1 loop
        if k = 0 then
          v_vpl_t := v_vpl_t + s.valor / power(1 + c.taxa_vp, case when s.periodicidade = 'Financiamento' then v_mes_sec
                     else public.meses_entre(v_venda, (s.vencimento + make_interval(months => v_mes * public.passo_meses(s.periodicidade)))::date) end);
        else
          v_vpl_p := v_vpl_p + round(s.valor, 2) / power(1 + c.taxa_vp, case when s.periodicidade = 'Financiamento' then v_mes_sec
                     else public.meses_entre(v_venda, (s.vencimento + make_interval(months => v_mes * public.passo_meses(s.periodicidade)))::date) end);
          v_total := v_total + round(s.valor, 2);
          if s.periodicidade = 'Sinal' then v_sinal := v_sinal + round(s.valor, 2); end if;
        end if;
      end loop;
    end loop;
  end loop;

  v_com := round(v_total * coalesce(p_comissao, c.comissao_pct), 2);
  return jsonb_build_object(
    'tabela_id', v_tab, 'preco_tabela', round(v_preco, 2), 'total', round(v_total, 2),
    'vpl_tabela', round(v_vpl_t, 2), 'vpl_proposta', round(v_vpl_p, 2),
    'diferenca_vpl', round(v_vpl_p - v_vpl_t, 2),
    'pv_pct', round(v_vpl_p / nullif(v_vpl_t, 0) * 100, 2),
    'sinal', round(v_sinal, 2), 'comissao', v_com,
    'comissao_coberta', v_sinal * c.parte_sinal + 0.01 >= v_com,
    'calculado_pelo_banco', true);
end;
$$;

-- ---------------------------------------------------------------------
-- Carga inicial: preços atuais e tabelas 1/2 → captações 1/2
-- ---------------------------------------------------------------------
do $$
declare v_tab uuid; c public.comercial;
begin
  if exists (select 1 from public.tabelas_preco) then return; end if;
  select * into c from public.comercial where id = 1;
  if c is null or not exists (select 1 from public.unidades where tipo_preco is not null and peso is not null and tabela is not null) then return; end if;

  insert into public.tabelas_preco (nome, mes_referencia, vigente_desde, origem, criada_por, ativada_por)
  values ('Tabela ' || to_char(c.mes_tabela, 'MM/YYYY'), c.mes_tabela, now(), 'inicial', 'sistema', 'sistema')
  returning id into v_tab;

  create temp table _cap on commit drop as
    select nome as tabela, row_number() over (order by nome)::smallint as numero
      from public.tabelas_venda where nome in (select distinct tabela from public.unidades where tabela is not null) limit 3;

  insert into public.captacoes (tabela_id, numero, nome) select v_tab, numero, 'Captação ' || numero from _cap;

  insert into public.captacoes_series (tabela_id, captacao, ordem, rotulo, periodicidade, percentual, qtd, base, meses, fim_meses)
  select v_tab, x.numero, s.ordem, s.rotulo, s.periodicidade, s.percentual,
         case when x.auto then null else s.qtd end, s.base, s.meses,
         case when x.auto then least(0, x.ultima + public.passo_meses(s.periodicidade) - 1) end
    from public.tabelas_series s
    join lateral (
      select _cap.numero,
             public.meses_entre(c.mes_entrega, (c.mes_tabela + make_interval(months => s.meses + (s.qtd - 1) * public.passo_meses(s.periodicidade)))::date) as ultima,
             s.base = 'venda' and s.qtd > 1 and s.periodicidade in ('Mensais', 'Bimestrais', 'Trimestrais', 'Semestrais', 'Anuais')
             and public.meses_entre(c.mes_entrega, (c.mes_tabela + make_interval(months => s.meses + (s.qtd - 1) * public.passo_meses(s.periodicidade)))::date) <= 0 as auto
        from _cap where _cap.tabela = s.tabela) x on true
   where s.percentual > 0;

  insert into public.tabelas_preco_itens (tabela_id, unidade_id, preco, captacao)
  select v_tab, u.id,
         round(pt.preco_m2 * u.peso * u.area_privativa
               / (select avg(y.peso) from public.unidades y where y.tipo_preco = u.tipo_preco and y.peso is not null), 2),
         _cap.numero
    from public.unidades u join public.precos_tipo pt on pt.tipo = u.tipo_preco join _cap on _cap.tabela = u.tabela
   where u.area_privativa is not null and u.peso is not null;

  update public.propostas set tabela_id = v_tab where tabela_id is null;
end $$;

-- ---------------------------------------------------------------------
-- Propostas: tabela da proposta
-- ---------------------------------------------------------------------
create or replace function public.propostas_tabela() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_vig uuid;
begin
  v_vig := public.tabela_vigente((select empreendimento_id from public.unidades where id = new.unidade_id));
  if tg_op = 'INSERT' then
    new.tabela_id := v_vig;
  elsif new.tabela_id is distinct from old.tabela_id then
    -- trocar de tabela só para a vigente; a proposta passa a ser de hoje
    if new.tabela_id is distinct from v_vig then raise exception 'TABELA_NAO_VIGENTE'; end if;
    new.data_proposta := public.hoje_brasilia();
    if exists (select 1 from jsonb_array_elements(new.series) x where (x ->> 'vencimento')::date < new.data_proposta) then
      raise exception 'VENCIMENTO_ANTERIOR' using hint = 'Nenhum vencimento pode ser anterior à data da proposta.';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists propostas_tabela on public.propostas;
create trigger propostas_tabela before insert or update on public.propostas
  for each row execute function public.propostas_tabela();

create or replace function public.enviar_proposta(p_id uuid) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v   public.propostas;
  c   public.comercial;
  r   jsonb;
  v_alcada text;
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
  if v.tabela_id is distinct from public.tabela_vigente(v.empreendimento_id) then
    raise exception 'TABELA_ENCERRADA' using hint = 'A tabela desta proposta não está mais vigente. Atualize para a tabela vigente.';
  end if;

  select * into c from public.comercial where id = 1;
  r := public.pv_proposta(v.unidade_id, v.series, v.comissao_pct, v.tabela_id, v.data_proposta);
  v_alcada := case
    when c.alcada_automatica and (r ->> 'pv_pct')::numeric >= c.alcada_auto_pv and (r ->> 'comissao_coberta')::boolean then 'automatica'
    when (r ->> 'pv_pct')::numeric >= c.alcada_vendas_pv then 'vendas'
    else 'admin' end;

  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas
     set status = 'enviada', enviada_em = now(), motivo_analise = null, alcada = v_alcada,
         resumo = coalesce(resumo, '{}') || r
   where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);

  if v_alcada = 'automatica' then
    v := public.aprovar_proposta_interno(p_id, 'Aprovação automática (PV ' || (r ->> 'pv_pct') || '%)');
  end if;
  return v;
end;
$$;

-- ---------------------------------------------------------------------
-- Gestão das tabelas (administrador)
-- ---------------------------------------------------------------------
create or replace function public.tabela_para_editar(p_tabela uuid) returns public.tabelas_preco
language plpgsql security definer set search_path = public as $$
declare t public.tabelas_preco;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select * into t from public.tabelas_preco where id = p_tabela for update;
  if not found then raise exception 'TABELA_NAO_ENCONTRADA'; end if;
  if t.vigente_desde is not null and t.vigente_desde <= now() then
    raise exception 'TABELA_JA_VIGENTE' using hint = 'Tabela vigente ou encerrada não muda. Crie uma nova tabela.';
  end if;
  return t;
end;
$$;

-- nova tabela: cópia da base (padrão: a vigente), com reajuste opcional
create or replace function public.nova_tabela(p_nome text, p_mes date, p_base uuid default null,
  p_reajuste numeric default null, p_unidades uuid[] default null, p_emp uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_emp uuid := coalesce(p_emp, public.empreendimento_padrao()); v_base uuid; v_id uuid;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_reajuste is not null and (p_reajuste <= -0.5 or p_reajuste > 1) then raise exception 'REAJUSTE_INVALIDO'; end if;
  v_base := coalesce(p_base, public.tabela_vigente(v_emp));
  insert into public.tabelas_preco (empreendimento_id, nome, mes_referencia, origem, base_id, criada_por)
  values (v_emp, trim(p_nome), date_trunc('month', p_mes)::date,
          case when v_base is null then 'manual' when p_reajuste is not null then 'reajuste' else 'copia' end, v_base, public.meu_email())
  returning id into v_id;
  if v_base is not null then
    insert into public.captacoes (tabela_id, numero, nome) select v_id, numero, nome from public.captacoes where tabela_id = v_base;
    insert into public.captacoes_series (tabela_id, captacao, ordem, rotulo, periodicidade, percentual, qtd, base, meses, fim_meses)
    select v_id, captacao, ordem, rotulo, periodicidade, percentual, qtd, base, meses, fim_meses from public.captacoes_series where tabela_id = v_base;
    insert into public.tabelas_preco_itens (tabela_id, unidade_id, preco, captacao)
    select v_id, unidade_id,
           case when p_reajuste is not null and (p_unidades is null or unidade_id = any (p_unidades)) then round(preco * (1 + p_reajuste), 2) else preco end,
           captacao
      from public.tabelas_preco_itens where tabela_id = v_base;
  end if;
  return v_id;
end;
$$;

create or replace function public.salvar_dados_tabela(p_tabela uuid, p_nome text, p_mes date, p_observacao text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.tabela_para_editar(p_tabela);
  update public.tabelas_preco set nome = trim(p_nome), mes_referencia = date_trunc('month', p_mes)::date,
         observacao = nullif(trim(coalesce(p_observacao, '')), ''), atualizada_em = now()
   where id = p_tabela;
end;
$$;

-- reajuste por % (todas as unidades ou as escolhidas)
create or replace function public.reajustar_tabela(p_tabela uuid, p_pct numeric, p_unidades uuid[] default null) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform public.tabela_para_editar(p_tabela);
  if p_pct is null or p_pct <= -0.5 or p_pct > 1 or p_pct = 0 then raise exception 'REAJUSTE_INVALIDO'; end if;
  update public.tabelas_preco_itens set preco = round(preco * (1 + p_pct), 2)
   where tabela_id = p_tabela and (p_unidades is null or unidade_id = any (p_unidades));
  get diagnostics n = row_count;
  update public.tabelas_preco set atualizada_em = now() where id = p_tabela;
  return n;
end;
$$;

-- preço/captação de uma unidade
create or replace function public.definir_item_tabela(p_tabela uuid, p_unidade uuid, p_preco numeric, p_captacao smallint)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.tabela_para_editar(p_tabela);
  if p_preco is null or p_preco <= 0 then raise exception 'PRECO_INVALIDO'; end if;
  if not exists (select 1 from public.captacoes where tabela_id = p_tabela and numero = p_captacao) then raise exception 'CAPTACAO_INEXISTENTE'; end if;
  insert into public.tabelas_preco_itens (tabela_id, unidade_id, preco, captacao) values (p_tabela, p_unidade, round(p_preco, 2), p_captacao)
  on conflict (tabela_id, unidade_id) do update set preco = excluded.preco, captacao = excluded.captacao;
  update public.tabelas_preco set atualizada_em = now() where id = p_tabela;
end;
$$;

-- carga por arquivo: [{numero, preco, captacao, area?, tipologia?}]
create or replace function public.importar_tabela(p_tabela uuid, p_linhas jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  t public.tabelas_preco;
  erros text[] := '{}';
  l record;
  n_precos int := 0; n_unid int := 0;
begin
  t := public.tabela_para_editar(p_tabela);
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then raise exception 'ARQUIVO_VAZIO'; end if;

  for l in
    select x.numero, x.preco, x.captacao, x.area, nullif(trim(x.tipologia), '') as tipologia, u.id as unidade_id,
           count(*) over (partition by x.numero) as repeticoes
      from jsonb_to_recordset(p_linhas) as x(numero text, preco numeric, captacao smallint, area numeric, tipologia text)
      left join public.unidades u on u.numero = trim(x.numero) and u.empreendimento_id = t.empreendimento_id
  loop
    if l.unidade_id is null then erros := erros || ('Unidade ' || coalesce(l.numero, '?') || ' não existe');
    elsif l.repeticoes > 1 then erros := erros || ('Unidade ' || l.numero || ' repetida');
    elsif l.preco is null or l.preco <= 0 then erros := erros || ('Unidade ' || l.numero || ': preço inválido');
    elsif not exists (select 1 from public.captacoes where tabela_id = p_tabela and numero = l.captacao) then
      erros := erros || ('Unidade ' || l.numero || ': captação ' || coalesce(l.captacao::text, 'vazia') || ' não cadastrada');
    elsif l.area is not null and l.area <= 0 then erros := erros || ('Unidade ' || l.numero || ': área inválida');
    end if;
  end loop;
  if cardinality(erros) > 0 then
    raise exception 'ARQUIVO_INVALIDO' using detail = array_to_string(erros[1:20], '; ');
  end if;

  insert into public.tabelas_preco_itens (tabela_id, unidade_id, preco, captacao)
  select p_tabela, u.id, round(x.preco, 2), x.captacao
    from jsonb_to_recordset(p_linhas) as x(numero text, preco numeric, captacao smallint)
    join public.unidades u on u.numero = trim(x.numero) and u.empreendimento_id = t.empreendimento_id
  on conflict (tabela_id, unidade_id) do update set preco = excluded.preco, captacao = excluded.captacao;
  get diagnostics n_precos = row_count;

  -- informações da unidade (área e tipologia), quando vierem no arquivo
  update public.unidades u set
         area_privativa = coalesce(x.area, u.area_privativa),
         tipologia = coalesce(nullif(trim(x.tipologia), ''), u.tipologia)
    from jsonb_to_recordset(p_linhas) as x(numero text, area numeric, tipologia text)
   where u.numero = trim(x.numero) and u.empreendimento_id = t.empreendimento_id
     and ((x.area is not null and x.area is distinct from u.area_privativa)
       or (nullif(trim(x.tipologia), '') is not null and trim(x.tipologia) is distinct from u.tipologia));
  get diagnostics n_unid = row_count;

  update public.tabelas_preco set origem = case when origem = 'manual' then 'arquivo' else origem end, atualizada_em = now() where id = p_tabela;
  return jsonb_build_object('precos', n_precos, 'unidades_atualizadas', n_unid);
end;
$$;

-- captações (até 3), cada uma somando 100%
create or replace function public.salvar_captacoes(p_tabela uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare c jsonb; s jsonb; v_soma numeric; v_ordem int;
begin
  perform public.tabela_para_editar(p_tabela);
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) not between 1 and 3 then raise exception 'CAPTACOES_1_A_3'; end if;
  for c in select * from jsonb_array_elements(p) loop
    if (c ->> 'numero')::int not between 1 and 3 then raise exception 'CAPTACOES_1_A_3'; end if;
    select coalesce(sum((x ->> 'percentual')::numeric), 0) into v_soma from jsonb_array_elements(c -> 'series') x;
    if abs(v_soma - 1) > 0.000001 then
      raise exception 'CAPTACAO_NAO_SOMA_100' using detail = coalesce(c ->> 'nome', 'Captação ' || (c ->> 'numero')) || ' soma ' || round(v_soma * 100, 4) || '%';
    end if;
  end loop;
  if exists (select 1 from public.tabelas_preco_itens i where i.tabela_id = p_tabela
              and i.captacao not in (select (x ->> 'numero')::int from jsonb_array_elements(p) x)) then
    raise exception 'CAPTACAO_EM_USO' using hint = 'Há unidades ligadas a uma captação removida. Troque a captação delas antes.';
  end if;

  delete from public.captacoes where tabela_id = p_tabela;
  for c in select * from jsonb_array_elements(p) loop
    insert into public.captacoes (tabela_id, numero, nome)
    values (p_tabela, (c ->> 'numero')::int, coalesce(nullif(trim(c ->> 'nome'), ''), 'Captação ' || (c ->> 'numero')));
    v_ordem := 0;
    for s in select * from jsonb_array_elements(c -> 'series') loop
      v_ordem := v_ordem + 1;
      insert into public.captacoes_series (tabela_id, captacao, ordem, rotulo, periodicidade, percentual, qtd, base, meses, fim_meses)
      values (p_tabela, (c ->> 'numero')::int, v_ordem, coalesce(nullif(trim(s ->> 'rotulo'), ''), s ->> 'periodicidade'), s ->> 'periodicidade',
              (s ->> 'percentual')::numeric, nullif(s ->> 'qtd', '')::int, s ->> 'base', (s ->> 'meses')::int,
              case when nullif(s ->> 'qtd', '') is null then coalesce(nullif(s ->> 'fim_meses', '')::int, 0) end);
    end loop;
  end loop;
  update public.tabelas_preco set atualizada_em = now() where id = p_tabela;
end;
$$;

-- ativar agora (p_data vazio ou hoje) ou agendar para o dia, à 0h de Brasília
create or replace function public.ativar_tabela(p_tabela uuid, p_data date default null) returns public.tabelas_preco
language plpgsql security definer set search_path = public as $$
declare t public.tabelas_preco; v_quando timestamptz; v_faltam int; v_cap record;
begin
  t := public.tabela_para_editar(p_tabela);
  if not exists (select 1 from public.captacoes where tabela_id = p_tabela) then raise exception 'TABELA_SEM_CAPTACAO'; end if;
  for v_cap in select c.nome, coalesce(sum(s.percentual), 0) as soma from public.captacoes c
                 left join public.captacoes_series s on s.tabela_id = c.tabela_id and s.captacao = c.numero
                where c.tabela_id = p_tabela group by c.nome loop
    if abs(v_cap.soma - 1) > 0.000001 then raise exception 'CAPTACAO_NAO_SOMA_100' using detail = v_cap.nome; end if;
  end loop;
  select count(*) into v_faltam from public.unidades u
   where u.empreendimento_id = t.empreendimento_id
     and not exists (select 1 from public.tabelas_preco_itens i where i.tabela_id = p_tabela and i.unidade_id = u.id);
  if v_faltam > 0 then raise exception 'TABELA_INCOMPLETA' using detail = v_faltam || ' unidade(s) sem preço'; end if;

  if p_data is null or p_data <= public.hoje_brasilia() then
    v_quando := now();
  else
    v_quando := p_data::timestamp at time zone 'America/Sao_Paulo';
    if exists (select 1 from public.tabelas_preco where empreendimento_id = t.empreendimento_id and id <> p_tabela and vigente_desde > now()) then
      raise exception 'JA_EXISTE_TABELA_AGENDADA' using hint = 'Cancele o agendamento da outra tabela antes.';
    end if;
  end if;
  update public.tabelas_preco set vigente_desde = v_quando, ativada_por = public.meu_email(), atualizada_em = now()
   where id = p_tabela returning * into t;
  -- ativada na hora: qualquer agendamento anterior a ela perde o sentido
  if v_quando <= now() then
    update public.tabelas_preco set vigente_desde = null
     where empreendimento_id = t.empreendimento_id and id <> p_tabela and vigente_desde > now();
  end if;
  return t;
end;
$$;

create or replace function public.cancelar_agendamento(p_tabela uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.tabela_para_editar(p_tabela);
  update public.tabelas_preco set vigente_desde = null, ativada_por = null, atualizada_em = now() where id = p_tabela;
end;
$$;

create or replace function public.excluir_tabela(p_tabela uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.tabelas_preco;
begin
  t := public.tabela_para_editar(p_tabela);
  if t.vigente_desde is not null then raise exception 'TABELA_AGENDADA' using hint = 'Cancele o agendamento antes de excluir.'; end if;
  if exists (select 1 from public.propostas where tabela_id = p_tabela) then raise exception 'TABELA_COM_PROPOSTAS'; end if;
  delete from public.tabelas_preco where id = p_tabela;
end;
$$;

-- ---------------------------------------------------------------------
-- Leitura
-- ---------------------------------------------------------------------
create or replace view public.tabelas_preco_resumo with (security_invoker = true) as
select t.id, t.empreendimento_id, t.nome, t.mes_referencia, t.vigente_desde, t.origem, t.observacao, t.base_id,
       t.criada_por, t.criada_em, t.ativada_por, t.atualizada_em,
       case when t.vigente_desde is null then 'rascunho'
            when t.vigente_desde > now() then 'agendada'
            when t.id = public.tabela_vigente(t.empreendimento_id) then 'vigente'
            else 'encerrada' end as situacao,
       (select count(*) from public.tabelas_preco_itens i where i.tabela_id = t.id) as unidades,
       (select coalesce(sum(i.preco), 0) from public.tabelas_preco_itens i where i.tabela_id = t.id) as vgv
  from public.tabelas_preco t;

alter table public.tabelas_preco enable row level security;
alter table public.captacoes enable row level security;
alter table public.captacoes_series enable row level security;
alter table public.tabelas_preco_itens enable row level security;
revoke all on public.tabelas_preco, public.captacoes, public.captacoes_series, public.tabelas_preco_itens, public.tabelas_preco_resumo from anon, authenticated;
grant select on public.tabelas_preco, public.captacoes, public.captacoes_series, public.tabelas_preco_itens, public.tabelas_preco_resumo to authenticated;

-- equipe vê todas; corretores e imobiliárias, só as publicadas (vigente, agendada e antigas) dos empreendimentos liberados
drop policy if exists tabelas_preco_leitura on public.tabelas_preco;
create policy tabelas_preco_leitura on public.tabelas_preco for select
  using (public.eh_equipe() or (auth.uid() is not null and vigente_desde is not null and public.acesso_empreendimento(empreendimento_id)));
drop policy if exists captacoes_leitura on public.captacoes;
create policy captacoes_leitura on public.captacoes for select using (exists (select 1 from public.tabelas_preco t where t.id = tabela_id));
drop policy if exists captacoes_series_leitura on public.captacoes_series;
create policy captacoes_series_leitura on public.captacoes_series for select using (exists (select 1 from public.tabelas_preco t where t.id = tabela_id));
drop policy if exists tabelas_itens_leitura on public.tabelas_preco_itens;
create policy tabelas_itens_leitura on public.tabelas_preco_itens for select using (exists (select 1 from public.tabelas_preco t where t.id = tabela_id));

revoke all on function public.nova_tabela(text, date, uuid, numeric, uuid[], uuid), public.salvar_dados_tabela(uuid, text, date, text),
  public.reajustar_tabela(uuid, numeric, uuid[]), public.definir_item_tabela(uuid, uuid, numeric, smallint),
  public.importar_tabela(uuid, jsonb), public.salvar_captacoes(uuid, jsonb), public.ativar_tabela(uuid, date),
  public.cancelar_agendamento(uuid), public.excluir_tabela(uuid), public.tabela_para_editar(uuid),
  public.pv_proposta(uuid, jsonb, numeric, uuid, date), public.preco_tabela_unidade(uuid, uuid),
  public.series_tabela(uuid, uuid, date), public.tabela_vigente(uuid), public.tabela_proxima(uuid),
  public.situacao_tabela(uuid), public.mes_venda_tabela(uuid, date), public.propostas_tabela() from public, anon;
grant execute on function public.nova_tabela(text, date, uuid, numeric, uuid[], uuid), public.salvar_dados_tabela(uuid, text, date, text),
  public.reajustar_tabela(uuid, numeric, uuid[]), public.definir_item_tabela(uuid, uuid, numeric, smallint),
  public.importar_tabela(uuid, jsonb), public.salvar_captacoes(uuid, jsonb), public.ativar_tabela(uuid, date),
  public.cancelar_agendamento(uuid), public.excluir_tabela(uuid),
  public.pv_proposta(uuid, jsonb, numeric, uuid, date), public.preco_tabela_unidade(uuid, uuid),
  public.series_tabela(uuid, uuid, date), public.tabela_vigente(uuid), public.tabela_proxima(uuid),
  public.situacao_tabela(uuid), public.mes_venda_tabela(uuid, date) to authenticated;

-- >>>>> supabase/migrations/111_simulador_cenarios.sql
-- =====================================================================
-- 111 — Simulador do Portal com cenários livres
--  * config.simulador passa a ser {"cenarios": [...]}. Cada cenário tem
--    nome (tipologia, metragem, posição...), descrição opcional, de 1 a 6
--    preços de referência (rótulo + valor), captação mínima e fluxo padrão
--    (ato, 30/60/90, mensais, semestrais/anuais, única).
--  * Os dados antigos (Poente/Nascente) viram dois cenários.
--  * Quantidade máxima de parcelas: calculada na tela pela data de entrega.
-- =====================================================================

update public.config
   set simulador = jsonb_build_object('cenarios', (
         select jsonb_agg(jsonb_build_object(
                  'id', k, 'nome', initcap(k), 'descricao', '',
                  'precos', jsonb_build_array(
                     jsonb_build_object('rotulo', 'A partir de', 'valor', (simulador -> k ->> 'a_partir')::numeric),
                     jsonb_build_object('rotulo', 'Preço médio', 'valor', (simulador -> k ->> 'medio')::numeric)),
                  'captacao', (simulador -> k ->> 'captacao')::numeric,
                  'pct', simulador -> k -> 'pct') order by k desc)
           from unnest(array['poente', 'nascente']) k where simulador ? k))
 where id = 1 and simulador ? 'poente' and not simulador ? 'cenarios';

create or replace function public.salvar_simulador(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare c jsonb; pr jsonb; s numeric;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if jsonb_typeof(p -> 'cenarios') <> 'array' or jsonb_array_length(p -> 'cenarios') not between 1 and 30 then
    raise exception 'CENARIOS_INVALIDOS';
  end if;
  for c in select * from jsonb_array_elements(p -> 'cenarios') loop
    if length(trim(coalesce(c ->> 'nome', ''))) < 2 or length(coalesce(c ->> 'id', '')) < 1 then raise exception 'NOME_INVALIDO'; end if;
    if jsonb_typeof(c -> 'precos') <> 'array' or jsonb_array_length(c -> 'precos') not between 1 and 6 then raise exception 'PRECO_INVALIDO'; end if;
    for pr in select * from jsonb_array_elements(c -> 'precos') loop
      if coalesce((pr ->> 'valor')::numeric, 0) <= 0 or length(trim(coalesce(pr ->> 'rotulo', ''))) = 0 then raise exception 'PRECO_INVALIDO'; end if;
    end loop;
    if coalesce((c ->> 'captacao')::numeric, 0) not between 1 and 100 then raise exception 'CAPTACAO_INVALIDA'; end if;
    if coalesce((c #>> '{pct,unica}')::numeric, 0) > 5 then raise exception 'UNICA_ACIMA_DO_LIMITE'; end if;
    select sum(v::numeric) into s from jsonb_each_text(c -> 'pct') as x(k, v);
    if s is null or s > 100 or s < (c ->> 'captacao')::numeric then raise exception 'FLUXO_PADRAO_INVALIDO'; end if;
  end loop;
  update public.config set simulador = jsonb_build_object('cenarios', p -> 'cenarios'), atualizado_em = now() where id = 1;
end;
$$;
revoke all on function public.salvar_simulador(jsonb) from public, anon;
grant execute on function public.salvar_simulador(jsonb) to authenticated;

-- >>>>> supabase/migrations/112_empreendimento_atual.sql
-- =====================================================================
-- 112 — Vários empreendimentos (Fase 1, etapas B a E, banco)
--  * Cada login trabalha num "empreendimento atual" (guardado no perfil).
--    O banco filtra por ele espelho, pastas, negociações, histórico,
--    propostas, rodadas, Meeting, Portal e tabela de vendas: as telas
--    não precisam mudar as consultas.
--  * Identidade e módulos (config), dados comerciais (comercial) e a fila
--    de escolha (fila_config / fila_escolha) passam a ser por empreendimento.
--  * Pastas e fila são de cada empreendimento. Códigos com a sigla:
--    DH-P-001 (pasta) e DH-PA-001 (submetida ao incorporador).
--  * Unidades: número e posição únicos dentro do empreendimento.
--  * Painéis com visão consolidada da incorporadora (todos os empreendimentos).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Empreendimento atual
-- ---------------------------------------------------------------------
alter table public.perfis add column if not exists empreendimento_atual uuid references public.empreendimentos (id) on delete set null;
alter table public.empreendimentos add column if not exists seq_pasta int not null default 0;
alter table public.empreendimentos add column if not exists seq_aprovacao int not null default 0;

-- pode trabalhar no empreendimento: equipe em todos; imobiliária/corretor nos ativos e não bloqueados
create or replace function public.pode_usar_empreendimento(p_emp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.empreendimentos e where e.id = p_emp
                  and (public.eh_equipe() or (e.ativo and public.acesso_empreendimento(e.id))));
$$;

create or replace function public.empreendimento_atual() returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.empreendimento_atual from public.perfis p
      where p.user_id = auth.uid() and p.empreendimento_atual is not null and public.pode_usar_empreendimento(p.empreendimento_atual)),
    (select e.id from public.empreendimentos e
      where e.ativo and (auth.uid() is null or public.pode_usar_empreendimento(e.id))
      order by e.ordem, e.criado_em limit 1),
    public.empreendimento_padrao());
$$;

create or replace function public.escolher_empreendimento(p_emp uuid) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.pode_usar_empreendimento(p_emp) then raise exception 'EMPREENDIMENTO_SEM_ACESSO'; end if;
  update public.perfis set empreendimento_atual = p_emp where user_id = auth.uid();
  return p_emp;
end;
$$;

-- empreendimentos que o login pode usar, com o atual marcado
create or replace function public.meus_empreendimentos() returns table (id uuid, slug text, sigla text, nome text, ativo boolean, atual boolean, escolhido boolean)
language sql stable security definer set search_path = public as $$
  select e.id, e.slug, e.sigla, e.nome, e.ativo, e.id = public.empreendimento_atual(),
         exists (select 1 from public.perfis p where p.user_id = auth.uid() and p.empreendimento_atual is not null)
    from public.empreendimentos e
   where auth.uid() is not null and public.pode_usar_empreendimento(e.id)
   order by e.ordem, e.criado_em;
$$;

-- ---------------------------------------------------------------------
-- Configuração, dados comerciais e fila: uma linha por empreendimento
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['config', 'comercial', 'fila_config'] loop
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_id_check');
    execute format('create sequence if not exists public.%I', t || '_id_seq');
    execute format('select setval(%L, greatest((select max(id) from public.%I), 1))', 'public.' || t || '_id_seq', t);
    execute format('alter table public.%I alter column id set default nextval(%L)', t, 'public.' || t || '_id_seq');
    execute format('alter table public.%I add column if not exists empreendimento_id uuid references public.empreendimentos (id) on delete cascade', t);
    execute format('update public.%I set empreendimento_id = public.empreendimento_padrao() where empreendimento_id is null', t);
    execute format('alter table public.%I alter column empreendimento_id set not null', t);
    execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_atual()', t);
    execute format('create unique index if not exists %I on public.%I (empreendimento_id)', t || '_empreendimento_key', t);
    -- cada login lê (e o admin altera) só a linha do empreendimento atual
    execute format('drop policy if exists %I on public.%I', t || '_do_empreendimento', t);
    execute format('create policy %I on public.%I as restrictive for all using (empreendimento_id = (select public.empreendimento_atual())) with check (empreendimento_id = (select public.empreendimento_atual()))', t || '_do_empreendimento', t);
  end loop;
end $$;
grant usage on sequence public.config_id_seq, public.comercial_id_seq, public.fila_config_id_seq to authenticated;

create or replace function public.comercial_de(p_emp uuid) returns public.comercial
language sql stable security definer set search_path = public as $$
  select * from public.comercial where empreendimento_id = p_emp;
$$;

-- ---------------------------------------------------------------------
-- Dados de lançamento: filtrados pelo empreendimento atual
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['unidades', 'negociacoes', 'historico', 'pastas', 'rodadas', 'recepcao_eventos',
                           'portal_itens', 'portal_downloads', 'simulacoes_log', 'propostas', 'tabelas_preco'] loop
    if to_regclass('public.' || t) is not null then
      execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_atual()', t);
      execute format('drop policy if exists %I on public.%I', t || '_do_empreendimento', t);
      execute format('create policy %I on public.%I as restrictive for select using (empreendimento_id = (select public.empreendimento_atual()))', t || '_do_empreendimento', t);
    end if;
  end loop;
end $$;

-- espelho público (TV/link) conforme a configuração do próprio empreendimento
drop policy if exists unidades_leitura on public.unidades;
create policy unidades_leitura on public.unidades for select using (
  (select c.publico_ativo from public.config c where c.empreendimento_id = unidades.empreendimento_id)
  or public.eh_equipe() or public.minha_imobiliaria() is not null);

-- número e posição únicos dentro de cada empreendimento
alter table public.unidades drop constraint if exists unidades_numero_key;
alter table public.unidades drop constraint if exists unidades_andar_posicao_key;
create unique index if not exists unidades_emp_numero_key on public.unidades (empreendimento_id, numero);
create unique index if not exists unidades_emp_andar_posicao_key on public.unidades (empreendimento_id, andar, posicao);

-- negociação: pasta e unidade do mesmo empreendimento
create or replace function public.negociacao_mesmo_empreendimento() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.pasta_id is not null
     and (select empreendimento_id from public.pastas where id = new.pasta_id)
         is distinct from (select empreendimento_id from public.unidades where id = new.unidade_id) then
    raise exception 'PASTA_DE_OUTRO_EMPREENDIMENTO' using hint = 'A pasta pertence a outro empreendimento.';
  end if;
  return new;
end;
$$;
drop trigger if exists negociacoes_mesmo_empreendimento on public.negociacoes;
create trigger negociacoes_mesmo_empreendimento before insert or update of unidade_id, pasta_id on public.negociacoes
  for each row execute function public.negociacao_mesmo_empreendimento();

-- ---------------------------------------------------------------------
-- Códigos das pastas com a sigla do empreendimento
-- ---------------------------------------------------------------------
update public.empreendimentos e set
  seq_pasta = greatest(e.seq_pasta, coalesce((select max(nullif(regexp_replace(p.codigo, '\D', '', 'g'), '')::int) from public.pastas p where p.empreendimento_id = e.id), 0)),
  seq_aprovacao = greatest(e.seq_aprovacao, coalesce((select max(nullif(regexp_replace(p.codigo_aprovacao, '\D', '', 'g'), '')::int) from public.pastas p where p.empreendimento_id = e.id), 0));
update public.pastas p set
  codigo = e.sigla || '-' || p.codigo,
  codigo_aprovacao = case when p.codigo_aprovacao is null then null else e.sigla || '-' || p.codigo_aprovacao end
  from public.empreendimentos e
 where e.id = p.empreendimento_id and p.codigo !~ '^[A-Z0-9]{2,4}-P';

create or replace function public.proximo_codigo(p_emp uuid, p_tipo text) returns text
language plpgsql security definer set search_path = public as $$
declare v_sigla text; v_n int;
begin
  if p_tipo = 'PA' then
    update public.empreendimentos set seq_aprovacao = seq_aprovacao + 1 where id = p_emp returning sigla, seq_aprovacao into v_sigla, v_n;
  else
    update public.empreendimentos set seq_pasta = seq_pasta + 1 where id = p_emp returning sigla, seq_pasta into v_sigla, v_n;
  end if;
  return v_sigla || '-' || public.formatar_codigo(p_tipo, v_n);
end;
$$;

alter table public.pastas alter column codigo set default public.proximo_codigo(public.empreendimento_atual(), 'P');
-- pasta gravada noutro empreendimento que não o atual: código com a sigla certa
create or replace function public.pastas_codigo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.codigo is null or split_part(new.codigo, '-', 1) is distinct from (select sigla from public.empreendimentos where id = new.empreendimento_id) then
    new.codigo := public.proximo_codigo(new.empreendimento_id, 'P');
  end if;
  return new;
end;
$$;
drop trigger if exists pastas_a_codigo on public.pastas;
create trigger pastas_a_codigo before insert on public.pastas for each row execute function public.pastas_codigo();

create or replace function public.submeter_pasta(p_pasta uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v_pasta.codigo_aprovacao is not null then raise exception 'JA_SUBMETIDA'; end if;
  if length(trim(coalesce(v_pasta.comprador_telefone, ''))) < 10
     or length(trim(coalesce(v_pasta.comprador_email, ''))) <= 3
     or length(trim(coalesce(v_pasta.comprador_profissao, ''))) <= 1 then
    raise exception 'DADOS_INCOMPLETOS';
  end if;
  if v_pasta.estado_civil in ('casado', 'uniao_estavel')
     and (length(trim(coalesce(v_pasta.conjuge_nome, ''))) <= 1
          or v_pasta.conjuge_cpf is null
          or length(trim(coalesce(v_pasta.conjuge_profissao, ''))) <= 1) then
    raise exception 'DADOS_CONJUGE_INCOMPLETOS';
  end if;
  if public.recalcular_pasta(p_pasta) <> 'pronta' then raise exception 'DOCUMENTOS_FALTANDO'; end if;

  update public.pastas
     set codigo_aprovacao = public.proximo_codigo(v_pasta.empreendimento_id, 'PA'),
         submetida_em = now(), submetida_por = public.meu_email()
   where id = p_pasta
  returning * into v_pasta;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pasta submetida ao incorporador', jsonb_build_object('codigo', v_pasta.codigo_aprovacao), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$$;

-- ---------------------------------------------------------------------
-- Funções que liam a linha única de configuração
-- ---------------------------------------------------------------------
create or replace function public.definir_publico(p_ativo boolean) returns public.config
language plpgsql security definer set search_path = public as $$
declare v_config public.config;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.config set publico_ativo = p_ativo, atualizado_em = now() where empreendimento_id = public.empreendimento_atual()
  returning * into v_config;
  return v_config;
end;
$$;

create or replace function public.salvar_simulador(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare c jsonb; pr jsonb; s numeric;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if jsonb_typeof(p -> 'cenarios') <> 'array' or jsonb_array_length(p -> 'cenarios') not between 1 and 30 then
    raise exception 'CENARIOS_INVALIDOS';
  end if;
  for c in select * from jsonb_array_elements(p -> 'cenarios') loop
    if length(trim(coalesce(c ->> 'nome', ''))) < 2 or length(coalesce(c ->> 'id', '')) < 1 then raise exception 'NOME_INVALIDO'; end if;
    if jsonb_typeof(c -> 'precos') <> 'array' or jsonb_array_length(c -> 'precos') not between 1 and 6 then raise exception 'PRECO_INVALIDO'; end if;
    for pr in select * from jsonb_array_elements(c -> 'precos') loop
      if coalesce((pr ->> 'valor')::numeric, 0) <= 0 or length(trim(coalesce(pr ->> 'rotulo', ''))) = 0 then raise exception 'PRECO_INVALIDO'; end if;
    end loop;
    if coalesce((c ->> 'captacao')::numeric, 0) not between 1 and 100 then raise exception 'CAPTACAO_INVALIDA'; end if;
    if coalesce((c #>> '{pct,unica}')::numeric, 0) > 5 then raise exception 'UNICA_ACIMA_DO_LIMITE'; end if;
    select sum(v::numeric) into s from jsonb_each_text(c -> 'pct') as x(k, v);
    if s is null or s > 100 or s < (c ->> 'captacao')::numeric then raise exception 'FLUXO_PADRAO_INVALIDO'; end if;
  end loop;
  update public.config set simulador = jsonb_build_object('cenarios', p -> 'cenarios'), atualizado_em = now()
   where empreendimento_id = public.empreendimento_atual();
end;
$$;

-- fluxo da tabela: entrega do empreendimento da tabela
create or replace function public.series_tabela(p_tabela uuid, p_unidade uuid, p_data date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  with i as (select * from public.tabelas_preco_itens where tabela_id = p_tabela and unidade_id = p_unidade),
       m as (select public.mes_venda_tabela(p_tabela, p_data) as venda,
                    (select c.mes_entrega from public.comercial c join public.tabelas_preco t on t.empreendimento_id = c.empreendimento_id where t.id = p_tabela) as entrega),
       s as (
         select cs.*, i.preco,
                ((case cs.base when 'venda' then m.venda else m.entrega end) + make_interval(months => cs.meses))::date as inicio,
                m.entrega
           from public.captacoes_series cs join i on cs.tabela_id = i.tabela_id and cs.captacao = i.captacao, m
       ),
       q as (
         select s.*, coalesce(s.qtd, greatest(1,
                  floor(public.meses_entre(s.inicio, (s.entrega + make_interval(months => s.fim_meses))::date)::numeric
                        / public.passo_meses(s.periodicidade))::int + 1)) as n
           from s
       )
  select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'qtd', n, 'periodicidade', periodicidade,
                                               'vencimento', inicio, 'valor', percentual * preco / n) order by ordem), '[]')
    from q;
$$;

create or replace function public.pv_proposta(p_unidade uuid, p_series jsonb, p_comissao numeric default null,
  p_tabela uuid default null, p_data date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c        public.comercial;
  v_emp    uuid;
  v_tab    uuid;
  v_preco  numeric;
  v_venda  date;
  v_mes_sec int;
  v_vpl_t  numeric := 0;
  v_vpl_p  numeric := 0;
  v_total  numeric := 0;
  v_sinal  numeric := 0;
  v_com    numeric;
  s        record;
  k        int;
  v_mes    int;
begin
  select empreendimento_id into v_emp from public.unidades where id = p_unidade;
  c := public.comercial_de(v_emp);
  v_tab := coalesce(p_tabela, public.tabela_vigente(v_emp));
  v_preco := public.preco_tabela_unidade(p_unidade, v_tab);
  if v_preco is null then raise exception 'UNIDADE_SEM_PRECO'; end if;
  v_venda := public.mes_venda_tabela(v_tab, p_data);
  v_mes_sec := public.meses_entre(v_venda, c.mes_entrega) + 1;

  for k in 0 .. 1 loop
    for s in select (e ->> 'qtd')::int as qtd, e ->> 'periodicidade' as periodicidade, (e ->> 'vencimento')::date as vencimento,
                    (e ->> 'valor')::numeric as valor
               from jsonb_array_elements(case k when 0 then public.series_tabela(v_tab, p_unidade, p_data) else p_series end) e loop
      for v_mes in 0 .. s.qtd - 1 loop
        if k = 0 then
          v_vpl_t := v_vpl_t + s.valor / power(1 + c.taxa_vp, case when s.periodicidade = 'Financiamento' then v_mes_sec
                     else public.meses_entre(v_venda, (s.vencimento + make_interval(months => v_mes * public.passo_meses(s.periodicidade)))::date) end);
        else
          v_vpl_p := v_vpl_p + round(s.valor, 2) / power(1 + c.taxa_vp, case when s.periodicidade = 'Financiamento' then v_mes_sec
                     else public.meses_entre(v_venda, (s.vencimento + make_interval(months => v_mes * public.passo_meses(s.periodicidade)))::date) end);
          v_total := v_total + round(s.valor, 2);
          if s.periodicidade = 'Sinal' then v_sinal := v_sinal + round(s.valor, 2); end if;
        end if;
      end loop;
    end loop;
  end loop;

  v_com := round(v_total * coalesce(p_comissao, c.comissao_pct), 2);
  return jsonb_build_object(
    'tabela_id', v_tab, 'preco_tabela', round(v_preco, 2), 'total', round(v_total, 2),
    'vpl_tabela', round(v_vpl_t, 2), 'vpl_proposta', round(v_vpl_p, 2),
    'diferenca_vpl', round(v_vpl_p - v_vpl_t, 2),
    'pv_pct', round(v_vpl_p / nullif(v_vpl_t, 0) * 100, 2),
    'sinal', round(v_sinal, 2), 'comissao', v_com,
    'comissao_coberta', v_sinal * c.parte_sinal + 0.01 >= v_com,
    'calculado_pelo_banco', true);
end;
$$;

create or replace function public.enviar_proposta(p_id uuid) returns public.propostas
language plpgsql security definer set search_path = public as $$
declare
  v   public.propostas;
  c   public.comercial;
  r   jsonb;
  v_alcada text;
begin
  select * into v from public.propostas where id = p_id for update;
  if not found or not public.acesso_pasta(v.imobiliaria_id, v.criado_por_id) then raise exception 'PROPOSTA_NAO_ENCONTRADA'; end if;
  if v.status not in ('rascunho', 'devolvida') then raise exception 'PROPOSTA_BLOQUEADA'; end if;
  if v.pasta_id is null then raise exception 'PASTA_OBRIGATORIA' using hint = 'Vincule a pasta do comprador antes de enviar.'; end if;
  if (select empreendimento_id from public.pastas where id = v.pasta_id) is distinct from v.empreendimento_id then
    raise exception 'PASTA_DE_OUTRO_EMPREENDIMENTO' using hint = 'A pasta pertence a outro empreendimento.';
  end if;
  if jsonb_array_length(v.series) = 0 then raise exception 'SERIES_INVALIDAS'; end if;
  if exists (select 1 from jsonb_array_elements(v.series) s where s ->> 'periodicidade' = 'Permuta')
     and length(trim(coalesce(v.observacoes, ''))) < 5 then
    raise exception 'PERMUTA_SEM_OBSERVACAO' using hint = 'Descreva a permuta nas observações da proposta.';
  end if;
  if v.tabela_id is distinct from public.tabela_vigente(v.empreendimento_id) then
    raise exception 'TABELA_ENCERRADA' using hint = 'A tabela desta proposta não está mais vigente. Atualize para a tabela vigente.';
  end if;

  c := public.comercial_de(v.empreendimento_id);
  r := public.pv_proposta(v.unidade_id, v.series, v.comissao_pct, v.tabela_id, v.data_proposta);
  v_alcada := case
    when c.alcada_automatica and (r ->> 'pv_pct')::numeric >= c.alcada_auto_pv and (r ->> 'comissao_coberta')::boolean then 'automatica'
    when (r ->> 'pv_pct')::numeric >= c.alcada_vendas_pv then 'vendas'
    else 'admin' end;

  perform set_config('propostas.funcao', 'sim', true);
  update public.propostas
     set status = 'enviada', enviada_em = now(), motivo_analise = null, alcada = v_alcada,
         resumo = coalesce(resumo, '{}') || r
   where id = p_id returning * into v;
  perform set_config('propostas.funcao', '', true);

  if v_alcada = 'automatica' then
    v := public.aprovar_proposta_interno(p_id, 'Aprovação automática (PV ' || (r ->> 'pv_pct') || '%)');
  end if;
  return v;
end;
$$;

-- nova tabela no empreendimento atual
create or replace function public.nova_tabela(p_nome text, p_mes date, p_base uuid default null,
  p_reajuste numeric default null, p_unidades uuid[] default null, p_emp uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_emp uuid := coalesce(p_emp, public.empreendimento_atual()); v_base uuid; v_id uuid;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_reajuste is not null and (p_reajuste <= -0.5 or p_reajuste > 1) then raise exception 'REAJUSTE_INVALIDO'; end if;
  v_base := coalesce(p_base, public.tabela_vigente(v_emp));
  if v_base is not null and (select empreendimento_id from public.tabelas_preco where id = v_base) <> v_emp then v_base := null; end if;
  insert into public.tabelas_preco (empreendimento_id, nome, mes_referencia, origem, base_id, criada_por)
  values (v_emp, trim(p_nome), date_trunc('month', p_mes)::date,
          case when v_base is null then 'manual' when p_reajuste is not null then 'reajuste' else 'copia' end, v_base, public.meu_email())
  returning id into v_id;
  if v_base is not null then
    insert into public.captacoes (tabela_id, numero, nome) select v_id, numero, nome from public.captacoes where tabela_id = v_base;
    insert into public.captacoes_series (tabela_id, captacao, ordem, rotulo, periodicidade, percentual, qtd, base, meses, fim_meses)
    select v_id, captacao, ordem, rotulo, periodicidade, percentual, qtd, base, meses, fim_meses from public.captacoes_series where tabela_id = v_base;
    insert into public.tabelas_preco_itens (tabela_id, unidade_id, preco, captacao)
    select v_id, unidade_id,
           case when p_reajuste is not null and (p_unidades is null or unidade_id = any (p_unidades)) then round(preco * (1 + p_reajuste), 2) else preco end,
           captacao
      from public.tabelas_preco_itens where tabela_id = v_base;
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Fila de escolha por empreendimento
-- ---------------------------------------------------------------------
alter table public.fila_escolha add column if not exists empreendimento_id uuid references public.empreendimentos (id) on delete cascade;
update public.fila_escolha f set empreendimento_id = p.empreendimento_id from public.pastas p where p.id = f.pasta_id and f.empreendimento_id is null;
alter table public.fila_escolha alter column empreendimento_id set not null;
create index if not exists fila_escolha_emp_idx on public.fila_escolha (empreendimento_id, posicao);
create or replace function public.fila_escolha_emp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select empreendimento_id into new.empreendimento_id from public.pastas where id = new.pasta_id;
  return new;
end;
$$;
drop trigger if exists fila_escolha_emp on public.fila_escolha;
create trigger fila_escolha_emp before insert on public.fila_escolha for each row execute function public.fila_escolha_emp();

create or replace function public.fila_de(p_emp uuid) returns public.fila_config
language sql stable security definer set search_path = public as $$
  select * from public.fila_config where empreendimento_id = p_emp;
$$;

drop function if exists public.fila_liberadas();
create or replace function public.fila_liberadas(p_emp uuid default null) returns int
language sql stable security definer set search_path = public as $$
  select case when not f.ativa or f.inicio is null or now() < f.inicio then 0
              else f.lote * (floor(extract(epoch from now() - f.inicio) / (f.intervalo_min * 60))::int + 1) end
    from public.fila_config f where f.empreendimento_id = coalesce(p_emp, public.empreendimento_atual());
$$;

drop function if exists public.fila_libera_em(int);
create or replace function public.fila_libera_em(p_posicao int, p_emp uuid default null) returns timestamptz
language sql stable security definer set search_path = public as $$
  select f.inicio + make_interval(mins => ((p_posicao - 1) / f.lote) * f.intervalo_min)
    from public.fila_config f where f.empreendimento_id = coalesce(p_emp, public.empreendimento_atual());
$$;

create or replace function public.fila_situacao() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ativa', f.ativa, 'inicio', f.inicio, 'lote', f.lote, 'intervalo_min', f.intervalo_min,
    'unidades_por_pasta', f.unidades_por_pasta,
    'liberadas', least(public.fila_liberadas(f.empreendimento_id), (select count(*) from public.fila_escolha e where e.empreendimento_id = f.empreendimento_id)),
    'total', (select count(*) from public.fila_escolha e where e.empreendimento_id = f.empreendimento_id),
    'proximo_lote_em', case when f.ativa and f.inicio is not null then
        case when now() < f.inicio then f.inicio
             else f.inicio + make_interval(mins => (floor(extract(epoch from now() - f.inicio) / (f.intervalo_min * 60))::int + 1) * f.intervalo_min) end end,
    'agora', now())
  from public.fila_config f where f.empreendimento_id = public.empreendimento_atual();
$$;

create or replace function public.minha_fila() returns table (
  pasta_id uuid, codigo text, comprador text, imobiliaria text, corretor text, posicao int,
  liberada boolean, libera_em timestamptz, reservas int, unidades text[]
)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.codigo_aprovacao, p.codigo), p.comprador_nome, i.nome,
         coalesce(nullif(pf.nome, ''), p.criado_por), f.posicao,
         f.posicao <= public.fila_liberadas(f.empreendimento_id), public.fila_libera_em(f.posicao, f.empreendimento_id),
         (select count(*)::int from public.negociacoes n where n.pasta_id = p.id and n.ativa),
         (select array_agg(u.numero order by u.numero) from public.negociacoes n join public.unidades u on u.id = n.unidade_id where n.pasta_id = p.id and n.ativa)
    from public.fila_escolha f
    join public.pastas p on p.id = f.pasta_id
    left join public.imobiliarias i on i.id = p.imobiliaria_id
    left join public.perfis pf on pf.user_id = p.criado_por_id
   where f.empreendimento_id = public.empreendimento_atual() and public.acesso_pasta(p.imobiliaria_id, p.criado_por_id)
   order by f.posicao;
$$;

create or replace function public.configurar_fila(p_ativa boolean, p_inicio timestamptz, p_lote int, p_intervalo int, p_unidades_por_pasta int default 1)
returns public.fila_config
language plpgsql security definer set search_path = public as $$
declare v public.fila_config;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_ativa and p_inicio is null then raise exception 'INICIO_OBRIGATORIO'; end if;
  insert into public.fila_config (empreendimento_id) values (public.empreendimento_atual()) on conflict (empreendimento_id) do nothing;
  update public.fila_config set ativa = p_ativa, inicio = p_inicio, lote = p_lote, intervalo_min = p_intervalo,
         unidades_por_pasta = coalesce(p_unidades_por_pasta, 1), atualizado_em = now(), atualizado_por = public.meu_email()
   where empreendimento_id = public.empreendimento_atual() returning * into v;
  return v;
end;
$$;

create or replace function public.montar_fila() returns int
language plpgsql security definer set search_path = public as $$
declare v_emp uuid := public.empreendimento_atual(); v_ini int; v_n int;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select coalesce(max(posicao), 0) into v_ini from public.fila_escolha where empreendimento_id = v_emp;
  insert into public.fila_escolha (pasta_id, posicao)
  select p.id, v_ini + row_number() over (order by p.submetida_em nulls last, p.codigo_aprovacao nulls last, p.criada_em)
    from public.pastas p
   where p.empreendimento_id = v_emp and p.status = 'aprovada' and not exists (select 1 from public.fila_escolha f where f.pasta_id = p.id);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function public.mover_na_fila(p_pasta uuid, p_posicao int) returns void
language plpgsql security definer set search_path = public as $$
declare v_atual int; v_max int; v_nova int; v_emp uuid;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  select posicao, empreendimento_id into v_atual, v_emp from public.fila_escolha where pasta_id = p_pasta;
  if v_atual is null then raise exception 'PASTA_FORA_DA_FILA'; end if;
  select max(posicao) into v_max from public.fila_escolha where empreendimento_id = v_emp;
  v_nova := greatest(1, least(p_posicao, v_max));
  if v_nova = v_atual then return; end if;
  if v_nova < v_atual then
    update public.fila_escolha set posicao = posicao + 1 where empreendimento_id = v_emp and posicao >= v_nova and posicao < v_atual;
  else
    update public.fila_escolha set posicao = posicao - 1 where empreendimento_id = v_emp and posicao > v_atual and posicao <= v_nova;
  end if;
  update public.fila_escolha set posicao = v_nova where pasta_id = p_pasta;
end;
$$;

create or replace function public.remover_da_fila(p_pasta uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_pos int; v_emp uuid;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  delete from public.fila_escolha where pasta_id = p_pasta returning posicao, empreendimento_id into v_pos, v_emp;
  if v_pos is not null then update public.fila_escolha set posicao = posicao - 1 where empreendimento_id = v_emp and posicao > v_pos; end if;
end;
$$;

create or replace function public.reservar_pela_fila(p_pasta uuid, p_unidade uuid) returns public.unidades
language plpgsql security definer set search_path = public as $$
declare
  f public.fila_config;
  p public.pastas;
  u public.unidades;
  v_pos int;
begin
  select * into p from public.pastas where id = p_pasta;
  if not found or not public.acesso_pasta(p.imobiliaria_id, p.criado_por_id) then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  f := public.fila_de(p.empreendimento_id);
  if f is null or not f.ativa then raise exception 'FILA_DESLIGADA'; end if;
  if p.status <> 'aprovada' then raise exception 'PASTA_NAO_APROVADA'; end if;
  select posicao into v_pos from public.fila_escolha where pasta_id = p_pasta;
  if v_pos is null then raise exception 'PASTA_FORA_DA_FILA'; end if;
  if v_pos > public.fila_liberadas(p.empreendimento_id) then
    raise exception 'PASTA_AINDA_NAO_LIBERADA' using hint = to_char(public.fila_libera_em(v_pos, p.empreendimento_id) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
  end if;
  if (select count(*) from public.negociacoes where pasta_id = p_pasta and ativa) >= f.unidades_por_pasta then
    raise exception 'LIMITE_DE_UNIDADES_DA_PASTA';
  end if;
  select * into u from public.unidades where id = p_unidade for update;
  if not found or u.empreendimento_id <> p.empreendimento_id then raise exception 'UNIDADE_NAO_ENCONTRADA'; end if;
  if u.status <> 'disponivel' then raise exception 'UNIDADE_INDISPONIVEL' using hint = 'Outra pessoa reservou esta unidade agora há pouco.'; end if;

  perform set_config('espelho.sistema', 'sim', true);
  u := public.alterar_status(p_unidade, 'reservada', u.versao, null, null, null, null, null, null, p_pasta);
  perform set_config('espelho.sistema', '', true);
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Unidade reservada pela fila de escolha', jsonb_build_object('unidade', u.numero, 'posicao', v_pos), public.meu_email());
  return u;
end;
$$;

-- ---------------------------------------------------------------------
-- Indicadores, rodadas e painéis
-- ---------------------------------------------------------------------
create or replace function public.indicadores() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  return jsonb_build_object(
    'unidades', (select jsonb_object_agg(status, n) from (select status::text, count(*) n from public.unidades where empreendimento_id = v_emp group by status) s),
    'pastas',   (select jsonb_object_agg(status, n) from (select status, count(*) n from public.pastas where empreendimento_id = v_emp group by status) s),
    'pastas_total', (select count(*) from public.pastas where empreendimento_id = v_emp),
    'pastas_submetidas', (select count(*) from public.pastas where empreendimento_id = v_emp and codigo_aprovacao is not null),
    'vendas_7_dias', (select count(*) from public.historico where empreendimento_id = v_emp and status_novo = 'vendida' and criado_em > now() - interval '7 days'),
    'reservas_7_dias', (select count(*) from public.historico where empreendimento_id = v_emp and status_novo = 'reservada' and criado_em > now() - interval '7 days')
  );
end;
$$;

create or replace function public.rodadas_vagas() returns table (rodada_id uuid, clientes int, pessoas int)
language sql stable security definer set search_path = public as $$
  select r.id, count(i.id)::int, coalesce(sum(i.pessoas), 0)::int
    from public.rodadas r
    left join public.rodada_inscricoes i on i.rodada_id = r.id and not i.cancelada
   where r.empreendimento_id = public.empreendimento_atual() and public.rodada_liberada(r.id)
   group by r.id;
$$;

drop function if exists public.paineis();
create or replace function public.paineis(p_todos boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;

  with
  un as (
    select u.id, u.numero, u.status, u.empreendimento_id, public.preco_tabela_unidade(u.id) as preco
      from public.unidades u where p_todos or u.empreendimento_id = v_emp
  ),
  neg as (
    select n.*, u.status as status_unidade, u.numero
      from public.negociacoes n join public.unidades u on u.id = n.unidade_id
     where n.ativa and (p_todos or n.empreendimento_id = v_emp)
  ),
  pas as (select * from public.pastas p where p_todos or p.empreendimento_id = v_emp),
  vendas_mes as (
    select to_char(date_trunc('month', h.criado_em at time zone 'America/Sao_Paulo'), 'YYYY-MM') as mes, h.status_novo, count(distinct h.unidade_id) as n
      from public.historico h
     where (p_todos or h.empreendimento_id = v_emp)
       and h.status_novo in ('reservada', 'proposta', 'contrato', 'vendida')
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
      from pas p join public.imobiliarias i on i.id = p.imobiliaria_id group by 1
  ),
  rank_corretor as (
    select coalesce(n.corretor, '—') as nome, coalesce(n.imobiliaria, 'Venda direta') as imobiliaria,
           count(*) filter (where n.status_unidade = 'reservada') as reservas,
           count(*) filter (where n.status_unidade in ('proposta', 'contrato', 'vendida')) as vendas,
           coalesce(sum(n.valor_venda) filter (where n.status_unidade in ('proposta', 'contrato', 'vendida')), 0) as vgv
      from neg n group by 1, 2
  ),
  props as (
    select * from public.propostas where status <> 'rascunho' and (p_todos or empreendimento_id = v_emp)
  ),
  por_emp as (
    select e.id, e.sigla, e.nome, e.ordem, e.criado_em,
           (select count(*) from un where un.empreendimento_id = e.id) as unidades,
           (select count(*) from un where un.empreendimento_id = e.id and un.status = 'disponivel') as disponiveis,
           (select count(*) from un where un.empreendimento_id = e.id and un.status = 'vendida') as vendidas,
           (select count(*) from neg where neg.empreendimento_id = e.id and neg.status_unidade in ('proposta', 'contrato', 'vendida')) as vendas,
           (select round(coalesce(sum(preco), 0), 2) from un where un.empreendimento_id = e.id) as vgv_tabela,
           (select round(coalesce(sum(valor_venda), 0), 2) from neg where neg.empreendimento_id = e.id and neg.status_unidade in ('proposta', 'contrato', 'vendida')) as vgv_vendido
      from public.empreendimentos e where p_todos or e.id = v_emp
  )
  select jsonb_build_object(
    'gerado_em', now(),
    'consolidado', p_todos,
    'por_empreendimento', coalesce((select jsonb_agg(jsonb_build_object('sigla', sigla, 'nome', nome, 'unidades', unidades, 'disponiveis', disponiveis,
                                     'vendidas', vendidas, 'vendas', vendas, 'vgv_tabela', vgv_tabela, 'vgv_vendido', vgv_vendido) order by ordem, criado_em) from por_emp), '[]'),
    'unidades', (select jsonb_object_agg(status, jsonb_build_object('n', n, 'vgv_tabela', vgv))
                   from (select status, count(*) n, round(coalesce(sum(preco), 0), 2) vgv from un group by status) x),
    'vgv_tabela_total', (select round(coalesce(sum(preco), 0), 2) from un),
    'vendas', (select jsonb_object_agg(status_unidade, jsonb_build_object('n', n, 'vgv', vgv))
                 from (select status_unidade, count(*) n, round(coalesce(sum(valor_venda), 0), 2) vgv from neg group by 1) x),
    'por_mes', coalesce((select jsonb_agg(jsonb_build_object('mes', mes, 'status', status_novo, 'n', n) order by mes) from vendas_mes), '[]'),
    'funil', jsonb_build_object(
       'pastas', (select count(*) from pas),
       'submetidas', (select count(*) from pas where codigo_aprovacao is not null),
       'aprovadas', (select count(*) from pas where status = 'aprovada'),
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

-- ---------------------------------------------------------------------
-- Cadastro de empreendimento: já nasce com configuração, dados comerciais e fila
-- ---------------------------------------------------------------------
create or replace function public.salvar_empreendimento(p_id uuid, p_nome text, p_slug text, p_sigla text,
  p_ativo boolean default true, p_ordem int default 0) returns public.empreendimentos
language plpgsql security definer set search_path = public as $$
declare v public.empreendimentos; v_base uuid := public.empreendimento_padrao();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if p_id is null then
    insert into public.empreendimentos (nome, slug, sigla, ativo, ordem)
    values (trim(p_nome), lower(trim(p_slug)), upper(trim(p_sigla)), p_ativo, p_ordem) returning * into v;
    -- identidade: cores e fonte do primeiro empreendimento; módulos desligados; sem logo
    insert into public.config
    select (jsonb_populate_record(null::public.config, to_jsonb(c) || jsonb_build_object(
              'id', nextval('public.config_id_seq'), 'empreendimento_id', v.id, 'nome_empreendimento', v.nome,
              'logo_url', null, 'logo_escuro_url', null, 'imagem_login_url', null, 'publico_ativo', false,
              'modulo_funil', false, 'modulo_portal', false, 'modulo_rodadas', false, 'modulo_meeting', false, 'modulo_tv', false,
              'simulador', jsonb_build_object('cenarios', '[]'::jsonb), 'atualizado_em', now()))).*
      from public.config c where c.empreendimento_id = v_base;
    -- dados comerciais: copiados do primeiro (o administrador ajusta entrega, SPE etc.)
    insert into public.comercial
    select (jsonb_populate_record(null::public.comercial, to_jsonb(c) || jsonb_build_object(
              'id', nextval('public.comercial_id_seq'), 'empreendimento_id', v.id, 'vendedora', null, 'vendedora_cnpj', null,
              'atualizado_em', now()))).*
      from public.comercial c where c.empreendimento_id = v_base;
    insert into public.fila_config (empreendimento_id) values (v.id) on conflict do nothing;
  else
    update public.empreendimentos set nome = trim(p_nome), slug = lower(trim(p_slug)), sigla = upper(trim(p_sigla)),
           ativo = p_ativo, ordem = p_ordem where id = p_id returning * into v;
    if not found then raise exception 'EMPREENDIMENTO_NAO_ENCONTRADO'; end if;
  end if;
  return v;
exception when unique_violation then raise exception 'ENDERECO_OU_SIGLA_EM_USO';
end;
$$;

-- dados comerciais do empreendimento atual (administrador)
create or replace function public.salvar_comercial(p jsonb) returns public.comercial
language plpgsql security definer set search_path = public as $$
declare v public.comercial;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.comercial c set
    mes_entrega = coalesce(date_trunc('month', (p ->> 'mes_entrega')::date)::date, c.mes_entrega),
    taxa_vp = coalesce((p ->> 'taxa_vp')::numeric, c.taxa_vp),
    comissao_pct = coalesce((p ->> 'comissao_pct')::numeric, c.comissao_pct),
    parte_sinal = coalesce((p ->> 'parte_sinal')::numeric, c.parte_sinal),
    alcada_automatica = coalesce((p ->> 'alcada_automatica')::boolean, c.alcada_automatica),
    alcada_auto_pv = coalesce((p ->> 'alcada_auto_pv')::numeric, c.alcada_auto_pv),
    alcada_vendas_pv = coalesce((p ->> 'alcada_vendas_pv')::numeric, c.alcada_vendas_pv),
    vendedora = case when p ? 'vendedora' then nullif(trim(p ->> 'vendedora'), '') else c.vendedora end,
    vendedora_cnpj = case when p ? 'vendedora_cnpj' then nullif(trim(p ->> 'vendedora_cnpj'), '') else c.vendedora_cnpj end,
    cidade_carta = case when p ? 'cidade_carta' then nullif(trim(p ->> 'cidade_carta'), '') else c.cidade_carta end,
    atualizado_em = now()
   where c.empreendimento_id = public.empreendimento_atual() returning * into v;
  return v;
end;
$$;

revoke all on function public.pode_usar_empreendimento(uuid), public.empreendimento_atual(), public.escolher_empreendimento(uuid),
  public.meus_empreendimentos(), public.comercial_de(uuid), public.proximo_codigo(uuid, text), public.pastas_codigo(),
  public.fila_de(uuid), public.fila_liberadas(uuid), public.fila_libera_em(int, uuid), public.paineis(boolean),
  public.salvar_comercial(jsonb), public.fila_escolha_emp(), public.negociacao_mesmo_empreendimento() from public, anon;
grant execute on function public.proximo_codigo(uuid, text) to authenticated;
grant execute on function public.empreendimento_atual() to anon, authenticated;
grant execute on function public.pode_usar_empreendimento(uuid), public.escolher_empreendimento(uuid), public.meus_empreendimentos(),
  public.fila_liberadas(uuid), public.fila_libera_em(int, uuid), public.paineis(boolean), public.salvar_comercial(jsonb) to authenticated;

-- >>>>> supabase/migrations/113_vitrine_empreendimentos.sql
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

-- >>>>> supabase/migrations/114_meeting_corretor.sql
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

-- >>>>> supabase/migrations/115_meeting_numero_sorteio.sql
-- =====================================================================
-- 115 — Meeting: número de presença e sorteio
--  * Ao confirmar a presença, o participante recebe um número sequencial
--    do meeting (1, 2, 3...), na ordem de chegada. Desfazer a confirmação
--    não libera o número; quem volta a ser confirmado mantém o mesmo.
--  * Sorteio feito no banco (sem viciar pelo navegador), só entre os
--    presentes com número que ainda não foram sorteados. Cada sorteio fica
--    registrado (ordem, prêmio, quem sorteou). Ganhador ausente: marca e
--    sorteia de novo.
--  * Recepcionista (032) opera o Meeting como a equipe: inclui, edita,
--    remove inscrição, cadastra meeting e faz o sorteio.
-- =====================================================================

alter table public.recepcao_participantes add column if not exists numero int;
create unique index if not exists recepcao_participantes_numero_key on public.recepcao_participantes (evento_id, numero) where numero is not null;

-- quem já estava confirmado recebe o número pela ordem de chegada
update public.recepcao_participantes p set numero = x.n
  from (select id, row_number() over (partition by evento_id order by chegada_em nulls last, criado_em) as n
          from public.recepcao_participantes where presente) x
 where x.id = p.id and p.numero is null
   and not exists (select 1 from public.recepcao_participantes q where q.evento_id = p.evento_id and q.numero is not null);

create or replace function public.recepcao_numerar() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.presente and new.numero is null then
    perform 1 from public.recepcao_eventos where id = new.evento_id for update;   -- um número por vez no meeting
    select coalesce(max(numero), 0) + 1 into new.numero from public.recepcao_participantes where evento_id = new.evento_id;
  end if;
  return new;
end;
$$;
drop trigger if exists recepcao_participantes_numerar on public.recepcao_participantes;
create trigger recepcao_participantes_numerar before insert or update of presente on public.recepcao_participantes
  for each row execute function public.recepcao_numerar();

-- ---------------------------------------------------------------------
-- Sorteio
-- ---------------------------------------------------------------------
create table if not exists public.meeting_sorteios (
  id              uuid primary key default gen_random_uuid(),
  evento_id       uuid not null references public.recepcao_eventos (id) on delete cascade,
  participante_id uuid not null references public.recepcao_participantes (id) on delete cascade,
  ordem           int not null,
  numero          int not null,
  nome            text not null,
  imobiliaria     text,
  premio          text,
  status          text not null default 'valido' check (status in ('valido', 'ausente')),
  sorteado_em     timestamptz not null default now(),
  sorteado_por    text,
  unique (evento_id, participante_id)
);
alter table public.meeting_sorteios enable row level security;
revoke all on public.meeting_sorteios from anon, authenticated;
grant select on public.meeting_sorteios to authenticated;
drop policy if exists meeting_sorteios_leitura on public.meeting_sorteios;
create policy meeting_sorteios_leitura on public.meeting_sorteios for select
  using (public.pode_meeting() and exists (select 1 from public.recepcao_eventos e where e.id = evento_id));

create or replace function public.sortear_meeting(p_evento uuid, p_premio text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g public.recepcao_participantes; v public.meeting_sorteios; v_ordem int;
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  perform 1 from public.recepcao_eventos where id = p_evento and empreendimento_id = public.empreendimento_atual() for update;
  if not found then raise exception 'MEETING_NAO_ENCONTRADO'; end if;

  select p.* into g from public.recepcao_participantes p
   where p.evento_id = p_evento and p.presente and p.numero is not null
     and not exists (select 1 from public.meeting_sorteios s where s.evento_id = p_evento and s.participante_id = p.id)
   order by random() limit 1;
  if not found then raise exception 'SEM_PARTICIPANTES_PARA_SORTEIO'; end if;

  select coalesce(max(ordem), 0) + 1 into v_ordem from public.meeting_sorteios where evento_id = p_evento;
  insert into public.meeting_sorteios (evento_id, participante_id, ordem, numero, nome, imobiliaria, premio, sorteado_por)
  values (p_evento, g.id, v_ordem, g.numero, g.nome, g.imobiliaria, nullif(trim(coalesce(p_premio, '')), ''), public.meu_email())
  returning * into v;
  return to_jsonb(v);
end;
$$;

create or replace function public.sorteio_ausente(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.meeting_sorteios set status = 'ausente' where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Recepcionista opera o Meeting como a equipe
-- ---------------------------------------------------------------------
create or replace function public.incluir_participante(p_evento uuid, p_nome text, p_imobiliaria text default null, p_telefone text default null)
returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes; v_tel text := public.normalizar_telefone(p_telefone);
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if v_tel is not null and exists (select 1 from public.recepcao_participantes where evento_id = p_evento and telefone = v_tel and origem = 'inscricao') then
    raise exception 'TELEFONE_JA_INSCRITO';
  end if;
  insert into public.recepcao_participantes (evento_id, nome, imobiliaria, telefone, presente, chegada_em, confirmado_por, incluido_na_hora, origem)
  values (p_evento, regexp_replace(trim(p_nome), '\s+', ' ', 'g'), nullif(trim(p_imobiliaria), ''), v_tel, true, now(), public.meu_email(), true, 'na_hora')
  returning * into v;
  return v;
end;
$$;

create or replace function public.remover_inscricao(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  delete from public.recepcao_participantes where id = p_id;
end;
$$;

create or replace function public.salvar_meeting(
  p_id uuid, p_nome text, p_slug text, p_data_hora timestamptz default null, p_local text default null,
  p_descricao text default null, p_abertas boolean default false, p_vagas int default null, p_encerra_em timestamptz default null
) returns public.recepcao_eventos
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_eventos; v_slug text := lower(trim(coalesce(p_slug, '')));
begin
  if not public.pode_meeting() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  if v_slug !~ '^[a-z0-9][a-z0-9-]{2,59}$' then raise exception 'ENDERECO_INVALIDO'; end if;
  if exists (select 1 from public.recepcao_eventos where slug = v_slug and id is distinct from p_id) then raise exception 'ENDERECO_EM_USO'; end if;
  if p_id is null then
    insert into public.recepcao_eventos (nome, slug, data_hora, local, descricao, inscricoes_abertas, vagas, encerra_em)
    values (trim(p_nome), v_slug, p_data_hora, nullif(trim(p_local), ''), nullif(trim(p_descricao), ''), p_abertas, p_vagas, p_encerra_em)
    returning * into v;
  else
    update public.recepcao_eventos
       set nome = trim(p_nome), slug = v_slug, data_hora = p_data_hora, local = nullif(trim(p_local), ''),
           descricao = nullif(trim(p_descricao), ''), inscricoes_abertas = p_abertas, vagas = p_vagas,
           encerra_em = p_encerra_em, atualizado_em = now()
     where id = p_id returning * into v;
    if not found then raise exception 'MEETING_NAO_ENCONTRADO'; end if;
  end if;
  return v;
end;
$$;

revoke all on function public.sortear_meeting(uuid, text), public.sorteio_ausente(uuid), public.recepcao_numerar() from public, anon;
grant execute on function public.sortear_meeting(uuid, text), public.sorteio_ausente(uuid) to authenticated;
-- políticas de leitura chamam pode_meeting(): visitante sem login recebe "não", e não erro
grant execute on function public.pode_meeting() to anon;

-- >>>>> supabase/migrations/116_modulos_duohaus_multi.sql
-- =====================================================================
-- 116 — Módulos novos do Duo Haus (034–048) dentro de vários empreendimentos
--  * Propostas: módulo ligado na v2 e lido no empreendimento da proposta.
--  * Pix do sinal: configuração do empreendimento da pasta.
--  * Contratos: dados da vendedora, quadro de áreas, modelos e documentos
--    fixos passam a ser de cada empreendimento (cada incorporadora tem os seus).
--  * Leads: configuração, chave da planilha, cotas, rodízio e leads por
--    empreendimento (a chave da planilha diz de qual empreendimento é o lead).
--  * submeter_pasta: junta a versão da v2 (código com a sigla) com as
--    regras novas do Duo Haus (regime de bens, PJ, cônjuge e Pix).
-- Nada é configurado aqui: IA, D4Sign e minutas continuam em branco.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- Propostas: ligado na v2; a chave é a do empreendimento da proposta
-- ---------------------------------------------------------------------
alter table public.config alter column modulo_propostas set default true;
update public.config set modulo_propostas = true where not modulo_propostas;

create or replace function public.propostas_modulo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_equipe() and not coalesce((select modulo_propostas from public.config
                                              where empreendimento_id = coalesce(new.empreendimento_id, public.empreendimento_atual())), false) then
    raise exception 'MODULO_DESLIGADO' using hint = 'As propostas ainda não estão liberadas.';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Pix do sinal: configuração do empreendimento da pasta
-- ---------------------------------------------------------------------
create or replace function public.pix_integrado(p_pasta uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select c.pix_modo = 'integrado' from public.config c join public.pastas p on p.empreendimento_id = c.empreendimento_id
                    where p.id = p_pasta), false);
$$;
revoke all on function public.pix_integrado(uuid) from public, anon, authenticated;

create or replace function public.recalcular_pasta(p_pasta uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ec        public.estado_civil;
  v_tipo      text;
  v_conjuge   boolean;
  v_submetida boolean;
  v_integrado boolean := public.pix_integrado(p_pasta);
  v_status    text;
  v_faltando  int;
  v_recusado  int;
  v_analise   int;
  v_enviado   int;
begin
  select estado_civil, tipo_pessoa, public.conjuge_no_contrato(estado_civil, regime_bens, conjuge_participa, tipo_pessoa), codigo_aprovacao is not null
    into v_ec, v_tipo, v_conjuge, v_submetida from public.pastas where id = p_pasta;

  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo
     and not (v_integrado and t.eh_pix)
     and case when v_tipo = 'pj' then t.aplica_a in ('pj', 'ambos') and t.obrigatorio_pj
              else t.aplica_a in ('pf', 'ambos') and v_ec = any (t.obrigatorio_para) and (t.pessoa <> 'conjuge' or v_conjuge) end
     and not exists (select 1 from public.documentos d where d.pasta_id = p_pasta and d.tipo_id = t.id and d.atual);
  if v_integrado and not public.pix_pago(p_pasta) then v_faltando := v_faltando + 1; end if;
  select count(*) into v_recusado from public.documentos where pasta_id = p_pasta and atual and status = 'recusado';
  select count(*) into v_analise  from public.documentos where pasta_id = p_pasta and atual and status = 'em_analise';
  select count(*) into v_enviado  from public.documentos where pasta_id = p_pasta and atual and status = 'enviado';

  if not v_submetida then
    v_status := case when v_faltando > 0 then 'incompleta' else 'pronta' end;
  else
    v_status := case
      when v_recusado > 0 then 'pendente_correcao'
      when v_faltando > 0 then 'incompleta'
      when v_analise > 0 then 'em_analise'
      when v_enviado > 0 then 'aguardando_analise'
      else 'aprovada' end;
  end if;

  update public.pastas set status = v_status where id = p_pasta and status is distinct from v_status;
  return v_status;
end;
$$;
revoke all on function public.recalcular_pasta(uuid) from public, anon, authenticated;

create or replace function public.config_pix_mudou() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.pix_modo is distinct from old.pix_modo then
    for r in select id from public.pastas where codigo_aprovacao is null and empreendimento_id = new.empreendimento_id loop
      perform public.recalcular_pasta(r.id);
    end loop;
  end if;
  return null;
end;
$$;

do $$
declare d text;
begin
  -- gerar_cobranca_pix: troca só a leitura da configuração
  select pg_get_functiondef('public.gerar_cobranca_pix(uuid)'::regprocedure) into d;
  if position('where id = 1' in d) > 0 then
    d := replace(d, 'select * into c from public.config where id = 1;',
                    'select c0.* into c from public.config c0 join public.pastas p0 on p0.empreendimento_id = c0.empreendimento_id where p0.id = p_pasta;');
    execute d;
  end if;
end $$;

-- Submissão: código com a sigla do empreendimento + regras de regime, PJ e Pix
create or replace function public.submeter_pasta(p_pasta uuid) returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v_pasta public.pastas;
begin
  select * into v_pasta from public.pastas where id = p_pasta for update;
  if not found or not public.acesso_pasta(v_pasta.imobiliaria_id, v_pasta.criado_por_id) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if v_pasta.codigo_aprovacao is not null then raise exception 'JA_SUBMETIDA'; end if;
  if length(trim(coalesce(v_pasta.comprador_telefone, ''))) < 10
     or length(trim(coalesce(v_pasta.comprador_email, ''))) <= 3
     or length(trim(coalesce(v_pasta.comprador_profissao, ''))) <= 1 then
    raise exception 'DADOS_INCOMPLETOS';
  end if;
  if v_pasta.tipo_pessoa = 'pf' and v_pasta.estado_civil in ('casado', 'uniao_estavel') and v_pasta.regime_bens is null then
    raise exception 'REGIME_NAO_INFORMADO';
  end if;
  if public.conjuge_no_contrato(v_pasta.estado_civil, v_pasta.regime_bens, v_pasta.conjuge_participa, v_pasta.tipo_pessoa)
     and (length(trim(coalesce(v_pasta.conjuge_nome, ''))) <= 1
          or v_pasta.conjuge_cpf is null
          or length(trim(coalesce(v_pasta.conjuge_profissao, ''))) <= 1) then
    raise exception 'DADOS_CONJUGE_INCOMPLETOS';
  end if;
  if public.pix_integrado(p_pasta) and not public.pix_pago(p_pasta) then
    raise exception 'PIX_PENDENTE';
  end if;
  if public.recalcular_pasta(p_pasta) <> 'pronta' then raise exception 'DOCUMENTOS_FALTANDO'; end if;

  update public.pastas
     set codigo_aprovacao = public.proximo_codigo(v_pasta.empreendimento_id, 'PA'),
         submetida_em = now(), submetida_por = public.meu_email()
   where id = p_pasta
  returning * into v_pasta;

  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Pasta submetida ao incorporador', jsonb_build_object('codigo', v_pasta.codigo_aprovacao), public.meu_email());

  perform public.recalcular_pasta(p_pasta);
  select * into v_pasta from public.pastas where id = p_pasta;
  return v_pasta;
end;
$$;

-- ---------------------------------------------------------------------
-- Contratos: cada empreendimento com os seus dados, quadro, modelos e fixos
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['empreendimento_contrato', 'unidade_areas', 'modelos_contrato', 'contrato_anexos_fixos'] loop
    execute format('alter table public.%I add column if not exists empreendimento_id uuid references public.empreendimentos (id) on delete cascade', t);
    execute format('update public.%I set empreendimento_id = public.empreendimento_padrao() where empreendimento_id is null', t);
    execute format('alter table public.%I alter column empreendimento_id set not null', t);
    execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_atual()', t);
    execute format('drop policy if exists %I on public.%I', t || '_do_empreendimento', t);
    execute format('create policy %I on public.%I as restrictive for select using (empreendimento_id = (select public.empreendimento_atual()))', t || '_do_empreendimento', t);
  end loop;
end $$;

-- dados da vendedora: uma linha por empreendimento
alter table public.empreendimento_contrato drop constraint if exists empreendimento_contrato_id_check;
create sequence if not exists public.empreendimento_contrato_id_seq as smallint;
select setval('public.empreendimento_contrato_id_seq', greatest((select max(id) from public.empreendimento_contrato), 1));
alter table public.empreendimento_contrato alter column id set default nextval('public.empreendimento_contrato_id_seq');
create unique index if not exists empreendimento_contrato_emp_key on public.empreendimento_contrato (empreendimento_id);

create or replace function public.salvar_empreendimento_contrato(p_dados jsonb) returns public.empreendimento_contrato
language plpgsql security definer set search_path = public as $$
declare v public.empreendimento_contrato;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.empreendimento_contrato (empreendimento_id, dados, atualizado_em, atualizado_por)
  values (public.empreendimento_atual(), coalesce(p_dados, '{}'), now(), public.meu_email())
  on conflict (empreendimento_id) do update set dados = excluded.dados, atualizado_em = now(), atualizado_por = public.meu_email()
  returning * into v;
  return v;
end;
$$;

-- quadro de áreas: número único dentro do empreendimento
alter table public.unidade_areas drop constraint if exists unidade_areas_pkey;
alter table public.unidade_areas add primary key (empreendimento_id, numero);

create or replace function public.importar_quadro_areas(p_linhas jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then raise exception 'PLANILHA_VAZIA'; end if;
  if exists (select 1 from jsonb_array_elements(p_linhas) l where coalesce(trim(l ->> 'numero'), '') = '') then raise exception 'UNIDADE_SEM_NUMERO'; end if;
  if (select count(distinct trim(l ->> 'numero')) from jsonb_array_elements(p_linhas) l) <> jsonb_array_length(p_linhas) then raise exception 'UNIDADE_REPETIDA'; end if;
  delete from public.unidade_areas where empreendimento_id = v_emp;
  insert into public.unidade_areas (empreendimento_id, numero, torre, pavimento, area_privativa, area_acessoria, area_privativa_total, area_comum,
                                    area_total, fracao_ideal, vagas, escaninho, escaninho_local, escaninho_area)
  select v_emp, trim(l ->> 'numero'), nullif(trim(l ->> 'torre'), ''), nullif(trim(l ->> 'pavimento'), ''),
         (l ->> 'area_privativa')::numeric, (l ->> 'area_acessoria')::numeric, (l ->> 'area_privativa_total')::numeric,
         (l ->> 'area_comum')::numeric, (l ->> 'area_total')::numeric, (l ->> 'fracao_ideal')::numeric,
         nullif(trim(l ->> 'vagas'), ''), nullif(trim(l ->> 'escaninho'), ''), nullif(trim(l ->> 'escaninho_local'), ''),
         (l ->> 'escaninho_area')::numeric
    from jsonb_array_elements(p_linhas) l;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- modelos: um ativo por documento em cada empreendimento
drop index if exists public.modelos_contrato_um_ativo;
create unique index if not exists modelos_contrato_um_ativo on public.modelos_contrato (empreendimento_id, documento) where ativo;

create or replace function public.salvar_modelo_contrato(p_documento text, p_nome text, p_caminho text)
returns public.modelos_contrato language plpgsql security definer set search_path = public as $$
declare v public.modelos_contrato; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.modelos_contrato set ativo = false where empreendimento_id = v_emp and documento = p_documento and ativo;
  insert into public.modelos_contrato (empreendimento_id, documento, nome, caminho, enviado_por)
  values (v_emp, p_documento, left(p_nome, 200), p_caminho, public.meu_email()) returning * into v;
  return v;
end;
$$;

create or replace function public.usar_modelo_padrao(p_documento text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.modelos_contrato set ativo = false where empreendimento_id = public.empreendimento_atual() and documento = p_documento and ativo;
end;
$$;

create or replace function public.salvar_anexo_fixo(p_nome text, p_caminho text, p_arquivo text, p_ordem int)
returns public.contrato_anexos_fixos language plpgsql security definer set search_path = public as $$
declare v public.contrato_anexos_fixos;
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.contrato_anexos_fixos (empreendimento_id, nome, caminho, arquivo, ordem, enviado_por)
  values (public.empreendimento_atual(), left(trim(p_nome), 150), p_caminho, left(p_arquivo, 200), coalesce(p_ordem, 100), public.meu_email()) returning * into v;
  return v;
end;
$$;

create or replace function public.alterar_anexo_fixo(p_id uuid, p_nome text, p_ordem int, p_ativo boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  update public.contrato_anexos_fixos set nome = coalesce(left(trim(p_nome), 150), nome), ordem = coalesce(p_ordem, ordem), ativo = coalesce(p_ativo, ativo)
   where id = p_id and empreendimento_id = public.empreendimento_atual();
end;
$$;

-- ---------------------------------------------------------------------
-- Leads por empreendimento
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['leads_config', 'leads_chave'] loop
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_id_check');
    execute format('create sequence if not exists public.%I', t || '_id_seq');
    execute format('select setval(%L, greatest((select max(id) from public.%I), 1))', 'public.' || t || '_id_seq', t);
    execute format('alter table public.%I alter column id set default nextval(%L)', t, 'public.' || t || '_id_seq');
  end loop;
  foreach t in array array['leads_config', 'leads_chave', 'leads_imobiliarias', 'leads_corretores', 'leads'] loop
    execute format('alter table public.%I add column if not exists empreendimento_id uuid references public.empreendimentos (id) on delete cascade', t);
    execute format('update public.%I set empreendimento_id = public.empreendimento_padrao() where empreendimento_id is null', t);
    execute format('alter table public.%I alter column empreendimento_id set not null', t);
    execute format('alter table public.%I alter column empreendimento_id set default public.empreendimento_atual()', t);
    execute format('drop policy if exists %I on public.%I', t || '_do_empreendimento', t);
    execute format('create policy %I on public.%I as restrictive for select using (empreendimento_id = (select public.empreendimento_atual()))', t || '_do_empreendimento', t);
  end loop;
end $$;
create unique index if not exists leads_config_emp_key on public.leads_config (empreendimento_id);
create unique index if not exists leads_chave_emp_key on public.leads_chave (empreendimento_id);
alter table public.leads_imobiliarias drop constraint if exists leads_imobiliarias_pkey;
alter table public.leads_imobiliarias add primary key (empreendimento_id, imobiliaria_id);
alter table public.leads_corretores drop constraint if exists leads_corretores_pkey;
alter table public.leads_corretores add primary key (empreendimento_id, user_id);
create index if not exists leads_emp_idx on public.leads (empreendimento_id, recebido_em desc);

-- todo empreendimento tem a sua configuração e a sua chave
insert into public.leads_config (empreendimento_id) select id from public.empreendimentos on conflict (empreendimento_id) do nothing;
insert into public.leads_chave (empreendimento_id) select id from public.empreendimentos on conflict (empreendimento_id) do nothing;
create or replace function public.empreendimento_cria_leads() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.leads_config (empreendimento_id) values (new.id) on conflict (empreendimento_id) do nothing;
  insert into public.leads_chave (empreendimento_id) values (new.id) on conflict (empreendimento_id) do nothing;
  return null;
end;
$$;
revoke all on function public.empreendimento_cria_leads() from public, anon, authenticated;
drop trigger if exists empreendimento_cria_leads on public.empreendimentos;
create trigger empreendimento_cria_leads after insert on public.empreendimentos for each row execute function public.empreendimento_cria_leads();

-- prazo e alertas: pela configuração do empreendimento
drop function if exists public.leads_prazo(timestamptz, int);
create or replace function public.leads_prazo(p_inicio timestamptz, p_minutos int, p_emp uuid default null) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare c public.leads_config; t timestamp; resto numeric := p_minutos; abre timestamp; fecha timestamp; dispo numeric; i int := 0;
begin
  select * into c from public.leads_config where empreendimento_id = coalesce(p_emp, public.empreendimento_atual());
  if c.id is null or c.plantao_24h or coalesce(array_length(c.dias_semana, 1), 0) = 0 or c.hora_fim <= c.hora_inicio then
    return p_inicio + make_interval(mins => p_minutos);
  end if;
  t := p_inicio at time zone 'America/Sao_Paulo';
  loop
    i := i + 1;
    exit when i > 40;
    if extract(isodow from t)::int = any (c.dias_semana) then
      abre := date_trunc('day', t) + c.hora_inicio;
      fecha := date_trunc('day', t) + c.hora_fim;
      if t < abre then t := abre; end if;
      if t < fecha then
        dispo := extract(epoch from (fecha - t)) / 60;
        if resto <= dispo then return (t + make_interval(secs => resto * 60)) at time zone 'America/Sao_Paulo'; end if;
        resto := resto - dispo;
      end if;
    end if;
    t := date_trunc('day', t) + interval '1 day';
  end loop;
  return p_inicio + make_interval(mins => p_minutos);
end;
$$;

drop function if exists public.leads_emails_alerta();
create or replace function public.leads_emails_alerta(p_emp uuid default null) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim((select emails_alerta from public.leads_config where empreendimento_id = coalesce(p_emp, public.empreendimento_atual()))), ''),
                  (select string_agg(email, ',') from public.perfis where papel = 'vendas'),
                  (select string_agg(email, ',') from public.perfis where papel = 'admin'));
$$;

/** Escolhe o próximo corretor (do rodízio do empreendimento do lead) e entrega o lead. */
create or replace function public.leads_atribuir(p_lead uuid, p_motivo text default 'Rodízio') returns void
language plpgsql security definer set search_path = public as $$
declare
  l public.leads; c public.leads_config; v_imob uuid; v_corr uuid; v_email text; v_nome text; v_prazo timestamptz;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null then return; end if;
  select * into c from public.leads_config where empreendimento_id = l.empreendimento_id;

  if coalesce(array_length(l.tentados, 1), 0) < c.max_tentativas then
    -- 1) próximo corretor da mesma imobiliária
    if l.imobiliaria_id is not null then
      select lc.user_id into v_corr
        from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
       where lc.empreendimento_id = l.empreendimento_id and lc.participa and p.papel = 'corretor'
         and p.imobiliaria_id = l.imobiliaria_id and not (lc.user_id = any (l.tentados))
       order by lc.ultimo_lead_em nulls first, lc.recebidos limit 1;
      if v_corr is not null then v_imob := l.imobiliaria_id; end if;
    end if;
    -- 2) imobiliária pela cota (quem está mais abaixo da sua proporção)
    if v_corr is null then
      select li.imobiliaria_id into v_imob
        from public.leads_imobiliarias li join public.imobiliarias i on i.id = li.imobiliaria_id and i.ativa
       where li.empreendimento_id = l.empreendimento_id and li.cota > 0 and li.imobiliaria_id is distinct from l.imobiliaria_id
         and exists (select 1 from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
                      where lc.empreendimento_id = l.empreendimento_id and lc.participa and p.papel = 'corretor'
                        and p.imobiliaria_id = li.imobiliaria_id and not (lc.user_id = any (l.tentados)))
       order by (li.recebidos + 1) / li.cota, li.cota desc, random() limit 1;
      if v_imob is not null then
        select lc.user_id into v_corr
          from public.leads_corretores lc join public.perfis p on p.user_id = lc.user_id
         where lc.empreendimento_id = l.empreendimento_id and lc.participa and p.papel = 'corretor'
           and p.imobiliaria_id = v_imob and not (lc.user_id = any (l.tentados))
         order by lc.ultimo_lead_em nulls first, lc.recebidos limit 1;
        update public.leads_imobiliarias set recebidos = recebidos + 1 where empreendimento_id = l.empreendimento_id and imobiliaria_id = v_imob;
      end if;
    end if;
  end if;

  if v_corr is null then
    update public.leads set status = 'sem_destino', corretor_id = null, prazo_aceite_em = null, atualizado_em = now() where id = l.id;
    perform public.lead_evento(l.id, 'Aguardando a Sec. Vendas', jsonb_build_object('motivo',
      case when coalesce(array_length(l.tentados, 1), 0) >= c.max_tentativas then 'Limite de tentativas atingido' else 'Nenhum corretor disponível no rodízio' end));
    perform public.lead_avisar(l.id, public.leads_emails_alerta(l.empreendimento_id), 'Lead ' || l.codigo || ' sem corretor — distribuir manualmente',
      jsonb_build_array('O lead ' || l.codigo || ' não foi assumido por ninguém do rodízio e aguarda a Sec. Vendas.') || public.lead_resumo(l), 'Distribuir lead');
    return;
  end if;

  v_prazo := public.leads_prazo(now(), c.prazo_aceite_min, l.empreendimento_id);
  update public.leads set status = 'aguardando_aceite', imobiliaria_id = v_imob, corretor_id = v_corr, distribuido_em = now(),
         prazo_aceite_em = v_prazo, aceito_em = null, tentados = array_append(tentados, v_corr), atualizado_em = now()
   where id = l.id returning * into l;
  update public.leads_corretores set ultimo_lead_em = now(), recebidos = recebidos + 1 where empreendimento_id = l.empreendimento_id and user_id = v_corr;
  select email, nome into v_email, v_nome from public.perfis where user_id = v_corr;
  perform public.lead_evento(l.id, 'Enviado ao corretor', jsonb_build_object('corretor', coalesce(v_nome, v_email), 'motivo', p_motivo, 'prazo', v_prazo));
  perform public.lead_avisar(l.id, v_email, 'Novo lead ' || l.codigo || ' — assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    jsonb_build_array('Você recebeu um lead (' || p_motivo || '). Assuma até ' || to_char(v_prazo at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI')
      || ' para ver telefone e e-mail; depois disso ele vai para o próximo corretor.') || public.lead_resumo(l), 'Assumir lead');
end;
$$;

/** Entrada da planilha (servidor, com a chave): a chave diz o empreendimento. */
create or replace function public.receber_leads(p_chave text, p_linhas jsonb, p_origem text default 'planilha', p_url text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r jsonb; v_id text; l public.leads; v_dono public.leads; v_tel text; v_email text; v_nome text; c public.leads_config; v_emp uuid;
  novos int := 0; repetidos int := 0; v_corr_pasta uuid; v_imob_pasta uuid;
  chaves_meta text[] := array['id', 'lead_id', 'leadgen_id', 'created_time', 'data_de_criacao', 'ad_id', 'ad_name', 'adset_id', 'adset_name',
    'campaign_id', 'campaign_name', 'form_id', 'form_name', 'is_organic', 'platform', 'plataforma', 'nome_completo', 'full_name', 'nome', 'name',
    'first_name', 'last_name', 'primeiro_nome', 'sobrenome', 'phone_number', 'phone', 'telefone', 'numero_de_telefone', 'celular', 'whatsapp',
    'email', 'e_mail', '_linha', '_rotulos', 'inbox_url', 'lead_status', 'vehicle', 'retailer_item_id'];
begin
  select empreendimento_id into v_emp from public.leads_chave where p_chave is not null and chave = p_chave;
  if v_emp is null then raise exception 'CHAVE_INVALIDA'; end if;
  select * into c from public.leads_config where empreendimento_id = v_emp;
  update public.leads_config set ultimo_recebimento = now(), url_app = coalesce(p_url, url_app) where empreendimento_id = v_emp;
  for r in select * from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) loop
    v_id := nullif(trim(coalesce(r ->> 'id', r ->> 'lead_id', r ->> 'leadgen_id')), '');
    v_id := coalesce(regexp_replace(v_id, '^l:', ''), p_origem || ':' || coalesce(r ->> '_linha', md5(r::text)));
    if exists (select 1 from public.leads where meta_id = v_id) then repetidos := repetidos + 1; continue; end if;
    v_nome := nullif(trim(coalesce(r ->> 'nome_completo', r ->> 'full_name', r ->> 'nome', r ->> 'name',
                 nullif(trim(coalesce(r ->> 'first_name', r ->> 'primeiro_nome', '') || ' ' || coalesce(r ->> 'last_name', r ->> 'sobrenome', '')), ''))), '');
    v_tel := public.so_digitos_tel(coalesce(r ->> 'phone_number', r ->> 'telefone', r ->> 'numero_de_telefone', r ->> 'celular', r ->> 'whatsapp', r ->> 'phone'));
    v_email := nullif(lower(trim(coalesce(r ->> 'email', r ->> 'e_mail', ''))), '');
    insert into public.leads (empreendimento_id, meta_id, origem, campanha, conjunto, anuncio, formulario, plataforma, criado_meta_em, nome, telefone, email, respostas)
    values (v_emp, v_id, coalesce(p_origem, 'planilha'), nullif(r ->> 'campaign_name', ''), nullif(r ->> 'adset_name', ''), nullif(r ->> 'ad_name', ''),
            nullif(r ->> 'form_name', ''), nullif(coalesce(r ->> 'platform', r ->> 'plataforma'), ''),
            case when coalesce(r ->> 'created_time', r ->> 'data_de_criacao', '') ~ '^\d{4}-\d{2}-\d{2}' then (coalesce(r ->> 'created_time', r ->> 'data_de_criacao'))::timestamptz end,
            initcap(v_nome), v_tel, v_email,
            coalesce((select jsonb_object_agg(coalesce(nullif(trim(r -> '_rotulos' ->> k), ''), k), v) from jsonb_each_text(r) as x(k, v) where not (k = any (chaves_meta)) and nullif(trim(v), '') is not null), '{}'::jsonb))
    returning * into l;
    novos := novos + 1;
    perform public.lead_evento(l.id, 'Lead recebido', jsonb_build_object('campanha', l.campanha, 'formulario', l.formulario, 'origem', l.origem));

    if not c.ativo then
      perform public.lead_evento(l.id, 'Aguardando a Sec. Vendas', jsonb_build_object('motivo', 'Rodízio desligado'));
      continue;
    end if;

    -- Cliente que voltou (no mesmo empreendimento): mesmo corretor durante "dono_dias"
    v_dono := null; v_corr_pasta := null; v_imob_pasta := null;
    select * into v_dono from public.leads x
     where x.id <> l.id and x.empreendimento_id = v_emp and x.corretor_id is not null and x.status <> 'perdido'
       and x.recebido_em > now() - make_interval(days => c.dono_dias)
       and ((v_tel is not null and x.telefone = v_tel) or (v_email is not null and lower(x.email) = v_email))
       and exists (select 1 from public.perfis p where p.user_id = x.corretor_id)
     order by x.recebido_em desc limit 1;
    if v_dono.id is null then
      -- ou cliente que já tem pasta neste empreendimento: corretor da pasta
      select coalesce(pa.cadastrado_por_id, pa.criado_por_id), pa.imobiliaria_id into v_corr_pasta, v_imob_pasta
        from public.pastas pa join public.perfis p on p.user_id = coalesce(pa.cadastrado_por_id, pa.criado_por_id) and p.papel = 'corretor'
       where pa.empreendimento_id = v_emp
         and ((v_tel is not null and public.so_digitos_tel(pa.comprador_telefone) = v_tel) or (v_email is not null and lower(pa.comprador_email) = v_email))
       order by pa.criada_em desc limit 1;
    else
      v_corr_pasta := v_dono.corretor_id; v_imob_pasta := v_dono.imobiliaria_id;
    end if;

    if v_corr_pasta is not null then
      update public.leads set retorno_de = v_dono.id, imobiliaria_id = v_imob_pasta, status = 'aguardando_aceite', corretor_id = v_corr_pasta,
             tentados = array[v_corr_pasta], distribuido_em = now(), prazo_aceite_em = public.leads_prazo(now(), c.prazo_aceite_min, v_emp)
       where id = l.id returning * into l;
      perform public.lead_evento(l.id, 'Enviado ao corretor', jsonb_build_object('motivo', 'Cliente já atendido por este corretor',
        'corretor', (select coalesce(nome, email) from public.perfis where user_id = v_corr_pasta), 'prazo', l.prazo_aceite_em));
      perform public.lead_avisar(l.id, (select email from public.perfis where user_id = v_corr_pasta),
        'Cliente seu voltou: lead ' || l.codigo || ' — assuma até ' || to_char(l.prazo_aceite_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
        jsonb_build_array('Um cliente que já é seu preencheu um novo formulário. Assuma até ' || to_char(l.prazo_aceite_em at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI') || '.') || public.lead_resumo(l), 'Assumir lead');
    else
      perform public.leads_atribuir(l.id, 'Rodízio');
    end if;
  end loop;
  return jsonb_build_object('novos', novos, 'repetidos', repetidos);
end;
$$;

/** Rodado a cada minuto pelo servidor, para todos os empreendimentos. */
create or replace function public.processar_leads() returns int
language plpgsql security definer set search_path = public as $$
declare l record; n int := 0;
begin
  for l in select id, corretor_id from public.leads where status = 'aguardando_aceite' and prazo_aceite_em < now() order by prazo_aceite_em limit 200 for update skip locked loop
    perform public.lead_evento(l.id, 'Prazo para assumir esgotado', jsonb_build_object('corretor', (select coalesce(nome, email) from public.perfis where user_id = l.corretor_id)));
    perform public.leads_atribuir(l.id, 'Redistribuído: o anterior não assumiu no prazo');
    n := n + 1;
  end loop;
  -- Assumiu mas não registrou contato no prazo: avisa o gestor da imobiliária (uma vez)
  for l in select x.id, x.codigo, x.imobiliaria_id, x.corretor_id from public.leads x
             join public.leads_config c on c.empreendimento_id = x.empreendimento_id
            where x.status = 'em_atendimento' and x.primeiro_contato_em is null
              and public.leads_prazo(x.aceito_em, c.prazo_contato_min, x.empreendimento_id) < now()
              and not exists (select 1 from public.lead_eventos e where e.lead_id = x.id and e.tipo = 'Sem registro de contato no prazo') limit 200 loop
    perform public.lead_evento(l.id, 'Sem registro de contato no prazo', '{}'::jsonb);
    perform public.lead_avisar(l.id, (select string_agg(email, ',') from public.perfis where papel = 'imobiliaria' and imobiliaria_id = l.imobiliaria_id),
      'Lead ' || l.codigo || ' sem contato registrado',
      jsonb_build_array((select coalesce(nome, email) from public.perfis where user_id = l.corretor_id) || ' assumiu o lead ' || l.codigo || ' e ainda não registrou o primeiro contato.'), 'Abrir lead');
  end loop;
  return n;
end;
$$;

do $$
declare d text;
begin
  -- listar_leads: só os leads do empreendimento atual
  select pg_get_functiondef('public.listar_leads(uuid)'::regprocedure) into d;
  if position('l.empreendimento_id' in d) = 0 then
    d := replace(d, 'where (p_id is null or l.id = p_id)', 'where l.empreendimento_id = public.empreendimento_atual() and (p_id is null or l.id = p_id)');
    execute d;
  end if;
  -- redistribuir_lead: prazo pela configuração do empreendimento do lead
  select pg_get_functiondef('public.redistribuir_lead(uuid, uuid)'::regprocedure) into d;
  d := replace(d, '(select prazo_aceite_min from public.leads_config where id = 1))',
                  '(select prazo_aceite_min from public.leads_config where empreendimento_id = l.empreendimento_id), l.empreendimento_id)');
  execute d;
  -- pasta nova converte só lead do mesmo empreendimento
  select pg_get_functiondef('public.pastas_converte_lead()'::regprocedure) into d;
  if position('new.empreendimento_id' in d) = 0 then
    d := replace(d, 'and (imobiliaria_id = new.imobiliaria_id)', 'and (imobiliaria_id = new.imobiliaria_id) and empreendimento_id = new.empreendimento_id');
    execute d;
  end if;
end $$;

create or replace function public.salvar_config_leads(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.leads_config (empreendimento_id) values (v_emp) on conflict (empreendimento_id) do nothing;
  update public.leads_config set
    ativo = coalesce((p ->> 'ativo')::boolean, ativo),
    prazo_aceite_min = coalesce((p ->> 'prazo_aceite_min')::int, prazo_aceite_min),
    prazo_contato_min = coalesce((p ->> 'prazo_contato_min')::int, prazo_contato_min),
    max_tentativas = coalesce((p ->> 'max_tentativas')::int, max_tentativas),
    dias_semana = coalesce((select array_agg(x::int order by x::int) from jsonb_array_elements_text(p -> 'dias_semana') x), dias_semana),
    hora_inicio = coalesce((p ->> 'hora_inicio')::time, hora_inicio),
    hora_fim = coalesce((p ->> 'hora_fim')::time, hora_fim),
    plantao_24h = coalesce((p ->> 'plantao_24h')::boolean, plantao_24h),
    dono_dias = coalesce((p ->> 'dono_dias')::int, dono_dias),
    emails_alerta = case when p ? 'emails_alerta' then nullif(trim(p ->> 'emails_alerta'), '') else emails_alerta end,
    remetente_email = case when p ? 'remetente_email' then nullif(trim(p ->> 'remetente_email'), '') else remetente_email end,
    remetente_nome = case when p ? 'remetente_nome' then nullif(trim(p ->> 'remetente_nome'), '') else remetente_nome end,
    atualizado_em = now(), atualizado_por = public.meu_email()
  where empreendimento_id = v_emp;
end;
$$;

create or replace function public.salvar_cotas_leads(p_cotas jsonb, p_zerar boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  for r in select (x ->> 'imobiliaria_id')::uuid as imob, greatest(0, coalesce((x ->> 'cota')::numeric, 0)) as cota from jsonb_array_elements(p_cotas) x loop
    insert into public.leads_imobiliarias (empreendimento_id, imobiliaria_id, cota) values (v_emp, r.imob, r.cota)
    on conflict (empreendimento_id, imobiliaria_id) do update set cota = excluded.cota;
  end loop;
  if p_zerar then update public.leads_imobiliarias set recebidos = 0 where empreendimento_id = v_emp; end if;
end;
$$;

create or replace function public.chave_leads(p_nova boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare v text; v_emp uuid := public.empreendimento_atual();
begin
  if not public.eh_admin() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.leads_chave (empreendimento_id) values (v_emp) on conflict (empreendimento_id) do nothing;
  if p_nova then update public.leads_chave set chave = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') where empreendimento_id = v_emp; end if;
  select chave into v from public.leads_chave where empreendimento_id = v_emp;
  return v;
end;
$$;

create or replace function public.definir_rodizio_corretor(p_user uuid, p_participa boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_imob uuid;
begin
  select imobiliaria_id into v_imob from public.perfis where user_id = p_user and papel = 'corretor';
  if v_imob is null then raise exception 'CORRETOR_INVALIDO'; end if;
  if not (public.eh_equipe() or (public.eh_gestor() and v_imob = public.minha_imobiliaria())) then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  insert into public.leads_corretores (empreendimento_id, user_id, participa, alterado_por) values (public.empreendimento_atual(), p_user, p_participa, public.meu_email())
  on conflict (empreendimento_id, user_id) do update set participa = excluded.participa, alterado_em = now(), alterado_por = excluded.alterado_por;
end;
$$;

-- Permissões (funções novas ou com assinatura nova)
revoke all on function public.leads_prazo(timestamptz, int, uuid), public.leads_emails_alerta(uuid) from public, anon, authenticated;
grant execute on function public.leads_prazo(timestamptz, int, uuid) to authenticated;

commit;
