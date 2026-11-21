// Quadro Resumo — modelo de teste (estrutura da minuta enviada, com dados da vendedora e do
// empreendimento trocados por campos do cadastro "Dados para contrato").
// Marcação: "= " título, "== " seção, "~ " referência legal, "## " parágrafo em negrito,
// "> " alínea recuada, "@bloco" bloco montado pelo sistema, {{campo}} dado do cadastro.
export const QUADRO_RESUMO = `= INSTRUMENTO PARTICULAR DE PROMESSA DE COMPRA E VENDA DE UNIDADE IMOBILIÁRIA EM CONSTRUÇÃO COM PARCELAMENTO DO PREÇO, GARANTIA DE PAGAMENTO E OUTRAS AVENÇAS

= QUADRO RESUMO

== 1 - DAS PARTES CONTRATANTES:

## 1.1. DA VENDEDORA

{{vendedora.razao_social}}, pessoa jurídica de direito privado, inscrita no CNPJ/MF nº {{vendedora.cnpj}}, com sede na {{vendedora.endereco}}, representada conforme contrato social registrado na {{vendedora.junta}} sob nº {{vendedora.registro}}, em {{vendedora.registro_data}}.

## 1.2. DO(S) COMPRADOR(ES)

@partes

== 2 - DO EMPREENDIMENTO:

~ (ARTIGO 35-A, INCISO XI, DA LEI Nº 4.591/1964, INCLUÍDO PELA LEI Nº 13.786/2018)

2.1. O presente contrato tem por objeto a aquisição, pelo(s) COMPRADOR(ES), da unidade autônoma relacionada no item “3” abaixo, do empreendimento denominado {{empreendimento.nome}}, localizado na {{empreendimento.endereco}}, {{empreendimento.descricao}}, tudo conforme memorial de incorporação, convenção de condomínio e demais documentos da incorporação imobiliária que integram a presente compra e venda, cuja observância é obrigatória pelo(s) COMPRADOR(ES).

2.2. O imóvel onde será construído o empreendimento procede da matrícula nº {{empreendimento.matricula}} do {{empreendimento.cartorio}}.

2.3. O memorial de incorporação do empreendimento foi registrado perante o {{empreendimento.cartorio}} sob nº {{empreendimento.registro_incorporacao}}, em {{empreendimento.registro_incorporacao_data}}.

2.4. O empreendimento em questão foi submetido pela VENDEDORA ao regime do patrimônio de afetação, o que foi devidamente registrado/averbado sob nº {{empreendimento.afetacao}} do {{empreendimento.cartorio}}, em {{empreendimento.afetacao_data}}.

2.5. {{empreendimento.subcondominios}}

== 3. DA UNIDADE AUTÔNOMA DE APARTAMENTO

3.1. A unidade autônoma de apartamento objeto deste contrato possui as nomenclaturas, características e metragens conforme disposto no quadro abaixo:

@quadro_unidade

3.2. A obrigação de entrega da unidade autônoma será “ad corpus”, servindo a metragem da área privativa apenas como referência, a qual pode sofrer variações de 5% (cinco por cento), a maior ou a menor.

3.3. A área privativa do apartamento inclui também a área correspondente às paredes externas e internas.

3.4. A disposição das vagas de garagem poderá ser alterada por motivos de ordem técnica ou decisão emanada do poder público e/ou concessionárias de serviço público.

3.5. Na referência às áreas da unidade autônoma foi adotado o critério de “área real”, constante do quadro II da NBR 12.721.

3.6. A unidade autônoma, ora adquirida, tem destinação exclusiva residencial.

3.7. O(A)(s) COMPRADOR(ES) declara(m) estar ciente(s) de que o empreendimento possui vagas de garagem integrantes das áreas comuns, destinadas ao uso comum ou ao uso exclusivo do Condomínio, as quais não integram a unidade autônoma objeto deste contrato, não conferindo qualquer direito de propriedade, posse, uso exclusivo ou preferência ao(à)(s) COMPRADOR(ES), salvo quando expressamente previsto na Convenção de Condomínio. Declara(m), ainda, o(à)(s) COMPRADOR(ES) ter(em) ciência de que as vagas destinadas a visitantes, prestadores de serviços ou quaisquer outras classificadas como áreas comuns não integram a presente aquisição e sua utilização observará exclusivamente as regras estabelecidas na Convenção de Condomínio, no Regimento Interno e nas deliberações da administração condominial.

3.8. O(A)(s) COMPRADOR(ES) declara(m) estar ciente(s) de que o empreendimento dispõe de vagas destinadas ao abastecimento/recarga de veículos elétricos, as quais integram as áreas comuns, não constituindo vagas privativas vinculadas à unidade autônoma objeto deste contrato. A utilização dessas vagas e da infraestrutura de recarga observará, exclusivamente, as disposições da Convenção de Condomínio, do Regimento Interno e das normas expedidas pela administração condominial, não conferindo ao(à)(s) COMPRADOR(ES) qualquer direito de uso exclusivo, reserva, preferência ou disponibilidade permanente.

== 4. DO PREÇO E DA FORMA DE PAGAMENTO

~ (ARTIGO 35-A, INCISOS I, II, IV E IX, DA LEI Nº 4.591/1964, INCLUÍDO PELA LEI Nº 13.786/2018)

@pagamento

== 5. DA INTERMEDIAÇÃO IMOBILIÁRIA

~ (ARTIGO 35-A, INCISO III, DA LEI Nº 4.591/1964, INCLUÍDO PELA LEI Nº 13.786/2018)

5.1. O(s) COMPRADOR(ES) declara(m) ter conhecimento de que a comercialização da unidade autônoma objeto deste contrato foi realizada por empresas de vendas de imóveis e/ou consultores imobiliários autônomos, devidamente inscritos no CRECI e se aperfeiçoou com a aproximação das partes e celebração do presente instrumento.

5.2. A comissão devida a tais profissionais, em razão do serviço prestado, foi paga pelo(s) COMPRADOR(ES) diretamente às empresas de venda de imóveis e/ou consultores imobiliários independentes, responsáveis pelo serviço de intermediação do presente negócio. Inobstante, para fins de cumprimento do artigo 35-A, inciso III, da Lei nº 4.591/1964, segundo informado pelo(s) COMPRADOR(ES), a comissão foi paga ao beneficiário abaixo, no seguinte valor:

@tabela_comissao

5.3. Todas as demais condições relativas à intermediação imobiliária estão dispostas na CLÁUSULA VIGÉSIMA PRIMEIRA das Normas Contratuais.

== 6. ATUALIZAÇÃO MONETÁRIA E INCIDÊNCIA DE JUROS

~ (ARTIGO 35-A, INCISOS V E VII, DA LEI Nº 4.591/1964, INCLUÍDO PELA LEI Nº 13.786/2018)

6.1. As parcelas do preço serão corrigidas monetariamente na forma abaixo e de acordo com estipulado nas Normas Contratuais, tendo como sistema de amortização a tabela price.

6.2. As parcelas indicadas e acordadas no item “4”, com exceção das ARRAS/SINAL, deste Quadro Resumo serão corrigidas monetariamente até o mês de conclusão das obras, caracterizado pela expedição do certificado de conclusão de obras (“Habite-se”), de acordo com a variação positiva do percentual mensal do {{empreendimento.indice_obra}}, tomando-se como base o índice de 02 (dois) meses anteriores ao da assinatura do contrato e como índice-correção o relativo ao segundo mês anterior àquele em que será realizado o pagamento da prestação.

> a) As parcelas vencíveis a partir do mês imediatamente posterior ao “Habite-se”, bem como aquelas vencidas e eventualmente não pagas, que foram corrigidas monetariamente até então, passarão a ser corrigidas de acordo com a variação positiva do percentual mensal do {{empreendimento.indice_pos_obra}}, tomando-se como base o índice de 02 (dois) meses anteriores ao mês da expedição do “Habite-se” e como índice-correção o relativo ao segundo mês anterior àquele em que será realizado o pagamento da prestação.

> b) Em atenção ao disposto no artigo 35-A, inciso VII, da Lei nº 4.591/1964, todas as parcelas acima indicadas e acordadas, bem como aquelas vencidas e eventualmente não pagas, que tenham vencimento após a expedição do “Habite-se”, estão sujeitas à incidência de juros de 1% (um por cento) ao mês, calculados pela tabela price.

== 7. PRAZO DE CONCLUSÃO DAS OBRAS E EFEITOS CONTRATUAIS NO CASO DE ATRASO

~ (ARTIGO 35-A, INCISO XII, DA LEI Nº 4.591/1964, INCLUÍDO PELA LEI Nº 13.786/2018)

7.1. As obras do empreendimento, bem como da unidade autônoma objeto deste contrato, tem seu prazo de término previsto para data de {{empreendimento.prazo_obra}}, com tolerância de até 180 (cento e oitenta) dias, ressalvadas as hipóteses de força maior, caso fortuito e/ou outras causas imprevisíveis e alheias à vontade da VENDEDORA. Fica entendido ainda que, ocorrendo caso fortuito, força maior, fato imprevisto ou imprevisível, seja no curso do prazo originário, seja no curso do prazo de tolerância, haverá suspensão do respectivo prazo, pelo período equivalente ao dos efeitos do evento.

7.2. A conclusão das obras do empreendimento, bem como da unidade autônoma objeto deste contrato, será caracterizada pela expedição do certificado de conclusão de obras (“Habite-se”) do empreendimento pelo Poder Público competente.

7.3. A utilização do prazo de tolerância de 180 (cento e oitenta) dias, previsto no item “7.1” acima, é prerrogativa da VENDEDORA, sendo dispensada sua justificação, não incidindo em desfavor da VENDEDORA qualquer penalidade moratória ou compensatória.

7.4. Caso o prazo estimado para conclusão das obras do empreendimento, acrescido do prazo de tolerância de 180 (cento e oitenta) dias, seja extrapolado, salvo pelos motivos previstos no item “4.3” das Normas Contratuais, ficará facultado ao(s) COMPRADOR(ES), em atenção ao disposto no artigo 43-A e seus parágrafos, da Lei nº 4.591/1964, optar por uma das seguintes alternativas, as quais, em hipótese alguma, poderão ser aplicadas cumulativamente:

> a) Resolver o presente contrato, até a data de expedição do “Habite-se” do empreendimento, com a restituição, pela VENDEDORA, no prazo de até 60 (sessenta) dias corridos, contados da resolução, da integralidade de todos os valores pagos pelo(s) COMPRADOR(ES), acrescidos de multa moratória e compensatória, no valor correspondente a 1% (um por cento) da quantia total paga a título de preço pelo(s) COMPRADOR(ES); ou

> b) Manter o presente contrato, hipótese em que a VENDEDORA deverá pagar ao(s) COMPRADOR(ES), caso este(s) esteja(m) adimplente(s) com suas obrigações contratuais, por ocasião da entrega da unidade autônoma, multa moratória e compensatória no valor correspondente a 1% (um por cento), calculado sobre o valor corrigido efetivamente pago à VENDEDORA, para cada mês de atraso, “pro rata die”. A multa ora estabelecida será devida somente ao final do prazo de tolerância e até a emissão do “Habite-se” do empreendimento.

7.5. Para a hipótese prevista na letra “a” do item “7.4” acima, o(s) COMPRADOR(ES) deverá(ão), até a data de emissão do “Habite-se” do empreendimento, enviar notificação escrita, por meio de carta registrada, com aviso de recebimento, à VENDEDORA, comunicando sua intenção de resolver o presente contrato. Caso o(s) COMPRADOR(ES) não envie(m) o comunicado até a data de expedição do “Habite-se”, ocorrerá a manutenção do presente contrato, aplicando-se o disposto na letra “b” do item “7.4” acima.

7.6. O valor da penalidade será disponibilizado ao(s) COMPRADOR(ES), a critério da VENDEDORA, mediante depósito em conta corrente de titularidade do(s) COMPRADOR(ES) ou, no caso da letra “b” do item “7.4” acima, a VENDEDORA poderá fazer a compensação no eventual saldo do preço da unidade autônoma ainda pendente de pagamento, quando da assinatura do instrumento definitivo de venda e compra da unidade autônoma.

7.7. Para fins de definição do critério base para aplicação das cláusulas penais do item “7.4” acima, fica estabelecido que será considerado apenas o valor do principal corrigido, excluídos eventuais juros ou multas moratórias pagas pelo(s) COMPRADOR(ES).

7.8. Com a quitação da penalidade aplicável previstas no item “7.4” acima, nada mais será devido pela VENDEDORA em favor do(s) COMPRADOR(ES), a qualquer título, em razão de ter sido extrapolado o prazo de entrega de obras do empreendimento, renunciando o(s) COMPRADOR(ES) qualquer questionamento ou pleito nesse sentido.

7.9. O(s) COMPRADOR(ES) têm ciência de que o prazo de conclusão das obras previsto no item “7.1” acima, caracterizado pela emissão do “Habite-se” do empreendimento, não se confunde com a data de realização da assembleia de instalação do condomínio, com a data de disponibilização da unidade autônoma ou com a data de entrega das chaves da unidade autônoma ao(s) COMPRADOR(ES), o que se dará na forma prevista na Cláusula Quarta, no item “4.1” das Normas Contratuais.

== 8. DA POSSE DA UNIDADE

O(s) COMPRADOR(ES) será(ão) imitido(as) na posse da unidade objeto do presente instrumento após atender, de forma cumulativa, todos os requisitos previstos na Cláusula Quarta das Normas Contratuais.

== 9. DO DIREITO DE ARREPENDIMENTO

~ (ARTIGO 35-A, INCISO VIII, DA LEI Nº 4.591/1964, INCLUÍDO PELA LEI Nº 13.786/2018)

9.1. Desde que o presente negócio jurídico tenha sido celebrado em stands de vendas e fora da sede ou fora do estabelecimento comercial da VENDEDORA, fica ressalvado ao(s) COMPRADOR(ES) a possibilidade do exercício do direito de arrependimento, durante o prazo improrrogável de 07 (sete) dias corridos, contados da assinatura deste contrato, com devolução de todos os valores eventualmente antecipados pelo(s) COMPRADOR(ES), com exceção da comissão de corretagem, que deverá ser requerida a sua devolução/restituição (se cabível) diretamente à imobiliária e/ou corretores que intermediaram o negócio, não tendo a VENDEDORA nenhuma responsabilidade nesse sentido.

9.2. O direito de arrependimento previsto no item “9.1” acima deverá ser exercido pelo(s) COMPRADOR(ES), por meio de carta registrada, com aviso de recebimento, sendo considerado como data para fins de contagem do prazo, o dia de postagem do documento, nos termos do artigo 67-A, §11, da Lei n° 4.591/1964. Atendido o prazo e a formalidade legal, a VENDEDORA nada lhe cobrará e promoverá a rescisão da proposta de compra e venda e/ou do contrato de promessa de compra e venda, bem como restituirá todos os valores antecipados pelo(s) COMPRADOR(ES), no prazo de 30 (trinta) dias, contados do recebimento da comunicação acerca do exercício do direito de arrependimento, com exceção da comissão de corretagem que deverá ser requerida a sua devolução/restituição (se cabível) diretamente à imobiliária e/ou corretores que intermediaram o negócio, observado o disposto nas Normas Contratuais.

9.3. Transcorrido o prazo de 07 (sete) dias sem que tenha sido regularmente exercido o direito de arrependimento por parte do(s) COMPRADOR(ES), será observada a irretratabilidade do contrato de incorporação imobiliária, conforme disposto no artigo 32, §2º da Lei nº 4.591/1964.

== 10. DA INADIMPLÊNCIA/MORA DO(S) COMPRADOR(ES)

10.1. DA INADIMPLÊNCIA/MORA: em qualquer momento do contrato em que ocorrer atraso no pagamento de quaisquer das parcelas do preço, independentemente de qualquer tipo de notificação ou comunicado, será cobrado do(s) COMPRADOR(ES), a título de encargos moratórios:

> a) multa no valor equivalente à 2% (dois por cento) do valor da parcela em atraso;

> b) juros de 1% (um por cento) ao mês, capitalizados mensalmente “pro rata die”;

> c) correção monetária pelo mesmo índice de reajuste da parcelas vigente à época e ajustado neste instrumento, até a data do efetivo pagamento; e

> d) honorários advocatícios no importe de 10% (dez por cento), calculado sobre o valor total do débito em atraso, mesmo que a cobrança esteja na fase extrajudicial.

10.2. O(s) COMPRADOR(ES) declara(m) ter pleno conhecimento das cominações previstas em razão de sua inadimplência, estando cientes também que, decorridos 15 (quinze) dias do vencimento de qualquer parcela do preço, seu nome e CPF serão encaminhados aos órgãos de proteção ao crédito, bem como será encaminhado para protesto e cobrança judicial, hipótese em que haverá também a incidência de honorários advocatícios e custas judiciais.

== 11. DA RESOLUÇÃO EXPRESSA DO CONTRATO POR INADIMPLEMENTO DO(S) COMPRADOR(ES) OU DO DISTRATO POR INICIATIVA UNILATERAL DO(S) COMPRADOR(ES)

~ (ARTIGO 35-A, INCISO VI, DA LEI Nº 4.591/1964, INCLUÍDO PELA LEI Nº 13.786/2018)

11.1. Caso o(s) COMPRADOR(ES) permaneça(m) inadimplente(s), por qualquer motivo, por mais de 30 (trinta) dias, poderá a VENDEDORA promover sua notificação, através de qualquer meio físico ou eletrônico, para que purguem a mora, no prazo de 15 (quinze) dias, contados do recebimento da notificação. Caso não seja purgada a mora, operará de pleno direito a resolução deste contrato por inadimplemento do(s) COMPRADOR(ES), ocasião em que a VENDEDORA poderá dispor e usar livremente do imóvel objeto deste contrato.

11.2. Caso não encontrado o(a) COMPRADOR(ES), a VENDEDORA promoverá sua notificação por edital em jornal de grande circulação, operando-se de pleno direito a resolução por inadimplemento do(s) COMPRADOR(ES).

11.3. No caso de distrato por iniciativa unilateral do(s) COMPRADOR(ES) ou resolução por inadimplemento absoluto de obrigação do(s) COMPRADOR(ES), serão restituídos ao(s) COMPRADOR(ES) as quantias que houver(em) pago diretamente ao incorporador, exceto as parcelas pagas à título de ARRAS/SINAL, atualizadas com base no índice contratualmente estabelecido para a correção monetária das parcelas do preço do imóvel, delas deduzidas uma multa no valor correspondente a 50% (cinquenta por cento) do valor efetivamente pago pelo(s) COMPRADOR(ES), conforme autorização legal prevista no artigo 67-A, §5º, da Lei nº 4.591/1964, alterado pela Lei nº 13.786/2018, sendo que a importância remanescente será restituída no prazo máximo de 30 (trinta) dias, contados após a data de expedição do “Habite-se”.

@rubrica_compradores

11.4. Na hipótese de resolução judicial ou extrajudicial, a VENDEDORA terá livre disponibilidade sobre a fração ideal do imóvel/terreno e suas acessões, podendo, inclusive, aliená-la, desde logo, a terceiros, ainda que não tenha sido restituída ao(s) COMPRADOR(ES) a quantia eventualmente devida, na forma deste contrato.

11.5. Constituem, ainda, causas de rescisão do contrato por culpa exclusiva do(s) COMPRADOR(ES):

> a) Cessão ou promessa de cessão de direitos e obrigações desse contrato por parte do COMPRADOR(ES), sem anuência da VENDEDORA;

> b) Constituição de qualquer ônus por parte do(s) COMPRADOR(ES) sobre o seu direito aquisitivo ou de qualquer forma relativo ao imóvel, sem anuência prévia e expressa da VENDEDORA;

> c) decreto de medida judicial que afete a unidade compromissada ou os direitos desse contrato.

11.6. Caso a unidade autônoma objeto deste contrato já tenha sido disponibilizada ao(s) COMPRADOR(ES), nos termos do artigo 67-A, §2º, da Lei nº 4.591/1964, o(s) COMPRADOR(ES) será(ão) o(s) único(s) e exclusivo(s) responsável(is) pelo pagamento dos seguintes valores:

> a) todos os impostos e taxas incidentes sobre a respectiva unidade, tais como: ITU/IPTU, taxas de condomínio, despesas extraordinárias do condomínio, dentre outras;

> b) 0,5% (zero vírgula cinco por cento) ao mês, calculado sobre o valor atualizado deste contrato, previsto no item “4” acima, devidamente atualizado pelos índices eleitos no item “6” deste Quadro Resumo, calculado “pro rata die”, incidente desde a data da disponibilização da unidade autônoma ao(s) COMPRADOR(ES), relativo à fruição do imóvel;

> c) todos os demais encargos e despesas incidentes sobre a unidade autônoma, quais sejam: despesas de consumo de gás, água e energia elétrica, se houver, bem como todas as despesas necessárias ao retorno da unidade autônoma ao padrão do empreendimento, caso o(s) COMPRADOR(ES) tenha solicitado e/ou efetivado alguma personalização e/ou modificação na unidade autônoma, diferentemente do previsto no memorial descritivo do empreendimento.

@rubrica_compradores

11.7. Se não houver o pagamento direto e voluntário pelo(s) COMPRADOR(ES) dos valores descritos no item “11.6” acima, quando da resolução contratual, a VENDEDORA fica, desde já, de forma irrevogável e irretratável, autorizada a descontar a totalidade dos valores devidos pelo(s) COMPRADOR(ES) das quantias que lhe serão restituídas em razão do desfazimento deste contrato, observando-se que, no caso das despesas mencionadas no item “11.6” acima, o eventual saldo devedor negativo deverá ser quitado pelo(s) COMPRADOR(ES), caso os montantes que tenham até então pago à VENDEDORA sejam insuficientes para a completa compensação de valores.

@rubrica_compradores

== 12. DAS DISPOSIÇÕES GERAIS

Sem efeito.

== 13. DA ASSINATURA ELETRÔNICA

As partes reconhecem a veracidade, autenticidade, integridade, validade e eficácia da assinatura e do aceite deste compromisso em formato eletrônico e/ou assinado pelas partes, ainda que sem uso de certificados eletrônicos emitidos pela ICP-Brasil, nos termos da Medida Provisória 2.200-2/2001 e da Lei Federal nº 14.063/2020.

== 14. DO FORO

Comarca de {{empreendimento.foro}}.

== 15. DO LOCAL E DATA

@local_data

@assinaturas_finais`;
