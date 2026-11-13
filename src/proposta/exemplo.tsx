// Página de exemplo da carta proposta (/carta-exemplo), só no ramo v2.
// Usa o motor de cálculo para montar o fluxo de tabela e destacar a comissão.
import { CartaProposta, type DadosCarta, type SerieCarta } from './CartaProposta';
import { destacarComissao, fluxoTabela, mes, precoUnidade, type SerieTabela } from './calculo';

const emp = { mesTabela: mes(2026, 11), entrega: mes(2030, 10), taxaVP: 0.007 };
const preco = Math.round(precoUnidade({ m2Grupo: 12500, peso: 0.9675, mediaPesoGrupo: 0.94203125, area: 34.93 }) * 100) / 100;

const tabela: SerieTabela[] = [
  { nome: 'Ato', tipo: 'sinal', parcelas: 1, percentual: 0.04, inicio: { base: 'venda', deslocamento: 0 } },
  { nome: '30/60/90', tipo: 'sinal', parcelas: 3, percentual: 0.04, inicio: { base: 'venda', deslocamento: 1 } },
  { nome: 'Mensais', tipo: 'mensal', parcelas: 44, percentual: 0.065, inicio: { base: 'venda', deslocamento: 4 } },
  { nome: 'Semestrais', tipo: 'semestral', parcelas: 7, percentual: 0.155, inicio: { base: 'venda', deslocamento: 5 } },
  { nome: 'Única', tipo: 'unica', parcelas: 1, percentual: 0.05, inicio: { base: 'entrega', deslocamento: -3 } },
  { nome: 'Financiamento', tipo: 'unica', parcelas: 1, percentual: 0.65, inicio: { base: 'entrega', deslocamento: 1 }, posChaves: true },
];
const fluxo = fluxoTabela(preco, tabela, emp);
const dia = (m: number, d = 10) => `${Math.floor(m / 12)}-${String((m % 12) + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`;

const series: SerieCarta[] = tabela.map((t) => {
  const p = fluxo.filter((x) => x.serie === t.nome);
  return {
    tipo: t.tipo, parcelas: p.length, valorParcela: Math.round(p[0].valor * 100) / 100,
    primeiroVencimento: t.nome === 'Ato' ? '2026-11-17' : dia(p[0].mes),
    posChaves: t.posChaves,
    correcao: t.tipo === 'sinal' ? 'Fixa' : t.posChaves ? '—' : 'INCC até o habite-se',
    formaPagamento: t.posChaves ? 'Financiamento bancário' : t.tipo === 'sinal' ? 'PIX' : 'Boleto',
  };
});

const sinal = fluxo.filter((p) => p.tipo === 'sinal').map((p) => ({ mes: p.mes, valor: p.valor }));
const com = destacarComissao(sinal, preco, 0.05, { tipo: 'proporcional', pctComissaoNaParcela: 0.7 });

const dados: DadosCarta = {
  numero: 'PA-001',
  data: '2026-11-17',
  local: 'Rio Verde - GO',
  vendedora: { nome: 'SPE Duo Haus Empreendimento Imobiliário Ltda.', cnpj: '00.000.000/0001-00' },
  empreendimento: 'Duo Haus – Wellness + Life',
  unidade: '1804',
  pavimento: '18º',
  area: 34.93,
  proponentes: [
    {
      nome: 'Carlos Eduardo Martins', cpf: '123.456.789-09', rg: '1234567', orgaoEmissor: 'SSP/GO',
      nascimento: '1988-04-12', nacionalidade: 'Brasileira', estadoCivil: 'Casado', regime: 'Comunhão parcial',
      profissao: 'Engenheiro agrônomo', celular: '(64) 99999-1234', email: 'carlos@exemplo.com',
      endereco: 'Rua 10, 250, Setor Central, Rio Verde - GO', cep: '75901-000',
    },
    {
      nome: 'Juliana Alves Martins', cpf: '987.654.321-00', rg: '7654321', orgaoEmissor: 'SSP/GO',
      nascimento: '1990-09-03', nacionalidade: 'Brasileira', estadoCivil: 'Casada', regime: 'Comunhão parcial',
      profissao: 'Médica veterinária', celular: '(64) 99999-5678', email: 'juliana@exemplo.com',
      endereco: 'Rua 10, 250, Setor Central, Rio Verde - GO', cep: '75901-000',
    },
  ],
  series,
  intermediacao: com.parcelas.filter((p) => p.comissao > 0).map((p, i) => ({
    papel: 'Imobiliária', nome: 'Imobiliária Exemplo', pct: p.comissao / preco, valor: Math.round(p.comissao * 100) / 100,
    vencimento: i === 0 ? '2026-11-17' : dia(p.mes),
  })),
  equipe: { imobiliaria: 'Imobiliária Exemplo', corretor: 'João Silva', creci: '12345-F', coordenador: 'Kavaná' },
  observacoes: 'Exemplo gerado a partir da tabela vigente, sem desconto.',
  clausulas: [
    'A partir desta data e até o mês da expedição do habite-se, os valores serão reajustados pelo INCC (Índice Nacional de Custo da Construção). A partir do primeiro dia do mês seguinte ao habite-se e até a quitação, os valores serão reajustados mensalmente pelo IGP-M (Índice Geral de Preços do Mercado), acrescidos de juros de 1% (um por cento) ao mês.',
    'Esta proposta será analisada pela vendedora, que poderá recusá-la, ainda que sem motivação.',
    'A concessão do financiamento bancário está sujeita à análise de crédito e aos critérios do banco financiador. É de responsabilidade exclusiva do(s) proponente(s) obter os recursos para a parcela de financiamento, por crédito bancário ou recursos próprios.',
    'Os honorários de intermediação imobiliária serão pagos com o sinal de negócio definido nesta proposta. Os valores de sinal e intermediação devem ser quitados na assinatura desta proposta.',
    'Em caso de recusa desta proposta ou de não compensação do sinal, ela perderá qualquer eficácia jurídica e a unidade ficará liberada para comercialização, sem ônus para o(s) proponente(s).',
    'Questões oriundas desta proposta serão resolvidas preferencialmente por via conciliatória ou arbitral, ficando eleito o foro da comarca de Rio Verde - GO.',
  ],
};

export function ExemploCarta() {
  return <CartaProposta d={dados} />;
}
