// Conferência do motor da proposta contra a planilha Compacto_Studio.xlsm (aba PV)
// Rodar: node --experimental-strip-types testes/proposta.ts
import assert from 'node:assert/strict';
import { COMPACTO_STUDIO as C } from '../src/proposta/compactoStudio.ts';
import * as M from '../src/proposta/motor.ts';

const u = C.unidades.find((x) => x.numero === '1804')!;
const perto = (a: number, b: number, tol = 0.01, msg = '') => assert.ok(Math.abs(a - b) <= tol, `${msg}: ${a} ≠ ${b}`);

// Preço e tabela (planilha: PV!H11, PV!C63, PV!C68:C73)
perto(M.precoUnidade(C, u), 448429.5903134844, 1e-6, 'preço 1804');
perto(M.precoUnidade(C, C.unidades.find((x) => x.numero === '201')!), 405576.25811783335, 1e-6, 'preço 201');
const pt = M.parcelas(C, M.seriesDaTabela(C, u));
perto(M.total(pt), 448429.59, 0.01, 'total tabela');
perto(M.vpl(C, pt), 344568.65289002523, 1e-6, 'VPL tabela');
const esperado = [0.06666666666666668, 0.10509740259740259, 0.1361038961038961, 0.16711038961038954, 0.19811688311688302, 0.26012987012987];
M.captacao(C, pt, pt).slice(0, 6).forEach((m, i) => perto(m.tabela, esperado[i], 1e-9, `captação ${m.rotulo}`));

// Regras novas
const hoje = '2026-11-13';
for (const modelo of ['tabela', 'entrega', 'semestrais', 'anuais'] as const) {
  const s = M.aplicarModelo(C, u, modelo, { dia: 10, hoje });
  const r = M.calcular(C, u, s, { dataMinima: hoje });
  assert.ok(r.diferencaVPL >= 0, `${modelo}: modelo não pode nascer com PV negativo`);
  assert.ok(s.every((x) => x.vencimento >= hoje), `${modelo}: vencimento antes de hoje`);
  const alvo = s.find((x) => x.periodicidade !== 'Sinal' && x.periodicidade !== 'Financiamento')!;
  const ajustado = M.redistribuir(C, u, s, alvo.id);
  assert.ok(!('erro' in ajustado));
  const r2 = M.calcular(C, u, ajustado as M.Serie[], { dataMinima: hoje });
  assert.ok(r2.diferencaVPL >= 0 && r2.diferencaVPL < 1, `${modelo}: PV zero`);
}
const passado = M.aplicarModelo(C, u, 'tabela', { dia: 10, hoje });
passado[0] = { ...passado[0], vencimento: '2026-10-10' };
assert.ok(!M.calcular(C, u, passado, { dataMinima: hoje }).aprovado, 'vencimento antes de hoje bloqueia');
assert.ok(M.calcular(C, u, passado, { dataMinima: '2026-10-01' }).aprovado, 'proposta salva antes pode manter a data');
// 8 semestrais entram todas no fluxo (a planilha só enxergava 7)
const oito: M.Serie[] = [{ id: 'a', qtd: 8, periodicidade: 'Semestrais', vencimento: '2027-03-10', valor: 1000 }];
assert.equal(M.parcelas(C, oito).length, 8);

console.log('ok — motor da proposta confere com a planilha');

// Comissão: sinal de 6% com 70/30 só destaca 4,2%; para 5,25% o sinal precisa de 7,5%
{
  const valor = 400000;
  const ps: M.Parcela[] = [{ serieId: 'a', data: '2026-12-01', mes: 1, mesVP: 1, valor: valor * 0.06, periodicidade: 'Sinal' }];
  const c = M.comissao(ps, valor, 0.0525, 0.7);
  perto(c.maximoPct, 0.042, 1e-9, 'máximo destacável');
  perto(c.sinalNecessarioPct, 0.075, 1e-6, 'sinal necessário');
  perto(c.faltaSinal, 6000, 0.01, 'falta de sinal');
  const s: M.Serie[] = [{ id: 'a', qtd: 1, periodicidade: 'Sinal', vencimento: '2026-12-01', valor: valor * 0.06 }];
  const s2 = M.aumentarSinal(s, c.faltaSinal);
  const c2 = M.comissao(M.parcelas(C, s2), valor, 0.0525, 0.7);
  assert.equal(c2.naoCoberta, 0, 'depois de aumentar o sinal a comissão fica coberta');
  console.log('ok — comissão: sinal 6% destaca no máximo 4,20%; precisa de 7,50%');
}

// Até as chaves: 100% → sem financiamento e PV zero nas mensais; 90% → 10% no financiamento
{
  const hoje = '2026-11-13';
  const preco = M.precoUnidade(C, u);
  for (const pct of [1, 0.9, 0.4]) {
    for (const modelo of ['entrega', 'semestrais', 'anuais'] as const) {
      const s = M.aplicarModelo(C, u, modelo, { dia: 10, hoje, preChaves: pct });
      const fin = s.find((x) => x.periodicidade === 'Financiamento');
      if (pct === 1) assert.equal(fin, undefined, `${modelo} 100%: sem financiamento`);
      else perto(fin!.valor, preco * (1 - pct), 0.01, `${modelo} ${pct}: financiamento`);
      const r = M.calcular(C, u, s, { dataMinima: hoje, diasVencimento: [5, 10, 15, 20] });
      assert.ok(r.diferencaVPL >= 0 && r.diferencaVPL < 1, `${modelo} ${pct}: PV zero (${r.diferencaVPL})`);
      assert.ok(!r.avisos.some((a) => a.texto.startsWith('Vencimento no dia')), `${modelo}: dias permitidos`);
    }
  }
  const s = M.aplicarModelo(C, u, 'tabela', { dia: 10, hoje });
  s[2] = { ...s[2], vencimento: '2027-03-12' };
  const r = M.calcular(C, u, s, { dataMinima: hoje, diasVencimento: [5, 10, 15, 20] });
  assert.ok(r.avisos.some((a) => a.texto === 'Vencimento no dia 12: use dia 05, 10, 15 ou 20.'), 'avisa dia 12');
  console.log('ok — até as chaves 100%/90%/40% com PV zero; aviso de dia de vencimento');
}
