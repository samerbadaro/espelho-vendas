/**
 * Integração com a D4Sign — UM ENVELOPE POR PASTA. O documento principal (Quadro Resumo)
 * sobe para o cofre; Normas, Carta Proposta e documentos fixos sobem como anexos dele.
 * As chaves ficam só no servidor (D4SIGN_TOKEN, D4SIGN_CRYPTKEY); o navegador da equipe pede
 * as ações por /api/d4sign. O webhook (/api/d4sign/webhook) só usa o UUID para consultar a
 * própria D4Sign (e confere o HMAC quando D4SIGN_HMAC existe).
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { PDFDocument } from 'pdf-lib';

export interface EnvD4 {
  SUPABASE_URL: string;
  SUPABASE_SECRET_KEY?: string;
  D4SIGN_TOKEN?: string;
  D4SIGN_CRYPTKEY?: string;
  D4SIGN_AMBIENTE?: string;   // 'producao' usa secure.d4sign.com.br; qualquer outro valor usa a sandbox
  D4SIGN_HMAC?: string;
}

const json = (dados: unknown, status = 200) =>
  new Response(JSON.stringify(dados), { status, headers: { 'content-type': 'application/json; charset=utf-8' } });
const erro = (mensagem: string, status = 400) => json({ erro: mensagem }, status);
class ErroD4 extends Error {}
const DOCX = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

const base = (env: EnvD4) => (env.D4SIGN_AMBIENTE === 'producao' ? 'https://secure.d4sign.com.br/api/v1' : 'https://sandbox.d4sign.com.br/api/v1');

async function d4(env: EnvD4, caminho: string, init: RequestInit = {}) {
  const sep = caminho.includes('?') ? '&' : '?';
  const url = `${base(env)}${caminho}${sep}tokenAPI=${encodeURIComponent(env.D4SIGN_TOKEN!)}&cryptKey=${encodeURIComponent(env.D4SIGN_CRYPTKEY ?? '')}`;
  const r = await fetch(url, { ...init, headers: { accept: 'application/json', ...(init.body && !(init.body instanceof FormData) ? { 'content-type': 'application/json' } : {}), ...(init.headers ?? {}) } });
  const txt = await r.text();
  let j: unknown;
  try { j = JSON.parse(txt); } catch { j = { message: txt }; }
  if (!r.ok) {
    const m = (j as { mensagem_pt?: string; message?: string; error?: string })?.mensagem_pt || (j as { error?: string })?.error || (j as { message?: string })?.message || `erro ${r.status}`;
    if (/tempo limite|time limit|rate/i.test(m)) {
      console.log('D4Sign limite', r.status, caminho.split('?')[0]);
      throw new ErroD4('A D4Sign limitou as chamadas desta chave de API por um tempo. Aguarde cerca de uma hora e tente de novo; o envelope continua montado.');
    }
    const etapa = caminho.split('?')[0].replace(/[0-9a-f]{8}-[0-9a-f-]{27,}/gi, '…');
    console.log('D4Sign erro', r.status, etapa, txt.slice(0, 500));
    throw new ErroD4(r.status === 429 || /limit/i.test(m) ? 'Limite de uso da D4Sign atingido. Tente de novo mais tarde.' : `D4Sign: ${m} (etapa ${etapa}${txt && !/^\s*$/.test(txt) && m === `erro ${r.status}` ? `: ${txt.slice(0, 160)}` : ''})`);
  }
  return j;
}

interface DocEnv { tipo: 'contrato' | 'fixo'; id: string; nome: string; versao?: number; arquivo: string; d4sign_uuid?: string | null; /** página onde o documento começa no PDF único */ pagina_inicial?: number }
interface Envelope {
  id: string; pasta_id: string; proposta_id: string | null; d4sign_uuid: string | null; status: string; documentos: DocEnv[];
}

/** Leva o envelope ao espelho: enviado → Contrato em assinatura; assinado → Vendida; cancelado → Proposta recebida. */
async function espelho(adm: SupabaseClient, e: Envelope, evento: 'enviado' | 'assinado' | 'cancelado', email: string | null) {
  const { data, error } = await adm.rpc('contrato_espelho', { p_envelope: e.id, p_evento: evento });
  if (error) await historico(adm, e.pasta_id, 'Espelho não atualizado pelo envelope', { evento, erro: error.message }, email).catch(() => null);
  return data as string | null;
}

