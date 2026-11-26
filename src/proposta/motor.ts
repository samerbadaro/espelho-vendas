// =====================================================================
// Motor da proposta: fluxo da tabela x fluxo da proposta, VPL, captação,
// comissão, validações, modelos de preenchimento e redistribuição.
// Funções puras (sem tela e sem banco), conferidas contra a planilha PV.
// Datas: 'AAAA-MM-DD' (vencimentos) e 'AAAA-MM' (meses de referência).
// =====================================================================

export type Periodicidade = 'Sinal' | 'Mensais' | 'Bimestrais' | 'Trimestrais' | 'Semestrais' | 'Anuais' | 'Unica' | 'Permuta' | 'Financiamento';

export const PERIODICIDADES: { valor: Periodicidade; rotulo: string }[] = [
  { valor: 'Sinal', rotulo: 'Sinal' },
  { valor: 'Mensais', rotulo: 'Mensais' },
  { valor: 'Bimestrais', rotulo: 'Bimestrais' },
  { valor: 'Trimestrais', rotulo: 'Trimestrais' },
  { valor: 'Semestrais', rotulo: 'Semestrais' },
  { valor: 'Anuais', rotulo: 'Anuais' },
  { valor: 'Unica', rotulo: 'Única' },
  { valor: 'Permuta', rotulo: 'Permuta' },
  { valor: 'Financiamento', rotulo: 'Financiamento' },
];

export interface Unidade {
  numero: string;
  area: number;
  tipo: string;
  peso: number;
  tabela: string;
}

export interface SerieTabela {
  rotulo: string;
  periodicidade: Periodicidade;
  qtd: number;
  percentual: number; // do preço da unidade, somando a série inteira
  inicio: { base: 'venda' | 'entrega'; meses: number };
}

export interface ConfigEmpreendimento {
  nome: string;
  mesTabela: string; // 'AAAA-MM'
  mesEntrega: string; // 'AAAA-MM'
  taxaVP: number; // ao mês
  precoM2PorTipo: Record<string, number>;
  tabelas: Record<string, SerieTabela[]>;
  unidades: Unidade[];
  /** percentual = imobiliária; coordenacao = coordenação de vendas (ex.: Kavaná), paga em até 3 parcelas do sinal */
  comissao: { percentual: number; parteDoSinal: number; coordenacao?: number; coordenacaoParcelas?: number };
  limiteVariacaoCaptacao: number; // ex.: -0.15
}

export interface Serie {
  id: string;
  qtd: number;
  periodicidade: Periodicidade;
  vencimento: string; // 1º vencimento 'AAAA-MM-DD'
  valor: number; // valor de cada parcela
}

export interface Parcela {
  serieId: string;
  data: string; // 'AAAA-MM-DD'
  mes: number; // meses desde o mês da tabela (0 = mês da tabela)
  mesVP: number; // mês usado no VPL (financiamento conta no mês seguinte à entrega)
  valor: number;
  periodicidade: Periodicidade;
}

// ---------------------------------------------------------------------
// Datas
// ---------------------------------------------------------------------
const ano = (s: string) => Number(s.slice(0, 4));
const mesNum = (s: string) => Number(s.slice(5, 7));
export const indiceMes = (s: string) => ano(s) * 12 + mesNum(s) - 1;
export const mesesEntre = (de: string, ate: string) => indiceMes(ate) - indiceMes(de);
const doisDig = (n: number) => String(n).padStart(2, '0');

/** Soma meses a 'AAAA-MM' ou 'AAAA-MM-DD' e devolve 'AAAA-MM'. */
export function somarMeses(s: string, n: number) {
  const i = indiceMes(s) + n;
  return `${Math.floor(i / 12)}-${doisDig((i % 12) + 1)}`;
}

/** Dia do vencimento dentro do mês, sem passar do último dia (ex.: dia 31 em fevereiro). */
export function dataNoMes(mes: string, dia: number) {
  const ultimo = new Date(Date.UTC(ano(mes), mesNum(mes), 0)).getUTCDate();
  return `${mes.slice(0, 7)}-${doisDig(Math.min(dia, ultimo))}`;
}

