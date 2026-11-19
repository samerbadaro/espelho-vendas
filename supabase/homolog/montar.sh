#!/bin/sh
# Junta todas as migrações num arquivo só, para rodar uma vez no banco NOVO de homologação.
cd "$(dirname "$0")/../.." || exit 1
saida=supabase/homolog/estrutura_completa.sql
{ echo "-- Estrutura completa do Duo Haus (migrações 001 em diante), gerada em $(date +%F)."
  echo "-- Rodar UMA vez no projeto duo-haus-homolog. NUNCA na produção."
  for f in supabase/migrations/0*.sql; do echo; echo "-- ===== $(basename $f) ====="; cat "$f"; done; } > "$saida"
echo "$saida"