async function historico(adm: SupabaseClient, pasta: string, acao: string, detalhes: Record<string, unknown>, email: string | null) {
  await adm.from('historico_pastas').insert({ pasta_id: pasta, acao, detalhes, usuario_email: email });
}

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

const idsContratos = (e: Envelope) => e.documentos.filter((d) => d.tipo === 'contrato').map((d) => d.id);

/** Consulta a D4Sign, atualiza assinantes e situação; guarda o pacote assinado quando finaliza. */
async function sincronizar(env: EnvD4, adm: SupabaseClient, e: Envelope, email: string | null) {
  const r = (await d4(env, `/documents/${e.d4sign_uuid}/list`)) as { statusId?: string; list?: { key_signer: string; signed?: string; sign_info?: { date_signed?: string } }[] }[];
  const doc = Array.isArray(r) ? r[0] : (r as unknown as { statusId?: string; list?: [] });
  const lista = doc?.list ?? [];
  for (const s of lista) {
    await adm.from('envelope_assinantes').update({
      assinado: s.signed === '1', assinado_em: s.signed === '1' ? s.sign_info?.date_signed ?? new Date().toISOString() : null, atualizado_em: new Date().toISOString(),
    }).eq('envelope_id', e.id).eq('key_signer', s.key_signer);
  }
  const status = String(doc?.statusId ?? '');
  if (status === '4' && e.status !== 'assinado') {
    // pacote completo (principal + anexos + relatório de assinaturas)
    const dl = (await d4(env, `/documents/${e.d4sign_uuid}/download`, { method: 'POST', body: JSON.stringify({ type: 'ZIP', language: 'pt' }) })) as { url?: string };
    let caminho: string | null = null;
    if (dl.url) {
      const zip = await fetch(dl.url).then((x) => (x.ok ? x.arrayBuffer() : null));
      if (zip) {
        caminho = `${e.pasta_id}/envelope-${e.id}-assinado.zip`;
        await adm.storage.from('contratos').upload(caminho, zip, { contentType: 'application/zip', upsert: true });
      }
    }
    const agora = new Date().toISOString();
    await adm.from('envelopes').update({ status: 'assinado', assinado_em: agora, caminho_assinado: caminho }).eq('id', e.id);
    await espelho(adm, e, 'assinado', email);
    const ids = idsContratos(e);
    if (ids.length) await adm.from('contratos').update({ assinatura: 'assinado', assinado_em: agora }).in('id', ids);
    await historico(adm, e.pasta_id, 'Envelope assinado por todos', { documentos: e.documentos.length }, email);
  } else if (status === '6' && e.status !== 'cancelado') {
    await adm.from('envelopes').update({ status: 'cancelado', cancelado_em: new Date().toISOString(), cancelado_por: 'D4Sign' }).eq('id', e.id);
    if (e.status === 'enviado') await espelho(adm, e, 'cancelado', email);
    const ids = idsContratos(e);
    if (ids.length) await adm.from('contratos').update({ assinatura: 'nao_enviado' }).in('id', ids);
    await historico(adm, e.pasta_id, 'Envelope cancelado na D4Sign', {}, email);
  }
  return { status, assinados: lista.filter((s) => s.signed === '1').length, total: lista.length };
}

