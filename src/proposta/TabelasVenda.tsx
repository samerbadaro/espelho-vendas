// Tabelas de venda (só administrador): mês da tabela, mês da entrega e as séries de cada tabela.
// As séries começam num número de meses a partir da venda (mês da tabela) ou da entrega.
import { useEffect, useMemo, useState } from 'react';
import { supabase } from '../dados';
import { traduzirErro } from './dadosProposta';
import { PERIODICIDADES, PASSO, fmtMes, type Periodicidade } from './motor';

interface Linha { chave: string; rotulo: string; periodicidade: Periodicidade; qtd: number; pct: string; base: 'venda' | 'entrega'; meses: number }
const novaChave = () => Math.random().toString(36).slice(2);
const somarMes = (mes: string, n: number) => { const [a, m] = mes.split('-').map(Number); const t = a * 12 + (m - 1) + n; return `${Math.floor(t / 12)}-${String((t % 12) + 1).padStart(2, '0')}`; };
const num = (t: string) => Number(String(t).replace(/\./g, '').replace(',', '.'));
const pctTexto = (v: number) => String(Math.round(v * 100 * 10000) / 10000).replace('.', ',');

export function TabelasVenda() {
  const [mesTabela, setMesTabela] = useState('');
  const [mesEntrega, setMesEntrega] = useState('');
  const [tabelas, setTabelas] = useState<string[]>([]);
  const [atual, setAtual] = useState('');
  const [linhas, setLinhas] = useState<Linha[]>([]);
  const [todas, setTodas] = useState<Record<string, Linha[]>>({});
  const [msg, setMsg] = useState<{ ok: boolean; t: string } | null>(null);
  const [salvando, setSalvando] = useState(false);

  const carregar = async () => {
    const [{ data: c }, { data: ts }, { data: ss }] = await Promise.all([
      supabase.from('comercial').select('mes_tabela, mes_entrega').eq('id', 1).maybeSingle(),
      supabase.from('tabelas_venda').select('nome').order('nome'),
      supabase.from('tabelas_series').select('tabela, ordem, rotulo, periodicidade, qtd, percentual, base, meses').order('tabela').order('ordem'),
    ]);
    if (c) { setMesTabela(String(c.mes_tabela).slice(0, 7)); setMesEntrega(String(c.mes_entrega).slice(0, 7)); }
    const nomes = ((ts as { nome: string }[]) ?? []).map((t) => t.nome);
    const porTabela: Record<string, Linha[]> = {};
    ((ss as { tabela: string; rotulo: string; periodicidade: Periodicidade; qtd: number; percentual: number; base: 'venda' | 'entrega'; meses: number }[]) ?? []).forEach((s) => {
      (porTabela[s.tabela] ??= []).push({ chave: novaChave(), rotulo: s.rotulo, periodicidade: s.periodicidade, qtd: s.qtd, pct: pctTexto(Number(s.percentual)), base: s.base, meses: s.meses });
    });
    setTabelas(nomes); setTodas(porTabela);
    const t = atual && nomes.includes(atual) ? atual : nomes[0] ?? '';
    setAtual(t); setLinhas(porTabela[t] ?? []);
  };
  useEffect(() => { carregar(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const trocarTabela = (t: string) => { setAtual(t); setLinhas(todas[t] ?? []); setMsg(null); };
  const mudar = (chave: string, campo: Partial<Linha>) => setLinhas((l) => l.map((x) => (x.chave === chave ? { ...x, ...campo } : x)));
  const soma = linhas.reduce((t, l) => t + (num(l.pct) || 0), 0);
  const quando = (l: Linha, k: number) => {
    if (!mesTabela || !mesEntrega) return '';
    return somarMes(l.base === 'venda' ? mesTabela : mesEntrega, l.meses + k * PASSO[l.periodicidade]);
  };
  const problemas = useMemo(() => {
    const p: string[] = [];
    if (Math.abs(soma - 100) > 0.0001) p.push(`Os percentuais somam ${String(Math.round(soma * 10000) / 10000).replace('.', ',')}%: precisam somar 100%.`);
    if (linhas.filter((l) => l.periodicidade === 'Financiamento').length > 1) p.push('Só pode haver uma série de financiamento.');
    linhas.forEach((l) => {
      if (!(l.qtd >= 1)) p.push(`${l.rotulo || l.periodicidade}: quantidade inválida.`);
      const fim = quando(l, l.qtd - 1);
      if (l.periodicidade !== 'Financiamento' && mesEntrega && fim > mesEntrega) p.push(`${l.rotulo || l.periodicidade}: a última parcela (${fmtMes(fim)}) passa da entrega (${fmtMes(mesEntrega)}).`);
    });
    return p;
  }, [linhas, soma, mesTabela, mesEntrega]); // eslint-disable-line react-hooks/exhaustive-deps

  const salvarMeses = async () => {
    setMsg(null);
    if (!/^\d{4}-\d{2}$/.test(mesTabela) || !/^\d{4}-\d{2}$/.test(mesEntrega) || mesEntrega <= mesTabela) { setMsg({ ok: false, t: 'Informe o mês da tabela e um mês de entrega posterior.' }); return; }
    setSalvando(true);
    const { error } = await supabase.from('comercial').update({ mes_tabela: `${mesTabela}-01`, mes_entrega: `${mesEntrega}-01` }).eq('id', 1);
    setSalvando(false);
    setMsg(error ? { ok: false, t: traduzirErro(error.message) } : { ok: true, t: 'Meses salvos. Valem para as próximas propostas abertas.' });
  };

  const salvarTabela = async () => {
    setMsg(null);
    if (problemas.length) { setMsg({ ok: false, t: problemas[0] }); return; }
    setSalvando(true);
    const series = linhas.map((l) => ({ rotulo: l.rotulo.trim(), periodicidade: l.periodicidade, qtd: l.qtd, percentual: Math.round((num(l.pct) / 100) * 1e8) / 1e8, base: l.base, meses: l.meses }));
    // fecha a soma em 100% exatos (arredondamento das casas)
    const dif = 1 - series.reduce((t, s) => t + s.percentual, 0);
    const fin = series.find((s) => s.periodicidade === 'Financiamento') ?? series[series.length - 1];
    fin.percentual = Math.round((fin.percentual + dif) * 1e8) / 1e8;
    const { error } = await supabase.rpc('salvar_tabela_venda', { p_tabela: atual, p_series: series });
    setSalvando(false);
    if (error) { setMsg({ ok: false, t: traduzirErro(error.message) }); return; }
    setMsg({ ok: true, t: `${atual} salva. Vale para as próximas propostas abertas e para o PV calculado no envio.` });
    carregar();
  };

  if (!tabelas.length) return <p className="vazio">Carregando tabelas…</p>;
  return (
    <div className="tabelas-venda">
      <h4>Tabelas de venda</h4>
      <p className="dica">As séries começam num número de meses a partir do mês da tabela (venda) ou da entrega. Ex.: “Única” 12 meses antes da entrega = base “entrega” e meses −12.</p>
      <div className="grade-campos">
        <label>Mês da tabela<input type="month" value={mesTabela} onChange={(e) => setMesTabela(e.target.value)} /></label>
        <label>Mês da entrega<input type="month" value={mesEntrega} onChange={(e) => setMesEntrega(e.target.value)} /></label>
        <div className="botoes"><button className="botao" disabled={salvando} onClick={salvarMeses}>Salvar meses</button></div>
      </div>
      <div className="prop-vistas pequenas" role="tablist" aria-label="Tabela">
        {tabelas.map((t) => <button key={t} role="tab" aria-selected={t === atual} className={t === atual ? 'ativa' : ''} onClick={() => trocarTabela(t)}>{t}</button>)}
      </div>
      <div className="tabela-rolagem">
        <table className="tabela tabela-series">
          <thead><tr><th>Nome</th><th>Periodicidade</th><th className="dir">Parcelas</th><th className="dir">% do preço</th><th>A partir de</th><th className="dir">Meses</th><th>1ª parcela</th><th>Última</th><th /></tr></thead>
          <tbody>
            {linhas.map((l) => (
              <tr key={l.chave}>
                <td><input value={l.rotulo} onChange={(e) => mudar(l.chave, { rotulo: e.target.value })} aria-label="Nome da série" /></td>
                <td><select value={l.periodicidade} onChange={(e) => mudar(l.chave, { periodicidade: e.target.value as Periodicidade })} aria-label="Periodicidade">
                  {PERIODICIDADES.filter((p) => p.valor !== 'Permuta').map((p) => <option key={p.valor} value={p.valor}>{p.rotulo}</option>)}
                </select></td>
                <td><input className="dir" inputMode="numeric" value={l.qtd} onChange={(e) => mudar(l.chave, { qtd: Math.max(1, Math.round(Number(e.target.value) || 1)) })} aria-label="Parcelas" /></td>
                <td><input className="dir" inputMode="decimal" value={l.pct} onChange={(e) => mudar(l.chave, { pct: e.target.value })} aria-label="Percentual do preço" /></td>
                <td><select value={l.base} onChange={(e) => mudar(l.chave, { base: e.target.value as 'venda' | 'entrega' })} aria-label="Base"><option value="venda">tabela</option><option value="entrega">entrega</option></select></td>
                <td><input className="dir" inputMode="numeric" value={l.meses} onChange={(e) => mudar(l.chave, { meses: Math.round(Number(e.target.value.replace('−', '-')) || 0) })} aria-label="Meses a partir da base" /></td>
                <td className="mono nowrap">{quando(l, 0) && fmtMes(quando(l, 0))}</td>
                <td className="mono nowrap">{quando(l, l.qtd - 1) && fmtMes(quando(l, l.qtd - 1))}</td>
                <td><button className="mini" onClick={() => setLinhas((x) => x.filter((y) => y.chave !== l.chave))} aria-label={`Tirar ${l.rotulo}`}>✕</button></td>
              </tr>
            ))}
          </tbody>
          <tfoot><tr><td colSpan={3}><button className="mini" onClick={() => setLinhas((x) => [...x.filter((y) => y.periodicidade !== 'Financiamento'), { chave: novaChave(), rotulo: 'Mensais', periodicidade: 'Mensais', qtd: 1, pct: '0', base: 'venda', meses: 1 }, ...x.filter((y) => y.periodicidade === 'Financiamento')])}>+ série</button></td>
            <td className={`dir mono ${Math.abs(soma - 100) > 0.0001 ? 'texto-ruim' : ''}`}>{String(Math.round(soma * 10000) / 10000).replace('.', ',')}%</td><td colSpan={5} /></tr></tfoot>
        </table>
      </div>
      {problemas.length > 0 && <ul className="erro lista-simples">{problemas.map((p) => <li key={p}>{p}</li>)}</ul>}
      <div className="botoes"><button className="botao principal" disabled={salvando || problemas.length > 0} onClick={salvarTabela}>Salvar {atual}</button></div>
      {msg && <p className={msg.ok ? 'ok' : 'erro'}>{msg.t}</p>}
    </div>
  );
}
