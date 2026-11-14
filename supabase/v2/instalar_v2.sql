-- =====================================================================
-- INSTALAÇÃO COMPLETA DA V2 (projeto de testes do Supabase)
-- Junta as migrações 001 a 028 na ordem. Para um projeto NOVO.
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

-- >>>>> supabase/migrations/022_propostas.sql
-- =====================================================================
-- 022 — Propostas (v2)
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

-- >>>>> supabase/migrations/023_dados_comerciais_duohaus.sql
-- =====================================================================
-- 023 — Dados comerciais do Duo Haus (planilha Compacto_Studio.xlsm)
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

-- >>>>> supabase/migrations/024_carta_modelo.sql
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

-- >>>>> supabase/migrations/025_novas_series.sql
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

-- >>>>> supabase/migrations/026_alcadas_pv_banco.sql
-- =====================================================================
-- 026 — Alçadas de aprovação e PV calculado pelo banco
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

-- >>>>> supabase/migrations/027_fila_escolha.sql
-- =====================================================================
-- 027 — Escolha de unidades por lotes de pastas (liga/desliga)
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

-- >>>>> supabase/migrations/028_paineis.sql
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
