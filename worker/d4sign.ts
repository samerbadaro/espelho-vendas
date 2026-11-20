/**
 * Integração com a D4Sign (assinatura eletrônica). As chaves ficam só no servidor
 * (D4SIGN_TOKEN, D4SIGN_CRYPTKEY); o navegador da equipe pede as ações por /api/d4sign.
 * O webhook (/api/d4sign/webhook) não confia no conteúdo recebido: ele só usa o UUID para
 * consultar a própria D4Sign e atualizar o status (e confere o HMAC quando D4SIGN_HMAC existe).
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

export interface EnvD4 {
  SUPABASE_URL: string;
  SUPABASE_SECRET_KEY?: string;
  D4SIGN_TOKEN?: string;
  D4SIGN_CRYPTKEY?: string;
  D4SIGN_AMBIENTE?: string;   // 'producao' usa secure.d4sign.com.br; qualquer outro valor usa a sandbox
  D4SIGN_HMAC?: string;       // chave do webhook (opcional)
}

const json = (dados: unknown, status = 200) =>
  new Response(JSON.stringify(dados), { status, headers: { 'content-type': 'application/json; charset=utf-8' } });
const erro = (mensagem: string, status = 400) => json({ erro: mensagem }, status);
class ErroD4 extends Error {}

const base = (env: EnvD4) => (env.D4SIGN_AMBIENTE === 'producao' ? 'https://secure.d4sign.com.br/api/v1' : 'https://sandbox.d4sign.com.br/api/v1');

async function d4(env: EnvD4, caminho: string, init: RequestInit = {}) {
  const sep = caminho.includes('?') ? '&' : '?';
  const url = `${base(env)}${caminho}${sep}tokenAPI=${encodeURIComponent(env.D4SIGN_TOKEN!)}&cryptKey=${encodeURIComponent(env.D4SIGN_CRYPTKEY ?? '')}`;
  const r = await fetch(url, { ...init, headers: { accept: 'application/json', ...(init.body && !(init.body instanceof FormData) ? { 'content-type': 'application/json' } : {}), ...(init.headers ?? {}) } });
  const txt = await r.text();
  let j: unknown;
  try { j = JSON.parse(txt); } catch { j = { message: txt }; }
  if (!r.ok) {
    const m = (j as { message?: string; mensagem_pt?: string })?.mensagem_pt || (j as { message?: string })?.message || `erro ${r.status}`;
    throw new ErroD4(r.status === 429 || /limit/i.test(m) ? 'Limite de uso da D4Sign atingido. Tente de novo mais tarde.' : `D4Sign: ${m}`);
  }
  return j;
}

interface Contrato {
  id: string; numero: number; pasta_id: string; nome: string; caminho: string | null; caminho_docx: string | null; versao: number;
  validacao: string; assinatura: string; cancelado_em: string | null; d4sign_uuid: string | null;
}

async function historico(adm: SupabaseClient, pasta: string, acao: string, detalhes: Record<string, unknown>, email: string | null) {
  await adm.from('historico_pastas').insert({ pasta_id: pasta, acao, detalhes, usuario_email: email });
}

/** Cofre configurado: pelo UUID guardado ou pelo nome cadastrado em "Dados para contrato". */
async function cofre(env: EnvD4, adm: SupabaseClient): Promise<string> {
  const { data } = await adm.from('empreendimento_contrato').select('dados').eq('id', 1).maybeSingle();
  const dados = (data?.dados ?? {}) as Record<string, string>;
  if (dados['assinatura.cofre_uuid']) return dados['assinatura.cofre_uuid'];
  const nome = (dados['assinatura.cofre'] ?? '').trim().toLowerCase();
  const lista = (await d4(env, '/safes')) as { uuid_safe: string; 'name-safe': string }[];
  const achado = (Array.isArray(lista) ? lista : []).find((c) => !nome || c['name-safe']?.trim().toLowerCase() === nome);
  if (!achado) throw new ErroD4(nome ? `Cofre "${dados['assinatura.cofre']}" não encontrado na D4Sign.` : 'Nenhum cofre encontrado na conta da D4Sign.');
  await adm.from('empreendimento_contrato').update({ dados: { ...dados, 'assinatura.cofre_uuid': achado.uuid_safe } }).eq('id', 1);
  return achado.uuid_safe;
}

