-- =====================================================================
-- 028 — Funil de vendas para imobiliárias e corretores (só leitura)
--  * O corretor vê as negociações das pastas dele; a imobiliária, as de
--    todos os seus corretores (mesma regra de acesso das pastas).
--  * Mover etapa continua só com a equipe (mover_etapa já exige eh_equipe).
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

drop policy if exists negociacoes_parceiros on public.negociacoes;
create policy negociacoes_parceiros on public.negociacoes for select
  using (pasta_id is not null and public.pode_ver_pasta(pasta_id));
