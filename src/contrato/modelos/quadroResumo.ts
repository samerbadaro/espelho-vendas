// Quadro Resumo — minuta r02 do jurídico do Duo Haus (24-25/11/2026), com os dados da vendedora,
// da incorporadora e do empreendimento trocados por campos do cadastro "Dados para contrato".
// Marcação: "= " título, "== " seção, "~ " nota em itálico, "## " parágrafo em negrito,
// "> " alínea recuada, "@bloco" bloco montado pelo sistema, {{campo}} dado do cadastro.
// Diferenças do .docx: qualificação em quadro (@partes), item 9.3 só com a alternativa a), linhas
// "COMPRADOR 1/2" dos aceites viram as assinaturas dos compradores (@aceite_compradores) e o prazo
// da obra sai do campo empreendimento.prazo_obra.
export const QUADRO_RESUMO = `= COMPROMISSO DE VENDA E COMPRA DE UNIDADE AUTÔNOMA DO EMPREENDIMENTO {{empreendimento.nome}}

= QUADRO RESUMO

== 1 – PARTES

> a) Na condição de promitente VENDEDORA: {{vendedora.razao_social}}, pessoa jurídica de direito privado, inscrita no CNPJ nº {{vendedora.cnpj}}, com sede na {{vendedora.endereco}}; e, na qualidade de incorporadora, {{incorporadora.razao_social}}, pessoa jurídica de direito privado, inscrita no CNPJ nº {{incorporadora.cnpj}}, com sede na {{incorporadora.endereco}}.

> b) Na condição de promissário COMPRADOR (independentemente do número):

@partes

== 2 – EMPREENDIMENTO

2.1 – Este contrato tem por objeto a aquisição, por parte do COMPRADOR, da unidade autônoma indicada no item “3” abaixo, do empreendimento {{empreendimento.nome}}, localizado na cidade de {{empreendimento.cidade}}, com Memorial de Incorporação devidamente registrado sob o nº {{empreendimento.registro_incorporacao}} da matrícula nº {{empreendimento.matricula}} do {{empreendimento.cartorio}}.

2.2 – O empreendimento foi submetido pela VENDEDORA ao regime do patrimônio de afetação, devidamente averbado na matrícula do imóvel.

== 3 – UNIDADE AUTÔNOMA

@unidade_quadro

3.1 – A referida unidade terá direito de uso de 01 (uma) vaga de uso rotativo – vaga não exclusiva – dependente da ocupação. A vaga não constitui unidade autônoma, não possui matrícula nem área privativa próprias, não é demarcada para uso exclusivo da unidade e não pode ser alienada, locada ou cedida separadamente desta, nos termos do item 1.4 das Normas Contratuais.

== 4 – PREÇO

@pagamento_quadro

4.2 – A responsabilidade pela obtenção do financiamento bancário competirá exclusivamente ao COMPRADOR, sem qualquer responsabilidade da VENDEDORA, inclusive no que se refere à obtenção dos documentos exigidos pela instituição financeira. O não pagamento de qualquer das parcelas descritas no item 4.1 acima, até a data de seus respectivos vencimentos, colocará o COMPRADOR em mora, sujeitando-o às penalidades previstas nas Normas Contratuais.

## 4.3 – CORREÇÃO MONETÁRIA E INCIDÊNCIA DE JUROS

4.3.1 – As parcelas do preço serão corrigidas da seguinte forma:

> a) as parcelas serão corrigidas monetariamente, até o mês de conclusão das obras, caracterizado pela expedição do habite-se, pela variação positiva do percentual mensal do INCC (Índice Nacional de Custos da Construção Civil), calculado pela FGV, tomando-se como base o índice de 02 (dois) meses anteriores ao da assinatura do contrato e como índice de correção o relativo ao segundo mês anterior àquele em que será realizado o pagamento da prestação;

> b) as parcelas que tiverem vencimento a partir do mês imediatamente posterior ao habite-se, bem como aquelas vencidas e eventualmente não pagas, que foram corrigidas monetariamente até então pela alínea “a” acima, passarão a ser corrigidas pela variação positiva do percentual mensal do IGP-M (Índice Geral de Preços – Mercado), calculado pela FGV, tomando-se como base o índice de 02 (dois) meses anteriores ao da expedição do habite-se e como índice de correção o relativo ao segundo mês anterior àquele em que será realizado o pagamento da prestação.

4.3.2 – Todas as parcelas do item 4.1, inclusive aquelas vencidas e não pagas, que tenham vencimento após a expedição do habite-se do empreendimento, terão incidência de juros de 1% (um por cento) ao mês, calculados pela Tabela Price.

4.3.3 – As parcelas das alíneas “b” e “c” do item 4.1 serão corrigidas monetariamente na forma prevista no item 4.3.1 acima.

4.3.4 – A data-base para efeito de correção das parcelas é {{contrato.data_base}}, independentemente da data de assinatura deste instrumento.

4.3.5 – O COMPRADOR terá livre escolha para obtenção do financiamento bancário na instituição financeira de sua preferência, porém está ciente de que algumas instituições financeiras vinculam a liberação de recursos para a quitação da unidade autônoma somente após a averbação da construção do empreendimento junto ao Cartório de Registro de Imóveis competente, que poderá ocorrer em até 180 (cento e oitenta) dias após a expedição do habite-se do empreendimento. Nesta hipótese, incidirão sobre o saldo devedor do contrato a correção monetária e juros de 1% (um por cento) ao mês, calculados pela Tabela Price, até a data da efetiva liberação dos recursos necessários para a quitação do saldo devedor junto à VENDEDORA.

4.3.6 – Em caso de extinção, indisponibilidade, substituição oficial ou alteração metodológica substancial dos índices INCC ou IGP-M, inclusive em decorrência de mudanças estruturais introduzidas pela Reforma Tributária (EC 132/2023 e legislação complementar) que comprometam sua capacidade de refletir adequadamente, respectivamente, os custos da construção civil e a variação geral de preços, tais índices serão automaticamente substituídos por outro índice oficial que melhor represente a evolução dos custos de construção, no caso do INCC, e a variação de preços ao consumidor, no caso do IGP-M, preservando-se a equivalência econômico-financeira originalmente pactuada entre as partes.

== 5 – PENALIDADES PELO ATRASO NO PAGAMENTO (MORA DO COMPRADOR)

5.1 – O atraso no pagamento de qualquer parcela do preço sujeitará o COMPRADOR à multa de 2% (dois por cento), mais juros de mora equivalentes a 1% (um por cento) ao mês, calculados pro rata die desde a data do vencimento até a data da efetiva liquidação da dívida, encargos esses que incidirão sobre o valor atualizado monetariamente, de acordo com os critérios previstos no item 4.3 deste Quadro Resumo.

5.2 – Permanecendo o atraso, o COMPRADOR será notificado para purgar a mora no prazo de 15 (quinze) dias, mediante pagamento do valor principal atualizado e dos encargos previstos no item 5.1 acima. Não havendo a purgação dentro do prazo estipulado, ficará a VENDEDORA autorizada a proceder à cobrança extrajudicial ou judicial do débito, hipótese em que incidirão honorários de cobrança no percentual de 10% (dez por cento) sobre o valor devido, sem prejuízo da possibilidade de inscrição do nome do COMPRADOR nos cadastros de proteção ao crédito. Persistindo o inadimplemento após o referido prazo, a VENDEDORA poderá, a seu exclusivo critério, declarar o vencimento antecipado das parcelas vincendas ou considerar o presente contrato resolvido, na forma do item 6.

== 6 – RESOLUÇÃO CONTRATUAL POR DISTRATO OU INADIMPLEMENTO – PENALIDADES

6.1 – Nos termos do art. 35-A, inciso VI, e do art. 67-A da Lei nº 4.591/64, em caso de desfazimento do presente contrato, em decorrência de distrato ou de resolução por inadimplemento de qualquer obrigação de responsabilidade do COMPRADOR, este se declara ciente e concorda que fará jus à restituição das quantias pagas à VENDEDORA pelo preço de aquisição da unidade, exceto as quantias referentes a juros moratórios ou multas moratórias pagos pelo COMPRADOR, até a data da resolução do contrato, atualizadas com base nos índices estabelecidos para a correção monetária das parcelas do preço de aquisição definidos neste Quadro Resumo, descontados cumulativamente os seguintes valores:

> a) a integralidade do valor pago a título de comissão de corretagem;

> b) multa em razão de distrato ou de resolução do contrato por inadimplemento do adquirente, no percentual de 50% (cinquenta por cento) das quantias efetivamente pagas pelo COMPRADOR do preço de aquisição da unidade autônoma, limite admitido pelo art. 67-A, § 5º, da Lei nº 4.591/64 por estar o empreendimento submetido ao regime do patrimônio de afetação (item 2.2).

6.2 – Caso a unidade autônoma já tenha sido disponibilizada ao COMPRADOR, além do disposto no item 6.1 acima, o COMPRADOR ainda será o único e exclusivo responsável pelo pagamento dos seguintes valores:

> a) impostos e taxas incidentes sobre a respectiva unidade, tais como IPTU e despesas ordinárias e extraordinárias de condomínio, dentre outras;

> b) 0,5% (zero vírgula cinco por cento) ao mês, calculado sobre o preço total do presente contrato, previsto no item 4 acima, devidamente atualizado nos termos do item 4.3 deste Quadro Resumo, calculado pro rata die, incidente desde a data da disponibilização da unidade autônoma ao COMPRADOR;

> c) demais encargos e despesas incidentes sobre a unidade autônoma, quais sejam: despesas de consumo de gás, água e energia elétrica, se houver, bem como todas as despesas necessárias ao retorno da unidade autônoma ao padrão do empreendimento, caso o COMPRADOR tenha solicitado e/ou efetivado alguma personalização ou modificação na respectiva unidade autônoma, diferentemente do previsto no memorial descritivo do empreendimento.

6.3 – Na resolução contratual, caso o COMPRADOR não efetue o pagamento dos valores descritos no item 6.2 acima, a VENDEDORA fica autorizada a descontar a totalidade dos valores devidos pelo COMPRADOR (item 6.2) das quantias que lhe serão restituídas em razão do desfazimento do contrato, sem prejuízo das deduções previstas no item 6.1.

6.4 – A VENDEDORA fará a restituição das quantias pagas pelo COMPRADOR, corrigidas monetariamente e com as deduções previstas no item 6.1 acima e, ainda, no item 6.2, se aplicável, no prazo máximo de 30 (trinta) dias após a emissão do habite-se do empreendimento, podendo realizar a restituição mediante depósito em conta corrente indicada no termo de rescisão ou, ainda, em conta judicial. Caso ocorra a revenda da unidade autônoma a terceiro antes da emissão do habite-se, as quantias devidas ao COMPRADOR serão restituídas pela VENDEDORA, corrigidas conforme os índices previstos neste instrumento e após as competentes deduções, em até 30 (trinta) dias contados da assinatura do novo contrato de compra e venda da unidade objeto deste contrato com o novo adquirente.

6.5 – Se o COMPRADOR encontrar terceiro interessado em adquirir a unidade autônoma objeto deste contrato, deverá enviar comunicação escrita à VENDEDORA nesse sentido, acompanhada dos documentos do terceiro (documentos pessoais, IR, comprovação de renda e demais documentos eventualmente solicitados pela VENDEDORA) para fins de aprovação do cadastro, da idoneidade e da capacidade financeira e econômica do terceiro interessado, a qual ocorrerá segundo os critérios e procedimentos adotados pela VENDEDORA, a seu exclusivo juízo.

6.5.1 – Ocorrendo a concordância expressa da VENDEDORA com a sub-rogação ao terceiro interessado, o COMPRADOR ficará isento do pagamento da multa prevista na alínea “b” do item 6.1 acima.

## Anuência prévia e específica do COMPRADOR quanto às consequências do desfazimento do contrato e às penalidades previstas nesta Cláusula 6 (art. 35-A, § 2º, da Lei nº 4.591/64):

@aceite_compradores

== 7 – DIREITO DE ARREPENDIMENTO

7.1 – Nos termos do art. 35-A, inciso VIII, e do art. 67-A, §§ 10, 11 e 12, da Lei nº 4.591/64, caso o presente negócio tenha sido celebrado em estande de vendas ou fora da sede da VENDEDORA, é concedida ao COMPRADOR a possibilidade do exercício do direito de arrependimento, durante o prazo improrrogável de 07 (sete) dias corridos, contados da assinatura deste instrumento pelo COMPRADOR, com a devolução de todos os valores eventualmente pagos referentes ao preço de aquisição da unidade autônoma e da comissão de corretagem, caso tenha sido paga pelo COMPRADOR.

7.2 – Para exercício do direito de arrependimento, o COMPRADOR deverá encaminhar comunicado escrito à VENDEDORA, de forma tempestiva, por meio de carta registrada, com aviso de recebimento, para o endereço constante neste Quadro Resumo, considerando-se a data da postagem como a data do exercício do direito de arrependimento. Neste caso, a VENDEDORA restituirá os valores até então pagos pelo COMPRADOR referentes ao preço da unidade e à corretagem (caso tenha sido paga pelo COMPRADOR), no prazo máximo de 30 (trinta) dias contados do recebimento da comunicação acerca do exercício do direito de arrependimento.

7.3 – Para que a VENDEDORA possa dar início aos procedimentos de desfazimento do contrato e de recolocação da unidade autônoma à venda, fica ajustado que o COMPRADOR também deverá encaminhar cópia do comunicado e do comprovante de postagem para o seguinte e-mail: {{empreendimento.email_arrependimento}}. Encaminhada a comunicação pelo COMPRADOR, a unidade autônoma objeto deste instrumento ficará automaticamente liberada para que a VENDEDORA realize nova venda, independentemente de assinatura de distrato entre as partes.

7.4 – Após o prazo de 07 (sete) dias mencionado no item 7.1 acima, sem que tenha sido exercido o direito de arrependimento por parte do COMPRADOR, será observada a irretratabilidade do presente instrumento.

## Ciência do COMPRADOR quanto ao direito de arrependimento previsto nesta Cláusula 7:

@aceite_compradores

== 8 – PRAZO DE CONCLUSÃO DAS OBRAS E CONSEQUÊNCIAS EM CASO DE ATRASO

8.1 – Prazo previsto para conclusão das obras do empreendimento: 46 (quarenta e seis) meses contados da data de lançamento do empreendimento, fixada em 05/12/2026, ou seja, {{empreendimento.prazo_obra}}, com tolerância de mais 180 (cento e oitenta) dias, ressalvadas as hipóteses de força maior, caso fortuito ou origens alheias à vontade da VENDEDORA.

8.2 – A conclusão das obras do empreendimento, bem como da unidade autônoma objeto deste contrato, será caracterizada pela expedição, pelo Poder Público, do Certificado de Conclusão de Obras (“Termo de Habite-se”) do empreendimento.

8.3 – A utilização do prazo de tolerância é prerrogativa da VENDEDORA, sendo dispensada sua justificação, não incidindo em desfavor da VENDEDORA qualquer penalidade moratória ou compensatória.

8.4 – Se o prazo estimado para conclusão das obras do empreendimento, acrescido do prazo de tolerância de 180 (cento e oitenta) dias, for extrapolado, salvo pelos motivos previstos nas Normas Contratuais, e desde que o COMPRADOR até então não tenha inadimplido nenhuma de suas obrigações aqui previstas por prazo superior a 30 (trinta) dias, ficará facultado ao COMPRADOR, em atenção ao art. 43-A e seus parágrafos da Lei nº 4.591/64, optar por uma das seguintes alternativas, as quais, em hipótese alguma, poderão ser aplicadas cumulativamente:

> a) resolver o presente contrato, até a data de expedição do habite-se do empreendimento, com a restituição pela VENDEDORA, no prazo de até 60 (sessenta) dias corridos contados da resolução, da integralidade de todos os valores pagos pelo COMPRADOR, acrescidos de multa indenizatória correspondente a 2% (dois por cento) sobre as quantias pagas do preço pelo COMPRADOR; ou

> b) manter o presente contrato para aquisição da unidade autônoma, hipótese em que a VENDEDORA deverá pagar ao COMPRADOR, caso este esteja adimplente com suas obrigações contratuais, por ocasião da entrega da unidade autônoma, multa moratória e compensatória no percentual de 1% (um por cento) do valor corrigido efetivamente pago pelo COMPRADOR à VENDEDORA, para cada mês de atraso, pro rata die. A multa ora estabelecida será devida somente a partir do final do prazo de tolerância até a emissão do habite-se do empreendimento.

8.5 – Na hipótese prevista na alínea “a” do item 8.4 acima, o COMPRADOR deverá, até a data de emissão do habite-se do empreendimento, enviar notificação escrita, por meio de carta registrada, com aviso de recebimento, à VENDEDORA, comunicando sua intenção de resolver o presente contrato. Caso o COMPRADOR não envie o comunicado até a data de expedição do habite-se, ocorrerá a manutenção do presente contrato, aplicando-se, neste caso, a alínea “b” do item 8.4 acima.

8.6 – Os valores das penalidades serão disponibilizados ao COMPRADOR, a critério da VENDEDORA, mediante depósito em conta corrente de titularidade do COMPRADOR ou, no caso da alínea “b” do item 8.4 acima, por compensação com o eventual saldo do preço da unidade autônoma ainda pendente de pagamento, quando da assinatura do instrumento definitivo de venda e compra da unidade autônoma.

8.7 – Para fins de definição do critério-base para aplicação das cláusulas penais do item 8.4 acima, fica estabelecido que será considerado apenas o valor do principal corrigido, excluídos juros ou multas moratórias eventualmente pagos pelo COMPRADOR.

8.8 – Com a quitação das penalidades previstas no item 8.4 acima, nada mais será devido pela VENDEDORA em favor do COMPRADOR, a qualquer título, em razão de ter sido extrapolado o prazo de entrega das obras do empreendimento.

8.9 – O COMPRADOR tem ciência de que o prazo de conclusão das obras previsto no item 8.1 acima, caracterizado pela emissão do habite-se do empreendimento, não se confunde com a data de realização da assembleia de instalação do condomínio, com a data de disponibilização da unidade autônoma ou com a data de entrega das chaves da unidade autônoma ao COMPRADOR, que se dará na forma prevista nas Normas Contratuais.

== 9 – INTERMEDIAÇÃO IMOBILIÁRIA

9.1 – O COMPRADOR está ciente de que a comercialização da unidade autônoma é realizada por empresa de vendas de imóveis e/ou consultores imobiliários autônomos, devidamente inscritos no Conselho Regional de Corretores de Imóveis (CRECI), e se aperfeiçoou com a aproximação das partes e a celebração do presente instrumento. O COMPRADOR declara que as informações quanto à intermediação imobiliária do negócio foram prestadas satisfatoriamente, com correção e transparência, nada tendo a reclamar.

9.2 – O COMPRADOR concorda que, em caso de resolução, distrato ou desistência do presente contrato, os valores pagos a título de comissão de corretagem não serão objeto de devolução ao COMPRADOR, exceto em caso de exercício do direito de arrependimento, nos termos do item “7” deste Quadro Resumo.

@comissao_quadro

== 10 – CONDIÇÕES GERAIS

10.1 – Para a construção do empreendimento, a VENDEDORA poderá obter financiamento bancário, com o que o COMPRADOR está ciente e concorda plenamente, caso em que será conferida ao agente financiador da obra garantia real sobre o terreno e todas as benfeitorias e acessões sobre ele erigidas, incluindo-se as unidades autônomas do empreendimento, cuja quitação será de exclusiva responsabilidade da VENDEDORA. Além disso, a VENDEDORA também poderá caucionar ou ceder fiduciariamente, em favor do mesmo agente financeiro, os créditos decorrentes das alienações das unidades autônomas, em garantia ao referido financiamento.

10.2 – O COMPRADOR somente receberá a posse da unidade objeto deste contrato após atender a todos os requisitos descritos no item 5.1 das Normas Contratuais.

10.3 – O COMPRADOR tomou conhecimento de todas as características da unidade autônoma e do escaninho (se houver), por meio de plantas e especificações do memorial descritivo deste contrato, concordando com suas localizações e tamanhos, e declara ciência de que a vaga de garagem é de uso rotativo, não exclusiva e dependente da ocupação, nos termos do item 3.1 acima.

10.4 – A unidade decorada do stand de vendas é tão somente um modelo de personalização e decoração, sendo que a unidade objeto deste contrato será entregue de acordo com as especificações do memorial descritivo, e não de acordo com o apartamento decorado.

10.5 – Este instrumento é composto de Quadro Resumo e Normas Contratuais. O COMPRADOR declara ter sido esclarecido em relação a todas as condições contratuais, não tendo qualquer dúvida e/ou alteração a solicitar, aceitando todas as cláusulas e condições deste instrumento.

10.6 – DECLARAÇÕES ESPECÍFICAS DO COMPRADOR: O COMPRADOR declara estar ciente e de acordo, de forma específica, de que:

> a) a VENDEDORA poderá alterar o projeto, a planta das unidades autônomas e a fachada do empreendimento, independentemente de consulta ou prévia aprovação do COMPRADOR, nas hipóteses previstas no item 6.2 das Normas Contratuais;

> b) eventuais diferenças de até 5% (cinco por cento), para mais ou para menos, nas medidas do terreno, nas áreas da unidade autônoma, nas áreas comuns e na fração ideal não darão direito a qualquer compensação, abatimento de preço ou indenização, nos termos dos itens 2.16 e 6.3 das Normas Contratuais;

> c) todas as imagens, perspectivas, maquetes, folhetos e sugestões de acabamento e decoração apresentados na divulgação do empreendimento são meramente ilustrativos, prevalecendo sempre o memorial descritivo, nos termos do item 12.5, alínea “c”, das Normas Contratuais;

> d) a unidade adquirida tem direito ao uso de 01 (uma) vaga de garagem rotativa, não exclusiva e dependente da ocupação, não havendo vaga determinada ou garantida para a unidade, nos termos do item 3.1 acima e do item 1.4 das Normas Contratuais.

## Ciência e concordância específica do COMPRADOR quanto ao item 10.6:

@aceite_compradores

== 11 – DA TRIBUTAÇÃO E DA REFORMA TRIBUTÁRIA

11.1 – O COMPRADOR declara ciência de que o sistema tributário poderá sofrer alterações em razão da Reforma Tributária, inclusive com a criação, modificação, unificação ou extinção de tributos que incidam sobre esta operação ou sobre os atos necessários à sua formalização.

11.2 – Quaisquer tributos, taxas, contribuições ou encargos fiscais, atuais ou futuros, relacionados à aquisição da unidade, ao registro deste contrato ou à realização dos atos necessários à transferência da propriedade serão de responsabilidade exclusiva do COMPRADOR, salvo se a legislação atribuir expressamente responsabilidade diversa.

11.3 – O preço pactuado neste instrumento não será revisto, reduzido ou recomposto em razão de alterações tributárias que venham a ocorrer após a assinatura deste contrato.

11.4 – Nos casos em que o pagamento devido à VENDEDORA ocorrer de forma separada, uma parcela correspondente ao valor principal e outra destinada ao recolhimento de tributos exigidos para a formalização da operação, a obrigação do COMPRADOR não será considerada quitada enquanto o tributo correspondente não for integralmente pago. Essa previsão aplica-se exclusivamente aos tributos cuja quitação constitua condição legal para a lavratura, o registro ou a efetivação da transmissão da unidade.

== 12 – DA PROTEÇÃO DE DADOS PESSOAIS

12.1 – A VENDEDORA se compromete a tratar os dados pessoais do COMPRADOR única e exclusivamente para cumprir a finalidade a que se destinam, nos termos aqui estabelecidos, observada toda a legislação aplicável sobre segurança da informação, privacidade e proteção de dados, inclusive, mas não se limitando à Lei nº 13.709/2018 (Lei Geral de Proteção de Dados) e demais disposições, regulamentações e interpretações que venham a ser publicadas ou pacificadas por quaisquer autoridades legais.

== 13 – DO FORO

13.1 – As partes elegem o foro da comarca de situação do imóvel, que será o único competente para dirimir dúvidas e/ou quaisquer questões decorrentes deste contrato, renunciando, desde já, a qualquer outro, por mais privilegiado que seja.

== 14 – DA ASSINATURA ELETRÔNICA

14.1 – As partes ajustam que as assinaturas do presente instrumento poderão ser realizadas por meio de ferramenta de assinatura digital, reconhecendo, por todos que o assinam, de forma irrevogável e irretratável, como verdadeiras, prova documental e título executivo extrajudicial, para todos os efeitos.

Assim, por estarem justos e contratados, assinam o presente, juntamente com 02 (duas) testemunhas, em duas vias de igual teor.

@local_data

@assinaturas_finais

~ (Página de assinaturas do Quadro Resumo do Compromisso de venda e compra de unidade autônoma do empreendimento {{empreendimento.nome}})`;
