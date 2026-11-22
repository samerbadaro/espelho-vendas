// =====================================================================
// Fluxo consolidado do incorporador: propostas aprovadas, mês a mês,
// com a comissão abatida. Filtros por unidade, imobiliária, cliente,
// tipologia e final. Só o administrador vê.
// =====================================================================
import { useEffect, useMemo, useState } from 'react';
import { supabase } from '../dados';
import { carregarContexto, doBanco, type Contexto } from './dadosProposta';
import { parcelas, comissao, total, fmtReal, fmtPct, fmtNum, type Parcela, type Serie } from './motor';
import { FileSpreadsheet } from 'lucide-react';
import './proposta.css';

interface Linha {
  id: string; codigo: string; data_proposta: string; series: Omit<Serie, 'id'>[]; comissao_pct: number | null; parte_sinal: number | null;
  unidade_id: string; unidades: { numero: string; tipo_preco: string | null; area_privativa: number | null } | null;
  pastas: { comprador_nome: string | null; status: string } | null; imobiliarias: { nome: string } | null;
}

/** Uma proposta já calculada: parcelas com a comissão abatida. */
interface Venda {
  id: string; codigo: string; data: string; unidade: string; tipologia: string; final: string; area: number;
  cliente: string; imobiliaria: string; vgv: number; comissao: number; liquido: number; permuta: number;
  mensal: Map<string, { bruto: number; comissao: number; chaves: boolean }>;
}

const SEM = '—';
const sem = (t: string) => t.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
const fmtMesCurto = (m: string) => `${['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'][Number(m.slice(5, 7)) - 1]}/${m.slice(2, 4)}`;

function calcularVenda(l: Linha, ctx: Contexto): Venda {
  const cfg = ctx.cfg;
  const series = doBanco(l.series);
  const ps: Parcela[] = parcelas(cfg, series);
  const caixa = ps.filter((p) => p.periodicidade !== 'Permuta');
  const vgv = total(ps);
  const com = comissao(ps, vgv, l.comissao_pct ?? cfg.comissao.percentual, l.parte_sinal ?? cfg.comissao.parteDoSinal);
  const mensal = new Map<string, { bruto: number; comissao: number; chaves: boolean }>();
  // comissão: a parte coberta sai do sinal; o que o sinal não cobre sai das parcelas seguintes, em ordem
  const doSinal = com.linhas.map((x) => x.comissao);
  let resto = com.naoCoberta;
  let iSinal = 0;
  for (const p of caixa) {
    let c = 0;
    if (p.periodicidade === 'Sinal' && iSinal < doSinal.length) c = doSinal[iSinal++];
    else if (resto > 0) { c = Math.min(resto, p.valor); resto -= c; }
    const mes = p.data.slice(0, 7);
    const m = mensal.get(mes) ?? { bruto: 0, comissao: 0, chaves: p.periodicidade !== 'Financiamento' };
    m.bruto += p.valor; m.comissao += c;
    mensal.set(mes, m);
  }
  const numero = l.unidades?.numero ?? SEM;
  return {
    id: l.id, codigo: l.codigo, data: l.data_proposta, unidade: numero, tipologia: l.unidades?.tipo_preco ?? SEM,
    final: numero.replace(/\D/g, '').slice(-2) || SEM, area: Number(l.unidades?.area_privativa ?? 0),
    cliente: l.pastas?.comprador_nome ?? SEM, imobiliaria: l.imobiliarias?.nome ?? 'Venda direta',
    vgv, comissao: com.devida, liquido: vgv - com.devida - total(ps.filter((p) => p.periodicidade === 'Permuta')),
    permuta: total(ps.filter((p) => p.periodicidade === 'Permuta')), mensal,
  };
}

