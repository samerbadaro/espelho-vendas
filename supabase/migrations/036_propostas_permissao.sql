-- =====================================================================
-- 036 — Corrige o salvar de Empreendimento depois do 035
-- O 035 criou a chave "modulo_propostas", mas não liberou a gravação dela.
-- Como a tela de Empreendimento salva todas as chaves juntas, qualquer
-- mudança de módulo dava erro. Executar uma única vez no SQL Editor.
-- =====================================================================
grant update (modulo_propostas) on public.config to authenticated;
