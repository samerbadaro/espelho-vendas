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
