-- =====================================================================
-- Dados de TESTE (só no projeto espelho-v2): para cada empreendimento (DH e RT)
--  * 30 pastas em todos os status (incompleta, pronta, aguardando análise,
--    em análise, pendente de correção, aprovada), de 5 imobiliárias;
--  * 30 negociações no espelho: reservada, proposta, contrato e vendida,
--    com valor de venda, corretor, imobiliária e histórico espalhado nos
--    últimos meses (alimenta Painéis, VSO, rankings e funil).
--  Marcados com "[TESTE]" nas observações e no motivo, para apagar depois.
--  Não roda duas vezes no mesmo empreendimento.
-- =====================================================================
set session_replication_role = replica;   -- grava direto, sem as regras de tela (permissões, documentos)

do $$
declare
  v_emp record;
  v_imobs uuid[];
  v_imob_nomes text[] := array['TESTE ALFA', 'Horizonte Imóveis', 'Prime Negócios Imobiliários', 'Casa Certa Imóveis', 'Viva Rio Verde Imóveis'];
  v_corretores text[] := array['Ana Paula Moraes', 'Bruno Carvalho', 'Carla Mendes', 'Diego Fernandes', 'Eduarda Lima', 'Felipe Souza',
                               'Gabriela Rocha', 'Henrique Alves', 'Isabela Martins', 'João Pedro Silva'];
  v_nomes text[] := array['Mariana', 'Rafael', 'Juliana', 'Lucas', 'Fernanda', 'Gustavo', 'Patrícia', 'Thiago', 'Camila', 'Rodrigo',
                          'Larissa', 'André', 'Beatriz', 'Marcelo', 'Aline', 'Leonardo', 'Renata', 'Vinícius', 'Tatiane', 'Paulo'];
  v_sobrenomes text[] := array['Albuquerque', 'Barbosa', 'Cardoso', 'Duarte', 'Esteves', 'Freitas', 'Gonçalves', 'Hoffmann',
                               'Lacerda', 'Macedo', 'Nogueira', 'Oliveira', 'Pereira', 'Queiroz', 'Ribeiro', 'Teixeira'];
  v_status_pasta text[] := array['incompleta', 'incompleta', 'incompleta', 'incompleta', 'pronta', 'pronta', 'pronta',
                                 'aguardando_analise', 'aguardando_analise', 'aguardando_analise', 'em_analise', 'em_analise',
                                 'pendente_correcao', 'pendente_correcao'];   -- 14 + 16 aprovadas
  v_status_neg text[] := array['reservada', 'reservada', 'reservada', 'reservada', 'reservada', 'reservada', 'reservada', 'reservada', 'reservada', 'reservada',
                               'proposta', 'proposta', 'proposta', 'proposta', 'proposta', 'proposta', 'proposta', 'proposta',
                               'contrato', 'contrato', 'contrato', 'contrato', 'contrato', 'contrato',
                               'vendida', 'vendida', 'vendida', 'vendida', 'vendida', 'vendida'];
  v_corretor_teste uuid := (select user_id from public.perfis where email = 'samerbadaroteste@hotmail.com');
  v_pastas uuid[];
  v_unids record;
  i int; k int;
  v_pasta uuid; v_imob int; v_nome text; v_cpf text; v_st text; v_quando timestamptz; v_preco numeric; v_neg_st text;
  d int[]; s1 int; s2 int;
