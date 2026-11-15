// Tabela de vendas: versões, preços por unidade, até 3 captações, reajuste, arquivo base e vigência.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { CalendarClock, Copy, Download, FileDown, Plus, Power, Trash2, Upload, X } from 'lucide-react';
import { supabase } from './dados';
import { type Perfil } from './util';
import { useDialogos } from './ui';
import {
  carregarCaptacoes, mesDaVenda, traduzirErro, ROTULO_SITUACAO, type CaptacaoBanco, type SituacaoTabela, type TabelaResumo,
} from './proposta/dadosProposta';
import { baixarArquivoBase, gerarPdfTabela, lerArquivo, type LinhaArquivo, type LinhaUnidade } from './proposta/tabelaArquivos';
import { fmtMes, fmtPct, fmtReal, hojeISO, PERIODICIDADES, resolverCaptacao, somarMeses, type Periodicidade, type SerieCaptacao } from './proposta/motor';

const CLASSE_SIT: Record<SituacaoTabela, string> = { rascunho: 'st-rascunho', agendada: 'st-agendada', vigente: 'st-vigente', encerrada: 'st-encerrada' };
const SeloSit = ({ s }: { s: SituacaoTabela }) => <span className={`selo ${CLASSE_SIT[s]}`}>{ROTULO_SITUACAO[s]}</span>;
const dataHora = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString('pt-BR') : '—');
const editavel = (t: TabelaResumo) => t.situacao === 'rascunho' || t.situacao === 'agendada';
const num2 = (v: number) => v.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const lerNumero = (s: string) => { const n = Number(s.replace(/\./g, '').replace(',', '.')); return Number.isFinite(n) ? n : NaN; };
const amanha = () => { const d = new Date(); d.setDate(d.getDate() + 1); return hojeISO(d); };
const ORIGEM: Record<string, string> = { inicial: 'Carga inicial', arquivo: 'Arquivo', reajuste: 'Reajuste', copia: 'Cópia', manual: 'Manual' };

interface Base { comercial: { mes_entrega: string }; marca: { nome_empreendimento: string; logo_url: string | null; cor_destaque: string | null } | null }
interface ItemBanco { unidade_id: string; preco: number; captacao: number }
interface UnidadeBanco { id: string; numero: string; andar: number | null; tipologia: string | null; area_privativa: number | null; status: string }

