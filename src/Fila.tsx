import { useCallback, useEffect, useMemo, useState } from 'react';
import { ArrowDown, ArrowUp, Clock, ListOrdered, Trash2 } from 'lucide-react';
import { supabase, useEspelho, type Unidade } from './dados';
import { Predio, Resumo } from './Predio';
import { useDialogos } from './ui';
import { type Perfil } from './util';
import { traduzirErro } from './proposta/dadosProposta';

// =====================================================================
// Escolha de unidades por lotes de pastas (fila).
//  * Administrador liga/desliga e define início, lote e intervalo.
//  * Equipe monta a fila (pastas aprovadas, ordem PA) e ajusta posições.
//  * Corretor/imobiliária: quando a pasta é liberada, escolhe a unidade
//    no espelho e reserva ele mesmo.
// =====================================================================

export interface SituacaoFila {
  ativa: boolean; inicio: string | null; lote: number; intervalo_min: number; unidades_por_pasta: number;
  liberadas: number; total: number; proximo_lote_em: string | null; agora: string;
}
interface ItemFila {
  pasta_id: string; codigo: string; comprador: string; imobiliaria: string | null; corretor: string | null; posicao: number;
  liberada: boolean; libera_em: string | null; reservas: number; unidades: string[] | null;
}

const hora = (iso: string | null) => (iso ? new Date(iso).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—');
const paraLocal = (iso: string | null) => {
  if (!iso) return '';
  const d = new Date(iso);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
};

/** Situação da fila (para o menu e a tela). */
export function useSituacaoFila() {
  const [s, setS] = useState<SituacaoFila | null>(null);
  const atualizar = useCallback(() => {
    supabase.rpc('fila_situacao').then(({ data, error }) => { if (!error) setS(data as SituacaoFila); });
  }, []);
  useEffect(() => { atualizar(); const t = setInterval(atualizar, 30_000); return () => clearInterval(t); }, [atualizar]);
  return { situacao: s, atualizar };
}

function Contagem({ ate }: { ate: string | null }) {
  const [agora, setAgora] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setAgora(Date.now()), 1000); return () => clearInterval(t); }, []);
  if (!ate) return null;
  const ms = new Date(ate).getTime() - agora;
  if (ms <= 0) return <span>agora</span>;
  const m = Math.floor(ms / 60000), s = Math.floor((ms % 60000) / 1000);
  return <span className="mono">{m >= 60 ? `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, '0')}min` : `${m}min ${String(s).padStart(2, '0')}s`}</span>;
}