/** Consulta a D4Sign e atualiza assinantes e status; guarda o PDF assinado quando finaliza. */
async function sincronizar(env: EnvD4, adm: SupabaseClient, c: Contrato, email: string | null) {
  const r = (await d4(env, `/documents/${c.d4sign_uuid}/list`)) as { statusId?: string; list?: { key_signer: string; signed?: string; sign_info?: { date_signed?: string } }[] }[];
  const doc = Array.isArray(r) ? r[0] : (r as unknown as { statusId?: string; list?: [] });
  const lista = doc?.list ?? [];
  for (const s of lista) {
    await adm.from('contrato_assinantes').update({
      assinado: s.signed === '1', assinado_em: s.signed === '1' ? s.sign_info?.date_signed ?? new Date().toISOString() : null, atualizado_em: new Date().toISOString(),
    }).eq('contrato_id', c.id).eq('key_signer', s.key_signer);
  }
  const status = String(doc?.statusId ?? '');
  if (status === '4' && c.assinatura !== 'assinado') {
    const dl = (await d4(env, `/documents/${c.d4sign_uuid}/download`, { method: 'POST', body: JSON.stringify({ type: 'PDF', language: 'pt' }) })) as { url?: string };
    let caminho: string | null = null;
    if (dl.url) {
      const pdf = await fetch(dl.url).then((x) => (x.ok ? x.arrayBuffer() : null));
      if (pdf) {
        caminho = `${c.pasta_id}/${c.d4sign_uuid}-assinado.pdf`;
        await adm.storage.from('contratos').upload(caminho, pdf, { contentType: 'application/pdf', upsert: true });
      }
    }
    await adm.from('contratos').update({ assinatura: 'assinado', assinado_em: new Date().toISOString(), caminho_assinado: caminho }).eq('id', c.id);
    await historico(adm, c.pasta_id, 'Contrato assinado por todos', { numero: c.numero }, email);
  } else if (status === '6' && c.assinatura !== 'cancelado') {
    await adm.from('contratos').update({ assinatura: 'cancelado' }).eq('id', c.id);
    await historico(adm, c.pasta_id, 'Assinatura cancelada na D4Sign', { numero: c.numero }, email);
  }
  return { status, assinados: lista.filter((s) => s.signed === '1').length, total: lista.length };
}

const telefone = (t: string) => { const d = t.replace(/\D/g, ''); return d ? `+${d.startsWith('55') ? d : `55${d}`}` : ''; };

