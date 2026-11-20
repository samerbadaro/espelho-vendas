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
