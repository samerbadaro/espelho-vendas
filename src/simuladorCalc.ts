import type { Marca } from './ui';

// ---------------------------------------------------------------------
// Regras (valores nominais, sem valor presente).
// Preços, captação mínima e fluxo padrão vêm de config.simulador
// (editáveis pelo administrador); os valores abaixo são o reserva.
// ---------------------------------------------------------------------
export type Posicao = 'poente' | 'nascente';
export type Referencia = 'a_partir' | 'medio';
export type K = 'ato' | 'sinal' | 'mensais' | 'periodicas' | 'unica';
export type Periodo = 'semestral' | 'anual';
export interface ConfPosicao { a_partir: number; medio: number; captacao: number; pct: Record<K, number> }
export type ConfSimulador = Record<Posicao, ConfPosicao>;

export const RESERVA: ConfSimulador = {
  poente: { a_partir: 405576.26, medio: 427575.76, captacao: 30, pct: { ato: 4, sinal: 4, mensais: 6, periodicas: 12, unica: 4 } },
  nascente: { a_partir: 405576.26, medio: 427575.76, captacao: 35, pct: { ato: 4, sinal: 4, mensais: 6.5, periodicas: 15.5, unica: 5 } },
};
export const POSICOES: Record<Posicao, string> = { poente: 'Poente', nascente: 'Nascente' };
export const REFERENCIAS: Record<Referencia, string> = { a_partir: 'A partir de', medio: 'Preço médio' };
/** Referências oferecidas ao corretor. Hoje só "a partir de"; o preço médio fica guardado, mas fora da tela. */
export const REFS: Referencia[] = ['a_partir'];
export const ORDEM: K[] = ['ato', 'sinal', 'mensais', 'periodicas', 'unica'];
export const ROTULO: Record<K, string> = { ato: 'Sinal (ato)', sinal: 'Sinal (30/60/90)', mensais: 'Mensais', periodicas: 'Semestrais', unica: 'Única' };
export const QTD_MAX: Record<K, number> = { ato: 1, sinal: 3, mensais: 43, periodicas: 7, unica: 1 };
export const PERIODICAS_MAX: Record<Periodo, number> = { semestral: 7, anual: 3 };
/** De onde sai (e para onde volta) o percentual quando uma série muda. O financiamento nunca entra. */
const FONTES: Record<K, K[]> = {
  mensais: ['periodicas', 'unica'],
  periodicas: ['mensais', 'unica'],
  ato: ['mensais', 'periodicas'],
  sinal: ['mensais', 'periodicas'],
  unica: ['mensais', 'periodicas'],
};
export const PASSO = 0.5;
/** A única nunca passa de 5% do preço. */
export const UNICA_MAX = 5;

export const r2 = (v: number) => Math.round(v * 100) / 100;
export const brl = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL', minimumFractionDigits: 0, maximumFractionDigits: 0 });
export const brl2 = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
export const pctFmt = (v: number) => `${v.toLocaleString('pt-BR', { minimumFractionDigits: 0, maximumFractionDigits: 2 })}%`;
export const soma = (p: Record<K, number>) => r2(ORDEM.reduce((a, k) => a + p[k], 0));

export function lerConf(m: Marca): ConfSimulador {
  const c = (m as Marca & { simulador?: Partial<ConfSimulador> }).simulador;
  const pos = (k: Posicao): ConfPosicao => ({ ...RESERVA[k], ...(c?.[k] ?? {}), pct: { ...RESERVA[k].pct, ...(c?.[k]?.pct ?? {}) } });
  return { poente: pos('poente'), nascente: pos('nascente') };
}

export interface Linha { k: K | 'financiamento'; rotulo: string; qtd: number; pct: number; parcela: number; total: number }

/**
 * Parcelas em reais inteiros. O financiamento é sempre (100 − captação)% do preço, fixo.
 * A sobra do arredondamento de cada série vai para as mensais; os centavos que restam
 * vão para o ato (ou a única), para o total fechar no preço sem mexer no financiamento.
 */
