/**
 * Servidor do Espelho de Vendas (Cloudflare Worker).
 * - Entrega o site (pasta dist) para qualquer endereço que não seja /api.
 * - /api/usuarios*: criação de logins e troca de senha, SOMENTE para administradores.
 *   Usa a chave secreta do Supabase, guardada como "secret" no Cloudflare
 *   (SUPABASE_SECRET_KEY) — ela nunca vai para o navegador.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

interface Env {
  ASSETS: { fetch: (req: Request) => Promise<Response> };
  SUPABASE_URL: string;
  SUPABASE_SECRET_KEY?: string;
}

const json = (dados: unknown, status = 200) =>
  new Response(JSON.stringify(dados), { status, headers: { 'content-type': 'application/json; charset=utf-8' } });
const erro = (mensagem: string, status = 400) => json({ erro: mensagem }, status);

const PAPEIS = ['admin', 'vendas', 'imobiliaria'] as const;
const emailValido = (e: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);

async function exigirAdmin(req: Request, adm: SupabaseClient) {
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return null;
  const { data, error } = await adm.auth.getUser(token);
  if (error || !data.user) return null;
  const { data: perfil } = await adm.from('perfis').select('papel').eq('user_id', data.user.id).maybeSingle();
  return perfil?.papel === 'admin' ? data.user : null;
}

async function api(req: Request, env: Env, caminho: string): Promise<Response> {
  if (req.method !== 'POST') return erro('Método não permitido.', 405);
  if (!env.SUPABASE_SECRET_KEY) return erro('O servidor ainda não foi configurado (chave secreta ausente).', 500);

  const adm = createClient(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = await exigirAdmin(req, adm);
  if (!admin) return erro('Somente administradores podem fazer isso.', 403);

  let corpo: Record<string, unknown>;
  try { corpo = await req.json(); } catch { return erro('Requisição inválida.'); }

  // Criar login
  if (caminho === '/api/usuarios') {
    const email = String(corpo.email || '').trim().toLowerCase();
    const senha = String(corpo.senha || '');
    const papel = String(corpo.papel || '') as (typeof PAPEIS)[number];
    const nome = String(corpo.nome || '').trim() || null;
    const imobiliaria_id = corpo.imobiliaria_id ? String(corpo.imobiliaria_id) : null;

    if (!emailValido(email)) return erro('Informe um e-mail válido.');
    if (senha.length < 8) return erro('A senha provisória precisa ter pelo menos 8 caracteres.');
    if (!PAPEIS.includes(papel)) return erro('Perfil inválido.');
    if (papel === 'imobiliaria' && !imobiliaria_id) return erro('Escolha a imobiliária.');

    const criado = await adm.auth.admin.createUser({ email, password: senha, email_confirm: true });
    if (criado.error || !criado.data.user) {
      const msg = criado.error?.message || '';
      return erro(/already|registered|exists/i.test(msg) ? 'Já existe um login com este e-mail.' : 'Não foi possível criar o login.');
    }
    const { error: ePerfil } = await adm.from('perfis').insert({
      user_id: criado.data.user.id, email, nome, papel,
      imobiliaria_id: papel === 'imobiliaria' ? imobiliaria_id : null, trocar_senha: true,
    });
    if (ePerfil) {
      await adm.auth.admin.deleteUser(criado.data.user.id);
      return erro('Não foi possível salvar o perfil do login.');
    }
    return json({ ok: true, user_id: criado.data.user.id });
  }

  // Definir nova senha provisória
  if (caminho === '/api/usuarios/senha') {
    const user_id = String(corpo.user_id || '');
    const senha = String(corpo.senha || '');
    if (senha.length < 8) return erro('A senha provisória precisa ter pelo menos 8 caracteres.');
    const { error } = await adm.auth.admin.updateUserById(user_id, { password: senha });
    if (error) return erro('Não foi possível trocar a senha.');
    await adm.from('perfis').update({ trocar_senha: true }).eq('user_id', user_id);
    return json({ ok: true });
  }

  // Remover login
  if (caminho === '/api/usuarios/remover') {
    const user_id = String(corpo.user_id || '');
    if (user_id === admin.id) return erro('Você não pode remover o seu próprio login.');
    const { error } = await adm.auth.admin.deleteUser(user_id);
    if (error) return erro('Não foi possível remover o login.');
    return json({ ok: true });
  }

  return erro('Endereço não encontrado.', 404);
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname.startsWith('/api/')) {
      try { return await api(req, env, url.pathname.replace(/\/+$/, '')); }
      catch { return erro('Erro inesperado no servidor.', 500); }
    }
    return env.ASSETS.fetch(req);
  },
};
