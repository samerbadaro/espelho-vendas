// Modelos padrão em Word COM MARCADORES (Quadro Resumo e Normas), gerados a partir dos textos-base.
// O administrador baixa, edita no Word (texto, formatação, logo) e envia de volta como modelo do empreendimento.
import type { RowInput, UserOptions } from 'jspdf-autotable';
import { renderizarWord, NOME_DOCUMENTO, TEXTO_BOLETOS, TEXTO_HABITE_1, TEXTO_HABITE_2, TEXTO_QUITACAO_SINAL, type Item, type OpPara, type TipoDocumento } from './gerador';

const CINZA: { fontStyle: 'bold'; fillColor: [number, number, number] } = { fontStyle: 'bold', fillColor: [242, 242, 242] };
const dados4 = (linhas: [string, string, string?, string?][]): Item => ({
  k: 'tabela',
  o: {
    body: linhas.map(([a, b, c, d]): RowInput => c === undefined
      ? [{ content: a, styles: CINZA }, { content: b, colSpan: 3 }]
      : [{ content: a, styles: CINZA }, b, { content: c, styles: CINZA }, d ?? '']),
    columnStyles: { 0: { cellWidth: 40 }, 2: { cellWidth: 36 } },
  } as UserOptions,
});
const p = (texto: string, o: OpPara = {}): Item => ({ k: 'p', texto, o });
const pessoa = (q: string): Item => dados4([
  ['Nome:', `{${q}.nome}`],
  ['Nacionalidade:', `{${q}.nacionalidade}`, 'Naturalidade:', `{${q}.naturalidade}`],
  ['Profissão:', `{${q}.profissao}`, 'Estado civil:', `{${q}.estado_civil}`],
  ['Regime de bens:', `{${q}.regime_bens}`, 'Data de nascimento:', `{${q}.nascimento}`],
  ['CPF nº:', `{${q}.cpf}`, 'Cédula de identidade nº:', `{${q}.rg_completo}`],
  ['Telefone(s):', `{${q}.telefone}`, 'E-mail:', `{${q}.email}`],
  ['Domicílio e residência:', `{${q}.endereco}`],
]);