export function EscolhaUnidades({ perfil }: { perfil: Perfil }) {
  const equipe = perfil.papel === 'admin' || perfil.papel === 'vendas';
  const admin = perfil.papel === 'admin';
  const { avisar, confirmar } = useDialogos();
  const esp = useEspelho();
  const { situacao, atualizar } = useSituacaoFila();
  const [itens, setItens] = useState<ItemFila[] | null>(null);
  const [pastaSel, setPastaSel] = useState<string>('');
  const [ocupado, setOcupado] = useState(false);

  const carregar = useCallback(() => {
    supabase.rpc('minha_fila').then(({ data, error }) => {
      if (error) avisar(traduzirErro(error.message), 'erro'); else setItens((data ?? []) as ItemFila[]);
    });
    atualizar();
  }, [avisar, atualizar]);
  // recarrega quando o espelho muda e a cada 30 s (novos lotes)
  const ultimaMudanca = Math.max(0, ...Object.values(esp.recentes));
  useEffect(() => { carregar(); }, [carregar, ultimaMudanca, situacao?.liberadas]);

  const minhas = useMemo(() => itens ?? [], [itens]);
  const podeEscolher = (i: ItemFila) => !!situacao?.ativa && i.liberada && i.reservas < (situacao?.unidades_por_pasta ?? 1);
  const escolhiveis = minhas.filter(podeEscolher);
  const pasta = escolhiveis.find((i) => i.pasta_id === pastaSel) ?? (escolhiveis.length === 1 ? escolhiveis[0] : undefined);

  const reservar = async (u: Unidade) => {
    if (!pasta) { avisar(escolhiveis.length ? 'Escolha primeiro a pasta liberada.' : 'Nenhuma pasta sua está liberada agora.', 'erro'); return; }
    if (u.status !== 'disponivel') { avisar(`A unidade ${u.numero} não está disponível.`, 'erro'); return; }
    if (!(await confirmar({ titulo: `Reservar a unidade ${u.numero}?`, texto: `Pasta ${pasta.codigo} · ${pasta.comprador}. A reserva fica registrada no seu nome.`, confirmar: 'Reservar' }))) return;
    setOcupado(true);
    const { error } = await supabase.rpc('reservar_pela_fila', { p_pasta: pasta.pasta_id, p_unidade: u.id });
    setOcupado(false);
    if (error) { avisar(traduzirErro(error.message) + (error.hint ? ` ${error.hint}` : ''), 'erro'); carregar(); return; }
    avisar(`Unidade ${u.numero} reservada para ${pasta.comprador}.`);
    setPastaSel('');
    carregar();
  };

  return (
    <section className="secao larga fila">
      <div className="secao-topo">
        <div>
          <h2>Escolha de unidades</h2>
          <p className="sub">{situacao?.ativa
            ? `Fila ligada: ${situacao.lote} ${situacao.lote === 1 ? 'pasta' : 'pastas'} a cada ${situacao.intervalo_min} min, desde ${hora(situacao.inicio)}.`
            : 'A escolha pela fila está desligada. As reservas são feitas pela Sec. Vendas.'}</p>
        </div>
      </div>

      {situacao?.ativa && (
        <div className="kpis fila-kpis">
          <div className="kpi"><span className="kpi-valor">{situacao.liberadas}<small> / {situacao.total}</small></span><span className="kpi-rotulo">Pastas liberadas</span></div>
          <div className="kpi"><span className="kpi-valor"><Contagem ate={situacao.proximo_lote_em} /></span><span className="kpi-rotulo">Próximo lote</span><span className="kpi-detalhe">{hora(situacao.proximo_lote_em)}</span></div>
          <div className="kpi s-disponivel"><span className="kpi-valor">{esp.unidades.filter((u) => u.status === 'disponivel').length}</span><span className="kpi-rotulo">Unidades disponíveis</span></div>
          <div className="kpi"><span className="kpi-valor">{situacao.unidades_por_pasta}</span><span className="kpi-rotulo">{situacao.unidades_por_pasta === 1 ? 'Unidade por pasta' : 'Unidades por pasta'}</span></div>
        </div>
      )}

      {admin && <ConfigFila situacao={situacao} aoSalvar={carregar} />}

      {!equipe && (
        <div className="cartao">
          <h3>Minhas pastas na fila</h3>
          {itens == null ? <p className="vazio">Carregando…</p> : minhas.length === 0 ? (
            <p className="vazio">Nenhuma pasta sua está na fila. A pasta entra na fila depois de aprovada pela equipe.</p>
          ) : (
            <ul className="fila-minhas">
              {minhas.map((i) => {
                const ok = podeEscolher(i);
                return (
                  <li key={i.pasta_id} className={`${ok ? 'liberada' : ''} ${pasta?.pasta_id === i.pasta_id ? 'selecionada' : ''}`}>
                    <label>
                      <input type="radio" name="pasta" disabled={!ok} checked={pasta?.pasta_id === i.pasta_id} onChange={() => setPastaSel(i.pasta_id)} />
                      <span className="fila-pos">{i.posicao}º</span>
                      <span><strong>{i.codigo}</strong> · {i.comprador}</span>
                    </label>
                    <span className="fila-estado">
                      {i.unidades?.length ? <>Unidade {i.unidades.join(', ')} reservada</>
                        : i.liberada ? (situacao?.ativa ? <>Liberada · escolha a unidade abaixo</> : <>Liberada</>)
                        : <><Clock size={14} /> Libera em {hora(i.libera_em)}</>}
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      )}

      {!equipe && situacao?.ativa && (
        <div className="cartao espelho-cartao">
          <div className="cartao-topo">
            <h3>{pasta ? `Escolha a unidade para ${pasta.comprador}` : 'Espelho'}</h3>
            {pasta && <span className="dica">Toque numa unidade disponível para reservar.</span>}
          </div>
          <Resumo unidades={esp.unidades} />
          <div className={ocupado ? 'carregando' : ''}>
            <Predio unidades={esp.unidades} recentes={esp.recentes} aoSelecionar={pasta ? reservar : undefined} />
          </div>
        </div>
      )}

      {equipe && <FilaEquipe itens={itens} situacao={situacao} aoMudar={carregar} />}
    </section>
  );
}

function ConfigFila({ situacao, aoSalvar }: { situacao: SituacaoFila | null; aoSalvar: () => void }) {
  const { avisar } = useDialogos();
  const [ativa, setAtiva] = useState(false);
  const [inicio, setInicio] = useState('');
  const [lote, setLote] = useState(10);
  const [intervalo, setIntervalo] = useState(30);
  const [porPasta, setPorPasta] = useState(1);
  useEffect(() => {
    if (!situacao) return;
    setAtiva(situacao.ativa); setInicio(paraLocal(situacao.inicio)); setLote(situacao.lote);
    setIntervalo(situacao.intervalo_min); setPorPasta(situacao.unidades_por_pasta);
  }, [situacao?.ativa, situacao?.inicio, situacao?.lote, situacao?.intervalo_min, situacao?.unidades_por_pasta]); // eslint-disable-line react-hooks/exhaustive-deps

  const salvar = async () => {
    const { error } = await supabase.rpc('configurar_fila', {
      p_ativa: ativa, p_inicio: inicio ? new Date(inicio).toISOString() : null, p_lote: lote, p_intervalo: intervalo, p_unidades_por_pasta: porPasta,
    });
    if (error) { avisar(traduzirErro(error.message), 'erro'); return; }
    avisar(ativa ? 'Fila ligada.' : 'Fila desligada.');
    aoSalvar();
  };

  return (
    <div className="cartao fila-config">
      <div className="cartao-topo"><h3>Configuração da fila</h3><span className="dica">Liga ou desliga por empreendimento</span></div>
      <div className="fila-campos">
        <label className="interruptor"><input type="checkbox" checked={ativa} onChange={(e) => setAtiva(e.target.checked)} /><span className="trilho" /><span><strong>Escolha pela fila</strong><br /><small className="dica">{ativa ? 'Ligada' : 'Desligada'}</small></span></label>
        <label>Início <input type="datetime-local" value={inicio} onChange={(e) => setInicio(e.target.value)} /></label>
        <label>Pastas por lote <input type="number" min={1} max={500} value={lote} onChange={(e) => setLote(Number(e.target.value))} /></label>
        <label>A cada (min) <input type="number" min={1} max={1440} value={intervalo} onChange={(e) => setIntervalo(Number(e.target.value))} /></label>
        <label>Unidades por pasta <input type="number" min={1} max={20} value={porPasta} onChange={(e) => setPorPasta(Number(e.target.value))} /></label>
        <button className="botao principal" onClick={salvar}>Salvar</button>
      </div>
      <p className="dica">Exemplo: 10 pastas a cada 30 minutos. Quem não reservar no seu horário continua podendo reservar depois, entre as unidades ainda disponíveis.</p>
    </div>
  );
}

function FilaEquipe({ itens, situacao, aoMudar }: { itens: ItemFila[] | null; situacao: SituacaoFila | null; aoMudar: () => void }) {
  const { avisar, confirmar } = useDialogos();
  const [filtro, setFiltro] = useState('');
  const rpc = async (nome: string, args: Record<string, unknown>, ok?: string) => {
    const { data, error } = await supabase.rpc(nome, args);
    if (error) { avisar(traduzirErro(error.message), 'erro'); return; }
    if (ok) avisar(ok.replace('{n}', String(data ?? '')));
    aoMudar();
  };
  const lista = (itens ?? []).filter((i) => !filtro || `${i.codigo} ${i.comprador} ${i.imobiliaria} ${i.corretor}`.toLowerCase().includes(filtro.toLowerCase()));

  return (
    <div className="cartao">
      <div className="cartao-topo">
        <h3><ListOrdered size={18} /> Fila de pastas ({itens?.length ?? 0})</h3>
        <div className="botoes-linha">
          <input className="busca" placeholder="Buscar pasta, comprador, imobiliária…" value={filtro} onChange={(e) => setFiltro(e.target.value)} />
          <button className="botao" onClick={() => rpc('montar_fila', {}, '{n} pasta(s) aprovada(s) incluída(s) no fim da fila.')}>Montar / completar fila</button>
        </div>
      </div>
      <p className="dica">Entram as pastas com documentação aprovada, na ordem de submissão ao incorporador (código PA). Use as setas para ajustar.</p>
      {itens == null ? <p className="vazio">Carregando…</p> : itens.length === 0 ? <p className="vazio">A fila está vazia. Clique em "Montar / completar fila".</p> : (
        <div className="tabela-rolagem">
          <table className="tabela">
            <thead><tr><th>Pos.</th><th>Pasta</th><th>Comprador</th><th>Imobiliária</th><th>Corretor</th><th>Liberação</th><th>Unidade</th><th /></tr></thead>
            <tbody>
              {lista.map((i) => (
                <tr key={i.pasta_id} className={i.liberada && situacao?.ativa ? 'fila-liberada' : ''}>
                  <td className="mono">{i.posicao}º</td>
                  <td className="mono">{i.codigo}</td>
                  <td>{i.comprador}</td>
                  <td>{i.imobiliaria ?? '—'}</td>
                  <td>{i.corretor ?? '—'}</td>
                  <td className="nowrap">{!situacao?.ativa ? '—' : i.liberada ? 'Liberada' : hora(i.libera_em)}</td>
                  <td className="mono">{i.unidades?.join(', ') ?? '—'}</td>
                  <td className="nowrap">
                    <button className="icone-botao" aria-label="Subir" onClick={() => rpc('mover_na_fila', { p_pasta: i.pasta_id, p_posicao: i.posicao - 1 })}><ArrowUp size={15} /></button>
                    <button className="icone-botao" aria-label="Descer" onClick={() => rpc('mover_na_fila', { p_pasta: i.pasta_id, p_posicao: i.posicao + 1 })}><ArrowDown size={15} /></button>
                    <button className="icone-botao" aria-label="Tirar da fila" onClick={async () => {
                      if (await confirmar({ titulo: 'Tirar da fila?', texto: `${i.codigo} · ${i.comprador}. As pastas abaixo sobem uma posição.`, confirmar: 'Tirar' })) rpc('remover_da_fila', { p_pasta: i.pasta_id });
                    }}><Trash2 size={15} /></button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