const telefone = (t: string) => { const d = t.replace(/\D/g, ''); return d ? `+${d.startsWith('55') ? d : `55${d}`}` : ''; };
const nomeArquivo = (n: string) => n.replace(/[\\/:*?"<>|]/g, '-').slice(0, 120);

/** POST /api/d4sign — { acao, ... } (somente equipe). */
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
  if (acao === 'diagnostico') {
    // confere as chaves sem mostrá-las: só o começo e o tamanho, e uma chamada de leitura (lista de cofres)
    const t = (env.D4SIGN_TOKEN ?? ''), c = (env.D4SIGN_CRYPTKEY ?? '');
    const forma = (v: string) => ({ inicio: v.slice(0, 5), tamanho: v.length, espacos: v !== v.trim() });
    let teste = 'ok';
    try { const r = await d4(env, '/safes'); teste = `ok: ${Array.isArray(r) ? r.length : 0} cofre(s)`; } catch (e) { teste = (e as Error).message; }
    return json({ configurado, ambiente: env.D4SIGN_AMBIENTE === 'producao' ? 'produção' : 'sandbox (testes)', token: forma(t), cryptKey: forma(c), teste });
  }
  if (!configurado) return erro('A D4Sign ainda não foi configurada (chaves ausentes no servidor).', 400);

  try {
    // ---- montar o envelope: principal + anexos ----
    if (acao === 'criar') {
      const pasta = String(corpo.pasta || '');
      const idsC = (Array.isArray(corpo.contratos) ? corpo.contratos : []).map(String);
      const idsF = (Array.isArray(corpo.fixos) ? corpo.fixos : []).map(String);
      if (!idsC.length) return erro('Escolha os documentos do envelope.');
      const { data: ativo } = await adm.from('envelopes').select('id').eq('pasta_id', pasta).in('status', ['preparado', 'enviado']).maybeSingle();
      if (ativo) return erro('Esta pasta já tem um envelope em andamento.');
      const { data: cs } = await adm.from('contratos').select('*').in('id', idsC);
      const contratos = (cs ?? []) as { id: string; numero: number; pasta_id: string; proposta_id: string | null; documento: string; nome: string; caminho: string | null; caminho_docx: string | null; versao: number; validacao: string; cancelado_em: string | null; assinatura: string }[];
      if (contratos.length !== idsC.length || contratos.some((c) => c.pasta_id !== pasta || c.cancelado_em)) return erro('Documento inválido para este envelope.');
      if (contratos.some((c) => c.validacao !== 'validado')) return erro('Valide todos os documentos antes de montar o envelope.');
      if (contratos.some((c) => c.assinatura === 'assinado')) return erro('Há documento já assinado na seleção.');
      const { data: fs } = idsF.length ? await adm.from('contrato_anexos_fixos').select('*').in('id', idsF).eq('ativo', true) : { data: [] };
      const fixos = (fs ?? []) as { id: string; nome: string; caminho: string; arquivo: string | null; ordem: number }[];

      // ordem do envelope: Carta Proposta, Contrato de Intermediação (quando houver), Quadro Resumo,
      // Normas Contratuais e os demais documentos fixos na ordem cadastrada
      const intermed = (t: string) => /intermedia/i.test(t);
      const peso = (tipo: 'contrato' | 'fixo', documento: string, nome: string, ordem = 0) =>
        documento === 'carta_proposta' ? 0 : intermed(`${documento} ${nome}`) ? 1 : documento === 'quadro_resumo' ? 2 : documento === 'normas' ? 3 : tipo === 'contrato' ? 4 : 5 + ordem / 1000;
      const itens: (DocEnv & { caminho: string; mime: string; peso: number })[] = [
        ...contratos.map((c) => {
          const usaPdf = !!c.caminho;
          return { tipo: 'contrato' as const, id: c.id, nome: c.nome, versao: c.versao, caminho: (usaPdf ? c.caminho : c.caminho_docx)!, mime: usaPdf ? 'application/pdf' : DOCX,
            arquivo: nomeArquivo(`${c.numero} - ${c.nome} (v${c.versao}).${usaPdf ? 'pdf' : 'docx'}`), peso: peso('contrato', c.documento, c.nome) };
        }),
        ...fixos.map((f) => ({ tipo: 'fixo' as const, id: f.id, nome: f.nome, caminho: f.caminho, mime: /\.docx$/i.test(f.caminho) ? DOCX : 'application/pdf',
          arquivo: nomeArquivo(f.arquivo || `${f.nome}.${/\.docx$/i.test(f.caminho) ? 'docx' : 'pdf'}`), peso: peso('fixo', '', `${f.nome} ${f.arquivo ?? ''}`, f.ordem) })),
      ].sort((a, b) => a.peso - b.peso);
      if (itens.some((i) => !i.caminho)) return erro('Há documento sem arquivo.');
      const semPdf = itens.filter((i) => i.mime !== 'application/pdf');
      if (semPdf.length) return erro(`Para juntar o envelope num arquivo só, todos os documentos precisam estar em PDF. Em Word: ${semPdf.map((i) => i.nome).join(', ')}.`);

      // nome na D4Sign: unidade - empreendimento - cliente (ex.: 206 - Duo Haus - Fulano de Tal)
      const [{ data: pa }, { data: cfg }, { data: pr }] = await Promise.all([
        adm.from('pastas').select('comprador_nome, tipo_pessoa, empresa_razao_social').eq('id', pasta).maybeSingle(),
        adm.from('config').select('nome_empreendimento').eq('id', 1).maybeSingle(),
        contratos[0].proposta_id ? adm.from('propostas').select('unidades(numero)').eq('id', contratos[0].proposta_id).maybeSingle() : Promise.resolve({ data: null }),
      ]);
      const unidade = ((pr as { unidades?: { numero?: string } } | null)?.unidades?.numero) ?? '';
      const emp = String(cfg?.nome_empreendimento ?? '').split(/\s+[–—-]\s+/)[0].trim();
      const cliente = (pa?.tipo_pessoa === 'pj' ? pa?.empresa_razao_social : pa?.comprador_nome) ?? '';
      const nomeEnvelope = nomeArquivo([unidade, emp, cliente].filter((x) => String(x).trim()).join(' - ') || 'Contrato') + '.pdf';

      // junta tudo num PDF só: a D4Sign conta as chamadas por hora, e um arquivo único gasta uma só
      const unico = await PDFDocument.create();
      const docs: DocEnv[] = [];
      for (const i of itens) {
        const { data: arq } = await adm.storage.from('contratos').download(i.caminho);
        if (!arq) throw new ErroD4(`Não foi possível ler o arquivo "${i.nome}".`);
        let origemPdf: PDFDocument;
        try { origemPdf = await PDFDocument.load(await arq.arrayBuffer(), { ignoreEncryption: true }); }
        catch { throw new ErroD4(`O arquivo "${i.nome}" não é um PDF válido.`); }
        const inicio = unico.getPageCount() + 1;
        const paginas = await unico.copyPages(origemPdf, origemPdf.getPageIndices());
        paginas.forEach((pg) => unico.addPage(pg));
        const { caminho: _c, mime: _m, peso: _p, ...resto } = i;
        docs.push({ ...resto, pagina_inicial: inicio });
      }
      const bytes = await unico.save();
      const uuidCofre = await cofre(env, adm);
      const fd = new FormData();
      fd.append('file', new File([bytes], nomeEnvelope, { type: 'application/pdf' }));
      const principal = (await d4(env, `/documents/${uuidCofre}/upload`, { method: 'POST', body: fd })) as { uuid?: string };
      if (!principal.uuid) throw new ErroD4('A D4Sign não devolveu o identificador do documento.');
      for (const d of docs) d.d4sign_uuid = principal.uuid;
      const origem = new URL(req.url).origin;
      const falhaAviso = await d4(env, `/documents/${principal.uuid}/webhooks`, { method: 'POST', body: JSON.stringify({ url: `${origem}/api/d4sign/webhook` }) })
        .then(() => null, (x: unknown) => (x instanceof Error ? x.message : String(x)));
      const limpos = docs.map(({ tipo, id, nome, versao, arquivo, d4sign_uuid, pagina_inicial }) => ({ tipo, id, nome, versao, arquivo, d4sign_uuid, pagina_inicial }));
      const { data: env_ } = await adm.from('envelopes').insert({
        pasta_id: pasta, proposta_id: contratos[0].proposta_id, d4sign_uuid: principal.uuid, documentos: limpos, criado_por: email,
      }).select('id').single();
      await adm.from('contratos').update({ assinatura: 'preparado' }).in('id', idsC);
      await historico(adm, pasta, 'Envelope montado na D4Sign', { documentos: limpos.map((d) => d.nome) }, email);
      if (falhaAviso) await historico(adm, pasta, 'Aviso automático de assinaturas não registrado na D4Sign', { erro: falhaAviso }, email);
      return json({ ok: true, envelope: env_?.id });
    }

    const { data: e } = await adm.from('envelopes').select('*').eq('id', String(corpo.envelope || '')).maybeSingle<Envelope>();
    if (!e) return erro('Envelope não encontrado.', 404);

    if (acao === 'previa') {
      const tipo = corpo.zip ? 'ZIP' : 'PDF';
      const dl = (await d4(env, `/documents/${e.d4sign_uuid}/download`, { method: 'POST', body: JSON.stringify({ type: tipo, language: 'pt' }) })) as { url?: string };
      if (!dl.url) return erro('A D4Sign ainda está preparando o arquivo. Tente de novo em alguns segundos.');
      return json({ ok: true, url: dl.url });
    }

    if (acao === 'descartar') {
      if (e.status !== 'preparado') return erro('Só dá para descartar antes de enviar aos assinantes.');
      await d4(env, `/documents/${e.d4sign_uuid}/cancel`, { method: 'POST', body: JSON.stringify({ comment: 'Descartado antes do envio (ajuste).' }) }).catch(() => null);
      await adm.from('envelopes').update({ status: 'cancelado', cancelado_em: new Date().toISOString(), cancelado_por: email }).eq('id', e.id);
      const ids = idsContratos(e);
      if (ids.length) await adm.from('contratos').update({ assinatura: 'nao_enviado' }).in('id', ids);
      await historico(adm, e.pasta_id, 'Envelope descartado antes do envio', {}, email);
      return json({ ok: true });
    }

    if (acao === 'enviar') {
      if (e.status !== 'preparado') return erro('Este envelope já foi enviado.');
      const lista = (Array.isArray(corpo.assinantes) ? corpo.assinantes : []) as { papel: string; nome: string; email: string; whatsapp?: string; canal?: string; ordem: number; testemunha?: boolean }[];
      if (!lista.length) return erro('Informe os assinantes.');
      if (lista.some((a) => !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test((a.email || '').trim()))) return erro('Todo assinante precisa de um e-mail válido.');
      if (lista.some((a) => a.canal === 'whatsapp' && telefone(a.whatsapp || '').length < 13)) return erro('Informe o WhatsApp com DDD de quem vai receber por WhatsApp.');
      const ordenada = [...lista].sort((a, b) => Number(a.ordem) - Number(b.ordem));
      const signers = ordenada.map((a) => ({
        email: a.email.trim().toLowerCase(), act: a.testemunha ? '5' : '1', foreign: '0', certificadoicpbr: '0', assinatura_presencial: '0',
        ...(a.canal === 'whatsapp' ? { whatsapp_number: telefone(a.whatsapp || '') } : {}),
      }));
      const r = (await d4(env, `/documents/${e.d4sign_uuid}/createlist`, { method: 'POST', body: JSON.stringify({ signers }) })) as unknown;
      const devolvidos = (Array.isArray(r) ? r : Array.isArray((r as { message?: unknown })?.message) ? (r as { message: unknown[] }).message : []) as { key_signer?: string; email?: string }[];
      await adm.from('envelope_assinantes').delete().eq('envelope_id', e.id);
      await adm.from('envelope_assinantes').insert(ordenada.map((a, i) => ({
        envelope_id: e.id, ordem: Number(a.ordem) || i + 1, papel: a.papel, nome: a.nome, email: a.email.trim().toLowerCase(),
        whatsapp: a.canal === 'whatsapp' ? telefone(a.whatsapp || '') : null, canal: a.canal === 'whatsapp' ? 'whatsapp' : 'email',
        key_signer: devolvidos.find((d) => d.email?.toLowerCase() === a.email.trim().toLowerCase())?.key_signer ?? devolvidos[i]?.key_signer ?? null,
      })));
      // posiciona cada assinatura na linha certa dos documentos gerados pelo sistema (o nome da linha = o nome do assinante)
      const pinos = await pinosDoEnvelope(adm, e, ordenada);
      if (pinos.length) {
        await d4(env, `/documents/${e.d4sign_uuid}/addpins`, { method: 'POST', body: JSON.stringify({ pins: pinos }) })
          .catch((x) => historico(adm, e.pasta_id, 'Posição das assinaturas não aplicada', { erro: (x as Error).message }, email));
      }
      await d4(env, `/documents/${e.d4sign_uuid}/sendtosigner`, {
        method: 'POST', body: JSON.stringify({ skip_email: '0', workflow: corpo.emOrdem === false ? '0' : '1', message: String(corpo.mensagem || '').slice(0, 500) }),
      });
      const agora = new Date().toISOString();
      await adm.from('envelopes').update({ status: 'enviado', enviado_em: agora }).eq('id', e.id);
      await espelho(adm, e, 'enviado', email);
      const ids = idsContratos(e);
      if (ids.length) await adm.from('contratos').update({ assinatura: 'enviado', enviado_assinatura_em: agora }).in('id', ids);
      await historico(adm, e.pasta_id, 'Envelope enviado para assinatura', { assinantes: ordenada.length, documentos: e.documentos.length }, email);
      return json({ ok: true });
    }

    if (acao === 'sincronizar') return json({ ok: true, ...(await sincronizar(env, adm, e, email)) });

    if (acao === 'reenviar') {
      const { data: a } = await adm.from('envelope_assinantes').select('*').eq('id', Number(corpo.assinante)).eq('envelope_id', e.id).maybeSingle();
      if (!a?.key_signer) return erro('Assinante não encontrado.');
      await d4(env, `/documents/${e.d4sign_uuid}/resend`, { method: 'POST', body: JSON.stringify({ email: a.whatsapp || a.email, key_signer: a.key_signer }) });
      return json({ ok: true });
    }

    if (acao === 'cancelar') {
      if (e.status !== 'enviado') return erro('Só envelopes enviados podem ser cancelados aqui.');
      await d4(env, `/documents/${e.d4sign_uuid}/cancel`, { method: 'POST', body: JSON.stringify({ comment: String(corpo.motivo || 'Cancelado pela equipe de vendas.') }) });
      await adm.from('envelopes').update({ status: 'cancelado', cancelado_em: new Date().toISOString(), cancelado_por: email }).eq('id', e.id);
      const ids = idsContratos(e);
      if (ids.length) await adm.from('contratos').update({ assinatura: 'nao_enviado' }).in('id', ids);
      await historico(adm, e.pasta_id, 'Envelope cancelado', {}, email);
      await espelho(adm, e, 'cancelado', email);
      return json({ ok: true });
    }
    return erro('Ação desconhecida.');
  } catch (x) {
    return erro(x instanceof ErroD4 ? x.message : 'Não foi possível falar com a D4Sign agora.', 502);
  }
}

async function hmacHex(chave: string, texto: string) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(chave), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(texto));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

