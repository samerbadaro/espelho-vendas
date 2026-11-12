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
