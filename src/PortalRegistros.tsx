import { useEffect, useMemo, useState } from 'react';
import { ArrowLeft, FileDown, Search } from 'lucide-react';
import { supabase } from './dados';
import { ir } from './util';

interface Download { id: number; criado_em: string; nome: string | null; email: string | null; papel: string | null; imobiliaria: string | null; categoria: string | null; titulo: string; modo: string }
interface Simulacao {
  id: number; criado_em: string; nome: string | null; email: string | null; papel: string | null; imobiliaria: string | null;
  posicao: string; referencia: string; preco: number; captacao: number; financiamento: number; formato: string;
  fluxo: { serie: string; parcelas: number; valor: number; total: number; pct: number }[];
}

const PAPEL: Record<string, string> = { admin: 'Administrador', vendas: 'Sec. Vendas', imobiliaria: 'Imobiliária', corretor: 'Corretor' };
const MODO: Record<string, string> = { arquivo: 'Baixou', link: 'Abriu link', visualizar: 'Visualizou', zip: 'Baixou tudo (.zip)' };
const CATEGORIA: Record<string, string> = {
  book: 'Book e apresentações', ficha_tecnica: 'Ficha técnica', fotos_decorado: 'Fotos do decorado', imagens: 'Imagens do empreendimento',
  materiais_apoio: 'Materiais de apoio', redes_sociais: 'Material para redes sociais', plantas: 'Plantas', simulador: 'Simulador',
  tour_virtual: 'Tour virtual', videos: 'Vídeos',
};
const dataHora = (s: string) => new Date(s).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' });
const pct = (v: number) => `${Number(v).toLocaleString('pt-BR', { maximumFractionDigits: 2 })}%`;
const brl = (v: number) => Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
const norm = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

