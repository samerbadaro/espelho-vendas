import { useEffect, useMemo, useState } from 'react';
import {
  aplicarModelo, calcular, dataDaParcela, fmtData, fmtMes, fmtNum, fmtPct, fmtReal, mesesEntre, novoId, ordenarSeries,
  PERIODICIDADES, TOLERANCIA_PV, aumentarSinal, redistribuir, somarMeses, type ConfigEmpreendimento, type Modelo, type Periodicidade, type Resultado,
  type Serie, type Unidade,
} from './motor';
import './proposta.css';

// =====================================================================
// Editor da proposta — simples como a planilha: uma grade de séries
// editável, botões de preenchimento e o comparativo tabela × proposta
// calculado na hora.
// =====================================================================
/** Número em pt-BR: "1.234,56" ↔ 1234.56 */
function lerNumero(s: string) {
  const limpo = s.replace(/[^\d,.-]/g, '');
  const n = limpo.includes(',') ? Number(limpo.replace(/\./g, '').replace(',', '.')) : Number(limpo);
  return Number.isFinite(n) ? n : NaN;
}

function CelulaNumero({ valor, casas = 2, aoMudar, rotulo }: { valor: number; casas?: number; aoMudar: (n: number) => void; rotulo: string }) {
  const [texto, setTexto] = useState<string | null>(null);
  return (
    <input
      className="celula num"
      aria-label={rotulo}
      inputMode="decimal"
      value={texto ?? (Number.isFinite(valor) ? fmtNum(valor, casas) : '')}
      onFocus={(e) => { setTexto(Number.isFinite(valor) ? fmtNum(valor, casas).replace(/\./g, '') : ''); requestAnimationFrame(() => e.target.select()); }}
      onChange={(e) => setTexto(e.target.value)}
      onBlur={() => { if (texto !== null) { const n = lerNumero(texto); if (!Number.isNaN(n)) aoMudar(n); } setTexto(null); }}
      onKeyDown={(e) => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur(); if (e.key === 'Escape') { setTexto(null); (e.target as HTMLInputElement).blur(); } }}
    />
  );
}

export interface EstadoEditor { series: Serie[]; comissaoPct: number; parteSinal: number; coordenacaoPct: number; coordenacaoParcelas: number; resultado: Resultado }