const BLOCOS: Record<string, () => Item[]> = {
  partes: () => [
    p('{#eh_pj}'),
    dados4([
      ['Razão social:', '{empresa.razao_social}'],
      ['CNPJ:', '{empresa.cnpj}', 'Data de abertura:', '{empresa.data_abertura}'],
      ['Atividade econômica:', '{empresa.atividade}'],
      ['Registro na junta comercial:', '{empresa.registro_junta}'],
      ['Telefone(s):', '{empresa.telefone}', 'E-mail:', '{empresa.email}'],
      ['Endereço:', '{empresa.endereco}'],
    ]),
    p('QUALIFICAÇÃO DO(S) REPRESENTANTE(S) LEGAL(IS):', { negrito: true }),
    p('{/eh_pj}'),
    pessoa('comprador'),
    p('{#tem_conjuge}'),
    p('Qualificação do cônjuge, que aqui também comparece como adquirente:', { negrito: true }),
    pessoa('conjuge'),
    p('{/tem_conjuge}'),
  ],
  quadro_unidade: () => [dados4([
    ['Empreendimento:', '{empreendimento.nome}'],
    ['Localização:', '{empreendimento.endereco}'],
    ['Torre:', '{unidade.torre}', 'Unidade:', '{unidade.numero}'],
    ['Pavimento:', '{unidade.pavimento}'],
    ['Número das vagas/localização:', '{unidade.vagas}'],
    ['Área total privativa:', '{unidade.area_privativa_total}', 'Vagas (área acessória):', '{unidade.area_acessoria}'],
    ['Área privativa principal:', '{unidade.area_privativa}', 'Área comum:', '{unidade.area_comum}'],
    ['Área total real:', '{unidade.area_total}', 'Fração ideal:', '{unidade.fracao_ideal}'],
    ['Escaninho:', '{unidade.escaninho} {unidade.escaninho_local}', 'Área total do escaninho:', '{unidade.escaninho_area}'],
  ])],
  pagamento: () => [
    p('4.1. O preço, certo e ajustado, para aquisição e pagamento da unidade autônoma de apartamento indicada no item “3.1” acima é de {preco.completo}, que deverá ser integralmente pago ou amortizado pelo(s) COMPRADOR(ES) nas seguintes condições:'),
    {
      k: 'tabela', o: {
        head: [['Série', 'Periodicidade', 'Quant.', 'Valor unitário', 'Valor total', '%', '1º vencimento', 'Correção']],
        body: [
          ['{#series}{serie}', '{periodicidade}', '{qtd}', '{valor}', '{total}', '{pct}', '{vencimento}', '{correcao}{/series}'],
          [{ content: 'Total', colSpan: 4, styles: { fontStyle: 'bold' } }, { content: '{preco.total}', styles: { fontStyle: 'bold' } }, { content: '100,00%', styles: { fontStyle: 'bold' } }, { content: '', colSpan: 2 }],
        ],
        styles: { halign: 'center' },
        columnStyles: { 0: { cellWidth: 12 }, 1: { cellWidth: 28 }, 2: { cellWidth: 13 }, 3: { cellWidth: 25 }, 4: { cellWidth: 25 }, 5: { cellWidth: 15 }, 6: { cellWidth: 25 }, 7: { cellWidth: 27 } },
      } as UserOptions,
    },
    p('4.2. ARRAS/SINAL: Neste ato o(s) COMPRADOR(ES) se obriga(m) a pagar a importância total de {sinal.completo}, a título de arras/sinal, valor este que representa o percentual de {sinal.pct} do valor total do preço previsto no item “4.1” acima, sendo que a primeira parcela será paga pelo(s) COMPRADOR(ES) através de TED/PIX e as demais parcelas deverão ser pagas por meio de boleto bancário, conforme subitens abaixo, tudo conforme disposto nos artigos 418 e 419 do Código Civil, cuja quitação dar-se-á somente após a compensação e efetiva liberação do crédito bancário em favor da VENDEDORA.'),
    p('{#sinal_parcelas}'),
    p('{item}) Parcela no valor unitário de {valor_completo}, com vencimento no dia {vencimento}.', { recuo: 6 }),
    p('{/sinal_parcelas}'),
    p(`{sinal.item_quitacao}) ${TEXTO_QUITACAO_SINAL}`, { recuo: 6 }),
    p('{#demais_series}'),
    p('{item}. {texto}'),
    p('{/demais_series}'),
    p('{habite_se.item}. {habite_se.texto}'),
    p(`{habite_se.item}.1. ${TEXTO_HABITE_1}`, { recuo: 6 }),
    p(`{habite_se.item}.2. ${TEXTO_HABITE_2}`, { recuo: 6 }),
    p(`{boletos.item}. ${TEXTO_BOLETOS}`),
  ],
  tabela_comissao: () => [{
    k: 'tabela', o: {
      head: [['Nome do beneficiário', 'Valor da comissão', 'Forma de pagamento', 'CPF / CNPJ']],
      body: [
        ['{#comissao}{nome}', '{valor}', '{forma}', '{documento}{/comissao}'],
        [{ content: 'TOTAL COMISSÃO', styles: { fontStyle: 'bold' } }, { content: '{comissao_total}', styles: { fontStyle: 'bold' } }, { content: '', colSpan: 2 }],
      ],
    } as UserOptions,
  }],
  rubrica_compradores: () => [p('Assinatura do(s) COMPRADOR(ES):', { negrito: true, antes: 2, secao: true }), { k: 'assinLoop', lista: 'compradores_assinatura' }],
  local_data: () => [p('{local_data}')],
  assinaturas_finais: () => [
    { k: 'espaco', mm: 4 },
    p('VENDEDORA', { negrito: true, secao: true }),
    { k: 'assin', nomes: [['{vendedora.assinante}', 'VENDEDORA']], colunas: 1 },
    p('COMPRADOR(ES):', { negrito: true, secao: true }),
    { k: 'assinLoop', lista: 'compradores_assinatura' },
    p('TESTEMUNHAS', { negrito: true, secao: true }),
    { k: 'assin', nomes: [['NOME: {testemunha1.nome}', 'CPF: {testemunha1.cpf}'], ['NOME: {testemunha2.nome}', 'CPF: {testemunha2.cpf}']], colunas: 2 },
  ],
};

/** Gera o modelo padrão em Word, com marcadores no lugar dos dados. */
export async function modeloPadrao(tipo: TipoDocumento): Promise<Blob> {
  const texto = tipo === 'quadro_resumo' ? (await import('./modelos/quadroResumo')).QUADRO_RESUMO : (await import('./modelos/normas')).NORMAS;
  const itens: Item[] = [];
  for (const bruto of texto.split(/\n\s*\n/)) {
    const t = bruto.trim().replace(/\{\{([\w.]+)\}\}/g, '{$1}');
    if (!t) continue;
    if (t.startsWith('@')) { itens.push(...(BLOCOS[t.slice(1)]?.() ?? [])); continue; }
    if (t.startsWith('== ')) itens.push(p(t.slice(3), { negrito: true, antes: 2.5, depois: 1.6, secao: true }));
    else if (t.startsWith('= ')) itens.push(p(t.slice(2), { negrito: true, centro: true, tam: 11, depois: 3 }));
    else if (t.startsWith('## ')) itens.push(p(t.slice(3), { negrito: true, depois: 1.6 }));
    else if (t.startsWith('~ ')) itens.push(p(t.slice(2), { italico: true, tam: 8, depois: 2 }));
    else if (t.startsWith('> ')) itens.push(p(t.slice(2), { recuo: 8 }));
    else itens.push(p(t));
  }
  return renderizarWord(itens, `${NOME_DOCUMENTO[tipo]} · Unidade {unidade.numero} · {contrato.referencia}`, `${NOME_DOCUMENTO[tipo]} — modelo com marcadores`);
}
