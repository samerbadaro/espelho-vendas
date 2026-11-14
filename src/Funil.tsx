import { useCallback, useEffect, useMemo, useState, type DragEvent } from 'react';
import { Clock, GripVertical, Search, X } from 'lucide-react';
import { supabase } from './dados';
import { ir } from './util';
import { useDialogos } from './ui';

type Etapa = 'aprovada' | 'reserva' | 'contrato_confeccao' | 'enviado_assinatura' | 'assinado';
const ESPELHO: Record<Etapa, string> = {
  aprovada: 'Disponível', reserva: 'Reservada', contrato_confeccao: 'Proposta recebida', enviado_assinatura: 'Contrato em assinatura', assinado: 'Vendida',
};

const ETAPAS: { valor: Etapa; rotulo: string }[] = [
  { valor: 'aprovada', rotulo: 'Pasta aprovada' },
  { valor: 'reserva', rotulo: 'Reserva' },
  { valor: 'contrato_confeccao', rotulo: 'Contrato em confecção' },
  { valor: 'enviado_assinatura', rotulo: 'Enviado para assinatura' },
  { valor: 'assinado', rotulo: 'Assinado / Vendido' },
];

interface PastaFunil {
  id: string; codigo: string; codigo_aprovacao: string | null; comprador_nome: string;
  etapa_atualizada_em: string | null; submetida_em: string | null; criado_por: string | null; imobiliaria_id: string;
  imobiliarias: { nome: string } | null; unidades_numeros: string | null;
}

/** Um card é uma pasta sem unidade (Pasta aprovada) ou uma unidade em negociação com a pasta. */
interface Card {
  chave: string;
  pasta: PastaFunil;
  unidade: { id: string; numero: string } | null;
  etapa: Etapa;
  desde: string | null;
}

const ETAPA_DO_STATUS: Record<string, Etapa> = {
  reservada: 'reserva', proposta: 'contrato_confeccao', contrato: 'enviado_assinatura', vendida: 'assinado',
};

interface NegFunil {
  unidade_id: string; atualizada_em: string | null; criada_em: string | null;
  unidades: { numero: string; status: string } | null; pastas: PastaFunil | null;
}

function diasDesde(iso: string | null) {
  if (!iso) return null;
  return Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000));
}

