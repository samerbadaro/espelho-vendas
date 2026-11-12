// Motor de cálculo da proposta (v2).
// Reproduz a planilha "Compacto_Studio.xlsm" (abas Padrões, PV, FluxoTabela,
// Proposta e Comparativo). Funções puras, sem acesso a banco, para poderem
// rodar tanto na tela quanto no servidor e serem testadas contra a planilha.

/** Mês como índice inteiro: ano * 12 + (mês - 1). */
export type Mes = number;

export const mes = (ano: number, m: number): Mes => ano * 12 + (m - 1);
export const mesDeData = (d: Date | string): Mes => {
  const x = typeof d === 'string' ? new Date(d + (d.length === 10 ? 'T12:00:00' : '')) : d;
  return mes(x.getFullYear(), x.getMonth() + 1);
};
export const rotuloMes = (m: Mes) => `${String((m % 12) + 1).padStart(2, '0')}/${Math.floor(m / 12)}`;

export type Periodicidade = 'sinal' | 'mensal' | 'semestral' | 'anual' | 'unica';

export const PASSO: Record<Periodicidade, number> = {
  sinal: 1, mensal: 1, semestral: 6, anual: 12, unica: 1,
};

// ---------------------------------------------------------------- empreendimento

export interface Empreendimento {
  /** Mês-base da tabela (Padrões!D5). Todo valor presente é trazido para cá. */
  mesTabela: Mes;
  /** Mês de entrega das chaves (Padrões!D6). */
  entrega: Mes;
  /** Taxa de desconto mensal do valor presente (Padrões!D7), ex.: 0.007. */
  taxaVP: number;
}

/** Preço da unidade (Padrões, coluna I). */
export function precoUnidade(p: {
  m2Grupo: number;        // R$/m² do grupo no mês (Padrões F/H/J… da linha do mês)
  peso: number;           // peso da unidade (andar/posição)
  mediaPesoGrupo: number; // média dos pesos das unidades do grupo
  area: number;           // área privativa
  escaninho?: number;     // área de escaninho
  vaga?: number;          // valor fixo da vaga, se houver
}): number {
  return (p.m2Grupo * p.peso * (p.area + (p.escaninho ?? 0))) / p.mediaPesoGrupo + (p.vaga ?? 0);
}

// ---------------------------------------------------------------- tabela de vendas

export interface SerieTabela {
  nome: string;             // "Ato", "30/60/90", "Mensais"…
  tipo: Periodicidade;
  parcelas: number;
  percentual: number;       // percentual da série inteira sobre o preço (0.06 = 6%)
  /** Início relativo à venda (mês da tabela) ou à entrega, em meses. */
  inicio: { base: 'venda' | 'entrega'; deslocamento: number };
  posChaves?: boolean;      // financiamento / pós-chaves
}

export interface Parcela {
  serie: string;
  tipo: Periodicidade;
  mes: Mes;
  valor: number;
  posChaves: boolean;
}

export function inicioSerie(s: SerieTabela, e: Empreendimento): Mes {
  return (s.inicio.base === 'venda' ? e.mesTabela : e.entrega) + s.inicio.deslocamento;
}

/** Fluxo da tabela para um preço (FluxoTabela). */
export function fluxoTabela(preco: number, series: SerieTabela[], e: Empreendimento): Parcela[] {
  const out: Parcela[] = [];
  for (const s of series) {
    if (!s.parcelas || !s.percentual) continue;
    const valor = (preco * s.percentual) / s.parcelas;
    const ini = inicioSerie(s, e);
    for (let k = 0; k < s.parcelas; k++) {
      out.push({ serie: s.nome, tipo: s.tipo, mes: ini + k * PASSO[s.tipo], valor, posChaves: !!s.posChaves });
    }
  }
  return out;
}

// ---------------------------------------------------------------- proposta

export interface SerieProposta {
  tipo: Periodicidade;
  parcelas: number;
  /** Data do 1º vencimento (AAAA-MM-DD). */
  primeiroVencimento: string;
  valorParcela: number;
  posChaves?: boolean;
  /** % de comissão retido nesta série (modo manual, como na planilha). */
  comissaoPct?: number;
}

