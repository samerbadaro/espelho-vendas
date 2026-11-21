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