export function FluxoConsolidado() {
  const [ctx, setCtx] = useState<Contexto | null>(null);
  const [vendas, setVendas] = useState<Venda[] | null>(null);
  const [erro, setErro] = useState('');
  const [f, setF] = useState({ unidade: '', imobiliaria: '', cliente: '', tipologia: '', final: '' });
  const [visao, setVisao] = useState<'mensal' | 'anual'>('mensal');
  const [agrupar, setAgrupar] = useState<'imobiliaria' | 'tipologia' | 'final'>('imobiliaria');

  useEffect(() => {
    (async () => {
      const c = await carregarContexto();
      if ('erro' in c) { setErro(c.erro); return; }
      setCtx(c);
      const { data, error } = await supabase.from('propostas')
        .select('id, codigo, data_proposta, series, comissao_pct, parte_sinal, unidade_id, atualizada_em, unidades(numero, tipo_preco, area_privativa), pastas(comprador_nome, status), imobiliarias(nome)')
        .eq('status', 'aprovada').order('atualizada_em', { ascending: false });
      if (error) { setErro(error.message); return; }
      // uma proposta por unidade (a aprovada mais recente) e sem clientes que desistiram
      const vistas = new Set<string>();
      const lista = ((data ?? []) as unknown as Linha[]).filter((l) => {
        if (vistas.has(l.unidade_id)) return false;
        vistas.add(l.unidade_id);
        return !['devolucao_pix', 'cancelada'].includes(l.pastas?.status ?? '');
      });
      setVendas(lista.map((l) => calcularVenda(l, c)));
    })();
  }, []);

  const opcoes = useMemo(() => {
    const u = (k: keyof Venda) => [...new Set((vendas ?? []).map((v) => String(v[k])))].sort((a, b) => a.localeCompare(b, 'pt-BR', { numeric: true }));
    return { unidade: u('unidade'), imobiliaria: u('imobiliaria'), tipologia: u('tipologia'), final: u('final') };
  }, [vendas]);

  const filtradas = useMemo(() => (vendas ?? []).filter((v) =>
    (!f.unidade || v.unidade === f.unidade) && (!f.imobiliaria || v.imobiliaria === f.imobiliaria)
    && (!f.tipologia || v.tipologia === f.tipologia) && (!f.final || v.final === f.final)
    && (!f.cliente.trim() || sem(v.cliente).includes(sem(f.cliente.trim())))), [vendas, f]);

  // fluxo mês a mês (ou ano a ano), com acumulado
  const fluxo = useMemo(() => {
    const mapa = new Map<string, { bruto: number; comissao: number; chaves: number; pos: number }>();
    for (const v of filtradas) for (const [mes, m] of v.mensal) {
      const k = visao === 'anual' ? mes.slice(0, 4) : mes;
      const a = mapa.get(k) ?? { bruto: 0, comissao: 0, chaves: 0, pos: 0 };
      a.bruto += m.bruto; a.comissao += m.comissao;
      if (m.chaves) a.chaves += m.bruto - m.comissao; else a.pos += m.bruto - m.comissao;
      mapa.set(k, a);
    }
    // meses sem recebimento entre o primeiro e o último também aparecem
    let chaves = [...mapa.keys()].sort();
    if (visao === 'mensal' && chaves.length) {
      const todos: string[] = [];
      let [a, m] = chaves[0].split('-').map(Number);
      const fim = chaves[chaves.length - 1];
      for (;;) { const k = `${a}-${String(m).padStart(2, '0')}`; todos.push(k); if (k >= fim) break; m++; if (m > 12) { m = 1; a++; } }
      chaves = todos;
    }
    const liquidoTotal = [...mapa.values()].reduce((t, x) => t + x.bruto - x.comissao, 0);
    let acum = 0;
    return chaves.map((k) => {
      const x = mapa.get(k) ?? { bruto: 0, comissao: 0, chaves: 0, pos: 0 };
      const liquido = x.bruto - x.comissao;
      acum += liquido;
      return { k, ...x, liquido, acum, acumPct: liquidoTotal > 0 ? acum / liquidoTotal : 0 };
    });
  }, [filtradas, visao]);

  const tot = useMemo(() => {
    const s = (fn: (v: Venda) => number) => filtradas.reduce((t, v) => t + fn(v), 0);
    const vgv = s((v) => v.vgv), area = s((v) => v.area);
    const chaves = fluxo.reduce((t, x) => t + x.chaves, 0), pos = fluxo.reduce((t, x) => t + x.pos, 0);
    return { n: filtradas.length, vgv, comissao: s((v) => v.comissao), liquido: chaves + pos, permuta: s((v) => v.permuta), area, chaves, pos, m2: area > 0 ? vgv / area : 0 };
  }, [filtradas, fluxo]);

  const grupos = useMemo(() => {
    const m = new Map<string, { n: number; vgv: number; comissao: number; liquido: number; area: number }>();
    for (const v of filtradas) {
      const k = String(v[agrupar]);
      const g = m.get(k) ?? { n: 0, vgv: 0, comissao: 0, liquido: 0, area: 0 };
      g.n++; g.vgv += v.vgv; g.comissao += v.comissao; g.liquido += v.liquido; g.area += v.area;
      m.set(k, g);
    }
    return [...m.entries()].sort((a, b) => b[1].vgv - a[1].vgv);
  }, [filtradas, agrupar]);

  const exportar = () => {
    const linhas = [['Período', 'Recebimento bruto', 'Comissão', 'Líquido incorporador', 'Até as chaves', 'Pós-chaves', 'Acumulado', '% acumulado'],
      ...fluxo.map((x) => [x.k, x.bruto, x.comissao, x.liquido, x.chaves, x.pos, x.acum, x.acumPct].map((v) => typeof v === 'number' ? v.toFixed(2).replace('.', ',') : v))];
    const csv = '﻿' + linhas.map((l) => l.join(';')).join('\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
    a.download = `fluxo-consolidado-${visao}.csv`; a.click();
  };

  if (erro) return <section className="secao"><h2>Fluxo consolidado</h2><p className="erro">{erro}</p></section>;
  if (!vendas || !ctx) return <section className="secao"><h2>Fluxo consolidado</h2><p className="vazio">Carregando…</p></section>;

  const filtro = (k: keyof typeof f, rotulo: string, lista: string[]) => (
    <label>{rotulo}
      <select value={f[k]} onChange={(e) => setF((x) => ({ ...x, [k]: e.target.value }))}>
        <option value="">Todas</option>
        {lista.map((o) => <option key={o} value={o}>{o}</option>)}
      </select>
    </label>
  );
  const algumFiltro = Object.values(f).some((v) => v.trim());

  return (
    <section className="secao fluxo-consolidado">
      <div className="secao-topo">
        <div>
          <h2>Fluxo consolidado</h2>
          <p className="sub">Propostas aprovadas, com a comissão abatida. Valores nominais, sem correção pelo INCC. Permutas ficam fora do caixa.</p>
        </div>
        <button className="botao" onClick={exportar} disabled={!fluxo.length}><FileSpreadsheet size={16} /> Exportar CSV</button>
      </div>

      <div className="cartao fluxo-filtros">
        {filtro('unidade', 'Unidade', opcoes.unidade)}
        {filtro('imobiliaria', 'Imobiliária', opcoes.imobiliaria)}
        <label>Cliente<input type="search" value={f.cliente} placeholder="Nome do cliente" onChange={(e) => setF((x) => ({ ...x, cliente: e.target.value }))} /></label>
        {filtro('tipologia', 'Tipologia', opcoes.tipologia)}
        {filtro('final', 'Final', opcoes.final)}
        <button className="botao" disabled={!algumFiltro} onClick={() => setF({ unidade: '', imobiliaria: '', cliente: '', tipologia: '', final: '' })}>Consolidado</button>
      </div>

      {!filtradas.length ? (
        <div className="cartao vazio-grande"><p>{vendas.length ? 'Nenhuma proposta aprovada com esses filtros.' : 'Ainda não há propostas aprovadas.'}</p></div>
      ) : (
        <>
          <div className="kpis fluxo-kpis">
            <Kpi rotulo="Unidades" valor={String(tot.n)} detalhe={`${fmtNum(tot.area)} m²`} />
            <Kpi rotulo="VGV aprovado" valor={fmtReal(tot.vgv)} detalhe={`${fmtReal(tot.m2)}/m² médio`} />
            <Kpi rotulo="Comissão" valor={fmtReal(tot.comissao)} detalhe={tot.vgv > 0 ? `${fmtPct(tot.comissao / tot.vgv, 2)} do VGV` : ''} />
            <Kpi rotulo="Líquido incorporador" valor={fmtReal(tot.liquido)} detalhe={tot.permuta > 0 ? `Permutas fora do caixa: ${fmtReal(tot.permuta)}` : 'Bruto − comissão'} />
            <Kpi rotulo="Até as chaves" valor={fmtReal(tot.chaves)} detalhe={tot.liquido > 0 ? `${fmtPct(tot.chaves / tot.liquido)} do líquido` : ''} />
            <Kpi rotulo="Financiamento" valor={fmtReal(tot.pos)} detalhe={tot.liquido > 0 ? `${fmtPct(tot.pos / tot.liquido)} do líquido` : ''} />
          </div>

          <div className="cartao">
            <div className="cartao-topo">
              <h3>Curva de recebimento</h3>
              <div className="segmentos">
                <button className={visao === 'mensal' ? 'ativo' : ''} onClick={() => setVisao('mensal')}>Mensal</button>
                <button className={visao === 'anual' ? 'ativo' : ''} onClick={() => setVisao('anual')}>Anual</button>
              </div>
            </div>
            <Grafico fluxo={fluxo} anual={visao === 'anual'} />
            <p className="dica">Barras: líquido do período (até as chaves e financiamento). Linha: % acumulado do líquido.</p>
          </div>

          <div className="cartao">
            <h3>{visao === 'mensal' ? 'Fluxo mês a mês' : 'Fluxo ano a ano'}</h3>
            <div className="tabela-rolagem">
              <table className="tabela fluxo-tabela">
                <thead><tr><th>Período</th><th className="dir">Bruto</th><th className="dir">Comissão</th><th className="dir">Líquido</th><th className="dir">Até as chaves</th><th className="dir">Financiamento</th><th className="dir">Acumulado</th><th className="dir">% acum.</th></tr></thead>
                <tbody>
                  {fluxo.map((x) => (
                    <tr key={x.k} className={x.bruto === 0 ? 'zerado' : ''}>
                      <td>{visao === 'anual' ? x.k : fmtMesCurto(x.k)}</td>
                      <td className="dir mono">{fmtReal(x.bruto)}</td>
                      <td className="dir mono">{x.comissao ? `−${fmtReal(x.comissao)}` : '—'}</td>
                      <td className="dir mono forte">{fmtReal(x.liquido)}</td>
                      <td className="dir mono">{fmtReal(x.chaves)}</td>
                      <td className="dir mono">{x.pos ? fmtReal(x.pos) : '—'}</td>
                      <td className="dir mono">{fmtReal(x.acum)}</td>
                      <td className="dir mono">{fmtPct(x.acumPct)}</td>
                    </tr>
                  ))}
                </tbody>
                <tfoot><tr><td>Total</td>
                  <td className="dir mono">{fmtReal(fluxo.reduce((t, x) => t + x.bruto, 0))}</td>
                  <td className="dir mono">−{fmtReal(fluxo.reduce((t, x) => t + x.comissao, 0))}</td>
                  <td className="dir mono forte">{fmtReal(tot.liquido)}</td>
                  <td className="dir mono">{fmtReal(tot.chaves)}</td>
                  <td className="dir mono">{fmtReal(tot.pos)}</td>
                  <td colSpan={2} />
                </tr></tfoot>
              </table>
            </div>
          </div>

          <div className="cartao">
            <div className="cartao-topo">
              <h3>Estatísticas</h3>
              <label className="em-linha">Agrupar por
                <select value={agrupar} onChange={(e) => setAgrupar(e.target.value as typeof agrupar)}>
                  <option value="imobiliaria">Imobiliária</option>
                  <option value="tipologia">Tipologia</option>
                  <option value="final">Final</option>
                </select>
              </label>
            </div>
            <div className="tabela-rolagem">
              <table className="tabela">
                <thead><tr><th>{agrupar === 'imobiliaria' ? 'Imobiliária' : agrupar === 'tipologia' ? 'Tipologia' : 'Final'}</th><th className="dir">Unidades</th><th className="dir">VGV</th><th className="dir">% do VGV</th><th className="dir">Ticket médio</th><th className="dir">R$/m²</th><th className="dir">Comissão</th><th className="dir">Líquido</th></tr></thead>
                <tbody>
                  {grupos.map(([k, g]) => (
                    <tr key={k}><td>{k}</td><td className="dir">{g.n}</td><td className="dir mono">{fmtReal(g.vgv)}</td><td className="dir mono">{fmtPct(g.vgv / tot.vgv)}</td>
                      <td className="dir mono">{fmtReal(g.vgv / g.n)}</td><td className="dir mono">{g.area > 0 ? fmtReal(g.vgv / g.area) : '—'}</td>
                      <td className="dir mono">{fmtReal(g.comissao)}</td><td className="dir mono">{fmtReal(g.liquido)}</td></tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          <div className="cartao">
            <h3>Propostas no fluxo ({filtradas.length})</h3>
            <div className="tabela-rolagem">
              <table className="tabela">
                <thead><tr><th>Proposta</th><th>Unidade</th><th>Cliente</th><th>Imobiliária</th><th>Tipologia</th><th className="dir">VGV</th><th className="dir">Comissão</th><th className="dir">Líquido</th></tr></thead>
                <tbody>
                  {[...filtradas].sort((a, b) => a.unidade.localeCompare(b.unidade, 'pt-BR', { numeric: true })).map((v) => (
                    <tr key={v.id}><td><a href={`/painel/propostas/${v.id}`}>{v.codigo}</a></td><td>{v.unidade}</td><td>{v.cliente}</td><td>{v.imobiliaria}</td><td>{v.tipologia}</td>
                      <td className="dir mono">{fmtReal(v.vgv)}</td><td className="dir mono">{fmtReal(v.comissao)}</td><td className="dir mono">{fmtReal(v.liquido)}</td></tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}
    </section>
  );
}

function Kpi({ rotulo, valor, detalhe }: { rotulo: string; valor: string; detalhe?: string }) {
  return <div className="kpi"><strong className="kpi-valor">{valor}</strong><span className="kpi-rotulo">{rotulo}</span>{detalhe && <span className="kpi-detalhe">{detalhe}</span>}</div>;
}

/** Barras do líquido por período (chaves + financiamento) e linha do % acumulado. */
function Grafico({ fluxo, anual }: { fluxo: { k: string; chaves: number; pos: number; acumPct: number }[]; anual: boolean }) {
  const [sobre, setSobre] = useState<number | null>(null);
  const W = 960, H = 280, e = 56, d = 44, t = 14, b = 30;
  const larg = W - e - d, alt = H - t - b;
  const max = Math.max(1, ...fluxo.map((x) => x.chaves + x.pos));
  const passo = larg / Math.max(1, fluxo.length);
  const bw = Math.max(2, passo * 0.72);
  const y = (v: number) => t + alt - (v / max) * alt;
  const yp = (p: number) => t + alt - p * alt;
  const marcas = [0, 0.25, 0.5, 0.75, 1];
  const cadaRotulo = anual ? 1 : Math.max(1, Math.ceil(fluxo.length / 12));
  const curto = (v: number) => (v >= 1e6 ? `${fmtNum(v / 1e6, 1)} mi` : v >= 1e3 ? `${fmtNum(v / 1e3, 0)} mil` : fmtNum(v, 0));
  const linha = fluxo.map((x, i) => `${i ? 'L' : 'M'}${e + passo * i + passo / 2},${yp(x.acumPct)}`).join(' ');
  const s = sobre != null ? fluxo[sobre] : null;
  return (
    <div className="fluxo-grafico">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Curva de recebimento líquido" onMouseLeave={() => setSobre(null)}>
        {marcas.map((m) => (
          <g key={m}>
            <line x1={e} x2={W - d} y1={t + alt - m * alt} y2={t + alt - m * alt} className="grade" />
            <text x={e - 6} y={t + alt - m * alt + 4} textAnchor="end" className="eixo">{curto(max * m)}</text>
            <text x={W - d + 6} y={t + alt - m * alt + 4} className="eixo">{Math.round(m * 100)}%</text>
          </g>
        ))}
        {fluxo.map((x, i) => {
          const cx = e + passo * i + (passo - bw) / 2;
          return (
            <g key={x.k} onMouseEnter={() => setSobre(i)}>
              <rect x={e + passo * i} y={t} width={passo} height={alt} fill="transparent" />
              <rect x={cx} y={y(x.chaves)} width={bw} height={Math.max(0, t + alt - y(x.chaves))} className="barra-chaves" />
              <rect x={cx} y={y(x.chaves + x.pos)} width={bw} height={Math.max(0, y(x.chaves) - y(x.chaves + x.pos))} className="barra-pos" />
              {i % cadaRotulo === 0 && <text x={e + passo * i + passo / 2} y={H - 10} textAnchor="middle" className="eixo">{anual ? x.k : fmtMesCurto(x.k)}</text>}
            </g>
          );
        })}
        <path d={linha} className="linha-acum" />
      </svg>
      <div className="fluxo-legenda">
        <span><i className="barra-chaves" /> Até as chaves</span>
        <span><i className="barra-pos" /> Financiamento</span>
        <span><i className="linha-acum" /> % acumulado</span>
        {s && <strong>{anual ? s.k : fmtMesCurto(s.k)}: {fmtReal(s.chaves + s.pos)} · {fmtPct(s.acumPct)} acumulado</strong>}
      </div>
    </div>
  );
}
