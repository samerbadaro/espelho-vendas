// Painel de assinatura eletrônica (D4Sign) de um documento emitido.
// Etapas: subir para a D4Sign → conferir a prévia do PDF → assinantes e ordem → enviar → acompanhar.
import { useCallback, useEffect, useState } from 'react';
import { ArrowDown, ArrowUp, CheckCircle2, Clock, Eye, Plus, RefreshCw, Send, Trash2, Upload } from 'lucide-react';
import { supabase, formatarDataHora } from '../dados';
import { useDialogos } from '../ui';
import { formatarTelefone } from '../util';
import type { DadosContrato as Dados } from './leitura';

export interface DocAssinatura {
  id: string; numero: number; nome: string; versao: number; validacao: string; assinatura: string; cancelado_em: string | null;
  d4sign_uuid?: string | null; enviado_assinatura_em?: string | null; assinado_em?: string | null; caminho_assinado?: string | null;
}
interface Assinante { id?: number; ordem: number; papel: string; nome: string; email: string; whatsapp: string; canal: 'email' | 'whatsapp'; testemunha?: boolean; assinado?: boolean; assinado_em?: string | null }

async function d4(corpo: Record<string, unknown>): Promise<{ erro?: string; url?: string; configurado?: boolean; ambiente?: string; assinados?: number; total?: number }> {
  const { data } = await supabase.auth.getSession();
  try {
    const r = await fetch('/api/d4sign', { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${data.session?.access_token ?? ''}` }, body: JSON.stringify(corpo) });
    return await r.json();
  } catch { return { erro: 'Sem conexão com o servidor.' }; }
}

const ROTULO: Record<string, [string, string]> = {
  nao_enviado: ['Não enviado', 'sp-incompleta'], preparado: ['Na D4Sign — conferir prévia', 'sp-em_analise'], enviado: ['Aguardando assinaturas', 'sp-aguardando_analise'],
  assinado: ['Assinado', 'sp-aprovada'], recusado: ['Recusado', 'sp-pendente_correcao'], cancelado: ['Cancelado na D4Sign', 'sp-pendente_correcao'],
};
export const rotuloAssinatura = (s: string) => ROTULO[s] ?? [s, 'sp-incompleta'];

export function PainelAssinatura({ doc, dados, temConjuge, pj, emp, imobiliariaId, aoMudar }: {
  doc: DocAssinatura; dados: Dados; temConjuge: boolean; pj: boolean; emp: Record<string, string>; imobiliariaId: string | null; aoMudar: () => void;
}) {
  const { avisar, confirmar } = useDialogos();
  const [sit, setSit] = useState<{ configurado: boolean; ambiente?: string } | null>(null);
  const [ocupado, setOcupado] = useState('');
  const [lista, setLista] = useState<Assinante[]>([]);
  const [emOrdem, setEmOrdem] = useState(true);
  const [mensagem, setMensagem] = useState('');

  useEffect(() => { d4({ acao: 'situacao' }).then((r) => setSit({ configurado: !!r.configurado, ambiente: r.ambiente })); }, []);

  // assinantes: os já enviados (do banco) ou uma sugestão montada com os dados do contrato
  const montar = useCallback(async () => {
    if (doc.assinatura === 'enviado' || doc.assinatura === 'assinado' || doc.assinatura === 'cancelado') {
      const { data } = await supabase.from('contrato_assinantes').select('*').eq('contrato_id', doc.id).order('ordem').order('id');
      setLista(((data as Assinante[]) ?? []).map((a) => ({ ...a, whatsapp: a.whatsapp ?? '' })));
      return;
    }
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
      ...(temConjuge && !pj ? [{ ordem: 1, papel: 'Cônjuge', nome: j.nome ?? '', email: j.email ?? '', whatsapp: tel(j.telefone), canal: 'email' as const }] : []),
      { ordem: 1, papel: 'Imobiliária', nome: gestor?.nome ?? '', email: gestor?.email ?? '', whatsapp: '', canal: 'email' },
      { ordem: 2, papel: 'Incorporadora', nome: emp['vendedora.signatario_nome'] ?? '', email: emp['vendedora.signatario_email'] ?? '', whatsapp: '', canal: 'email' },
      { ordem: 3, papel: 'Testemunha', nome: emp['testemunha1.nome'] ?? '', email: emp['testemunha1.email'] ?? '', whatsapp: '', canal: 'email', testemunha: true },
      { ordem: 3, papel: 'Testemunha', nome: emp['testemunha2.nome'] ?? '', email: emp['testemunha2.email'] ?? '', whatsapp: '', canal: 'email', testemunha: true },
    ]);
  }, [doc.id, doc.assinatura, dados, temConjuge, pj, emp, imobiliariaId]);
  useEffect(() => { montar(); }, [montar]);

  const executar = async (rotulo: string, corpo: Record<string, unknown>, ok?: string) => {
    setOcupado(rotulo);
    const r = await d4({ ...corpo, contrato: doc.id });
    setOcupado('');
    if (r.erro) { avisar(r.erro, 'erro'); return null; }
    if (ok) avisar(ok);
    aoMudar();
    return r;
  };

  const mudar = (i: number, campo: keyof Assinante, v: string | boolean | number) => setLista(lista.map((a, k) => (k === i ? { ...a, [campo]: v } : a)));
  const mover = (i: number, d: -1 | 1) => { const n = [...lista]; const [a] = n.splice(i, 1); n.splice(i + d, 0, a); setLista(n); };

  const enviar = async () => {
    const faltando = lista.filter((a) => !a.email.trim() || (a.canal === 'whatsapp' && a.whatsapp.replace(/\D/g, '').length < 10));
    if (faltando.length) { avisar(`Complete e-mail${faltando.some((a) => a.canal === 'whatsapp') ? ' e WhatsApp' : ''} de: ${faltando.map((a) => a.papel).join(', ')}.`, 'erro'); return; }
    if (!(await confirmar({ titulo: `Enviar o nº ${doc.numero} para ${lista.length} assinantes?`, texto: emOrdem ? 'Cada assinante recebe o link na sua vez, seguindo a ordem da lista.' : 'Todos recebem o link ao mesmo tempo.', confirmar: 'Enviar para assinatura' }))) return;
    const assinantes = lista.map((a, i) => ({ ...a, ordem: emOrdem ? i + 1 : a.ordem }));
    await executar('Enviando…', { acao: 'enviar', assinantes, emOrdem, mensagem }, 'Enviado para assinatura.');
  };

  const previa = async () => {
    const r = await executar('Buscando a prévia…', { acao: 'previa' });
    if (r?.url) window.open(r.url, '_blank');
  };

  const baixarAssinado = async () => {
    if (!doc.caminho_assinado) return;
    const { data } = await supabase.storage.from('contratos').createSignedUrl(doc.caminho_assinado, 60, { download: `${doc.numero} - ${doc.nome} (assinado).pdf` });
    if (data?.signedUrl) window.location.href = data.signedUrl;
  };

  const [rot, cls] = rotuloAssinatura(doc.assinatura);
  const editavel = doc.assinatura === 'preparado';

  return (
    <div className="ass-painel">
      <div className="cartao-topo">
        <div>
          <h4>Assinatura eletrônica — nº {doc.numero} (v{doc.versao})</h4>
          <p className="sub">D4Sign {sit?.ambiente ? `· ${sit.ambiente}` : ''}{doc.enviado_assinatura_em && <> · enviado em {formatarDataHora(doc.enviado_assinatura_em)}</>}{doc.assinado_em && <> · concluído em {formatarDataHora(doc.assinado_em)}</>}</p>
        </div>
        <span className={`selo ${cls}`}>{rot}</span>
      </div>

      {sit && !sit.configurado && <p className="erro">A D4Sign ainda não foi configurada no servidor. Assim que as chaves (D4SIGN_TOKEN e D4SIGN_CRYPTKEY) forem cadastradas no Cloudflare, os botões abaixo passam a funcionar.</p>}

      {doc.assinatura === 'nao_enviado' && (
        <div className="acoes">
          <span className="sub ass-dica">{doc.validacao !== 'validado' ? 'Valide o documento antes de enviar.' : 'O arquivo da versão atual sobe para a D4Sign; você confere a prévia do PDF antes de chamar os assinantes.'}</span>
          <button type="button" className="botao principal" disabled={!sit?.configurado || doc.validacao !== 'validado' || !!ocupado}
            onClick={() => executar('Subindo para a D4Sign…', { acao: 'subir' }, 'Documento na D4Sign. Confira a prévia.')}><Upload size={16} /> {ocupado || 'Subir para a D4Sign'}</button>
        </div>
      )}

      {editavel && (
        <div className="acoes ass-topo">
          <button type="button" className="botao" disabled={!!ocupado} onClick={previa}><Eye size={16} /> Ver prévia do PDF (D4Sign)</button>
          <button type="button" className="botao" disabled={!!ocupado} onClick={async () => {
            if (await confirmar({ titulo: 'Descartar o envio à D4Sign?', texto: 'Use quando a prévia mostrar algo a ajustar: o documento volta para edição (Enviar ajuste) e pode subir de novo.', confirmar: 'Descartar' }))
              executar('Descartando…', { acao: 'descartar' }, 'Envio descartado. Ajuste e suba de novo.');
          }}>Descartar e ajustar</button>
        </div>
      )}

      {lista.length > 0 && doc.assinatura !== 'nao_enviado' && (
        <div className="tabela-rolagem">
          <table className="tabela ass-tabela">
            <thead><tr><th>Ordem</th><th>Papel</th><th>Nome</th><th>E-mail</th><th>Receber por</th>{editavel ? <th /> : <th>Situação</th>}</tr></thead>
            <tbody>
              {lista.map((a, i) => (
                <tr key={a.id ?? i}>
                  <td>{editavel && !emOrdem ? <input className="ass-ordem" type="number" min={1} value={a.ordem} onChange={(e) => mudar(i, 'ordem', Number(e.target.value))} /> : emOrdem && editavel ? i + 1 : a.ordem}</td>
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
                      {!a.assinado && doc.assinatura === 'enviado' && a.id && <button type="button" className="botao pequeno ass-reenviar" disabled={!!ocupado} onClick={() => executar('Reenviando…', { acao: 'reenviar', assinante: a.id }, `Link reenviado para ${a.nome || a.email}.`)}>Reenviar</button>}
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
          <label className="ass-msg">Mensagem no e-mail (opcional)<textarea rows={2} maxLength={500} value={mensagem} onChange={(e) => setMensagem(e.target.value)} placeholder="Ex.: Segue o contrato da unidade para assinatura." /></label>
          <div className="acoes"><button type="button" className="botao principal" disabled={!!ocupado} onClick={enviar}><Send size={16} /> {ocupado || 'Enviar para assinatura'}</button></div>
        </>
      )}

      {doc.assinatura === 'enviado' && (
        <div className="acoes">
          <button type="button" className="botao" disabled={!!ocupado} onClick={async () => {
            const r = await executar('Atualizando…', { acao: 'sincronizar' });
            if (r) avisar(`${r.assinados ?? 0} de ${r.total ?? 0} assinaturas concluídas.`);
          }}><RefreshCw size={16} /> Atualizar status</button>
          <button type="button" className="botao" disabled={!!ocupado} onClick={async () => {
            if (await confirmar({ titulo: `Cancelar a assinatura do nº ${doc.numero}?`, texto: 'O documento é cancelado na D4Sign e os links deixam de valer. Para seguir, emita de novo.', confirmar: 'Cancelar assinatura', perigo: true }))
              executar('Cancelando…', { acao: 'cancelar' }, 'Assinatura cancelada.');
          }}>Cancelar assinatura</button>
        </div>
      )}
      {doc.assinatura === 'assinado' && doc.caminho_assinado && (
        <div className="acoes"><button type="button" className="botao principal" onClick={baixarAssinado}>Baixar PDF assinado</button></div>
      )}
      <p className="sub ass-nota">A D4Sign avisa o sistema a cada assinatura; o “Atualizar status” é só para conferir na hora.</p>
    </div>
  );
}
