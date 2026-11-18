-- =====================================================================
-- 034 — Portal do Corretor: categoria "Regras da premiação"
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================
alter table public.portal_itens drop constraint if exists portal_itens_categoria_check;
alter table public.portal_itens add constraint portal_itens_categoria_check check (categoria in (
  'book', 'ficha_tecnica', 'fotos_decorado', 'imagens', 'materiais_apoio', 'redes_sociais',
  'plantas', 'premiacao', 'simulador', 'tour_virtual', 'videos'));