/** Vencimento da parcela k (0, 1, 2...) de uma série. */
export function dataDaParcela(serie: Pick<Serie, 'vencimento' | 'periodicidade'>, k: number) {
  const passo = PASSO[serie.periodicidade];
  const dia = Number(serie.vencimento.slice(8, 10));
  return dataNoMes(somarMeses(serie.vencimento, k * passo), dia);
}

export const PASSO: Record<Periodicidade, number> = {
  Sinal: 1, Mensais: 1, Bimestrais: 2, Trimestrais: 3, Semestrais: 6, Anuais: 12, Unica: 1, Permuta: 1, Financiamento: 1,
};

export function hojeISO(d = new Date()) {
  return `${d.getFullYear()}-${doisDig(d.getMonth() + 1)}-${doisDig(d.getDate())}`;
}

const centavos = (v: number) => Math.round(v * 100) / 100;
/** Arredonda para cima no centavo (modelos: o PV nunca fica negativo por arredondamento). */
const centavosAcima = (v: number) => Math.ceil(Math.round(v * 1e6) / 1e4) / 100;

// ---------------------------------------------------------------------
// Preço e tabela
// ---------------------------------------------------------------------
/** Preço da unidade = R$/m² do tipo × peso do andar × área ÷ peso médio do tipo. */
export function precoUnidade(cfg: ConfigEmpreendimento, u: Unidade) {
  const doTipo = cfg.unidades.filter((x) => x.tipo === u.tipo);
  const pesoMedio = doTipo.reduce((s, x) => s + x.peso, 0) / doTipo.length;
  return (cfg.precoM2PorTipo[u.tipo] * u.peso * u.area) / pesoMedio;
}

/** Fluxo da tabela da unidade, como séries (vencimento no dia 1º, como a planilha). */
export function seriesDaTabela(cfg: ConfigEmpreendimento, u: Unidade, dia = 1): Serie[] {
  const preco = precoUnidade(cfg, u);
  return cfg.tabelas[u.tabela].map((s, i) => {
    const base = s.inicio.base === 'venda' ? cfg.mesTabela : cfg.mesEntrega;
    return {
      id: `t${i}`,
      qtd: s.qtd,
      periodicidade: s.periodicidade,
      vencimento: dataNoMes(somarMeses(base, s.inicio.meses), dia),
      valor: (s.percentual * preco) / s.qtd,
    };
  });
}

// ---------------------------------------------------------------------
// Fluxo, VPL e captação
// ---------------------------------------------------------------------
export function parcelas(cfg: ConfigEmpreendimento, series: Serie[]): Parcela[] {
  const mesSecuritizacao = mesesEntre(cfg.mesTabela, somarMeses(cfg.mesEntrega, 1));
  const lista: Parcela[] = [];
  for (const s of series) {
    if (!s.vencimento || !(s.qtd > 0)) continue;
    for (let k = 0; k < Math.floor(s.qtd); k++) {
      const data = dataDaParcela(s, k);
      const mes = mesesEntre(cfg.mesTabela, data);
      lista.push({
        serieId: s.id, data, mes, valor: s.valor, periodicidade: s.periodicidade,
        // como na planilha: o pós-chaves (financiamento) é securitizado no mês seguinte à entrega
        mesVP: s.periodicidade === 'Financiamento' ? mesSecuritizacao : mes,
      });
    }
  }
  return lista.sort((a, b) => a.data.localeCompare(b.data));
}

/** Diferença de PV abaixo disto (centavos de arredondamento) conta como PV zerado. */
export const TOLERANCIA_PV = 0.5;

const fator = (taxa: number, mes: number) => Math.pow(1 + taxa, -mes);

export function vpl(cfg: ConfigEmpreendimento, ps: Parcela[]) {
  return ps.reduce((s, p) => s + p.valor * fator(cfg.taxaVP, p.mesVP), 0);
}

export const total = (ps: Parcela[]) => ps.reduce((s, p) => s + p.valor, 0);

export interface Marco { rotulo: string; ateMes: number; tabela: number; proposta: number; variacao: number | null }

