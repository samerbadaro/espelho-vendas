// =====================================================================
// Painel de assinaturas: todos os envelopes da D4Sign num só lugar,
// em colunas pela etapa (comprador, imobiliária, incorporadora,
// testemunhas, concluído). Lê o que o retorno da D4Sign já gravou:
// não consome chamadas da API ao abrir.
// =====================================================================
import { useEffect, useMemo, useState } from 'react';
import { supabase, formatarDataHora } from '../dados';
import { ir } from '../util';
import { Search } from 'lucide-react';

interface Assinante { envelope_id: string; ordem: number; papel: string; nome: string | null; email: string; assinado: boolean; assinado_em: string | null }
interface Envelope {
  id: string; pasta_id: string; proposta_id: string | null; status: 'preparado' | 'enviado' | 'assinado' | 'cancelado';
  criado_em: string; enviado_em: string | null; assinado_em: string | null; cancelado_em: string | null;
  pastas: { comprador_nome: string | null; tipo_pessoa: string | null; empresa_razao_social: string | null; imobiliarias: { nome: string } | null } | null;
  propostas: { codigo: string; unidades: { numero: string } | null } | null;
}

type Etapa = 'montado' | 'comprador' | 'imobiliaria' | 'incorporadora' | 'testemunhas' | 'concluido' | 'cancelado';
const COLUNAS: { id: Etapa; rotulo: string; dica: string }[] = [
  { id: 'montado', rotulo: 'Montado, não enviado', dica: 'Envelope pronto na D4Sign, aguardando o envio' },
  { id: 'comprador', rotulo: 'Comprador', dica: 'Comprador, cônjuge ou representantes' },
  { id: 'imobiliaria', rotulo: 'Imobiliária', dica: 'Gestor da imobiliária' },
  { id: 'incorporadora', rotulo: 'Incorporadora', dica: 'Representante da vendedora' },
  { id: 'testemunhas', rotulo: 'Testemunhas', dica: 'Testemunhas do contrato' },
  { id: 'concluido', rotulo: 'Assinado', dica: 'Todos assinaram' },
];

/** Agrupa o papel do assinante na etapa do funil. */
const grupo = (papel: string): Exclude<Etapa, 'montado' | 'concluido' | 'cancelado'> => {
  const p = papel.toLowerCase();
  if (p.includes('testemunha')) return 'testemunhas';
  if (p.includes('imobili')) return 'imobiliaria';
  if (p.includes('incorpora') || p.includes('vendedora')) return 'incorporadora';
  return 'comprador';
};
const dias = (de: string | null) => (de ? Math.floor((Date.now() - new Date(de).getTime()) / 86_400_000) : 0);
const sem = (t: string) => t.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

