-- 058 — Nome da proposta (da simulação), dado por quem cria, para achar rascunhos e tratativas.
-- Ex.: "Samer – Lote do Parque do Cerrado".
begin;
alter table public.propostas add column if not exists nome text;
alter table public.propostas drop constraint if exists propostas_nome_tamanho;
alter table public.propostas add constraint propostas_nome_tamanho check (nome is null or length(nome) <= 120);
commit;
