-- =====================================================================
-- 018 — Rodadas: nome completo de cada convidado
--  * O corretor informa quantas pessoas vêm e o nome completo de cada uma.
--    O primeiro nome é o do cliente; os demais são acompanhantes.
--  * Só quem confirmou (o corretor) edita ou cancela. A imobiliária vê os
--    convidados dos seus corretores; Sec. Vendas e administrador veem e
--    alteram tudo.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.rodada_inscricoes add column if not exists convidados text[];
update public.rodada_inscricoes set convidados = array[cliente_nome] where convidados is null;

-- Limpa e confere a lista de nomes
create or replace function public.normalizar_convidados(p text[]) returns text[]
language plpgsql immutable as $$
declare v text[] := '{}'; n text;
begin
  foreach n in array coalesce(p, '{}') loop
    n := regexp_replace(trim(coalesce(n, '')), '\s+', ' ', 'g');
    if length(n) < 3 then raise exception 'NOME_CONVIDADO_OBRIGATORIO'; end if;
    if position(' ' in n) = 0 then raise exception 'NOME_COMPLETO_OBRIGATORIO' using hint = n; end if;
    v := v || n;
  end loop;
  if coalesce(array_length(v, 1), 0) < 1 or array_length(v, 1) > 20 then raise exception 'PESSOAS_INVALIDO'; end if;
  return v;
end;
$$;

create or replace function public.pode_alterar_inscricao(p public.rodada_inscricoes) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_equipe() or p.corretor_id = auth.uid();
$$;

drop function if exists public.confirmar_cliente_rodada(uuid, text, int, text, text, uuid);
drop function if exists public.editar_cliente_rodada(uuid, text, int, text, text);

create function public.confirmar_cliente_rodada(
  p_rodada uuid, p_convidados text[], p_telefone text default null, p_observacao text default null,
  p_imobiliaria uuid default null
) returns public.rodada_inscricoes
language plpgsql security definer set search_path = public as $$
declare
  v_rodada public.rodadas;
  v_lista  text[] := public.normalizar_convidados(p_convidados);
  v_imob   uuid;
  v_nome   text;
  v_ocup   int;
  v        public.rodada_inscricoes;
begin
  select * into v_rodada from public.rodadas where id = p_rodada for update;
  if not found or not public.rodada_liberada(p_rodada) then raise exception 'RODADA_NAO_ENCONTRADA'; end if;
  if not public.eh_equipe() and not v_rodada.inscricoes_abertas then raise exception 'INSCRICOES_ENCERRADAS'; end if;
  if not public.eh_equipe() and v_rodada.data_hora < now() then raise exception 'RODADA_JA_ACONTECEU'; end if;

  select count(*) into v_ocup from public.rodada_inscricoes where rodada_id = p_rodada and not cancelada;
  if v_ocup >= v_rodada.limite_clientes then raise exception 'RODADA_LOTADA'; end if;

  v_imob := case when public.eh_equipe() then p_imobiliaria else public.minha_imobiliaria() end;
  select coalesce(nullif(nome, ''), email) into v_nome from public.perfis where user_id = auth.uid();

  begin
    insert into public.rodada_inscricoes (rodada_id, cliente_nome, pessoas, convidados, telefone, observacao, imobiliaria_id, corretor_id, corretor_nome)
    values (p_rodada, v_lista[1], array_length(v_lista, 1), v_lista, nullif(trim(p_telefone), ''),
            nullif(trim(p_observacao), ''), v_imob, auth.uid(), v_nome)
    returning * into v;
  exception when unique_violation then
    raise exception 'CLIENTE_JA_CONFIRMADO';
  end;
  return v;
end;
$$;

create function public.editar_cliente_rodada(
  p_id uuid, p_convidados text[], p_telefone text default null, p_observacao text default null
) returns public.rodada_inscricoes
language plpgsql security definer set search_path = public as $$
declare v public.rodada_inscricoes; v_rodada public.rodadas; v_lista text[] := public.normalizar_convidados(p_convidados);
begin
  select * into v from public.rodada_inscricoes where id = p_id for update;
  if not found or v.cancelada or not public.pode_alterar_inscricao(v) then raise exception 'INSCRICAO_NAO_ENCONTRADA'; end if;
  select * into v_rodada from public.rodadas where id = v.rodada_id;
  if not public.eh_equipe() and (not v_rodada.inscricoes_abertas or v_rodada.data_hora < now()) then
    raise exception 'INSCRICOES_ENCERRADAS';
  end if;
  begin
    update public.rodada_inscricoes
       set cliente_nome = v_lista[1], pessoas = array_length(v_lista, 1), convidados = v_lista,
           telefone = nullif(trim(p_telefone), ''), observacao = nullif(trim(p_observacao), ''), atualizado_em = now()
     where id = p_id returning * into v;
  exception when unique_violation then
    raise exception 'CLIENTE_JA_CONFIRMADO';
  end;
  return v;
end;
$$;

revoke all on function public.confirmar_cliente_rodada(uuid, text[], text, text, uuid) from public, anon;
revoke all on function public.editar_cliente_rodada(uuid, text[], text, text) from public, anon;
grant execute on function public.confirmar_cliente_rodada(uuid, text[], text, text, uuid) to authenticated;
grant execute on function public.editar_cliente_rodada(uuid, text[], text, text) to authenticated;
