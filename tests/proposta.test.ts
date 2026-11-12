// Confere o motor contra os números da planilha Compacto_Studio.xlsm.
// Rodar: npm run teste:proposta
import {
  mes, precoUnidade, fluxoTabela, fluxoProposta, valorPresente, comparar, validar,
  destacarComissao, total, type SerieTabela, type Empreendimento,
} from '../src/proposta/calculo.ts';

let ok = 0, falhas = 0;
function igual(nome: string, obtido: number, esperado: number, tol = 0.01) {
  if (Math.abs(obtido - esperado) <= tol) { ok++; return; }
  falhas++; console.log(`FALHOU ${nome}: obtido ${obtido}, esperado ${esperado}`);
}
function verdade(nome: string, cond: boolean) { if (cond) ok++; else { falhas++; console.log(`FALHOU ${nome}`); } }

const emp: Empreendimento = { mesTabela: mes(2026, 11), entrega: mes(2030, 10), taxaVP: 0.007 };

// Preço da unidade 1804 (grupo II, R$ 12.500/m², peso 0,9675, média do grupo 0,94203125)
const preco = precoUnidade({ m2Grupo: 12500, peso: 0.9675, mediaPesoGrupo: 0.94203125, area: 34.93 });
igual('preço 1804', preco, 448429.5903134844);

// Tabela como a aba PV aplica hoje (percentuais da Tabela 1, prazos da Tabela 3)
const tabela: SerieTabela[] = [
  { nome: 'Ato', tipo: 'sinal', parcelas: 1, percentual: 0.04, inicio: { base: 'venda', deslocamento: 0 } },
  { nome: '30/60/90', tipo: 'sinal', parcelas: 3, percentual: 0.04, inicio: { base: 'venda', deslocamento: 1 } },
  { nome: 'Mensais', tipo: 'mensal', parcelas: 44, percentual: 0.06, inicio: { base: 'venda', deslocamento: 4 } },
  { nome: 'Semestrais', tipo: 'semestral', parcelas: 7, percentual: 0.12, inicio: { base: 'venda', deslocamento: 5 } },
  { nome: 'Única', tipo: 'unica', parcelas: 1, percentual: 0.04, inicio: { base: 'entrega', deslocamento: -3 } },
  { nome: 'Financiamento', tipo: 'unica', parcelas: 1, percentual: 0.70, inicio: { base: 'entrega', deslocamento: 1 }, posChaves: true },
];
const ft = fluxoTabela(preco, tabela, emp);
igual('total da tabela (PV!I26)', total(ft), 448429.5903134844);
igual('mensal (PV!G20)', ft.find(p => p.serie === 'Mensais')!.valor, 611.4948958820241);
igual('semestral (PV!G21)', ft.find(p => p.serie === 'Semestrais')!.valor, 7687.364405374019);
igual('VP da tabela (PV!C63)', valorPresente(ft, emp), 342011.62230460165);

// Recebimento acumulado da tabela por horizonte (PV!C68:C73)
const cmp0 = comparar(ft, ft, emp);
const esperado = [0.06666666666666665, 0.09987012987012985, 0.12519480519480516,
  0.15051948051948047, 0.17584415584415586, 0.22649350649350664];
esperado.forEach((v, i) => igual(`horizonte ${cmp0.horizontes[i].rotulo}`, cmp0.horizontes[i].tabela, v, 1e-9));
igual('proposta igual à tabela: variação 0', cmp0.variacaoVP, 0, 1e-12);

// Proposta: mesma soma, porém com sinal menor e mais peso no fim → VP cai
const prop = fluxoProposta([
  { tipo: 'sinal', parcelas: 1, primeiroVencimento: '2026-11-20', valorParcela: 10000, comissaoPct: 0.05 },
  { tipo: 'mensal', parcelas: 46, primeiroVencimento: '2026-12-10', valorParcela: 1500 },
  { tipo: 'unica', parcelas: 1, primeiroVencimento: '2030-11-10', valorParcela: 448429.59 - 10000 - 69000, posChaves: true },
]);
const cmp = comparar(ft, prop, emp);
igual('total da proposta', cmp.totalProposta, 448429.59);
verdade('VP da proposta abaixo da tabela', cmp.vpProposta < cmp.vpTabela);
const alertas = validar([
  { tipo: 'sinal', parcelas: 1, primeiroVencimento: '2026-11-20', valorParcela: 10000 },
  { tipo: 'mensal', parcelas: 50, primeiroVencimento: '2026-12-12', valorParcela: 1500 },
], cmp, emp, '2026-11-17');
verdade('pede aprovação por VP', alertas.some(a => a.nivel === 'aprovacao'));
verdade('acusa dia 12', alertas.some(a => a.texto.includes('dia 12')));
verdade('acusa série depois das chaves', alertas.some(a => a.texto.includes('depois das chaves')));

// Comissão de 5% sobre R$ 400.000 = R$ 20.000
const sinal = [{ mes: 0, valor: 16000 }, { mes: 1, valor: 8000 }, { mes: 2, valor: 8000 }];
const p70 = destacarComissao(sinal, 400000, 0.05, { tipo: 'proporcional', pctComissaoNaParcela: 0.7 });
igual('70/30: 1ª parcela comissão', p70.parcelas[0].comissao, 11200);
igual('70/30: 2ª parcela comissão', p70.parcelas[1].comissao, 5600);
igual('70/30: 3ª parcela completa o total', p70.parcelas[2].comissao, 3200);
igual('70/30: nada faltando', p70.faltando, 0);
const ret = destacarComissao(sinal, 400000, 0.05, { tipo: 'retencao', retencaoPctPreco: 0.01 });
igual('retenção: incorporador fica com 1% na 1ª', ret.parcelas[0].incorporador, 4000);
igual('retenção: 1ª parcela comissão', ret.parcelas[0].comissao, 12000);
igual('retenção: 2ª completa', ret.parcelas[1].comissao, 8000);
igual('retenção: 3ª toda do incorporador', ret.parcelas[2].incorporador, 8000);
const curto = destacarComissao([{ mes: 0, valor: 10000 }], 400000, 0.05, { tipo: 'proporcional', pctComissaoNaParcela: 0.8 });
igual('sinal insuficiente: falta', curto.faltando, 12000);

console.log(`${ok} conferências ok, ${falhas} falha(s)`);
if (falhas) process.exit(1);
