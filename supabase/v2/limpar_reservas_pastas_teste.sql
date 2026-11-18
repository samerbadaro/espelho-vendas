-- Apaga os dados gerados por seed_reservas_pastas_teste.sql (só no projeto espelho-v2).
set session_replication_role = replica;
with u as (select distinct unidade_id from public.historico where motivo = '[TESTE]')
update public.unidades set status = 'disponivel', versao = versao + 1, atualizado_em = now() where id in (select unidade_id from u);
delete from public.negociacoes where unidade_id in (select unidade_id from public.historico where motivo = '[TESTE]');
delete from public.historico where motivo = '[TESTE]';
delete from public.pastas where observacoes like '[TESTE]%';
set session_replication_role = origin;