/** Funil de vendas da Sec. Vendas: pastas com documentação aprovada, por etapa. */
export function Funil() {
  const { avisar, confirmar } = useDialogos();
  const [escolha, setEscolha] = useState<{ card: Card; etapa: Etapa } | null>(null);
  const [cards, setCards] = useState<Card[] | null>(null);
  const [nomes, setNomes] = useState<Record<string, string>>({});
  const [imob, setImob] = useState('');
  const [busca, setBusca] = useState('');
  const [arrastando, setArrastando] = useState<string | null>(null);
  const [sobre, setSobre] = useState<Etapa | null>(null);

  const carregar = useCallback(async () => {
    const campos = 'id, codigo, codigo_aprovacao, comprador_nome, etapa_atualizada_em, submetida_em, criado_por, imobiliaria_id, imobiliarias(nome), unidades_numeros';
    const [pa, ng] = await Promise.all([
      supabase.from('pastas').select(campos).eq('status', 'aprovada').is('unidades_numeros', null).order('submetida_em', { ascending: true }),
      supabase.from('negociacoes').select(`unidade_id, atualizada_em, criada_em, unidades(numero, status), pastas(${campos})`)
        .eq('ativa', true).not('pasta_id', 'is', null),
    ]);
    if (pa.error || ng.error) { avisar('Não foi possível carregar o funil.', 'erro'); return; }
    const livres: Card[] = ((pa.data as unknown as PastaFunil[]) ?? []).map((p) => ({
      chave: p.id, pasta: p, unidade: null, etapa: 'aprovada', desde: p.etapa_atualizada_em ?? p.submetida_em,
    }));
    const emNegociacao: Card[] = ((ng.data as unknown as NegFunil[]) ?? [])
      .filter((n) => n.pastas && n.unidades && ETAPA_DO_STATUS[n.unidades.status])
      .map((n) => ({
        chave: `${n.pastas!.id}:${n.unidade_id}`, pasta: n.pastas!, unidade: { id: n.unidade_id, numero: n.unidades!.numero },
        etapa: ETAPA_DO_STATUS[n.unidades!.status], desde: n.atualizada_em ?? n.criada_em,
      }))
      .sort((a, b) => (a.desde ?? '').localeCompare(b.desde ?? ''));
    setCards([...livres, ...emNegociacao]);
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
    (cards ?? []).forEach((c) => c.pasta.imobiliarias && m.set(c.pasta.imobiliaria_id, c.pasta.imobiliarias.nome));
    return [...m.entries()].sort((a, b) => a[1].localeCompare(b[1], 'pt-BR'));
  }, [cards]);
  const chave = (s: string) => s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
  const termo = chave(busca.trim());
  const visiveis = (cards ?? []).filter((c) => {
    if (imob && c.pasta.imobiliaria_id !== imob) return false;
    if (!termo) return true;
    const corretor = c.pasta.criado_por ? nomes[c.pasta.criado_por] ?? c.pasta.criado_por : '';
    const alvo = [c.pasta.comprador_nome, c.pasta.imobiliarias?.nome, corretor, c.unidade?.numero,
      c.pasta.codigo, c.pasta.codigo_aprovacao].filter(Boolean).join(' ');
    return chave(alvo).includes(termo);
  });

  const ERROS: Record<string, string> = {
    SEM_UNIDADE: 'Escolha a unidade desta pasta.',
    UNIDADE_OCUPADA: 'Essa unidade já está em negociação com outro cliente no espelho.',
    UNIDADE_DE_OUTRA_PASTA: 'Essa unidade está com outro cliente.',
    PASTA_NAO_APROVADA: 'A documentação desta pasta não está mais aprovada.',
  };

  const executar = async (card: Card, etapa: Etapa, unidade?: string) => {
    const { error } = await supabase.rpc('mover_etapa', { p_pasta: card.pasta.id, p_etapa: etapa, p_unidade: unidade ?? card.unidade?.id ?? null });
    if (error) {
      const chave = Object.keys(ERROS).find((k) => error.message.includes(k));
      avisar(chave ? ERROS[chave] : 'Não foi possível mover a pasta. Tente novamente.', 'erro');
      return false;
    }
    await carregar();
    avisar(`${card.pasta.comprador_nome}: ${ETAPAS.find((e) => e.valor === etapa)?.rotulo}. Espelho atualizado.`);
    return true;
  };

  const mover = async (chave: string, etapa: Etapa) => {
    const card = cards?.find((c) => c.chave === chave);
    if (!card || card.etapa === etapa) return;
    const unid = card.unidade?.numero;
    const nome = card.pasta.comprador_nome;
    if (etapa === 'aprovada') {
      if (!unid) return;
      const outras = (card.pasta.unidades_numeros ?? '').split(', ').filter((n) => n && n !== unid);
      if (!(await confirmar({
        titulo: `Liberar a unidade ${unid} de ${nome}?`,
        texto: outras.length
          ? `A ${unid} volta a ficar disponível no espelho. As outras unidades de ${nome} (${outras.join(', ')}) continuam como estão.`
          : `A ${unid} volta a ficar disponível no espelho e a pasta volta para "Pasta aprovada".`,
        confirmar: 'Liberar unidade', perigo: true,
      }))) return;
      executar(card, etapa);
      return;
    }
    if (!unid) { setEscolha({ card, etapa }); return; }
    if (etapa === 'assinado' && !(await confirmar({ titulo: `Marcar a unidade ${unid} como vendida?`, texto: `${nome} vai para "Assinado / Vendido" e a unidade aparece como vendida no espelho e na TV.`, confirmar: 'Marcar como vendida' }))) return;
    executar(card, etapa);
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
        <div><h2>Funil de vendas</h2><p className="sub">Cada unidade em negociação é um card. Arraste o card para mudar a etapa; o espelho acompanha. Para outra unidade do mesmo cliente, reserve no espelho.</p></div>
      </div>

      <div className="funil-filtros">
        <label className="busca-funil">
          <Search size={18} aria-hidden="true" />
          <input value={busca} onChange={(e) => setBusca(e.target.value)}
            placeholder="Buscar por cliente, corretor, imobiliária, unidade ou código" aria-label="Buscar no funil" />
          {busca && <button className="icone-botao" onClick={() => setBusca('')} aria-label="Limpar busca"><X size={16} /></button>}
        </label>
        {imobiliarias.length > 1 && (
          <select value={imob} onChange={(e) => setImob(e.target.value)} aria-label="Filtrar por imobiliária">
            <option value="">Todas as imobiliárias</option>
            {imobiliarias.map(([id, nome]) => <option key={id} value={id}>{nome}</option>)}
          </select>
        )}
        {(busca || imob) && (
          <span className="funil-contagem">{visiveis.length} de {cards?.length ?? 0} cards</span>
        )}
      </div>

      {escolha && (
        <EscolherUnidade card={escolha.card} etapa={escolha.etapa} aoFechar={() => setEscolha(null)}
          aoConfirmar={async (u) => { if (await executar(escolha.card, escolha.etapa, u)) setEscolha(null); }} />
      )}
      {cards === null ? <p className="vazio">Carregando…</p> : (
        <div className="kanban">
          {ETAPAS.map((et) => {
            const lista = visiveis.filter((c) => c.etapa === et.valor);
            return (
              <div key={et.valor} className={`coluna k-${et.valor}${sobre === et.valor ? ' sobre' : ''}`}
                onDragOver={(e) => { e.preventDefault(); setSobre(et.valor); }}
                onDragLeave={() => setSobre((s) => (s === et.valor ? null : s))}
                onDrop={soltar(et.valor)}>
                <div className="coluna-topo"><div><h3>{et.rotulo}</h3><span className="coluna-espelho">Espelho: {ESPELHO[et.valor]}</span></div><span className="contagem">{lista.length}</span></div>
                <div className="coluna-cards">
                  {lista.length === 0 && <p className="coluna-vazia">Nenhum card nesta etapa.</p>}
                  {lista.map((c) => {
                    const dias = diasDesde(c.desde);
                    return (
                      <article key={c.chave} className={`kcard${arrastando === c.chave ? ' arrastando' : ''}`} draggable
                        onDragStart={(e) => { e.dataTransfer.setData('text/plain', c.chave); e.dataTransfer.effectAllowed = 'move'; setArrastando(c.chave); }}
                        onDragEnd={() => { setArrastando(null); setSobre(null); }}>
                        <div className="kcard-topo">
                          <span className="mono">{c.pasta.codigo_aprovacao ?? c.pasta.codigo}</span>
                          {c.unidade && <span className="kcard-unidade">Unid. {c.unidade.numero}</span>}
                          <GripVertical size={16} className="alca" aria-hidden="true" />
                        </div>
                        <button className="kcard-nome" onClick={() => ir(`/painel/pastas/${c.pasta.id}`)}>{c.pasta.comprador_nome}</button>
                        <p className="kcard-meta">{c.pasta.imobiliarias?.nome}{c.pasta.criado_por ? `, ${nomes[c.pasta.criado_por] ?? c.pasta.criado_por}` : ''}</p>
                        {c.unidade && (c.pasta.unidades_numeros ?? '').includes(',') && (
                          <p className="kcard-meta">Também com: {(c.pasta.unidades_numeros ?? '').split(', ').filter((n) => n !== c.unidade!.numero).join(', ')}</p>
                        )}
                        <div className="kcard-pe">
                          {dias !== null && <span className="kcard-dias"><Clock size={13} /> {dias === 0 ? 'hoje' : `${dias} ${dias === 1 ? 'dia' : 'dias'}`}</span>}
                          <select value={c.etapa} onChange={(e) => mover(c.chave, e.target.value as Etapa)} aria-label={`Mover ${c.pasta.comprador_nome} para outra etapa`}>
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

/** Escolha da unidade quando a pasta ainda não tem uma. */
function EscolherUnidade({ card, etapa, aoFechar, aoConfirmar }: {
  card: Card; etapa: Etapa; aoFechar: () => void; aoConfirmar: (unidade: string) => Promise<void>;
}) {
  const [unidades, setUnidades] = useState<{ id: string; numero: string; area_privativa: number | null }[]>([]);
  const [valor, setValor] = useState('');
  const [enviando, setEnviando] = useState(false);
  useEffect(() => {
    supabase.from('unidades').select('id, numero, area_privativa').eq('status', 'disponivel').order('andar').order('posicao')
      .then(({ data }) => setUnidades((data as typeof unidades) ?? []));
  }, []);
  return (
    <div className="fundo-dialogo" onClick={aoFechar}>
      <div className="dialogo confirmacao" role="dialog" aria-modal="true" aria-labelledby="esc-titulo" onClick={(e) => e.stopPropagation()}>
        <h2 id="esc-titulo">Qual unidade de {card.pasta.comprador_nome}?</h2>
        <p>A pasta vai para “{ETAPAS.find((x) => x.valor === etapa)?.rotulo}” e a unidade fica como “{ESPELHO[etapa]}” no espelho.</p>
        <label className="campo-motivo" style={{ marginTop: 14 }}>Unidades disponíveis
          <select value={valor} onChange={(e) => setValor(e.target.value)} autoFocus>
            <option value="">Escolha…</option>
            {unidades.map((u) => <option key={u.id} value={u.id}>{u.numero}{u.area_privativa ? `, ${u.area_privativa.toLocaleString('pt-BR')} m²` : ''}</option>)}
          </select>
        </label>
        <div className="dialogo-acoes">
          <button className="botao" onClick={aoFechar}>Cancelar</button>
          <button className="botao principal" disabled={!valor || enviando}
            onClick={async () => { setEnviando(true); await aoConfirmar(valor); setEnviando(false); }}>
            {enviando ? 'Salvando…' : 'Confirmar unidade'}
          </button>
        </div>
      </div>
    </div>
  );
}
