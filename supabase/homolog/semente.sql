-- =====================================================================
-- HOMOLOGAÇÃO — dados fictícios para teste (NUNCA rodar na produção)
-- Rodar depois da estrutura completa (todas as migrações).
-- =====================================================================
do $$ begin
  if current_database() is null then return; end if;
  -- trava de segurança: o banco de produção do Duo Haus tem pastas reais;
  -- se encontrar mais de 20 pastas, entende que NÃO é homologação e para.
  if (select count(*) from public.pastas) > 20 then
    raise exception 'PARECE_PRODUCAO' using hint = 'Este banco já tem pastas. A semente é só para a homologação.';
  end if;
end $$;

update public.config set
  modulo_pastas = true, modulo_funil = true, modulo_portal = true, modulo_rodadas = true, modulo_meeting = true,
  modulo_tv = true, modulo_cadastro = true, modulo_espelho_parceiros = true, modulo_treinamentos = true, modulo_propostas = true
where id = 1;

insert into public.imobiliarias (nome, ativa, cnpj, creci_pj) values
  ('Imobiliária Teste A', true, '11222333000181', 'J-0001'),
  ('Imobiliária Teste B', true, '11444777000161', 'J-0002')
on conflict do nothing;

insert into public.rodadas (nome, data_hora, local, observacoes, limite_clientes, inscricoes_abertas, todas_imobiliarias)
select 'Rodada de teste', now() + interval '10 days', 'Stand de vendas (teste)', 'Rodada fictícia para homologação.', 40, true, true
where not exists (select 1 from public.rodadas where nome = 'Rodada de teste');

select 'imobiliarias' as tabela, count(*) from public.imobiliarias
union all select 'unidades', count(*) from public.unidades
union all select 'rodadas', count(*) from public.rodadas;
