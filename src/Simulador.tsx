import { useEffect, useMemo, useState, type FormEvent } from 'react';
import { Copy, Download, FileDown, RotateCcw, Minus, Plus, Settings2, Trash2 } from 'lucide-react';
import { supabase } from './dados';
import { useMarca, useDialogos, type Marca } from './ui';
import type { Perfil } from './util';
import {
  ajustarPct, brl, brl2, calcular, normalizar, ORDEM, type Linha, pctFmt, PASSO, r2, ROTULO, soma, UNICA_MAX, type K, type Periodo,
} from './simuladorCalc';

// ---------------------------------------------------------------------
// Regras (valores nominais, sem valor presente).
// Os cenários (tipologias, metragens, posições...) com preços, captação
// mínima e fluxo padrão vêm de config.simulador.cenarios (editáveis pelo
// administrador); o cenário abaixo é só a reserva.
// ---------------------------------------------------------------------
export interface PrecoRef { rotulo: string; valor: number }
export interface Cenario { id: string; nome: string; descricao: string; precos: PrecoRef[]; captacao: number; pct: Record<K, number> }
export type ConfSimulador = Cenario[];

const PCT_PADRAO: Record<K, number> = { ato: 4, sinal: 4, mensais: 6, periodicas: 12, unica: 4 };
const RESERVA: ConfSimulador = [
  { id: 'padrao', nome: 'Unidade padrão', descricao: '', precos: [{ rotulo: 'A partir de', valor: 405576.26 }, { rotulo: 'Preço médio', valor: 427575.76 }], captacao: 30, pct: { ...PCT_PADRAO } },
];
const QTD_RESERVA: Record<K, number> = { ato: 1, sinal: 3, mensais: 43, periodicas: 7, unica: 1 };

const novoId = () => Math.random().toString(36).slice(2, 10);

/**
 * Máximo de parcelas para uma venda hoje, pela entrega: mensais da 4ª à entrega;
 * semestrais e anuais da 5ª até um mês antes da entrega.
 */
function qtdMaxima(mesEntrega: string | null): { base: Record<K, number>; periodicas: Record<Periodo, number> } {
  if (!mesEntrega) return { base: { ...QTD_RESERVA }, periodicas: { semestral: 7, anual: 3 } };
  const hoje = new Date();
  const [a, m] = mesEntrega.split('-').map(Number);
  const meses = (a - hoje.getFullYear()) * 12 + (m - 1 - hoje.getMonth());
  const mensais = Math.max(1, meses - 4 + 1);
  const ate = (passo: number) => Math.max(1, Math.floor((meses - 1 - 5) / passo) + 1);
  return { base: { ato: 1, sinal: 3, mensais, periodicas: ate(6), unica: 1 }, periodicas: { semestral: ate(6), anual: ate(12) } };
}

type Antigo = Record<string, { a_partir?: number; medio?: number; captacao?: number; pct?: Partial<Record<K, number>> }>;

export function lerConf(m: Marca): ConfSimulador {
  const c = (m as Marca & { simulador?: { cenarios?: Partial<Cenario>[] } & Antigo }).simulador;
  if (c && Array.isArray(c.cenarios) && c.cenarios.length) {
    return c.cenarios.map((x, i) => ({
      id: x.id || `c${i}`, nome: x.nome || `Cenário ${i + 1}`, descricao: x.descricao ?? '',
      precos: (x.precos ?? []).filter((p) => p && Number(p.valor) > 0).map((p) => ({ rotulo: p.rotulo, valor: Number(p.valor) })),
      captacao: Number(x.captacao ?? 30), pct: { ...PCT_PADRAO, ...(x.pct ?? {}) },
    })).filter((x) => x.precos.length);
  }
  const antigos = c ? (['poente', 'nascente'] as const).filter((k) => c[k]) : [];
  if (antigos.length) {
    return antigos.map((k) => ({
      id: k, nome: k === 'poente' ? 'Poente' : 'Nascente', descricao: '',
      precos: [{ rotulo: 'A partir de', valor: Number(c![k].a_partir) }, { rotulo: 'Preço médio', valor: Number(c![k].medio) }],
      captacao: Number(c![k].captacao ?? 30), pct: { ...PCT_PADRAO, ...(c![k].pct ?? {}) },
    }));
  }
  return RESERVA;
}

