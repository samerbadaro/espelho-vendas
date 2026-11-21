-- =====================================================================
-- Backup antes do 035 (propostas). Rodar ANTES do 035, uma única vez.
-- Copia as tabelas do espelho e das pastas para o esquema "backup_035",
-- que não aparece para o site (só aqui no SQL Editor).
-- =====================================================================
create schema if not exists backup_035;
revoke all on schema backup_035 from public, anon, authenticated;
create table backup_035.config            as select * from public.config;
create table backup_035.unidades          as select * from public.unidades;
create table backup_035.negociacoes       as select * from public.negociacoes;
create table backup_035.historico         as select * from public.historico;
create table backup_035.pastas            as select * from public.pastas;
create table backup_035.historico_pastas  as select * from public.historico_pastas;
select 'unidades' as tabela, count(*) from backup_035.unidades
union all select 'negociacoes', count(*) from backup_035.negociacoes
union all select 'pastas', count(*) from backup_035.pastas;
