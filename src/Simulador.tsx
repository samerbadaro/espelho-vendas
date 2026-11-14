import { useMemo, useState } from 'react';
import { Download, FileDown, RotateCcw, Minus, Plus } from 'lucide-react';
import { useMarca, type Marca } from './ui';
import type { Perfil } from './util';

// ---------------------------------------------------------------------
// Regras do fluxo de pagamento (valores nominais, sem valor presente).
// Para mudar preços ou percentuais, edite só este bloco.
// ---------------------------------------------------------------------
const PRECOS = {
  a_partir: { rotulo: 'A partir de', valor: 405576.26 },
  medio: { rotulo: 'Preço médio', valor: 427575.76 },
} as const;
type ChavePreco = keyof typeof PRECOS;

type ChaveSerie = 'ato' | 'sinal' | 'mensais' | 'semestrais' | 'unica';
interface Serie { k: ChaveSerie; rotulo: string; qtdMin: number; qtdMax: number }
const SERIES: Serie[] = [
  { k: 'ato', rotulo: 'Sinal (ato)', qtdMin: 1, qtdMax: 1 },
  { k: 'sinal', rotulo: 'Sinal (30/60/90)', qtdMin: 1, qtdMax: 3 },
  { k: 'mensais', rotulo: 'Mensais', qtdMin: 1, qtdMax: 43 },
  { k: 'semestrais', rotulo: 'Semestrais', qtdMin: 1, qtdMax: 7 },
  { k: 'unica', rotulo: 'Única', qtdMin: 1, qtdMax: 1 },
];

const FLUXOS = {
  poente: { rotulo: 'Poente', captacao: 30, pct: { ato: 4, sinal: 4, mensais: 6, semestrais: 12, unica: 4 } },
  nascente: { rotulo: 'Nascente', captacao: 35, pct: { ato: 4, sinal: 4, mensais: 6.5, semestrais: 15.5, unica: 5 } },
} as const;
type ChaveFluxo = keyof typeof FLUXOS;

const QTD_PADRAO: Record<ChaveSerie, number> = { ato: 1, sinal: 3, mensais: 43, semestrais: 7, unica: 1 };
const PASSO = 0.5;

const brl = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL', minimumFractionDigits: 0, maximumFractionDigits: 0 });
const brl2 = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
const pctFmt = (v: number) => `${v.toLocaleString('pt-BR', { minimumFractionDigits: 0, maximumFractionDigits: 2 })}%`;
const arred = (v: number) => Math.round(v * 100) / 100;

interface Linha { k: ChaveSerie | 'financiamento'; rotulo: string; qtd: number; pct: number; parcela: number; total: number }

/** Monta as parcelas: cada série em reais inteiros; o financiamento absorve a sobra dos arredondamentos. */
function calcular(preco: number, pct: Record<ChaveSerie, number>, qtd: Record<ChaveSerie, number>) {
  const linhas: Linha[] = SERIES.filter((s) => pct[s.k] > 0).map((s) => {
    const parcela = Math.round((preco * pct[s.k]) / 100 / qtd[s.k]);
    return { k: s.k, rotulo: s.rotulo, qtd: qtd[s.k], pct: pct[s.k], parcela, total: parcela * qtd[s.k] };
  });
  const captacao = arred(SERIES.reduce((a, s) => a + pct[s.k], 0));
  const fin = arred(preco - linhas.reduce((a, l) => a + l.total, 0));
  linhas.push({ k: 'financiamento', rotulo: 'Financiamento', qtd: 1, pct: arred(100 - captacao), parcela: fin, total: fin });
  return { linhas, captacao };
}

