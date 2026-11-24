-- =====================================================================
-- 054 · Um envelope em andamento por unidade (proposta), não por pasta
--   O índice da 046 deixava só um envelope ativo por pasta: com duas
--   unidades do mesmo cliente, o envelope da segunda não era gravado.
-- =====================================================================
begin;
drop index if exists public.envelopes_um_ativo;
create unique index envelopes_um_ativo on public.envelopes (proposta_id) where status in ('preparado', 'enviado');
commit;
