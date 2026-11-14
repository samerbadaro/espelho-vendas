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