export function Simulador({ perfil }: { perfil: Perfil }) {
  const { marca } = useMarca();
  const [fluxo, setFluxo] = useState<ChaveFluxo | null>(null);
  const [preco, setPreco] = useState<ChavePreco>('a_partir');
  const [pct, setPct] = useState<Record<ChaveSerie, number>>({ ...FLUXOS.poente.pct });
  const [qtd, setQtd] = useState<Record<ChaveSerie, number>>({ ...QTD_PADRAO });
  const [gerando, setGerando] = useState('');

  const escolherFluxo = (f: ChaveFluxo) => { setFluxo(f); setPct({ ...FLUXOS[f].pct }); setQtd({ ...QTD_PADRAO }); };
  const restaurar = () => fluxo && escolherFluxo(fluxo);

  const valor = PRECOS[preco].valor;
  const { linhas, captacao } = useMemo(() => calcular(valor, pct, qtd), [valor, pct, qtd]);
  const minimo = fluxo ? FLUXOS[fluxo].captacao : 0;
  const abaixo = captacao < minimo - 1e-9;
  const acima = captacao > 100 + 1e-9;
  const problema = abaixo
    ? `A captação está em ${pctFmt(captacao)}. O mínimo para ${FLUXOS[fluxo!].rotulo} é ${minimo}%: faltam ${pctFmt(arred(minimo - captacao))}.`
    : acima ? 'A soma das séries passou de 100%. Diminua alguma série.' : '';

  const mudaPct = (k: ChaveSerie, v: number) => setPct((p) => ({ ...p, [k]: Math.max(0, Math.min(100, arred(Math.round(v / 0.01) * 0.01))) }));
  const mudaQtd = (s: Serie, v: number) => setQtd((q) => ({ ...q, [s.k]: Math.max(s.qtdMin, Math.min(s.qtdMax, Math.round(v))) }));

  const baixar = async (formato: 'png' | 'pdf') => {
    if (!fluxo || problema) return;
    setGerando(formato);
    try {
      const canvas = await desenhar({ marca, fluxo: FLUXOS[fluxo].rotulo, precoRotulo: PRECOS[preco].rotulo, valor, linhas, captacao, autor: perfil.nome || '' });
      const nome = `simulacao-${FLUXOS[fluxo].rotulo.toLowerCase()}-${new Date().toISOString().slice(0, 10)}`;
      if (formato === 'png') {
        const a = document.createElement('a');
        a.href = canvas.toDataURL('image/png'); a.download = `${nome}.png`; a.click();
      } else {
        const { jsPDF } = await import('jspdf');
        const doc = new jsPDF({ unit: 'mm', format: [108, 192] });
        doc.addImage(canvas.toDataURL('image/jpeg', 0.92), 'JPEG', 0, 0, 108, 192);
        doc.save(`${nome}.pdf`);
      }
    } finally { setGerando(''); }
  };

  if (!fluxo) {
    return (
      <div className="cartao simulador">
        <h3>Simulador de pagamento</h3>
        <p className="sub">Escolha a posição da unidade e a referência de preço. O simulador monta o fluxo padrão e você ajusta como quiser.</p>
        <div className="sim-escolha">
          <div>
            <span className="sim-rotulo">Referência de preço</span>
            <div className="segmentado">
              {(Object.keys(PRECOS) as ChavePreco[]).map((k) => (
                <button key={k} className={preco === k ? 'ativo' : ''} onClick={() => setPreco(k)}>{PRECOS[k].rotulo}<small>{brl2(PRECOS[k].valor)}</small></button>
              ))}
            </div>
          </div>
          <div>
            <span className="sim-rotulo">Posição</span>
            <div className="sim-fluxos">
              {(Object.keys(FLUXOS) as ChaveFluxo[]).map((k) => (
                <button key={k} className="sim-fluxo" onClick={() => escolherFluxo(k)}>
                  <strong>{FLUXOS[k].rotulo}</strong>
                  <span>Captação mínima de {FLUXOS[k].captacao}%</span>
                  <span>Financiamento até {100 - FLUXOS[k].captacao}%</span>
                </button>
              ))}
            </div>
          </div>
        </div>
      </div>
    );
  }

  const fin = linhas[linhas.length - 1];
  return (
    <div className="cartao simulador">
      <div className="sim-topo">
        <div>
          <h3>Simulador · {FLUXOS[fluxo].rotulo}</h3>
          <div className="segmentado pequeno">
            {(Object.keys(PRECOS) as ChavePreco[]).map((k) => (
              <button key={k} className={preco === k ? 'ativo' : ''} onClick={() => setPreco(k)}>{PRECOS[k].rotulo}: {brl2(PRECOS[k].valor)}</button>
            ))}
          </div>
        </div>
        <div className="acoes-linha">
          <button className="botao pequeno" onClick={restaurar}><RotateCcw size={14} /> Voltar ao padrão</button>
          <button className="botao pequeno" onClick={() => setFluxo(null)}>Trocar posição</button>
        </div>
      </div>

      <div className={`sim-captacao${problema ? ' erro' : ''}`}>
        <div className="sim-barra" aria-hidden="true">
          <span style={{ width: `${Math.min(100, captacao)}%` }} />
          <i style={{ left: `${minimo}%` }} />
        </div>
        <p><strong>Captação {pctFmt(captacao)}</strong> · mínimo {minimo}% · financiamento {pctFmt(fin.pct)}</p>
      </div>

      <div className="sim-rolagem">
      <table className="sim-tabela">
        <thead><tr><th>Série</th><th>Parcelas</th><th>% do preço</th><th className="num">Valor da parcela</th><th className="num">Total</th></tr></thead>
        <tbody>
          {SERIES.map((s) => {
            const l = linhas.find((x) => x.k === s.k);
            return (
              <tr key={s.k} className={pct[s.k] === 0 ? 'zerada' : ''}>
                <td>{s.rotulo}</td>
                <td>
                  {s.qtdMax > 1 ? (
                    <span className="sim-passo">
                      <button onClick={() => mudaQtd(s, qtd[s.k] - 1)} aria-label={`Menos parcelas em ${s.rotulo}`}><Minus size={14} /></button>
                      <input type="number" value={qtd[s.k]} min={s.qtdMin} max={s.qtdMax} onChange={(e) => mudaQtd(s, Number(e.target.value))} aria-label={`Parcelas de ${s.rotulo}`} />
                      <button onClick={() => mudaQtd(s, qtd[s.k] + 1)} aria-label={`Mais parcelas em ${s.rotulo}`}><Plus size={14} /></button>
                    </span>
                  ) : <span className="sim-fixo">1</span>}
                </td>
                <td>
                  <span className="sim-pct">
                    <input type="range" min={0} max={40} step={PASSO} value={Math.min(40, pct[s.k])} onChange={(e) => mudaPct(s.k, Number(e.target.value))} aria-label={`Percentual de ${s.rotulo}`} />
                    <span className="sim-passo">
                      <button onClick={() => mudaPct(s.k, pct[s.k] - PASSO)} aria-label={`Diminuir ${s.rotulo}`}><Minus size={14} /></button>
                      <input type="number" step={PASSO} value={pct[s.k]} onChange={(e) => mudaPct(s.k, Number(e.target.value))} aria-label={`Percentual de ${s.rotulo}`} />
                      <button onClick={() => mudaPct(s.k, pct[s.k] + PASSO)} aria-label={`Aumentar ${s.rotulo}`}><Plus size={14} /></button>
                    </span>
                    <span className="sim-sufixo">%</span>
                  </span>
                </td>
                <td className="num">{l ? `${l.qtd > 1 ? `${l.qtd} × ` : ''}${brl(l.parcela)}` : '—'}</td>
                <td className="num">{l ? brl(l.total) : '—'}</td>
              </tr>
            );
          })}
          <tr className="sim-fin">
            <td>Financiamento</td><td><span className="sim-fixo">1</span></td><td>{pctFmt(fin.pct)} <small>(calculado)</small></td>
            <td className="num">{brl(fin.parcela)}</td><td className="num">{brl(fin.total)}</td>
          </tr>
        </tbody>
        <tfoot><tr><td colSpan={4}>Total</td><td className="num">{brl2(valor)}</td></tr></tfoot>
      </table>
      </div>

      {problema && <p className="erro" role="alert">{problema}</p>}
      <div className="sim-rodape">
        <p className="dica">Valores nominais, sem correção. Estimativa sujeita a alteração sem aviso prévio.</p>
        <div className="acoes-linha">
          <button className="botao" disabled={!!problema || !!gerando} onClick={() => baixar('pdf')}><FileDown size={16} /> {gerando === 'pdf' ? 'Gerando…' : 'Baixar PDF'}</button>
          <button className="botao principal" disabled={!!problema || !!gerando} onClick={() => baixar('png')}><Download size={16} /> {gerando === 'png' ? 'Gerando…' : 'Baixar imagem'}</button>
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------
// Arte para baixar (1080 × 1920, formato stories)
// ---------------------------------------------------------------------
function carregarImagem(url: string): Promise<HTMLImageElement | null> {
  return new Promise((ok) => {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => ok(img);
    img.onerror = () => ok(null);
    img.src = url;
    setTimeout(() => ok(null), 6000);
  });
}

function textoCor(hex: string) {
  const h = hex.replace('#', '');
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
  return (r * 299 + g * 587 + b * 114) / 1000 > 150 ? '#1D1E19' : '#FFFFFF';
}

async function desenhar(d: { marca: Marca; fluxo: string; precoRotulo: string; valor: number; linhas: Linha[]; captacao: number; autor: string }) {
  const W = 1080, H = 1920;
  const c = document.createElement('canvas'); c.width = W; c.height = H;
  const g = c.getContext('2d')!;
  const fonte = `'${d.marca.fonte || 'Archivo'}', system-ui, sans-serif`;
  try { await document.fonts.ready; } catch { /* segue com a fonte do sistema */ }
  const fundo = d.marca.cor_primaria || '#23251C';
  const destaque = d.marca.cor_destaque || '#94874A';
  const tinta = textoCor(fundo);
  const suave = tinta === '#FFFFFF' ? 'rgba(255,255,255,0.68)' : 'rgba(0,0,0,0.6)';

  g.fillStyle = fundo; g.fillRect(0, 0, W, H);
  // moldura discreta
  g.strokeStyle = destaque; g.lineWidth = 3; g.strokeRect(48, 48, W - 96, H - 96);

  // logo ou nome
  let y = 150;
  const logoUrl = tinta === '#FFFFFF' ? (d.marca.logo_escuro_url || d.marca.logo_url) : d.marca.logo_url;
  const logo = logoUrl ? await carregarImagem(logoUrl) : null;
  if (logo) {
    const r = logo.width / logo.height;
    const lw = Math.min(700, r * 190), lh = lw / r;
    g.drawImage(logo, (W - lw) / 2, y, lw, lh);
    y += lh + 80;
  } else {
    g.fillStyle = tinta; g.textAlign = 'center'; g.font = `600 96px ${fonte}`;
    g.fillText(d.marca.nome_empreendimento || 'Duo Haus', W / 2, y + 100); y += 200;
  }

  g.textAlign = 'center';
  g.fillStyle = destaque; g.font = `600 46px ${fonte}`;
  g.fillText('Simulador de pagamento', W / 2, y); y += 66;
  g.fillStyle = suave; g.font = `400 34px ${fonte}`;
  g.fillText(`${d.fluxo} · ${d.precoRotulo.toLowerCase()} ${brl2(d.valor)}`, W / 2, y); y += 110;

  // tabela
  const xL = 110, xQ = 560, xV = W - 110;
  g.font = `500 28px ${fonte}`; g.fillStyle = suave;
  g.textAlign = 'left'; g.fillText('Série', xL, y);
  g.textAlign = 'center'; g.fillText('Parcelas', xQ, y);
  g.textAlign = 'right'; g.fillText('Valor', xV, y);
  y += 26; g.fillStyle = destaque; g.fillRect(xL, y, xV - xL, 3); y += 72;

  for (const l of d.linhas) {
    const fin = l.k === 'financiamento';
    if (fin) { g.fillStyle = destaque; g.globalAlpha = 0.18; g.fillRect(xL - 24, y - 56, xV - xL + 48, 86); g.globalAlpha = 1; }
    g.fillStyle = tinta; g.font = `${fin ? 600 : 400} 40px ${fonte}`;
    g.textAlign = 'left'; g.fillText(l.rotulo, xL, y);
    g.textAlign = 'center'; g.fillText(String(l.qtd), xQ, y);
    g.textAlign = 'right'; g.fillText(brl(l.parcela), xV, y);
    y += 100;
  }

  y += 10; g.fillStyle = destaque; g.fillRect(xL, y - 50, xV - xL, 3); y += 30;
  g.fillStyle = tinta; g.font = `600 52px ${fonte}`;
  g.textAlign = 'left'; g.fillText('Total', xL, y);
  g.textAlign = 'right'; g.fillText(brl2(d.valor), xV, y); y += 60;
  g.fillStyle = suave; g.font = `400 30px ${fonte}`;
  g.fillText(`Captação ${pctFmt(d.captacao)} · financiamento ${pctFmt(arred(100 - d.captacao))}`, xV, y);

  // rodapé
  g.textAlign = 'center'; g.fillStyle = suave; g.font = `400 28px ${fonte}`;
  g.fillText('*Valores nominais estimados, sem correção,', W / 2, H - 230);
  g.fillText('sujeitos a alteração sem aviso prévio.', W / 2, H - 190);
  const data = new Date().toLocaleDateString('pt-BR');
  g.fillText(d.autor ? `Simulação de ${d.autor} em ${data}` : `Simulação em ${data}`, W / 2, H - 140);
  return c;
}
