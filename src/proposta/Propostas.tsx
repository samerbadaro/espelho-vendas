import { useCallback, useEffect, useMemo, useState } from 'react';
import { ArrowLeft, FileDown, Plus, Send, X } from 'lucide-react';
import { supabase } from '../dados';
import { ir, type Perfil } from '../util';
import { useDialogos } from '../ui';
import { EditorProposta, type EstadoEditor } from './Proposta';
import {
  alcadaPrevista, carregarContexto, doBanco, paraBanco, resumoDe, rotuloProposta, traduzirErro, ROTULO_ALCADA, STATUS_PROPOSTA,
  type Contexto, type PropostaSalva, type StatusProposta,
} from './dadosProposta';
import { gerarCarta, gerarCartaWord, type DadosCarta, type DadosPasta } from './carta';
import {
  aplicarModelo, calcular, distribuir, fmtData, fmtMes, fmtNum, fmtPct, fmtReal, hojeISO, mesmasSeries, pesosPorPreco, precoUnidade, rotuloPeriodicidade, somarSeries, unidadeConjunta,
  type ConfigEmpreendimento, type Resultado, type Serie, type Unidade,
} from './motor';

const CLASSE: Record<StatusProposta, string> = {
  rascunho: 'spr-rascunho', enviada: 'spr-enviada', devolvida: 'spr-devolvida', aprovada: 'spr-aprovada', recusada: 'spr-recusada', cancelada: 'spr-cancelada',
};
const Selo = ({ s }: { s: StatusProposta }) => <span className={`selo ${CLASSE[s]}`}>{rotuloProposta(s)}</span>;

interface PastaResumo { id: string; codigo: string; comprador_nome: string; status: string; imobiliaria_id: string }