export function EditorProposta({
  cfg, unidade, hoje, dataMinima, dias, seriesIniciais, comissaoInicial, parteInicial, coordPctInicial, coordParcelasInicial, nomeCoordenacao,
  somenteLeitura = false, podeEditarComissao = false, aoMudar, observacoes,
}: {
  cfg: ConfigEmpreendimento; unidade: Unidade; hoje: string; dataMinima: string; dias: number[];
  seriesIniciais?: Serie[]; comissaoInicial?: number | null; parteInicial?: number | null;
  coordPctInicial?: number | null; coordParcelasInicial?: number | null; nomeCoordenacao?: string | null;
  somenteLeitura?: boolean; podeEditarComissao?: boolean; aoMudar?: (e: EstadoEditor) => void;
  /** Texto das observações da proposta (a permuta exige descrição). */
  observacoes?: string;
}) {
  const CFG = cfg;
  const preChavesTabela = CFG.tabelas[unidade.tabela].filter((s) => s.periodicidade !== 'Financiamento').reduce((s, x) => s + x.percentual, 0);
  const [dia, setDia] = useState(dias.includes(10) ? 10 : dias[0] ?? 10);
  const [preChaves, setPreChaves] = useState<number | null>(null); // null = o da tabela
  const [series, setSeries] = useState<Serie[]>(() => ordenarSeries(seriesIniciais ?? aplicarModelo(CFG, unidade, 'tabela', { dia, hoje })));
  const [comissaoPct, setComissaoPct] = useState(comissaoInicial ?? CFG.comissao.percentual);
  const [parteSinal, setParteSinal] = useState(parteInicial ?? CFG.comissao.parteDoSinal);
  // coordenação de vendas: percentual fixo do parâmetro (o da proposta salva, se houver); parcelas de 1 a 3 (exceção por proposta)
  const nomeCoord = nomeCoordenacao?.trim() || 'Coordenação';
  const coordPct = coordPctInicial != null ? Number(coordPctInicial) : (CFG.comissao.coordenacao ?? 0);
  const [coordParcelas, setCoordParcelas] = useState(Number(coordParcelasInicial ?? CFG.comissao.coordenacaoParcelas ?? 2));
  const [mensagem, setMensagem] = useState<string | null>(null);
  const [verFluxo, setVerFluxo] = useState(false);
  // "⟲ ajustar": iguala o PV (valor presente) ou o valor nominal ao da tabela
  const [meta, setMeta] = useState<'pv' | 'nominal'>('pv');

  const r = useMemo(
    () => calcular(CFG, unidade, series, {
      dataMinima, comissaoPercentual: comissaoPct, parteDoSinal: parteSinal, coordenacao: coordPct, coordenacaoParcelas: coordParcelas, diasVencimento: dias, observacoes,
    }),
    [CFG, unidade, series, dataMinima, comissaoPct, parteSinal, coordPct, coordParcelas, dias, observacoes],
  );
  useEffect(() => { aoMudar?.({ series, comissaoPct, parteSinal, coordenacaoPct: coordPct, coordenacaoParcelas: coordParcelas, resultado: r }); }, [r]); // eslint-disable-line react-hooks/exhaustive-deps

  const modelo = (m: Modelo) => {
    setSeries(aplicarModelo(CFG, unidade, m, { dia, hoje, preChaves: preChaves ?? preChavesTabela }));
    setMensagem(null);
  };
  const mudar = (id: string, campo: Partial<Serie>) => setSeries((l) => l.map((s) => (s.id === id ? { ...s, ...campo } : s)));
  const remover = (id: string) => setSeries((l) => l.filter((s) => s.id !== id));
  /** Reordena por data (financiamento sempre por último): ao sair do campo de data, ao trocar a periodicidade e ao incluir. */
  const ordenar = () => setSeries((l) => { const o = ordenarSeries(l); return o.every((x, i) => x === l[i]) ? l : o; });
  const adicionar = () => {
    // a nova série entra depois da última parcela antes das chaves (não depois do financiamento)
    const antes = series.filter((x) => x.periodicidade !== 'Financiamento');
    const ultima = antes[antes.length - 1];
    const venc = ultima ? dataDaParcela(ultima, ultima.qtd) : hoje;
    setSeries((l) => ordenarSeries([...l, { id: novoId(), qtd: 1, periodicidade: 'Mensais', vencimento: venc < dataMinima ? dataMinima : venc, valor: 0 }]));
  };
  const pvZero = (id: string) => {
    const res = redistribuir(CFG, unidade, series, id, meta);
    if ('erro' in res) setMensagem(res.erro);
    else if ('aviso' in res) { setSeries(res.series); setMensagem(res.aviso); }
    else { setSeries(res); setMensagem(null); }
  };

  const avisosDa = (id: string) => r.avisos.filter((a) => a.serieId === id);
  const difNominal = r.proposta.total - r.tabela.total;
  const sinalR = (v: number) => `${v > 0.005 ? '+' : v < -0.005 ? '−' : ''}${fmtReal(Math.abs(v))}`;
  const chaves = r.marcos.find((m) => m.rotulo === 'Até a entrega');
  const capDif = chaves ? chaves.proposta * r.proposta.total - chaves.tabela * r.tabela.total : 0;
  const avisosGerais = r.avisos.filter((a) => !a.serieId);
  const positivo = r.diferencaVPL >= -TOLERANCIA_PV;
  const outrosErros = r.avisos.some((a) => a.nivel === 'erro');
  const estado = !positivo ? 'ruim' : outrosErros ? 'pendente' : 'bom';
  const ro = somenteLeitura;

  return (
    <div className="prop">
      {!ro && (
        <section className="prop-bloco prop-ferramentas">
          <div className="grupo">
            <span>Vencimento</span>
            <div className="segmentos">
              {dias.map((d) => (
                <button key={d} className={d === dia ? 'ativo' : ''} onClick={() => setDia(d)}>dia {String(d).padStart(2, '0')}</button>
              ))}
            </div>
          </div>
          <div className="grupo">
            <span>Preencher</span>
            <div className="botoes">
              <button className="botao pequeno" onClick={() => modelo('tabela')}>Modelo da tabela</button>
              <button className="botao pequeno" onClick={() => modelo('entrega')}>Mensais até a entrega</button>
              <button className="botao pequeno" onClick={() => modelo('semestrais')}>Semestrais</button>
              <button className="botao pequeno" onClick={() => modelo('anuais')}>Anuais</button>
            </div>
          </div>
          <div className="grupo">
            <span title="O que o botão ⟲ ajustar de cada série iguala ao da tabela">Ajustar para</span>
            <div className="segmentos">
              <button className={meta === 'pv' ? 'ativo' : ''} onClick={() => setMeta('pv')} title="Sem desconto em valor presente">Zerar PV</button>
              <button className={meta === 'nominal' ? 'ativo' : ''} onClick={() => setMeta('nominal')} title="Mesmo valor total da tabela; o PV pode ficar abaixo">Zerar nominal</button>
            </div>
          </div>
          <div className="grupo">
            <span title="Quanto do preço é pago direto até as chaves (sinal incluso). O resto vai para o financiamento. Vale para Mensais, Semestrais e Anuais.">Até as chaves</span>
            <div className="pct">
              <CelulaNumero rotulo="Percentual até as chaves" valor={(preChaves ?? preChavesTabela) * 100} casas={1}
                aoMudar={(n) => setPreChaves(Math.min(100, Math.max(0, n)) / 100)} />
              <em>%</em>
            </div>
          </div>
        </section>
      )}

      {/* ===== Grade de séries ===== */}
      <section className="prop-bloco">
        <div className="tabela-rolagem">
          <table className="grade">
            <thead>
              <tr>
                <th>Nº parc.</th><th>Periodicidade</th><th>1º vencimento</th><th className="dir">Valor da parcela</th>
                <th className="dir">Total da série</th><th>Último venc.</th><th className="dir">% do total</th>{!ro && <><th title={meta === 'pv' ? 'Ajusta a parcela para o PV ficar igual ao da tabela' : 'Ajusta a parcela para o valor total ficar igual ao da tabela'}>{meta === 'pv' ? 'Zerar PV' : 'Zerar nominal'}</th><th /></>}
              </tr>
            </thead>
            <tbody>
              {series.map((s) => {
                const av = avisosDa(s.id);
                const totalSerie = s.valor * s.qtd;
                return (
                  <tr key={s.id} className={av.some((a) => a.nivel === 'erro') ? 'com-erro' : av.length ? 'com-alerta' : ''} title={av.map((a) => a.texto).join('\n')}>
                    {ro ? (
                      <>
                        <td className="dir mono">{s.qtd}</td>
                        <td className="mono">{PERIODICIDADES.find((p) => p.valor === s.periodicidade)?.rotulo}</td>
                        <td className="mono">{fmtData(s.vencimento)}</td>
                        <td className="dir mono">{fmtNum(s.valor)}</td>
                      </>
                    ) : (
                      <>
                        <td className="estreita"><CelulaNumero rotulo="Número de parcelas" valor={s.qtd} casas={0} aoMudar={(n) => mudar(s.id, { qtd: Math.max(1, Math.round(n)) })} /></td>
                        <td>
                          <select className="celula" value={s.periodicidade} onChange={(e) => { mudar(s.id, { periodicidade: e.target.value as Periodicidade }); ordenar(); }}>
                            {PERIODICIDADES.map((p) => <option key={p.valor} value={p.valor}>{p.rotulo}</option>)}
                          </select>
                        </td>
                        <td><input className="celula" type="date" min={dataMinima} value={s.vencimento} onChange={(e) => mudar(s.id, { vencimento: e.target.value })} onBlur={ordenar} /></td>
                        <td><CelulaNumero rotulo="Valor da parcela" valor={s.valor} aoMudar={(n) => mudar(s.id, { valor: Math.max(0, n) })} /></td>
                      </>
                    )}
                    <td className="dir mono">{fmtNum(totalSerie)}</td>
                    <td className="mono">{s.vencimento ? fmtData(dataDaParcela(s, s.qtd - 1)) : '—'}</td>
                    <td className="dir mono">{r.proposta.total > 0 ? fmtPct(totalSerie / r.proposta.total) : '—'}</td>
                    {!ro && <>
                      <td><button className="mini" onClick={() => pvZero(s.id)} title={meta === 'pv' ? 'Recalcula a parcela desta série para o PV ficar igual ao da tabela' : 'Recalcula a parcela desta série para o valor total ficar igual ao da tabela'}>⟲ ajustar</button></td>
                      <td><button className="mini x" onClick={() => remover(s.id)} aria-label="Remover série">✕</button></td>
                    </>}
                  </tr>
                );
              })}
            </tbody>
            <tfoot>
              <tr>
                <td colSpan={4}>{!ro && <button className="mini" onClick={adicionar}>+ adicionar série</button>}</td>
                <td className="dir mono forte">{fmtNum(r.proposta.total)}</td>
                <td /><td className="dir mono">100%</td>{!ro && <td colSpan={2} />}
              </tr>
            </tfoot>
          </table>
        </div>
        {mensagem && <p className="erro">{mensagem}</p>}
        {series.flatMap((s) => avisosDa(s.id).map((a, i) => (
          <p key={s.id + i} className={a.nivel === 'erro' ? 'erro' : 'alerta'}>{PERIODICIDADES.find((p) => p.valor === s.periodicidade)?.rotulo} ({s.qtd}x): {a.texto}</p>
        )))}
      </section>

      {/* ===== Resultado ===== */}
      <div className="prop-colunas">
        <section className="prop-bloco">
          <div className={`veredito ${estado}`}>
            <span>{estado === 'ruim' ? 'PV negativo' : estado === 'pendente' ? 'PV ok · corrigir os erros da grade' : 'PV aprovado'}</span>
            <strong>{r.diferencaVPL >= 0 ? '+' : ''}{fmtReal(r.diferencaVPL)}</strong>
            <em>{fmtPct(r.variacaoVPL, 2)} sobre o VPL da tabela</em>
          </div>
          <table className="comp">
            <thead><tr><th /><th className="dir">Tabela</th><th className="dir">Proposta</th><th className="dir">Variação</th><th className="dir">Diferença (R$)</th></tr></thead>
            <tbody>
              <tr><td>Valor total</td><td className="dir mono">{fmtReal(r.tabela.total)}</td><td className="dir mono">{fmtReal(r.proposta.total)}</td><td className="dir mono">{fmtPct(r.proposta.total / r.tabela.total - 1, 2)}</td><td className={`dir mono ${difNominal < -0.005 ? 'texto-ruim' : ''}`}>{sinalR(difNominal)}</td></tr>
              <tr><td>VPL ({fmtPct(CFG.taxaVP, 2)} a.m.)</td><td className="dir mono">{fmtReal(r.tabela.vpl)}</td><td className="dir mono">{fmtReal(r.proposta.vpl)}</td><td className="dir mono">{fmtPct(r.variacaoVPL, 2)}</td><td className={`dir mono ${r.diferencaVPL < -0.005 ? 'texto-ruim' : ''}`}>{sinalR(r.diferencaVPL)}</td></tr>
              <tr><td>Preço do m²</td><td className="dir mono">{fmtReal(r.tabela.m2)}</td><td className="dir mono">{fmtReal(r.proposta.m2)}</td><td className="dir mono">{fmtPct(r.proposta.m2 / r.tabela.m2 - 1, 2)}</td><td className="dir mono">{sinalR(r.proposta.m2 - r.tabela.m2)}</td></tr>
              {chaves && (
                <tr><td>Captação até as chaves</td>
                  <td className="dir mono">{fmtPct(chaves.tabela)}<br /><small>{fmtReal(chaves.tabela * r.tabela.total)}</small></td>
                  <td className="dir mono">{fmtPct(chaves.proposta)}<br /><small>{fmtReal(chaves.proposta * r.proposta.total)}</small></td>
                  <td className="dir mono">{chaves.variacao === null ? '—' : fmtPct(chaves.variacao, 2)}</td>
                  <td className={`dir mono ${capDif < -0.005 ? 'texto-ruim' : ''}`}>{sinalR(capDif)}</td></tr>
              )}
            </tbody>
          </table>
          <p className="dica">
            {difNominal < -0.005 ? <>Desconto nominal de <strong>{fmtReal(-difNominal)}</strong> sobre o valor de tabela. </> : difNominal > 0.005 ? <>Valor nominal <strong>{fmtReal(difNominal)}</strong> acima da tabela. </> : <>Valor nominal igual ao da tabela. </>}
            {r.diferencaVPL < -0.005 ? <>Desconto em valor presente de <strong>{fmtReal(-r.diferencaVPL)}</strong>.</> : <>Sem desconto em valor presente.</>}
          </p>
          {avisosGerais.length > 0 && (
            <ul className="prop-avisos">
              {avisosGerais.map((a, i) => <li key={i} className={a.nivel}>{a.texto}</li>)}
            </ul>
          )}
        </section>

        <section className="prop-bloco">
          <h2>Captação acumulada</h2>
          <table className="comp">
            <thead><tr><th /><th className="dir">Tabela</th><th className="dir">Proposta</th><th className="dir">Variação</th></tr></thead>
            <tbody>
              {r.marcos.map((m) => (
                <tr key={m.rotulo} className={m.variacao !== null && m.variacao < CFG.limiteVariacaoCaptacao ? 'linha-alerta' : ''}>
                  <td>{m.rotulo} <small>até {fmtMes(somarMeses(CFG.mesTabela, m.ateMes))}</small></td>
                  <td className="dir mono">{fmtPct(m.tabela)}</td>
                  <td className="dir mono">{fmtPct(m.proposta)}</td>
                  <td className="dir mono">{m.variacao === null ? '—' : fmtPct(m.variacao)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      </div>

      <section className="prop-bloco">
        <div className="titulo-linha">
          <h2>Fluxo acumulado: tabela × proposta</h2>
          <div className="legenda-grafico">
            <span><Traco tipo="tabela" />Tabela</span>
            <span><Traco tipo="proposta" />Proposta</span>
          </div>
        </div>
        <GraficoFluxo cfg={CFG} tabela={r.tabela.parcelas} proposta={r.proposta.parcelas} />
      </section>

      {/* ===== Comissão ===== */}
      <section className="prop-bloco">
        <div className="titulo-linha">
          <h2>Comissão</h2>
          <div className="params">
            {podeEditarComissao && !ro ? (
              <>
                <label>Imobiliária <span className="pct"><CelulaNumero rotulo="Comissão da imobiliária" valor={comissaoPct * 100} aoMudar={(n) => setComissaoPct(Math.max(0, n) / 100)} /><em>%</em></span></label>
                {coordPct > 0 && (
                  <label>{nomeCoord} {fmtPct(coordPct, 2)} em
                    <select value={coordParcelas} onChange={(e) => setCoordParcelas(Number(e.target.value))} aria-label="Parcelas da coordenação">
                      <option value={1}>1 parcela</option><option value={2}>2 parcelas</option><option value={3}>3 parcelas</option>
                    </select>
                  </label>
                )}
                <label>Do sinal para a comissão <span className="pct"><CelulaNumero rotulo="Parte do sinal para comissão" valor={parteSinal * 100} casas={0} aoMudar={(n) => setParteSinal(Math.min(100, Math.max(0, n)) / 100)} /><em>%</em></span></label>
              </>
            ) : (
              <span>Imobiliária {fmtPct(comissaoPct, 2)}{coordPct > 0 ? ` · ${nomeCoord} ${fmtPct(coordPct, 2)} em ${coordParcelas} parcela${coordParcelas > 1 ? 's' : ''}` : ''} · {fmtPct(parteSinal, 0)} do sinal para a comissão</span>
            )}
          </div>
        </div>
        {r.comissao.naoCoberta > 0.005 && (
          <div className="comissao-falta">
            <strong>Sinal insuficiente para destacar {fmtPct(comissaoPct + coordPct, 2)} de comissão.</strong>
            <span>
              Com sinal de {fmtPct(r.comissao.sinalPct, 2)} ({fmtReal(r.comissao.sinal)}) e {fmtPct(parteSinal, 0)} para a comissão,
              {' '}o máximo destacável é <strong>{fmtPct(r.comissao.maximoPct, 2)}</strong> ({fmtReal(r.comissao.destacada)}).
              {' '}Para destacar {fmtPct(comissaoPct + coordPct, 2)}, o sinal precisa ser de pelo menos <strong>{fmtPct(r.comissao.sinalNecessarioPct, 2)}</strong> ({fmtReal(r.comissao.sinalNecessario)}):
              {' '}aumente o sinal em <strong>{fmtReal(r.comissao.faltaSinal)}</strong> e reduza outra série.
            </span>
            {!ro && (
              <button className="mini" onClick={() => {
                // aumenta o ato o bastante para cobrir a comissão mesmo com o valor total subindo junto
                const T = r.proposta.total, S = r.comissao.sinal, c = comissaoPct + coordPct, p = parteSinal;
                const extra = p > c ? Math.max(0, (c * T - p * S) / (p - c)) : r.comissao.faltaSinal;
                setSeries((l) => aumentarSinal(l, extra));
                setMensagem('Sinal aumentado. Use "⟲ ajustar" em outra série (mensais, semestrais...) para voltar o PV e o valor total.');
              }}>Aumentar o ato para cobrir a comissão</button>
            )}
          </div>
        )}
        <p className="dica">
          Sinal de <strong>{fmtPct(r.comissao.sinalPct, 2)}</strong> ({fmtReal(r.comissao.sinal)}) · máximo destacável {fmtPct(r.comissao.maximoPct, 2)}.
          {' '}Comissão de <strong>{fmtReal(r.comissao.devida)}</strong> sobre o valor total
          {coordPct > 0 && <> (imobiliária {fmtReal(r.comissao.devidaImob)} + {nomeCoord} {fmtReal(r.comissao.devidaCoord)})</>}, paga com {fmtPct(parteSinal, 0)} de cada parcela de sinal até completar.
          {' '}Para o incorporador no sinal: <strong>{fmtReal(r.comissao.linhas.reduce((s, l) => s + l.incorporador, 0))}</strong>.
        </p>
        <div className="tabela-rolagem">
          <table className="comp comp-centro">
            <thead><tr><th>Vencimento</th><th className="dir">Parcela de sinal</th>{coordPct > 0 && <th className="dir">{nomeCoord}</th>}<th className="dir">Imobiliária</th><th className="dir">Incorporador</th></tr></thead>
            <tbody>
              {r.comissao.linhas.map((l, i) => (
                <tr key={i}><td className="mono">{fmtData(l.data)}</td><td className="dir mono">{fmtNum(l.parcela)}</td>{coordPct > 0 && <td className="dir mono destaque">{fmtNum(l.coordenacao)}</td>}<td className="dir mono destaque">{fmtNum(l.imobiliaria)}</td><td className="dir mono">{fmtNum(l.incorporador)}</td></tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {/* ===== Fluxo mensal ===== */}
      <section className="prop-bloco">
        <button className="mini" onClick={() => setVerFluxo((v) => !v)}>{verFluxo ? '▾' : '▸'} Fluxo mês a mês (tabela × proposta)</button>
        {verFluxo && <FluxoMensal cfg={CFG} tabela={r.tabela.parcelas} proposta={r.proposta.parcelas} />}
      </section>
    </div>
  );
}

function FluxoMensal({ cfg: CFG, tabela, proposta }: { cfg: ConfigEmpreendimento; tabela: { mes: number; valor: number }[]; proposta: { mes: number; valor: number }[] }) {
  const ultimo = Math.max(0, ...tabela.map((p) => p.mes), ...proposta.map((p) => p.mes));
  const primeiro = Math.min(0, ...proposta.map((p) => p.mes));
  const soma = (l: { mes: number; valor: number }[], m: number) => l.filter((p) => p.mes === m).reduce((s, p) => s + p.valor, 0);
  let at = 0, ap = 0;
  const linhas = [];
  for (let m = primeiro; m <= ultimo; m++) {
    const t = soma(tabela, m), p = soma(proposta, m);
    at += t; ap += p;
    if (t || p) linhas.push({ m, t, p, at, ap });
  }
  return (
    <div className="tabela-rolagem fluxo">
      <table className="comp">
        <thead><tr><th>Mês</th><th className="dir">Tabela</th><th className="dir">Proposta</th><th className="dir">Tabela acum.</th><th className="dir">Proposta acum.</th></tr></thead>
        <tbody>
          {linhas.map((l) => (
            <tr key={l.m}>
              <td className="mono">{fmtMes(somarMeses(CFG.mesTabela, l.m))}</td>
              <td className="dir mono">{fmtNum(l.t)}</td><td className="dir mono">{fmtNum(l.p)}</td>
              <td className="dir mono">{fmtNum(l.at)}</td><td className="dir mono">{fmtNum(l.ap)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="dica">{mesesEntre(CFG.mesTabela, CFG.mesEntrega)} meses da tabela até a entrega. O financiamento entra no VPL no mês seguinte à entrega.</p>
    </div>
  );
}

// ---------------------------------------------------------------------
// Gráfico do fluxo acumulado (como o da aba PV da planilha):
// tabela em âmbar tracejado, proposta em azul contínuo; passe o mouse
// para ver os valores do mês.
// ---------------------------------------------------------------------
function GraficoFluxo({ cfg, tabela, proposta }: { cfg: ConfigEmpreendimento; tabela: { mes: number; valor: number }[]; proposta: { mes: number; valor: number }[] }) {
  const [foco, setFoco] = useState<number | null>(null);
  const dados = useMemo(() => {
    const ini = Math.min(0, ...proposta.map((p) => p.mes));
    const fim = Math.max(1, ...tabela.map((p) => p.mes), ...proposta.map((p) => p.mes));
    const linhas: { m: number; t: number; p: number }[] = [];
    let t = 0, p = 0;
    for (let m = ini; m <= fim; m++) {
      t += tabela.filter((x) => x.mes === m).reduce((s, x) => s + x.valor, 0);
      p += proposta.filter((x) => x.mes === m).reduce((s, x) => s + x.valor, 0);
      linhas.push({ m, t, p });
    }
    return linhas;
  }, [tabela, proposta]);

  const W = 900, H = 260, e = 64, d = 16, topo = 12, base = 30;
  const maxV = Math.max(1, ...dados.map((x) => Math.max(x.t, x.p)));
  const passoY = [50_000, 100_000, 200_000, 250_000, 500_000, 1_000_000, 2_000_000].find((v) => maxV / v <= 5) ?? 5_000_000;
  const topoY = Math.ceil(maxV / passoY) * passoY;
  const x = (i: number) => e + (i / Math.max(1, dados.length - 1)) * (W - e - d);
  const y = (v: number) => topo + (1 - v / topoY) * (H - topo - base);
  const caminho = (k: 't' | 'p') => dados.map((pt, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(pt[k]).toFixed(1)}`).join('');
  const rotuloV = (v: number) => (v >= 1_000_000 ? `${(v / 1_000_000).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} mi` : `${Math.round(v / 1000)} mil`);
  const marcasX = dados.map((pt, i) => ({ pt, i })).filter(({ pt }) => pt.m % 6 === 0);
  const sel = foco != null ? dados[foco] : null;

  const mover = (ev: React.PointerEvent<SVGRectElement>) => {
    const r = ev.currentTarget.getBoundingClientRect();
    const px = ((ev.clientX - r.left) / r.width) * (W - e - d);
    setFoco(Math.max(0, Math.min(dados.length - 1, Math.round((px / (W - e - d)) * (dados.length - 1)))));
  };

  return (
    <div className="grafico-fluxo">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Fluxo acumulado da tabela e da proposta, mês a mês">
        {Array.from({ length: Math.round(topoY / passoY) + 1 }, (_, k) => k * passoY).map((v) => (
          <g key={v}>
            <line x1={e} x2={W - d} y1={y(v)} y2={y(v)} className="grade-linha" />
            <text x={e - 8} y={y(v) + 4} textAnchor="end" className="eixo">{v === 0 ? '0' : rotuloV(v)}</text>
          </g>
        ))}
        {marcasX.map(({ pt, i }) => (
          <text key={pt.m} x={x(i)} y={H - 10} textAnchor="middle" className="eixo">{fmtMes(somarMeses(cfg.mesTabela, pt.m)).replace(/\/(\d\d)(\d\d)$/, '/$2')}</text>
        ))}
        <path d={caminho('t')} className="serie tabela" />
        <path d={caminho('p')} className="serie proposta" />
        {sel && foco != null && (
          <g>
            <line x1={x(foco)} x2={x(foco)} y1={topo} y2={H - base} className="mira" />
            <circle cx={x(foco)} cy={y(sel.t)} r={4.5} className="ponto tabela" />
            <circle cx={x(foco)} cy={y(sel.p)} r={4.5} className="ponto proposta" />
          </g>
        )}
        <rect x={e} y={topo} width={W - e - d} height={H - topo - base} fill="transparent"
          onPointerMove={mover} onPointerDown={mover} onPointerLeave={() => setFoco(null)} />
      </svg>
      {sel && foco != null && (
        <div className="dica-grafico" style={{ left: `${(x(foco) / W) * 100}%` }}>
          <strong>{fmtMes(somarMeses(cfg.mesTabela, sel.m))}</strong>
          <span><Traco tipo="tabela" />Tabela <b>{fmtReal(sel.t)}</b></span>
          <span><Traco tipo="proposta" />Proposta <b>{fmtReal(sel.p)}</b></span>
          <span className="dif">Diferença <b>{sel.p - sel.t >= 0 ? '+' : ''}{fmtReal(sel.p - sel.t)}</b></span>
        </div>
      )}
    </div>
  );
}

const Traco = ({ tipo }: { tipo: 'tabela' | 'proposta' }) => (
  <svg width="22" height="8" aria-hidden="true" className="traco-svg">
    <line x1="1" x2="21" y1="4" y2="4" stroke={tipo === 'tabela' ? '#B0730F' : '#2F63A8'} strokeWidth="2.5"
      strokeDasharray={tipo === 'tabela' ? '5 3' : undefined} strokeLinecap="round" />
  </svg>
);