/** % do valor total recebido até cada marco (3, 6, 12, 18, 24, 36 meses e entrega). */
export function captacao(cfg: ConfigEmpreendimento, tab: Parcela[], prop: Parcela[]): Marco[] {
  const entrega = mesesEntre(cfg.mesTabela, cfg.mesEntrega);
  const marcos = [
    ['3 meses', 2], ['6 meses', 5], ['12 meses', 11], ['18 meses', 17], ['24 meses', 23], ['36 meses', 35], ['Até a entrega', entrega],
  ] as const;
  const pct = (ps: Parcela[], ate: number) => {
    const t = total(ps);
    return t > 0 ? ps.filter((p) => p.mes <= ate).reduce((s, p) => s + p.valor, 0) / t : 0;
  };
  return marcos.map(([rotulo, ateMes]) => {
    const tabela = pct(tab, ateMes);
    const proposta = pct(prop, ateMes);
    return { rotulo, ateMes, tabela, proposta, variacao: tabela > 0 ? proposta / tabela - 1 : null };
  });
}

// ---------------------------------------------------------------------
// Comissão: sai do sinal. De cada parcela de sinal, "parteDoSinal" (ex.: 70%)
// vai para a comissão até completá-la; o resto é do incorporador.
// A comissão tem duas partes: imobiliária (ex.: 5%) e coordenação de vendas
// (ex.: 0,5%). Dentro da parte de cada parcela, a coordenação recebe primeiro
// até coordenação ÷ N do valor total (N = 1 a 3 parcelas; padrão 2: 0,25% + 0,25%)
// e o restante vai para a imobiliária. Se o sinal cobre a comissão inteira, a
// última parcela de sinal completa o que faltar da coordenação (ex.: sinal numa
// parcela só leva os 0,5% de uma vez).
// ---------------------------------------------------------------------
export interface LinhaComissao { data: string; parcela: number; comissao: number; imobiliaria: number; coordenacao: number; incorporador: number }

export function comissao(prop: Parcela[], valorTotal: number, percentual: number, parteDoSinal: number, coordenacao = 0, coordenacaoParcelas = 2) {
  const devidaImob = centavos(valorTotal * percentual);
  const devidaCoord = centavos(valorTotal * Math.max(0, coordenacao));
  const devida = centavos(devidaImob + devidaCoord);
  const n = Math.min(3, Math.max(1, Math.round(coordenacaoParcelas || 2)));
  const porParcela = centavos(devidaCoord / n);
  const sinais = prop.filter((p) => p.periodicidade === 'Sinal');
  const capacidade = sinais.reduce((t, p) => t + centavos(p.valor * parteDoSinal), 0);
  const cobre = capacidade + 0.005 >= devida;
  let faltaI = devidaImob, faltaC = devidaCoord;
  const linhas: LinhaComissao[] = sinais.map((p, i) => {
    const fatia = centavos(Math.min(faltaI + faltaC, p.valor * parteDoSinal));
    const ultima = i === sinais.length - 1;
    // a última parcela de cada "rodada" de N completa a sobra de arredondamento
    const teto = cobre && ultima ? faltaC : Math.min(faltaC, i === n - 1 ? faltaC : porParcela);
    const c = centavos(Math.min(teto, fatia));
    const im = centavos(Math.min(faltaI, fatia - c));
    faltaC = centavos(faltaC - c); faltaI = centavos(faltaI - im);
    const tot = centavos(c + im);
    return { data: p.data, parcela: p.valor, comissao: tot, imobiliaria: im, coordenacao: c, incorporador: centavos(p.valor - tot) };
  });
  const falta = centavos(faltaI + faltaC);
  const sinal = centavos(linhas.reduce((t, l) => t + l.parcela, 0));
  // sinal mínimo para destacar a comissão inteira: comissão ÷ parte do sinal (ex.: 5,5% ÷ 70% = 7,86%)
  const sinalNecessario = parteDoSinal > 0 ? centavosAcima(devida / parteDoSinal) : Infinity;
  return {
    devida, devidaImob, devidaCoord, linhas, naoCoberta: Math.max(0, falta),
    destacada: centavos(devida - Math.max(0, falta)),
    destacadaImob: centavos(devidaImob - faltaI), destacadaCoord: centavos(devidaCoord - faltaC),
    sinal,
    sinalPct: valorTotal > 0 ? sinal / valorTotal : 0,
    /** % máximo do valor que dá para destacar com o sinal atual */
    maximoPct: valorTotal > 0 ? (sinal * parteDoSinal) / valorTotal : 0,
    sinalNecessario,
    sinalNecessarioPct: valorTotal > 0 ? sinalNecessario / valorTotal : 0,
    faltaSinal: Math.max(0, centavos(sinalNecessario - sinal)),
  };
}