export function PainelAssinaturas() {
  const [envs, setEnvs] = useState<Envelope[] | null>(null);
  const [ass, setAss] = useState<Assinante[]>([]);
  const [erro, setErro] = useState('');
  const [busca, setBusca] = useState('');
  const [verCancelados, setVerCancelados] = useState(false);

  useEffect(() => {
    (async () => {
      const [{ data: e, error }, { data: a }] = await Promise.all([
        supabase.from('envelopes').select('id, pasta_id, proposta_id, status, criado_em, enviado_em, assinado_em, cancelado_em, pastas(comprador_nome, tipo_pessoa, empresa_razao_social, imobiliarias(nome)), propostas(codigo, unidades(numero))')
          .order('criado_em', { ascending: false }).limit(1000),
        supabase.from('envelope_assinantes').select('envelope_id, ordem, papel, nome, email, assinado, assinado_em').order('ordem').limit(10000),
      ]);
      if (error) { setErro(error.message); return; }
      // um envelope por pasta: o mais recente (os cancelados antigos ficam só no filtro)
      const vistos = new Set<string>();
      const lista = ((e ?? []) as unknown as Envelope[]).filter((x) => {
        if (x.status === 'cancelado') return true;
        if (vistos.has(x.pasta_id)) return false;
        vistos.add(x.pasta_id); return true;
      });
      setEnvs(lista); setAss((a as Assinante[]) ?? []);
    })();
  }, []);

  const linhas = useMemo(() => (envs ?? []).map((e) => {
    const lista = ass.filter((a) => a.envelope_id === e.id).sort((x, y) => x.ordem - y.ordem);
    const pend = lista.filter((a) => !a.assinado);
    const etapa: Etapa = e.status === 'cancelado' ? 'cancelado' : e.status === 'assinado' || (lista.length > 0 && !pend.length) ? 'concluido'
      : e.status === 'preparado' ? 'montado' : pend.length ? grupo(pend[0].papel) : 'comprador';
    const ultima = lista.filter((a) => a.assinado_em).map((a) => a.assinado_em!).sort().pop() ?? null;
    const cliente = (e.pastas?.tipo_pessoa === 'pj' ? e.pastas?.empresa_razao_social : e.pastas?.comprador_nome) ?? '—';
    return {
      e, etapa, lista, pend, cliente, unidade: e.propostas?.unidades?.numero ?? '—', imobiliaria: e.pastas?.imobiliarias?.nome ?? 'Venda direta',
      parado: dias(ultima ?? e.enviado_em ?? e.criado_em), quem: pend[0] ?? null,
    };
  }), [envs, ass]);

  const filtradas = linhas.filter((l) => (verCancelados || l.etapa !== 'cancelado')
    && (!busca.trim() || sem(`${l.cliente} ${l.unidade} ${l.imobiliaria} ${l.e.propostas?.codigo ?? ''}`).includes(sem(busca.trim()))));
  const conta = (et: Etapa) => linhas.filter((l) => l.etapa === et).length;
  const emAssinatura = linhas.filter((l) => ['comprador', 'imobiliaria', 'incorporadora', 'testemunhas'].includes(l.etapa));
  const parados = emAssinatura.filter((l) => l.parado >= 2).length;
  const concl = linhas.filter((l) => l.etapa === 'concluido' && l.e.enviado_em && l.e.assinado_em);
  const tempoMedio = concl.length ? concl.reduce((t, l) => t + (new Date(l.e.assinado_em!).getTime() - new Date(l.e.enviado_em!).getTime()), 0) / concl.length / 86_400_000 : null;

  if (erro) return <section className="secao"><h2>Assinaturas</h2><p className="erro">{erro}</p></section>;
  if (!envs) return <section className="secao"><h2>Assinaturas</h2><p className="vazio">Carregando…</p></section>;

  return (
    <section className="secao assinaturas">
      <div className="secao-topo">
        <div>
          <h2>Assinaturas</h2>
          <p className="sub">Envelopes da D4Sign por etapa: em que assinatura cada contrato está parado. Atualiza com o retorno automático da D4Sign.</p>
        </div>
      </div>

      <div className="kpis as-kpis">
        <div className="kpi"><strong className="kpi-valor">{emAssinatura.length}</strong><span className="kpi-rotulo">Em assinatura</span><span className="kpi-detalhe">Enviados, faltando alguém</span></div>
        <div className="kpi"><strong className="kpi-valor">{parados}</strong><span className="kpi-rotulo">Parados há 2 dias ou mais</span><span className="kpi-detalhe">Sem nenhuma assinatura nova</span></div>
        <div className="kpi"><strong className="kpi-valor">{conta('concluido')}</strong><span className="kpi-rotulo">Assinados</span><span className="kpi-detalhe">{tempoMedio != null ? `Em média ${tempoMedio.toLocaleString('pt-BR', { maximumFractionDigits: 1 })} dia(s) do envio à última assinatura` : 'Todos assinaram'}</span></div>
        <div className="kpi"><strong className="kpi-valor">{conta('montado')}</strong><span className="kpi-rotulo">Montados, não enviados</span><span className="kpi-detalhe">Prontos na D4Sign</span></div>
      </div>

      <div className="as-filtros">
        <label className="busca-funil"><Search size={16} /><input type="search" placeholder="Buscar por cliente, unidade, imobiliária ou proposta" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
        <label className="as-check"><input type="checkbox" checked={verCancelados} onChange={(e) => setVerCancelados(e.target.checked)} /> Mostrar cancelados ({conta('cancelado')})</label>
      </div>

      <div className="as-quadro">
        {[...COLUNAS, ...(verCancelados ? [{ id: 'cancelado' as Etapa, rotulo: 'Cancelado', dica: 'Envelopes cancelados ou descartados' }] : [])].map((c) => {
          const itens = filtradas.filter((l) => l.etapa === c.id).sort((a, b) => b.parado - a.parado);
          return (
            <div key={c.id} className={`as-coluna as-${c.id}`}>
              <div className="as-coluna-topo" title={c.dica}><strong>{c.rotulo}</strong><span>{itens.length}</span></div>
              {!itens.length ? <p className="as-vazio">Nenhum</p> : itens.map((l) => {
                const feitos = l.lista.filter((a) => a.assinado).length;
                return (
                  <button key={l.e.id} type="button" className="as-cartao" onClick={() => l.e.proposta_id && ir(`/painel/contratos/${l.e.proposta_id}`)} disabled={!l.e.proposta_id}>
                    <div className="as-linha1"><strong>{l.unidade}</strong><span>{l.cliente}</span></div>
                    <div className="as-linha2">{l.imobiliaria}</div>
                    {l.lista.length > 0 && (
                      <div className="as-progresso" aria-label={`${feitos} de ${l.lista.length} assinaturas`}>
                        {l.lista.map((a, i) => <i key={i} className={a.assinado ? 'ok' : a === l.quem ? 'vez' : ''} title={`${a.papel}${a.nome ? ` — ${a.nome}` : ''}: ${a.assinado ? `assinou ${a.assinado_em ? formatarDataHora(a.assinado_em) : ''}` : 'pendente'}`} />)}
                        <span>{feitos}/{l.lista.length}</span>
                      </div>
                    )}
                    {l.quem && c.id !== 'cancelado' && <div className="as-quem">Falta: {l.quem.nome || l.quem.papel}</div>}
                    <div className={`as-tempo ${l.parado >= 2 && !['concluido', 'cancelado'].includes(c.id) ? 'atrasado' : ''}`}>
                      {c.id === 'concluido' && l.e.assinado_em ? `Assinado em ${formatarDataHora(l.e.assinado_em)}`
                        : c.id === 'cancelado' ? `Cancelado${l.e.cancelado_em ? ` em ${formatarDataHora(l.e.cancelado_em)}` : ''}`
                        : c.id === 'montado' ? `Montado há ${l.parado} dia(s)` : `Parado há ${l.parado} dia(s)`}
                    </div>
                  </button>
                );
              })}
            </div>
          );
        })}
      </div>
    </section>
  );
}
