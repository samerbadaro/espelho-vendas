import { useEffect, useMemo, useState, type FormEvent } from 'react';
import { Download, FileDown, RotateCcw, Minus, Plus, Settings2 } from 'lucide-react';
import { supabase } from './dados';
import { useMarca, useDialogos, type Marca } from './ui';
import type { Perfil } from './util';
import {
  ajustarPct, brl, brl2, calcular, lerConf, normalizar, ORDEM, pctFmt, PASSO, PERIODICAS_MAX, POSICOES, QTD_MAX, r2, REFERENCIAS, REFS,
  RESERVA, ROTULO, soma, UNICA_MAX, type ConfSimulador, type K, type Linha, type Periodo, type Posicao, type Referencia,
} from './simuladorCalc';

export function Simulador({ perfil }: { perfil: Perfil }) {
  const { marca } = useMarca();
  const conf = useMemo(() => lerConf(marca), [marca]);
  const admin = perfil.papel === 'admin';
  const [escolha, setEscolha] = useState<{ pos: Posicao; ref: Referencia } | null>(null);
  const [pct, setPct] = useState<Record<K, number>>({ ...RESERVA.poente.pct });
  const [qtd, setQtd] = useState<Record<K, number>>({ ...QTD_MAX });
  const [periodo, setPeriodo] = useState<Periodo>('semestral');
  const [gerando, setGerando] = useState('');
  const [configurando, setConfigurando] = useState(false);

  const padrao = escolha ? normalizar(conf[escolha.pos].pct, conf[escolha.pos].captacao) : RESERVA.poente.pct;
  const iniciar = (pos: Posicao, ref: Referencia) => {
    setEscolha({ pos, ref }); setPct(normalizar(conf[pos].pct, conf[pos].captacao)); setQtd({ ...QTD_MAX }); setPeriodo('semestral');
  };

  const preco = escolha ? conf[escolha.pos][escolha.ref] : 0;
  const { linhas, captacao, fin } = useMemo(() => calcular(preco, pct, qtd, periodo), [preco, pct, qtd, periodo]);
  const minimo = escolha ? conf[escolha.pos].captacao : 0;
  const problema = escolha && captacao < minimo - 1e-9
    ? `A captação está em ${pctFmt(captacao)}. O mínimo para ${POSICOES[escolha.pos]} é ${pctFmt(minimo)}: faltam ${pctFmt(r2(minimo - captacao))}.`
    : '';

  const mudaPct = (k: K, valor: number) => setPct((p) => ajustarPct(p, k, valor, padrao));
  const maxQtd = (k: K) => (k === 'periodicas' ? PERIODICAS_MAX[periodo] : QTD_MAX[k]);
  const mudaQtd = (k: K, v: number) => setQtd((q) => ({ ...q, [k]: Math.max(1, Math.min(maxQtd(k), Math.round(v) || 1)) }));
  const trocarPeriodo = (p: Periodo) => { setPeriodo(p); setQtd((q) => ({ ...q, periodicas: PERIODICAS_MAX[p] })); };

  const baixar = async (formato: 'png' | 'pdf') => {
    if (!escolha || problema) return;
    setGerando(formato);
    try {
      const canvas = await desenhar({ marca, posicao: POSICOES[escolha.pos], referencia: REFERENCIAS[escolha.ref], valor: preco, linhas, captacao, fin, autor: perfil.nome || '' });
      const nome = `simulacao-${escolha.pos}-${new Date().toISOString().slice(0, 10)}`;
      if (formato === 'png') {
        const a = document.createElement('a');
        a.href = canvas.toDataURL('image/png'); a.download = `${nome}.png`; a.click();
      } else {
        const { jsPDF } = await import('jspdf');
        const doc = new jsPDF({ unit: 'mm', format: [108, 192] });
        doc.addImage(canvas.toDataURL('image/jpeg', 0.92), 'JPEG', 0, 0, 108, 192);
        doc.save(`${nome}.pdf`);
      }
      supabase.rpc('registrar_simulacao', {
        p_posicao: POSICOES[escolha.pos], p_referencia: REFERENCIAS[escolha.ref], p_preco: preco,
        p_captacao: captacao, p_financiamento: fin, p_formato: formato,
        p_fluxo: linhas.map((l) => ({ serie: l.rotulo, parcelas: l.qtd, valor: l.parcela, total: l.total, pct: l.pct })),
      }).then(({ error }) => { if (error) console.warn('Registro da simulação falhou:', error.message); }); // o .then dispara a chamada
    } finally { setGerando(''); }
  };

  const configurar = admin && <button className="botao pequeno" onClick={() => setConfigurando(true)}><Settings2 size={14} /> Configurar preços e fluxos</button>;
  const dialogo = configurando && <ConfigurarSimulador conf={conf} aoFechar={() => setConfigurando(false)} />;

  if (!escolha) {
    return (
      <div className="cartao simulador">
        <div className="sim-topo">
          <div>
            <h3>Simulador de pagamento</h3>
            <p className="sub">Escolha a posição. O fluxo padrão é montado e você ajusta como quiser.</p>
          </div>
          {configurar}
        </div>
        <div className="sim-fluxos">
          {(Object.keys(POSICOES) as Posicao[]).map((pos) => (
            <div key={pos} className="sim-posicao">
              <div className="sim-posicao-topo">
                <strong>{POSICOES[pos]}</strong>
                <span>Captação de {pctFmt(conf[pos].captacao)} · financiamento de {pctFmt(r2(100 - conf[pos].captacao))}</span>
              </div>
              <div className="sim-precos">
                {REFS.map((ref) => (
                  <button key={ref} className="sim-preco" onClick={() => iniciar(pos, ref)}>
                    <span>{REFERENCIAS[ref]}</span>
                    <strong>{brl2(conf[pos][ref])}</strong>
                  </button>
                ))}
              </div>
            </div>
          ))}
        </div>
        {dialogo}
      </div>
    );
  }

  const finLinha = linhas[linhas.length - 1];
  return (
    <div className="cartao simulador">
      <div className="sim-topo">
        <div>
          <h3>Simulador · {POSICOES[escolha.pos]}</h3>
          {REFS.length > 1 ? (
            <div className="segmentado pequeno">
              {REFS.map((ref) => (
                <button key={ref} className={escolha.ref === ref ? 'ativo' : ''} onClick={() => setEscolha({ ...escolha, ref })}>{REFERENCIAS[ref]}: {brl2(conf[escolha.pos][ref])}</button>
              ))}
            </div>
          ) : <p className="sub">{REFERENCIAS[escolha.ref]} {brl2(conf[escolha.pos][escolha.ref])}</p>}
        </div>
        <div className="acoes-linha">
          <button className="botao pequeno" onClick={() => iniciar(escolha.pos, escolha.ref)}><RotateCcw size={14} /> Voltar ao padrão</button>
          <button className="botao pequeno" onClick={() => setEscolha(null)}>Trocar posição</button>
        </div>
      </div>

      <div className={`sim-captacao${problema ? ' erro' : ''}`}>
        <div className="sim-barra" aria-hidden="true">
          <span style={{ width: `${Math.min(100, captacao)}%` }} />
          <i style={{ left: `${minimo}%` }} />
        </div>
        <p><strong>Captação {pctFmt(captacao)}</strong> · financiamento fixo em {pctFmt(fin)}</p>
      </div>

      <div className="sim-rolagem">
        <table className="sim-tabela">
          <thead><tr><th>Série</th><th>Parcelas</th><th>% do preço</th><th className="num">Valor da parcela</th><th className="num">Total</th></tr></thead>
          <tbody>
            {ORDEM.map((k) => {
              const l = linhas.find((x) => x.k === k);
              return (
                <tr key={k} className={pct[k] === 0 ? 'zerada' : ''}>
                  <td>
                    {k === 'periodicas' ? (
                      <div className="segmentado mini" role="group" aria-label="Tipo de parcela periódica">
                        <button className={periodo === 'semestral' ? 'ativo' : ''} onClick={() => trocarPeriodo('semestral')}>Semestrais</button>
                        <button className={periodo === 'anual' ? 'ativo' : ''} onClick={() => trocarPeriodo('anual')}>Anuais</button>
                      </div>
                    ) : ROTULO[k]}
                  </td>
                  <td>
                    {maxQtd(k) > 1 ? (
                      <span className="sim-passo">
                        <button onClick={() => mudaQtd(k, qtd[k] - 1)} aria-label={`Menos parcelas em ${ROTULO[k]}`}><Minus size={14} /></button>
                        <input type="number" value={qtd[k]} min={1} max={maxQtd(k)} onChange={(e) => mudaQtd(k, Number(e.target.value))} aria-label={`Parcelas de ${ROTULO[k]}`} />
                        <button onClick={() => mudaQtd(k, qtd[k] + 1)} aria-label={`Mais parcelas em ${ROTULO[k]}`}><Plus size={14} /></button>
                      </span>
                    ) : <span className="sim-fixo">1</span>}
                  </td>
                  <td>
                    <span className="sim-pct">
                      <input type="range" min={0} max={k === 'unica' ? UNICA_MAX : 100} step={PASSO} value={pct[k]} onChange={(e) => mudaPct(k, Number(e.target.value))} aria-label={`Percentual de ${ROTULO[k]}`} />
                      <span className="sim-passo">
                        <button onClick={() => mudaPct(k, pct[k] - PASSO)} aria-label={`Diminuir ${ROTULO[k]}`}><Minus size={14} /></button>
                        <input type="number" step={PASSO} value={pct[k]} onChange={(e) => mudaPct(k, Number(e.target.value))} aria-label={`Percentual de ${ROTULO[k]}`} />
                        <button onClick={() => mudaPct(k, pct[k] + PASSO)} aria-label={`Aumentar ${ROTULO[k]}`}><Plus size={14} /></button>
                      </span>
                      <span className="sim-sufixo">%</span>
                    </span>
                  </td>
                  <td className="num">{l ? `${l.qtd > 1 ? `${l.qtd} × ` : ''}${l.parcela % 1 ? brl2(l.parcela) : brl(l.parcela)}` : '—'}</td>
                  <td className="num">{l ? (l.total % 1 ? brl2(l.total) : brl(l.total)) : '—'}</td>
                </tr>
              );
            })}
            <tr className="sim-fin">
              <td>Financiamento</td><td><span className="sim-fixo">{finLinha.total > 0 ? 1 : 0}</span></td><td>{pctFmt(fin)} <small>(fixo)</small></td>
              <td className="num">{brl2(finLinha.total)}</td><td className="num">{brl2(finLinha.total)}</td>
            </tr>
          </tbody>
          <tfoot><tr><td colSpan={4}>Total</td><td className="num">{brl2(preco)}</td></tr></tfoot>
        </table>
      </div>

      {problema && <p className="erro" role="alert">{problema}</p>}
      <div className="sim-rodape">
        <p className="dica">O financiamento fica fixo. Ao subir mensais ou {periodo === 'anual' ? 'anuais' : 'semestrais'}, o valor sai da outra série e depois da única; ato, sinal e única se compensam com as mensais. Única limitada a {UNICA_MAX}%. Valores nominais, sem correção.</p>
        <div className="acoes-linha">
          {configurar}
          <button className="botao" disabled={!!problema || !!gerando} onClick={() => baixar('pdf')}><FileDown size={16} /> {gerando === 'pdf' ? 'Gerando…' : 'Baixar PDF'}</button>
          <button className="botao principal" disabled={!!problema || !!gerando} onClick={() => baixar('png')}><Download size={16} /> {gerando === 'png' ? 'Gerando…' : 'Baixar imagem'}</button>
        </div>
      </div>
      {dialogo}
    </div>
  );
}