begin
  -- imobiliárias de teste
  foreach v_nome in array v_imob_nomes loop
    insert into public.imobiliarias (nome) select v_nome where not exists (select 1 from public.imobiliarias where nome = v_nome);
  end loop;
  select array_agg(id order by array_position(v_imob_nomes, nome)) into v_imobs from public.imobiliarias where nome = any (v_imob_nomes);

  for v_emp in select * from public.empreendimentos where sigla in ('DH', 'RT') order by ordem loop
    if exists (select 1 from public.pastas where empreendimento_id = v_emp.id and observacoes like '[TESTE]%') then continue; end if;
    v_pastas := '{}';

    -- 30 pastas
    for i in 1 .. 30 loop
      v_imob := 1 + (i % 5);
      v_nome := v_nomes[1 + (i * 7 + length(v_emp.sigla) * 3) % 20] || ' ' || v_sobrenomes[1 + (i * 5) % 16] || ' ' || v_sobrenomes[1 + (i * 11 + 3) % 16];
      -- CPF válido gerado
      d := array[floor(random() * 10)::int, floor(random() * 10)::int, floor(random() * 10)::int, floor(random() * 10)::int, floor(random() * 10)::int,
                 floor(random() * 10)::int, floor(random() * 10)::int, floor(random() * 10)::int, 1 + floor(random() * 9)::int];
      s1 := 0; for k in 1 .. 9 loop s1 := s1 + d[k] * (11 - k); end loop; s1 := case when s1 % 11 < 2 then 0 else 11 - s1 % 11 end;
      s2 := 0; for k in 1 .. 9 loop s2 := s2 + d[k] * (12 - k); end loop; s2 := s2 + s1 * 2; s2 := case when s2 % 11 < 2 then 0 else 11 - s2 % 11 end;
      v_cpf := array_to_string(d, '') || s1 || s2;
      v_st := case when i <= 14 then v_status_pasta[i] else 'aprovada' end;
      v_quando := now() - make_interval(days => 5 + (i * 37) % 110, hours => (i * 5) % 12);

      insert into public.pastas (codigo, imobiliaria_id, comprador_nome, comprador_cpf, comprador_nascimento, comprador_telefone, comprador_email,
                                 comprador_profissao, estado_civil, status, criado_por, criado_por_id, criada_em, atualizada_em,
                                 codigo_aprovacao, submetida_em, submetida_por, etapa_venda, observacoes, empreendimento_id)
      values (public.proximo_codigo(v_emp.id, 'P'), v_imobs[v_imob], v_nome, v_cpf, date '1975-01-01' + (i * 397) % 9000,
              '6499' || lpad(((i * 7919 + length(v_emp.sigla) * 104729) % 10000000)::text, 7, '0'),
              lower(translate(split_part(v_nome, ' ', 1) || '.' || split_part(v_nome, ' ', 2), 'áéíóúâêôãõç', 'aeiouaeoaoc')) || i || '@exemplo.com',
              (array['Médico(a)', 'Empresário(a)', 'Engenheiro(a) agrônomo(a)', 'Advogado(a)', 'Produtor(a) rural', 'Professor(a)'])[1 + i % 6],
              case when i % 3 = 0 then 'casado'::estado_civil else 'solteiro'::estado_civil end,
              v_st,
              case when v_imob = 1 then 'samerbadaroteste@hotmail.com' else v_corretores[1 + i % 10] end,
              case when v_imob = 1 then v_corretor_teste end,
              v_quando, v_quando + interval '2 days',
              case when v_st in ('aguardando_analise', 'em_analise', 'pendente_correcao', 'aprovada') then public.proximo_codigo(v_emp.id, 'PA') end,
              case when v_st in ('aguardando_analise', 'em_analise', 'pendente_correcao', 'aprovada') then v_quando + interval '1 day' end,
              case when v_st in ('aguardando_analise', 'em_analise', 'pendente_correcao', 'aprovada') then 'corretor@exemplo.com' end,
              'aprovada', '[TESTE] pasta gerada para testes', v_emp.id)
      returning id into v_pasta;
      if v_st = 'aprovada' then v_pastas := v_pastas || v_pasta; end if;
    end loop;

    -- 30 negociações em unidades sorteadas
    i := 0;
    for v_unids in
      select u.id, u.numero, u.versao, coalesce(public.preco_tabela_unidade(u.id), 500000) as preco
        from public.unidades u where u.empreendimento_id = v_emp.id and u.status = 'disponivel'
       order by md5(u.id::text || v_emp.sigla) limit 30
    loop
      i := i + 1;
      v_neg_st := v_status_neg[i];
      v_imob := 1 + (i % 5);
      v_quando := now() - make_interval(days => 3 + (i * 23) % 120, hours => (i * 7) % 10);
      v_preco := round(v_unids.preco * (0.965 + (i % 4) * 0.01), 2);
      v_pasta := case when i <= array_length(v_pastas, 1) then v_pastas[i] end;
      if v_pasta is not null then
        select comprador_nome into v_nome from public.pastas where id = v_pasta;
        v_imob := array_position(v_imobs, (select imobiliaria_id from public.pastas where id = v_pasta));
      else
        v_nome := v_nomes[1 + (i * 3) % 20] || ' ' || v_sobrenomes[1 + (i * 13) % 16];
      end if;

      update public.unidades set status = v_neg_st::status_unidade, versao = versao + 1, atualizado_em = v_quando where id = v_unids.id;
      insert into public.negociacoes (unidade_id, imobiliaria, corretor, cliente, valor_venda, pv_aprovado, ativa, criado_por, criada_em, atualizada_em, pasta_id, empreendimento_id)
      values (v_unids.id, v_imob_nomes[v_imob],
              case when v_imob = 1 then 'Samer (corretor teste)' else v_corretores[1 + (i * 3) % 10] end,
              v_nome,
              case when v_neg_st = 'reservada' then null else v_preco end,
              case when v_neg_st = 'reservada' then null else round(97 + (i % 5) * 0.8, 2) end,
              true, 'equipe@exemplo.com', v_quando, v_quando, v_pasta, v_emp.id);

      -- histórico: disponível → reservada → (proposta → contrato → vendida)
      insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_email, criado_em, empreendimento_id)
      values (v_unids.id, v_unids.numero, 'disponivel', 'reservada', '[TESTE]', 'equipe@exemplo.com', v_quando, v_emp.id);
      if v_neg_st in ('proposta', 'contrato', 'vendida') then
        insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_email, criado_em, empreendimento_id)
        values (v_unids.id, v_unids.numero, 'reservada', 'proposta', '[TESTE]', 'equipe@exemplo.com', v_quando + interval '2 days', v_emp.id);
      end if;
      if v_neg_st in ('contrato', 'vendida') then
        insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_email, criado_em, empreendimento_id)
        values (v_unids.id, v_unids.numero, 'proposta', 'contrato', '[TESTE]', 'equipe@exemplo.com', v_quando + interval '6 days', v_emp.id);
      end if;
      if v_neg_st = 'vendida' then
        insert into public.historico (unidade_id, numero, status_anterior, status_novo, motivo, usuario_email, criado_em, empreendimento_id)
        values (v_unids.id, v_unids.numero, 'contrato', 'vendida', '[TESTE]', 'equipe@exemplo.com', least(now(), v_quando + interval '15 days'), v_emp.id);
      end if;

      if v_pasta is not null then
        update public.pastas set unidade_id = v_unids.id, unidades_numeros = v_unids.numero,
               etapa_venda = case v_neg_st when 'reservada' then 'reserva' when 'proposta' then 'reserva' when 'contrato' then
                                   (case when i % 2 = 0 then 'contrato_confeccao' else 'enviado_assinatura' end) else 'assinado' end,
               etapa_atualizada_em = v_quando
         where id = v_pasta;
      end if;
    end loop;
  end loop;
end $$;

set session_replication_role = origin;
