# v2 – Proposta, valor presente e comissão

Ramo `v2`. Banco de testes: projeto Supabase `yntdnpuokozhhytdknnm` (organização gratuita).
O ramo `main` e o projeto `mtlzwuiqznsyqasmdkew` (Duo Haus) não são tocados.

## Motor de cálculo (`src/proposta/calculo.ts`)

Reproduz a planilha `Compacto_Studio.xlsm`. Conferido com `npm run teste:proposta`
(26 conferências), incluindo o valor presente da tabela da unidade 1804
(R$ 342.011,62 a 0,7% a.m.), idêntico à aba PV.

- Preço da unidade: R$/m² do grupo × peso × (área + escaninho) ÷ média dos pesos do grupo + vaga.
- Fluxo da tabela: séries com %, número de parcelas, periodicidade e início relativo à venda ou à entrega.
- Valor presente "securitizado": todo o pós-chaves conta como recebido no mês seguinte à entrega;
  o mês da tabela não é descontado.
- Comparação tabela × proposta: total, VP, variação, captação até as chaves e recebimento
  acumulado em 3, 6, 12, 18, 24 e 36 meses e até a entrega.
- Validações da planilha: VP abaixo da tabela, dia de vencimento (5/10/15/20), sinal no passado,
  série pré-chaves terminando depois das chaves, financiamento antes da entrega, queda > 15% por horizonte.
- Comissão: regra proporcional (70/30, 80/20…) ou retenção do incorporador na 1ª parcela.

## Pontos encontrados na planilha (para confirmar com o Samer)

1. A aba PV usa os percentuais da Tabela 1 com as quantidades e datas da Tabela 3.
   A unidade 1804 está marcada como TABELA 2, mas o cálculo sai pela mistura 1 + 3.
2. O teste "até a entrega" do recebimento acumulado está fixo até abr/2030; a entrega é out/2030.
3. O teste de financiamento no pré-chaves compara com a data fixa 01/01/2025.
4. A carta proposta ainda traz "NOAH SIM HOME" e algumas fórmulas com #REF!.
5. Comissão hoje: % em cada linha do sinal × valor total da proposta.
