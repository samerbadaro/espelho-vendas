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
