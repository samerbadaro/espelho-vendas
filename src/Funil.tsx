import { useCallback, useEffect, useMemo, useState, type DragEvent } from 'react';
import { Clock, GripVertical } from 'lucide-react';
import { supabase } from './dados';
import { ir } from './util';
import { useDialogos } from './ui';

type Etapa = 'aprovada' | 'reserva' | 'contrato_confeccao' | 'enviado_assinatura' | 'assinado';
const ETAPAS: { valor: Etapa; rotulo: string }[] = [
  { valor: 'aprovada', rotulo: 'Pasta aprovada' },
  { valor: 'reserva', rotulo: 'Reserva' },
  { valor: 'contrato_confeccao', rotulo: 'Contrato em confecção' },
  { valor: 'enviado_assinatura', rotulo: 'Enviado para assinatura' },
  { valor: 'assinado', rotulo: 'Assinado / Vendido' },
];

interface Card {
  id: string; codigo: string; codigo_aprovacao: string | null; comprador_nome: string; etapa_venda: Etapa;
  etapa_atualizada_em: string | null; submetida_em: string | null; criado_por: string | null; imobiliaria_id: string;
  imobiliarias: { nome: string } | null; unidades: { numero: string } | null;
}

function diasDesde(iso: string | null) {
  if (!iso) return null;
  return Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000));
}

/** Funil de vendas da Sec. Vendas: pastas com documentação aprovada, por etapa. */
export function Funil() {
  const { avisar } = useDialogos();
  const [cards, setCards] = useState<Card[] | null>(null);
  const [nomes, setNomes] = useState<Record<string, string>>({});
  const [imob, setImob] = useState('');
  const [arrastando, setArrastando] = useState<string | null>(null);
  const [sobre, setSobre] = useState<Etapa | null>(null);

  const carregar = useCallback(async () => {
    const { data, error } = await supabase.from('pastas')
      .select('id, codigo, codigo_aprovacao, comprador_nome, etapa_venda, etapa_atualizada_em, submetida_em, criado_por, imobiliaria_id, imobiliarias(nome), unidades(numero)')
      .eq('status', 'aprovada').order('submetida_em', { ascending: true });
    if (error) { avisar('Não foi possível carregar o funil.', 'erro'); return; }
    setCards((data as unknown as Card[]) ?? []);
  }, [avisar]);

  useEffect(() => {
    carregar();
    supabase.from('perfis').select('email, nome').then(({ data }) => {
      const m: Record<string, string> = {};
      ((data as { email: string; nome: string | null }[]) ?? []).forEach((x) => { m[x.email] = x.nome || x.email; });
      setNomes(m);
    });
  }, [carregar]);

  const imobiliarias = useMemo(() => {
    const m = new Map<string, string>();
    (cards ?? []).forEach((c) => c.imobiliarias && m.set(c.imobiliaria_id, c.imobiliarias.nome));
    return [...m.entries()].sort((a, b) => a[1].localeCompare(b[1], 'pt-BR'));
  }, [cards]);
  const visiveis = (cards ?? []).filter((c) => !imob || c.imobiliaria_id === imob);

  const mover = async (id: string, etapa: Etapa) => {
    const card = cards?.find((c) => c.id === id);
    if (!card || card.etapa_venda === etapa) return;
    const anterior = card.etapa_venda;
    setCards((l) => l?.map((c) => (c.id === id ? { ...c, etapa_venda: etapa, etapa_atualizada_em: new Date().toISOString() } : c)) ?? null);
    const { error } = await supabase.rpc('mover_etapa', { p_pasta: id, p_etapa: etapa });
    if (error) {
      setCards((l) => l?.map((c) => (c.id === id ? { ...c, etapa_venda: anterior } : c)) ?? null);
      avisar('Não foi possível mover a pasta. Tente novamente.', 'erro');
      return;
    }
    avisar(`${card.comprador_nome}: ${ETAPAS.find((e) => e.valor === etapa)?.rotulo}.`);
  };

  const soltar = (etapa: Etapa) => (e: DragEvent) => {
    e.preventDefault();
    const id = e.dataTransfer.getData('text/plain');
    setSobre(null); setArrastando(null);
    if (id) mover(id, etapa);
  };

  return (
    <section className="secao larga">
      <div className="secao-topo">
        <div><h2>Funil de vendas</h2><p className="sub">Pastas com documentação aprovada. Arraste o card para mudar a etapa.</p></div>
        {imobiliarias.length > 1 && (
          <select value={imob} onChange={(e) => setImob(e.target.value)} aria-label="Filtrar por imobiliária" style={{ width: 'auto' }}>
            <option value="">Todas as imobiliárias</option>
            {imobiliarias.map(([id, nome]) => <option key={id} value={id}>{nome}</option>)}
          </select>
        )}
      </div>

      {cards === null ? <p className="vazio">Carregando…</p> : (
        <div className="kanban">
          {ETAPAS.map((et) => {
            const lista = visiveis.filter((c) => c.etapa_venda === et.valor);
            return (
              <div key={et.valor} className={`coluna k-${et.valor}${sobre === et.valor ? ' sobre' : ''}`}
                onDragOver={(e) => { e.preventDefault(); setSobre(et.valor); }}
                onDragLeave={() => setSobre((s) => (s === et.valor ? null : s))}
                onDrop={soltar(et.valor)}>
                <div className="coluna-topo"><h3>{et.rotulo}</h3><span className="contagem">{lista.length}</span></div>
                <div className="coluna-cards">
                  {lista.length === 0 && <p className="coluna-vazia">Nenhuma pasta nesta etapa.</p>}
                  {lista.map((c) => {
                    const dias = diasDesde(c.etapa_atualizada_em ?? c.submetida_em);
                    return (
                      <article key={c.id} className={`kcard${arrastando === c.id ? ' arrastando' : ''}`} draggable
                        onDragStart={(e) => { e.dataTransfer.setData('text/plain', c.id); e.dataTransfer.effectAllowed = 'move'; setArrastando(c.id); }}
                        onDragEnd={() => { setArrastando(null); setSobre(null); }}>
                        <div className="kcard-topo">
                          <span className="mono">{c.codigo_aprovacao ?? c.codigo}</span>
                          {c.unidades && <span className="kcard-unidade">Unid. {c.unidades.numero}</span>}
                          <GripVertical size={16} className="alca" aria-hidden="true" />
                        </div>
                        <button className="kcard-nome" onClick={() => ir(`/painel/pastas/${c.id}`)}>{c.comprador_nome}</button>
                        <p className="kcard-meta">{c.imobiliarias?.nome}{c.criado_por ? `, ${nomes[c.criado_por] ?? c.criado_por}` : ''}</p>
                        <div className="kcard-pe">
                          {dias !== null && <span className="kcard-dias"><Clock size={13} /> {dias === 0 ? 'hoje' : `${dias} ${dias === 1 ? 'dia' : 'dias'}`}</span>}
                          <select value={c.etapa_venda} onChange={(e) => mover(c.id, e.target.value as Etapa)} aria-label={`Mover ${c.comprador_nome} para outra etapa`}>
                            {ETAPAS.map((x) => <option key={x.valor} value={x.valor}>{x.rotulo}</option>)}
                          </select>
                        </div>
                      </article>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}