// ---------------------------------------------------------------------
// Resultado completo
// ---------------------------------------------------------------------
export interface Aviso { nivel: 'erro' | 'alerta'; texto: string; serieId?: string }

export interface Resultado {
  preco: number;
  tabela: { parcelas: Parcela[]; total: number; vpl: number; m2: number };
  proposta: { parcelas: Parcela[]; total: number; vpl: number; m2: number };
  variacaoVPL: number; // proposta ÷ tabela − 1
  diferencaVPL: number; // R$
  marcos: Marco[];
  comissao: ReturnType<typeof comissao>;
  avisos: Aviso[];
  aprovado: boolean;
}

export interface Opcoes {
  /** Nenhum vencimento antes desta data: hoje, ou a data da proposta já salva. */
  dataMinima: string;
  comissaoPercentual?: number;
  parteDoSinal?: number;
  /** coordenação de vendas: percentual e em quantas parcelas do sinal (1 a 3) */
  coordenacao?: number;
  coordenacaoParcelas?: number;
  /** Dias de vencimento permitidos (ex.: 5, 10, 15, 20). O ato que vence na data da proposta fica de fora. */
  diasVencimento?: number[];
  /** Observações da proposta: obrigatórias quando há permuta. */
  observacoes?: string | null;
}

export function calcular(cfg: ConfigEmpreendimento, u: Unidade, series: Serie[], op: Opcoes): Resultado {
  const preco = precoUnidade(cfg, u);
  const pt = parcelas(cfg, seriesDaTabela(cfg, u));
  const pp = parcelas(cfg, series);
  const t = { parcelas: pt, total: total(pt), vpl: vpl(cfg, pt), m2: total(pt) / u.area };
  const p = { parcelas: pp, total: total(pp), vpl: vpl(cfg, pp), m2: total(pp) / u.area };
  const marcos = captacao(cfg, pt, pp);
  const com = comissao(pp, p.total, op.comissaoPercentual ?? cfg.comissao.percentual, op.parteDoSinal ?? cfg.comissao.parteDoSinal,
    op.coordenacao ?? cfg.comissao.coordenacao ?? 0, op.coordenacaoParcelas ?? cfg.comissao.coordenacaoParcelas ?? 2);
  const diferencaVPL = p.vpl - t.vpl;

  const avisos: Aviso[] = [];
  const limitePreChaves = somarMeses(cfg.mesEntrega, 2);
  for (const s of series) {
    if (!s.vencimento) { avisos.push({ nivel: 'erro', texto: 'Série sem data de vencimento.', serieId: s.id }); continue; }
    if (!(s.qtd >= 1) || !Number.isInteger(s.qtd)) avisos.push({ nivel: 'erro', texto: 'Número de parcelas inválido.', serieId: s.id });
    if (!(s.valor > 0)) avisos.push({ nivel: 'erro', texto: 'Valor da parcela deve ser maior que zero.', serieId: s.id });
    if (s.vencimento < op.dataMinima) avisos.push({ nivel: 'erro', texto: `Vencimento anterior a ${fmtData(op.dataMinima)}.`, serieId: s.id });
    const diaVenc = Number(s.vencimento.slice(8, 10));
    if (op.diasVencimento?.length && s.vencimento !== op.dataMinima && !op.diasVencimento.includes(diaVenc))
      avisos.push({ nivel: 'alerta', texto: `Vencimento no dia ${String(diaVenc).padStart(2, '0')}: use dia ${op.diasVencimento.map((d) => String(d).padStart(2, '0')).join(', ').replace(/, (\d+)$/, ' ou $1')}.`, serieId: s.id });
    const fim = dataDaParcela(s, Math.max(0, Math.floor(s.qtd) - 1));
    if (s.periodicidade !== 'Financiamento' && indiceMes(fim) > indiceMes(limitePreChaves))
      avisos.push({ nivel: 'alerta', texto: 'Parcela no período do financiamento (depois da entrega).', serieId: s.id });
    if (s.periodicidade === 'Financiamento' && indiceMes(s.vencimento) < indiceMes(cfg.mesEntrega))
      avisos.push({ nivel: 'alerta', texto: 'Financiamento antes da entrega.', serieId: s.id });
  }
  const permuta = series.find((s) => s.periodicidade === 'Permuta');
  if (permuta && op.observacoes !== undefined && !(op.observacoes ?? '').trim())
    avisos.push({ nivel: 'erro', texto: 'Permuta: descreva nas observações o que entra na permuta (imóvel, carro, serviços...).', serieId: permuta.id });
  // PV abaixo da tabela não bloqueia: a proposta vai para a alçada de aprovação
  if (p.total > t.total + 0.005)
    avisos.push({ nivel: 'erro', texto: `Preço ${fmtReal(p.total - t.total)} acima da tabela. O preço da unidade não pode passar do preço de tabela: use "⟲ ajustar" numa série para voltar.` });
  if (diferencaVPL < -TOLERANCIA_PV) avisos.push({ nivel: 'alerta', texto: `PV negativo: faltam ${fmtReal(-diferencaVPL)} em valor presente. Precisa de aprovação.` });
  for (const m of marcos)
    if (m.variacao !== null && m.variacao < cfg.limiteVariacaoCaptacao)
      avisos.push({ nivel: 'alerta', texto: `Captação em ${m.rotulo.toLowerCase()} ${fmtPct(m.variacao)} abaixo da tabela.` });
  if (com.naoCoberta > 0.005)
    avisos.push({
      nivel: 'alerta',
      texto: `Sinal insuficiente para destacar a comissão: com sinal de ${fmtPct(com.sinalPct, 2)}, o máximo é ${fmtPct(com.maximoPct, 2)}. Aumente o sinal em ${fmtReal(com.faltaSinal)}.`,
    });

  return {
    preco, tabela: t, proposta: p,
    variacaoVPL: t.vpl > 0 ? p.vpl / t.vpl - 1 : 0, diferencaVPL, marcos, comissao: com, avisos,
    aprovado: !avisos.some((a) => a.nivel === 'erro'),
  };
}

