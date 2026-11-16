-- =====================================================================
-- 029 — Corretor responsável pela pasta
--  * A pasta pertence ao corretor atribuído, não a quem a cadastrou.
--    pastas.criado_por_id passa a significar "corretor responsável" (é ele
--    que todas as regras de acesso já usam); quem cadastrou fica guardado
--    em pastas.cadastrado_por_id.
--  * O corretor vê as pastas atribuídas a ele (lista, funil e andamento);
--    a imobiliária continua vendo todas as suas.
--  * Equipe e imobiliária (para as suas pastas) atribuem ou trocam o corretor.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.pastas add column if not exists cadastrado_por_id uuid;
update public.pastas set cadastrado_por_id = criado_por_id where cadastrado_por_id is null;
comment on column public.pastas.criado_por_id is 'Corretor responsável (dono da pasta para as regras de acesso)';
comment on column public.pastas.cadastrado_por_id is 'Login que cadastrou a pasta';

-- pastas cadastradas pela equipe ou pela imobiliária não têm corretor até alguém atribuir
update public.pastas p set criado_por_id = null
  from public.perfis f
 where f.user_id = p.criado_por_id and f.papel <> 'corretor';

create or replace function public.pastas_cadastro() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_papel text;
begin
  new.cadastrado_por_id := auth.uid();
  select papel into v_papel from public.perfis where user_id = auth.uid();
  -- só um corretor vira dono automático da pasta que ele mesmo cadastra
  if coalesce(v_papel, '') <> 'corretor' then new.criado_por_id := null; end if;
  return new;
end;
$$;
drop trigger if exists pastas_cadastro on public.pastas;
create trigger pastas_cadastro before insert on public.pastas
  for each row execute function public.pastas_cadastro();   -- roda depois de pastas_antes (ordem alfabética)

create or replace function public.atribuir_corretor(p_pasta uuid, p_corretor uuid)
returns public.pastas
language plpgsql security definer set search_path = public as $$
declare v public.pastas; v_antes text; v_depois text;
begin
  select * into v from public.pastas where id = p_pasta for update;
  if not found then raise exception 'PASTA_NAO_ENCONTRADA'; end if;
  if not (public.eh_equipe() or (public.eh_gestor() and v.imobiliaria_id = public.minha_imobiliaria())) then
    raise exception 'SEM_PERMISSAO' using errcode = '42501';
  end if;
  if p_corretor is not null and not exists (
    select 1 from public.perfis where user_id = p_corretor and papel = 'corretor' and imobiliaria_id = v.imobiliaria_id
  ) then raise exception 'CORRETOR_INVALIDO'; end if;
  if v.criado_por_id is not distinct from p_corretor then return v; end if;

  select coalesce(nullif(nome, ''), email) into v_antes from public.perfis where user_id = v.criado_por_id;
  select coalesce(nullif(nome, ''), email) into v_depois from public.perfis where user_id = p_corretor;
  update public.pastas set criado_por_id = p_corretor where id = p_pasta returning * into v;
  update public.negociacoes set corretor = v_depois where pasta_id = p_pasta and ativa;
  insert into public.historico_pastas (pasta_id, acao, detalhes, usuario_email)
  values (p_pasta, 'Corretor responsável alterado',
          jsonb_build_object('corretor', coalesce(v_antes, 'sem corretor') || ' → ' || coalesce(v_depois, 'sem corretor')),
          public.meu_email());
  return v;
end;
$$;
revoke all on function public.atribuir_corretor(uuid, uuid) from public, anon;
grant execute on function public.atribuir_corretor(uuid, uuid) to authenticated;
