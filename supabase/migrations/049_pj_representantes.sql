-- =====================================================================
-- 049 · Pessoa jurídica: comprovante de estado civil do representante e
--        segundo representante legal (opcional), com os documentos dele.
--        No PJ o cônjuge do representante não entra (já era assim).
-- =====================================================================
begin;

-- Segundo representante: dados em um único campo (nome, cpf, nascimento, telefone, email, profissao, estado_civil)
alter table public.pastas add column if not exists representante2 jsonb;
alter table public.pastas drop constraint if exists pastas_representante2_pj;
alter table public.pastas add constraint pastas_representante2_pj check (representante2 is null or tipo_pessoa = 'pj');
grant insert (representante2), update (representante2) on public.pastas to authenticated;

-- Documentos do segundo representante
alter table public.tipos_documento drop constraint if exists tipos_documento_pessoa_check;
alter table public.tipos_documento add constraint tipos_documento_pessoa_check check (pessoa in ('comprador', 'conjuge', 'geral', 'representante2'));

insert into public.tipos_documento (nome, pessoa, aplica_a, obrigatorio_pj, ordem, sigla)
select v.nome, v.pessoa, 'pj', v.obrig, v.ordem, v.sigla
  from (values
    ('Comprovante de estado civil do representante', 'comprador', true, 35, 'ESTADO_CIVIL'),
    ('RG ou CNH do 2º representante', 'representante2', true, 46, 'IDENTIFICACAO'),
    ('CPF do 2º representante (se não constar no RG/CNH)', 'representante2', false, 47, 'CPF'),
    ('Comprovante de endereço do 2º representante', 'representante2', true, 48, 'ENDERECO'),
    ('Comprovante de estado civil do 2º representante', 'representante2', true, 49, 'ESTADO_CIVIL')
  ) as v(nome, pessoa, obrig, ordem, sigla)
 where not exists (select 1 from public.tipos_documento t where t.nome = v.nome);

-- Limpa o segundo representante quando a pasta volta para PF
create or replace function public.pastas_limpa_representante2() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.tipo_pessoa = 'pf' then new.representante2 := null; end if;
  if new.representante2 is not null and nullif(trim(coalesce(new.representante2->>'nome', '')), '') is null then new.representante2 := null; end if;
  return new;
end;
$$;
drop trigger if exists pastas_limpa_representante2 on public.pastas;
create trigger pastas_limpa_representante2 before insert or update on public.pastas
  for each row execute function public.pastas_limpa_representante2();
revoke all on function public.pastas_limpa_representante2() from public, anon, authenticated;

-- Recalcula o status quando entra ou sai o segundo representante
create or replace function public.pastas_recalcula_representante2() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.representante2 is null) is distinct from (old.representante2 is null) then
    perform public.recalcular_pasta(new.id);
  end if;
  return null;
end;
$$;
drop trigger if exists pastas_recalcula_representante2 on public.pastas;
create trigger pastas_recalcula_representante2 after update of representante2 on public.pastas
  for each row execute function public.pastas_recalcula_representante2();
revoke all on function public.pastas_recalcula_representante2() from public, anon, authenticated;

-- Documentos obrigatórios: os do 2º representante só contam quando ele existe
create or replace function public.recalcular_pasta(p_pasta uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_ec        public.estado_civil;
  v_tipo      text;
  v_conjuge   boolean;
  v_rep2      boolean;
  v_submetida boolean;
  v_integrado boolean := coalesce((select pix_modo = 'integrado' from public.config where id = 1), false);
  v_status    text;
  v_faltando  int;
  v_recusado  int;
  v_analise   int;
  v_enviado   int;
begin
  select estado_civil, tipo_pessoa, public.conjuge_no_contrato(estado_civil, regime_bens, conjuge_participa, tipo_pessoa),
         representante2 is not null, codigo_aprovacao is not null
    into v_ec, v_tipo, v_conjuge, v_rep2, v_submetida from public.pastas where id = p_pasta;

  select count(*) into v_faltando
    from public.tipos_documento t
   where t.ativo
     and not (v_integrado and t.eh_pix)
     and case when v_tipo = 'pj' then t.aplica_a in ('pj', 'ambos') and t.obrigatorio_pj and (t.pessoa <> 'representante2' or v_rep2)
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

-- Envio da pasta: dados mínimos do 2º representante
create or replace function public.pastas_valida_representante2() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.representante2 is not null and (
       length(trim(coalesce(new.representante2->>'nome', ''))) < 3
    or length(regexp_replace(coalesce(new.representante2->>'cpf', ''), '\D', '', 'g')) <> 11
    or length(trim(coalesce(new.representante2->>'profissao', ''))) < 2
    or coalesce(new.representante2->>'estado_civil', '') not in ('solteiro', 'casado', 'uniao_estavel', 'divorciado', 'viuvo')) then
    raise exception 'DADOS_REPRESENTANTE2_INCOMPLETOS' using hint = 'Informe nome, CPF, profissão e estado civil do 2º representante.';
  end if;
  return new;
end;
$$;
drop trigger if exists pastas_valida_representante2 on public.pastas;
create trigger pastas_valida_representante2 before insert or update of representante2 on public.pastas
  for each row execute function public.pastas_valida_representante2();
revoke all on function public.pastas_valida_representante2() from public, anon, authenticated;

-- Download (.zip): nome do 2º representante nos arquivos dele
create or replace function public.registrar_download(p_pasta uuid)
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
           case when t.pessoa = 'conjuge' then coalesce(v_pasta.conjuge_nome, 'CONJUGE')
                when t.pessoa = 'representante2' then coalesce(v_pasta.representante2->>'nome', 'REPRESENTANTE2')
                else v_pasta.comprador_nome end,
           coalesce(v_pasta.codigo_aprovacao, v_pasta.codigo), v_pasta.comprador_nome
      from public.documentos d join public.tipos_documento t on t.id = d.tipo_id
     where d.pasta_id = p_pasta and d.atual
     order by t.ordem, d.enviado_em;
end;
$$;
revoke all on function public.registrar_download(uuid) from public, anon;
grant execute on function public.registrar_download(uuid) to authenticated;

-- Leitura com IA: manda também os dados digitados do 2º representante
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
      'representante2', p.representante2,
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

-- pastas PJ ainda não enviadas: recalcula (passa a exigir o comprovante de estado civil do representante).
-- As já enviadas só mudam se algum documento delas mudar.
do $$ declare r record; begin
  for r in select id from public.pastas where tipo_pessoa = 'pj' and codigo_aprovacao is null loop perform public.recalcular_pasta(r.id); end loop;
end $$;

commit;
