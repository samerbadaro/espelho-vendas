// Quadro Resumo — minuta final do Duo Haus (recebida em 23/11/2026), com os dados da vendedora,
// da incorporadora e do empreendimento trocados por campos do cadastro "Dados para contrato".
// Marcação: "= " título, "== " seção, "~ " nota em itálico, "## " parágrafo em negrito,
// "> " alínea recuada, "@bloco" bloco montado pelo sistema, {{campo}} dado do cadastro.
// Pontos da minuta a validar com o jurídico ficam no roadmap (referências cruzadas e numeração).
export const QUADRO_RESUMO = `= COMPROMISSO DE VENDA E COMPRA DE UNIDADE AUTÔNOMA DO EMPREENDIMENTO {{empreendimento.nome}}

= QUADRO RESUMO

== 1 - PARTES

> a) Na condição de promitente VENDEDORA {{vendedora.razao_social}}, pessoa jurídica de direito privado, inscrita no CNPJ nº {{vendedora.cnpj}}, com sede na {{vendedora.endereco}}, e na qualidade de incorporadora {{incorporadora.razao_social}}, pessoa jurídica de direito privado, inscrita no CNPJ nº {{incorporadora.cnpj}}, com sede na {{incorporadora.endereco}}.

> b) Na condição de promissário COMPRADOR (independentemente do número):

@partes

== 2 - EMPREENDIMENTO

2.1 – Este contrato tem por objeto a aquisição, por parte do COMPRADOR, da unidade autônoma indicada no item “3” abaixo, do empreendimento {{empreendimento.nome}} localizado na cidade de {{empreendimento.cidade}} com Memorial de Incorporação devidamente registrado sob n. {{empreendimento.registro_incorporacao}} da matrícula {{empreendimento.matricula}} do {{empreendimento.cartorio}}.

2.2 - O empreendimento foi submetido pela VENDEDORA ao regime do patrimônio de afetação, devidamente averbado na matrícula do imóvel.

== 3 – UNIDADE AUTÔNOMA

@unidade_quadro

3.1 – A unidade autônoma objeto deste contrato não possui vaga de garagem vinculada, nem área privativa de garagem. Caberá à referida unidade o direito de uso de 01 (uma) vaga de garagem indeterminada e rotativa, na garagem coletiva do empreendimento, para a guarda de 01 (um) veículo de passeio, sem demarcação ou localização fixa, a ser utilizada conforme a disponibilidade e as regras de uso, ordem e rodízio estabelecidas na Convenção de Condomínio e no Regimento Interno. Esse direito é acessório à unidade autônoma, não constitui unidade autônoma nem área privativa ou acessória, não será objeto de matrícula própria e não poderá ser alienado, locado ou cedido separadamente da unidade, nem a pessoas estranhas ao condomínio, nos termos do art. 1.331, § 1º, do Código Civil.

== 4 - PREÇO

@pagamento_quadro

4.2 – A responsabilidade pela obtenção do financiamento bancário competirá exclusivamente ao COMPRADOR, sem qualquer responsabilidade da VENDEDORA, inclusive no que se refere à obtenção dos documentos exigidos pela instituição financeira. O não pagamento de qualquer das parcelas descritas no item 4.1 acima, até a data de seus respectivos vencimentos, colocará o COMPRADOR em mora, sujeitando-o às penalidades previstas nas Normas Contratuais.

## 4.3 - CORREÇÃO MONETÁRIA E INCIDÊNCIA DE JUROS

4.3.1 – As parcelas do preço serão corrigidas da seguinte forma:

> a) As parcelas serão corrigidas monetariamente, até o mês de conclusão das obras, caracterizado pela expedição do Habite-se, pela variação positiva do percentual mensal do INCC (Índice Nacional de Custos da Construção Civil), calculado pela FGV, tomando-se como base o índice de 02 (dois) meses anteriores ao da assinatura do contrato e como índice de correção o relativo ao segundo mês anterior àquele em que será realizado o pagamento da prestação.

> b) As parcelas que tiverem vencimento a partir do mês imediatamente posterior ao Habite-se, bem como aquelas vencidas e eventualmente não pagas, que foram corrigidas monetariamente até então pela alínea “a” acima, passarão a ser corrigidas pela variação positiva do percentual mensal do IGP-M (Índice Geral de Preços - Mercado), calculado pela FGV, tomando-se como base o índice de 02 (dois) meses anteriores ao da expedição do Habite-se e como índice de correção o relativo ao segundo mês anterior àquele em que será realizado o pagamento da prestação.

4.3.2 - Todas as parcelas do item 4.1, inclusive aquelas vencidas e não pagas, que tenham vencimento após a expedição do habite-se do empreendimento, terão incidência de juros de 1% (um por cento) ao mês, calculados pela Tabela Price.

4.3.3 – As parcelas dos itens “b” e “c” do item 4.1, serão corrigidas monetariamente na forma prevista no item 4.3.1 acima.

4.3.4 - A data base para efeito de correção das parcelas é {{contrato.data_base}}, independente da data de assinatura deste instrumento.

4.3.5 – O COMPRADOR terá livre escolha para obtenção do financiamento bancário na instituição financeira de sua preferência, porém está ciente que algumas instituições financeiras vinculam a liberação de recursos para a quitação da unidade autônoma somente após a averbação da construção do empreendimento junto ao Cartório de Registro de Imóveis competente, que poderá ocorrer em até 180 (cento e oitenta) dias após a expedição do habite-se do empreendimento. Nesta hipótese, incidirá sobre o saldo devedor do contrato a correção monetária e incidência de juros de 1% (um por cento) ao mês, calculados pela Tabela Price, até a data da efetiva liberação dos recursos necessários para a quitação do saldo devedor junto a VENDEDORA.

4.3.6 – Em caso de extinção, indisponibilidade, substituição oficial ou alteração metodológica substancial dos índices INCC ou IGP-M, inclusive em decorrência de mudanças estruturais introduzidas pela Reforma Tributária (EC 132/2023 e legislação complementar) que comprometam sua capacidade de refletir adequadamente, respectivamente, os custos da construção civil e a variação geral de preços, tais índices serão automaticamente substituídos por outro índice oficial que melhor represente a evolução dos custos de construção, no caso do INCC e a variação de preços ao consumidor, no caso do IGP-M, preservando-se a equivalência econômico-financeira originalmente pactuada entre as Partes.

== 5 – PENALIDADES PELO ATRASO NO PAGAMENTO (MORA DO COMPRADOR)

5.1 – O atraso no pagamento de qualquer parcela do preço sujeitará o COMPRADOR à multa de 2% (dois por cento), mais juros de mora equivalente a 1,0% a.m. (um por cento ao mês), calculados pro rata die desde a data do vencimento até a data da efetiva liquidação da dívida, encargos esses que incidirão sobre o valor atualizado monetariamente, de acordo com os critérios previstos no item 4.3 deste Quadro Resumo.

5.2 – Permanecendo o atraso, o COMPRADOR será notificado para purgar a mora no prazo de 15 (quinze) dias, mediante pagamento do valor principal atualizado e dos encargos previstos no item 5.1 acima. Não havendo a purgação dentro do prazo estipulado, ficará a VENDEDORA autorizada a proceder à cobrança extrajudicial ou judicial do débito, hipótese em que incidirão honorários de cobrança no percentual de 10% (dez por cento) sobre o valor devido, sem prejuízo da possibilidade de inscrição do nome do COMPRADOR nos cadastros de proteção ao crédito. Persistindo o inadimplemento após o referido prazo, a VENDEDORA poderá, a seu exclusivo critério, declarar o vencimento antecipado das parcelas vincendas ou considerar o presente contrato resolvido, na forma do item 6.

== 6 – RESOLUÇÃO CONTRATUAL POR INADIMPLEMENTO

6.1 – Nos termos do Art. 35-A, inciso VI e Art. 67-A da Lei nº 4.591/64, em caso do desfazimento do presente contrato, em decorrência de distrato ou resolução por inadimplemento de qualquer obrigação de responsabilidade do COMPRADOR, este se declara ciente e concorda que fará jus à restituição das quantias pagas à VENDEDORA pelo preço de aquisição da unidade, exceto as quantias referentes a juros moratórios ou multas moratórias pagos pelo COMPRADOR, até a data da resolução do contrato, atualizadas com base nos índices estabelecidos para a correção monetária das parcelas do preço de aquisição, definidos neste Quadro Resumo, descontados cumulativamente os seguintes valores:

> (a) a integralidade do valor pago a título de comissão de corretagem.

> (b) multa em razão de distrato ou resolução do contrato por inadimplemento do adquirente no percentual de 50% (cinquenta por cento) das quantias efetivamente pagas pelo COMPRADOR do preço de aquisição da unidade autônoma.

6.2 – Caso a unidade autônoma já tenha sido disponibilizada ao COMPRADOR, além do disposto no item 6.1 acima, o COMPRADOR ainda será o único e exclusivo responsável pelo pagamento dos seguintes valores:

> (a) impostos e taxas incidentes sobre a respectiva unidade, tais como: IPTU, despesas ordinárias e extraordinárias de condomínio, dentre outras.

> (b) 0,5% (zero virgula cinco por cento) ao mês, calculado sobre o preço total do presente contrato, previsto no item 4 acima, devidamente atualizado nos termos do item 4.3 deste Quadro Resumo, calculado pro rata die, incidente desde a data da disponibilização da unidade autônoma ao COMPRADOR.

> (c) demais encargos e despesas incidentes sobre a unidade autônoma, quais sejam: despesas de consumo de gás, água e energia elétrica, se houver, bem como todas as despesas necessárias ao retorno da unidade autônoma ao padrão do empreendimento, caso o COMPRADOR tenha solicitado e/ou efetivado alguma personalização/modificação na respectiva unidade autônoma, diferentemente do previsto no memorial descritivo do empreendimento.

6.3 – Na resolução contratual, caso o COMPRADOR não efetue o pagamento dos valores descritos no item 6.2 acima, a VENDEDORA fica autorizada a descontar a totalidade dos valores devidos pelo COMPRADOR (item 6.2) das quantias que lhe serão restituídas em razão do desfazimento do contrato, sem prejuízo das deduções previstas no item 6.1.

6.4 - A VENDEDORA fará a restituição das quantias pagas pelo COMPRADOR, corrigidas monetariamente e com as deduções previstas nos itens 6.1 acima e, ainda, 6.2, se aplicável, no prazo máximo de 30 (trinta) dias após a emissão do habite-se do empreendimento, podendo realizar a restituição mediante depósito em conta corrente indicada no termo de rescisão ou, ainda, em conta judicial. Caso ocorra a revenda da unidade autônoma à terceiro, antes da emissão do habite-se, as quantias devidas ao COMPRADOR serão restituídas pela VENDEDORA, corrigidas conforme índices previstos neste instrumento e após as competentes deduções previstas, em até 30 (trinta) dias contados da assinatura do novo contrato de compra e venda da unidade objeto deste contrato com o novo adquirente.

6.5 – Se o COMPRADOR encontrar terceiro interessado em adquirir a unidade autônoma objeto deste contrato, deverá enviar comunicação escrita à VENDEDORA nesse sentido, acompanhada dos documentos do terceiro (documentos pessoais, IR, comprovação de renda e demais documentos eventualmente solicitados pela VENDEDORA) para fins de aprovação do cadastro, idoneidade e da capacidade financeira e econômica do terceiro interessado, a qual ocorrerá segundo os critérios e procedimentos adotados pela VENDEDORA, ao seu exclusivo juízo.

6.5.1 – Ocorrendo a concordância expressa pela VENDEDORA com a sub-rogação ao terceiro interessado, o COMPRADOR ficará isento do pagamento da multa prevista nas letras “b” ou “c”, conforme aplicável, do item 6.1 acima.

## Aceitação expressa do COMPRADOR quanto aos termos desta Cláusula 6:

@aceite_compradores

== 7 - DIREITO DE ARREPENDIMENTO

7.1 – Nos termos do Art. 35-A, inciso VIII e Art. 67-A, § 10, 11 e 12 da Lei nº 4.591/64, desde que o presente negócio tenha sido celebrado em estandes de vendas e fora da sede da VENDEDORA, é concedido ao COMPRADOR a possibilidade do exercício do direito de arrependimento, durante o prazo improrrogável de 07 (sete) dias corridos, contados da assinatura deste instrumento pelo COMPRADOR, com a devolução de todos os valores eventualmente pagos referente ao preço de aquisição da unidade autônoma e da comissão de corretagem, caso tenha sido paga pelo COMPRADOR.

7.2 – Para exercício do direito de arrependimento, o COMPRADOR deverá encaminhar comunicado escrito à VENDEDORA, de forma tempestiva, através de carta registrada, com aviso de recebimento, para o endereço constante neste Quadro Resumo, considerando-se a data da postagem como a data do exercício do direito de arrependimento. Neste caso, a VENDEDORA restituirá os valores até então pagos pelo COMPRADOR referente ao preço da unidade e de corretagem (caso tenha sido paga pelo COMPRADOR), no prazo máximo de 30 (trinta) dias contados do recebimento da comunicação acerca do exercício do direito de arrependimento.

7.3 – Para que a VENDEDORA possa dar início aos procedimentos de desfazimento do contrato e recolocação da unidade autônoma à venda, fica ajustado que o COMPRADOR também deverá encaminhar cópia do comunicado e do comprovante de postagem para o seguinte e-mail: {{empreendimento.email_arrependimento}}. Encaminhada a comunicação pelo COMPRADOR, a unidade autônoma objeto deste instrumento ficará automaticamente liberada para que a VENDEDORA realize nova venda, independente de assinatura de distrato entre as partes.

7.4 – Após o prazo de 07 (sete) dias mencionado no item 5.1, acima, sem que tenha sido exercido o direito de arrependimento por parte do COMPRADOR, será observada a irretratabilidade do presente instrumento.

== 8 – PRAZO DE CONCLUSÃO DAS OBRAS E CONSEQUÊNCIAS EM CASO DE ATRASO

8.1 – Prazo previsto para conclusão das obras do empreendimento: {{empreendimento.prazo_obra}}, com tolerância de mais 180 (cento e oitenta) dias, ressalvada hipóteses de força maior, caso fortuito ou origens alheias à vontade da VENDEDORA.

8.2 - A conclusão das obras do empreendimento, bem como da unidade autônoma objeto deste contrato, será caracterizada pela expedição, pelo Poder Público, do Certificado de Conclusão de Obras (“Termo de Habite-se”) do empreendimento.

8.3 - A utilização do prazo de tolerância é prerrogativa da VENDEDORA, sendo dispensada sua justificação, não incidindo em desfavor da VENDEDORA qualquer penalidade moratória ou compensatória.

8.4 – Se o prazo estimado para conclusão das obras do empreendimento, acrescido do prazo de tolerância de 180 (cento e oitenta) dias, for extrapolado, salvo pelos motivos previstos nas Normas Contratuais, e desde que o COMPRADOR até então não tenha inadimplido em nenhuma de suas obrigações aqui previstas por prazo superior a 30 (trinta) dias, ficará facultado ao COMPRADOR, em atenção ao artigo 43-A e seus parágrafos da Lei nº 4.591/64, optar por uma das seguintes alternativas, as quais, em hipótese alguma, poderão ser aplicadas cumulativamente:

> a) Resolver o presente contrato, até a data de expedição do habite-se do empreendimento, com a restituição pela VENDEDORA, no prazo de até 60 (sessenta) dias úteis contados da resolução, da integralidade de todos os valores pagos pelo COMPRADOR, acrescidos de multa indenizatória correspondente a 2% (dois por cento) sobre as quantias pagas do preço pelo COMPRADOR; ou

> b) Manter o presente contrato para aquisição da unidade autônoma, hipótese em que a VENDEDORA deverá pagar ao COMPRADOR, caso este esteja adimplente com suas obrigações contratuais, por ocasião da entrega da unidade autônoma, multa moratória e compensatória no percentual de 1% (um por cento) do valor corrigido efetivamente pago pelo COMPRADOR à VENDEDORA, para cada mês de atraso, pro rata die. A multa ora estabelecida será devida somente ao final do prazo de tolerância até a emissão do Habite-se do empreendimento.

8.5 – Na hipótese prevista na letra “a” do item 8.4 acima, o COMPRADOR deverá, até a data de emissão do Habite-se do empreendimento, enviar notificação escrita, por meio de carta registrada, com aviso de recebimento, à VENDEDORA, comunicando sua intenção de resolver o presente contrato. Caso o COMPRADOR não envie o comunicado até a data de expedição do Habite-se, ocorrerá a manutenção do presente contrato, aplicando-se, neste caso, a letra “b” do item 8.4 acima.

8.6 - Os valores das penalidades serão disponibilizados ao COMPRADOR, a critério da VENDEDORA, mediante depósito em conta corrente de titularidade do COMPRADOR ou no caso da letra “b” do item 8.4 acima, com compensação no eventual saldo do preço da unidade autônoma ainda pendente de pagamento, quando da assinatura do instrumento definitivo de venda e compra da unidade autônoma.

8.7 - Para fins de definição do critério base para aplicação das cláusulas penais do item 8.4 acima, fica estabelecido que será considerado apenas o valor do principal corrigido, excluídos juros ou multas moratórias eventualmente pagas pelo COMPRADOR.

8.8 - Com a quitação das penalidades previstas no item 8.4 acima, nada mais será devido pela VENDEDORA em favor do COMPRADOR a qualquer título, em razão de ter sido extrapolado o prazo de entrega de obras do empreendimento.

8.9 - O COMPRADOR tem ciência de que o prazo de conclusão das obras previsto no item 8.1 acima, caracterizado pela emissão do habite-se do empreendimento, não se confunde com a data de realização da assembleia de instalação do condomínio, com a data de disponibilização da unidade autônoma ou com a data de entrega das chaves da unidade autônoma ao COMPRADOR, que se dará na forma prevista nas Normas Contratuais.

== 9– INTERMEDIAÇÃO IMOBILIÁRIA

9.1 - O COMPRADOR está ciente que a comercialização da unidade autônoma é realizada por empresa de vendas de imóveis e/ou consultores imobiliários autônomos, devidamente inscritos no Conselho Regional de Corretores de Imóveis (CRECI) e se aperfeiçoou com a aproximação das partes e celebração do presente instrumento. O COMPRADOR declara que as informações quanto à intermediação imobiliária do negócio foram realizadas satisfatoriamente, com correção e transparência, nada tendo a reclamar.

9.2 - O COMPRADOR concorda que, em caso de resolução, distrato ou desistência do presente contrato, os valores pagos a título de comissão de corretagem não serão objeto de devolução ao COMPRADOR, exceto em caso do exercício do direito de arrependimento, nos termos do item “5” deste Quadro Resumo.

@comissao_quadro

== 10 – CONDIÇÕES GERAIS

10.1 – Para a construção do empreendimento, a VENDEDORA poderá obter financiamento bancário, com o que o COMPRADOR está ciente e concorda plenamente, caso em que será conferido ao agente financiador da obra garantia real sobre o terreno e todas as benfeitorias e acessões sobre ele erigidas, incluindo-se as unidades autônomas do empreendimento, cuja quitação será de exclusiva responsabilidade da VENDEDORA. Além disso, a VENDEDORA também poderá caucionar ou ceder fiduciariamente, em favor do mesmo agente financeiro, os créditos decorrentes das alienações das unidades autônomas, em garantia ao referido financiamento.

10.2 - O COMPRADOR somente receberá a posse da unidade objeto deste contrato após atender todos os requisitos descritos no item 5.1 das Normas Contratuais.

10.3 – O COMPRADOR tomou conhecimento de todas as características da unidade autônoma, das vagas de garagem e escaninho (se houver), por meio de plantas, especificações do memorial descritivo deste contrato, concordando com as localizações e tamanhos.

10.4 - A unidade decorada do stand de vendas é tão somente um modelo de personalização e decoração, sendo que a unidade objeto deste contrato será entregue de acordo com as especificações do memorial descritivo, e não de acordo com o apartamento decorado.

10.5 – Este instrumento é composto de Quadro Resumo e Normas Contratuais. O COMPRADOR declara ter sido esclarecido em relação a todas as condições contratuais, não tendo qualquer dúvida e/ou alteração a solicitar, aceitando todas as cláusulas e condições deste instrumento.

== 11 – DA TRIBUTAÇÃO E REFORMA TRIBUTÁRIA

11.1 – O COMPRADOR declara ciência de que o sistema tributário poderá sofrer alterações em razão da Reforma Tributária, inclusive com a criação, modificação, unificação ou extinção de tributos que incidam sobre esta operação ou sobre os atos necessários à sua formalização.

11.2 – Quaisquer tributos, taxas, contribuições ou encargos fiscais, atuais ou futuros, relacionados à aquisição da unidade, ao registro deste contrato ou à realização dos atos necessários à transferência da propriedade serão de responsabilidade exclusiva do COMPRADOR, salvo se a legislação atribuir expressamente responsabilidade diversa.

11.3 – O preço pactuado neste instrumento não será revisto, reduzido ou recomposto em razão de alterações tributárias que venham a ocorrer após a assinatura deste contrato.

11.4 – Nos casos em que o pagamento devido à VENDEDORA ocorrer de forma separada, uma parcela correspondente ao valor principal e outra destinada ao recolhimento de tributos exigidos para a formalização da operação, a obrigação do COMPRADOR não será considerada quitada enquanto o tributo correspondente não for integralmente pago. Essa previsão aplica-se exclusivamente aos tributos cuja quitação constitua condição legal para a lavratura, registro ou efetivação da transmissão da unidade.

== 12 – PROTEÇÃO DE DADOS PESSOAIS

12.1 - A VENDEDORA se compromete a tratar os dados pessoais do COMPRADOR, única e exclusivamente para cumprir com a finalidade a que se destina nos termos aqui estabelecidos, observada toda a legislação aplicável sobre segurança da informação, privacidade e proteção de dados, inclusive, mas não se limitando à Lei nº 13.709/2018 (Lei Geral de Proteção de Dados) e demais disposições, regulamentações e interpretações que venham a ser publicadas ou pacificadas por quaisquer autoridades legais.

== 132 – DO FORO

13.1 - As partes elegem o foro do imóvel, que será o único competente para dirimir dúvidas e/ou quaisquer questões decorrentes deste contrato, renunciando, desde já, a qualquer outro, por mais privilegiado que seja.

== 14 – DA ASSINATURA ELETRÔNICA

14.1 - As Partes ajustam que as assinaturas do presente instrumento poderão ser realizadas por meio de ferramenta de assinatura digital, reconhecendo, por todos que o assinam, de forma irrevogável e irretratável, como verdadeiras, prova documental e título executivo extrajudicial, para todos os efeitos.

Assim, por estarem justos e contratados, assinam o presente, juntamente com 02 (duas) testemunhas, emitido em duas vias de igual teor.

@local_data

@assinaturas_finais

~ (Página de assinaturas do Quadro Resumo do Compromisso de venda e compra de unidade autônoma do empreendimento {{empreendimento.nome}})`;
