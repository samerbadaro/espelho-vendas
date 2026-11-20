// Envelope único de assinatura da pasta (D4Sign): Quadro Resumo como principal,
// Normas, Carta Proposta e documentos fixos como anexos. Montar → conferir prévia →
// assinantes e ordem → enviar → acompanhar → pacote assinado.
import { useCallback, useEffect, useState } from 'react';
import { ArrowDown, ArrowUp, CheckCircle2, Clock, Download, Eye, FileArchive, Package, Plus, RefreshCw, Send, Trash2 } from 'lucide-react';
import { supabase, formatarDataHora } from '../dados';
import { useDialogos } from '../ui';
import { formatarTelefone } from '../util';
import type { DadosContrato as Dados } from './leitura';

export interface DocEmitido { id: string; numero: number; documento: string; nome: string; versao: number; validacao: string; assinatura: string; cancelado_em: string | null }
interface Fixo { id: string; nome: string; arquivo: string | null; ordem: number }
interface EnvelopeRow {
  id: string; status: 'preparado' | 'enviado' | 'assinado' | 'cancelado'; documentos: { tipo: string; id: string; nome: string; versao?: number; arquivo: string }[];
  criado_em: string; criado_por: string | null; enviado_em: string | null; assinado_em: string | null; caminho_assinado: string | null; cancelado_em: string | null;
}
interface Assinante { id?: number; ordem: number; papel: string; nome: string; email: string; whatsapp: string; canal: 'email' | 'whatsapp'; testemunha?: boolean; assinado?: boolean; assinado_em?: string | null }

