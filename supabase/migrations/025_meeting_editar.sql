-- =====================================================================
-- 025 — Meeting: editar nome, imobiliária e telefone de um convidado
--  * A equipe corrige os dados na recepção, antes ou depois de confirmar.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

create or replace function public.editar_participante(p_id uuid, p_nome text, p_imobiliaria text default null,
                                                      p_telefone text default null, p_confirmar boolean default false)
returns public.recepcao_participantes
language plpgsql security definer set search_path = public as $$
declare v public.recepcao_participantes;
begin
  if not public.eh_equipe() then raise exception 'SEM_PERMISSAO' using errcode = '42501'; end if;
  if coalesce(length(trim(p_nome)), 0) < 3 then raise exception 'NOME_OBRIGATORIO'; end if;
  update public.recepcao_participantes
     set nome = regexp_replace(trim(p_nome), '\s+', ' ', 'g'),
         imobiliaria = nullif(regexp_replace(trim(coalesce(p_imobiliaria, '')), '\s+', ' ', 'g'), ''),
         telefone = nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), ''),
         presente = presente or p_confirmar,
         chegada_em = case when p_confirmar and not presente then now() else chegada_em end,
         confirmado_por = case when p_confirmar and not presente then public.meu_email() else confirmado_por end
   where id = p_id returning * into v;
  if not found then raise exception 'PARTICIPANTE_NAO_ENCONTRADO'; end if;
  return v;
end;
$$;

revoke all on function public.editar_participante(uuid, text, text, text, boolean) from public, anon;
grant execute on function public.editar_participante(uuid, text, text, text, boolean) to authenticated;
