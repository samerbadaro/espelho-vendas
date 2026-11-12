/**
 * Servidor do Espelho de Vendas (Cloudflare Worker).
 * - Entrega o site (pasta dist) para qualquer endereço que não seja /api.
 * - /api/usuarios*: criação de logins e troca de senha. Administradores gerenciam todos;
 *   a imobiliária gerencia somente os corretores dela.
 *   Usa a chave secreta do Supabase, guardada como "secret" no Cloudflare
 *   (SUPABASE_SECRET_KEY) — ela nunca vai para o navegador.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

interface Env {
  ASSETS: { fetch: (req: Request) => Promise<Response> };
  SUPABASE_URL: string;
  SUPABASE_PUBLISHABLE_KEY: string;
  SUPABASE_SECRET_KEY?: string;
}

const json = (dados: unknown, status = 200) =>
  new Response(JSON.stringify(dados), { status, headers: { 'content-type': 'application/json; charset=utf-8' } });
const erro = (mensagem: string, status = 400) => json({ erro: mensagem }, status);

const PAPEIS = ['admin', 'vendas', 'imobiliaria', 'corretor'] as const;
type Papel = (typeof PAPEIS)[number];
const emailValido = (e: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);

interface Chamador { id: string; papel: Papel; imobiliaria_id: string | null }

/** Identifica quem chamou. Só administradores e imobiliárias (gestoras) podem gerenciar logins. */
async function identificar(req: Request, adm: SupabaseClient): Promise<Chamador | null> {
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return null;
  const { data, error } = await adm.auth.getUser(token);
  if (error || !data.user) return null;
  const { data: perfil } = await adm.from('perfis').select('papel, imobiliaria_id').eq('user_id', data.user.id).maybeSingle();
  if (!perfil || (perfil.papel !== 'admin' && perfil.papel !== 'imobiliaria')) return null;
  if (perfil.papel === 'imobiliaria') {
    const { data: imob } = await adm.from('imobiliarias').select('ativa').eq('id', perfil.imobiliaria_id).maybeSingle();
    if (!imob?.ativa) return null;
  }
  return { id: data.user.id, papel: perfil.papel as Papel, imobiliaria_id: perfil.imobiliaria_id };
}

/** Imobiliária só mexe nos corretores dela; admin mexe em todos. */
async function podeGerenciar(quem: Chamador, alvo: string, adm: SupabaseClient) {
  if (alvo === quem.id) return false;
  if (quem.papel === 'admin') return true;
  const { data } = await adm.from('perfis').select('papel, imobiliaria_id').eq('user_id', alvo).maybeSingle();
  return data?.papel === 'corretor' && data.imobiliaria_id === quem.imobiliaria_id;
}

async function api(req: Request, env: Env, caminho: string): Promise<Response> {
  if (req.method !== 'POST') return erro('Método não permitido.', 405);
  if (!env.SUPABASE_SECRET_KEY) return erro('O servidor ainda não foi configurado (chave secreta ausente).', 500);

  const adm = createClient(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  let corpo: Record<string, unknown>;
  try { corpo = await req.json(); } catch { return erro('Requisição inválida.'); }

  // Link temporário (1 minuto) para visualizar um documento.
  // A permissão é conferida pelo banco COM O LOGIN DO USUÁRIO, que também registra a visualização.
  if (caminho === '/api/documentos/link') {
    const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    if (!token) return erro('Faça login novamente.', 401);
    const comoUsuario = createClient(env.SUPABASE_URL, env.SUPABASE_PUBLISHABLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data: arquivo, error } = await comoUsuario.rpc('registrar_visualizacao', { p_documento: String(corpo.documento_id || '') });
    if (error || !arquivo) return erro('Você não tem acesso a este documento.', 403);
    const { data: link, error: eLink } = await adm.storage.from('documentos').createSignedUrl(String(arquivo), 60);
    if (eLink || !link) return erro('Não foi possível gerar o link do documento.', 500);
    return json({ ok: true, url: link.signedUrl });
  }

  const quem = await identificar(req, adm);
  if (!quem) return erro('Você não tem permissão para gerenciar logins.', 403);

  // Criar login
  if (caminho === '/api/usuarios') {
    const email = String(corpo.email || '').trim().toLowerCase();
    const senha = String(corpo.senha || '');
    let papel = String(corpo.papel || '') as Papel;
    const nome = String(corpo.nome || '').trim() || null;
    let imobiliaria_id = corpo.imobiliaria_id ? String(corpo.imobiliaria_id) : null;

    // imobiliária só cria corretores, sempre na própria imobiliária
    if (quem.papel === 'imobiliaria') { papel = 'corretor'; imobiliaria_id = quem.imobiliaria_id; }

    if (!emailValido(email)) return erro('Informe um e-mail válido.');
    if (senha.length < 8) return erro('A senha provisória precisa ter pelo menos 8 caracteres.');
    if (!PAPEIS.includes(papel)) return erro('Perfil inválido.');
    const comImob = papel === 'imobiliaria' || papel === 'corretor';
    if (comImob && !imobiliaria_id) return erro('Escolha a imobiliária.');
    if (papel === 'corretor' && !nome) return erro('Informe o nome do corretor.');

    const criado = await adm.auth.admin.createUser({ email, password: senha, email_confirm: true });
    if (criado.error || !criado.data.user) {
      const msg = criado.error?.message || '';
      return erro(/already|registered|exists/i.test(msg) ? 'Já existe um login com este e-mail.' : 'Não foi possível criar o login.');
    }
    const { error: ePerfil } = await adm.from('perfis').insert({
      user_id: criado.data.user.id, email, nome, papel,
      imobiliaria_id: comImob ? imobiliaria_id : null, trocar_senha: true,
    });
    if (ePerfil) {
      await adm.auth.admin.deleteUser(criado.data.user.id);
      return erro('Não foi possível salvar o perfil do login.');
    }
    return json({ ok: true, user_id: criado.data.user.id });
  }

  const user_id = String(corpo.user_id || '');
  if (!(await podeGerenciar(quem, user_id, adm))) return erro('Você não pode alterar este login.', 403);

  // Definir nova senha provisória
  if (caminho === '/api/usuarios/senha') {
    const senha = String(corpo.senha || '');
    if (senha.length < 8) return erro('A senha provisória precisa ter pelo menos 8 caracteres.');
    const { error } = await adm.auth.admin.updateUserById(user_id, { password: senha });
    if (error) return erro('Não foi possível trocar a senha.');
    await adm.from('perfis').update({ trocar_senha: true }).eq('user_id', user_id);
    return json({ ok: true });
  }

  // Remover login (as pastas criadas continuam com a imobiliária)
  if (caminho === '/api/usuarios/remover') {
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