const normal = (t: string) => t.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase().replace(/[^A-Z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();

/** Pinos de assinatura: para cada linha de assinatura gravada na emissão, o assinante com o mesmo nome. */
async function pinosDoEnvelope(adm: SupabaseClient, e: Envelope, assinantes: { nome: string; email: string; papel: string }[]) {
  const ids = e.documentos.filter((d) => d.tipo === 'contrato' && d.d4sign_uuid).map((d) => d.id);
  if (!ids.length) return [];
  const { data } = await adm.from('contratos').select('id, dados').in('id', ids);
  const pinos: Record<string, string>[] = [];
  for (const c of (data ?? []) as { id: string; dados: { assinaturas?: { pagina: number; x: number; y: number; largura: number; nomes: string[] }[] } | null }[]) {
    const doc = e.documentos.find((d) => d.id === c.id);
    for (const p of c.dados?.assinaturas ?? []) {
      const nomes = (p.nomes ?? []).map(normal).filter((n) => n.length >= 3);
      const quem = assinantes.find((a) => {
        const n = normal(a.nome || '');
        return n.length >= 3 && nomes.some((x) => x === n || x.includes(n) || (x.length >= 8 && n.includes(x)));
      });
      if (!quem || !doc?.d4sign_uuid) continue;
      // A D4Sign desenha o carimbo com tamanho fixo (cerca de 150 × 78 na escala da página que recebe).
      // Mandamos a página na escala de pixels de um A4 (794 × 1123) para o carimbo ficar com ~40 × 21 mm,
      // centralizado na linha e com a base encostada nela.
      const PX = 794 / 210, PY = 1123 / 297, LARG_MM = 40, ALT_MM = 21;
      const xMm = p.x + Math.max(0, (p.largura - LARG_MM) / 2), yMm = Math.max(0, p.y - ALT_MM);
      pinos.push({
        document: doc.d4sign_uuid, email: quem.email.trim().toLowerCase(), page: String((doc.pagina_inicial ?? 1) - 1 + p.pagina),
        page_width: '794', page_height: '1123', position_x: String(Math.round(xMm * PX)), position_y: String(Math.round(yMm * PY)), type: '0',
      });
    }
  }
  return pinos;
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
  const { data: e } = await adm.from('envelopes').select('*').eq('d4sign_uuid', uuid).maybeSingle<Envelope>();
  if (e) {
    const tipo = (() => { try { return String((JSON.parse(bruto) as { type_post?: string }).type_post ?? ''); } catch { return new URLSearchParams(bruto).get('type_post') ?? ''; } })();
    const falha = await sincronizar(env, adm, e, 'D4Sign').then(() => null, (x: unknown) => (x instanceof Error ? x.message : String(x)));
    await historico(adm, e.pasta_id, falha ? 'Aviso da D4Sign recebido, mas não foi possível atualizar' : 'Aviso da D4Sign recebido',
      falha ? { tipo, erro: falha } : { tipo }, 'D4Sign').catch(() => null);
  }
  return new Response('ok');
}
