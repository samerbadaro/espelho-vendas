// Instrumento de intermediação imobiliária — minuta de 26/11/2026 (modelo do Seven Europa revisto
// para o Duo Haus; em validação pelos sócios). Mesma marcação do Quadro Resumo:
// "= " título, "== " seção, "> " alínea recuada, "@bloco" bloco montado pelo sistema, {{campo}} dado.
// Campos intermediacao.*, negociacao.* e unidade.numero vêm da proposta aprovada e do cadastro da
// imobiliária; os demais, de Empreendimento › Dados para contrato.
export const INTERMEDIACAO = `= INSTRUMENTO PARTICULAR DE PRESTAÇÃO DE SERVIÇOS DE INTERMEDIAÇÃO IMOBILIÁRIA NA COMPRA E VENDA DE UNIDADE AUTÔNOMA

== CONTRATANTE(S)

@partes

Doravante denominado(s) CONTRATANTE(S).

== CONTRATADAS

@contratadas_intermediacao

A IMOBILIÁRIA é representada neste ato por {{intermediacao.gestor_nome}}, e-mail {{intermediacao.gestor_email}}, gestor responsável pelo atendimento. A COORDENAÇÃO DE VENDAS é representada por {{coordenacao.signatario_nome}}, e-mail {{coordenacao.signatario_email}}.

As partes acima têm entre si justo e contratado o presente instrumento, que se regerá pelas cláusulas a seguir.

== CLÁUSULA PRIMEIRA – DO OBJETO

1.1 – O(s) CONTRATANTE(S), por intermédio das CONTRATADAS, prometeu(ram) adquirir de {{vendedora.razao_social}}, inscrita no CNPJ sob o nº {{vendedora.cnpj}} (VENDEDORA), a unidade autônoma nº {{unidade.numero}} do empreendimento {{empreendimento.nome}}, situado em {{empreendimento.endereco}}, objeto da matrícula nº {{empreendimento.matricula}} do {{empreendimento.cartorio}}, conforme o Quadro Resumo e as Normas Contratuais do Contrato de Promessa de Compra e Venda assinado no mesmo ato deste instrumento (CONTRATO).

1.2 – Valor total da negociação: {{negociacao.total}}, sendo {{negociacao.preco_imovel}} referentes ao preço da unidade, devidos à VENDEDORA na forma do CONTRATO, e {{intermediacao.total}} referentes à remuneração das CONTRATADAS pelos serviços de intermediação, na forma deste instrumento.

== CLÁUSULA SEGUNDA – DA REMUNERAÇÃO E DA FORMA DE PAGAMENTO

2.1 – Pelos serviços de intermediação, o(s) CONTRATANTE(S) pagará(ão) às CONTRATADAS a quantia total de {{intermediacao.total}}, equivalente a {{intermediacao.pct}} do valor total da negociação, distribuída conforme o quadro de contratadas acima. Esse valor está destacado no item 9.3 do Quadro Resumo, em atendimento ao art. 35-A da Lei nº 4.591/64, e não integra o preço da unidade.

2.2 – A remuneração será paga nas parcelas e datas abaixo:

@parcelas_intermediacao

2.3 – O(s) CONTRATANTE(S) fará(ão) um único pagamento por mês, por meio da plataforma de cobrança Imobitech, abrangendo, quando for o caso, a parcela do preço devida à VENDEDORA e a parcela da remuneração devida a cada CONTRATADA. A plataforma destinará a cada parte, diretamente, o valor que lhe cabe, conforme os quadros deste instrumento e do CONTRATO. O(s) CONTRATANTE(S) autoriza(m) essa distribuição.

2.4 – O comprovante de pagamento emitido pela plataforma vale como recibo da parcela correspondente, perante a VENDEDORA e as CONTRATADAS.

2.5 – Parcela não paga no vencimento será acrescida de multa de 2% (dois por cento) e juros de 1% (um por cento) ao mês, pro rata die. Após 30 (trinta) dias de atraso, a CONTRATADA credora poderá incluir o nome do(s) CONTRATANTE(S) nos cadastros de proteção ao crédito e cobrar honorários advocatícios de 10% (dez por cento) na cobrança extrajudicial ou de 20% (vinte por cento) na judicial, sobre o valor atualizado do débito.

== CLÁUSULA TERCEIRA – DA AUTONOMIA E DA NÃO DEVOLUÇÃO

3.1 – O(s) CONTRATANTE(S) reconhece(m) que os serviços de intermediação foram integralmente prestados com a aproximação das partes e a assinatura do CONTRATO, não sendo passíveis de impugnação nem de devolução, ainda que o CONTRATO venha a ser resolvido, distratado ou não se efetive por desistência do(s) CONTRATANTE(S), nos termos do art. 725 do Código Civil e do item 9.2 do Quadro Resumo.

3.2 – Fica ressalvado o direito de arrependimento previsto no item 7 do Quadro Resumo (art. 67-A, § 10, da Lei nº 4.591/64). Exercido no prazo e na forma ali previstos, as CONTRATADAS devolverão integralmente os valores recebidos por este instrumento.

3.3 – Este instrumento decorre de relação entre o(s) CONTRATANTE(S) e as CONTRATADAS. A VENDEDORA não responde por qualquer questão relativa a ele.

== CLÁUSULA QUARTA – DA IRREVOGABILIDADE E DO TÍTULO EXECUTIVO

4.1 – Ressalvado o item 3.2, este instrumento é irrevogável e irretratável e obriga as partes, seus herdeiros e sucessores.

4.2 – Este instrumento constitui título executivo extrajudicial, nos termos do art. 784, III e § 4º, do Código de Processo Civil.

== CLÁUSULA QUINTA – DOS DADOS PESSOAIS

5.1 – Os dados pessoais do(s) CONTRATANTE(S) serão tratados pelas CONTRATADAS, pela VENDEDORA e pela plataforma de cobrança somente para esta negociação, a cobrança e o cumprimento deste instrumento e do CONTRATO, nos termos da Lei nº 13.709/2018.

== CLÁUSULA SEXTA – DAS DISPOSIÇÕES FINAIS

6.1 – O(s) CONTRATANTE(S) declara(m) que leu(ram) todas as cláusulas, em especial o valor e a forma de pagamento, e com elas concorda(m).

6.2 – As partes elegem o foro da Comarca de {{empreendimento.foro}} para dirimir questões deste instrumento.

6.3 – Este instrumento é assinado eletronicamente pela plataforma {{assinatura.plataforma}}, nos termos da MP nº 2.200-2/2001 e da Lei nº 14.063/2020, com a mesma validade das vias físicas.

@local_data

@assinaturas_intermediacao`;
