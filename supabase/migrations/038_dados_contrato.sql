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