async function d4(corpo: Record<string, unknown>): Promise<{ erro?: string; url?: string; configurado?: boolean; ambiente?: string; assinados?: number; total?: number }> {
  const { data } = await supabase.auth.getSession();
  try {
    const r = await fetch('/api/d4sign', { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${data.session?.access_token ?? ''}` }, body: JSON.stringify(corpo) });
    return await r.json();
  } catch { return { erro: 'Sem conexão com o servidor.' }; }
}

const SITUACAO: Record<string, [string, string]> = {
  preparado: ['Montado na D4Sign — conferir prévia', 'sp-em_analise'], enviado: ['Aguardando assinaturas', 'sp-aguardando_analise'],
  assinado: ['Assinado por todos', 'sp-aprovada'], cancelado: ['Cancelado', 'sp-pendente_correcao'],
};
const ORDEM_DOC: Record<string, number> = { quadro_resumo: 0, normas: 1, carta_proposta: 2 };
const NOME_ESPERADO: Record<string, string> = { quadro_resumo: 'Quadro Resumo', normas: 'Normas Contratuais', carta_proposta: 'Carta Proposta' };

export function EnvelopeAssinatura({ pastaId, documentos, dados, temConjuge, pj, emp, imobiliariaId, aoMudar }: {
  pastaId: string; documentos: DocEmitido[]; dados: Dados; temConjuge: boolean; pj: boolean; emp: Record<string, string>; imobiliariaId: string | null; aoMudar: () => void;
}) {
  const { avisar, confirmar } = useDialogos();
  const [sit, setSit] = useState<{ configurado: boolean; ambiente?: string } | null>(null);
  const [env, setEnv] = useState<EnvelopeRow | null | undefined>(undefined);
  const [fixos, setFixos] = useState<Fixo[]>([]);
  const [usarFixo, setUsarFixo] = useState<Record<string, boolean>>({});
  const [usarDoc, setUsarDoc] = useState<Record<string, boolean>>({});
  const [lista, setLista] = useState<Assinante[]>([]);
  const [emOrdem, setEmOrdem] = useState(true);
  const [mensagem, setMensagem] = useState('');
  const [ocupado, setOcupado] = useState('');

  useEffect(() => { d4({ acao: 'situacao' }).then((r) => setSit({ configurado: !!r.configurado, ambiente: r.ambiente })); }, []);

  // documento mais recente (não cancelado) de cada tipo
  const atuais = Object.values(documentos.filter((d) => !d.cancelado_em).reduce<Record<string, DocEmitido>>((acc, d) => {
    if (!acc[d.documento] || acc[d.documento].numero < d.numero) acc[d.documento] = d;
    return acc;
  }, {})).sort((a, b) => (ORDEM_DOC[a.documento] ?? 9) - (ORDEM_DOC[b.documento] ?? 9));

  const carregar = useCallback(async () => {
    const [{ data: e }, { data: f }] = await Promise.all([
      supabase.from('envelopes').select('*').eq('pasta_id', pastaId).order('criado_em', { ascending: false }).limit(1).maybeSingle(),
      supabase.from('contrato_anexos_fixos').select('id, nome, arquivo, ordem').eq('ativo', true).order('ordem'),
    ]);
    const envelope = (e as EnvelopeRow) ?? null;
    setEnv(envelope);
    setFixos((f as Fixo[]) ?? []);
    setUsarFixo((u) => Object.fromEntries(((f as Fixo[]) ?? []).map((x) => [x.id, u[x.id] ?? true])));
    if (envelope && envelope.status !== 'preparado' && envelope.status !== 'cancelado') {
      const { data } = await supabase.from('envelope_assinantes').select('*').eq('envelope_id', envelope.id).order('ordem').order('id');
      setLista(((data as Assinante[]) ?? []).map((a) => ({ ...a, whatsapp: a.whatsapp ?? '' })));
    }
  }, [pastaId]);
  useEffect(() => { carregar(); }, [carregar]);

  // sugestão de assinantes ao montar o envelope
  const sugerir = useCallback(async () => {
    const c = dados.comprador ?? {}, j = dados.conjuge ?? {};
    type Gestor = { nome: string | null; email: string };
    let gestor: Gestor | null = null;
    if (imobiliariaId) {
      const { data } = await supabase.from('perfis').select('nome, email').eq('imobiliaria_id', imobiliariaId).eq('papel', 'imobiliaria').order('email').limit(1).maybeSingle();
      gestor = (data as Gestor | null) ?? null;
    }
    const tel = (t?: string) => (t ? formatarTelefone(t) : '');
    setLista([
      { ordem: 1, papel: pj ? `Comprador (representante de ${dados.empresa?.razao_social ?? 'empresa'})` : 'Comprador', nome: c.nome ?? '', email: c.email ?? '', whatsapp: tel(c.telefone), canal: 'email' },
      ...(temConjuge && !pj ? [{ ordem: 2, papel: 'Cônjuge', nome: j.nome ?? '', email: j.email ?? '', whatsapp: tel(j.telefone), canal: 'email' as const }] : []),
      { ordem: 3, papel: 'Imobiliária', nome: gestor?.nome ?? '', email: gestor?.email ?? '', whatsapp: '', canal: 'email' },
      { ordem: 4, papel: 'Incorporadora', nome: emp['vendedora.signatario_nome'] ?? '', email: emp['vendedora.signatario_email'] ?? '', whatsapp: '', canal: 'email' },
      { ordem: 5, papel: 'Testemunha', nome: emp['testemunha1.nome'] ?? '', email: emp['testemunha1.email'] ?? '', whatsapp: '', canal: 'email', testemunha: true },
      { ordem: 6, papel: 'Testemunha', nome: emp['testemunha2.nome'] ?? '', email: emp['testemunha2.email'] ?? '', whatsapp: '', canal: 'email', testemunha: true },
    ]);
  }, [dados, temConjuge, pj, emp, imobiliariaId]);
  useEffect(() => { if (env?.status === 'preparado') sugerir(); }, [env?.status, env?.id, sugerir]);

  const executar = async (rotulo: string, corpo: Record<string, unknown>, ok?: string) => {
    setOcupado(rotulo);
    const r = await d4(corpo);
    setOcupado('');
    if (r.erro) { avisar(r.erro, 'erro'); return null; }
    if (ok) avisar(ok);
    await carregar(); aoMudar();
    return r;
  };

  if (env === undefined) return null;
  const ativo = env && (env.status === 'preparado' || env.status === 'enviado' || env.status === 'assinado') ? env : null;
  const incluidos = atuais.filter((d) => usarDoc[d.id] ?? true);
  const faltam = Object.keys(NOME_ESPERADO).filter((t) => !atuais.some((d) => d.documento === t));
  const temPrincipal = incluidos.some((d) => d.documento === 'quadro_resumo');
  const pendentes = incluidos.filter((d) => d.validacao !== 'validado');
  const podeMontar = !!sit?.configurado && temPrincipal && !pendentes.length && !ocupado;

  const montar = async () => {
    const fx = fixos.filter((f) => usarFixo[f.id]);
    if (!(await confirmar({ titulo: 'Montar o envelope na D4Sign?', texto: `${incluidos.length + fx.length} documento(s) sobem num único envelope, nesta ordem: ${[...incluidos.map((d) => d.nome), ...fx.map((f) => f.nome)].join(' · ')}. Enquanto o envelope estiver ativo, os documentos ficam travados.`, confirmar: 'Montar envelope' }))) return;
    await executar('Subindo os documentos…', { acao: 'criar', pasta: pastaId, contratos: incluidos.map((d) => d.id), fixos: fx.map((f) => f.id) }, 'Envelope montado. Confira a prévia.');
  };

  const enviar = async () => {
    const faltando = lista.filter((a) => !a.email.trim() || (a.canal === 'whatsapp' && a.whatsapp.replace(/\D/g, '').length < 10));
    if (faltando.length) { avisar(`Complete e-mail${faltando.some((a) => a.canal === 'whatsapp') ? ' e WhatsApp' : ''} de: ${faltando.map((a) => a.papel).join(', ')}.`, 'erro'); return; }
    if (!(await confirmar({ titulo: `Enviar o envelope para ${lista.length} assinantes?`, texto: emOrdem ? 'Cada assinante recebe o link na sua vez, seguindo a ordem da lista.' : 'Todos recebem o link ao mesmo tempo.', confirmar: 'Enviar para assinatura' }))) return;
    await executar('Enviando…', { acao: 'enviar', envelope: env!.id, assinantes: lista.map((a, i) => ({ ...a, ordem: i + 1 })), emOrdem, mensagem }, 'Envelope enviado para assinatura.');
  };

  const abrir = async (zip: boolean) => {
    const r = await executar(zip ? 'Buscando o pacote…' : 'Buscando a prévia…', { acao: 'previa', envelope: env!.id, zip });
    if (r?.url) window.open(r.url, '_blank');
  };
  const baixarAssinado = async () => {
    if (!env?.caminho_assinado) return;
    const { data } = await supabase.storage.from('contratos').createSignedUrl(env.caminho_assinado, 60, { download: 'Envelope assinado.zip' });
    if (data?.signedUrl) window.location.href = data.signedUrl;
  };
  const mudar = (i: number, campo: keyof Assinante, v: string | boolean) => setLista(lista.map((a, k) => (k === i ? { ...a, [campo]: v } : a)));
  const mover = (i: number, d: -1 | 1) => { const n = [...lista]; const [a] = n.splice(i, 1); n.splice(i + d, 0, a); setLista(n); };
  const editavel = ativo?.status === 'preparado';

  return (
    <div className="cartao env-cartao">
      <div className="cartao-topo">
        <div>
          <h3>Envelope de assinatura</h3>
          <p className="sub">Um único envelope por venda na D4Sign{sit?.ambiente ? ` (${sit.ambiente})` : ''}: o Quadro Resumo é o documento principal e os demais vão como anexos.
            {ativo?.enviado_em && <> Enviado em {formatarDataHora(ativo.enviado_em)}.</>}{ativo?.assinado_em && <> Concluído em {formatarDataHora(ativo.assinado_em)}.</>}</p>
        </div>
        {ativo ? <span className={`selo ${SITUACAO[ativo.status][1]}`}>{SITUACAO[ativo.status][0]}</span> : <span className="selo sp-incompleta">Não montado</span>}
      </div>

      {sit && !sit.configurado && <p className="erro">A D4Sign ainda não foi configurada no servidor (chaves D4SIGN_TOKEN e D4SIGN_CRYPTKEY no Cloudflare). Dá para conferir a composição; o envio fica liberado quando as chaves forem cadastradas.</p>}

      {/* composição */}
      {!ativo ? (
        <>
          {env?.status === 'cancelado' && <p className="sub">O envelope anterior foi cancelado em {env.cancelado_em ? formatarDataHora(env.cancelado_em) : '—'}. Monte um novo quando os documentos estiverem prontos.</p>}
          <ul className="env-docs">
            {atuais.map((d) => (
              <li key={d.id}>
                <label><input type="checkbox" disabled={d.documento === 'quadro_resumo'} checked={usarDoc[d.id] ?? true} onChange={(e) => setUsarDoc({ ...usarDoc, [d.id]: e.target.checked })} />
                  <strong>{d.nome}</strong> <span className="sub">nº {d.numero} · v{d.versao}{d.documento === 'quadro_resumo' && ' · principal'}</span></label>
                {d.validacao === 'validado' ? <span className="selo sp-aprovada">Validado</span> : <span className="selo sp-pendente_correcao">Falta validar</span>}
              </li>
            ))}
            {faltam.map((t) => (
              <li key={t}>
                <span><strong>{NOME_ESPERADO[t]}</strong> <span className="sub">ainda não emitido — marque em Emissão e emita para incluir no envelope</span></span>
                <span className="selo sp-pendente_correcao">Falta emitir</span>
              </li>
            ))}
            {fixos.map((f) => (
              <li key={f.id}>
                <label><input type="checkbox" checked={!!usarFixo[f.id]} onChange={(e) => setUsarFixo({ ...usarFixo, [f.id]: e.target.checked })} />
                  <strong>{f.nome}</strong> <span className="sub">documento fixo do empreendimento</span></label>
                <span className="selo sp-aprovada">Fixo</span>
              </li>
            ))}
          </ul>
          {!temPrincipal && <p className="erro">Emita e valide o Quadro Resumo: ele é o documento principal do envelope.</p>}
          {!!pendentes.length && <p className="sub">Valide {pendentes.map((d) => d.nome).join(', ')} para montar o envelope.</p>}
          {!fixos.length && <p className="sub">Nenhum documento fixo cadastrado (memorial, plantas, convenção…). O administrador cadastra em Empreendimento → Documentos fixos do contrato.</p>}
          <div className="acoes"><button type="button" className="botao principal" disabled={!podeMontar} onClick={montar}><Package size={16} /> {ocupado || 'Montar envelope na D4Sign'}</button></div>
        </>
      ) : (
        <ul className="env-docs">
          {ativo.documentos.map((d, i) => <li key={`${d.tipo}-${d.id}`}><span><strong>{d.nome}</strong> <span className="sub">{d.arquivo}{i === 0 && ' · principal'}</span></span></li>)}
        </ul>
      )}

      {editavel && (
        <div className="acoes env-topo">
          <button type="button" className="botao" disabled={!!ocupado} onClick={() => abrir(false)}><Eye size={16} /> Prévia do principal (PDF)</button>
          <button type="button" className="botao" disabled={!!ocupado} onClick={() => abrir(true)}><FileArchive size={16} /> Pacote completo (ZIP)</button>
          <button type="button" className="botao" disabled={!!ocupado} onClick={async () => {
            if (await confirmar({ titulo: 'Descartar o envelope?', texto: 'Use quando a prévia mostrar algo a ajustar: os documentos voltam para edição e você monta de novo depois.', confirmar: 'Descartar' }))
              executar('Descartando…', { acao: 'descartar', envelope: ativo!.id }, 'Envelope descartado. Ajuste e monte de novo.');
          }}>Descartar e ajustar</button>
        </div>
      )}

      {ativo && lista.length > 0 && (
        <div className="tabela-rolagem">
          <table className="tabela ass-tabela">
            <thead><tr><th>Ordem</th><th>Papel</th><th>Nome</th><th>E-mail</th><th>Receber por</th>{editavel ? <th /> : <th>Situação</th>}</tr></thead>
            <tbody>
              {lista.map((a, i) => (
                <tr key={a.id ?? i}>
                  <td>{editavel ? i + 1 : a.ordem}</td>
                  <td>{editavel ? <input value={a.papel} onChange={(e) => mudar(i, 'papel', e.target.value)} /> : a.papel}</td>
                  <td>{editavel ? <input value={a.nome} onChange={(e) => mudar(i, 'nome', e.target.value)} /> : a.nome}</td>
                  <td>{editavel ? <input type="email" value={a.email} onChange={(e) => mudar(i, 'email', e.target.value)} /> : a.email}</td>
                  <td>{editavel ? (
                    <div className="ass-canal">
                      <select value={a.canal} onChange={(e) => mudar(i, 'canal', e.target.value)}><option value="email">E-mail</option><option value="whatsapp">WhatsApp</option></select>
                      {a.canal === 'whatsapp' && <input placeholder="(64) 99999-0000" value={a.whatsapp} onChange={(e) => mudar(i, 'whatsapp', formatarTelefone(e.target.value))} />}
                    </div>
                  ) : a.canal === 'whatsapp' ? `WhatsApp ${a.whatsapp}` : 'E-mail'}</td>
                  {editavel ? (
                    <td className="ass-mover">
                      <button type="button" className="botao pequeno" disabled={i === 0} onClick={() => mover(i, -1)}><ArrowUp size={12} /></button>
                      <button type="button" className="botao pequeno" disabled={i === lista.length - 1} onClick={() => mover(i, 1)}><ArrowDown size={12} /></button>
                      <button type="button" className="botao pequeno" onClick={() => setLista(lista.filter((_, k) => k !== i))}><Trash2 size={12} /></button>
                    </td>
                  ) : (
                    <td>{a.assinado
                      ? <span className="selo sp-aprovada"><CheckCircle2 size={12} /> Assinou{a.assinado_em ? ` ${formatarDataHora(a.assinado_em)}` : ''}</span>
                      : <span className="selo sp-aguardando_analise"><Clock size={12} /> Pendente</span>}
                      {!a.assinado && ativo.status === 'enviado' && a.id && <button type="button" className="botao pequeno ass-reenviar" disabled={!!ocupado} onClick={() => executar('Reenviando…', { acao: 'reenviar', envelope: ativo.id, assinante: a.id }, `Link reenviado para ${a.nome || a.email}.`)}>Reenviar</button>}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {editavel && (
        <>
          <div className="acoes ass-opcoes">
            <button type="button" className="botao pequeno" onClick={() => setLista([...lista, { ordem: lista.length + 1, papel: 'Outro', nome: '', email: '', whatsapp: '', canal: 'email' }])}><Plus size={14} /> Assinante</button>
            <label className="ass-check"><input type="checkbox" checked={emOrdem} onChange={(e) => setEmOrdem(e.target.checked)} /> Seguir a ordem da lista (um de cada vez)</label>
          </div>
          <label className="ass-msg">Mensagem para os assinantes (opcional)<textarea rows={2} maxLength={500} value={mensagem} onChange={(e) => setMensagem(e.target.value)} placeholder="Ex.: Segue o contrato da sua unidade para assinatura." /></label>
          <div className="acoes"><button type="button" className="botao principal" disabled={!!ocupado} onClick={enviar}><Send size={16} /> {ocupado || 'Enviar para assinatura'}</button></div>
        </>
      )}

      {ativo?.status === 'enviado' && (
        <div className="acoes">
          <button type="button" className="botao" disabled={!!ocupado} onClick={async () => {
            const r = await executar('Atualizando…', { acao: 'sincronizar', envelope: ativo.id });
            if (r) avisar(`${r.assinados ?? 0} de ${r.total ?? 0} assinaturas concluídas.`);
          }}><RefreshCw size={16} /> Atualizar status</button>
          <button type="button" className="botao" disabled={!!ocupado} onClick={async () => {
            if (await confirmar({ titulo: 'Cancelar o envelope?', texto: 'Os links deixam de valer e os documentos voltam para edição. Para seguir, monte um novo envelope.', confirmar: 'Cancelar envelope', perigo: true }))
              executar('Cancelando…', { acao: 'cancelar', envelope: ativo.id }, 'Envelope cancelado.');
          }}>Cancelar envelope</button>
        </div>
      )}
      {ativo?.status === 'assinado' && ativo.caminho_assinado && (
        <div className="acoes"><button type="button" className="botao principal" onClick={baixarAssinado}><Download size={16} /> Baixar pacote assinado (ZIP)</button></div>
      )}
    </div>
  );
}