export function fluxoProposta(series: SerieProposta[]): Parcela[] {
  const out: Parcela[] = [];
  series.forEach((s, i) => {
    const ini = mesDeData(s.primeiroVencimento);
    for (let k = 0; k < s.parcelas; k++) {
      out.push({
        serie: `${i + 1}`, tipo: s.tipo, mes: ini + k * PASSO[s.tipo],
        valor: s.valorParcela, posChaves: !!s.posChaves,
      });
    }
  });
  return out;
}

export const total = (f: Parcela[]) => f.reduce((a, p) => a + p.valor, 0);

// ---------------------------------------------------------------- valor presente

/**
 * Valor presente "securitizado" (PV!C63 / Comparativo coluna E):
 * todo o pós-chaves é considerado recebido no mês seguinte à entrega;
 * o mês da tabela não é descontado, os demais são descontados à taxa mensal.
 */
export function valorPresente(f: Parcela[], e: Empreendimento): number {
  const recebimento = e.entrega + 1;
  let vp = 0;
  for (const p of f) {
    const m = p.posChaves ? recebimento : p.mes;
    const n = Math.max(0, m - e.mesTabela);
    vp += p.valor / Math.pow(1 + e.taxaVP, n);
  }
  return vp;
}

// ---------------------------------------------------------------- comparação

export interface Comparacao {
  totalTabela: number;
  totalProposta: number;
  vpTabela: number;
  vpProposta: number;
  variacaoVP: number;        // vpProposta / vpTabela - 1
  diferencaVP: number;       // R$
  captacaoPreChaves: number; // % do total da proposta pago até as chaves
  /** Percentual do total recebido até cada horizonte, tabela x proposta (PV!B68:F74). */
  horizontes: { rotulo: string; tabela: number; proposta: number; variacao: number }[];
}

const HORIZONTES: [string, number | 'entrega'][] = [
  ['3 meses', 3], ['6 meses', 6], ['12 meses', 12], ['18 meses', 18],
  ['24 meses', 24], ['36 meses', 36], ['Até a entrega', 'entrega'],
];

function acumulado(f: Parcela[], e: Empreendimento, ateMes: Mes) {
  const t = total(f);
  if (!t) return 0;
  const rec = e.entrega + 1;
  return f.filter(p => (p.posChaves ? rec : p.mes) <= ateMes).reduce((a, p) => a + p.valor, 0) / t;
}

export function comparar(tabela: Parcela[], proposta: Parcela[], e: Empreendimento): Comparacao {
  const vpT = valorPresente(tabela, e);
  const vpP = valorPresente(proposta, e);
  const tP = total(proposta);
  return {
    totalTabela: total(tabela),
    totalProposta: tP,
    vpTabela: vpT,
    vpProposta: vpP,
    variacaoVP: vpT ? vpP / vpT - 1 : 0,
    diferencaVP: vpP - vpT,
    captacaoPreChaves: tP ? proposta.filter(p => !p.posChaves).reduce((a, p) => a + p.valor, 0) / tP : 0,
    horizontes: HORIZONTES.map(([rotulo, h]) => {
      // a planilha conta os horizontes em linhas do fluxo, começando no mês da tabela
      const ate = h === 'entrega' ? e.entrega : e.mesTabela + h - 1;
      const t = acumulado(tabela, e, ate);
      const p = acumulado(proposta, e, ate);
      return { rotulo, tabela: t, proposta: p, variacao: t ? p / t - 1 : 0 };
    }),
  };
}

// ---------------------------------------------------------------- validações

export interface RegrasValidacao {
  /** Quanto o VP da proposta pode ficar abaixo do da tabela sem aprovação (0 = nada). */
  toleranciaVP: number;
  /** Dias de vencimento aceitos para parcelas que não são sinal. */
  diasVencimento: number[];
  /** Queda máxima aceita no recebimento acumulado por horizonte (0.15 = 15%). */
  quedaMaxHorizonte: number;
  /** Meses de folga, após a entrega, para terminar as séries pré-chaves. */
  folgaPreChaves: number;
}

