#!/bin/bash
# Duas pessoas da equipe alteram a MESMA unidade ao mesmo tempo, ambas com a versão 1.
# Esperado: exatamente uma consegue e a outra recebe CONFLITO.
P="psql -h ${PGHOST:-/tmp} -p ${PGPORT:-5499} -U postgres -d espelho -q -t"
tenta() {
  $P <<SQL 2>&1 | grep -Eo 'CONFLITO|reservada|vendida' | head -1
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false) \g /dev/null
begin;
select status from public.alterar_status((select id from unidades where numero='1305'), '$1', 1, null, 'Imob', 'Corretor', 'Cliente');
select pg_sleep(1) \g /dev/null
commit;
SQL
}
tenta reservada > /tmp/a.txt & tenta vendida > /tmp/b.txt & wait
echo "Sessão A: $(cat /tmp/a.txt) | Sessão B: $(cat /tmp/b.txt)"
$P -c "select 'Estado final: ' || status || ' (versão ' || versao || '), registros no histórico: ' || (select count(*) from historico where numero='1305') from unidades where numero='1305'"
$P -c "delete from historico; delete from negociacoes; update unidades set status='disponivel', versao=1;" >/dev/null