export function Simulador({ perfil }: { perfil: Perfil }) {
  const { marca } = useMarca();
  const conf = useMemo(() => lerConf(marca), [marca]);
  const admin = perfil.papel === 'admin';
  const [entrega, setEntrega] = useState<string | null>(null);
  const [escolha, setEscolha] = useState<{ id: string; ref: number } | null>(null);
  const [pct, setPct] = useState<Record<K, number>>({ ...PCT_PADRAO });
  const maximas = useMemo(() => qtdMaxima(entrega), [entrega]);
  const [qtd, setQtd] = useState<Record<K, number>>({ ...QTD_RESERVA });
  const [periodo, setPeriodo] = useState<Periodo>('semestral');
  const [gerando, setGerando] = useState('');
  const [configurando, setConfigurando] = useState(false);
  const [busca, setBusca] = useState('');

  useEffect(() => {
    supabase.from('comercial').select('mes_entrega').limit(1).maybeSingle()
      .then(({ data }) => setEntrega((data as { mes_entrega?: string } | null)?.mes_entrega?.slice(0, 7) ?? null));
  }, []);

  const cenario = escolha ? conf.find((c) => c.id === escolha.id) ?? null : null;
  // financiamento fixo em (100 − captação): o fluxo padrão soma exatamente a captação do cenário
  const padrao = cenario ? normalizar(cenario.pct, cenario.captacao) : PCT_PADRAO;
  const iniciar = (c: Cenario, ref: number) => {
    setEscolha({ id: c.id, ref }); setPct(normalizar(c.pct, c.captacao)); setQtd({ ...maximas.base }); setPeriodo('semestral');
  };

  const precoRef = cenario ? cenario.precos[Math.min(escolha!.ref, cenario.precos.length - 1)] : null;
  const preco = precoRef?.valor ?? 0;
  const { linhas, captacao, fin } = useMemo(() => calcular(preco, pct, qtd, periodo), [preco, pct, qtd, periodo]);
  const minimo = cenario ? cenario.captacao : 0;
  const problema = cenario && captacao < minimo - 1e-9
    ? `A captação está em ${pctFmt(captacao)}. O mínimo para ${cenario.nome} é ${pctFmt(minimo)}: faltam ${pctFmt(r2(minimo - captacao))}.`
    : '';

  const mudaPct = (k: K, valor: number) => setPct((p) => ajustarPct(p, k, valor, padrao));
  const maxQtd = (k: K) => (k === 'periodicas' ? maximas.periodicas[periodo] : maximas.base[k]);
  const mudaQtd = (k: K, v: number) => setQtd((q) => ({ ...q, [k]: Math.max(1, Math.min(maxQtd(k), Math.round(v) || 1)) }));
  const trocarPeriodo = (p: Periodo) => { setPeriodo(p); setQtd((q) => ({ ...q, periodicas: maximas.periodicas[p] })); };

  const baixar = async (formato: 'png' | 'pdf') => {
    if (!cenario || !precoRef || problema) return;
    setGerando(formato);
    try {
      const canvas = await desenhar({ marca, posicao: cenario.nome, referencia: precoRef.rotulo, valor: preco, linhas, captacao, fin, autor: perfil.nome || '' });
      const nome = `simulacao-${cenario.nome.normalize('NFD').replace(/[^\w]+/g, '-').toLowerCase()}-${new Date().toISOString().slice(0, 10)}`;
      if (formato === 'png') {
        const a = document.createElement('a');
        a.href = canvas.toDataURL('image/png'); a.download = `${nome}.png`; a.click();
      } else {
        const { jsPDF } = await import('jspdf');
        const doc = new jsPDF({ unit: 'mm', format: [108, 192] });
        doc.addImage(canvas.toDataURL('image/jpeg', 0.92), 'JPEG', 0, 0, 108, 192);
        doc.save(`${nome}.pdf`);
      }
      void supabase.rpc('registrar_simulacao', {
        p_posicao: cenario.nome, p_referencia: precoRef.rotulo, p_preco: preco,
        p_captacao: captacao, p_financiamento: fin, p_formato: formato,
        p_fluxo: linhas.map((l) => ({ serie: l.rotulo, parcelas: l.qtd, valor: l.parcela, total: l.total, pct: l.pct })),
      }).then(({ error }) => { if (error) console.warn('Registro da simulação falhou:', error.message); }); // o .then dispara a chamada
    } finally { setGerando(''); }
  };

  const configurar = admin && <button className="botao pequeno" onClick={() => setConfigurando(true)}><Settings2 size={14} /> Configurar cenários</button>;
  const dialogo = configurando && <ConfigurarSimulador conf={conf} aoFechar={() => setConfigurando(false)} />;

  if (!cenario || !precoRef) {
    const termo = busca.trim().toLowerCase();
    const lista = conf.filter((c) => !termo || `${c.nome} ${c.descricao}`.toLowerCase().includes(termo));
    return (
      <div className="cartao simulador">
        <div className="sim-topo">
          <div>
            <h3>Simulador de pagamento</h3>
            <p className="sub">Escolha a unidade e a referência de preço. O fluxo padrão é montado e você ajusta como quiser.</p>
          </div>
          {configurar}
        </div>
        {conf.length > 6 && <input className="sim-busca" placeholder="Buscar tipologia, metragem…" value={busca} onChange={(e) => setBusca(e.target.value)} />}
        <div className="sim-fluxos">
          {lista.map((c) => (
            <div key={c.id} className="sim-posicao">
              <div className="sim-posicao-topo">
                <strong>{c.nome}</strong>
                {c.descricao && <span>{c.descricao}</span>}
                <span>Captação mínima de {pctFmt(c.captacao)} · financiamento até {pctFmt(r2(100 - c.captacao))}</span>
              </div>
              <div className="sim-precos">
                {c.precos.map((p, i) => (
                  <button key={i} className="sim-preco" onClick={() => iniciar(c, i)}>
                    <span>{p.rotulo}</span>
                    <strong>{brl2(p.valor)}</strong>
                  </button>
                ))}
              </div>
            </div>
          ))}
          {!lista.length && <p className="vazio">Nenhum cenário encontrado.</p>}
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
          <h3>Simulador · {cenario.nome}</h3>
          {cenario.precos.length > 1 && (
            <div className="segmentado pequeno">
              {cenario.precos.map((p, i) => (
                <button key={i} className={escolha!.ref === i ? 'ativo' : ''} onClick={() => setEscolha({ ...escolha!, ref: i })}>{p.rotulo}: {brl2(p.valor)}</button>
              ))}
            </div>
          )}
        </div>
        <div className="acoes-linha">
          <button className="botao pequeno" onClick={() => iniciar(cenario, escolha!.ref)}><RotateCcw size={14} /> Voltar ao padrão</button>
          <button className="botao pequeno" onClick={() => setEscolha(null)}>Trocar unidade</button>
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
        <p className="dica">Ao subir mensais ou {periodo === 'anual' ? 'anuais' : 'semestrais'}, o valor sai da outra série e depois da única; o financiamento fica fixo na captação do cenário. Única limitada a {UNICA_MAX}%. Quantidade máxima de parcelas pela data de entrega{entrega ? ` (${entrega.slice(5, 7)}/${entrega.slice(0, 4)})` : ''}. Valores nominais, sem correção.</p>
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
// Configuração dos cenários (administrador)
// ---------------------------------------------------------------------
const ERROS_CONF: Record<string, string> = {
  CENARIOS_INVALIDOS: 'Cadastre de 1 a 30 cenários.',
  NOME_INVALIDO: 'Dê um nome a cada cenário.',
  PRECO_INVALIDO: 'Cada cenário precisa de 1 a 6 preços, com rótulo e valor maior que zero.',
  CAPTACAO_INVALIDA: 'A captação mínima precisa estar entre 1% e 100%.',
  UNICA_ACIMA_DO_LIMITE: `A única não pode passar de ${UNICA_MAX}% do preço.`,
  FLUXO_PADRAO_INVALIDO: 'Em cada cenário, o fluxo padrão precisa somar pelo menos a captação mínima e no máximo 100%.',
  SEM_PERMISSAO: 'Só o administrador altera o simulador.',
};
const numBR = (v: number) => v.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const lerBR = (s: string) => Number(s.replace(/\./g, '').replace(',', '.'));

interface CenarioForm { id: string; nome: string; descricao: string; precos: { rotulo: string; valor: string }[]; captacao: string; pct: Record<K, number> }
const paraForm = (c: Cenario): CenarioForm => ({
  id: c.id, nome: c.nome, descricao: c.descricao, captacao: String(c.captacao).replace('.', ','), pct: { ...c.pct },
  precos: c.precos.map((p) => ({ rotulo: p.rotulo, valor: numBR(p.valor) })),
});

function ConfigurarSimulador({ conf, aoFechar }: { conf: ConfSimulador; aoFechar: () => void }) {
  const { recarregar } = useMarca();
  const { avisar } = useDialogos();
  const [f, setF] = useState<CenarioForm[]>(() => conf.map(paraForm));
  const [erro, setErro] = useState('');
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && aoFechar();
    window.addEventListener('keydown', esc); return () => window.removeEventListener('keydown', esc);
  }, [aoFechar]);
  const mudar = (i: number, g: (c: CenarioForm) => CenarioForm) => setF((x) => x.map((c, j) => (j === i ? g(structuredClone(c)) : c)));
  const salvar = async (e: FormEvent) => {
    e.preventDefault(); setErro('');
    const cenarios: Cenario[] = f.map((c) => ({
      id: c.id, nome: c.nome.trim(), descricao: c.descricao.trim(), captacao: Number(c.captacao.replace(',', '.')), pct: c.pct,
      precos: c.precos.map((p) => ({ rotulo: p.rotulo.trim(), valor: lerBR(p.valor) })),
    }));
    const { error } = await supabase.rpc('salvar_simulador', { p: { cenarios } });
    if (error) { setErro(ERROS_CONF[error.message] ?? 'Não foi possível salvar. Confira se a migração 111 foi aplicada.'); return; }
    recarregar(); avisar('Simulador atualizado.'); aoFechar();
  };
  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <form className="dialogo sim-conf-dialogo" role="dialog" aria-modal="true" aria-labelledby="conf-sim" onClick={(e) => e.stopPropagation()} onSubmit={salvar}>
        <h2 id="conf-sim">Configurar cenários do simulador</h2>
        <p className="sub">Um cenário por tipologia, metragem ou posição, cada um com seus preços de referência e seu fluxo padrão. O financiamento é o que falta para 100%.</p>
        <div className="sim-conf-lista">
          {f.map((c, i) => (
            <fieldset key={c.id} className="sim-conf-cenario">
              <div className="sim-conf-linha">
                <label>Nome<input value={c.nome} onChange={(e) => mudar(i, (x) => ({ ...x, nome: e.target.value }))} placeholder="ex.: Studio 35 m² · Nascente" /></label>
                <label>Descrição (opcional)<input value={c.descricao} onChange={(e) => mudar(i, (x) => ({ ...x, descricao: e.target.value }))} placeholder="ex.: finais 01 e 02, do 3º ao 10º andar" /></label>
                <div className="sim-conf-acoes">
                  <button type="button" className="icone-botao" title="Duplicar" onClick={() => setF((x) => [...x.slice(0, i + 1), { ...structuredClone(c), id: novoId(), nome: `${c.nome} (cópia)` }, ...x.slice(i + 1)])}><Copy size={15} /></button>
                  {f.length > 1 && <button type="button" className="icone-botao" title="Remover" onClick={() => setF((x) => x.filter((_, j) => j !== i))}><Trash2 size={15} /></button>}
                </div>
              </div>
              <div className="sim-conf-precos">
                {c.precos.map((p, k) => (
                  <span key={k} className="sim-conf-preco">
                    <input value={p.rotulo} aria-label="Rótulo do preço" onChange={(e) => mudar(i, (x) => { x.precos[k].rotulo = e.target.value; return x; })} />
                    <input value={p.valor} inputMode="decimal" aria-label="Valor" onChange={(e) => mudar(i, (x) => { x.precos[k].valor = e.target.value; return x; })} />
                    {c.precos.length > 1 && <button type="button" className="icone-botao" aria-label="Remover preço" onClick={() => mudar(i, (x) => { x.precos.splice(k, 1); return x; })}><Trash2 size={13} /></button>}
                  </span>
                ))}
                {c.precos.length < 6 && <button type="button" className="botao pequeno" onClick={() => mudar(i, (x) => { x.precos.push({ rotulo: 'Preço', valor: '' }); return x; })}><Plus size={13} /> Preço</button>}
              </div>
              <div className="sim-conf-fluxo">
                <label>Captação mín. (%)<input value={c.captacao} inputMode="decimal" onChange={(e) => mudar(i, (x) => ({ ...x, captacao: e.target.value }))} /></label>
                {ORDEM.map((k) => (
                  <label key={k}>{k === 'periodicas' ? 'Semestrais' : ROTULO[k]} (%)
                    <input type="number" step={0.5} min={0} max={k === 'unica' ? UNICA_MAX : 100} value={c.pct[k]} onChange={(e) => mudar(i, (x) => { x.pct[k] = Number(e.target.value); return x; })} />
                  </label>
                ))}
                <span className="sim-conf-fin">Financiamento {pctFmt(r2(100 - soma(c.pct)))}</span>
              </div>
            </fieldset>
          ))}
        </div>
        {f.length < 30 && (
          <button type="button" className="botao pequeno" onClick={() => setF((x) => [...x, { id: novoId(), nome: `Cenário ${x.length + 1}`, descricao: '', captacao: '30', pct: { ...PCT_PADRAO }, precos: [{ rotulo: 'A partir de', valor: '' }] }])}>
            <Plus size={14} /> Novo cenário
          </button>
        )}
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