// ---------------------------------------------------------------------
// Redistribuir ("atingir meta"): calcula o valor da parcela de uma série
// para que o VPL da proposta fique igual ao da tabela (PV zero).
// ---------------------------------------------------------------------
export function redistribuir(cfg: ConfigEmpreendimento, u: Unidade, series: Serie[], serieId: string, meta: 'pv' | 'nominal' = 'pv'): Serie[] | { erro: string } | { series: Serie[]; aviso: string } {
  const alvo = series.find((s) => s.id === serieId);
  if (!alvo) return { erro: 'Série não encontrada.' };
  if (meta === 'nominal') {
    // valor nominal da proposta igual ao valor total da tabela (sem desconto nominal; o PV pode ficar abaixo)
    const totalTabela = total(parcelas(cfg, seriesDaTabela(cfg, u)));
    const outras = series.filter((s) => s.id !== serieId).reduce((t, s) => t + s.valor * s.qtd, 0);
    if (!(alvo.qtd >= 1)) return { erro: 'A série precisa ter número de parcelas.' };
    const valor = Math.floor(((totalTabela - outras) / alvo.qtd) * 100) / 100; // para baixo: nunca acima da tabela
    if (valor <= 0) return { erro: 'As outras séries já somam o valor da tabela; não sobra valor para esta série.' };
    return series.map((s) => (s.id === serieId ? { ...s, valor } : s));
  }
  const vplTabela = vpl(cfg, parcelas(cfg, seriesDaTabela(cfg, u)));
  const outras = vpl(cfg, parcelas(cfg, series.filter((s) => s.id !== serieId)));
  // VPL da série-alvo com parcela de R$ 1,00
  const unitario = vpl(cfg, parcelas(cfg, [{ ...alvo, valor: 1 }]));
  if (!(unitario > 0)) return { erro: 'A série precisa ter vencimento e número de parcelas.' };
  const valor = Math.ceil(((vplTabela - outras) / unitario) * 100) / 100; // arredonda para cima: PV nunca fica negativo
  if (valor <= 0) return { erro: 'As outras séries já cobrem o PV da tabela; não sobra valor para esta série.' };
  // Trava: o preço (valor nominal) da proposta nunca passa do preço de tabela. Se zerar o PV exigir isso,
  // a série fica no valor que leva o total ao preço de tabela e o PV continua negativo.
  const totalTabela = total(parcelas(cfg, seriesDaTabela(cfg, u)));
  const outrasNominal = series.filter((s) => s.id !== serieId).reduce((t, s) => t + s.valor * s.qtd, 0);
  if (outrasNominal + valor * alvo.qtd > totalTabela + 0.005) {
    const teto = Math.floor(((totalTabela - outrasNominal) / alvo.qtd) * 100) / 100;
    if (teto <= 0) return { erro: 'As outras séries já somam o preço de tabela. Com esta condição não é possível chegar ao PV 0 sem passar do preço de tabela.' };
    return {
      series: series.map((s) => (s.id === serieId ? { ...s, valor: teto } : s)),
      aviso: 'Ajustado até o preço de tabela. Com esta condição de pagamento não é possível chegar ao PV 0 sem o preço passar do preço de tabela: antecipe parcelas (mais sinal ou parcelas mais cedo) para melhorar o PV.',
    };
  }
  return series.map((s) => (s.id === serieId ? { ...s, valor } : s));
}