export function TabelaVendas({ perfil }: { perfil: Perfil }) {
  const { avisar } = useDialogos();
  const admin = perfil.papel === 'admin';
  const equipe = admin || perfil.papel === 'vendas';
  const [tabelas, setTabelas] = useState<TabelaResumo[] | null>(null);
  const [base, setBase] = useState<Base | null>(null);
  const [aberta, setAberta] = useState<string | null>(null);
  const [nova, setNova] = useState(false);
  const [erro, setErro] = useState('');

  const carregar = useCallback(async () => {
    const [t, c, m] = await Promise.all([
      supabase.from('tabelas_preco_resumo').select('*').order('criada_em', { ascending: false }),
      supabase.from('comercial').select('mes_entrega').eq('id', 1).maybeSingle(),
      supabase.from('config').select('nome_empreendimento, logo_url, cor_destaque').eq('id', 1).maybeSingle(),
    ]);
    if (t.error) { setErro(t.error.message.includes('does not exist') ? 'O banco ainda não tem a tabela de vendas (migração 110).' : traduzirErro(t.error.message)); return; }
    setTabelas((t.data ?? []) as TabelaResumo[]);
    setBase({ comercial: c.data as Base['comercial'], marca: m.data as Base['marca'] });
  }, []);
  useEffect(() => { carregar(); }, [carregar]);

  const vigente = tabelas?.find((t) => t.situacao === 'vigente') ?? null;
  const proxima = tabelas?.find((t) => t.situacao === 'agendada') ?? null;
  useEffect(() => { if (aberta == null && vigente) setAberta(vigente.id); }, [vigente, aberta]);

  const pdf = async (t: TabelaResumo, somenteDisponiveis = false) => {
    if (!base) return;
    try {
      const [caps, itens, uns] = await Promise.all([
        carregarCaptacoes(t.id),
        supabase.from('tabelas_preco_itens').select('unidade_id, preco, captacao').eq('tabela_id', t.id),
        supabase.from('unidades').select('id, numero, andar, tipologia, area_privativa, status'),
      ]);
      const desde = t.vigente_desde ? t.vigente_desde.slice(0, 10) : hojeISO();
      const venda = mesDaVenda(t, desde > hojeISO() ? desde : hojeISO());
      const entrega = base.comercial.mes_entrega.slice(0, 7);
      const porId = new Map(((uns.data ?? []) as UnidadeBanco[]).map((u) => [u.id, u]));
      await gerarPdfTabela({
        empreendimento: base.marca?.nome_empreendimento ?? 'Empreendimento', tabela: t.nome,
        vigencia: t.situacao === 'vigente' ? `vigente desde ${dataHora(t.vigente_desde)}` : t.situacao === 'agendada' ? `vale a partir de ${dataHora(t.vigente_desde)}` : ROTULO_SITUACAO[t.situacao].toLowerCase(),
        mesVenda: venda, mesEntrega: entrega, logoUrl: base.marca?.logo_url, corDestaque: base.marca?.cor_destaque ?? undefined,
        captacoes: caps.map((c) => ({ numero: c.numero, nome: c.nome, series: resolverCaptacao(c.series, venda, entrega) })),
        unidades: ((itens.data ?? []) as ItemBanco[]).flatMap((i) => {
          const u = porId.get(i.unidade_id);
          return u ? [{ numero: u.numero, andar: u.andar, tipologia: u.tipologia, area: u.area_privativa, preco: Number(i.preco), captacao: i.captacao, status: u.status }] : [];
        }),
        somenteDisponiveis,
      });
    } catch { avisar('Não foi possível gerar o PDF.', 'erro'); }
  };

  if (erro) return <section className="secao"><p className="erro">{erro}</p></section>;
  if (!tabelas || !base) return <section className="secao"><p className="vazio">Carregando…</p></section>;
  const tabelaAberta = tabelas.find((t) => t.id === aberta) ?? null;

  return (
    <section className="secao tv">
      <div className="secao-topo">
        <div>
          <h2>Tabela de vendas</h2>
          <p className="sub">Preço de cada unidade e captações (fluxos de pagamento). A quantidade de parcelas acompanha o mês da venda até a entrega.</p>
        </div>
        {admin && <button className="botao principal" onClick={() => setNova(true)}><Plus size={16} /> Nova tabela</button>}
      </div>

      <div className="tv-cartoes">
        <CartaoTabela titulo="Tabela vigente" t={vigente} vazio="Nenhuma tabela vigente." aoPdf={pdf} aoAbrir={equipe ? setAberta : undefined} />
        <CartaoTabela titulo="Próxima tabela" t={proxima} vazio={admin ? 'Nenhuma tabela agendada. Crie uma nova tabela e agende a data de início.' : 'Nenhuma tabela agendada.'}
          aoPdf={pdf} aoAbrir={equipe ? setAberta : undefined} />
      </div>

      {nova && admin && <NovaTabela vigente={vigente} aoFechar={() => setNova(false)} aoCriar={(id) => { setNova(false); setAberta(id); carregar(); }} />}

      {equipe && (
        <>
          <h3 className="tv-titulo">Todas as tabelas</h3>
          <div className="tabela-rolagem">
            <table className="tabela">
              <thead><tr><th>Tabela</th><th>Situação</th><th>Vigência</th><th>Mês de referência</th><th className="dir">Unidades</th><th className="dir">VGV</th><th>Origem</th></tr></thead>
              <tbody>
                {tabelas.map((t) => (
                  <tr key={t.id} tabIndex={0} className={t.id === aberta ? 'tv-linha-aberta' : ''} onClick={() => setAberta(t.id)} onKeyDown={(e) => e.key === 'Enter' && setAberta(t.id)}>
                    <td><strong>{t.nome}</strong></td>
                    <td><SeloSit s={t.situacao} /></td>
                    <td className="nowrap">{t.vigente_desde ? (t.situacao === 'agendada' ? `a partir de ${dataHora(t.vigente_desde)}` : `desde ${dataHora(t.vigente_desde)}`) : '—'}</td>
                    <td>{fmtMes(t.mes_referencia.slice(0, 7))}</td>
                    <td className="dir mono">{t.unidades}</td>
                    <td className="dir mono">{fmtReal(Number(t.vgv))}</td>
                    <td>{ORIGEM[t.origem] ?? t.origem}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      {tabelaAberta && (equipe || tabelaAberta.situacao !== 'rascunho') && (
        <DetalheTabela key={tabelaAberta.id + tabelaAberta.atualizada_em} t={tabelaAberta} vigente={vigente} admin={admin} entrega={base.comercial.mes_entrega.slice(0, 7)}
          aoMudar={carregar} aoPdf={pdf} aoExcluir={() => { setAberta(vigente?.id ?? null); carregar(); }} />
      )}
    </section>
  );
}

function CartaoTabela({ titulo, t, vazio, aoPdf, aoAbrir }: {
  titulo: string; t: TabelaResumo | null; vazio: string; aoPdf: (t: TabelaResumo, disp?: boolean) => void; aoAbrir?: (id: string) => void;
}) {
  return (
    <div className={`cartao tv-cartao${t ? ` ${CLASSE_SIT[t.situacao]}` : ''}`}>
      <span className="kpi-rotulo">{titulo}</span>
      {t ? (
        <>
          <strong className="tv-nome">{t.nome}</strong>
          <span className="dica">{t.situacao === 'agendada' ? `Passa a valer em ${dataHora(t.vigente_desde)}, à 0h` : `Desde ${dataHora(t.vigente_desde)}`} · {t.unidades} unidades · VGV {fmtReal(Number(t.vgv))}</span>
          <div className="botoes-linha">
            <button className="botao pequeno" onClick={() => aoPdf(t)}><FileDown size={14} /> PDF</button>
            <button className="botao pequeno" onClick={() => aoPdf(t, true)} title="Só as unidades disponíveis no espelho"><FileDown size={14} /> PDF das disponíveis</button>
            {aoAbrir && <button className="botao pequeno" onClick={() => aoAbrir(t.id)}>Abrir</button>}
          </div>
        </>
      ) : <span className="dica">{vazio}</span>}
    </div>
  );
}

// ---------------------------------------------------------------------
function NovaTabela({ vigente, aoFechar, aoCriar }: { vigente: TabelaResumo | null; aoFechar: () => void; aoCriar: (id: string) => void }) {
  const { avisar } = useDialogos();
  const proxMes = somarMeses(hojeISO(), 1);
  const [nome, setNome] = useState(`Tabela ${proxMes.slice(5, 7)}/${proxMes.slice(0, 4)}`);
  const [mes, setMes] = useState(proxMes);
  const [copiar, setCopiar] = useState(!!vigente);
  const [reajuste, setReajuste] = useState('');
  const [salvando, setSalvando] = useState(false);
  const criar = async () => {
    const r = reajuste.trim() ? lerNumero(reajuste) / 100 : null;
    if (r != null && (!Number.isFinite(r) || r <= -0.5 || r > 1)) { avisar('Reajuste inválido.', 'erro'); return; }
    setSalvando(true);
    const { data, error } = await supabase.rpc('nova_tabela', {
      p_nome: nome, p_mes: `${mes}-01`, p_base: copiar ? vigente?.id ?? null : null, p_reajuste: copiar ? r : null,
    });
    setSalvando(false);
    if (error) { avisar(traduzirErro(error.message), 'erro'); return; }
    avisar('Tabela criada em rascunho.');
    aoCriar(data as string);
  };
  return (
    <div className="cartao tv-nova">
      <div className="cartao-topo"><h3>Nova tabela</h3><button className="icone-botao" onClick={aoFechar} aria-label="Fechar"><X size={16} /></button></div>
      <div className="tv-form">
        <label>Nome<input value={nome} onChange={(e) => setNome(e.target.value)} /></label>
        <label>Mês de referência<input type="month" value={mes} onChange={(e) => setMes(e.target.value)} /></label>
        {vigente && (
          <label className="tv-check"><input type="checkbox" checked={copiar} onChange={(e) => setCopiar(e.target.checked)} /> Copiar preços e captações da vigente ({vigente.nome})</label>
        )}
        {copiar && vigente && <label>Reajuste em todas as unidades (%)<input value={reajuste} onChange={(e) => setReajuste(e.target.value)} placeholder="ex.: 1,5 (opcional)" inputMode="decimal" /></label>}
      </div>
      <p className="dica">A tabela nasce em rascunho e não muda nada até ser ativada. {copiar ? 'Depois dá para reajustar só algumas unidades ou carregar um arquivo.' : 'Cadastre as captações e carregue os preços pelo arquivo base.'}</p>
      <div className="botoes-linha"><button className="botao principal" onClick={criar} disabled={salvando || nome.trim().length < 2}>Criar tabela</button></div>
    </div>
  );
}

// ---------------------------------------------------------------------
function DetalheTabela({ t, vigente, admin, entrega, aoMudar, aoPdf, aoExcluir }: {
  t: TabelaResumo; vigente: TabelaResumo | null; admin: boolean; entrega: string;
  aoMudar: () => void; aoPdf: (t: TabelaResumo, disp?: boolean) => void; aoExcluir: () => void;
}) {
  const { avisar, confirmar } = useDialogos();
  const pode = admin && editavel(t);
  const [aba, setAba] = useState<'unidades' | 'captacoes'>('unidades');
  const [caps, setCaps] = useState<CaptacaoBanco[] | null>(null);
  const [linhas, setLinhas] = useState<LinhaUnidade[] | null>(null);
  const [precoVig, setPrecoVig] = useState<Map<string, number>>(new Map());
  const [agendar, setAgendar] = useState('');
  const [leitura, setLeitura] = useState<{ linhas: LinhaArquivo[]; erros: string[]; ignoradas: number; nome: string } | null>(null);
  const [ocupado, setOcupado] = useState(false);
  const arquivo = useRef<HTMLInputElement>(null);

  const carregar = useCallback(async () => {
    const [c, it, us, iv] = await Promise.all([
      carregarCaptacoes(t.id),
      supabase.from('tabelas_preco_itens').select('unidade_id, preco, captacao').eq('tabela_id', t.id),
      supabase.from('unidades').select('id, numero, andar, tipologia, area_privativa, status').order('andar').order('posicao'),
      vigente && vigente.id !== t.id ? supabase.from('tabelas_preco_itens').select('unidade_id, preco').eq('tabela_id', vigente.id) : Promise.resolve({ data: [] }),
    ]);
    setCaps(c);
    const porId = new Map(((it.data ?? []) as ItemBanco[]).map((i) => [i.unidade_id, i]));
    setLinhas(((us.data ?? []) as UnidadeBanco[]).map((u) => ({
      unidade_id: u.id, numero: u.numero, andar: u.andar, tipologia: u.tipologia, area: u.area_privativa != null ? Number(u.area_privativa) : null,
      status: u.status, preco: porId.has(u.id) ? Number(porId.get(u.id)!.preco) : null, captacao: porId.get(u.id)?.captacao ?? null,
    })));
    setPrecoVig(new Map(((iv.data ?? []) as { unidade_id: string; preco: number }[]).map((x) => [x.unidade_id, Number(x.preco)])));
  }, [t.id, vigente]);
  useEffect(() => { carregar(); }, [carregar]);

  const rpc = async (fn: string, args: Record<string, unknown>, ok: string) => {
    setOcupado(true);
    const { data, error } = await supabase.rpc(fn, args);
    setOcupado(false);
    if (error) { avisar(`${traduzirErro(error.message)}${error.details ? ` (${error.details})` : ''}`, 'erro'); return null; }
    if (ok) avisar(ok);
    return data ?? true;
  };

  const ativarAgora = async () => {
    if (!(await confirmar({ titulo: `Ativar ${t.nome} agora?`, texto: `A partir deste momento, novas propostas e o PDF usam esta tabela${vigente ? `; a ${vigente.nome} fica encerrada. Rascunhos na tabela antiga precisarão ser atualizados para serem enviados` : ''}.`, confirmar: 'Ativar agora' }))) return;
    if (await rpc('ativar_tabela', { p_tabela: t.id, p_data: null }, 'Tabela ativada.')) aoMudar();
  };
  const agendarData = async () => {
    if (!agendar) return;
    const dia = agendar.split('-').reverse().join('/');
    if (!(await confirmar({ titulo: `Agendar ${t.nome}?`, texto: `Ela passa a valer em ${dia}, à 0h (Brasília). Até lá, a tabela atual continua valendo e esta fica disponível para consulta.`, confirmar: 'Agendar' }))) return;
    if (await rpc('ativar_tabela', { p_tabela: t.id, p_data: agendar }, `Tabela agendada para ${dia}.`)) aoMudar();
  };
  const cancelar = async () => { if (await rpc('cancelar_agendamento', { p_tabela: t.id }, 'Agendamento cancelado; a tabela voltou para rascunho.')) aoMudar(); };
  const excluir = async () => {
    if (!(await confirmar({ titulo: `Excluir ${t.nome}?`, texto: 'O rascunho será apagado.', confirmar: 'Excluir', perigo: true }))) return;
    if (await rpc('excluir_tabela', { p_tabela: t.id }, 'Tabela excluída.')) aoExcluir();
  };
  const copiar = async () => {
    const m = somarMeses(hojeISO(), 1);
    const id = await rpc('nova_tabela', { p_nome: `Tabela ${m.slice(5, 7)}/${m.slice(0, 4)}`, p_mes: `${m}-01`, p_base: t.id }, 'Nova tabela criada em rascunho a partir desta.');
    if (id) aoMudar();
  };

  const baixarBase = async () => {
    if (!linhas || !caps) return;
    try { await baixarArquivoBase(`Tabela base - ${t.nome.replace(/[\\/:*?"<>|]/g, '-')}.xlsx`, linhas, caps.map((c) => ({ numero: c.numero, nome: c.nome }))); }
    catch { avisar('Não foi possível gerar o arquivo.', 'erro'); }
  };
  const escolherArquivo = async (f: File | undefined) => {
    if (!f || !linhas || !caps) return;
    try {
      const r = await lerArquivo(f, new Set(linhas.map((l) => l.numero)), new Set(caps.map((c) => c.numero)));
      setLeitura({ ...r, nome: f.name });
    } catch { avisar('Não consegui ler o arquivo. Use o arquivo base em Excel (.xlsx).', 'erro'); }
    if (arquivo.current) arquivo.current.value = '';
  };
  const confirmarCarga = async () => {
    if (!leitura) return;
    const r = await rpc('importar_tabela', { p_tabela: t.id, p_linhas: leitura.linhas }, '');
    if (r) {
      const x = r as { precos: number; unidades_atualizadas: number };
      avisar(`Carga feita: ${x.precos} preços gravados${x.unidades_atualizadas ? `, ${x.unidades_atualizadas} unidades com área/tipologia atualizadas` : ''}.`);
      setLeitura(null); carregar(); aoMudar();
    }
  };

  const semPreco = linhas?.filter((l) => l.preco == null).length ?? 0;
  const venda = mesDaVenda(t, t.vigente_desde && t.vigente_desde.slice(0, 10) > hojeISO() ? t.vigente_desde.slice(0, 10) : hojeISO());

  return (
    <div className="cartao tv-detalhe">
      <div className="cartao-topo tv-detalhe-topo">
        <div>
          <h3>{t.nome} <SeloSit s={t.situacao} /></h3>
          <p className="dica">
            Referência {fmtMes(t.mes_referencia.slice(0, 7))} · criada por {t.criada_por ?? '—'} em {dataHora(t.criada_em)}
            {t.vigente_desde && ` · ${t.situacao === 'agendada' ? 'vale a partir de' : 'ativada em'} ${dataHora(t.vigente_desde)}${t.ativada_por ? ` por ${t.ativada_por}` : ''}`}
          </p>
        </div>
        <div className="botoes-linha">
          <button className="botao pequeno" onClick={() => aoPdf(t)}><FileDown size={14} /> PDF</button>
          {admin && <button className="botao pequeno" onClick={baixarBase} disabled={!linhas}><Download size={14} /> Baixar arquivo base</button>}
          {pode && <button className="botao pequeno" onClick={() => arquivo.current?.click()} disabled={!caps?.length} title={caps?.length ? '' : 'Cadastre as captações antes'}><Upload size={14} /> Carregar arquivo</button>}
          {admin && !pode && <button className="botao pequeno" onClick={copiar} disabled={ocupado}><Copy size={14} /> Nova tabela a partir desta</button>}
          <input ref={arquivo} type="file" accept=".xlsx" hidden onChange={(e) => escolherArquivo(e.target.files?.[0])} />
        </div>
      </div>

      {pode && (
        <div className="tv-vigencia">
          {t.situacao === 'agendada' ? (
            <>
              <span><CalendarClock size={15} /> Agendada para {dataHora(t.vigente_desde)}, à 0h. Até lá a tabela atual continua valendo.</span>
              <button className="botao pequeno principal" onClick={ativarAgora} disabled={ocupado}><Power size={14} /> Ativar agora</button>
              <button className="botao pequeno" onClick={cancelar} disabled={ocupado}>Cancelar agendamento</button>
            </>
          ) : (
            <>
              <span>{semPreco ? `${semPreco} unidade(s) sem preço: complete antes de ativar.` : 'Pronta para valer.'}</span>
              <button className="botao pequeno principal" onClick={ativarAgora} disabled={ocupado || semPreco > 0}><Power size={14} /> Ativar agora</button>
              <label className="tv-agendar">ou a partir de <input type="date" value={agendar} min={amanha()} onChange={(e) => setAgendar(e.target.value)} /></label>
              <button className="botao pequeno" onClick={agendarData} disabled={ocupado || !agendar || semPreco > 0}><CalendarClock size={14} /> Agendar</button>
              <button className="botao pequeno perigo-texto" onClick={excluir} disabled={ocupado}><Trash2 size={14} /> Excluir rascunho</button>
            </>
          )}
        </div>
      )}

      {leitura && (
        <PreviaArquivo leitura={leitura} linhas={linhas ?? []} aoCancelar={() => setLeitura(null)} aoConfirmar={confirmarCarga} ocupado={ocupado} />
      )}

      <div className="abas" role="tablist">
        <button className={aba === 'unidades' ? 'ativa' : ''} onClick={() => setAba('unidades')}>Unidades e preços</button>
        <button className={aba === 'captacoes' ? 'ativa' : ''} onClick={() => setAba('captacoes')}>Captações ({caps?.length ?? 0} de 3)</button>
      </div>
      {!linhas || !caps ? <p className="vazio">Carregando…</p> : aba === 'unidades' ? (
        <GradeUnidades t={t} linhas={linhas} caps={caps} precoVig={precoVig} pode={pode} rpc={rpc} aoMudar={() => { carregar(); aoMudar(); }} />
      ) : (
        <EditorCaptacoes t={t} caps={caps} pode={pode} venda={venda} entrega={entrega} rpc={rpc} aoMudar={() => { carregar(); aoMudar(); }} />
      )}
    </div>
  );
}

function PreviaArquivo({ leitura, linhas, aoCancelar, aoConfirmar, ocupado }: {
  leitura: { linhas: LinhaArquivo[]; erros: string[]; ignoradas: number; nome: string }; linhas: LinhaUnidade[];
  aoCancelar: () => void; aoConfirmar: () => void; ocupado: boolean;
}) {
  const atual = new Map(linhas.map((l) => [l.numero, l]));
  let alterados = 0, novos = 0, iguais = 0, infos = 0;
  for (const l of leitura.linhas) {
    const a = atual.get(l.numero);
    if (!a || a.preco == null) novos++;
    else if (Math.abs(a.preco - l.preco) > 0.004 || a.captacao !== l.captacao) alterados++;
    else iguais++;
    if (a && ((l.area != null && l.area !== a.area) || (l.tipologia && l.tipologia !== a.tipologia))) infos++;
  }
  const fora = linhas.filter((l) => l.preco != null && !leitura.linhas.some((x) => x.numero === l.numero)).length;
  const vgv = leitura.linhas.reduce((s, l) => s + l.preco, 0);
  return (
    <div className={`tv-previa${leitura.erros.length ? ' com-erro' : ''}`}>
      <strong>Arquivo {leitura.nome}</strong>
      <ul>
        <li>{leitura.linhas.length} linhas válidas · VGV do arquivo {fmtReal(vgv)}</li>
        <li>{novos} preços novos · {alterados} alterados · {iguais} sem mudança{infos ? ` · ${infos} com área/tipologia nova` : ''}</li>
        {fora > 0 && <li>{fora} unidade(s) com preço na tabela não vieram no arquivo e ficam como estão.</li>}
        {leitura.ignoradas > 0 && <li>{leitura.ignoradas} linha(s) sem preço foram ignoradas.</li>}
      </ul>
      {leitura.erros.length > 0 && (
        <>
          <p className="erro">Corrija o arquivo e carregue de novo ({leitura.erros.length} problema{leitura.erros.length > 1 ? 's' : ''}):</p>
          <ul className="tv-erros">{leitura.erros.slice(0, 15).map((e) => <li key={e}>{e}</li>)}{leitura.erros.length > 15 && <li>… e mais {leitura.erros.length - 15}</li>}</ul>
        </>
      )}
      <div className="botoes-linha">
        <button className="botao pequeno" onClick={aoCancelar}>Cancelar</button>
        <button className="botao pequeno principal" onClick={aoConfirmar} disabled={ocupado || leitura.erros.length > 0 || !leitura.linhas.length}>Gravar na tabela</button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------
type Rpc = (fn: string, args: Record<string, unknown>, ok: string) => Promise<unknown>;

function GradeUnidades({ t, linhas, caps, precoVig, pode, rpc, aoMudar }: {
  t: TabelaResumo; linhas: LinhaUnidade[]; caps: CaptacaoBanco[]; precoVig: Map<string, number>; pode: boolean; rpc: Rpc; aoMudar: () => void;
}) {
  const [busca, setBusca] = useState('');
  const [fCap, setFCap] = useState('');
  const [fTip, setFTip] = useState('');
  const [deAndar, setDeAndar] = useState('');
  const [ateAndar, setAteAndar] = useState('');
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [pct, setPct] = useState('');
  const [alvo, setAlvo] = useState<'todas' | 'filtradas' | 'selecionadas'>('todas');
  const tipologias = useMemo(() => Array.from(new Set(linhas.map((l) => l.tipologia).filter(Boolean))) as string[], [linhas]);
  const nomeCap = (n: number | null) => caps.find((c) => c.numero === n)?.nome ?? (n ? `Captação ${n}` : '—');
  const comparar = precoVig.size > 0;

  const filtradas = linhas.filter((l) =>
    (!busca || l.numero.includes(busca.trim())) && (!fCap || String(l.captacao ?? '') === fCap) && (!fTip || l.tipologia === fTip)
    && (!deAndar || (l.andar ?? 0) >= Number(deAndar)) && (!ateAndar || (l.andar ?? 0) <= Number(ateAndar)));
  const temFiltro = !!(busca || fCap || fTip || deAndar || ateAndar);
  const vgv = filtradas.reduce((s, l) => s + (l.preco ?? 0), 0);
  const area = filtradas.reduce((s, l) => s + (l.preco != null ? l.area ?? 0 : 0), 0);

  const aplicar = async () => {
    const p = lerNumero(pct) / 100;
    if (!Number.isFinite(p) || p === 0 || p <= -0.5 || p > 1) return;
    const ids = alvo === 'todas' ? null : alvo === 'filtradas' ? filtradas.map((l) => l.unidade_id) : Array.from(sel);
    const n = await rpc('reajustar_tabela', { p_tabela: t.id, p_pct: p, p_unidades: ids }, '');
    if (n != null) { setPct(''); setSel(new Set()); aoMudar(); }
  };
  const definir = async (l: LinhaUnidade, preco: number | null, cap: number | null) => {
    if (preco == null || cap == null) return;
    if (await rpc('definir_item_tabela', { p_tabela: t.id, p_unidade: l.unidade_id, p_preco: preco, p_captacao: cap }, '')) aoMudar();
  };
  const alternar = (id: string) => setSel((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  const nAlvo = alvo === 'todas' ? linhas.filter((l) => l.preco != null).length : alvo === 'filtradas' ? filtradas.length : sel.size;

  return (
    <>
      <div className="filtros">
        <input placeholder="Buscar unidade" value={busca} onChange={(e) => setBusca(e.target.value)} />
        <select value={fCap} onChange={(e) => setFCap(e.target.value)}><option value="">Todas as captações</option>{caps.map((c) => <option key={c.numero} value={c.numero}>{c.nome}</option>)}</select>
        {tipologias.length > 1 && <select value={fTip} onChange={(e) => setFTip(e.target.value)}><option value="">Todas as tipologias</option>{tipologias.map((x) => <option key={x}>{x}</option>)}</select>}
        <input className="tv-andar" placeholder="Andar de" value={deAndar} onChange={(e) => setDeAndar(e.target.value.replace(/\D/g, ''))} inputMode="numeric" />
        <input className="tv-andar" placeholder="até" value={ateAndar} onChange={(e) => setAteAndar(e.target.value.replace(/\D/g, ''))} inputMode="numeric" />
      </div>
      {pode && (
        <div className="tv-reajuste">
          <span>Reajustar</span>
          <input value={pct} onChange={(e) => setPct(e.target.value)} placeholder="%" inputMode="decimal" />
          <span>% em</span>
          <select value={alvo} onChange={(e) => setAlvo(e.target.value as typeof alvo)}>
            <option value="todas">todas as unidades</option>
            <option value="filtradas" disabled={!temFiltro}>as filtradas ({filtradas.length})</option>
            <option value="selecionadas" disabled={!sel.size}>as selecionadas ({sel.size})</option>
          </select>
          <button className="botao pequeno principal" onClick={aplicar} disabled={!pct.trim() || !nAlvo}>Aplicar em {nAlvo} unidade{nAlvo === 1 ? '' : 's'}</button>
          <span className="dica">Use número negativo para reduzir. Arredonda no centavo.</span>
        </div>
      )}
      <div className="tabela-rolagem tv-grade">
        <table className="tabela">
          <thead>
            <tr>
              {pode && <th><input type="checkbox" aria-label="Selecionar as filtradas" checked={filtradas.length > 0 && filtradas.every((l) => sel.has(l.unidade_id))}
                onChange={(e) => setSel(e.target.checked ? new Set(filtradas.map((l) => l.unidade_id)) : new Set())} /></th>}
              <th>Unidade</th><th>Andar</th><th>Tipologia</th><th className="dir">Área m²</th><th className="dir">Preço</th><th className="dir">R$/m²</th><th>Captação</th>
              {comparar && <th className="dir">vs. vigente</th>}
            </tr>
          </thead>
          <tbody>
            {filtradas.map((l) => {
              const v = precoVig.get(l.unidade_id);
              return (
                <tr key={l.unidade_id} className={l.preco == null ? 'tv-sem-preco' : ''}>
                  {pode && <td><input type="checkbox" checked={sel.has(l.unidade_id)} onChange={() => alternar(l.unidade_id)} aria-label={`Selecionar ${l.numero}`} /></td>}
                  <td className="mono"><strong>{l.numero}</strong></td>
                  <td>{l.andar != null ? `${l.andar}º` : ''}</td>
                  <td>{l.tipologia ?? ''}</td>
                  <td className="dir mono">{l.area != null ? num2(l.area) : '—'}</td>
                  <td className="dir mono">
                    {pode ? <CampoPreco valor={l.preco} aoSalvar={(p) => definir(l, p, l.captacao ?? caps[0]?.numero ?? null)} /> : l.preco != null ? num2(l.preco) : '—'}
                  </td>
                  <td className="dir mono">{l.preco != null && l.area ? num2(l.preco / l.area) : '—'}</td>
                  <td>
                    {pode ? (
                      <select value={l.captacao ?? ''} onChange={(e) => definir(l, l.preco, Number(e.target.value))} disabled={l.preco == null} title={l.preco == null ? 'Informe o preço primeiro' : ''}>
                        {l.captacao == null && <option value="">—</option>}
                        {caps.map((c) => <option key={c.numero} value={c.numero}>{c.nome}</option>)}
                      </select>
                    ) : nomeCap(l.captacao)}
                  </td>
                  {comparar && <td className={`dir mono ${v != null && l.preco != null && l.preco < v ? 'texto-ruim' : ''}`}>{v != null && l.preco != null ? fmtPct(l.preco / v - 1, 2) : '—'}</td>}
                </tr>
              );
            })}
          </tbody>
          <tfoot>
            <tr>
              {pode && <td />}
              <td colSpan={4}>{filtradas.length} unidade{filtradas.length === 1 ? '' : 's'}{temFiltro ? ' (filtradas)' : ''}</td>
              <td className="dir mono">{fmtReal(vgv)}</td>
              <td className="dir mono">{area ? num2(vgv / area) : '—'}</td>
              <td colSpan={comparar ? 2 : 1} />
            </tr>
          </tfoot>
        </table>
      </div>
    </>
  );
}

function CampoPreco({ valor, aoSalvar }: { valor: number | null; aoSalvar: (v: number) => void }) {
  const [txt, setTxt] = useState(valor != null ? num2(valor) : '');
  useEffect(() => setTxt(valor != null ? num2(valor) : ''), [valor]);
  const sair = () => {
    const n = lerNumero(txt);
    if (!txt.trim()) { setTxt(valor != null ? num2(valor) : ''); return; }
    if (!Number.isFinite(n) || n <= 0) { setTxt(valor != null ? num2(valor) : ''); return; }
    if (valor == null || Math.abs(n - valor) > 0.004) aoSalvar(Math.round(n * 100) / 100);
  };
  return <input className="tv-preco" value={txt} onChange={(e) => setTxt(e.target.value)} onBlur={sair} onKeyDown={(e) => e.key === 'Enter' && (e.target as HTMLInputElement).blur()} inputMode="decimal" placeholder="preço" />;
}

// ---------------------------------------------------------------------
interface SerieEdit { rotulo: string; periodicidade: Periodicidade; pct: string; base: 'venda' | 'entrega'; meses: string; auto: boolean; qtd: string; fim: string }
interface CapEdit { numero: number; nome: string; series: SerieEdit[] }
const PERIODOS = PERIODICIDADES.filter((p) => p.valor !== 'Permuta');
const AUTOMATICAVEIS: Periodicidade[] = ['Mensais', 'Bimestrais', 'Trimestrais', 'Semestrais', 'Anuais'];
const paraEdicao = (c: CaptacaoBanco): CapEdit => ({
  numero: c.numero, nome: c.nome,
  series: c.series.map((s) => ({
    rotulo: s.rotulo, periodicidade: s.periodicidade, pct: (Math.round(s.percentual * 1e6) / 1e4).toLocaleString('pt-BR', { maximumFractionDigits: 4 }),
    base: s.inicio.base, meses: String(s.inicio.meses), auto: s.qtd == null, qtd: String(s.qtd ?? ''), fim: String(s.fimMeses ?? 0),
  })),
});
const MODELO: SerieEdit[] = [
  { rotulo: 'Ato', periodicidade: 'Sinal', pct: '4', base: 'venda', meses: '0', auto: false, qtd: '1', fim: '0' },
  { rotulo: '30 / 60 / 90', periodicidade: 'Sinal', pct: '4', base: 'venda', meses: '1', auto: false, qtd: '3', fim: '0' },
  { rotulo: 'Mensais', periodicidade: 'Mensais', pct: '6', base: 'venda', meses: '4', auto: true, qtd: '', fim: '0' },
  { rotulo: 'Semestrais', periodicidade: 'Semestrais', pct: '12', base: 'venda', meses: '5', auto: true, qtd: '', fim: '-1' },
  { rotulo: 'Única', periodicidade: 'Unica', pct: '4', base: 'entrega', meses: '-3', auto: false, qtd: '1', fim: '0' },
  { rotulo: 'Financiamento', periodicidade: 'Financiamento', pct: '70', base: 'entrega', meses: '1', auto: false, qtd: '1', fim: '0' },
];
const paraSerie = (s: SerieEdit): SerieCaptacao | null => {
  const p = lerNumero(s.pct) / 100, meses = Number(s.meses), qtd = Number(s.qtd), fim = Number(s.fim);
  if (!Number.isFinite(p) || p <= 0 || !Number.isInteger(meses)) return null;
  if (s.auto ? !Number.isInteger(fim) : !(Number.isInteger(qtd) && qtd >= 1)) return null;
  return { rotulo: s.rotulo || s.periodicidade, periodicidade: s.periodicidade, percentual: p, qtd: s.auto ? null : qtd, fimMeses: s.auto ? fim : null, inicio: { base: s.base, meses } };
};

function EditorCaptacoes({ t, caps, pode, venda, entrega, rpc, aoMudar }: {
  t: TabelaResumo; caps: CaptacaoBanco[]; pode: boolean; venda: string; entrega: string; rpc: Rpc; aoMudar: () => void;
}) {
  const [ed, setEd] = useState<CapEdit[]>(() => caps.map(paraEdicao));
  const [sujo, setSujo] = useState(false);
  const mudar = (f: (x: CapEdit[]) => CapEdit[]) => { setEd((x) => f(structuredClone(x))); setSujo(true); };
  const somas = ed.map((c) => c.series.reduce((s, x) => s + (lerNumero(x.pct) || 0), 0));
  const invalidas = ed.some((c) => c.series.some((s) => !paraSerie(s)));
  const ok = ed.length >= 1 && somas.every((s) => Math.abs(s - 100) < 0.0001) && !invalidas;

  const salvar = async () => {
    const p = ed.map((c) => ({
      numero: c.numero, nome: c.nome,
      series: c.series.map((s) => { const x = paraSerie(s)!; return { rotulo: x.rotulo, periodicidade: x.periodicidade, percentual: x.percentual, qtd: x.qtd, base: x.inicio.base, meses: x.inicio.meses, fim_meses: x.fimMeses }; }),
    }));
    if (await rpc('salvar_captacoes', { p_tabela: t.id, p }, 'Captações salvas.')) { setSujo(false); aoMudar(); }
  };
  const proximoNumero = [1, 2, 3].find((n) => !ed.some((c) => c.numero === n));

  return (
    <>
      <p className="dica">
        Cada captação soma 100% do preço. Em quantidade <strong>automática</strong>, as parcelas vão da 1ª até a entrega (± meses de folga) e são recalculadas pelo mês da venda.
        Prévia para vendas em <strong>{fmtMes(venda)}</strong>, com entrega em {fmtMes(entrega)}.
      </p>
      <div className="tv-caps">
        {ed.map((c, ci) => {
          const resolvidas = (() => { const ss = c.series.map(paraSerie); return ss.every(Boolean) ? resolverCaptacao(ss as SerieCaptacao[], venda, entrega) : null; })();
          return (
            <div key={c.numero} className="tv-cap">
              <div className="tv-cap-topo">
                <span className="tv-cap-num">{c.numero}</span>
                {pode ? <input value={c.nome} onChange={(e) => mudar((x) => { x[ci].nome = e.target.value; return x; })} /> : <strong>{c.nome}</strong>}
                <span className={`tv-soma ${Math.abs(somas[ci] - 100) < 0.0001 ? 'ok' : 'ruim'}`}>{somas[ci].toLocaleString('pt-BR', { maximumFractionDigits: 4 })}%</span>
                {pode && ed.length > 1 && <button className="icone-botao" onClick={() => mudar((x) => x.filter((_, i) => i !== ci))} aria-label={`Remover ${c.nome}`}><Trash2 size={15} /></button>}
              </div>
              <div className="tabela-rolagem">
                <table className="tabela tv-series">
                  <thead><tr><th>Série</th><th>Tipo</th><th className="dir">%</th><th>1ª parcela</th><th>Quantidade</th><th>Prévia</th>{pode && <th />}</tr></thead>
                  <tbody>
                    {c.series.map((s, si) => {
                      const r = resolvidas?.[si];
                      const ini = r ? somarMeses(r.inicio.base === 'venda' ? venda : entrega, r.inicio.meses) : null;
                      const set = (k: keyof SerieEdit, v: string | boolean) => mudar((x) => { (x[ci].series[si] as unknown as Record<string, unknown>)[k] = v; if (k === 'periodicidade') { if (!AUTOMATICAVEIS.includes(v as Periodicidade)) x[ci].series[si].auto = false; x[ci].series[si].fim = v === 'Semestrais' || v === 'Anuais' ? '-1' : '0'; } return x; });
                      return (
                        <tr key={si}>
                          <td>{pode ? <input className="tv-rot" value={s.rotulo} onChange={(e) => set('rotulo', e.target.value)} /> : s.rotulo}</td>
                          <td>{pode ? <select value={s.periodicidade} onChange={(e) => set('periodicidade', e.target.value)}>{PERIODOS.map((p) => <option key={p.valor} value={p.valor}>{p.rotulo}</option>)}</select> : PERIODOS.find((p) => p.valor === s.periodicidade)?.rotulo}</td>
                          <td className="dir">{pode ? <input className="tv-num" value={s.pct} onChange={(e) => set('pct', e.target.value)} inputMode="decimal" /> : `${s.pct}%`}</td>
                          <td className="nowrap">
                            {pode ? (
                              <><input className="tv-num" value={s.meses} onChange={(e) => set('meses', e.target.value)} inputMode="numeric" /> meses
                                <select value={s.base} onChange={(e) => set('base', e.target.value)}><option value="venda">após a venda</option><option value="entrega">da entrega</option></select></>
                            ) : `${s.meses} meses ${s.base === 'venda' ? 'após a venda' : 'da entrega'}`}
                          </td>
                          <td className="nowrap">
                            {pode ? (
                              <>
                                <select value={s.auto ? 'auto' : 'fixa'} onChange={(e) => set('auto', e.target.value === 'auto')}>
                                  <option value="fixa">Fixa</option>
                                  {AUTOMATICAVEIS.includes(s.periodicidade) && <option value="auto">Automática</option>}
                                </select>
                                {s.auto
                                  ? <> até a entrega <input className="tv-num" value={s.fim} onChange={(e) => set('fim', e.target.value)} inputMode="numeric" title="Meses em relação à entrega: 0 = pode vencer no mês da entrega; -1 = até o mês anterior (padrão de semestrais e anuais)" /> meses</>
                                  : <input className="tv-num" value={s.qtd} onChange={(e) => set('qtd', e.target.value)} inputMode="numeric" />}
                              </>
                            ) : s.auto ? `Automática (até entrega ${Number(s.fim) >= 0 ? '+' : ''}${s.fim} m)` : `${s.qtd}×`}
                          </td>
                          <td className="nowrap dica">{r && ini ? `${r.qtd}× a partir de ${fmtMes(ini)}` : '—'}</td>
                          {pode && <td><button className="icone-botao" onClick={() => mudar((x) => { x[ci].series.splice(si, 1); return x; })} aria-label="Remover série"><X size={14} /></button></td>}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
              {pode && <button className="botao pequeno" onClick={() => mudar((x) => { x[ci].series.push({ rotulo: 'Nova série', periodicidade: 'Unica', pct: '0', base: 'venda', meses: '0', auto: false, qtd: '1', fim: '0' }); return x; })}><Plus size={14} /> Série</button>}
            </div>
          );
        })}
      </div>
      {pode && (
        <div className="botoes-linha">
          {proximoNumero && <button className="botao" onClick={() => mudar((x) => [...x, { numero: proximoNumero, nome: `Captação ${proximoNumero}`, series: structuredClone(MODELO) }].sort((a, b) => a.numero - b.numero))}><Plus size={15} /> Captação</button>}
          <button className="botao principal" onClick={salvar} disabled={!sujo || !ok}>Salvar captações</button>
          {sujo && !ok && <span className="erro">Cada captação precisa somar 100% e ter todos os campos válidos.</span>}
        </div>
      )}
      {!pode && t.situacao !== 'rascunho' && <p className="dica">Tabela {ROTULO_SITUACAO[t.situacao].toLowerCase()}: para mudar as captações, crie uma nova tabela a partir desta.</p>}
    </>
  );
}