/** POST /api/d4sign — { acao, contrato, ... } (somente equipe). */
export async function apiD4Sign(req: Request, env: EnvD4): Promise<Response> {
  if (req.method !== 'POST') return erro('Método não permitido.', 405);
  if (!env.SUPABASE_SECRET_KEY) return erro('O servidor ainda não foi configurado (chave secreta ausente).', 500);
  const adm = createClient(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: u } = await adm.auth.getUser(token);
  if (!u?.user) return erro('Faça login novamente.', 401);
  const { data: perfil } = await adm.from('perfis').select('papel, email').eq('user_id', u.user.id).maybeSingle();
  if (!perfil || !['admin', 'vendas'].includes(perfil.papel)) return erro('Somente a equipe de vendas pode enviar para assinatura.', 403);
  const email = perfil.email ?? u.user.email ?? null;
  let corpo: Record<string, unknown>;
  try { corpo = await req.json(); } catch { return erro('Requisição inválida.'); }
  const acao = String(corpo.acao || '');

  const configurado = !!env.D4SIGN_TOKEN;
  if (acao === 'situacao') return json({ configurado, ambiente: env.D4SIGN_AMBIENTE === 'producao' ? 'produção' : 'sandbox (testes)' });
  if (!configurado) return erro('A D4Sign ainda não foi configurada (chaves ausentes no servidor).', 400);

  const { data: c } = await adm.from('contratos').select('*').eq('id', String(corpo.contrato || '')).maybeSingle<Contrato>();
  if (!c) return erro('Documento não encontrado.', 404);
  if (c.cancelado_em) return erro('Este documento foi cancelado.');

  try {
    if (acao === 'subir') {
      if (c.validacao !== 'validado') return erro('Valide o documento antes de enviar para a D4Sign.');
      if (c.assinatura !== 'nao_enviado') return erro('Este documento já está na D4Sign.');
      const usarPdf = !!c.caminho;
      const caminho = usarPdf ? c.caminho! : c.caminho_docx;
      if (!caminho) return erro('Documento sem arquivo.');
      const { data: arq } = await adm.storage.from('contratos').download(caminho);
      if (!arq) return erro('Não foi possível ler o arquivo do documento.');
      const uuidCofre = await cofre(env, adm);
      const fd = new FormData();
      const nome = `${c.numero} - ${c.nome} (v${c.versao}).${usarPdf ? 'pdf' : 'docx'}`.replace(/[\\/:*?"<>|]/g, '-');
      fd.append('file', new File([arq], nome, { type: usarPdf ? 'application/pdf' : 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }));
      const up = (await d4(env, `/documents/${uuidCofre}/upload`, { method: 'POST', body: fd })) as { uuid?: string };
      if (!up.uuid) throw new ErroD4('A D4Sign não devolveu o identificador do documento.');
      const origem = new URL(req.url).origin;
      await d4(env, `/documents/${up.uuid}/webhooks`, { method: 'POST', body: JSON.stringify({ url: `${origem}/api/d4sign/webhook` }) }).catch(() => null);
      await adm.from('contratos').update({ d4sign_uuid: up.uuid, assinatura: 'preparado' }).eq('id', c.id);
      await historico(adm, c.pasta_id, 'Documento enviado à D4Sign', { numero: c.numero, versao: c.versao }, email);
      return json({ ok: true, uuid: up.uuid });
    }

    if (!c.d4sign_uuid) return erro('O documento ainda não foi enviado à D4Sign.');

    if (acao === 'previa') {
      const dl = (await d4(env, `/documents/${c.d4sign_uuid}/download`, { method: 'POST', body: JSON.stringify({ type: 'PDF', language: 'pt' }) })) as { url?: string };
      if (!dl.url) return erro('A D4Sign ainda está preparando o PDF. Tente de novo em alguns segundos.');
      return json({ ok: true, url: dl.url });
    }

    if (acao === 'descartar') {
      if (c.assinatura !== 'preparado') return erro('Só dá para descartar antes de enviar aos assinantes.');
      await d4(env, `/documents/${c.d4sign_uuid}/cancel`, { method: 'POST', body: JSON.stringify({ comment: 'Descartado antes do envio (ajuste do documento).' }) }).catch(() => null);
      await adm.from('contratos').update({ d4sign_uuid: null, assinatura: 'nao_enviado' }).eq('id', c.id);
      await historico(adm, c.pasta_id, 'Envio à D4Sign descartado', { numero: c.numero }, email);
      return json({ ok: true });
    }

    if (acao === 'enviar') {
      if (c.assinatura !== 'preparado') return erro('Suba o documento e confira a prévia antes de enviar.');
      const lista = (Array.isArray(corpo.assinantes) ? corpo.assinantes : []) as { papel: string; nome: string; email: string; whatsapp?: string; canal?: string; ordem: number; testemunha?: boolean }[];
      if (!lista.length) return erro('Informe os assinantes.');
      if (lista.some((a) => !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test((a.email || '').trim()))) return erro('Todo assinante precisa de um e-mail válido.');
      if (lista.some((a) => a.canal === 'whatsapp' && telefone(a.whatsapp || '').length < 13)) return erro('Informe o WhatsApp com DDD de quem vai receber por WhatsApp.');
      const ordenada = [...lista].sort((a, b) => Number(a.ordem) - Number(b.ordem));
      const signers = ordenada.map((a) => ({
        email: a.email.trim().toLowerCase(), act: a.testemunha ? '5' : '1', foreign: '0', certificadoicpbr: '0', assinatura_presencial: '0',
        ...(a.canal === 'whatsapp' ? { whatsapp_number: telefone(a.whatsapp || '') } : {}),
      }));
      const r = (await d4(env, `/documents/${c.d4sign_uuid}/createlist`, { method: 'POST', body: JSON.stringify({ signers }) })) as { message?: { key_signer?: string; email?: string }[] } | { key_signer?: string; email?: string }[];
      const devolvidos = (Array.isArray(r) ? r : Array.isArray((r as { message?: unknown }).message) ? (r as { message: { key_signer?: string; email?: string }[] }).message : []) as { key_signer?: string; email?: string }[];
      await adm.from('contrato_assinantes').delete().eq('contrato_id', c.id);
      await adm.from('contrato_assinantes').insert(ordenada.map((a, i) => ({
        contrato_id: c.id, ordem: Number(a.ordem) || i + 1, papel: a.papel, nome: a.nome, email: a.email.trim().toLowerCase(),
        whatsapp: a.canal === 'whatsapp' ? telefone(a.whatsapp || '') : null, canal: a.canal === 'whatsapp' ? 'whatsapp' : 'email',
        key_signer: devolvidos.find((d) => d.email?.toLowerCase() === a.email.trim().toLowerCase())?.key_signer ?? devolvidos[i]?.key_signer ?? null,
      })));
      await d4(env, `/documents/${c.d4sign_uuid}/sendtosigner`, {
        method: 'POST',
        body: JSON.stringify({ skip_email: '0', workflow: corpo.emOrdem === false ? '0' : '1', message: String(corpo.mensagem || '').slice(0, 500) }),
      });
      await adm.from('contratos').update({ assinatura: 'enviado', enviado_assinatura_em: new Date().toISOString() }).eq('id', c.id);
      await historico(adm, c.pasta_id, 'Contrato enviado para assinatura', { numero: c.numero, assinantes: ordenada.length }, email);
      return json({ ok: true });
    }

    if (acao === 'sincronizar') return json({ ok: true, ...(await sincronizar(env, adm, c, email)) });

    if (acao === 'reenviar') {
      const { data: a } = await adm.from('contrato_assinantes').select('*').eq('id', Number(corpo.assinante)).eq('contrato_id', c.id).maybeSingle();
      if (!a?.key_signer) return erro('Assinante não encontrado.');
      await d4(env, `/documents/${c.d4sign_uuid}/resend`, { method: 'POST', body: JSON.stringify({ email: a.whatsapp || a.email, key_signer: a.key_signer }) });
      return json({ ok: true });
    }

    if (acao === 'cancelar') {
      if (c.assinatura === 'assinado') return erro('Documento já assinado não pode ser cancelado.');
      await d4(env, `/documents/${c.d4sign_uuid}/cancel`, { method: 'POST', body: JSON.stringify({ comment: String(corpo.motivo || 'Cancelado pela equipe de vendas.') }) });
      await adm.from('contratos').update({ assinatura: 'cancelado', cancelado_em: new Date().toISOString(), cancelado_por: email }).eq('id', c.id);
      await historico(adm, c.pasta_id, 'Assinatura cancelada', { numero: c.numero }, email);
      return json({ ok: true });
    }
    return erro('Ação desconhecida.');
  } catch (e) {
    return erro(e instanceof ErroD4 ? e.message : 'Não foi possível falar com a D4Sign agora.', 502);
  }
}

async function hmacHex(chave: string, texto: string) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(chave), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(texto));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** POST /api/d4sign/webhook — chamado pela D4Sign quando alguém assina, finaliza ou cancela. */
export async function webhookD4Sign(req: Request, env: EnvD4): Promise<Response> {
  if (req.method !== 'POST' || !env.SUPABASE_SECRET_KEY || !env.D4SIGN_TOKEN) return new Response('ok');
  const bruto = await req.text();
  let uuid = '';
  try { uuid = String((JSON.parse(bruto) as { uuid?: string }).uuid ?? ''); } catch { uuid = new URLSearchParams(bruto).get('uuid') ?? ''; }
  if (!/^[0-9a-f-]{36}$/i.test(uuid)) return new Response('ok');
  if (env.D4SIGN_HMAC) {
    const recebido = (req.headers.get('content-hmac') || '').replace(/^sha256=/i, '').toLowerCase();
    if (recebido !== (await hmacHex(env.D4SIGN_HMAC, uuid))) return new Response('assinatura inválida', { status: 401 });
  }
  const adm = createClient(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: c } = await adm.from('contratos').select('*').eq('d4sign_uuid', uuid).maybeSingle<Contrato>();
  if (c) await sincronizar(env, adm, c, 'D4Sign').catch(() => null);
  return new Response('ok');
}
