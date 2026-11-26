-- 057 — Instrumento de intermediação imobiliária como documento do contrato
-- (emitido em Contratos e assinado no mesmo envelope, entre a Carta Proposta e o Quadro Resumo).
begin;
alter table public.contratos drop constraint if exists contratos_documento_check;
alter table public.contratos add constraint contratos_documento_check
  check (documento in ('quadro_resumo', 'normas', 'carta_proposta', 'intermediacao'));
commit;