export const REGRAS_PADRAO: RegrasValidacao = {
  toleranciaVP: 0,
  diasVencimento: [5, 10, 15, 20],
  quedaMaxHorizonte: 0.15,
  folgaPreChaves: 2,
};

export interface Alerta { nivel: 'erro' | 'aprovacao' | 'aviso'; texto: string }

export function validar(
  series: SerieProposta[], cmp: Comparacao, e: Empreendimento,
  hoje: string, regras: RegrasValidacao = REGRAS_PADRAO,
): Alerta[] {
  const a: Alerta[] = [];
  if (cmp.variacaoVP < -regras.toleranciaVP - 1e-9) {
    a.push({ nivel: 'aprovacao', texto: `Valor presente ${(cmp.variacaoVP * 100).toFixed(2)}% abaixo da tabela.` });
  }
  series.forEach((s, i) => {
    const n = i + 1;
    const dia = Number(s.primeiroVencimento.slice(8, 10));
    if (s.tipo === 'sinal' && s.primeiroVencimento < hoje) {
      a.push({ nivel: 'erro', texto: `Série ${n}: sinal com vencimento no passado.` });
    }
    if (s.tipo !== 'sinal' && !regras.diasVencimento.includes(dia)) {
      a.push({ nivel: 'erro', texto: `Série ${n}: vencimento no dia ${dia}; use ${regras.diasVencimento.join(', ')}.` });
    }
    const fim = mesDeData(s.primeiroVencimento) + (s.parcelas - 1) * PASSO[s.tipo];
    if (!s.posChaves && fim > e.entrega + regras.folgaPreChaves) {
      a.push({ nivel: 'erro', texto: `Série ${n}: termina em ${rotuloMes(fim)}, depois das chaves.` });
    }
    if (s.posChaves && mesDeData(s.primeiroVencimento) <= e.entrega) {
      a.push({ nivel: 'erro', texto: `Série ${n}: financiamento antes da entrega.` });
    }
  });
  for (const h of cmp.horizontes) {
    if (h.variacao < -regras.quedaMaxHorizonte) {
      a.push({ nivel: 'aviso', texto: `${h.rotulo}: recebimento ${(h.variacao * 100).toFixed(0)}% menor que a tabela.` });
    }
  }
  return a;
}

// ---------------------------------------------------------------- comissão

/**
 * Regras de destaque da comissão dentro do sinal.
 * - proporcional: cada parcela do sinal é dividida (ex.: 70% comissão / 30% incorporador)
 *   até a comissão total ser atingida; depois, tudo vai para o incorporador.
 * - retencao: o incorporador retém um valor da 1ª parcela (ex.: 1% do preço) e
 *   o restante do sinal vai para a comissão até atingir o total.
 */
export type RegraComissao =
  | { tipo: 'proporcional'; pctComissaoNaParcela: number }
  | { tipo: 'retencao'; retencaoPctPreco: number };

export interface DestaqueParcela {
  mes: Mes; valor: number; comissao: number; incorporador: number;
}

export function destacarComissao(
  sinal: { mes: Mes; valor: number }[], preco: number, pctComissao: number, regra: RegraComissao,
): { comissaoTotal: number; parcelas: DestaqueParcela[]; faltando: number } {
  const comissaoTotal = preco * pctComissao;
  let resta = comissaoTotal;
  const parcelas = [...sinal].sort((x, y) => x.mes - y.mes).map((p, i) => {
    let disponivel: number;
    if (regra.tipo === 'proporcional') disponivel = p.valor * regra.pctComissaoNaParcela;
    else disponivel = i === 0 ? Math.max(0, p.valor - preco * regra.retencaoPctPreco) : p.valor;
    const c = Math.min(resta, disponivel);
    resta -= c;
    return { mes: p.mes, valor: p.valor, comissao: c, incorporador: p.valor - c };
  });
  return { comissaoTotal, parcelas, faltando: Math.max(0, resta) };
}
