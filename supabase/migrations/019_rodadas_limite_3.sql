-- =====================================================================
-- 019 — Rodadas: no máximo 3 pessoas por cliente (o cliente e até 2 acompanhantes)
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

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
  if coalesce(array_length(v, 1), 0) < 1 or array_length(v, 1) > 3 then raise exception 'PESSOAS_INVALIDO'; end if;
  return v;
end;
$$;
