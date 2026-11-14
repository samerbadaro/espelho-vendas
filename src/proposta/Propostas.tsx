import { useCallback, useEffect, useMemo, useState } from 'react';
import { ArrowLeft, FileDown, Plus, Send } from 'lucide-react';
import { supabase } from '../dados';
import { ir, type Perfil } from '../util';
import { useDialogos } from '../ui';
import { EditorProposta, type EstadoEditor } from './Proposta';
import {
  carregarContexto, doBanco, paraBanco, resumoDe, rotuloProposta, traduzirErro, STATUS_PROPOSTA,
  type Contexto, type PropostaSalva, type StatusProposta,
} from './dadosProposta';
import { gerarCarta, type DadosPasta } from './carta';
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
  const [erro, setErro] = useState('');

  useEffect(() => {
    let q = supabase.from('propostas')
      .select('id, codigo, status, data_proposta, resumo, criado_por, atualizada_em, unidades(numero), pastas(comprador_nome), imobiliarias(nome)')
      .order('atualizada_em', { ascending: false }).limit(300);
    if (filtro) q = q.eq('status', filtro);
    q.then(({ data, error }) => {
      if (error) setErro(traduzirErro(error.message)); else setLista((data ?? []) as never);
    });
  }, [filtro]);

  return (
    <section className="secao">
      <div className="secao-topo">
        <div>
          <h2>Propostas</h2>
          <p className="sub">{equipe ? 'Analise as propostas enviadas pelas imobiliárias.' : 'Monte a proposta, confira o PV e envie para análise.'}</p>
        </div>
        <button className="botao principal" onClick={() => ir('/painel/propostas/nova')}><Plus size={16} /> Nova proposta</button>
      </div>
      <div className="filtros">
        <select value={filtro} onChange={(e) => setFiltro(e.target.value as StatusProposta | '')}>
          <option value="">Todas</option>
          {STATUS_PROPOSTA.map((s) => <option key={s.valor} value={s.valor}>{s.rotulo}</option>)}
        </select>
      </div>
      {erro && <p className="erro">{erro}</p>}
      {lista == null ? <p className="vazio">Carregando…</p> : lista.length === 0 ? (
        <div className="cartao vazio-grande"><p>Nenhuma proposta {filtro ? `com status "${rotuloProposta(filtro)}"` : 'ainda'}.</p></div>
      ) : (
        <div className="tabela-rolagem">
          <table className="tabela">
            <thead><tr><th>Código</th><th>Unidade</th><th>Comprador</th>{equipe && <th>Imobiliária</th>}<th>Corretor</th><th className="dir">Valor</th><th className="dir">PV</th><th>Status</th><th>Atualizada</th></tr></thead>
            <tbody>
              {lista.map((p) => (
                <tr key={p.id} tabIndex={0} onClick={() => ir(`/painel/propostas/${p.id}`)} onKeyDown={(e) => e.key === 'Enter' && ir(`/painel/propostas/${p.id}`)}>
                  <td className="mono">{p.codigo}</td>
                  <td className="mono">{p.unidades?.numero}</td>
                  <td>{p.pastas?.comprador_nome ?? <span className="dica">sem pasta</span>}</td>
                  {equipe && <td>{p.imobiliarias?.nome ?? 'Direto'}</td>}
                  <td>{p.criado_por}</td>
                  <td className="dir mono">{p.resumo.total != null ? fmtReal(p.resumo.total) : '—'}</td>
                  <td className={`dir mono ${(p.resumo.pv_pct ?? 100) < 100 ? 'texto-ruim' : ''}`}>{p.resumo.pv_pct != null ? `${p.resumo.pv_pct.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}%` : '—'}</td>
                  <td><Selo s={p.status} /></td>
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

  const salvar = async (): Promise<string | null> => {
    if (!estado) return null;
    setSalvando(true);
    const campos = {
      unidade_id: unidadeId, pasta_id: pastaId || null, observacoes: obs.trim() || null,
      series: paraBanco(estado.series), resumo: resumoDe(estado.resultado),
      comissao_pct: estado.comissaoPct, parte_sinal: estado.parteSinal,
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
    if (temErro) { avisar('Corrija os erros (PV negativo ou vencimentos) antes de enviar.', 'erro'); return; }
    if (!pastaId) { avisar('Vincule a pasta do comprador antes de enviar.', 'erro'); return; }
    if (!(await confirmar({ titulo: 'Enviar para análise?', texto: 'Depois de enviada, a proposta só volta a ser editada se a equipe devolver para ajuste.', confirmar: 'Enviar proposta' }))) return;
    const novoId = await salvar();
    if (!novoId) return;
    const { error } = await supabase.rpc('enviar_proposta', { p_id: novoId });
    if (error) { avisar(traduzirErro(error.message), 'erro'); if (!proposta) ir(`/painel/propostas/${novoId}`); return; }
    avisar('Proposta enviada para análise.');
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

  const carta = async () => {
    if (!estado) return;
    let dadosPasta: DadosPasta | null = null;
    if (pastaId) {
      const { data } = await supabase.from('pastas').select('codigo, comprador_nome, comprador_cpf, comprador_nascimento, comprador_telefone, comprador_email, comprador_profissao, estado_civil, conjuge_nome, conjuge_cpf, conjuge_nascimento, conjuge_telefone, conjuge_email, conjuge_profissao').eq('id', pastaId).maybeSingle();
      dadosPasta = data as DadosPasta | null;
    }
    const imobId = proposta?.imobiliaria_id ?? pasta?.imobiliaria_id;
    const { data: im } = imobId ? await supabase.from('imobiliarias').select('nome').eq('id', imobId).maybeSingle() : { data: null };
    try {
      await gerarCarta({
        codigo: proposta?.codigo ?? 'SIMULAÇÃO', dataProposta: proposta?.data_proposta ?? hoje, empreendimento: ctx.nome, comercial: ctx.comercial,
        unidade: { numero: unidade.numero, area: unidade.area, andar: unidade.andar }, pasta: dadosPasta,
        logoUrl: ctx.logoUrl, corDestaque: ctx.corDestaque,
        imobiliaria: (im as { nome: string } | null)?.nome ?? '', corretor: proposta ? proposta.criado_por_nome ?? proposta.criado_por ?? '' : perfil.nome || perfil.email,
        series: estado.series, resultado: estado.resultado, observacoes: obs,
      });
    } catch { avisar('Não foi possível gerar a carta proposta.', 'erro'); }
  };

  const trocarUnidade = (novo: string) => { setUnidadeId(novo); setChaveEditor((k) => k + 1); };
  const statusEspelho = (s: string) => ({ disponivel: 'disponível', reservada: 'reservada', proposta: 'proposta recebida', contrato: 'contrato', vendida: 'vendida', bloqueada: 'bloqueada', permutante: 'permutante' } as Record<string, string>)[s] ?? s;

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
          <button className="botao" onClick={carta} disabled={!estado}><FileDown size={16} /> Carta proposta</button>
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
          <div className="botoes-linha">
            <button className="botao ok" onClick={() => analisar('aprovada')} disabled={salvando}>Aprovar</button>
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
        somenteLeitura={!editavel} podeEditarComissao={equipe}
        aoMudar={setEstado}
      />

      <div className="prop-bloco">
        <label className="campo-motivo">Observações da proposta (saem na carta)
          <textarea rows={2} value={obs} onChange={(e) => setObs(e.target.value)} disabled={!editavel} />
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