export function calcular(preco: number, pct: Record<K, number>, qtd: Record<K, number>, periodo: Periodo) {
  const fin = Math.max(0, r2(100 - soma(pct)));
  const financiamento = r2((preco * fin) / 100);
  const alvo = (k: K) => (preco * pct[k]) / 100;
  const tot = {} as Record<K, { parcela: number; total: number }>;
  let sobra = 0;
  for (const k of ['ato', 'sinal', 'periodicas', 'unica'] as K[]) {
    const parcela = pct[k] > 0 ? Math.floor(alvo(k) / qtd[k]) : 0;
    tot[k] = { parcela, total: parcela * qtd[k] };
    sobra += alvo(k) - tot[k].total;
  }
  const alvoMensais = alvo('mensais') + (pct.mensais > 0 ? sobra : 0);
  const pm = alvoMensais > 0 ? Math.floor(alvoMensais / qtd.mensais) : 0;
  tot.mensais = { parcela: pm, total: pm * qtd.mensais };
  const resto = r2(preco - financiamento - ORDEM.reduce((a, k) => a + tot[k].total, 0));
  const recebe: K | undefined = (['ato', 'unica'] as K[]).find((k) => pct[k] > 0);
  let fTotal = financiamento;
  if (recebe) tot[recebe] = { parcela: r2(tot[recebe].parcela + resto), total: r2(tot[recebe].total + resto) };
  else fTotal = r2(fTotal + resto);
  const linhas: Linha[] = ORDEM.filter((k) => tot[k].total > 0).map((k) => ({
    k, rotulo: k === 'periodicas' ? (periodo === 'anual' ? 'Anuais' : 'Semestrais') : ROTULO[k],
    qtd: qtd[k], pct: pct[k], parcela: tot[k].parcela, total: tot[k].total,
  }));
  linhas.push({ k: 'financiamento', rotulo: 'Financiamento', qtd: fTotal > 0 ? 1 : 0, pct: fin, parcela: fTotal, total: fTotal });
  return { linhas, captacao: r2(100 - fin), fin };
}

/**
 * A captação (e portanto o financiamento) nunca muda: o que uma série ganha, outra perde.
 * Mensais ↔ semestrais/anuais: ao subir uma, sai primeiro da outra série e depois da única;
 * ao descer, volta para a outra série e para a única até o padrão, e o resto fica na outra série.
 * Ato, sinal e única se compensam com as mensais e depois com as periódicas.
 * Se não houver de onde tirar, a série para no máximo possível. A única fica limitada a UNICA_MAX.
 */
export function ajustarPct(p: Record<K, number>, k: K, valor: number, padrao: Record<K, number>) {
  const teto = k === 'unica' ? UNICA_MAX : 100;
  const novo = Math.max(0, Math.min(teto, r2(valor)));
  let delta = r2(novo - p[k]);
  if (delta === 0) return p;
  const n = { ...p };
  const fontes = FONTES[k];
  if (delta > 0) {
    for (const f of fontes) {
      const tira = Math.min(delta, n[f]);
      n[f] = r2(n[f] - tira); n[k] = r2(n[k] + tira); delta = r2(delta - tira);
    }
  } else {
    delta = -delta;
    n[k] = r2(n[k] - delta);
    for (const f of fontes) {
      const alvo = f === 'unica' ? Math.min(padrao.unica, UNICA_MAX) : padrao[f];
      const devolve = Math.min(delta, Math.max(0, r2(alvo - n[f])));
      n[f] = r2(n[f] + devolve); delta = r2(delta - devolve);
    }
    const resto = fontes.find((f) => f !== 'unica') as K;
    n[resto] = r2(n[resto] + delta);
  }
  return n;
}

/** Ajusta o fluxo padrão para somar exatamente a captação (mexendo nas mensais e depois nas periódicas). */
export function normalizar(pct: Record<K, number>, captacao: number) {
  const n = { ...pct };
  let dif = r2(captacao - soma(n));
  for (const f of ['mensais', 'periodicas', 'sinal', 'ato'] as K[]) {
    if (dif === 0) break;
    const muda = dif > 0 ? dif : -Math.min(-dif, n[f]);
    n[f] = r2(n[f] + muda); dif = r2(dif - muda);
  }
  return n;
}

