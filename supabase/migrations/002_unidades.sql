-- =====================================================================
-- Carga inicial das 173 unidades
--  * 2º andar: finais 01 a 08 (posições 09–11 são o lazer)
--  * 3º ao 17º andar: finais 01 a 11 (numeração sequencial, com 13º andar)
--  * Área privativa por final, conforme a planta enviada
-- Tipologia fica em branco até ser informada.
-- =====================================================================
with areas(posicao, area) as (
  values (1, 34.93), (2, 35.00), (3, 35.00), (4, 34.93), (5, 34.93), (6, 34.93),
         (7, 34.93), (8, 34.99), (9, 34.99), (10, 34.93), (11, 34.92)
)
insert into public.unidades (numero, andar, posicao, area_privativa)
select (andar * 100 + a.posicao)::text, andar, a.posicao, a.area
from generate_series(2, 17) as andar
cross join areas a
where not (andar = 2 and a.posicao > 8)
order by andar, a.posicao;
