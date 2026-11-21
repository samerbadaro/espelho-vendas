/**
 * Leads das campanhas do Meta.
 *  - POST /api/leads/entrada: o script da planilha do Google envia as linhas novas (cabeçalho "x-chave").
 *  - A cada minuto (Cron Trigger): prazos vencidos voltam ao rodízio e os e-mails pendentes saem pela Brevo.
 * E-mails: segredo BREVO_API_KEY no Cloudflare + remetente em Leads → Configuração. Sem a chave, os avisos
 * ficam na fila e aparecem só no painel.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

export interface EnvLeads {
  SUPABASE_URL: string;
  SUPABASE_SECRET_KEY?: string;
  BREVO_API_KEY?: string;
}

const json = (dados: unknown, status = 200) =>
  new Response(JSON.stringify(dados), { status, headers: { 'content-type': 'application/json; charset=utf-8' } });

const admin = (env: EnvLeads) => createClient(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY!, { auth: { persistSession: false, autoRefreshToken: false } });

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

function html(linhas: string[], botao: string | null, link: string | null) {
  const [primeira, ...resto] = linhas;
  return `<div style="font-family:Arial,sans-serif;font-size:15px;color:#222;max-width:520px">
<p style="font-size:16px">${esc(primeira ?? '')}</p>
${resto.length ? `<table style="border-collapse:collapse;margin:12px 0">${resto.map((l) => `<tr><td style="padding:3px 0;color:#444">${esc(l)}</td></tr>`).join('')}</table>` : ''}
${link ? `<p style="margin:22px 0"><a href="${esc(link)}" style="background:#1f1f1f;color:#fff;padding:12px 20px;border-radius:6px;text-decoration:none;font-weight:bold">${esc(botao || 'Abrir')}</a></p>` : ''}
<p style="font-size:12px;color:#888">Telefone e e-mail do cliente aparecem no sistema depois que você assumir o lead.</p></div>`;
}

/** Envia os e-mails pendentes (até 50 por vez). */
export async function enviarAvisos(env: EnvLeads, adm: SupabaseClient) {
  if (!env.BREVO_API_KEY) return { enviados: 0, motivo: 'sem chave' };
  const [{ data: cfg }, { data: fila }] = await Promise.all([
    // remetente: o primeiro empreendimento com remetente configurado (um por conta Brevo)
    adm.from('leads_config').select('remetente_email, remetente_nome, url_app').not('remetente_email', 'is', null).order('id').limit(1).maybeSingle(),
    adm.rpc('leads_notificacoes_pendentes', { p_limite: 50 }),
  ]);
  if (!cfg?.remetente_email) return { enviados: 0, motivo: 'sem remetente' };
  let enviados = 0;
  for (const n of (fila ?? []) as { id: number; para: string; assunto: string; linhas: string[]; botao: string | null; caminho: string | null }[]) {
    const link = n.caminho && cfg.url_app ? `${cfg.url_app.replace(/\/+$/, '')}${n.caminho}` : null;
    try {
      const r = await fetch('https://api.brevo.com/v3/smtp/email', {
        method: 'POST',
        headers: { 'api-key': env.BREVO_API_KEY, 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({
          sender: { email: cfg.remetente_email, name: cfg.remetente_nome || 'Leads' },
          to: [{ email: n.para }], subject: n.assunto,
          htmlContent: html(n.linhas ?? [], n.botao, link),
          textContent: [...(n.linhas ?? []), link ? `\n${n.botao || 'Abrir'}: ${link}` : ''].join('\n'),
        }),
      });
      const ok = r.ok;
      await adm.rpc('leads_marcar_notificacao', { p_id: n.id, p_ok: ok, p_erro: ok ? null : `${r.status} ${(await r.text()).slice(0, 200)}` });
      if (ok) enviados++;
    } catch (e) {
      await adm.rpc('leads_marcar_notificacao', { p_id: n.id, p_ok: false, p_erro: String(e).slice(0, 200) });
    }
  }
  return { enviados };
}

/** POST /api/leads/entrada — chamado pelo script da planilha. */
export async function entradaLeads(req: Request, env: EnvLeads): Promise<Response> {
  if (req.method !== 'POST') return json({ erro: 'Método não permitido.' }, 405);
  if (!env.SUPABASE_SECRET_KEY) return json({ erro: 'Servidor não configurado.' }, 500);
  const chave = req.headers.get('x-chave') || '';
  let corpo: { linhas?: unknown[]; origem?: string };
  try { corpo = await req.json(); } catch { return json({ erro: 'Requisição inválida.' }, 400); }
  const linhas = Array.isArray(corpo.linhas) ? corpo.linhas.slice(0, 500) : [];
  const adm = admin(env);
  const { data, error } = await adm.rpc('receber_leads', {
    p_chave: chave, p_linhas: linhas, p_origem: String(corpo.origem || 'planilha').slice(0, 60), p_url: new URL(req.url).origin,
  });
  if (error) return json({ erro: error.message.includes('CHAVE_INVALIDA') ? 'Chave inválida.' : 'Não foi possível registrar os leads.' }, error.message.includes('CHAVE_INVALIDA') ? 401 : 500);
  await enviarAvisos(env, adm).catch(() => null);
  return json({ ok: true, ...(data as object) });
}

/** Cron a cada minuto. */
export async function rotinaLeads(env: EnvLeads) {
  if (!env.SUPABASE_SECRET_KEY) return;
  const adm = admin(env);
  await adm.rpc('processar_leads');
  await enviarAvisos(env, adm);
}