// =====================================================================
// Lista de propostas
// =====================================================================
export function ListaPropostas({ perfil }: { perfil: Perfil }) {
  const equipe = perfil.papel === 'admin' || perfil.papel === 'vendas';
  const [lista, setLista] = useState<(PropostaSalva & { unidades: { numero: string } | null; pastas: { comprador_nome: string } | null; imobiliarias: { nome: string } | null })[] | null>(null);
  const [filtro, setFiltro] = useState<StatusProposta | ''>(equipe ? 'enviada' : '');
  const [busca, setBusca] = useState('');
  const [verParametros, setVerParametros] = useState(false);
  const [erro, setErro] = useState('');

  useEffect(() => {
    let q = supabase.from('propostas')
      .select('id, codigo, status, alcada, analisada_por, data_proposta, resumo, criado_por, criado_por_nome, atualizada_em, grupo_id, contraproposta, unidades(numero), pastas(comprador_nome), imobiliarias(nome)')
      .order('atualizada_em', { ascending: false }).limit(300);
    if (filtro) q = q.eq('status', filtro);
    q.then(({ data, error }) => {
      if (error) setErro(traduzirErro(error.message)); else setLista((data ?? []) as never);
    });
  }, [filtro]);

  // busca sem acento e sem diferenciar maiúsculas, em unidade, cliente, imobiliária, corretor e código
  const sem = (t: string) => t.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
  const termo = sem(busca.trim());
  const filtradas = (lista ?? []).filter((p) => !termo || sem([p.codigo, p.unidades?.numero, p.pastas?.comprador_nome, p.imobiliarias?.nome, p.criado_por, p.criado_por_nome].filter(Boolean).join(' ')).includes(termo));
  // proposta conjunta: uma linha só para as propostas do mesmo grupo (e mesma situação)
  const visiveis = useMemo(() => {
    const linhas: { p: (typeof filtradas)[number]; codigos: string[]; numeros: string[]; total: number | null; pv: number | null }[] = [];
    const porGrupo = new Map<string, (typeof linhas)[number]>();
    const membros = new Map<string, (typeof filtradas)>();
    for (const p of filtradas) {
      if (!p.grupo_id) { linhas.push({ p, codigos: [p.codigo], numeros: [p.unidades?.numero ?? ''], total: p.resumo.total ?? null, pv: p.resumo.pv_pct ?? null }); continue; }
      const k = `${p.grupo_id}|${p.status}`;
      if (!porGrupo.has(k)) { const l = { p, codigos: [], numeros: [], total: 0, pv: null }; porGrupo.set(k, l); linhas.push(l); membros.set(k, []); }
      membros.get(k)!.push(p);
    }
    for (const [k, l] of porGrupo) {
      const ms = membros.get(k)!.sort((a, b) => a.codigo.localeCompare(b.codigo));
      l.p = ms[0];
      l.codigos = ms.map((m) => m.codigo);
      l.numeros = ms.map((m) => m.unidades?.numero ?? '');
      l.total = ms.reduce((t, m) => t + (m.resumo.total ?? 0), 0);
      const vt = ms.reduce((t, m) => t + (m.resumo.vpl_tabela ?? 0), 0), vp = ms.reduce((t, m) => t + (m.resumo.vpl_proposta ?? 0), 0);
      l.pv = vt > 0 ? Math.round((vp / vt) * 10000) / 100 : ms[0].resumo.pv_pct_grupo ?? ms[0].resumo.pv_pct ?? null;
    }
    return linhas;
  }, [filtradas]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <section className="secao">
      <div className="secao-topo">
        <div>
          <h2>Propostas</h2>
          <p className="sub">{equipe ? 'Analise as propostas enviadas pelas imobiliárias.' : 'Monte a proposta, confira o PV e envie para análise.'}</p>
        </div>
        <div className="botoes">
          {perfil.papel === 'admin' && <button className="botao" onClick={() => setVerParametros((v) => !v)}>Parâmetros da proposta</button>}
          <button className="botao principal" onClick={() => ir('/painel/propostas/nova')}><Plus size={16} /> Nova proposta</button>
        </div>
      </div>
      {verParametros && perfil.papel === 'admin' && <ParametrosProposta aoFechar={() => setVerParametros(false)} />}
      <div className="filtros">
        <input type="search" placeholder="Buscar por unidade, cliente, imobiliária, corretor ou código" value={busca} onChange={(e) => setBusca(e.target.value)} aria-label="Buscar propostas" />
        <select value={filtro} onChange={(e) => setFiltro(e.target.value as StatusProposta | '')}>
          <option value="">Todas</option>
          {STATUS_PROPOSTA.map((s) => <option key={s.valor} value={s.valor}>{s.rotulo}</option>)}
        </select>
      </div>
      {erro && <p className="erro">{erro}</p>}
      {lista == null ? <p className="vazio">Carregando…</p> : visiveis.length === 0 ? (
        <div className="cartao vazio-grande"><p>{busca.trim() ? `Nenhuma proposta encontrada para “${busca.trim()}”${filtro ? ` com status "${rotuloProposta(filtro)}"` : ''}.` : `Nenhuma proposta ${filtro ? `com status "${rotuloProposta(filtro)}"` : 'ainda'}.`}</p></div>
      ) : (
        <div className="tabela-rolagem">
          <table className="tabela">
            <thead><tr><th>Código</th><th>Unidade</th><th>Comprador</th>{equipe && <th>Imobiliária</th>}<th>Corretor</th><th className="dir">Valor</th><th className="dir">PV</th><th>Status</th><th>Atualizada</th></tr></thead>
            <tbody>
              {visiveis.map(({ p, codigos, numeros, total, pv }) => (
                <tr key={`${p.id}-${codigos.length}`} tabIndex={0} onClick={() => ir(`/painel/propostas/${p.id}`)} onKeyDown={(e) => e.key === 'Enter' && ir(`/painel/propostas/${p.id}`)}>
                  <td className="mono">{codigos.join(', ')}{codigos.length > 1 && <small className="dica nowrap"> conjunta</small>}</td>
                  <td className="mono">{numeros.join(', ')}</td>
                  <td>{p.pastas?.comprador_nome ?? <span className="dica">sem pasta</span>}</td>
                  {equipe && <td>{p.imobiliarias?.nome ?? 'Direto'}</td>}
                  <td>{p.criado_por}</td>
                  <td className="dir mono">{total != null ? fmtReal(total) : '—'}</td>
                  <td className={`dir mono ${(pv ?? 100) < 100 ? 'texto-ruim' : ''}`}>{pv != null ? `${pv.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}%` : '—'}</td>
                  <td><Selo s={p.status} />{p.status === 'devolvida' && p.contraproposta && <small className="dica nowrap"> com contraproposta</small>}{p.status === 'enviada' && p.alcada && <small className="dica nowrap"> {ROTULO_ALCADA[p.alcada]}</small>}
                    {p.status === 'aprovada' && p.analisada_por?.startsWith('Aprovação automática') && <small className="dica nowrap"> automática</small>}</td>
                  <td className="nowrap">{fmtData(p.atualizada_em.slice(0, 10))}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

// =====================================================================
// Nova proposta / proposta salva
// Proposta conjunta: várias unidades numa simulação só; ao salvar, cada unidade
// vira uma proposta, com as parcelas divididas pelo preço de tabela de cada uma.
// =====================================================================
export function PaginaProposta({ id, perfil }: { id: string | 'nova'; perfil: Perfil }) {
  const { avisar, confirmar } = useDialogos();
  const equipe = perfil.papel === 'admin' || perfil.papel === 'vendas';
  const hoje = hojeISO();
  const [ctx, setCtx] = useState<Contexto | null>(null);
  const [proposta, setProposta] = useState<PropostaSalva | null>(null);
  /** Propostas do grupo (sem as canceladas), quando a proposta é conjunta. */
  const [membros, setMembros] = useState<PropostaSalva[]>([]);
  /** null = visão conjunta; id = uma proposta do grupo, sozinha */
  const [vista, setVista] = useState<string | null>(null);
  const [pastas, setPastas] = useState<PastaResumo[]>([]);
  const [historico, setHistorico] = useState<{ acao: string; usuario_email: string | null; criado_em: string; detalhes: { motivo?: string } | null }[]>([]);
  const [erro, setErro] = useState('');
  const [unidadeIds, setUnidadeIds] = useState<string[]>([]);
  const [pastaId, setPastaId] = useState('');
  const [obs, setObs] = useState('');
  const [estado, setEstado] = useState<EstadoEditor | null>(null);
  const [salvando, setSalvando] = useState(false);
  const [analise, setAnalise] = useState<null | 'devolvida' | 'recusada' | 'cancelada' | 'cancelar-unidade'>(null);
  const [motivo, setMotivo] = useState('');
  const [chaveEditor, setChaveEditor] = useState(0);
  /** a equipe está montando uma contraproposta na grade */
  const [modoContra, setModoContra] = useState(false);
  /** mostrar a proposta original do corretor (em vez da contraproposta) */
  const [verOriginal, setVerOriginal] = useState(false);

  const carregar = useCallback(async () => {
    const c = await carregarContexto();
    if ('erro' in c) { setErro(c.erro); return; }
    setCtx(c);
    const { data: ps } = await supabase.from('pastas').select('id, codigo, comprador_nome, status, imobiliaria_id').order('criada_em', { ascending: false });
    setPastas((ps ?? []) as PastaResumo[]);
    if (id === 'nova') {
      const q = new URLSearchParams(window.location.search);
      const un = q.get('unidade');
      setUnidadeIds([c.unidades.find((u) => u.numero === un || u.id === un)?.id ?? c.unidades.find((u) => u.status === 'disponivel')?.id ?? c.unidades[0].id]);
      setPastaId(q.get('pasta') ?? '');
      return;
    }
    const { data, error } = await supabase.from('propostas').select('*').eq('id', id).maybeSingle();
    if (error || !data) { setErro(error ? traduzirErro(error.message) : 'Proposta não encontrada.'); return; }
    const p = data as PropostaSalva;
    let grupo: PropostaSalva[] = [];
    if (p.grupo_id) {
      const { data: gs } = await supabase.from('propostas').select('*').eq('grupo_id', p.grupo_id).neq('status', 'cancelada').order('codigo');
      grupo = (gs ?? []) as PropostaSalva[];
    }
    setProposta(p); setMembros(grupo); setPastaId(p.pasta_id ?? ''); setObs(p.observacoes ?? ''); setModoContra(false); setVerOriginal(false);
    const conjunta = grupo.length > 0 && p.status !== 'cancelada';
    setUnidadeIds(conjunta ? grupo.map((m) => m.unidade_id) : [p.unidade_id]);
    // a proposta cancelada de um grupo abre sozinha; o resto abre na visão conjunta (que também serve para uma unidade só)
    setVista(p.grupo_id && !conjunta ? p.id : null);
    setChaveEditor((k) => k + 1);
    const { data: h } = await supabase.from('historico_propostas').select('acao, usuario_email, criado_em, detalhes').eq('proposta_id', id).order('criado_em', { ascending: false });
    setHistorico((h ?? []) as never);
  }, [id]);
  useEffect(() => { carregar(); }, [carregar]);

  const grupoId = proposta?.grupo_id ?? null;
  const conjunta = vista === null; // simulação/visão de todas as unidades juntas
  const propostaVista = vista ? (membros.find((m) => m.id === vista) ?? proposta) : proposta;
  const unidadesSel = useMemo(() => (ctx ? unidadeIds.map((x) => ctx.unidades.find((u) => u.id === x)).filter((u): u is NonNullable<typeof u> => !!u) : []), [ctx, unidadeIds]);
  const unidadeVista = useMemo(() => (ctx && propostaVista && vista ? ctx.unidades.find((u) => u.id === propostaVista.unidade_id) : undefined), [ctx, propostaVista, vista]);

  // o que o editor mostra: uma unidade, ou a unidade conjunta (soma das escolhidas)
  const alvo = useMemo(() => {
    if (!ctx) return null;
    if (!conjunta && unidadeVista) return { cfg: ctx.cfg, unidade: unidadeVista };
    if (unidadesSel.length > 1) return unidadeConjunta(ctx.cfg, unidadesSel);
    return unidadesSel[0] ? { cfg: ctx.cfg, unidade: unidadesSel[0] } : null;
  }, [ctx, conjunta, unidadeVista, unidadesSel]);

  const statusAtual = propostaVista?.status;
  const editavel = modoContra || (!verOriginal && (!proposta || ((statusAtual === 'rascunho' || statusAtual === 'devolvida') && (!grupoId || conjunta))));
  // contraproposta: as propostas da visão (todas do grupo, na visão conjunta)
  const daVisao = proposta ? (conjunta ? (membros.length ? membros : [proposta]) : propostaVista ? [propostaVista] : []) : [];
  const temContra = daVisao.length > 0 && daVisao.every((m) => m.contraproposta && m.proposta_original);
  const contra = temContra ? daVisao[0].contraproposta! : null;
  const seriesOriginal = useMemo(() => (temContra ? (daVisao.length > 1 ? somarSeries(daVisao.map((m) => doBanco(m.proposta_original!.series))) : doBanco(daVisao[0].proposta_original!.series)) : null), [temContra, daVisao.map((m) => m.id + m.versao).join()]); // eslint-disable-line react-hooks/exhaustive-deps
  const seriesContra = useMemo(() => (temContra ? (daVisao.length > 1 ? somarSeries(daVisao.map((m) => doBanco(m.contraproposta!.series))) : doBanco(daVisao[0].contraproposta!.series)) : null), [temContra, daVisao.map((m) => m.id + m.versao).join()]); // eslint-disable-line react-hooks/exhaustive-deps
  const ehGrupo = unidadesSel.length > 1 || (!!grupoId && conjunta);

  // séries iniciais: as salvas (somadas, na visão conjunta) quando as unidades são as mesmas; senão, o modelo da tabela
  const seriesIniciais = useMemo(() => {
    if (!proposta) return undefined;
    if (verOriginal && seriesOriginal) return seriesOriginal;
    if (!conjunta) return propostaVista ? doBanco(propostaVista.series) : undefined;
    const salvas = membros.length ? membros : [proposta];
    const mesmas = salvas.length === unidadeIds.length && salvas.every((m) => unidadeIds.includes(m.unidade_id));
    if (!mesmas) return undefined;
    return salvas.length > 1 ? somarSeries(salvas.map((m) => doBanco(m.series))) : doBanco(salvas[0].series);
  }, [proposta, propostaVista, membros, unidadeIds, conjunta, verOriginal, seriesOriginal]);

  if (erro) return <section className="secao"><p className="erro">{erro}</p><button className="botao" onClick={() => ir('/painel/propostas')}>Voltar</button></section>;
  if (!ctx || !alvo) return <section className="secao"><p className="vazio">Carregando…</p></section>;

  const pasta = pastas.find((p) => p.id === pastaId);
  const temErro = estado?.resultado.avisos.some((a) => a.nivel === 'erro') ?? true;
  const temPermuta = estado?.series.some((s) => s.periodicidade === 'Permuta') ?? false;
  const pvPct = estado ? Math.round((estado.resultado.proposta.vpl / estado.resultado.tabela.vpl) * 10000) / 100 : 0;
  const alcada = alcadaPrevista(ctx.comercial, pvPct, (estado?.resultado.comissao.naoCoberta ?? 1) <= 0.005);
  const faltaPermuta = temPermuta && !obs.trim();
  const pesos = unidadesSel.length > 1 ? pesosPorPreco(ctx.cfg, unidadesSel) : [1];
  const codigos = membros.length > 1 ? membros.map((m) => m.codigo).join(' + ') : proposta?.codigo ?? '';

  const calcularUnidade = (u: (typeof unidadesSel)[number], series: Serie[]) => calcular(ctx.cfg, u, series, {
    dataMinima: proposta?.data_proposta ?? hoje, comissaoPercentual: estado!.comissaoPct, parteDoSinal: estado!.parteSinal,
    coordenacao: estado!.coordenacaoPct, coordenacaoParcelas: estado!.coordenacaoParcelas, diasVencimento: ctx.comercial.dias_vencimento, observacoes: obs,
  });

  /** Grava a proposta (ou as propostas do grupo). Devolve o id para abrir e o grupo, se houver. */
  const salvar = async (): Promise<{ id: string; grupo: string | null } | null> => {
    if (!estado) return null;
    setSalvando(true);
    try {
      const base = {
        pasta_id: pastaId || null, observacoes: obs.trim() || null,
        comissao_pct: estado.comissaoPct, parte_sinal: estado.parteSinal,
        coordenacao_pct: estado.coordenacaoPct, coordenacao_parcelas: estado.coordenacaoParcelas,
      };
      if (!ehGrupo) {
        const campos = { ...base, unidade_id: unidadesSel[0].id, series: paraBanco(estado.series), resumo: resumoDe(estado.resultado) };
        const r = proposta
          ? await supabase.from('propostas').update(campos).eq('id', proposta.id).select('id').single()
          : await supabase.from('propostas').insert(campos).select('id').single();
        if (r.error) { avisar(traduzirErro(r.error.message), 'erro'); return null; }
        return { id: (r.data as { id: string }).id, grupo: null };
      }
      // grupo: divide as séries pelo preço de tabela de cada unidade
      const grupo = grupoId ?? crypto.randomUUID();
      const partes = distribuir(estado.series, pesos);
      // propostas que já existem: primeiro as da mesma unidade; as que sobrarem trocam de unidade; o resto é retirado
      const existentes = membros.length ? [...membros] : proposta ? [proposta] : [];
      const usadas = new Set<string>();
      const destino = unidadesSel.map((u) => {
        const m = existentes.find((x) => x.unidade_id === u.id && !usadas.has(x.id));
        if (m) usadas.add(m.id);
        return m ?? null;
      });
      for (let i = 0; i < destino.length; i++) {
        if (destino[i]) continue;
        const livre = existentes.find((x) => !usadas.has(x.id));
        if (livre) { usadas.add(livre.id); destino[i] = livre; }
      }
      let primeiro: string | null = null;
      for (let i = 0; i < unidadesSel.length; i++) {
        const u = unidadesSel[i];
        const r = calcularUnidade(u, partes[i]);
        const campos = { ...base, grupo_id: grupo, unidade_id: u.id, series: paraBanco(partes[i]), resumo: resumoDe(r) };
        const d = destino[i];
        const res = d
          ? await supabase.from('propostas').update(campos).eq('id', d.id).select('id').single()
          : await supabase.from('propostas').insert(campos).select('id').single();
        if (res.error) { avisar(`Unidade ${u.numero}: ${traduzirErro(res.error.message)}`, 'erro'); return null; }
        primeiro ??= (res.data as { id: string }).id;
      }
      for (const x of existentes.filter((x) => !usadas.has(x.id))) {
        const { error } = await supabase.rpc('retirar_do_grupo', { p_id: x.id });
        if (error) { avisar(traduzirErro(error.message), 'erro'); return null; }
      }
      const fica = proposta && usadas.has(proposta.id) ? proposta.id : primeiro!;
      return { id: fica, grupo };
    } finally { setSalvando(false); }
  };

  const aoSalvar = async () => {
    const r = await salvar();
    if (!r) return;
    avisar(ehGrupo ? `Proposta conjunta salva: ${unidadesSel.length} propostas, uma por unidade.` : 'Proposta salva.');
    if (!proposta || r.id !== proposta.id) ir(`/painel/propostas/${r.id}`); else carregar();
  };

  const enviar = async () => {
    if (faltaPermuta) { avisar('Descreva a permuta nas observações antes de enviar.', 'erro'); return; }
    if (temErro) { avisar('Corrija os erros da grade (vencimentos, parcelas) antes de enviar.', 'erro'); return; }
    if (!pastaId) { avisar('Vincule a pasta do comprador antes de enviar.', 'erro'); return; }
    const deQuem = ehGrupo ? `as ${unidadesSel.length} propostas serão aprovadas juntas` : 'a proposta será aprovada na hora';
    const textoAlcada = alcada === 'automatica' ? `PV dentro da tabela e sinal cobrindo a comissão: ${deQuem} e ${ehGrupo ? 'as unidades irão' : 'a unidade irá'} para "Proposta recebida".`
      : `PV de ${pvPct.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}%${ehGrupo ? ' no conjunto' : ''}: a aprovação fica com ${alcada === 'vendas' ? 'a Sec. Vendas' : 'o administrador'}.`;
    if (!(await confirmar({ titulo: ehGrupo ? 'Enviar a proposta conjunta?' : 'Enviar proposta?', texto: `${textoAlcada} Depois de enviada, ela só volta a ser editada se for devolvida para ajuste.`, confirmar: 'Enviar proposta' }))) return;
    const s = await salvar();
    if (!s) return;
    if (s.grupo) {
      const { data, error } = await supabase.rpc('enviar_grupo', { p_grupo: s.grupo });
      if (error) { avisar(traduzirErro(error.message), 'erro'); ir(`/painel/propostas/${s.id}`); carregar(); return; }
      const lista = (data ?? []) as PropostaSalva[];
      const e = lista.find((x) => x.status !== 'cancelada');
      avisar(e?.status === 'aprovada' ? 'Proposta conjunta aprovada automaticamente. As unidades foram para "Proposta recebida".'
        : `Proposta conjunta enviada. Aprovação: ${e?.alcada ? ROTULO_ALCADA[e.alcada] : 'equipe'}.`);
    } else {
      const { data: enviada, error } = await supabase.rpc('enviar_proposta', { p_id: s.id });
      if (error) { avisar(traduzirErro(error.message), 'erro'); if (!proposta) ir(`/painel/propostas/${s.id}`); return; }
      const e = enviada as PropostaSalva | null;
      avisar(e?.status === 'aprovada' ? 'Proposta aprovada automaticamente. A unidade foi para "Proposta recebida".'
        : `Proposta enviada. Aprovação: ${e?.alcada ? ROTULO_ALCADA[e.alcada] : 'equipe'}.`);
    }
    if (!proposta || s.id !== proposta.id) ir(`/painel/propostas/${s.id}`); else carregar();
  };

  const analisar = async (decisao: 'aprovada' | 'devolvida' | 'recusada' | 'cancelada' | 'cancelar-unidade') => {
    if (!proposta) return;
    const numeros = unidadesSel.map((u) => u.numero).join(', ');
    if (decisao === 'aprovada' && !(await confirmar({ titulo: grupoId ? 'Aprovar a proposta conjunta?' : 'Aprovar proposta?', texto: grupoId ? `As unidades ${numeros} vão juntas para "Proposta recebida" no espelho, cada uma com o valor da sua proposta.` : `A unidade ${alvo.unidade.numero} vai para "Proposta recebida" no espelho, com o valor e o PV desta proposta.`, confirmar: 'Aprovar' }))) return;
    if (decisao !== 'aprovada' && !motivo.trim()) { avisar('Informe o motivo.', 'erro'); return; }
    setSalvando(true);
    const { error } = grupoId && decisao !== 'cancelar-unidade'
      ? await supabase.rpc('analisar_grupo', { p_grupo: grupoId, p_decisao: decisao, p_motivo: motivo.trim() || null })
      : await supabase.rpc('analisar_proposta', { p_id: decisao === 'cancelar-unidade' ? propostaVista!.id : proposta.id, p_decisao: decisao === 'cancelar-unidade' ? 'cancelada' : decisao, p_motivo: motivo.trim() || null });
    setSalvando(false);
    if (error) { avisar(traduzirErro(error.message), 'erro'); return; }
    setAnalise(null); setMotivo('');
    avisar(decisao === 'aprovada' ? (grupoId ? 'Proposta conjunta aprovada. O espelho foi atualizado.' : 'Proposta aprovada. O espelho foi atualizado.') : 'Decisão registrada.');
    carregar();
  };

  /** Equipe: devolve com a grade alterada (contraproposta). Sem alteração na grade, é uma devolução para ajuste comum. */
  const devolverComContra = async () => {
    if (!proposta || !estado) return;
    if (!motivo.trim()) { avisar('Explique a contraproposta (ou o que ajustar) no motivo.', 'erro'); return; }
    const semMudanca = mesmasSeries(estado.series, seriesIniciais ?? []) && estado.comissaoPct === Number(proposta.comissao_pct ?? estado.comissaoPct)
      && estado.coordenacaoParcelas === Number(proposta.coordenacao_parcelas ?? estado.coordenacaoParcelas);
    if (semMudanca) {
      if (!(await confirmar({ titulo: 'Devolver sem contraproposta?', texto: 'A grade não foi alterada: a proposta volta para o corretor ajustar, com o motivo informado.', confirmar: 'Devolver' }))) return;
      await analisar('devolvida');
      setModoContra(false);
      return;
    }
    if (temErro) { avisar('Corrija os erros da grade (vencimentos, parcelas) antes de devolver.', 'erro'); return; }
    if (!(await confirmar({ titulo: 'Devolver com contraproposta?', texto: `A proposta volta para o corretor com a sua contraproposta (PV de ${pvPct.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}%). Ele verá a original e a sua. Se o cliente aceitar sem alterar, a proposta é aprovada na hora.`, confirmar: 'Devolver com contraproposta' }))) return;
    const dados = (series: Serie[], r: Resultado) => ({
      series: paraBanco(series), resumo: resumoDe(r), comissao_pct: estado.comissaoPct, parte_sinal: estado.parteSinal,
      coordenacao_pct: estado.coordenacaoPct, coordenacao_parcelas: estado.coordenacaoParcelas,
    });
    setSalvando(true);
    let error: { message: string } | null = null;
    if (grupoId) {
      const partes = distribuir(estado.series, pesos);
      const itens = membros.map((m) => {
        const i = unidadesSel.findIndex((u) => u.id === m.unidade_id);
        return { id: m.id, dados: dados(partes[i], calcularUnidade(unidadesSel[i], partes[i])) };
      });
      ({ error } = await supabase.rpc('contrapropor_grupo', { p_grupo: grupoId, p_itens: itens, p_motivo: motivo.trim() }));
    } else {
      ({ error } = await supabase.rpc('contrapropor', { p_id: proposta.id, p_dados: dados(estado.series, estado.resultado), p_motivo: motivo.trim() }));
    }
    setSalvando(false);
    if (error) { avisar(traduzirErro(error.message), 'erro'); return; }
    setMotivo(''); setModoContra(false);
    avisar('Contraproposta enviada ao corretor.');
    carregar();
  };

  /** Corretor: o cliente aceitou a contraproposta sem alterar — aprova na hora. */
  const aceitarContra = async () => {
    if (!proposta) return;
    if (!pastaId) { avisar('Vincule a pasta do comprador antes de aceitar.', 'erro'); return; }
    if (!(await confirmar({ titulo: 'Aceitar a contraproposta?', texto: `Confirme que o cliente aceitou a contraproposta. A proposta${grupoId ? ' conjunta' : ''} será aprovada na hora e ${grupoId ? 'as unidades irão' : 'a unidade irá'} para "Proposta recebida".`, confirmar: 'Aceitar contraproposta' }))) return;
    if (pastaId !== (proposta.pasta_id ?? '') || obs.trim() !== (proposta.observacoes ?? '').trim()) { if (!(await salvar())) return; }
    setSalvando(true);
    const { error } = await supabase.rpc('aceitar_contraproposta', { p_id: proposta.id });
    setSalvando(false);
    if (error) { avisar(traduzirErro(error.message), 'erro'); return; }
    avisar('Contraproposta aceita. A proposta foi aprovada e o espelho foi atualizado.');
    carregar();
  };

  /** Resumo da proposta (carta simples, sem campos em branco nem assinaturas), em PDF ou Word. */
  const carta = async (formato: 'pdf' | 'docx' = 'pdf') => {
    if (!estado) return;
    let dadosPasta: DadosPasta | null = null;
    if (pastaId) {
      const { data } = await supabase.from('pastas').select('codigo, comprador_nome, comprador_cpf, comprador_nascimento, comprador_telefone, comprador_email, comprador_profissao, estado_civil, conjuge_nome, conjuge_cpf, conjuge_nascimento, conjuge_telefone, conjuge_email, conjuge_profissao').eq('id', pastaId).maybeSingle();
      dadosPasta = data as DadosPasta | null;
    }
    const imobId = proposta?.imobiliaria_id ?? pasta?.imobiliaria_id;
    const { data: im } = imobId ? await supabase.from('imobiliarias').select('nome').eq('id', imobId).maybeSingle() : { data: null };
    const juntas = conjunta && unidadesSel.length > 1;
    const uCarta = juntas
      ? { numero: unidadesSel.map((u) => u.numero).join(', '), area: unidadesSel.reduce((t, u) => t + u.area, 0), andar: null }
      : { numero: alvo.unidade.numero, area: alvo.unidade.area, andar: (unidadeVista ?? unidadesSel[0])?.andar ?? null };
    try {
      const dados: DadosCarta = {
        codigo: (juntas ? codigos : propostaVista?.codigo) || 'SIMULAÇÃO', dataProposta: proposta?.data_proposta ?? hoje, empreendimento: ctx.nome, comercial: ctx.comercial,
        unidade: uCarta, pasta: dadosPasta,
        logoUrl: ctx.logoUrl, corDestaque: ctx.corDestaque,
        imobiliaria: (im as { nome: string } | null)?.nome ?? '', corretor: proposta ? proposta.criado_por_nome ?? proposta.criado_por ?? '' : perfil.nome || perfil.email,
        series: estado.series, resultado: estado.resultado, observacoes: obs,
      };
      await (formato === 'docx' ? gerarCartaWord : gerarCarta)(dados, { simples: true });
    } catch { avisar('Não foi possível gerar a carta proposta.', 'erro'); }
  };

  const recomecar = () => setChaveEditor((k) => k + 1);
  const trocarUnidade = (i: number, novo: string) => { setUnidadeIds((l) => l.map((x, k) => (k === i ? novo : x))); recomecar(); };
  const adicionarUnidade = () => {
    const livre = ctx.unidades.find((u) => u.status === 'disponivel' && !unidadeIds.includes(u.id)) ?? ctx.unidades.find((u) => !unidadeIds.includes(u.id));
    if (livre) { setUnidadeIds((l) => [...l, livre.id]); recomecar(); }
  };
  const removerUnidade = (i: number) => { setUnidadeIds((l) => l.filter((_, k) => k !== i)); recomecar(); };
  const statusEspelho = (s: string) => ({ disponivel: 'disponível', reservada: 'reservada', proposta: 'proposta recebida', contrato: 'contrato em assinatura', vendida: 'vendida', bloqueada: 'bloqueada', permutante: 'permutante' } as Record<string, string>)[s] ?? s;
  const precoTotal = unidadesSel.reduce((t, u) => t + precoUnidade(ctx.cfg, u), 0);
  const titulo = !proposta ? (unidadesSel.length > 1 ? 'Nova proposta conjunta' : 'Nova proposta')
    : conjunta && membros.length > 1 ? `Proposta conjunta ${codigos}` : `Proposta ${propostaVista?.codigo ?? proposta.codigo}`;
  const unidadesComAlerta = (conjunta ? unidadesSel : unidadeVista ? [unidadeVista] : []).filter((u) => u.status !== 'disponivel');

  return (
    <section className="secao prop-pagina">
      <div className="secao-topo">
        <div>
          <button className="link-voltar" onClick={() => ir('/painel/propostas')}><ArrowLeft size={15} /> Propostas</button>
          <h2>{titulo} {propostaVista && <Selo s={propostaVista.status} />}</h2>
          <p className="sub">
            {proposta ? `Criada em ${fmtData(proposta.data_proposta)} por ${proposta.criado_por_nome ?? proposta.criado_por ?? '—'}` : `Data da proposta: ${fmtData(hoje)}`}
            {propostaVista?.analisada_por && ` · analisada por ${propostaVista.analisada_por} em ${fmtData(propostaVista.analisada_em!.slice(0, 10))}`}
          </p>
        </div>
        <div className="botoes-linha">
          {editavel && estado && <span className={`chip-alcada a-${alcada}`} title="Quem aprova esta proposta, pelo PV e pela comissão">Aprovação: {ROTULO_ALCADA[alcada]}</span>}
          {!editavel && propostaVista?.alcada && propostaVista.status === 'enviada' && <span className={`chip-alcada a-${propostaVista.alcada}`}>Aguardando: {ROTULO_ALCADA[propostaVista.alcada]}</span>}
          <button className="botao" onClick={() => carta('pdf')} disabled={!estado} title="Resumo da proposta em PDF, sem campos em branco e sem assinaturas"><FileDown size={16} /> Resumo da proposta</button>
          <button className="botao" onClick={() => carta('docx')} disabled={!estado} title="O mesmo resumo em Word"><FileDown size={16} /> Word</button>
          {editavel && !modoContra && <button className="botao" onClick={aoSalvar} disabled={salvando || !estado}>Salvar rascunho</button>}
          {editavel && !modoContra && <button className="botao principal" onClick={enviar} disabled={salvando || !estado}><Send size={16} /> Enviar para análise</button>}
        </div>
      </div>

      {membros.length > 1 && proposta?.status !== 'cancelada' && (
        <div className="prop-vistas" role="tablist" aria-label="Visão da proposta conjunta">
          <button role="tab" aria-selected={conjunta} className={conjunta ? 'ativa' : ''} onClick={() => { setVista(null); recomecar(); }}>Conjunta ({membros.length} unidades)</button>
          {membros.map((m) => (
            <button key={m.id} role="tab" aria-selected={vista === m.id} className={vista === m.id ? 'ativa' : ''} onClick={() => { setVista(m.id); recomecar(); }}>
              {m.codigo} · {ctx.unidades.find((u) => u.id === m.unidade_id)?.numero ?? '—'}
            </button>
          ))}
        </div>
      )}

      {propostaVista?.motivo_analise && !(temContra && propostaVista.status === 'devolvida') && (propostaVista.status === 'devolvida' || propostaVista.status === 'recusada' || propostaVista.status === 'cancelada') && (
        <div className={`cartao aviso-prop ${propostaVista.status}`}><strong>{rotuloProposta(propostaVista.status)}:</strong> {propostaVista.motivo_analise}</div>
      )}

      {equipe && proposta && propostaVista?.status === 'enviada' && (conjunta || !grupoId) && !modoContra && (
        <div className="cartao analise-prop">
          <strong>{grupoId ? 'Análise da proposta conjunta (vale para todas as unidades)' : 'Análise da equipe'}</strong>
          {propostaVista.alcada === 'admin' && perfil.papel !== 'admin' && <span className="dica">PV de {(propostaVista.resumo.pv_pct_grupo ?? propostaVista.resumo.pv_pct)?.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}%: abaixo da alçada da Sec. Vendas, só o administrador aprova.</span>}
          <div className="botoes-linha">
            {(propostaVista.alcada !== 'admin' || perfil.papel === 'admin') && <button className="botao ok" onClick={() => analisar('aprovada')} disabled={salvando}>Aprovar</button>}
            <button className="botao" onClick={() => { setModoContra(true); setVerOriginal(false); setAnalise(null); }} title="Altere a grade e devolva ao corretor com a sua contraproposta (ou só com o motivo, sem alterar)">Devolver com contraproposta</button>
            <button className="botao" onClick={() => setAnalise('recusada')}>Recusar</button>
          </div>
        </div>
      )}
      {modoContra && (
        <div className="cartao contra-prop">
          <strong>Contraproposta</strong>
          <p className="dica">Altere a grade abaixo (séries, valores, vencimentos e, se precisar, a comissão). O corretor verá a proposta original e a sua contraproposta lado a lado. Se o cliente aceitar sem alterar, a proposta é aprovada na hora. Sem alterar a grade, a proposta só volta para ajuste.</p>
          <label className="campo-motivo">Motivo (o corretor verá)
            <textarea rows={2} value={motivo} onChange={(e) => setMotivo(e.target.value)} placeholder="Ex.: sinal maior para manter o PV; financiamento reduzido." autoFocus />
          </label>
          <div className="botoes-linha">
            <button className="botao" onClick={() => { setModoContra(false); setMotivo(''); recomecar(); }}>Desistir</button>
            <button className="botao principal" onClick={devolverComContra} disabled={salvando || !estado}>Devolver com contraproposta</button>
          </div>
        </div>
      )}
      {temContra && contra && !modoContra && (
        <div className="cartao contra-prop">
          <div className="contra-topo">
            <div>
              <strong>Contraproposta</strong> de {contra.por ?? 'equipe'} em {new Date(contra.em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}
              {contra.motivo && <p className="dica">{contra.motivo}</p>}
            </div>
            <div className="prop-vistas pequenas" role="tablist" aria-label="Comparar com a proposta original">
              <button role="tab" aria-selected={!verOriginal} className={!verOriginal ? 'ativa' : ''} onClick={() => { setVerOriginal(false); recomecar(); }}>Contraproposta</button>
              <button role="tab" aria-selected={verOriginal} className={verOriginal ? 'ativa' : ''} onClick={() => { setVerOriginal(true); recomecar(); }}>Proposta original</button>
            </div>
          </div>
          {seriesOriginal && seriesContra && (
            <OQueMudou cfg={alvo.cfg} unidade={alvo.unidade} original={seriesOriginal} contra={seriesContra}
              opcoes={{ dataMinima: proposta?.data_proposta ?? hoje, diasVencimento: ctx.comercial.dias_vencimento, observacoes: obs,
                comissaoOriginal: Number(daVisao[0].proposta_original!.comissao_pct ?? ctx.cfg.comissao.percentual), comissaoContra: Number(daVisao[0].comissao_pct ?? ctx.cfg.comissao.percentual),
                parteSinal: Number(daVisao[0].parte_sinal ?? ctx.cfg.comissao.parteDoSinal), coordenacao: Number(daVisao[0].coordenacao_pct ?? ctx.cfg.comissao.coordenacao ?? 0), coordenacaoParcelas: Number(daVisao[0].coordenacao_parcelas ?? 2) }} />
          )}
          {propostaVista?.status === 'devolvida' && (conjunta || !grupoId) && (
            <div className="botoes-linha">
              <button className="botao ok" onClick={aceitarContra} disabled={salvando || verOriginal || !estado || !mesmasSeries(estado.series, seriesContra ?? [])}
                title={verOriginal ? 'Volte para a aba “Contraproposta”' : 'O cliente aceitou a contraproposta sem alterar'}>Aceitar contraproposta</button>
              <span className="dica">{estado && seriesContra && !verOriginal && !mesmasSeries(estado.series, seriesContra) ? 'Você alterou a grade: envie para análise de novo.' : 'Ou altere a grade e envie para análise de novo.'}</span>
            </div>
          )}
        </div>
      )}
      {equipe && grupoId && !conjunta && propostaVista?.status === 'enviada' && (
        <p className="dica">Esta unidade faz parte de uma proposta conjunta: aprove, devolva ou recuse na aba “Conjunta”.</p>
      )}
      {equipe && proposta && propostaVista && propostaVista.status !== 'cancelada' && propostaVista.status !== 'enviada' && (
        <div className="botoes-linha direita">
          {grupoId && !conjunta
            ? <button className="botao pequeno" onClick={() => setAnalise('cancelar-unidade')}>Cancelar só esta unidade</button>
            : <button className="botao pequeno" onClick={() => setAnalise('cancelada')}>{grupoId ? 'Cancelar a proposta conjunta' : 'Cancelar proposta'}</button>}
        </div>
      )}
      {analise && (
        <div className="cartao">
          <label className="campo-motivo">Motivo ({analise === 'devolvida' ? 'o corretor verá o que ajustar' : analise === 'recusada' ? 'recusa' : 'cancelamento'})
            <textarea rows={2} value={motivo} onChange={(e) => setMotivo(e.target.value)} autoFocus />
          </label>
          <div className="botoes-linha">
            <button className="botao" onClick={() => { setAnalise(null); setMotivo(''); }}>Voltar</button>
            <button className={`botao ${analise === 'devolvida' ? 'principal' : 'perigo'}`} onClick={() => analisar(analise)} disabled={salvando}>
              {analise === 'devolvida' ? 'Devolver' : analise === 'recusada' ? 'Recusar' : analise === 'cancelar-unidade' ? 'Cancelar esta unidade' : 'Cancelar proposta'}
            </button>
          </div>
        </div>
      )}

      <div className="prop-bloco prop-unidade">
        {(conjunta ? unidadeIds : [propostaVista?.unidade_id ?? '']).map((uid, i) => (
          <label key={i}>
            <span>{unidadeIds.length > 1 && conjunta ? `Unidade ${i + 1}` : 'Unidade'}</span>
            <span className="prop-unidade-escolha">
              <select value={uid} onChange={(e) => trocarUnidade(i, e.target.value)} disabled={!editavel || !conjunta || modoContra}>
                {ctx.unidades.filter((u) => u.id === uid || !unidadeIds.includes(u.id)).map((u) => <option key={u.id} value={u.id}>{u.numero}{u.status !== 'disponivel' ? ` (${statusEspelho(u.status)})` : ''}</option>)}
              </select>
              {editavel && !modoContra && conjunta && unidadeIds.length > 1 && (
                <button type="button" className="botao-icone" onClick={() => removerUnidade(i)} aria-label={`Tirar a unidade ${ctx.unidades.find((u) => u.id === uid)?.numero ?? ''}`} title="Tirar esta unidade"><X size={14} /></button>
              )}
            </span>
          </label>
        ))}
        {editavel && !modoContra && conjunta && (
          <div className="prop-mais-unidade"><button type="button" className="botao pequeno" onClick={adicionarUnidade}><Plus size={14} /> Adicionar unidade</button></div>
        )}
        <div><span>Área{conjunta && unidadesSel.length > 1 ? ' (soma)' : ''}</span><strong>{alvo.unidade.area.toLocaleString('pt-BR', { minimumFractionDigits: 2 })} m²</strong></div>
        <div><span>Tabela</span><strong>{conjunta && unidadesSel.length > 1 ? [...new Set(unidadesSel.map((u) => u.tabela))].join(', ') : alvo.unidade.tabela}</strong></div>
        <div><span>Preço de tabela{conjunta && unidadesSel.length > 1 ? ' (soma)' : ''}</span><strong>{fmtReal(conjunta ? precoTotal : precoUnidade(alvo.cfg, alvo.unidade))}</strong></div>
        <div><span>Entrega</span><strong>{fmtData(ctx.comercial.mes_entrega).slice(3)}</strong></div>
        <label className="prop-pasta">
          <span>Pasta do comprador</span>
          <select value={pastaId} onChange={(e) => setPastaId(e.target.value)} disabled={!editavel || modoContra}>
            <option value="">— vincular depois —</option>
            {pastas.map((p) => <option key={p.id} value={p.id}>{p.codigo} · {p.comprador_nome}{p.status !== 'aprovada' ? ' (documentação não aprovada)' : ''}</option>)}
          </select>
        </label>
      </div>
      {conjunta && unidadesSel.length > 1 && (
        <p className="dica prop-divisao">
          {editavel && !modoContra ? 'Simulação conjunta: monte o fluxo sobre o total. Ao salvar, cada unidade vira uma proposta, com as parcelas divididas pelo preço de tabela: ' : modoContra ? 'Contraproposta conjunta: monte o fluxo sobre o total; ao devolver, ele é dividido entre as unidades pelo preço de tabela: ' : 'Divisão entre as unidades, pelo preço de tabela: '}
          {unidadesSel.map((u, i) => `${u.numero} (${fmtPct(pesos[i], 2)})`).join(', ')}.
        </p>
      )}
      {unidadesComAlerta.length > 0 && editavel && (
        <p className="alerta">{unidadesComAlerta.map((u) => `A unidade ${u.numero} está ${statusEspelho(u.status)} no espelho.`).join(' ')}</p>
      )}

      <EditorProposta
        key={`${unidadeIds.join(',')}-${vista ?? 'conjunta'}-${chaveEditor}`}
        cfg={alvo.cfg} unidade={alvo.unidade} hoje={hoje}
        dataMinima={proposta?.data_proposta ?? hoje}
        dias={ctx.comercial.dias_vencimento}
        seriesIniciais={seriesIniciais ?? aplicarModelo(alvo.cfg, alvo.unidade, 'tabela', { dia: 10, hoje })}
        comissaoInicial={proposta?.comissao_pct} parteInicial={proposta?.parte_sinal}
        coordParcelasInicial={proposta?.coordenacao_parcelas ?? undefined} nomeCoordenacao={ctx.comercial.coordenacao_comercial} coordPctInicial={proposta?.coordenacao_pct ?? undefined}
        somenteLeitura={!editavel} podeEditarComissao={equipe}
        aoMudar={setEstado}
        observacoes={obs}
      />

      <div className="prop-bloco">
        <label className={`campo-motivo${faltaPermuta ? ' obrigatorio' : ''}`}>
          {faltaPermuta ? 'Observações — obrigatório: descreva a permuta (imóvel, carro, serviços, valor de avaliação...)' : 'Observações da proposta (saem na carta)'}
          <textarea rows={faltaPermuta ? 3 : 2} value={obs} onChange={(e) => setObs(e.target.value)} disabled={!editavel || modoContra}
            placeholder={temPermuta ? 'Ex.: permuta de veículo Toyota Corolla 2022, placa ABC1D23, avaliado em R$ 110.000,00.' : undefined} />
        </label>
      </div>

      {historico.length > 0 && (
        <div className="prop-bloco">
          <h2>Histórico</h2>
          <ul className="lista-simples">
            {historico.map((h, i) => (
              <li key={i}><span>{h.acao.replace('Status: ', 'Status: ').replace(/: (\w+)$/, (_, s) => `: ${rotuloProposta(s as StatusProposta)}`)}{h.detalhes?.motivo ? ` — ${h.detalhes.motivo}` : ''}</span>
                <small className="dica">{h.usuario_email} · {new Date(h.criado_em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}</small></li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}

// =====================================================================
// O que mudou: proposta original do corretor × contraproposta da equipe
// =====================================================================
function OQueMudou({ cfg, unidade, original, contra, opcoes }: {
  cfg: ConfigEmpreendimento; unidade: Unidade; original: Serie[]; contra: Serie[];
  opcoes: { dataMinima: string; diasVencimento: number[]; observacoes: string; comissaoOriginal: number; comissaoContra: number; parteSinal: number; coordenacao: number; coordenacaoParcelas: number };
}) {
  const calc = (series: Serie[], comissao: number) => calcular(cfg, unidade, series, {
    dataMinima: opcoes.dataMinima, comissaoPercentual: comissao, parteDoSinal: opcoes.parteSinal, coordenacao: opcoes.coordenacao,
    coordenacaoParcelas: opcoes.coordenacaoParcelas, diasVencimento: opcoes.diasVencimento, observacoes: opcoes.observacoes,
  });
  const a = calc(original, opcoes.comissaoOriginal);
  const b = calc(contra, opcoes.comissaoContra);
  const sinal = (r: Resultado) => r.proposta.parcelas.filter((p) => p.periodicidade === 'Sinal').reduce((t, p) => t + p.valor, 0);
  const pv = (r: Resultado) => (r.proposta.vpl / r.tabela.vpl) * 100;
  const linhas: { rotulo: string; a: number; b: number; fmt: (v: number) => string; dif: (d: number) => string }[] = [
    { rotulo: 'Valor total', a: a.proposta.total, b: b.proposta.total, fmt: fmtReal, dif: (d) => `${d > 0 ? '+' : ''}${fmtReal(d)}` },
    { rotulo: 'PV sobre a tabela', a: pv(a), b: pv(b), fmt: (v) => `${fmtNum(v)}%`, dif: (d) => `${d > 0 ? '+' : ''}${fmtNum(d)} p.p.` },
    { rotulo: 'Sinal (soma)', a: sinal(a), b: sinal(b), fmt: fmtReal, dif: (d) => `${d > 0 ? '+' : ''}${fmtReal(d)}` },
    { rotulo: 'Comissão', a: a.comissao.devida, b: b.comissao.devida, fmt: fmtReal, dif: (d) => `${d > 0 ? '+' : ''}${fmtReal(d)}` },
  ];
  const chave = (x: Serie) => `${x.qtd}|${x.periodicidade}|${x.vencimento}|${x.valor.toFixed(2)}`;
  const emA = new Set(original.map(chave)), emB = new Set(contra.map(chave));
  const desc = (x: Serie) => `${x.qtd}× ${rotuloPeriodicidade(x.periodicidade)} de ${fmtReal(x.valor)} a partir de ${x.qtd > 1 ? fmtMes(x.vencimento.slice(0, 7)) : fmtData(x.vencimento)}`;
  return (
    <div className="o-que-mudou">
      <table className="comp">
        <thead><tr><th>O que mudou</th><th className="dir">Original</th><th className="dir">Contraproposta</th><th className="dir">Diferença</th></tr></thead>
        <tbody>
          {linhas.map((l) => {
            const d = l.b - l.a; const igual = Math.abs(d) < 0.005;
            return <tr key={l.rotulo} className={igual ? '' : 'mudou'}><td>{l.rotulo}</td><td className="dir mono">{l.fmt(l.a)}</td><td className="dir mono">{l.fmt(l.b)}</td><td className="dir mono">{igual ? '—' : l.dif(d)}</td></tr>;
          })}
        </tbody>
      </table>
      <div className="series-comp">
        <div><span>Séries da original</span><ul>{original.map((x) => <li key={x.id} className={emB.has(chave(x)) ? '' : 'saiu'}>{desc(x)}</li>)}</ul></div>
        <div><span>Séries da contraproposta</span><ul>{contra.map((x) => <li key={x.id} className={emA.has(chave(x)) ? '' : 'entrou'}>{desc(x)}</li>)}</ul></div>
      </div>
    </div>
  );
}

// =====================================================================
// Parâmetros da proposta (só o administrador): dias de vencimento e alçadas
// =====================================================================
function ParametrosProposta({ aoFechar }: { aoFechar: () => void }) {
  const [dias, setDias] = useState<number[] | null>(null);
  const [auto, setAuto] = useState(true);
  const [autoPv, setAutoPv] = useState('100');
  const [vendasPv, setVendasPv] = useState('98');
  const [imobPct, setImobPct] = useState('5');
  const [coordPct, setCoordPct] = useState('0,5');
  const [coordParc, setCoordParc] = useState(2);
  const [parteSinal, setParteSinal] = useState('70');
  const [msg, setMsg] = useState<{ ok: boolean; t: string } | null>(null);
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    supabase.from('comercial').select('dias_vencimento, alcada_automatica, alcada_auto_pv, alcada_vendas_pv, comissao_pct, coordenacao_pct, coordenacao_parcelas, parte_sinal').eq('id', 1).maybeSingle().then(({ data, error }) => {
      if (error || !data) { setMsg({ ok: false, t: error?.message ?? 'Parâmetros comerciais não encontrados.' }); return; }
      setDias([...(data.dias_vencimento as number[])].sort((a, b) => a - b));
      setAuto(data.alcada_automatica !== false);
      setAutoPv(String(data.alcada_auto_pv ?? 100).replace('.', ','));
      setVendasPv(String(data.alcada_vendas_pv ?? 98).replace('.', ','));
      const pct = (v: unknown, casas = 2) => String(Math.round(Number(v ?? 0) * 100 * 10 ** casas) / 10 ** casas).replace('.', ',');
      setImobPct(pct(data.comissao_pct)); setCoordPct(pct(data.coordenacao_pct));
      setCoordParc(Number(data.coordenacao_parcelas ?? 2)); setParteSinal(pct(data.parte_sinal, 0));
    });
  }, []);

  const alternar = (d: number) => setDias((l) => (l ?? []).includes(d) ? (l ?? []).filter((x) => x !== d) : [...(l ?? []), d].sort((a, b) => a - b));
  const num = (t: string) => Number(t.replace(',', '.'));

  const salvar = async () => {
    setMsg(null);
    if (!dias?.length) { setMsg({ ok: false, t: 'Escolha pelo menos um dia de vencimento.' }); return; }
    const a = num(autoPv), v = num(vendasPv);
    if (!(a > 0 && a <= 200) || !(v > 0 && v <= 200)) { setMsg({ ok: false, t: 'Informe os percentuais de PV entre 0 e 200.' }); return; }
    if (v > a) { setMsg({ ok: false, t: 'O PV da Secretaria de Vendas não pode ser maior que o da aprovação automática.' }); return; }
    const ci = num(imobPct), cc = num(coordPct), ps = num(parteSinal);
    if (!(ci >= 0 && ci < 20) || !(cc >= 0 && cc < 5)) { setMsg({ ok: false, t: 'Informe as comissões em %, por exemplo 5 e 0,5.' }); return; }
    if (!(ps > 0 && ps <= 100)) { setMsg({ ok: false, t: 'A parte do sinal para a comissão deve ficar entre 1% e 100%.' }); return; }
    setSalvando(true);
    const { error } = await supabase.from('comercial').update({
      dias_vencimento: dias, alcada_automatica: auto, alcada_auto_pv: a, alcada_vendas_pv: v,
      comissao_pct: ci / 100, coordenacao_pct: cc / 100, coordenacao_parcelas: coordParc, parte_sinal: ps / 100,
    }).eq('id', 1);
    setSalvando(false);
    setMsg(error ? { ok: false, t: error.message } : { ok: true, t: 'Parâmetros salvos. Valem para as próximas propostas abertas.' });
  };

  return (
    <div className="cartao parametros-proposta">
      <div className="titulo-linha"><h3>Parâmetros da proposta</h3><button className="mini" onClick={aoFechar} aria-label="Fechar">✕</button></div>
      {dias == null ? <p className="vazio">{msg?.t ?? 'Carregando…'}</p> : (
        <>
          <p className="dica">Dias de vencimento permitidos nas parcelas. O ato (sinal na data da proposta) fica de fora da regra.</p>
          <div className="dias-vencimento">
            {Array.from({ length: 28 }, (_, i) => i + 1).map((d) => (
              <button key={d} type="button" className={dias.includes(d) ? 'ativo' : ''} aria-pressed={dias.includes(d)} onClick={() => alternar(d)}>{String(d).padStart(2, '0')}</button>
            ))}
          </div>
          <p className="dica">Alçadas de aprovação, pelo PV da proposta em % do VPL da tabela:</p>
          <label className="param-check"><input type="checkbox" checked={auto} onChange={(e) => setAuto(e.target.checked)} /> Aprovar sozinha quando o PV atingir o mínimo e o sinal cobrir a comissão</label>
          <div className="grade-campos">
            <label>Aprovação automática a partir de (%)<input inputMode="decimal" value={autoPv} disabled={!auto} onChange={(e) => setAutoPv(e.target.value)} /></label>
            <label>Secretaria de Vendas aprova a partir de (%)<input inputMode="decimal" value={vendasPv} onChange={(e) => setVendasPv(e.target.value)} /></label>
          </div>
          <p className="dica">Abaixo do percentual da Secretaria de Vendas, só o administrador aprova.</p>
          <p className="dica">Comissão (sai das parcelas do sinal). De cada parcela, a parte do sinal vai para a comissão: primeiro a coordenação de vendas, dividida no número de parcelas escolhido; o resto para a imobiliária, até completar. O que sobra da parcela é do incorporador.</p>
          <div className="grade-campos">
            <label>Comissão da imobiliária (%)<input inputMode="decimal" value={imobPct} onChange={(e) => setImobPct(e.target.value)} /></label>
            <label>Coordenação de vendas (%)<input inputMode="decimal" value={coordPct} onChange={(e) => setCoordPct(e.target.value)} /></label>
            <label>Coordenação dividida em
              <select value={coordParc} onChange={(e) => setCoordParc(Number(e.target.value))}>
                <option value={1}>1 parcela do sinal</option><option value={2}>2 parcelas do sinal</option><option value={3}>3 parcelas do sinal</option>
              </select>
            </label>
            <label>Parte de cada parcela do sinal para a comissão (%)<input inputMode="decimal" value={parteSinal} onChange={(e) => setParteSinal(e.target.value)} /></label>
          </div>
          <div className="botoes"><button className="botao principal" disabled={salvando} onClick={salvar}>{salvando ? 'Salvando…' : 'Salvar parâmetros'}</button></div>
          {msg && <p className={msg.ok ? 'ok' : 'erro'}>{msg.t}</p>}
        </>
      )}
    </div>
  );
}