/** Preço nunca acima da tabela: se o arredondamento das parcelas (para cima) passar do preço de tabela,
 *  tira o excedente da última série (financiamento, se houver). A diferença no PV fica em centavos. */
export function limitarAoPreco(cfg: ConfigEmpreendimento, u: Unidade, series: Serie[]): Serie[] {
  const tabela = total(parcelas(cfg, seriesDaTabela(cfg, u)));
  const excesso = series.reduce((t, s) => t + s.valor * s.qtd, 0) - tabela;
  if (excesso <= 0.005) return series;
  const alvo = series.find((s) => s.periodicidade === 'Financiamento' && s.qtd >= 1) ?? [...series].reverse().find((s) => s.qtd >= 1);
  if (!alvo) return series;
  const corte = Math.ceil((excesso / alvo.qtd) * 100) / 100;
  if (corte >= alvo.valor) return series;
  return series.map((s) => (s.id === alvo.id ? { ...s, valor: centavos(s.valor - corte) } : s));
}

/** Soma ao ato (primeira série de sinal) o que falta para o sinal cobrir a comissão inteira. */
export function aumentarSinal(series: Serie[], valor: number): Serie[] {
  const ato = series.filter((s) => s.periodicidade === 'Sinal').sort((a, b) => a.vencimento.localeCompare(b.vencimento))[0];
  if (!ato || valor <= 0) return series;
  const extra = centavosAcima(valor / ato.qtd);
  return series.map((s) => (s.id === ato.id ? { ...s, valor: centavos(s.valor + extra) } : s));
}

// ---------------------------------------------------------------------
// Modelos de preenchimento (botões da tela)
// ---------------------------------------------------------------------
let seq = 0;
export const novoId = () => `s${Date.now().toString(36)}${(seq++).toString(36)}`;

export type Modelo = 'tabela' | 'entrega' | 'semestrais' | 'anuais';

export interface OpcoesModelo {
  dia: number; // dia do vencimento: 5, 10, 15, 20...
  hoje: string; // data da proposta
  /** Para semestrais/anuais: % do preço pago até as chaves (sinal incluso); o resto vai para o financiamento. */
  preChaves?: number;
}

/** Primeiro vencimento no mês indicado, nunca antes de hoje (se cair antes, vai para o mês seguinte). */
function vencimentoValido(mes: string, dia: number, hoje: string) {
  const d = dataNoMes(mes, dia);
  return d >= hoje ? d : dataNoMes(somarMeses(mes, 1), dia);
}

