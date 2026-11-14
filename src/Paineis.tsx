import { useEffect, useMemo, useState } from 'react';
import { supabase } from './dados';
import { type Perfil } from './util';
import { Inicio } from './Inicio';
import { carregarContexto, doBanco, traduzirErro, type Contexto, type PropostaSalva } from './proposta/dadosProposta';
import { fmtMes, fmtPct, fmtReal, parcelas, somarMeses, indiceMes } from './proposta/motor';

// =====================================================================
// Painéis da gestão comercial (equipe):
//   Visão geral (o antigo Início) · Vendas · Rankings · Carteira de
//   recebíveis · Propostas.
// =====================================================================

type Aba = 'geral' | 'vendas' | 'rankings' | 'carteira' | 'propostas';
const ABAS: { v: Aba; r: string }[] = [
  { v: 'geral', r: 'Visão geral' }, { v: 'vendas', r: 'Vendas' }, { v: 'rankings', r: 'Rankings' },
  { v: 'carteira', r: 'Carteira de recebíveis' }, { v: 'propostas', r: 'Propostas' },
];

interface Dados {
  gerado_em: string;
  unidades: Record<string, { n: number; vgv_tabela: number }> | null;
  vgv_tabela_total: number;
  vendas: Record<string, { n: number; vgv: number }> | null;
  por_mes: { mes: string; status: string; n: number }[];
  funil: { pastas: number; submetidas: number; aprovadas: number; com_unidade: number; proposta: number; contrato: number; vendida: number };
  ranking_imobiliarias: { nome: string; reservas: number; vendas: number; vendidas: number; vgv: number; pastas_aprovadas: number; pastas: number }[];
  ranking_corretores: { nome: string; imobiliaria: string; reservas: number; vendas: number; vgv: number }[];
  propostas: {
    por_status: Record<string, number>; automaticas: number; pv_medio_aprovadas: number | null; horas_medias_analise: number | null;
    aguardando_vendas: number; aguardando_admin: number; motivos: { codigo: string; status: string; motivo: string; em: string }[];
  };
}

const mi = (v: number) => (Math.abs(v) >= 1e6 ? `R$ ${(v / 1e6).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} mi` : fmtReal(v));
const nf = (v: number) => v.toLocaleString('pt-BR');

