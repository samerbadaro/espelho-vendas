// Leads das campanhas (Meta → planilha → sistema): rodízio por imobiliária e corretor,
// prazo para assumir, funil de atendimento, motivos de perda e conversão em pasta.
import { Fragment, useCallback, useEffect, useMemo, useState } from 'react';
import { CheckCircle2, Clock, Copy, KeyRound, MessageCircle, Phone, RefreshCw, Send, UserCheck } from 'lucide-react';
import { supabase, formatarDataHora } from './dados';
import { useDialogos } from './ui';
import { formatarTelefone, ir, type Perfil } from './util';

export const ETAPAS: { v: string; r: string; c: string }[] = [
  { v: 'aguardando_aceite', r: 'Aguardando aceite', c: 'sp-aguardando_analise' },
  { v: 'em_atendimento', r: 'Em atendimento', c: 'sp-em_analise' },
  { v: 'visita_agendada', r: 'Visita agendada', c: 'sp-pronta' },
  { v: 'visita_realizada', r: 'Visita realizada', c: 'sp-pronta' },
  { v: 'proposta', r: 'Proposta', c: 'sp-pronta' },
  { v: 'convertido', r: 'Virou pasta', c: 'sp-aprovada' },
  { v: 'perdido', r: 'Perdido', c: 'sp-pendente_correcao' },
  { v: 'sem_destino', r: 'Aguardando Sec. Vendas', c: 'sp-incompleta' },
];
const etapa = (v: string) => ETAPAS.find((e) => e.v === v) ?? { v, r: v, c: 'sp-incompleta' };
const MOTIVOS = ['Sem interesse', 'Preço', 'Renda ou crédito insuficiente', 'Localização', 'Comprou outro imóvel', 'Só pesquisando',
  'Contato inválido', 'Não atende após várias tentativas', 'Lead duplicado', 'Outro'];
const CANAIS = ['WhatsApp', 'Ligação', 'E-mail', 'Presencial'];
const DIAS = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];

export interface Lead {
  id: string; codigo: string; status: string; campanha: string | null; conjunto: string | null; anuncio: string | null; formulario: string | null; plataforma: string | null;
  recebido_em: string; nome: string | null; telefone: string | null; email: string | null; respostas: Record<string, string>;
  imobiliaria_id: string | null; imobiliaria: string | null; corretor_id: string | null; corretor: string | null;
  distribuido_em: string | null; prazo_aceite_em: string | null; aceito_em: string | null; primeiro_contato_em: string | null;
  tentativas: number; motivo_perda: string | null; observacao: string | null; pasta_id: string | null; pasta_codigo: string | null;
  convertido_em: string | null; retorno: boolean; mascarado: boolean;
}