export function aplicarModelo(cfg: ConfigEmpreendimento, u: Unidade, modelo: Modelo, op: OpcoesModelo): Serie[] {
  const preco = precoUnidade(cfg, u);
  const tab = cfg.tabelas[u.tabela];
  const mesHoje = op.hoje.slice(0, 7);
  // a proposta anda junto com o calendário da tabela, a partir do mês de hoje
  const deslocamento = Math.max(0, mesesEntre(cfg.mesTabela, mesHoje));
  const mesInicio = (s: SerieTabela) =>
    s.inicio.base === 'venda' ? somarMeses(cfg.mesTabela, s.inicio.meses + deslocamento) : somarMeses(cfg.mesEntrega, s.inicio.meses);

  const daTabela = tab.map((s) => ({
    id: novoId(),
    qtd: s.qtd,
    periodicidade: s.periodicidade,
    // ato: vence hoje; demais: no dia escolhido
    vencimento: s.periodicidade === 'Sinal' && s.inicio.base === 'venda' && s.inicio.meses === 0
      ? op.hoje
      : vencimentoValido(mesInicio(s), op.dia, op.hoje),
    valor: centavosAcima((s.percentual * preco) / s.qtd),
    _ref: s,
  }));

  const limpar = (l: (Serie & { _ref?: SerieTabela })[]): Serie[] => l.map(({ _ref, ...s }) => s);
  if (modelo === 'tabela') return limitarAoPreco(cfg, u, limpar(daTabela));

  const sinais = daTabela.filter((s) => s._ref.periodicidade === 'Sinal');
  const totalSinal = sinais.reduce((s, x) => s + x.valor * x.qtd, 0);
  const fin = daTabela.find((s) => s._ref.periodicidade === 'Financiamento');
  const preChavesTabela = tab.filter((s) => s.periodicidade !== 'Financiamento').reduce((s, x) => s + x.percentual, 0);

  // Mensais / semestrais / anuais: o sinal segue a tabela; "até as chaves" define quanto do
  // preço é pago direto (sinal incluso) e o resto fica no financiamento. A série principal
  // é calculada para o PV ficar zero; com 100% até as chaves não há financiamento.
  const pct = Math.min(1, Math.max(0, op.preChaves ?? preChavesTabela));
  let principal: Serie;
  if (modelo === 'entrega') {
    const mensal = daTabela.find((s) => s._ref.periodicidade === 'Mensais');
    const venc = mensal?.vencimento ?? vencimentoValido(somarMeses(mesHoje, 1), op.dia, op.hoje);
    const qtd = Math.max(1, mesesEntre(venc, cfg.mesEntrega) + 1);
    principal = { id: novoId(), qtd, periodicidade: 'Mensais', vencimento: venc, valor: 0 };
  } else {
    const semestral = tab.find((s) => s.periodicidade === 'Semestrais');
    const mesPrimeira = semestral ? mesInicio(semestral) : somarMeses(mesHoje, 6);
    const passo = modelo === 'anuais' ? 12 : 6;
    const vencimento = vencimentoValido(mesPrimeira, op.dia, op.hoje);
    const qtd = Math.max(1, Math.floor(mesesEntre(vencimento, cfg.mesEntrega) / passo) + 1);
    principal = { id: novoId(), qtd, periodicidade: modelo === 'anuais' ? 'Anuais' : 'Semestrais', vencimento, valor: 0 };
  }
  principal.valor = centavosAcima(Math.max(0, preco * pct - totalSinal) / principal.qtd);
  const restoFin = preco * (1 - pct);
  const lista: Serie[] = [...limpar(sinais), principal];
  if (restoFin > 0.005)
    lista.push({
      id: novoId(), qtd: 1, periodicidade: 'Financiamento',
      vencimento: fin?.vencimento ?? dataNoMes(somarMeses(cfg.mesEntrega, 1), op.dia), valor: centavosAcima(restoFin),
    });
  const pvZero = redistribuir(cfg, u, lista, principal.id);
  return limitarAoPreco(cfg, u, 'erro' in pvZero ? lista : 'aviso' in pvZero ? pvZero.series : pvZero);
}