/** Registros do Portal do Corretor (somente equipe): downloads de materiais e simulações baixadas. */
export function Registros() {
  const [aba, setAba] = useState<'downloads' | 'simulacoes'>('downloads');
  const [downloads, setDownloads] = useState<Download[] | null>(null);
  const [sims, setSims] = useState<Simulacao[] | null>(null);
  const [busca, setBusca] = useState('');
  const [erro, setErro] = useState('');

  useEffect(() => {
    supabase.from('portal_downloads').select('*').order('criado_em', { ascending: false }).limit(2000)
      .then(({ data, error }) => { if (error) setErro('Não foi possível carregar. Confira se a migração 026 foi aplicada.'); setDownloads((data as Download[]) ?? []); });
    supabase.from('simulacoes_log').select('*').order('criado_em', { ascending: false }).limit(2000)
      .then(({ data }) => setSims((data as Simulacao[]) ?? []));
  }, []);

  const t = norm(busca.trim());
  const dl = useMemo(() => (downloads ?? []).filter((d) => !t || norm([d.nome, d.email, d.imobiliaria, d.titulo, d.categoria && CATEGORIA[d.categoria]].join(' ')).includes(t)), [downloads, t]);
  const sm = useMemo(() => (sims ?? []).filter((d) => !t || norm([d.nome, d.email, d.imobiliaria, d.posicao, d.referencia].join(' ')).includes(t)), [sims, t]);

  const exportar = async () => {
    const [{ jsPDF }, { default: autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
    const doc = new jsPDF({ orientation: 'landscape', unit: 'mm', format: 'a4' });
    doc.setFontSize(14);
    doc.text(aba === 'downloads' ? 'Portal do Corretor: downloads' : 'Portal do Corretor: simulações baixadas', 14, 15);
    doc.setFontSize(9); doc.text(`Gerado em ${new Date().toLocaleString('pt-BR')}${busca ? ` · filtro: ${busca}` : ''}`, 14, 21);
    if (aba === 'downloads') {
      autoTable(doc, { startY: 26, styles: { fontSize: 8 }, head: [['Data', 'Quem', 'Perfil', 'Imobiliária', 'Ação', 'Categoria', 'Material']],
        body: dl.map((d) => [dataHora(d.criado_em), d.nome || d.email || '', PAPEL[d.papel ?? ''] ?? '', d.imobiliaria ?? '', MODO[d.modo] ?? d.modo, d.categoria ? CATEGORIA[d.categoria] ?? d.categoria : '', d.titulo]) });
    } else {
      autoTable(doc, { startY: 26, styles: { fontSize: 8 }, head: [['Data', 'Quem', 'Perfil', 'Imobiliária', 'Posição', 'Preço', 'Captação', 'Financ.', 'Fluxo', 'Arquivo']],
        body: sm.map((d) => [dataHora(d.criado_em), d.nome || d.email || '', PAPEL[d.papel ?? ''] ?? '', d.imobiliaria ?? '', d.posicao, `${d.referencia} ${brl(d.preco)}`, pct(d.captacao), pct(d.financiamento),
          (d.fluxo ?? []).filter((f) => f.serie !== 'Financiamento').map((f) => `${f.serie} ${pct(f.pct)}`).join(' · '), d.formato.toUpperCase()]) });
    }
    doc.save(aba === 'downloads' ? 'registros-downloads.pdf' : 'registros-simulacoes.pdf');
  };

  const lista = aba === 'downloads' ? downloads : sims;
  return (
    <section className="secao">
      <button className="voltar" onClick={() => ir('/painel/portal')}><ArrowLeft size={16} /> Portal do Corretor</button>
      <div className="secao-topo">
        <div>
          <h2>Registros de downloads</h2>
          <p className="sub">Quem baixou o quê e quando. Visível só para o administrador e a Sec. Vendas.</p>
        </div>
        <button className="botao" onClick={exportar} disabled={!lista?.length}><FileDown size={16} /> Exportar PDF</button>
      </div>
      <div className="registros-abas segmentado">
        <button className={aba === 'downloads' ? 'ativo' : ''} onClick={() => setAba('downloads')}>Materiais do portal{downloads ? ` (${downloads.length})` : ''}</button>
        <button className={aba === 'simulacoes' ? 'ativo' : ''} onClick={() => setAba('simulacoes')}>Simulações baixadas{sims ? ` (${sims.length})` : ''}</button>
      </div>
      <label className="busca-funil"><Search size={16} /><input placeholder="Buscar por pessoa, imobiliária ou material" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
      {erro && <p className="erro">{erro}</p>}
      <div className="tabela-rolagem">
        {lista == null ? <p className="vazio">Carregando…</p> : aba === 'downloads' ? (
          dl.length === 0 ? <p className="vazio">{busca ? 'Nada encontrado com essa busca.' : 'Nenhum download registrado ainda.'}</p> : (
            <table className="tabela tabela-registros">
              <thead><tr><th>Data</th><th>Quem</th><th>Imobiliária</th><th>Ação</th><th>Material</th></tr></thead>
              <tbody>{dl.map((d) => (
                <tr key={d.id}>
                  <td className="nowrap">{dataHora(d.criado_em)}</td>
                  <td>{d.nome || d.email}<small>{PAPEL[d.papel ?? ''] ?? ''}</small></td>
                  <td>{d.imobiliaria ?? '—'}</td>
                  <td className="nowrap">{MODO[d.modo] ?? d.modo}</td>
                  <td>{d.titulo}<small>{d.categoria ? CATEGORIA[d.categoria] ?? d.categoria : ''}</small></td>
                </tr>
              ))}</tbody>
            </table>
          )
        ) : (
          sm.length === 0 ? <p className="vazio">{busca ? 'Nada encontrado com essa busca.' : 'Nenhuma simulação baixada ainda.'}</p> : (
            <table className="tabela tabela-registros">
              <thead><tr><th>Data</th><th>Quem</th><th>Imobiliária</th><th>Simulação</th><th>Captação</th><th>Fluxo</th></tr></thead>
              <tbody>{sm.map((d) => (
                <tr key={d.id}>
                  <td className="nowrap">{dataHora(d.criado_em)}<small>{d.formato.toUpperCase()}</small></td>
                  <td>{d.nome || d.email}<small>{PAPEL[d.papel ?? ''] ?? ''}</small></td>
                  <td>{d.imobiliaria ?? '—'}</td>
                  <td className="nowrap">{d.posicao}<small>{d.referencia} {brl(d.preco)}</small></td>
                  <td className="nowrap"><strong>{pct(d.captacao)}</strong><small>financ. {pct(d.financiamento)}</small></td>
                  <td>{(d.fluxo ?? []).filter((f) => f.serie !== 'Financiamento').map((f) => `${f.serie} ${pct(f.pct)}${f.parcelas > 1 ? ` (${f.parcelas}x)` : ''}`).join(' · ')}</td>
                </tr>
              ))}</tbody>
            </table>
          )
        )}
      </div>
    </section>
  );
}
