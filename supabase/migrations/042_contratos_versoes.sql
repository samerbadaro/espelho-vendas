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