// ---------------------------------------------------------------------
// Configuração (administrador)
// ---------------------------------------------------------------------
const ERROS_CONF: Record<string, string> = {
  PRECO_INVALIDO: 'Preencha os 2 preços com valores maiores que zero.',
  CAPTACAO_INVALIDA: 'A captação mínima precisa estar entre 1% e 100%.',
  FLUXO_PADRAO_INVALIDO: 'Em cada posição, o fluxo padrão precisa somar pelo menos a captação mínima e no máximo 100%.',
  SEM_PERMISSAO: 'Só o administrador altera o simulador.',
};
const numBR = (v: number) => v.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const lerBR = (s: string) => Number(s.replace(/\./g, '').replace(',', '.'));

function ConfigurarSimulador({ conf, aoFechar }: { conf: ConfSimulador; aoFechar: () => void }) {
  const { recarregar } = useMarca();
  const { avisar } = useDialogos();
  const [f, setF] = useState(() => ({
    poente: { a_partir: numBR(conf.poente.a_partir), medio: numBR(conf.poente.medio), captacao: String(conf.poente.captacao), pct: { ...conf.poente.pct } },
    nascente: { a_partir: numBR(conf.nascente.a_partir), medio: numBR(conf.nascente.medio), captacao: String(conf.nascente.captacao), pct: { ...conf.nascente.pct } },
  }));
  const [erro, setErro] = useState('');
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && aoFechar();
    window.addEventListener('keydown', esc); return () => window.removeEventListener('keydown', esc);
  }, [aoFechar]);
  const salvar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    const p: ConfSimulador = {
      poente: { a_partir: lerBR(f.poente.a_partir), medio: lerBR(f.poente.a_partir), captacao: Number(f.poente.captacao.replace(',', '.')), pct: f.poente.pct },
      nascente: { a_partir: lerBR(f.nascente.a_partir), medio: lerBR(f.nascente.a_partir), captacao: Number(f.nascente.captacao.replace(',', '.')), pct: f.nascente.pct },
    };
    if (p.poente.pct.unica > UNICA_MAX || p.nascente.pct.unica > UNICA_MAX) { setErro(`A única não pode passar de ${UNICA_MAX}% do preço.`); return; }
    for (const pos of ['poente', 'nascente'] as Posicao[]) {
      if (Math.abs(soma(p[pos].pct) - p[pos].captacao) > 0.001) {
        setErro(`${POSICOES[pos]}: as séries somam ${pctFmt(soma(p[pos].pct))}, mas a captação é ${pctFmt(p[pos].captacao)}. Ajuste para fechar igual.`); return;
      }
    }
    const { error } = await supabase.rpc('salvar_simulador', { p });
    if (error) { setErro(ERROS_CONF[error.message] ?? 'Não foi possível salvar. Confira se a migração 026 foi aplicada.'); return; }
    recarregar(); avisar('Simulador atualizado.'); aoFechar();
  };
  const campo = (pos: Posicao, k: 'a_partir' | 'medio' | 'captacao') => (
    <input value={f[pos][k]} inputMode="decimal" aria-label={`${POSICOES[pos]} ${k}`} onChange={(e) => setF((x) => ({ ...x, [pos]: { ...x[pos], [k]: e.target.value } }))} />
  );
  const pctCampo = (pos: Posicao, k: K) => (
    <input type="number" step={0.5} min={0} max={100} value={f[pos].pct[k]} aria-label={`${POSICOES[pos]} ${ROTULO[k]}`}
      onChange={(e) => setF((x) => ({ ...x, [pos]: { ...x[pos], pct: { ...x[pos].pct, [k]: Number(e.target.value) } } }))} />
  );
  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <form className="dialogo" role="dialog" aria-modal="true" aria-labelledby="conf-sim" onClick={(e) => e.stopPropagation()} onSubmit={salvar}>
        <h2 id="conf-sim">Configurar simulador</h2>
        <p className="sub">O fluxo padrão é o que aparece quando o corretor escolhe a posição. As séries precisam somar a captação; o financiamento fica fixo no restante.</p>
        <table className="sim-conf">
          <thead><tr><th></th><th>Poente</th><th>Nascente</th></tr></thead>
          <tbody>
            <tr><td>A partir de (R$)</td><td>{campo('poente', 'a_partir')}</td><td>{campo('nascente', 'a_partir')}</td></tr>
            <tr><td>Captação (%)</td><td>{campo('poente', 'captacao')}</td><td>{campo('nascente', 'captacao')}</td></tr>
            {ORDEM.map((k) => <tr key={k}><td>{ROTULO[k]} (%)</td><td>{pctCampo('poente', k)}</td><td>{pctCampo('nascente', k)}</td></tr>)}
            <tr className="sim-conf-fin"><td>Soma das séries</td>
              <td>{pctFmt(soma(f.poente.pct))}</td><td>{pctFmt(soma(f.nascente.pct))}</td></tr>
            <tr className="sim-conf-fin"><td>Financiamento (fixo)</td>
              <td>{pctFmt(r2(100 - Number(f.poente.captacao.replace(',', '.'))))}</td><td>{pctFmt(r2(100 - Number(f.nascente.captacao.replace(',', '.'))))}</td></tr>
          </tbody>
        </table>
        {erro && <p className="erro">{erro}</p>}
        <div className="dialogo-acoes">
          <button type="button" className="botao" onClick={aoFechar}>Cancelar</button>
          <button className="botao principal">Salvar</button>
        </div>
      </form>
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

