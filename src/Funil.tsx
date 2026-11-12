import { useCallback, useEffect, useMemo, useState, type DragEvent } from 'react';
import { Clock, GripVertical } from 'lucide-react';
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
  const { avisar, confirmar } = useDialogos();
  const [escolha, setEscolha] = useState<{ card: Card; etapa: Etapa } | null>(null);
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

  const ERROS: Record<string, string> = {
    SEM_UNIDADE: 'Escolha a unidade desta pasta.',
    UNIDADE_OCUPADA: 'Essa unidade já está em negociação com outro cliente no espelho.',
    PASTA_JA_TEM_UNIDADE: 'Esta pasta já está em outra unidade. Volte o card para "Pasta aprovada" para trocar.',
    PASTA_NAO_APROVADA: 'A documentação desta pasta não está mais aprovada.',
  };

  const executar = async (card: Card, etapa: Etapa, unidade?: string) => {
    const { error } = await supabase.rpc('mover_etapa', { p_pasta: card.id, p_etapa: etapa, p_unidade: unidade ?? null });
    if (error) {
      const chave = Object.keys(ERROS).find((k) => error.message.includes(k));
      avisar(chave ? ERROS[chave] : 'Não foi possível mover a pasta. Tente novamente.', 'erro');
      return false;
    }
    await carregar();
    avisar(`${card.comprador_nome}: ${ETAPAS.find((e) => e.valor === etapa)?.rotulo}. Espelho atualizado.`);
    return true;
  };

  const mover = async (id: string, etapa: Etapa) => {
    const card = cards?.find((c) => c.id === id);
    if (!card || card.etapa_venda === etapa) return;
    const unid = card.unidades?.numero;
    if (etapa === 'aprovada') {
      if (unid && !(await confirmar({ titulo: `Voltar ${card.comprador_nome} para "Pasta aprovada"?`, texto: `A unidade ${unid} volta a ficar disponível no espelho.`, confirmar: 'Voltar e liberar unidade', perigo: true }))) return;
      executar(card, etapa);
      return;
    }
    if (!unid) { setEscolha({ card, etapa }); return; }
    if (etapa === 'assinado' && !(await confirmar({ titulo: `Marcar a unidade ${unid} como vendida?`, texto: `${card.comprador_nome} vai para "Assinado / Vendido" e a unidade aparece como vendida no espelho e na TV.`, confirmar: 'Marcar como vendida' }))) return;
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
        <div><h2>Funil de vendas</h2><p className="sub">Pastas com documentação aprovada. Arraste o card para mudar a etapa; o espelho acompanha.</p></div>
        {imobiliarias.length > 1 && (
          <select value={imob} onChange={(e) => setImob(e.target.value)} aria-label="Filtrar por imobiliária" style={{ width: 'auto' }}>
            <option value="">Todas as imobiliárias</option>
            {imobiliarias.map(([id, nome]) => <option key={id} value={id}>{nome}</option>)}
          </select>
        )}
      </div>

      {escolha && (
        <EscolherUnidade card={escolha.card} etapa={escolha.etapa} aoFechar={() => setEscolha(null)}
          aoConfirmar={async (u) => { if (await executar(escolha.card, escolha.etapa, u)) setEscolha(null); }} />
      )}
      {cards === null ? <p className="vazio">Carregando…</p> : (
        <div className="kanban">
          {ETAPAS.map((et) => {
            const lista = visiveis.filter((c) => c.etapa_venda === et.valor);
            return (
              <div key={et.valor} className={`coluna k-${et.valor}${sobre === et.valor ? ' sobre' : ''}`}
                onDragOver={(e) => { e.preventDefault(); setSobre(et.valor); }}
                onDragLeave={() => setSobre((s) => (s === et.valor ? null : s))}
                onDrop={soltar(et.valor)}>
                <div className="coluna-topo"><div><h3>{et.rotulo}</h3><span className="coluna-espelho">Espelho: {ESPELHO[et.valor]}</span></div><span className="contagem">{lista.length}</span></div>
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
        <h2 id="esc-titulo">Qual unidade de {card.comprador_nome}?</h2>
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
