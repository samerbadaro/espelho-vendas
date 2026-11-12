-- =====================================================================
-- 009 — Sec. Vendas passa a ver os nomes dos logins (corretores e
-- imobiliárias), para os relatórios e a exportação de pastas.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================
drop policy perfis_leitura on public.perfis;
create policy perfis_leitura on public.perfis for select
  using (user_id = auth.uid() or public.eh_equipe()
         or (public.eh_gestor() and imobiliaria_id = public.minha_imobiliaria()));
