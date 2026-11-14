-- =====================================================================
-- 021 — Carta proposta no modelo novo
--  * Campos da carta: vaga, escaninho, coordenação comercial.
--  * Textos de abertura e condições gerais do modelo (foro de Rio Verde).
--  * Nome de quem criou a proposta (sai como corretor na carta).
-- Executar uma única vez no SQL Editor do Supabase (projeto de testes).
-- =====================================================================

alter table public.comercial
  add column if not exists vaga                  text not null default 'Não inclui',
  add column if not exists escaninho             text not null default 'Não inclui',
  add column if not exists coordenacao_comercial text;

update public.comercial set
  forma_sinal = 'PIX',
  coordenacao_comercial = coalesce(coordenacao_comercial, 'Kavaná'),
  texto_abertura = 'Por meio desta, o(s) proponente(s) abaixo qualificado(s) formaliza(m) proposta para aquisição da unidade descrita, nos termos e condições a seguir, para avaliação da vendedora.',
  texto_condicoes = $t$A partir desta data e até o mês da expedição do habite-se, os valores serão reajustados pelo INCC (Índice Nacional de Custo da Construção). A partir do primeiro dia do mês seguinte ao habite-se e até a quitação, os valores serão reajustados mensalmente pelo IGP-M (Índice Geral de Preços do Mercado), acrescidos de juros de 1% (um por cento) ao mês.
Esta proposta será analisada pela vendedora, que poderá recusá-la, ainda que sem motivação.
A concessão do financiamento bancário está sujeita à análise de crédito e aos critérios do banco financiador. É de responsabilidade exclusiva do(s) proponente(s) obter os recursos para a parcela de financiamento, por crédito bancário ou recursos próprios.
Os honorários de intermediação imobiliária serão pagos com o sinal de negócio definido nesta proposta. Os valores de sinal e intermediação devem ser quitados na assinatura desta proposta.
Em caso de recusa desta proposta ou de não compensação do sinal, ela perderá qualquer eficácia jurídica e a unidade ficará liberada para comercialização, sem ônus para o(s) proponente(s).
Questões oriundas desta proposta serão resolvidas preferencialmente por via conciliatória ou arbitral, ficando eleito o foro da comarca de Rio Verde - GO.$t$,
  atualizado_em = now()
where id = 1;

-- Nome de quem criou a proposta
alter table public.propostas add column if not exists criado_por_nome text;
update public.propostas p set criado_por_nome = coalesce(nullif(pf.nome, ''), pf.email)
  from public.perfis pf where pf.user_id = p.criado_por_id and p.criado_por_nome is null;

create or replace function public.propostas_nome_criador() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    select coalesce(nullif(nome, ''), email) into new.criado_por_nome from public.perfis where user_id = auth.uid();
  else
    new.criado_por_nome := old.criado_por_nome;
  end if;
  return new;
end;
$$;
drop trigger if exists propostas_nome_criador on public.propostas;
-- roda depois de propostas_antes (ordem alfabética dos gatilhos)
create trigger propostas_nome_criador before insert or update on public.propostas
  for each row execute function public.propostas_nome_criador();