export function Paineis({ perfil }: { perfil: Perfil }) {
  const [aba, setAba] = useState<Aba>(() => (new URLSearchParams(window.location.search).get('aba') as Aba) || 'geral');
  const [dados, setDados] = useState<Dados | null>(null);
  const [erro, setErro] = useState('');

  useEffect(() => {
    if (aba === 'geral') return;
    supabase.rpc('paineis').then(({ data, error }) => {
      if (error) setErro(error.message.includes('function') ? 'O banco ainda não tem os painéis (migração 028).' : traduzirErro(error.message));
      else setDados(data as Dados);
    });
  }, [aba]);

  const trocar = (v: Aba) => {
    setAba(v);
    const url = new URL(window.location.href);
    if (v === 'geral') url.searchParams.delete('aba'); else url.searchParams.set('aba', v);
    window.history.replaceState(null, '', url);
  };

  return (
    <div className="paineis">
      <div className="abas paineis-abas" role="tablist">
        {ABAS.map((a) => <button key={a.v} role="tab" aria-selected={aba === a.v} className={aba === a.v ? 'ativa' : ''} onClick={() => trocar(a.v)}>{a.r}</button>)}
      </div>
      {aba === 'geral' ? <Inicio perfil={perfil} /> : (
        <section className="secao">
          {erro ? <p className="erro">{erro}</p> : !dados ? <p className="vazio">Carregando…</p> : (
            <>
              {aba === 'vendas' && <Vendas d={dados} />}
              {aba === 'rankings' && <Rankings d={dados} />}
              {aba === 'carteira' && <Carteira />}
              {aba === 'propostas' && <PropostasPainel d={dados} />}
              <p className="dica paineis-rodape">Atualizado em {new Date(dados.gerado_em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}.</p>
            </>
          )}
        </section>
      )}
    </div>
  );
}

function Kpi({ valor, rotulo, detalhe }: { valor: string; rotulo: string; detalhe?: string }) {
  return (
    <div className="kpi"><span className="kpi-valor kpi-texto">{valor}</span><span className="kpi-rotulo">{rotulo}</span>{detalhe && <span className="kpi-detalhe">{detalhe}</span>}</div>
  );
}

// ---------------------------------------------------------------------
// Gráfico de barras por mês (uma série), com valor ao passar o mouse
// ---------------------------------------------------------------------
function Barras({ dados, formato, rotuloSerie }: { dados: { rotulo: string; valor: number; detalhe?: string }[]; formato: (v: number) => string; rotuloSerie: string }) {
  const [foco, setFoco] = useState<number | null>(null);
  const W = 900, H = 220, e = 70, d = 10, topo = 10, base = 26;
  const max = Math.max(1, ...dados.map((x) => x.valor));
  const passo = (() => { const bruto = max / 4; const p = 10 ** Math.floor(Math.log10(bruto)); return [1, 2, 2.5, 5, 10].map((m) => m * p).find((v) => v >= bruto) ?? bruto; })();
  const topoY = Math.ceil(max / passo) * passo;
  const larg = (W - e - d) / Math.max(1, dados.length);
  const y = (v: number) => topo + (1 - v / topoY) * (H - topo - base);
  const rotulos = dados.length > 18 ? Math.ceil(dados.length / 12) : 1;
  return (
    <div className="grafico-barras">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={rotuloSerie}>
        {Array.from({ length: Math.round(topoY / passo) + 1 }, (_, k) => k * passo).map((v) => (
          <g key={v}><line x1={e} x2={W - d} y1={y(v)} y2={y(v)} className="grade-linha" /><text x={e - 8} y={y(v) + 4} textAnchor="end" className="eixo">{v === 0 ? '0' : formato(v)}</text></g>
        ))}
        {dados.map((b, i) => {
          const x = e + i * larg + Math.max(1, larg * 0.18);
          const w = Math.max(2, larg * 0.64);
          const h = Math.max(0, H - base - y(b.valor));
          return (
            <g key={b.rotulo} onPointerEnter={() => setFoco(i)} onPointerLeave={() => setFoco(null)}>
              <rect x={e + i * larg} y={topo} width={larg} height={H - topo - base} fill="transparent" />
              {b.valor > 0 && <path className={`barra${foco === i ? ' foco' : ''}`} d={`M${x},${H - base} V${H - base - h + Math.min(4, h)} q0,-${Math.min(4, h)} ${Math.min(4, w / 2)},-${Math.min(4, h)} H${x + w - Math.min(4, w / 2)} q${Math.min(4, w / 2)},0 ${Math.min(4, w / 2)},${Math.min(4, h)} V${H - base} Z`} />}
              {i % rotulos === 0 && <text x={e + i * larg + larg / 2} y={H - 8} textAnchor="middle" className="eixo">{b.rotulo}</text>}
            </g>
          );
        })}
      </svg>
      {foco != null && dados[foco] && (
        <div className="dica-grafico" style={{ left: `${((e + foco * larg + larg / 2) / W) * 100}%` }}>
          <strong>{dados[foco].rotulo}</strong>
          <span>{rotuloSerie} <b>{formato(dados[foco].valor)}</b></span>
          {dados[foco].detalhe && <span className="dif">{dados[foco].detalhe}</span>}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------
// Vendas
// ---------------------------------------------------------------------
function Vendas({ d }: { d: Dados }) {
  const u = d.unidades ?? {};
  const n = (s: string) => u[s]?.n ?? 0;
  const total = Object.values(u).reduce((t, x) => t + x.n, 0);
  const v = d.vendas ?? {};
  const vendidas = ['proposta', 'contrato', 'vendida'].reduce((t, s) => t + (v[s]?.n ?? 0), 0);
  const vgvVendido = ['proposta', 'contrato', 'vendida'].reduce((t, s) => t + (v[s]?.vgv ?? 0), 0);
  const estoqueTabela = u.disponivel?.vgv_tabela ?? 0;

  // meses: últimos 12, com vendas (chegou a "Proposta recebida") e VSO
  const meses = useMemo(() => {
    const hoje = new Date();
    const atual = `${hoje.getFullYear()}-${String(hoje.getMonth() + 1).padStart(2, '0')}`;
    const lista = Array.from({ length: 12 }, (_, i) => somarMeses(atual, i - 11));
    const de = (m: string, s: string) => d.por_mes.find((x) => x.mes === m && x.status === s)?.n ?? 0;
    // estoque no início do mês ≈ disponíveis hoje + vendas do mês em diante
    let depois = 0;
    const linhas = lista.map((m) => ({ m, reservas: de(m, 'reservada'), vendas: de(m, 'proposta'), estoque: 0, vso: 0 })).reverse();
    for (const l of linhas) { depois += l.vendas; l.estoque = n('disponivel') + n('reservada') + depois; l.vso = l.estoque > 0 ? l.vendas / l.estoque : 0; }
    return linhas.reverse();
  }, [d]); // eslint-disable-line react-hooks/exhaustive-deps

  const f = d.funil;
  const etapas = [
    { r: 'Pastas criadas', v: f.pastas }, { r: 'Submetidas ao incorporador', v: f.submetidas }, { r: 'Documentação aprovada', v: f.aprovadas },
    { r: 'Com unidade reservada', v: f.com_unidade }, { r: 'Proposta recebida', v: f.proposta }, { r: 'Contrato em assinatura', v: f.contrato }, { r: 'Vendida', v: f.vendida },
  ];
  const maxF = Math.max(1, ...etapas.map((x) => x.v));

  return (
    <>
      <div className="kpis">
        <Kpi valor={mi(vgvVendido)} rotulo="VGV vendido" detalhe={`${nf(vendidas)} unidades, de proposta recebida a vendida`} />
        <Kpi valor={total ? fmtPct(vendidas / total) : '—'} rotulo="Unidades vendidas" detalhe={`${nf(vendidas)} de ${nf(total)}`} />
        <Kpi valor={vendidas ? mi(vgvVendido / vendidas) : '—'} rotulo="Ticket médio" />
        <Kpi valor={mi(estoqueTabela)} rotulo="Estoque a preço de tabela" detalhe={`${nf(n('disponivel'))} disponíveis · VGV total ${mi(d.vgv_tabela_total)}`} />
      </div>

      <div className="cartao">
        <div className="cartao-topo"><h3>Vendas por mês</h3><span className="dica">Unidades que chegaram a "Proposta recebida" no mês</span></div>
        <Barras dados={meses.map((l) => ({ rotulo: fmtMes(l.m).replace(/\/(\d\d)(\d\d)$/, '/$2'), valor: l.vendas, detalhe: `VSO ${fmtPct(l.vso)} · ${l.reservas} reservas` }))} formato={(x) => nf(Math.round(x))} rotuloSerie="Vendas" />
        <div className="tabela-rolagem">
          <table className="tabela compacta">
            <thead><tr><th>Mês</th>{meses.map((l) => <th key={l.m} className="dir">{fmtMes(l.m).replace(/\/(\d\d)(\d\d)$/, '/$2')}</th>)}</tr></thead>
            <tbody>
              <tr><td>Reservas</td>{meses.map((l) => <td key={l.m} className="dir mono">{l.reservas}</td>)}</tr>
              <tr><td>Vendas</td>{meses.map((l) => <td key={l.m} className="dir mono">{l.vendas}</td>)}</tr>
              <tr><td>VSO</td>{meses.map((l) => <td key={l.m} className="dir mono">{l.vendas ? fmtPct(l.vso) : '—'}</td>)}</tr>
            </tbody>
          </table>
        </div>
        <p className="dica">VSO (vendas sobre oferta) = vendas do mês ÷ estoque no início do mês (disponíveis + reservadas).</p>
      </div>

      <div className="cartao">
        <div className="cartao-topo"><h3>Funil comercial</h3><span className="dica">Da pasta à venda, com a conversão de cada etapa</span></div>
        <ul className="funil-barras">
          {etapas.map((x, i) => (
            <li key={x.r}>
              <span className="funil-rotulo">{x.r}</span>
              <span className="funil-trilho"><span style={{ width: `${(x.v / maxF) * 100}%` }} /></span>
              <span className="funil-n mono">{nf(x.v)}</span>
              <span className="funil-conv mono">{i > 0 && etapas[i - 1].v > 0 ? fmtPct(x.v / etapas[i - 1].v, 0) : ''}</span>
            </li>
          ))}
        </ul>
      </div>
    </>
  );
}

// ---------------------------------------------------------------------
// Rankings
// ---------------------------------------------------------------------
function Rankings({ d }: { d: Dados }) {
  const [por, setPor] = useState<'vgv' | 'vendas'>('vgv');
  const ord = <T extends { vgv: number; vendas: number; reservas: number }>(l: T[]) =>
    [...l].sort((a, b) => (por === 'vgv' ? b.vgv - a.vgv || b.vendas - a.vendas : b.vendas - a.vendas || b.vgv - a.vgv) || b.reservas - a.reservas);
  const imobs = ord(d.ranking_imobiliarias);
  const corretores = ord(d.ranking_corretores);
  const totalVgv = imobs.reduce((t, x) => t + x.vgv, 0);
  const maxI = Math.max(1, ...imobs.map((x) => (por === 'vgv' ? x.vgv : x.vendas)));
  const maxC = Math.max(1, ...corretores.map((x) => (por === 'vgv' ? x.vgv : x.vendas)));
  const medalha = (i: number) => (i < 3 ? <span className={`medalha m${i + 1}`}>{i + 1}</span> : <span className="medalha">{i + 1}</span>);

  return (
    <>
      <div className="segmentos-linha">
        <span className="dica">Ordenar por</span>
        <div className="segmentos">
          <button className={por === 'vgv' ? 'ativo' : ''} onClick={() => setPor('vgv')}>VGV</button>
          <button className={por === 'vendas' ? 'ativo' : ''} onClick={() => setPor('vendas')}>Unidades</button>
        </div>
      </div>
      <div className="cartao">
        <h3>Imobiliárias</h3>
        {imobs.length === 0 ? <p className="vazio">Nenhuma unidade negociada ainda.</p> : (
          <div className="tabela-rolagem">
            <table className="tabela ranking">
              <thead><tr><th>#</th><th>Imobiliária</th><th className="dir">Pastas aprovadas</th><th className="dir">Reservas</th><th className="dir">Vendas</th><th className="dir">VGV</th><th className="dir">% do VGV</th><th className="dir">Conversão</th><th className="barra-col" /></tr></thead>
              <tbody>
                {imobs.map((x, i) => (
                  <tr key={x.nome}>
                    <td>{medalha(i)}</td><td>{x.nome}</td>
                    <td className="dir mono">{x.pastas_aprovadas}</td><td className="dir mono">{x.reservas}</td><td className="dir mono">{x.vendas}</td>
                    <td className="dir mono">{mi(x.vgv)}</td><td className="dir mono">{totalVgv ? fmtPct(x.vgv / totalVgv) : '—'}</td>
                    <td className="dir mono" title="Vendas ÷ pastas aprovadas">{x.pastas_aprovadas ? fmtPct(x.vendas / x.pastas_aprovadas, 0) : '—'}</td>
                    <td className="barra-col"><span className="barra-inline"><span style={{ width: `${((por === 'vgv' ? x.vgv : x.vendas) / maxI) * 100}%` }} /></span></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
      <div className="cartao">
        <h3>Corretores</h3>
        {corretores.length === 0 ? <p className="vazio">Nenhuma unidade negociada ainda.</p> : (
          <div className="tabela-rolagem">
            <table className="tabela ranking">
              <thead><tr><th>#</th><th>Corretor</th><th>Imobiliária</th><th className="dir">Reservas</th><th className="dir">Vendas</th><th className="dir">VGV</th><th className="barra-col" /></tr></thead>
              <tbody>
                {corretores.map((x, i) => (
                  <tr key={x.nome + x.imobiliaria}>
                    <td>{medalha(i)}</td><td>{x.nome}</td><td className="dica">{x.imobiliaria}</td>
                    <td className="dir mono">{x.reservas}</td><td className="dir mono">{x.vendas}</td><td className="dir mono">{mi(x.vgv)}</td>
                    <td className="barra-col"><span className="barra-inline"><span style={{ width: `${((por === 'vgv' ? x.vgv : x.vendas) / maxC) * 100}%` }} /></span></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
      <p className="dica">Vendas = unidades de "Proposta recebida" a "Vendida". VGV = valor de venda informado na negociação.</p>
    </>
  );
}

// ---------------------------------------------------------------------
// Carteira de recebíveis (a partir das propostas aprovadas)
// ---------------------------------------------------------------------
function Carteira() {
  const [ctx, setCtx] = useState<Contexto | null>(null);
  const [props, setProps] = useState<(PropostaSalva & { unidades: { numero: string } | null })[] | null>(null);
  const [erro, setErro] = useState('');
  useEffect(() => {
    carregarContexto().then((c) => { if ('erro' in c) setErro(c.erro); else setCtx(c); });
    supabase.from('propostas').select('id, codigo, series, resumo, unidade_id, unidades(numero)').eq('status', 'aprovada')
      .then(({ data, error }) => { if (error) setErro(traduzirErro(error.message)); else setProps((data ?? []) as never); });
  }, []);

  const calc = useMemo(() => {
    if (!ctx || !props) return null;
    const mesesMap = new Map<string, { direto: number; permuta: number; fin: number }>();
    let direto = 0, permuta = 0, fin = 0, sinal = 0, vplT = 0, vplP = 0, total = 0;
    for (const p of props) {
      const ps = parcelas(ctx.cfg, doBanco(p.series));
      for (const x of ps) {
        const mes = x.data.slice(0, 7);
        const m = mesesMap.get(mes) ?? { direto: 0, permuta: 0, fin: 0 };
        if (x.periodicidade === 'Financiamento') { m.fin += x.valor; fin += x.valor; }
        else if (x.periodicidade === 'Permuta') { m.permuta += x.valor; permuta += x.valor; }
        else { m.direto += x.valor; direto += x.valor; if (x.periodicidade === 'Sinal') sinal += x.valor; }
        mesesMap.set(mes, m);
      }
      vplT += Number(p.resumo.vpl_tabela ?? 0); vplP += Number(p.resumo.vpl_proposta ?? 0); total += Number(p.resumo.total ?? 0);
    }
    const chaves = Array.from(mesesMap.keys()).sort();
    const ini = chaves[0], fim = chaves[chaves.length - 1];
    const meses = ini ? Array.from({ length: indiceMes(fim) - indiceMes(ini) + 1 }, (_, i) => somarMeses(ini, i)).map((m) => ({ m, ...(mesesMap.get(m) ?? { direto: 0, permuta: 0, fin: 0 }) })) : [];
    const anos = new Map<string, { direto: number; permuta: number; fin: number }>();
    for (const m of meses) { const a = anos.get(m.m.slice(0, 4)) ?? { direto: 0, permuta: 0, fin: 0 }; a.direto += m.direto; a.permuta += m.permuta; a.fin += m.fin; anos.set(m.m.slice(0, 4), a); }
    return { meses, anos: Array.from(anos.entries()), direto, permuta, fin, sinal, vplT, vplP, total };
  }, [ctx, props]);

  if (erro) return <p className="erro">{erro}</p>;
  if (!calc) return <p className="vazio">Carregando…</p>;
  if (!props?.length) return <div className="cartao vazio-grande"><p>A carteira é montada com as propostas aprovadas. Nenhuma proposta aprovada ainda.</p></div>;
  const c = calc;
  return (
    <>
      <div className="kpis">
        <Kpi valor={mi(c.total)} rotulo="Carteira total" detalhe={`${props.length} propostas aprovadas`} />
        <Kpi valor={mi(c.direto)} rotulo="Direto até as chaves" detalhe={`Sinal ${mi(c.sinal)} · parcelas ${mi(c.direto - c.sinal)}`} />
        <Kpi valor={mi(c.fin)} rotulo="Financiamento" detalhe={c.permuta ? `Permutas ${mi(c.permuta)}` : 'Pós-chaves'} />
        <Kpi valor={c.vplT ? fmtPct(c.vplP / c.vplT - 1, 2) : '—'} rotulo="VPL vendido × tabela" detalhe={`VPL ${mi(c.vplP)} · tabela ${mi(c.vplT)}`} />
      </div>
      <div className="cartao">
        <div className="cartao-topo"><h3>Recebimentos diretos por mês</h3><span className="dica">Sinal e parcelas até as chaves (sem financiamento e permuta)</span></div>
        <Barras dados={c.meses.map((m) => ({ rotulo: fmtMes(m.m).replace(/\/(\d\d)(\d\d)$/, '/$2'), valor: m.direto, detalhe: m.fin || m.permuta ? `Financiamento ${mi(m.fin)}${m.permuta ? ` · permuta ${mi(m.permuta)}` : ''}` : undefined }))}
          formato={(v) => (v >= 1e6 ? `${(v / 1e6).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} mi` : `${Math.round(v / 1000)} mil`)} rotuloSerie="Recebimento direto" />
      </div>
      <div className="cartao">
        <h3>Por ano</h3>
        <div className="tabela-rolagem">
          <table className="tabela">
            <thead><tr><th>Ano</th><th className="dir">Direto (sinal + parcelas)</th><th className="dir">Permuta</th><th className="dir">Financiamento</th><th className="dir">Total</th></tr></thead>
            <tbody>
              {c.anos.map(([a, v]) => (
                <tr key={a}><td>{a}</td><td className="dir mono">{fmtReal(v.direto)}</td><td className="dir mono">{fmtReal(v.permuta)}</td><td className="dir mono">{fmtReal(v.fin)}</td><td className="dir mono forte">{fmtReal(v.direto + v.permuta + v.fin)}</td></tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="dica">Valores nominais, sem correção pelo INCC/IGP-M. Considera só as propostas aprovadas no sistema.</p>
      </div>
    </>
  );
}

// ---------------------------------------------------------------------
// Propostas
// ---------------------------------------------------------------------
function PropostasPainel({ d }: { d: Dados }) {
  const p = d.propostas;
  const s = (k: string) => p.por_status[k] ?? 0;
  return (
    <>
      <div className="kpis">
        <Kpi valor={nf(s('enviada'))} rotulo="Aguardando análise" detalhe={`${p.aguardando_vendas} Sec. Vendas · ${p.aguardando_admin} administrador`} />
        <Kpi valor={nf(s('aprovada'))} rotulo="Aprovadas" detalhe={`${p.automaticas} automáticas`} />
        <Kpi valor={p.pv_medio_aprovadas != null ? `${p.pv_medio_aprovadas.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}%` : '—'} rotulo="PV médio das aprovadas" detalhe="VPL da proposta ÷ VPL da tabela" />
        <Kpi valor={p.horas_medias_analise != null ? `${p.horas_medias_analise.toLocaleString('pt-BR')} h` : '—'} rotulo="Tempo médio de análise" detalhe="Do envio à decisão da equipe" />
      </div>
      <div className="cartao">
        <h3>Situação</h3>
        <div className="kpis">
          <Kpi valor={nf(s('devolvida'))} rotulo="Devolvidas para ajuste" />
          <Kpi valor={nf(s('recusada'))} rotulo="Recusadas" />
          <Kpi valor={nf(s('cancelada'))} rotulo="Canceladas" />
          <Kpi valor={nf(Object.values(p.por_status).reduce((t, x) => t + x, 0))} rotulo="Total enviadas" />
        </div>
      </div>
      <div className="cartao">
        <h3>Últimos motivos de devolução e recusa</h3>
        {p.motivos.length === 0 ? <p className="vazio">Nenhuma devolução ou recusa.</p> : (
          <ul className="lista-simples">
            {p.motivos.map((m) => <li key={m.codigo + m.em}><span><strong className="mono">{m.codigo}</strong> · {m.status === 'devolvida' ? 'Devolvida' : 'Recusada'}: {m.motivo}</span><small className="dica">{new Date(m.em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}</small></li>)}
          </ul>
        )}
      </div>
    </>
  );
}