/** Contagem regressiva até o prazo de aceite. */
function useAgora(ms = 15000) {
  const [agora, setAgora] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setAgora(Date.now()), ms); return () => clearInterval(t); }, [ms]);
  return agora;
}
const restante = (prazo: string | null, agora: number) => {
  if (!prazo) return '';
  const m = Math.round((new Date(prazo).getTime() - agora) / 60000);
  if (m < 0) return 'prazo esgotado';
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h${String(m % 60).padStart(2, '0')}` : `até ${formatarDataHora(prazo)}`;
};
const rotuloResposta = (k: string) => (/\s/.test(k) || !k.includes('_') ? k : k.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase())).replace(/[:?]\s*$/, '');

// ============================================================================
export function Leads({ perfil }: { perfil: Perfil }) {
  const equipe = perfil.papel === 'admin' || perfil.papel === 'vendas';
  const gestor = perfil.papel === 'imobiliaria';
  const [aba, setAba] = useState<'leads' | 'rodizio' | 'config'>('leads');
  return (
    <section className="secao leads">
      <div className="secao-topo">
        <div>
          <h2>Leads</h2>
          <p className="sub">{perfil.papel === 'corretor'
            ? 'Leads das campanhas direcionados a você. Assuma dentro do prazo para ver o contato; depois, registre cada etapa do atendimento.'
            : 'Leads das campanhas do Meta, distribuídos por rodízio. Acompanhe prazo, atendimento, perdas e conversão em pasta.'}</p>
        </div>
      </div>
      {(equipe || gestor) && (
        <div className="abas">
          <button className={aba === 'leads' ? 'ativa' : ''} onClick={() => setAba('leads')}>Leads</button>
          <button className={aba === 'rodizio' ? 'ativa' : ''} onClick={() => setAba('rodizio')}>Rodízio</button>
          {perfil.papel === 'admin' && <button className={aba === 'config' ? 'ativa' : ''} onClick={() => setAba('config')}>Configuração e planilha</button>}
        </div>
      )}
      {aba === 'leads' && <ListaLeads perfil={perfil} />}
      {aba === 'rodizio' && <Rodizio perfil={perfil} />}
      {aba === 'config' && <ConfigLeads />}
    </section>
  );
}

// ---------------------------------------------------------------------------
function ListaLeads({ perfil }: { perfil: Perfil }) {
  const corretor = perfil.papel === 'corretor';
  const equipe = perfil.papel === 'admin' || perfil.papel === 'vendas';
  const [lista, setLista] = useState<Lead[] | null>(null);
  const [filtro, setFiltro] = useState('');
  const [busca, setBusca] = useState('');
  const [campanha, setCampanha] = useState('');
  const [imob, setImob] = useState('');
  const [dias, setDias] = useState(30);
  const agora = useAgora();

  const carregar = useCallback(async () => {
    const { data } = await supabase.rpc('listar_leads');
    setLista((data as Lead[]) ?? []);
  }, []);
  useEffect(() => { carregar(); const t = setInterval(carregar, 30000); return () => clearInterval(t); }, [carregar]);

  const doPeriodo = useMemo(() => (lista ?? []).filter((l) => !dias || new Date(l.recebido_em).getTime() > Date.now() - dias * 864e5), [lista, dias]);
  const base = doPeriodo.filter((l) => (!campanha || l.campanha === campanha) && (!imob || l.imobiliaria_id === imob));
  const visiveis = base.filter((l) => (!filtro || l.status === filtro)
    && (!busca || `${l.codigo} ${l.nome ?? ''} ${l.corretor ?? ''} ${l.telefone ?? ''}`.toLowerCase().includes(busca.toLowerCase())));
  const campanhas = [...new Set((lista ?? []).map((l) => l.campanha).filter(Boolean))] as string[];
  const imobs = [...new Map((lista ?? []).filter((l) => l.imobiliaria_id).map((l) => [l.imobiliaria_id!, l.imobiliaria ?? ''])).entries()];

  const aceitos = base.filter((l) => l.aceito_em && l.distribuido_em);
  const tempoMedio = aceitos.length ? Math.max(0, Math.round(aceitos.reduce((s, l) => s + Math.max(0, new Date(l.aceito_em!).getTime() - new Date(l.distribuido_em!).getTime()), 0) / aceitos.length / 60000)) : null;
  const convertidos = base.filter((l) => l.status === 'convertido').length;
  const perdidos = base.filter((l) => l.status === 'perdido');
  const motivos = Object.entries(perdidos.reduce<Record<string, number>>((a, l) => { const m = l.motivo_perda ?? '—'; a[m] = (a[m] ?? 0) + 1; return a; }, {})).sort((a, b) => b[1] - a[1]);

  if (!lista) return <p className="vazio">Carregando…</p>;
  return (
    <>
      <div className="ld-resumo">
        <div className="ld-num"><strong>{base.length}</strong><span>leads no período</span></div>
        <div className="ld-num"><strong>{tempoMedio == null ? '—' : tempoMedio < 60 ? `${tempoMedio} min` : `${Math.floor(tempoMedio / 60)}h${String(tempoMedio % 60).padStart(2, '0')}`}</strong><span>tempo médio para assumir</span></div>
        <div className="ld-num"><strong>{base.length ? `${Math.round((convertidos / base.length) * 100)}%` : '—'}</strong><span>viraram pasta ({convertidos})</span></div>
        <div className="ld-num"><strong>{perdidos.length}</strong><span>perdidos{motivos[0] ? ` · mais comum: ${motivos[0][0]}` : ''}</span></div>
      </div>

      <div className="ld-funil">
        <button className={!filtro ? 'ativo' : ''} onClick={() => setFiltro('')}>Todos <b>{base.length}</b></button>
        {ETAPAS.filter((e) => !corretor || e.v !== 'sem_destino').map((e) => (
          <button key={e.v} className={filtro === e.v ? 'ativo' : ''} onClick={() => setFiltro(filtro === e.v ? '' : e.v)}>
            {e.r} <b>{base.filter((l) => l.status === e.v).length}</b>
          </button>
        ))}
      </div>

      <div className="filtros">
        <input placeholder="Buscar por código, nome, corretor…" value={busca} onChange={(e) => setBusca(e.target.value)} />
        {campanhas.length > 1 && <select value={campanha} onChange={(e) => setCampanha(e.target.value)}><option value="">Todas as campanhas</option>{campanhas.map((c) => <option key={c}>{c}</option>)}</select>}
        {equipe && imobs.length > 1 && <select value={imob} onChange={(e) => setImob(e.target.value)}><option value="">Todas as imobiliárias</option>{imobs.map(([i, n]) => <option key={i} value={i}>{n}</option>)}</select>}
        <select value={dias} onChange={(e) => setDias(Number(e.target.value))}>
          <option value={7}>Últimos 7 dias</option><option value={30}>Últimos 30 dias</option><option value={90}>Últimos 90 dias</option><option value={0}>Tudo</option>
        </select>
        <button className="botao" onClick={carregar}><RefreshCw size={15} /> Atualizar</button>
      </div>

      {!visiveis.length ? <p className="vazio">{lista.length ? 'Nenhum lead com esses filtros.' : corretor ? 'Nenhum lead direcionado a você ainda.' : 'Nenhum lead recebido ainda. Configure a planilha em “Configuração e planilha”.'}</p> : (
        <div className="tabela-rolagem">
          <table className="tabela ld-tabela">
            <thead><tr><th>Lead</th><th>Recebido</th><th>Cliente</th><th>Campanha</th>{!corretor && <th>Imobiliária · corretor</th>}<th>Etapa</th></tr></thead>
            <tbody>
              {visiveis.map((l) => (
                <tr key={l.id} className="clicavel" onClick={() => ir(`/painel/leads/${l.id}`)}>
                  <td className="mono">{l.codigo}{l.retorno && <><br /><small className="sub">cliente voltou</small></>}</td>
                  <td>{formatarDataHora(l.recebido_em)}</td>
                  <td><strong>{l.nome || '—'}</strong>{l.motivo_perda && <><br /><small className="sub">{l.motivo_perda}</small></>}</td>
                  <td>{l.campanha || '—'}{l.formulario && <><br /><small className="sub">{l.formulario}</small></>}</td>
                  {!corretor && <td>{l.imobiliaria || '—'}<br /><small className="sub">{l.corretor || 'sem corretor'}{l.tentativas > 1 ? ` · ${l.tentativas}ª tentativa` : ''}</small></td>}
                  <td>
                    <span className={`selo ${etapa(l.status).c}`}>{etapa(l.status).r}</span>
                    {l.status === 'aguardando_aceite' && <><br /><small className={`ld-prazo ${new Date(l.prazo_aceite_em ?? 0).getTime() < agora ? 'vencido' : ''}`}><Clock size={12} /> {restante(l.prazo_aceite_em, agora)}</small></>}
                    {l.status === 'em_atendimento' && !l.primeiro_contato_em && <><br /><small className="ld-prazo vencido">sem contato registrado</small></>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {!corretor && motivos.length > 0 && (
        <div className="cartao ld-motivos">
          <h3>Motivos de perda no período</h3>
          <ul>{motivos.map(([m, n]) => <li key={m}><span>{m}</span><b>{n}</b><i style={{ width: `${(n / perdidos.length) * 100}%` }} /></li>)}</ul>
        </div>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
interface Evento { id: number; tipo: string; detalhes: Record<string, string | boolean | number | null>; usuario_email: string | null; criado_em: string }

export function DetalheLead({ id, perfil }: { id: string; perfil: Perfil }) {
  const { avisar, confirmar } = useDialogos();
  const equipe = perfil.papel === 'admin' || perfil.papel === 'vendas';
  const gestor = perfil.papel === 'imobiliaria';
  const [l, setL] = useState<Lead | null | undefined>(undefined);
  const [eventos, setEventos] = useState<Evento[]>([]);
  const [corretores, setCorretores] = useState<{ user_id: string; nome: string; imob: string }[]>([]);
  const [pastas, setPastas] = useState<{ id: string; codigo: string; comprador_nome: string }[]>([]);
  const [canal, setCanal] = useState('WhatsApp');
  const [nota, setNota] = useState('');
  const [motivo, setMotivo] = useState('');
  const [obs, setObs] = useState('');
  const [destino, setDestino] = useState('');
  const [pastaEsc, setPastaEsc] = useState('');
  const [ocupado, setOcupado] = useState(false);
  const agora = useAgora(10000);

  const carregar = useCallback(async () => {
    const [{ data }, { data: ev }] = await Promise.all([
      supabase.rpc('listar_leads', { p_id: id }),
      supabase.from('lead_eventos').select('*').eq('lead_id', id).order('criado_em', { ascending: false }),
    ]);
    setL(((data as Lead[]) ?? [])[0] ?? null);
    setEventos((ev as Evento[]) ?? []);
  }, [id]);
  useEffect(() => { carregar(); }, [carregar]);
  useEffect(() => {
    if (!equipe && !gestor) return;
    let q = supabase.from('perfis').select('user_id, nome, email, imobiliarias(nome)').eq('papel', 'corretor');
    if (gestor && perfil.imobiliaria_id) q = q.eq('imobiliaria_id', perfil.imobiliaria_id);
    q.then(({ data }) => setCorretores(((data as unknown as { user_id: string; nome: string | null; email: string; imobiliarias: { nome: string } | null }[]) ?? [])
      .map((c) => ({ user_id: c.user_id, nome: c.nome || c.email, imob: c.imobiliarias?.nome ?? '' }))
      .sort((a, b) => `${a.imob}${a.nome}`.localeCompare(`${b.imob}${b.nome}`, 'pt-BR'))));
  }, [equipe, gestor, perfil.imobiliaria_id]);
  useEffect(() => {
    if (!l || l.status === 'convertido' || l.mascarado) return;
    supabase.from('pastas').select('id, codigo, comprador_nome').order('criada_em', { ascending: false }).limit(300)
      .then(({ data }) => setPastas((data as { id: string; codigo: string; comprador_nome: string }[]) ?? []));
  }, [l]);

  const rpc = async (nome: string, args: Record<string, unknown>, ok: string) => {
    setOcupado(true);
    const { error } = await supabase.rpc(nome, args);
    setOcupado(false);
    if (error) {
      const m = error.message;
      avisar(m.includes('LEAD_JA_ASSUMIDO') || m.includes('LEAD_NAO_E_SEU') ? 'Este lead já não está mais com você (o prazo pode ter acabado).'
        : m.includes('MOTIVO_OBRIGATORIO') ? 'Escolha o motivo da perda.' : m.includes('LEAD_SEM_ATENDIMENTO') ? 'O lead precisa ser assumido antes.'
        : m.includes('SEM_PERMISSAO') ? 'Você não tem permissão para isso.' : 'Não foi possível concluir.', 'erro');
      carregar(); return false;
    }
    avisar(ok); carregar(); return true;
  };

  if (l === undefined) return <section className="secao"><p className="vazio">Carregando…</p></section>;
  if (!l) return <section className="secao"><button className="voltar" onClick={() => ir('/painel/leads')}>‹ Leads</button><p className="erro">Lead não encontrado ou não está mais com você.</p></section>;

  const meu = l.corretor_id === perfil.user_id;
  const atendendo = !['aguardando_aceite', 'sem_destino'].includes(l.status);
  const podeMexer = equipe || gestor || (meu && atendendo);
  const aberto = !['convertido', 'perdido'].includes(l.status);
  const tel = (l.telefone ?? '').replace(/\D/g, '');

  const criarPasta = () => {
    try { sessionStorage.setItem('lead-para-pasta', JSON.stringify({ lead: l.id, nome: l.nome, telefone: l.telefone, email: l.email, imobiliaria_id: l.imobiliaria_id })); } catch { /* */ }
    ir('/painel/pastas/nova');
  };

  return (
    <section className="secao lead-detalhe">
      <button className="voltar" onClick={() => ir('/painel/leads')}>‹ Leads</button>
      <div className="secao-topo">
        <div>
          <h2>{l.nome || 'Lead'} <span className="mono sub">{l.codigo}</span></h2>
          <p className="sub">Recebido em {formatarDataHora(l.recebido_em)} · {l.campanha || 'campanha não informada'}{l.formulario ? ` · ${l.formulario}` : ''}{l.plataforma ? ` · ${l.plataforma}` : ''}
            {l.retorno && ' · cliente que voltou'}</p>
        </div>
        <span className={`selo grande ${etapa(l.status).c}`}>{etapa(l.status).r}</span>
      </div>

      {l.status === 'aguardando_aceite' && meu && (
        <div className="cartao ld-assumir">
          <div>
            <h3>Lead direcionado a você</h3>
            <p className="sub">Assuma para ver telefone e e-mail. Prazo: <strong>{restante(l.prazo_aceite_em, agora)}</strong>{l.prazo_aceite_em ? ` (${formatarDataHora(l.prazo_aceite_em)})` : ''}. Depois disso, ele vai para o próximo corretor.</p>
          </div>
          <button className="botao principal" disabled={ocupado} onClick={() => rpc('assumir_lead', { p_id: l.id }, 'Lead assumido. Faça o primeiro contato e registre aqui.')}><UserCheck size={18} /> Assumir lead</button>
        </div>
      )}

      <div className="ld-grade">
        <div className="cartao">
          <h3>Contato</h3>
          {l.mascarado ? <p className="sub">Telefone e e-mail aparecem depois que o lead for assumido.</p> : (
            <div className="ld-contato">
              {l.telefone && <a className="botao" href={`https://wa.me/55${tel}`} target="_blank" rel="noreferrer"><MessageCircle size={16} /> WhatsApp {formatarTelefone(l.telefone)}</a>}
              {l.telefone && <a className="botao" href={`tel:+55${tel}`}><Phone size={16} /> Ligar</a>}
              {l.email && <a className="botao" href={`mailto:${l.email}`}><Send size={16} /> {l.email}</a>}
              {!l.telefone && !l.email && <p className="sub">O formulário não trouxe telefone nem e-mail.</p>}
            </div>
          )}
          <dl className="ld-dados">
            <dt>Imobiliária</dt><dd>{l.imobiliaria || '—'}</dd>
            <dt>Corretor</dt><dd>{l.corretor || '—'}{l.tentativas > 1 ? ` (${l.tentativas}ª tentativa)` : ''}</dd>
            {l.aceito_em && <><dt>Assumido</dt><dd>{formatarDataHora(l.aceito_em)}</dd></>}
            {l.primeiro_contato_em && <><dt>Primeiro contato</dt><dd>{formatarDataHora(l.primeiro_contato_em)}</dd></>}
            {l.pasta_id && <><dt>Pasta</dt><dd><a href={`/painel/pastas/${l.pasta_id}`} onClick={(e) => { e.preventDefault(); ir(`/painel/pastas/${l.pasta_id}`); }} className="mono">{l.pasta_codigo}</a></dd></>}
            {l.motivo_perda && <><dt>Motivo da perda</dt><dd>{l.motivo_perda}</dd></>}
            {l.observacao && <><dt>Observação</dt><dd>{l.observacao}</dd></>}
          </dl>
        </div>
        <div className="cartao">
          <h3>Respostas do formulário</h3>
          {Object.keys(l.respostas ?? {}).length ? (
            <dl className="ld-dados">{Object.entries(l.respostas).map(([k, v]) => <Fragment key={k}><dt>{rotuloResposta(k)}</dt><dd>{v}</dd></Fragment>)}</dl>
          ) : <p className="sub">Sem perguntas adicionais.</p>}
          {(l.anuncio || l.conjunto) && <p className="sub">Anúncio: {l.anuncio || '—'} · Conjunto: {l.conjunto || '—'}</p>}
        </div>
      </div>

      {podeMexer && atendendo && aberto && (
        <div className="cartao">
          <h3>Atendimento</h3>
          <div className="ld-acao">
            <select value={canal} onChange={(e) => setCanal(e.target.value)}>{CANAIS.map((c) => <option key={c}>{c}</option>)}</select>
            <input placeholder="O que foi conversado (opcional)" value={nota} onChange={(e) => setNota(e.target.value)} />
            <button className="botao" disabled={ocupado} onClick={async () => { if (await rpc('registrar_contato_lead', { p_id: l.id, p_canal: canal, p_nota: nota }, 'Contato registrado.')) setNota(''); }}><CheckCircle2 size={16} /> Registrar contato</button>
          </div>
          <div className="ld-etapas">
            <span className="sub">Mover para:</span>
            {ETAPAS.filter((e) => ['em_atendimento', 'visita_agendada', 'visita_realizada', 'proposta'].includes(e.v)).map((e) => (
              <button key={e.v} className={`botao pequeno ${l.status === e.v ? 'principal' : ''}`} disabled={ocupado || l.status === e.v}
                onClick={() => rpc('mover_lead', { p_id: l.id, p_status: e.v, p_motivo: null, p_obs: obs || null }, `Etapa: ${e.r}.`)}>{e.r}</button>
            ))}
          </div>
          <div className="ld-acao">
            <button className="botao principal" onClick={criarPasta}>Criar pasta com este cliente</button>
            {pastas.length > 0 && (
              <>
                <select value={pastaEsc} onChange={(e) => setPastaEsc(e.target.value)}><option value="">ou vincular a uma pasta existente…</option>{pastas.map((p) => <option key={p.id} value={p.id}>{p.codigo} · {p.comprador_nome}</option>)}</select>
                <button className="botao" disabled={!pastaEsc || ocupado} onClick={() => rpc('vincular_pasta_lead', { p_lead: l.id, p_pasta: pastaEsc }, 'Lead convertido em pasta.')}>Vincular</button>
              </>
            )}
          </div>
          <div className="ld-acao ld-perda">
            <select value={motivo} onChange={(e) => setMotivo(e.target.value)}><option value="">Motivo da perda…</option>{MOTIVOS.map((m) => <option key={m}>{m}</option>)}</select>
            <input placeholder="Observação (obrigatória em “Outro”)" value={obs} onChange={(e) => setObs(e.target.value)} />
            <button className="botao perigo" disabled={ocupado || !motivo || (motivo === 'Outro' && !obs.trim())} onClick={async () => {
              if (await confirmar({ titulo: 'Marcar como perdido?', texto: `Motivo: ${motivo}${obs ? ` — ${obs}` : ''}.`, confirmar: 'Marcar como perdido', perigo: true }))
                rpc('mover_lead', { p_id: l.id, p_status: 'perdido', p_motivo: motivo === 'Outro' ? obs : motivo, p_obs: obs || null }, 'Lead marcado como perdido.');
            }}>Marcar como perdido</button>
          </div>
        </div>
      )}

      {(equipe || gestor) && (
        <div className="cartao">
          <h3>{l.status === 'sem_destino' ? 'Distribuir este lead' : 'Redirecionar'}</h3>
          {!aberto && <p className="sub">Para reabrir, mova para “Em atendimento”.</p>}
          {!aberto && <div className="ld-acao"><button className="botao" disabled={ocupado} onClick={() => rpc('mover_lead', { p_id: l.id, p_status: 'em_atendimento' }, 'Lead reaberto.')}>Reabrir atendimento</button></div>}
          {l.status !== 'convertido' && (
            <div className="ld-acao">
              <select value={destino} onChange={(e) => setDestino(e.target.value)}>
                <option value="">Escolha o corretor…</option>
                {corretores.map((c) => <option key={c.user_id} value={c.user_id}>{equipe ? `${c.imob} · ` : ''}{c.nome}</option>)}
              </select>
              <button className="botao principal" disabled={!destino || ocupado} onClick={() => rpc('redistribuir_lead', { p_id: l.id, p_corretor: destino }, 'Lead enviado ao corretor, com novo prazo para assumir.')}>Enviar ao corretor</button>
              {equipe && <button className="botao" disabled={ocupado} onClick={() => rpc('redistribuir_lead', { p_id: l.id, p_corretor: null }, 'Lead devolvido ao rodízio.')}><RefreshCw size={15} /> Devolver ao rodízio</button>}
            </div>
          )}
        </div>
      )}

      <div className="cartao">
        <h3>Histórico</h3>
        <ul className="ld-historico">
          {eventos.map((e) => (
            <li key={e.id}>
              <span className="sub">{formatarDataHora(e.criado_em)}</span>
              <div><strong>{e.tipo}</strong>
                {Object.entries(e.detalhes ?? {}).filter(([, v]) => v != null && v !== '' && v !== false).map(([k, v]) => (
                  <span key={k} className="sub"> · {k === 'prazo' ? `prazo ${formatarDataHora(String(v))}` : k === 'minutos' ? `em ${v} min` : k === 'automatico' ? 'automático (mesmo telefone/e-mail)' : String(v)}</span>
                ))}
                {e.usuario_email && e.usuario_email !== 'sistema' && <span className="sub"> · {e.usuario_email}</span>}
              </div>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
interface CorretorRod { user_id: string; nome: string | null; email: string; imobiliaria_id: string; participa: boolean; recebidos: number; ultimo_lead_em: string | null }

function Rodizio({ perfil }: { perfil: Perfil }) {
  const { avisar } = useDialogos();
  const admin = perfil.papel === 'admin';
  const gestor = perfil.papel === 'imobiliaria';
  const [imobs, setImobs] = useState<{ id: string; nome: string; cota: string; recebidos: number }[]>([]);
  const [corr, setCorr] = useState<CorretorRod[]>([]);
  const [zerar, setZerar] = useState(false);

  const carregar = useCallback(async () => {
    let qp = supabase.from('perfis').select('user_id, nome, email, imobiliaria_id').eq('papel', 'corretor');
    if (gestor && perfil.imobiliaria_id) qp = qp.eq('imobiliaria_id', perfil.imobiliaria_id);
    const [{ data: im }, { data: li }, { data: ps }, { data: lc }] = await Promise.all([
      gestor ? supabase.from('imobiliarias').select('id, nome').eq('id', perfil.imobiliaria_id ?? '') : supabase.from('imobiliarias').select('id, nome').eq('ativa', true).order('nome'),
      supabase.from('leads_imobiliarias').select('*'),
      qp, supabase.from('leads_corretores').select('*'),
    ]);
    const cot = new Map(((li as { imobiliaria_id: string; cota: number; recebidos: number }[]) ?? []).map((x) => [x.imobiliaria_id, x]));
    setImobs(((im as { id: string; nome: string }[]) ?? []).map((i) => ({ ...i, cota: String(Number(cot.get(i.id)?.cota ?? 0)).replace('.', ','), recebidos: cot.get(i.id)?.recebidos ?? 0 })));
    const rod = new Map(((lc as { user_id: string; participa: boolean; recebidos: number; ultimo_lead_em: string | null }[]) ?? []).map((x) => [x.user_id, x]));
    setCorr(((ps as { user_id: string; nome: string | null; email: string; imobiliaria_id: string }[]) ?? []).map((p) => ({
      ...p, participa: rod.get(p.user_id)?.participa ?? false, recebidos: rod.get(p.user_id)?.recebidos ?? 0, ultimo_lead_em: rod.get(p.user_id)?.ultimo_lead_em ?? null,
    })).sort((a, b) => (a.nome || a.email).localeCompare(b.nome || b.email, 'pt-BR')));
  }, [gestor, perfil.imobiliaria_id]);
  useEffect(() => { carregar(); }, [carregar]);

  const alternar = async (c: CorretorRod) => {
    const { error } = await supabase.rpc('definir_rodizio_corretor', { p_user: c.user_id, p_participa: !c.participa });
    if (error) avisar('Não foi possível alterar.', 'erro'); else carregar();
  };
  const salvarCotas = async () => {
    const { error } = await supabase.rpc('salvar_cotas_leads', { p_cotas: imobs.map((i) => ({ imobiliaria_id: i.id, cota: Number(i.cota.replace(',', '.')) || 0 })), p_zerar: zerar });
    if (error) avisar('Não foi possível salvar as cotas.', 'erro'); else { avisar('Cotas salvas.'); setZerar(false); carregar(); }
  };
  const somaCota = imobs.reduce((s, i) => s + (Number(i.cota.replace(',', '.')) || 0), 0);
  const somaRec = imobs.reduce((s, i) => s + i.recebidos, 0);

  return (
    <>
      {!gestor && (
        <div className="cartao">
          <h3>Cotas por imobiliária</h3>
          <p className="sub">Peso de cada imobiliária no rodízio (ex.: 40, 30, 30 ou 2, 1, 1). Cota zero não recebe. O sistema entrega cada lead para quem está mais abaixo da sua proporção, e só considera imobiliárias com pelo menos um corretor na lista.</p>
          <div className="tabela-rolagem"><table className="tabela">
            <thead><tr><th>Imobiliária</th><th>Cota</th><th>% previsto</th><th>Leads recebidos</th><th>% real</th><th>Corretores na lista</th></tr></thead>
            <tbody>{imobs.map((i, k) => {
              const c = Number(i.cota.replace(',', '.')) || 0;
              return (
                <tr key={i.id}>
                  <td>{i.nome}</td>
                  <td>{admin ? <input className="ld-cota" inputMode="decimal" value={i.cota} onChange={(e) => setImobs(imobs.map((x, j) => (j === k ? { ...x, cota: e.target.value } : x)))} /> : i.cota}</td>
                  <td>{somaCota ? `${Math.round((c / somaCota) * 100)}%` : '—'}</td>
                  <td>{i.recebidos}</td>
                  <td>{somaRec ? `${Math.round((i.recebidos / somaRec) * 100)}%` : '—'}</td>
                  <td>{corr.filter((x) => x.imobiliaria_id === i.id && x.participa).length}</td>
                </tr>
              );
            })}</tbody>
          </table></div>
          {admin && (
            <div className="acoes">
              <label className="ass-check"><input type="checkbox" checked={zerar} onChange={(e) => setZerar(e.target.checked)} /> Zerar a contagem de leads recebidos (recomeçar a proporção)</label>
              <button className="botao principal" onClick={salvarCotas}>Salvar cotas</button>
            </div>
          )}
        </div>
      )}
      <div className="cartao">
        <h3>{gestor ? 'Corretores da sua equipe no rodízio' : 'Corretores no rodízio'}</h3>
        <p className="sub">{gestor ? 'Marque quem recebe leads. Dentro da imobiliária, o lead vai para quem está há mais tempo sem receber.' : 'Cada imobiliária escolhe os seus; a equipe também pode ajustar.'}</p>
        {!corr.length ? <p className="vazio">Nenhum corretor cadastrado.</p> : (
          <div className="tabela-rolagem"><table className="tabela">
            <thead><tr>{!gestor && <th>Imobiliária</th>}<th>Corretor</th><th>No rodízio</th><th>Leads recebidos</th><th>Último lead</th></tr></thead>
            <tbody>{corr.filter((c) => gestor || imobs.some((i) => i.id === c.imobiliaria_id)).sort((a, b) => (imobs.find((i) => i.id === a.imobiliaria_id)?.nome ?? '').localeCompare(imobs.find((i) => i.id === b.imobiliaria_id)?.nome ?? '')).map((c) => (
              <tr key={c.user_id}>
                {!gestor && <td>{imobs.find((i) => i.id === c.imobiliaria_id)?.nome}</td>}
                <td>{c.nome || c.email}</td>
                <td><label className="interruptor"><input type="checkbox" checked={c.participa} onChange={() => alternar(c)} /><span className="trilho" aria-hidden="true" /><span>{c.participa ? 'Recebe' : 'Fora'}</span></label></td>
                <td>{c.recebidos}</td>
                <td>{c.ultimo_lead_em ? formatarDataHora(c.ultimo_lead_em) : '—'}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
interface Cfg {
  ativo: boolean; prazo_aceite_min: number; prazo_contato_min: number; max_tentativas: number; dias_semana: number[]; hora_inicio: string; hora_fim: string;
  plantao_24h: boolean; dono_dias: number; emails_alerta: string | null; remetente_email: string | null; remetente_nome: string | null;
  ultimo_recebimento: string | null; atualizado_em: string; atualizado_por: string | null;
}

export function scriptPlanilha(url: string, chave: string) {
  return `// Envia os leads novos desta planilha para o sistema (${url}).
// Instalação: Extensões → Apps Script → cole este código → salve → escolha a função "instalar" → Executar → autorize.
// Depois disso roda sozinho a cada minuto. Não altere a chave; para trocar, gere uma nova no sistema.
const URL_SISTEMA = '${url}/api/leads/entrada';
const CHAVE = '${chave}';

function enviarLeads() {
  const trava = LockService.getScriptLock();
  if (!trava.tryLock(20000)) return;
  try {
    const props = PropertiesService.getScriptProperties();
    const feitos = JSON.parse(props.getProperty('enviados') || '{}');
    for (const aba of SpreadsheetApp.getActive().getSheets()) {
      const nome = aba.getName();
      const ultima = aba.getLastRow();
      const inicio = (feitos[nome] || 1) + 1;
      if (ultima < inicio || aba.getLastColumn() < 2) continue;
      const titulos = aba.getRange(1, 1, 1, aba.getLastColumn()).getDisplayValues()[0];
      const cab = titulos.map(normalizar);
      const dados = aba.getRange(inicio, 1, ultima - inicio + 1, cab.length).getDisplayValues();
      const linhas = dados.map(function (l, i) {
        const o = { _linha: nome + ':' + (inicio + i), _rotulos: {} };
        cab.forEach(function (c, j) { if (c && l[j] !== '') { o[c] = l[j]; o._rotulos[c] = titulos[j]; } });
        return o;
      }).filter(function (o) { return Object.keys(o).length > 3; });
      for (let k = 0; k < linhas.length; k += 100) {
        const r = UrlFetchApp.fetch(URL_SISTEMA, {
          method: 'post', contentType: 'application/json', headers: { 'x-chave': CHAVE }, muteHttpExceptions: true,
          payload: JSON.stringify({ linhas: linhas.slice(k, k + 100), origem: 'Planilha · ' + nome }),
        });
        if (r.getResponseCode() !== 200) throw new Error('O sistema respondeu ' + r.getResponseCode() + ': ' + r.getContentText());
      }
      feitos[nome] = ultima;
      props.setProperty('enviados', JSON.stringify(feitos));
    }
  } finally { trava.releaseLock(); }
}

function normalizar(t) {
  return String(t).normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
}

// Instala o envio automático (a cada minuto) e já envia o que houver na planilha.
function instalar() {
  ScriptApp.getProjectTriggers().forEach(function (t) { ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('enviarLeads').timeBased().everyMinutes(1).create();
  enviarLeads();
}

// Opcional: marca tudo o que já está na planilha como enviado (para começar só com os próximos leads).
function comecarDeAgora() {
  const feitos = {};
  SpreadsheetApp.getActive().getSheets().forEach(function (a) { feitos[a.getName()] = a.getLastRow(); });
  PropertiesService.getScriptProperties().setProperty('enviados', JSON.stringify(feitos));
}
`;
}

function ConfigLeads() {
  const { avisar, confirmar } = useDialogos();
  const [c, setC] = useState<Cfg | null>(null);
  const [chave, setChave] = useState('');
  const [verScript, setVerScript] = useState(false);

  const carregar = useCallback(async () => {
    const { data } = await supabase.from('leads_config').select('*').eq('id', 1).maybeSingle();
    if (data) setC({ ...(data as Cfg), hora_inicio: String(data.hora_inicio).slice(0, 5), hora_fim: String(data.hora_fim).slice(0, 5) });
  }, []);
  useEffect(() => { carregar(); }, [carregar]);

  const pegarChave = async (nova: boolean) => {
    if (nova && !(await confirmar({ titulo: 'Gerar uma nova chave?', texto: 'O script atual da planilha para de funcionar até você colar o novo código.', confirmar: 'Gerar nova chave', perigo: true }))) return;
    const { data, error } = await supabase.rpc('chave_leads', { p_nova: nova });
    if (error) { avisar('Não foi possível obter a chave.', 'erro'); return; }
    setChave(String(data)); setVerScript(true);
  };
  const salvar = async () => {
    if (!c) return;
    const { error } = await supabase.rpc('salvar_config_leads', { p: c });
    if (error) avisar('Não foi possível salvar. Confira os valores.', 'erro'); else { avisar('Configuração salva.'); carregar(); }
  };
  if (!c) return <p className="vazio">Carregando…</p>;
  const set = <K extends keyof Cfg>(k: K, v: Cfg[K]) => setC({ ...c, [k]: v });
  const script = scriptPlanilha(window.location.origin, chave);

  return (
    <>
      <div className="cartao">
        <div className="cartao-topo">
          <div><h3>Regras do rodízio</h3><p className="sub">{c.atualizado_por ? `Alterado por ${c.atualizado_por} em ${formatarDataHora(c.atualizado_em)}.` : 'Padrões de mercado; ajuste à operação.'}</p></div>
          <label className="interruptor"><input type="checkbox" checked={c.ativo} onChange={(e) => set('ativo', e.target.checked)} /><span className="trilho" aria-hidden="true" /><span>{c.ativo ? 'Rodízio ligado' : 'Desligado: leads ficam com a Sec. Vendas'}</span></label>
        </div>
        <div className="grade-campos">
          <label>Prazo para assumir (minutos)<input type="number" min={1} value={c.prazo_aceite_min} onChange={(e) => set('prazo_aceite_min', Number(e.target.value))} /></label>
          <label>Prazo para o 1º contato (minutos)<input type="number" min={5} value={c.prazo_contato_min} onChange={(e) => set('prazo_contato_min', Number(e.target.value))} /><small className="sub">Passou disso sem contato registrado, o gestor da imobiliária é avisado.</small></label>
          <label>Corretores tentados antes da Sec. Vendas<input type="number" min={1} max={20} value={c.max_tentativas} onChange={(e) => set('max_tentativas', Number(e.target.value))} /></label>
          <label>Cliente que volta fica com o mesmo corretor por (dias)<input type="number" min={0} value={c.dono_dias} onChange={(e) => set('dono_dias', Number(e.target.value))} /></label>
        </div>
        <h4>Horário comercial</h4>
        <p className="sub">Fora dele o lead é distribuído na hora, mas o prazo só começa a contar na abertura.</p>
        <div className="ld-dias">
          {DIAS.map((d, i) => (
            <label key={d} className="ass-check"><input type="checkbox" disabled={c.plantao_24h} checked={c.dias_semana.includes(i + 1)}
              onChange={(e) => set('dias_semana', e.target.checked ? [...c.dias_semana, i + 1].sort() : c.dias_semana.filter((x) => x !== i + 1))} /> {d}</label>
          ))}
          <label>das <input type="time" disabled={c.plantao_24h} value={c.hora_inicio} onChange={(e) => set('hora_inicio', e.target.value)} /></label>
          <label>às <input type="time" disabled={c.plantao_24h} value={c.hora_fim} onChange={(e) => set('hora_fim', e.target.value)} /></label>
          <label className="ass-check"><input type="checkbox" checked={c.plantao_24h} onChange={(e) => set('plantao_24h', e.target.checked)} /> Plantão 24h (prazo corre sempre)</label>
        </div>
        <h4>Avisos por e-mail</h4>
        <div className="grade-campos">
          <label>Remetente (e-mail validado na Brevo)<input type="email" placeholder="leads@seudominio.com.br" value={c.remetente_email ?? ''} onChange={(e) => set('remetente_email', e.target.value)} /></label>
          <label>Nome do remetente<input value={c.remetente_nome ?? ''} onChange={(e) => set('remetente_nome', e.target.value)} /></label>
          <label className="largo">Quem recebe os leads sem corretor (e-mails separados por vírgula)<input placeholder="Vazio = usuários da Sec. Vendas" value={c.emails_alerta ?? ''} onChange={(e) => set('emails_alerta', e.target.value)} /></label>
        </div>
        <p className="sub">O envio usa a Brevo: cadastre a chave de API como segredo <code>BREVO_API_KEY</code> no Cloudflare (nunca por aqui). Sem ela, o rodízio funciona e os avisos aparecem só no painel.</p>
        <div className="acoes"><button className="botao principal" onClick={salvar}>Salvar regras</button></div>
      </div>

      <div className="cartao">
        <div className="cartao-topo">
          <div>
            <h3>Planilha do Meta</h3>
            <p className="sub">{c.ultimo_recebimento ? `Último envio da planilha: ${formatarDataHora(c.ultimo_recebimento)}.` : 'Nenhum envio recebido ainda.'}</p>
          </div>
        </div>
        <ol className="ld-passos">
          <li>No Business Suite: Formulários instantâneos → Configuração de CRM → Google Sheets, ligado à planilha dos leads.</li>
          <li>Na planilha: Extensões → Apps Script. Apague o que houver e cole o código abaixo.</li>
          <li>Salve, escolha a função <strong>instalar</strong> no menu de cima e clique em Executar. Autorize com a conta Google dona da planilha.</li>
          <li>Pronto: a cada minuto, as linhas novas entram aqui. Para ignorar o que já existe na planilha, execute <strong>comecarDeAgora</strong> antes de <strong>instalar</strong>.</li>
        </ol>
        <div className="acoes">
          {!chave && <button className="botao principal" onClick={() => pegarChave(false)}><KeyRound size={16} /> Mostrar o código do script</button>}
          {chave && <button className="botao principal" onClick={() => { navigator.clipboard.writeText(script); avisar('Código copiado.'); }}><Copy size={16} /> Copiar código</button>}
          <button className="botao" onClick={() => pegarChave(true)}>Gerar nova chave</button>
        </div>
        {verScript && chave && <pre className="ld-script">{script}</pre>}
      </div>
    </>
  );
}