async function desenhar(d: { marca: Marca; posicao: string; referencia: string; valor: number; linhas: Linha[]; captacao: number; fin: number; autor: string }) {
  const W = 1080, H = 1920;
  const c = document.createElement('canvas'); c.width = W; c.height = H;
  const g = c.getContext('2d')!;
  const fonte = `'${d.marca.fonte || 'Archivo'}', system-ui, sans-serif`;
  try { await document.fonts.ready; } catch { /* segue com a fonte do sistema */ }
  const fundo = d.marca.cor_primaria || '#23251C';
  const destaque = d.marca.cor_destaque || '#94874A';
  const tinta = textoCor(fundo);
  const suave = tinta === '#FFFFFF' ? 'rgba(255,255,255,0.68)' : 'rgba(0,0,0,0.6)';
  const linhas = d.linhas.filter((l) => l.k !== 'financiamento' || l.total > 0);

  g.fillStyle = fundo; g.fillRect(0, 0, W, H);
  g.strokeStyle = destaque; g.lineWidth = 3; g.strokeRect(48, 48, W - 96, H - 96);

  // centraliza o bloco quando há poucas séries
  let y = 150 + Math.max(0, 6 - linhas.length) * 50;
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
  g.fillText(`${d.posicao} · ${d.referencia.toLowerCase()} ${brl2(d.valor)}`, W / 2, y); y += 110;

  const xL = 110, xQ = 560, xV = W - 110;
  g.font = `500 28px ${fonte}`; g.fillStyle = suave;
  g.textAlign = 'left'; g.fillText('Série', xL, y);
  g.textAlign = 'center'; g.fillText('Parcelas', xQ, y);
  g.textAlign = 'right'; g.fillText('Valor', xV, y);
  y += 26; g.fillStyle = destaque; g.fillRect(xL, y, xV - xL, 3); y += 72;

  for (const l of linhas) {
    const fin = l.k === 'financiamento';
    if (fin) { g.fillStyle = destaque; g.globalAlpha = 0.18; g.fillRect(xL - 24, y - 56, xV - xL + 48, 86); g.globalAlpha = 1; }
    g.fillStyle = tinta; g.font = `${fin ? 600 : 400} 40px ${fonte}`;
    g.textAlign = 'left'; g.fillText(l.rotulo, xL, y);
    g.textAlign = 'center'; g.fillText(String(l.qtd), xQ, y);
    g.textAlign = 'right'; g.fillText(l.parcela % 1 ? brl2(l.parcela) : brl(l.parcela), xV, y);
    y += 100;
  }

  y += 10; g.fillStyle = destaque; g.fillRect(xL, y - 50, xV - xL, 3); y += 30;
  g.fillStyle = tinta; g.font = `600 52px ${fonte}`;
  g.textAlign = 'left'; g.fillText('Total', xL, y);
  g.textAlign = 'right'; g.fillText(brl2(d.valor), xV, y); y += 60;
  g.fillStyle = suave; g.font = `400 30px ${fonte}`;
  g.fillText(d.fin > 0 ? `Captação ${pctFmt(d.captacao)} · financiamento ${pctFmt(d.fin)}` : 'Pagamento direto até a entrega, sem financiamento', xV, y);

  g.textAlign = 'center'; g.fillStyle = suave; g.font = `400 28px ${fonte}`;
  g.fillText('*Valores nominais estimados, sem correção,', W / 2, H - 230);
  g.fillText('sujeitos a alteração sem aviso prévio.', W / 2, H - 190);
  const data = new Date().toLocaleDateString('pt-BR');
  g.fillText(d.autor ? `Simulação de ${d.autor} em ${data}` : `Simulação em ${data}`, W / 2, H - 140);
  return c;
}
