import { useCallback, useEffect, useMemo, useState } from 'react';
import { ArrowLeft, FileDown, Plus, Send } from 'lucide-react';
import { supabase } from '../dados';
import { ir, type Perfil } from '../util';
import { useDialogos } from '../ui';
import { EditorProposta, type EstadoEditor } from './Proposta';
import {
  alcadaPrevista, carregarContexto, doBanco, paraBanco, resumoDe, rotuloProposta, traduzirErro, ROTULO_ALCADA, STATUS_PROPOSTA,
  type Contexto, type PropostaSalva, type StatusProposta,
} from './dadosProposta';
import { gerarCarta, gerarCartaWord, type DadosCarta, type DadosPasta } from './carta';
import { aplicarModelo, fmtData, fmtReal, hojeISO, precoUnidade } from './motor';

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
      .select('id, codigo, status, alcada, analisada_por, data_proposta, resumo, criado_por, criado_por_nome, atualizada_em, unidades(numero), pastas(comprador_nome), imobiliarias(nome)')
      .order('atualizada_em', { ascending: false }).limit(300);
    if (filtro) q = q.eq('status', filtro);
    q.then(({ data, error }) => {
      if (error) setErro(traduzirErro(error.message)); else setLista((data ?? []) as never);
    });
  }, [filtro]);

  // busca sem acento e sem diferenciar maiúsculas, em unidade, cliente, imobiliária, corretor e código
  const sem = (t: string) => t.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
  const termo = sem(busca.trim());
  const visiveis = (lista ?? []).filter((p) => !termo || sem([p.codigo, p.unidades?.numero, p.pastas?.comprador_nome, p.imobiliarias?.nome, p.criado_por, p.criado_por_nome].filter(Boolean).join(' ')).includes(termo));

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
              {visiveis.map((p) => (
                <tr key={p.id} tabIndex={0} onClick={() => ir(`/painel/propostas/${p.id}`)} onKeyDown={(e) => e.key === 'Enter' && ir(`/painel/propostas/${p.id}`)}>
                  <td className="mono">{p.codigo}</td>
                  <td className="mono">{p.unidades?.numero}</td>
                  <td>{p.pastas?.comprador_nome ?? <span className="dica">sem pasta</span>}</td>
                  {equipe && <td>{p.imobiliarias?.nome ?? 'Direto'}</td>}
                  <td>{p.criado_por}</td>
                  <td className="dir mono">{p.resumo.total != null ? fmtReal(p.resumo.total) : '—'}</td>
                  <td className={`dir mono ${(p.resumo.pv_pct ?? 100) < 100 ? 'texto-ruim' : ''}`}>{p.resumo.pv_pct != null ? `${p.resumo.pv_pct.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}%` : '—'}</td>
                  <td><Selo s={p.status} />{p.status === 'enviada' && p.alcada && <small className="dica nowrap"> {ROTULO_ALCADA[p.alcada]}</small>}
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
// =====================================================================
export function PaginaProposta({ id, perfil }: { id: string | 'nova'; perfil: Perfil }) {
  const { avisar, confirmar } = useDialogos();
  const equipe = perfil.papel === 'admin' || perfil.papel === 'vendas';
  const hoje = hojeISO();
  const [ctx, setCtx] = useState<Contexto | null>(null);
  const [proposta, setProposta] = useState<PropostaSalva | null>(null);
  const [pastas, setPastas] = useState<PastaResumo[]>([]);
  const [historico, setHistorico] = useState<{ acao: string; usuario_email: string | null; criado_em: string; detalhes: { motivo?: string } | null }[]>([]);
  const [erro, setErro] = useState('');
  const [unidadeId, setUnidadeId] = useState('');
  const [pastaId, setPastaId] = useState('');
  const [obs, setObs] = useState('');
  const [estado, setEstado] = useState<EstadoEditor | null>(null);
  const [salvando, setSalvando] = useState(false);
  const [analise, setAnalise] = useState<null | 'devolvida' | 'recusada' | 'cancelada'>(null);
  const [motivo, setMotivo] = useState('');
  const [chaveEditor, setChaveEditor] = useState(0);

  const carregar = useCallback(async () => {
    const c = await carregarContexto();
    if ('erro' in c) { setErro(c.erro); return; }
    setCtx(c);
    const { data: ps } = await supabase.from('pastas').select('id, codigo, comprador_nome, status, imobiliaria_id').order('criada_em', { ascending: false });
    setPastas((ps ?? []) as PastaResumo[]);
    if (id === 'nova') {
      const q = new URLSearchParams(window.location.search);
      const un = q.get('unidade');
      setUnidadeId(c.unidades.find((u) => u.numero === un || u.id === un)?.id ?? c.unidades.find((u) => u.status === 'disponivel')?.id ?? c.unidades[0].id);
      setPastaId(q.get('pasta') ?? '');
      return;
    }
    const { data, error } = await supabase.from('propostas').select('*').eq('id', id).maybeSingle();
    if (error || !data) { setErro(error ? traduzirErro(error.message) : 'Proposta não encontrada.'); return; }
    const p = data as PropostaSalva;
    setProposta(p); setUnidadeId(p.unidade_id); setPastaId(p.pasta_id ?? ''); setObs(p.observacoes ?? '');
    setChaveEditor((k) => k + 1);
    const { data: h } = await supabase.from('historico_propostas').select('acao, usuario_email, criado_em, detalhes').eq('proposta_id', id).order('criado_em', { ascending: false });
    setHistorico((h ?? []) as never);
  }, [id]);
  useEffect(() => { carregar(); }, [carregar]);

  const unidade = useMemo(() => ctx?.unidades.find((u) => u.id === unidadeId), [ctx, unidadeId]);
  const editavel = !proposta || proposta.status === 'rascunho' || proposta.status === 'devolvida';
  const seriesIniciais = useMemo(() => (proposta && proposta.unidade_id === unidadeId ? doBanco(proposta.series) : undefined), [proposta, unidadeId]);

  if (erro) return <section className="secao"><p className="erro">{erro}</p><button className="botao" onClick={() => ir('/painel/propostas')}>Voltar</button></section>;
  if (!ctx || !unidade) return <section className="secao"><p className="vazio">Carregando…</p></section>;

  const pasta = pastas.find((p) => p.id === pastaId);
  const temErro = estado?.resultado.avisos.some((a) => a.nivel === 'erro') ?? true;
  const temPermuta = estado?.series.some((s) => s.periodicidade === 'Permuta') ?? false;
  const pvPct = estado ? Math.round((estado.resultado.proposta.vpl / estado.resultado.tabela.vpl) * 10000) / 100 : 0;
  const alcada = alcadaPrevista(ctx.comercial, pvPct, (estado?.resultado.comissao.naoCoberta ?? 1) <= 0.005);
  const faltaPermuta = temPermuta && !obs.trim();

  const salvar = async (): Promise<string | null> => {
    if (!estado) return null;
    setSalvando(true);
    const campos = {
      unidade_id: unidadeId, pasta_id: pastaId || null, observacoes: obs.trim() || null,
      series: paraBanco(estado.series), resumo: resumoDe(estado.resultado),
      comissao_pct: estado.comissaoPct, parte_sinal: estado.parteSinal,
      coordenacao_pct: estado.coordenacaoPct, coordenacao_parcelas: estado.coordenacaoParcelas,
    };
    const r = proposta
      ? await supabase.from('propostas').update(campos).eq('id', proposta.id).select('id').single()
      : await supabase.from('propostas').insert(campos).select('id').single();
    setSalvando(false);
    if (r.error) { avisar(traduzirErro(r.error.message), 'erro'); return null; }
    return (r.data as { id: string }).id;
  };

  const aoSalvar = async () => {
    const novoId = await salvar();
    if (!novoId) return;
    avisar('Proposta salva.');
    if (!proposta) ir(`/painel/propostas/${novoId}`); else carregar();
  };

  const enviar = async () => {
    if (faltaPermuta) { avisar('Descreva a permuta nas observações antes de enviar.', 'erro'); return; }
    if (temErro) { avisar('Corrija os erros da grade (vencimentos, parcelas) antes de enviar.', 'erro'); return; }
    if (!pastaId) { avisar('Vincule a pasta do comprador antes de enviar.', 'erro'); return; }
    const textoAlcada = alcada === 'automatica' ? 'PV dentro da tabela e sinal cobrindo a comissão: a proposta será aprovada na hora e a unidade irá para "Proposta recebida".'
      : `PV de ${pvPct.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}%: a aprovação fica com ${alcada === 'vendas' ? 'a Sec. Vendas' : 'o administrador'}.`;
    if (!(await confirmar({ titulo: 'Enviar proposta?', texto: `${textoAlcada} Depois de enviada, ela só volta a ser editada se for devolvida para ajuste.`, confirmar: 'Enviar proposta' }))) return;
    const novoId = await salvar();
    if (!novoId) return;
    const { data: enviada, error } = await supabase.rpc('enviar_proposta', { p_id: novoId });
    if (error) { avisar(traduzirErro(error.message), 'erro'); if (!proposta) ir(`/painel/propostas/${novoId}`); return; }
    const e = enviada as PropostaSalva | null;
    avisar(e?.status === 'aprovada' ? 'Proposta aprovada automaticamente. A unidade foi para "Proposta recebida".'
      : `Proposta enviada. Aprovação: ${e?.alcada ? ROTULO_ALCADA[e.alcada] : 'equipe'}.`);
    if (!proposta) ir(`/painel/propostas/${novoId}`); else carregar();
  };

  const analisar = async (decisao: 'aprovada' | 'devolvida' | 'recusada' | 'cancelada') => {
    if (!proposta) return;
    if (decisao === 'aprovada' && !(await confirmar({ titulo: 'Aprovar proposta?', texto: `A unidade ${unidade.numero} vai para "Proposta recebida" no espelho, com o valor e o PV desta proposta.`, confirmar: 'Aprovar' }))) return;
    if (decisao !== 'aprovada' && !motivo.trim()) { avisar('Informe o motivo.', 'erro'); return; }
    setSalvando(true);
    const { error } = await supabase.rpc('analisar_proposta', { p_id: proposta.id, p_decisao: decisao, p_motivo: motivo.trim() || null });
    setSalvando(false);
    if (error) { avisar(traduzirErro(error.message), 'erro'); return; }
    setAnalise(null); setMotivo('');
    avisar(decisao === 'aprovada' ? 'Proposta aprovada. O espelho foi atualizado.' : 'Decisão registrada.');
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
    try {
      const dados: DadosCarta = {
        codigo: proposta?.codigo ?? 'SIMULAÇÃO', dataProposta: proposta?.data_proposta ?? hoje, empreendimento: ctx.nome, comercial: ctx.comercial,
        unidade: { numero: unidade.numero, area: unidade.area, andar: unidade.andar }, pasta: dadosPasta,
        logoUrl: ctx.logoUrl, corDestaque: ctx.corDestaque,
        imobiliaria: (im as { nome: string } | null)?.nome ?? '', corretor: proposta ? proposta.criado_por_nome ?? proposta.criado_por ?? '' : perfil.nome || perfil.email,
        series: estado.series, resultado: estado.resultado, observacoes: obs,
      };
      await (formato === 'docx' ? gerarCartaWord : gerarCarta)(dados, { simples: true });
    } catch { avisar('Não foi possível gerar a carta proposta.', 'erro'); }
  };

  const trocarUnidade = (novo: string) => { setUnidadeId(novo); setChaveEditor((k) => k + 1); };
  const statusEspelho = (s: string) => ({ disponivel: 'disponível', reservada: 'reservada', proposta: 'proposta recebida', contrato: 'contrato em assinatura', vendida: 'vendida', bloqueada: 'bloqueada', permutante: 'permutante' } as Record<string, string>)[s] ?? s;

  return (
    <section className="secao prop-pagina">
      <div className="secao-topo">
        <div>
          <button className="link-voltar" onClick={() => ir('/painel/propostas')}><ArrowLeft size={15} /> Propostas</button>
          <h2>{proposta ? `Proposta ${proposta.codigo}` : 'Nova proposta'} {proposta && <Selo s={proposta.status} />}</h2>
          <p className="sub">
            {proposta ? `Criada em ${fmtData(proposta.data_proposta)} por ${proposta.criado_por_nome ?? proposta.criado_por ?? '—'}` : `Data da proposta: ${fmtData(hoje)}`}
            {proposta?.analisada_por && ` · analisada por ${proposta.analisada_por} em ${fmtData(proposta.analisada_em!.slice(0, 10))}`}
          </p>
        </div>
        <div className="botoes-linha">
          {editavel && estado && <span className={`chip-alcada a-${alcada}`} title="Quem aprova esta proposta, pelo PV e pela comissão">Aprovação: {ROTULO_ALCADA[alcada]}</span>}
          {!editavel && proposta?.alcada && proposta.status === 'enviada' && <span className={`chip-alcada a-${proposta.alcada}`}>Aguardando: {ROTULO_ALCADA[proposta.alcada]}</span>}
          <button className="botao" onClick={() => carta('pdf')} disabled={!estado} title="Resumo da proposta em PDF, sem campos em branco e sem assinaturas"><FileDown size={16} /> Resumo da proposta</button>
          <button className="botao" onClick={() => carta('docx')} disabled={!estado} title="O mesmo resumo em Word"><FileDown size={16} /> Word</button>
          {editavel && <button className="botao" onClick={aoSalvar} disabled={salvando || !estado}>Salvar rascunho</button>}
          {editavel && <button className="botao principal" onClick={enviar} disabled={salvando || !estado}><Send size={16} /> Enviar para análise</button>}
        </div>
      </div>

      {proposta?.motivo_analise && (proposta.status === 'devolvida' || proposta.status === 'recusada' || proposta.status === 'cancelada') && (
        <div className={`cartao aviso-prop ${proposta.status}`}><strong>{rotuloProposta(proposta.status)}:</strong> {proposta.motivo_analise}</div>
      )}

      {equipe && proposta && proposta.status === 'enviada' && (
        <div className="cartao analise-prop">
          <strong>Análise da equipe</strong>
          {proposta.alcada === 'admin' && perfil.papel !== 'admin' && <span className="dica">PV de {proposta.resumo.pv_pct?.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}%: abaixo da alçada da Sec. Vendas, só o administrador aprova.</span>}
          <div className="botoes-linha">
            {(proposta.alcada !== 'admin' || perfil.papel === 'admin') && <button className="botao ok" onClick={() => analisar('aprovada')} disabled={salvando}>Aprovar</button>}
            <button className="botao" onClick={() => setAnalise('devolvida')}>Devolver para ajuste</button>
            <button className="botao" onClick={() => setAnalise('recusada')}>Recusar</button>
          </div>
        </div>
      )}
      {equipe && proposta && proposta.status !== 'cancelada' && proposta.status !== 'enviada' && (
        <div className="botoes-linha direita"><button className="botao pequeno" onClick={() => setAnalise('cancelada')}>Cancelar proposta</button></div>
      )}
      {analise && (
        <div className="cartao">
          <label className="campo-motivo">Motivo ({analise === 'devolvida' ? 'o corretor verá o que ajustar' : analise === 'recusada' ? 'recusa' : 'cancelamento'})
            <textarea rows={2} value={motivo} onChange={(e) => setMotivo(e.target.value)} autoFocus />
          </label>
          <div className="botoes-linha">
            <button className="botao" onClick={() => { setAnalise(null); setMotivo(''); }}>Voltar</button>
            <button className={`botao ${analise === 'devolvida' ? 'principal' : 'perigo'}`} onClick={() => analisar(analise)} disabled={salvando}>
              {analise === 'devolvida' ? 'Devolver' : analise === 'recusada' ? 'Recusar' : 'Cancelar proposta'}
            </button>
          </div>
        </div>
      )}

      <div className="prop-bloco prop-unidade">
        <label>
          <span>Unidade</span>
          <select value={unidadeId} onChange={(e) => trocarUnidade(e.target.value)} disabled={!editavel}>
            {ctx.unidades.map((u) => <option key={u.id} value={u.id}>{u.numero}{u.status !== 'disponivel' ? ` (${statusEspelho(u.status)})` : ''}</option>)}
          </select>
        </label>
        <div><span>Área</span><strong>{unidade.area.toLocaleString('pt-BR', { minimumFractionDigits: 2 })} m²</strong></div>
        <div><span>Tabela</span><strong>{unidade.tabela}</strong></div>
        <div><span>Preço de tabela</span><strong>{fmtReal(precoUnidade(ctx.cfg, unidade))}</strong></div>
        <div><span>Entrega</span><strong>{fmtData(ctx.comercial.mes_entrega).slice(3)}</strong></div>
        <label className="prop-pasta">
          <span>Pasta do comprador</span>
          <select value={pastaId} onChange={(e) => setPastaId(e.target.value)} disabled={!editavel}>
            <option value="">— vincular depois —</option>
            {pastas.map((p) => <option key={p.id} value={p.id}>{p.codigo} · {p.comprador_nome}{p.status !== 'aprovada' ? ' (documentação não aprovada)' : ''}</option>)}
          </select>
        </label>
      </div>
      {unidade.status !== 'disponivel' && editavel && (
        <p className="alerta">A unidade {unidade.numero} está {statusEspelho(unidade.status)} no espelho.</p>
      )}

      <EditorProposta
        key={`${unidadeId}-${chaveEditor}`}
        cfg={ctx.cfg} unidade={unidade} hoje={hoje}
        dataMinima={proposta?.data_proposta ?? hoje}
        dias={ctx.comercial.dias_vencimento}
        seriesIniciais={seriesIniciais ?? aplicarModelo(ctx.cfg, unidade, 'tabela', { dia: 10, hoje })}
        comissaoInicial={proposta?.comissao_pct} parteInicial={proposta?.parte_sinal}
        coordParcelasInicial={proposta?.coordenacao_parcelas ?? undefined} nomeCoordenacao={ctx.comercial.coordenacao_comercial} coordPctInicial={proposta?.coordenacao_pct ?? undefined}
        somenteLeitura={!editavel} podeEditarComissao={equipe}
        aoMudar={setEstado}
        observacoes={obs}
      />

      <div className="prop-bloco">
        <label className={`campo-motivo${faltaPermuta ? ' obrigatorio' : ''}`}>
          {faltaPermuta ? 'Observações — obrigatório: descreva a permuta (imóvel, carro, serviços, valor de avaliação...)' : 'Observações da proposta (saem na carta)'}
          <textarea rows={faltaPermuta ? 3 : 2} value={obs} onChange={(e) => setObs(e.target.value)} disabled={!editavel}
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