// ---------------------------------------------------------------------
// Formatação
// ---------------------------------------------------------------------
export const fmtReal = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
export const fmtNum = (v: number, casas = 2) => v.toLocaleString('pt-BR', { minimumFractionDigits: casas, maximumFractionDigits: casas });
export const fmtPct = (v: number, casas = 1) => `${(Math.abs(v * 100) < 0.5 * 10 ** -casas ? 0 : v * 100).toLocaleString('pt-BR', { minimumFractionDigits: casas, maximumFractionDigits: casas })}%`;
export const fmtData = (iso: string) => (iso ? `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}` : '—');
export const fmtMes = (mes: string) => {
  const nomes = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
  return `${nomes[mesNum(mes) - 1]}/${mes.slice(0, 4)}`;
};

// ---------------------------------------------------------------------
// Proposta conjunta (várias unidades numa simulação só)
// ---------------------------------------------------------------------
/**
 * Junta as unidades numa "unidade conjunta" para o editor: preço = soma dos preços,
 * área = soma das áreas e tabela = soma dos fluxos de tabela de cada uma.
 */
export function unidadeConjunta(cfg: ConfigEmpreendimento, us: Unidade[]): { cfg: ConfigEmpreendimento; unidade: Unidade } {
  const precos = us.map((u) => precoUnidade(cfg, u));
  const soma = precos.reduce((s, p) => s + p, 0);
  const area = us.reduce((s, u) => s + u.area, 0);
  const mesmaTabela = us.every((u) => u.tabela === us[0].tabela);
  const tabela = mesmaTabela ? us[0].tabela : '__conjunta';
  const tabelas = mesmaTabela ? cfg.tabelas : {
    ...cfg.tabelas,
    __conjunta: us.flatMap((u, i) => cfg.tabelas[u.tabela].map((s) => ({ ...s, percentual: (s.percentual * precos[i]) / soma }))),
  };
  const unidade: Unidade = { numero: us.map((u) => u.numero).join(' + '), area, tipo: '__conjunta', peso: 1, tabela };
  return {
    cfg: { ...cfg, tabelas, precoM2PorTipo: { ...cfg.precoM2PorTipo, __conjunta: soma / area }, unidades: [...cfg.unidades, unidade] },
    unidade,
  };
}

/** Peso de cada unidade no conjunto: o preço de tabela dela ÷ a soma dos preços. */
export function pesosPorPreco(cfg: ConfigEmpreendimento, us: Unidade[]) {
  const precos = us.map((u) => precoUnidade(cfg, u));
  const soma = precos.reduce((s, p) => s + p, 0);
  return precos.map((p) => p / soma);
}

/**
 * Divide as séries da simulação conjunta entre as unidades, pelo peso de cada uma.
 * Mesmas datas, quantidades e periodicidades; cada parcela arredondada em centavos,
 * com a sobra do arredondamento na última unidade (a soma bate com a simulação).
 */
export function distribuir(series: Serie[], pesos: number[]): Serie[][] {
  const c2 = (v: number) => Math.round(v * 100) / 100;
  return pesos.map((w, i) => series.map((s) => {
    const base = c2(s.valor);
    const valor = i < pesos.length - 1 ? c2(base * w) : c2(base - pesos.slice(0, -1).reduce((t, x) => t + c2(base * x), 0));
    return { ...s, id: novoId(), valor };
  }));
}

/** Soma, parcela a parcela, as séries das propostas de um grupo (mesma estrutura em todas). */
export function somarSeries(lista: Serie[][]): Serie[] {
  const [primeira, ...resto] = lista;
  if (!primeira) return [];
  const iguais = resto.every((l) => l.length === primeira.length && l.every((s, i) => s.periodicidade === primeira[i].periodicidade && s.vencimento === primeira[i].vencimento && s.qtd === primeira[i].qtd));
  if (!iguais) return primeira.map((s) => ({ ...s, id: novoId() }));
  return primeira.map((s, i) => ({ ...s, id: novoId(), valor: Math.round(lista.reduce((t, l) => t + l[i].valor, 0) * 100) / 100 }));
}
