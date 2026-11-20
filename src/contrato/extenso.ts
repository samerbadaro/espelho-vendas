// Números e valores por extenso (português do Brasil), para o contrato.
const UN = ['zero', 'um', 'dois', 'três', 'quatro', 'cinco', 'seis', 'sete', 'oito', 'nove', 'dez', 'onze', 'doze', 'treze',
  'quatorze', 'quinze', 'dezesseis', 'dezessete', 'dezoito', 'dezenove'];
const DEZ = ['', '', 'vinte', 'trinta', 'quarenta', 'cinquenta', 'sessenta', 'setenta', 'oitenta', 'noventa'];
const CEM = ['', 'cento', 'duzentos', 'trezentos', 'quatrocentos', 'quinhentos', 'seiscentos', 'setecentos', 'oitocentos', 'novecentos'];

function ate999(n: number): string {
  if (n === 100) return 'cem';
  const c = Math.floor(n / 100), r = n % 100, d = Math.floor(r / 10), u = r % 10;
  const partes: string[] = [];
  if (c) partes.push(CEM[c]);
  if (r) partes.push(r < 20 ? UN[r] : DEZ[d] + (u ? ` e ${UN[u]}` : ''));
  return partes.join(' e ');
}

/** Inteiro por extenso (masculino): 1234 → "mil duzentos e trinta e quatro". */
export function extensoInteiro(n: number): string {
  n = Math.floor(Math.abs(n));
  if (n === 0) return 'zero';
  const grupos: number[] = [];
  while (n > 0) { grupos.push(n % 1000); n = Math.floor(n / 1000); }
  const nomes = [['', ''], ['mil', 'mil'], ['milhão', 'milhões'], ['bilhão', 'bilhões']];
  const partes: { txt: string; v: number }[] = [];
  for (let i = grupos.length - 1; i >= 0; i--) {
    const g = grupos[i];
    if (!g) continue;
    const base = i === 1 && g === 1 ? '' : ate999(g);
    const nome = nomes[i][g === 1 ? 0 : 1];
    partes.push({ txt: [base, nome].filter(Boolean).join(' '), v: g });
  }
  // "e" antes do último grupo quando ele é < 100 ou centena redonda
  return partes.map((p, k) => (k > 0 && k === partes.length - 1 && (p.v < 100 || p.v % 100 === 0) ? 'e ' : '') + p.txt).join(' ').replace(/\s+/g, ' ');
}

/** Valor em reais por extenso: 1234.5 → "mil duzentos e trinta e quatro reais e cinquenta centavos". */
export function extensoReais(v: number): string {
  const centavos = Math.round(Math.abs(v) * 100);
  const reais = Math.floor(centavos / 100), cent = centavos % 100;
  const partes: string[] = [];
  if (reais) {
    const milhaoRedondo = reais >= 1_000_000 && reais % 1_000_000 === 0;
    partes.push(`${extensoInteiro(reais)}${milhaoRedondo ? ' de' : ''} ${reais === 1 ? 'real' : 'reais'}`);
  }
  if (cent) partes.push(`${extensoInteiro(cent)} ${cent === 1 ? 'centavo' : 'centavos'}`);
  return partes.length ? partes.join(' e ') : 'zero real';
}

/** "05 (cinco)" — quantidade com dois dígitos e por extenso (feminino para "parcelas"). */
export function qtdExtenso(n: number, feminino = true): string {
  let t = extensoInteiro(n);
  if (feminino) t = t.replace(/\bum\b/g, 'uma').replace(/\bdois\b/g, 'duas').replace(/entos\b/g, 'entas');
  return `${String(n).padStart(2, '0')} (${t})`;
}
