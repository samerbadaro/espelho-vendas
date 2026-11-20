/**
 * Servidor do Espelho de Vendas (Cloudflare Worker).
 * - Entrega o site (pasta dist) para qualquer endereço que não seja /api.
 * - /api/usuarios*: criação de logins e troca de senha. Administradores gerenciam todos;
 *   a imobiliária gerencia somente os corretores dela.
 *   Usa a chave secreta do Supabase, guardada como "secret" no Cloudflare
 *   (SUPABASE_SECRET_KEY) — ela nunca vai para o navegador.
 * - /api/contrato/ler: leitura dos documentos da pasta com IA (Claude). Só a equipe, só com
 *   proposta aprovada. A chave da IA (ANTHROPIC_API_KEY) também é "secret" no Cloudflare.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

interface Env {
  ASSETS: { fetch: (req: Request) => Promise<Response> };
  SUPABASE_URL: string;
  SUPABASE_PUBLISHABLE_KEY: string;
  SUPABASE_SECRET_KEY?: string;
  ANTHROPIC_API_KEY?: string;
}

const json = (dados: unknown, status = 200) =>
  new Response(JSON.stringify(dados), { status, headers: { 'content-type': 'application/json; charset=utf-8' } });
const erro = (mensagem: string, status = 400) => json({ erro: mensagem }, status);

const PAPEIS = ['admin', 'vendas', 'imobiliaria', 'corretor', 'recepcao'] as const;
type Papel = (typeof PAPEIS)[number];
const emailValido = (e: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);
const digitos = (s: unknown) => String(s ?? '').replace(/\D/g, '');
const creciLimpo = (s: unknown) => String(s ?? '').trim().replace(/\s+/g, ' ').toUpperCase().slice(0, 30);
const nomeCompleto = (s: string) => s.trim().split(/\s+/).length >= 2;
function cpfValido(v: unknown) {
  const d = digitos(v);
  if (d.length !== 11 || /^(\d)\1{10}$/.test(d)) return false;
  const dv = (n: number) => { let s = 0; for (let i = 0; i < n; i++) s += Number(d[i]) * (n + 1 - i); const r = (s * 10) % 11; return r === 10 ? 0 : r; };
  return dv(9) === Number(d[9]) && dv(10) === Number(d[10]);
}
function cnpjValido(v: unknown) {
  const d = digitos(v);
  if (d.length !== 14 || /^(\d)\1{13}$/.test(d)) return false;
  const calc = (n: number) => { const pesos = n === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
    const r = pesos.reduce((a, p, i) => a + p * Number(d[i]), 0) % 11; return r < 2 ? 0 : 11 - r; };
  return calc(12) === Number(d[12]) && calc(13) === Number(d[13]);
}

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

  // Todos os documentos de uma pasta, com nomes padronizados, para baixar num único .zip (somente equipe)
  if (caminho === '/api/documentos/pacote') {
    const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    if (!token) return erro('Faça login novamente.', 401);
    const comoUsuario = createClient(env.SUPABASE_URL, env.SUPABASE_PUBLISHABLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data: docs, error } = await comoUsuario.rpc('registrar_download', { p_pasta: String(corpo.pasta_id || '') });
    if (error) return erro('Somente a equipe de vendas pode baixar todos os documentos.', 403);
    const lista = (docs ?? []) as { caminho: string; nome_arquivo: string; sigla: string; nome_pessoa: string; codigo: string; cliente: string }[];
    if (!lista.length) return erro('Esta pasta ainda não tem documentos.', 404);

    const limpar = (t: string) => t.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_|_$/g, '');
    const usados = new Map<string, number>();
    const { data: links, error: eLinks } = await adm.storage.from('documentos').createSignedUrls(lista.map((d) => d.caminho), 120);
    if (eLinks || !links) return erro('Não foi possível preparar os arquivos.', 500);
    const arquivos = lista.map((d, i) => {
      const ext = (d.nome_arquivo.match(/\.([A-Za-z0-9]{2,5})$/)?.[1] || 'pdf').toLowerCase();
      const base = `${limpar(d.sigla)}_${limpar(d.nome_pessoa.trim().split(/\s+/)[0] || 'CLIENTE')}`;
      const n = (usados.get(base) ?? 0) + 1;
      usados.set(base, n);
      return { nome: `${n > 1 ? `${base}_${n}` : base}.${ext}`, url: links[i]?.signedUrl };
    }).filter((a) => a.url);
    return json({ ok: true, nome_zip: `${limpar(lista[0].codigo)}_${limpar(lista[0].cliente)}.zip`, arquivos });
  }

  // Cadastro público de imobiliária: cria o login (sem acesso) e a solicitação para o administrador aprovar
  if (caminho === '/api/cadastro-imobiliaria') {
    if (String(corpo.site || '')) return json({ ok: true }); // campo invisível preenchido: robô
    const txt = (k: string, max = 120) => String(corpo[k] ?? '').trim().replace(/\s+/g, ' ').slice(0, max);
    const dados = {
      imobiliaria_nome: txt('imobiliaria'),
      cnpj: digitos(corpo.cnpj),
      creci: creciLimpo(corpo.creci),
      cidade: txt('cidade', 80) || null,
      responsavel: txt('responsavel'),
      responsavel_cpf: digitos(corpo.cpf),
      responsavel_creci: creciLimpo(corpo.creci_pf),
      email: txt('email').toLowerCase(),
      telefone: txt('telefone', 20).replace(/\D/g, ''),
    };
    const senha = String(corpo.senha || '');
    if (dados.imobiliaria_nome.length < 2) return erro('Informe o nome da imobiliária.');
    if (!cnpjValido(dados.cnpj)) return erro('O CNPJ não é válido. Confira os números.');
    if (!dados.creci) return erro('Informe o CRECI PJ da imobiliária.');
    if (!nomeCompleto(dados.responsavel)) return erro('Informe o nome completo do responsável.');
    if (!cpfValido(dados.responsavel_cpf)) return erro('O CPF do responsável não é válido. Confira os números.');
    if (!dados.responsavel_creci) return erro('Informe o CRECI PF do responsável.');
    if (!emailValido(dados.email)) return erro('Informe um e-mail válido.');
    if (dados.telefone.length < 10) return erro('Informe um telefone com DDD.');
    if (senha.length < 8) return erro('A senha precisa ter pelo menos 8 caracteres.');

    const { data: cfg } = await adm.from('config').select('*').eq('id', 1).maybeSingle();
    if (cfg && (cfg as { modulo_cadastro?: boolean }).modulo_cadastro === false) return erro('O cadastro de novas imobiliárias está fechado no momento. Fale com a equipe de vendas.', 403);

    const ip = req.headers.get('cf-connecting-ip') || '';
    const desde = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    if (ip) {
      const { count } = await adm.from('solicitacoes_imobiliaria').select('id', { count: 'exact', head: true }).eq('ip', ip).gte('criada_em', desde);
      if ((count ?? 0) >= 5) return erro('Muitos cadastros enviados deste local hoje. Tente amanhã ou fale com a administração.', 429);
    }
    const { count: pendentes } = await adm.from('solicitacoes_imobiliaria').select('id', { count: 'exact', head: true }).eq('status', 'pendente');
    if ((pendentes ?? 0) >= 300) return erro('O cadastro está temporariamente fechado. Fale com a administração.', 429);

    // e-mail que já se cadastrou antes
    const { data: anterior } = await adm.from('solicitacoes_imobiliaria').select('id, user_id, status').eq('email', dados.email).maybeSingle();
    if (anterior?.status === 'pendente') return erro('Já existe um cadastro em análise com este e-mail. Aguarde a aprovação.');
    if (anterior?.status === 'aprovada') return erro('Este e-mail já tem acesso. Entre pela tela de login.');
    if (anterior?.status === 'recusada') {
      const { error: eSenha } = await adm.auth.admin.updateUserById(anterior.user_id, { password: senha });
      if (eSenha) return erro(/pwned|leak|weak/i.test(eSenha.message) ? 'Essa senha é fraca ou já apareceu em vazamentos. Escolha outra.' : 'Não foi possível enviar o cadastro.');
      await adm.from('solicitacoes_imobiliaria').update({ ...dados, ip, status: 'pendente', motivo: null, analisada_em: null, analisada_por: null, criada_em: new Date().toISOString() }).eq('id', anterior.id);
      return json({ ok: true });
    }
    const { data: jaTemPerfil } = await adm.from('perfis').select('user_id').eq('email', dados.email).maybeSingle();
    if (jaTemPerfil) return erro('Este e-mail já tem acesso. Entre pela tela de login.');

    const criado = await adm.auth.admin.createUser({ email: dados.email, password: senha, email_confirm: true });
    if (criado.error || !criado.data.user) {
      const msg = criado.error?.message || '';
      if (/pwned|leak|weak/i.test(msg)) return erro('Essa senha é fraca ou já apareceu em vazamentos. Escolha outra.');
      return erro(/already|registered|exists/i.test(msg) ? 'Este e-mail já tem um login. Entre pela tela de login ou fale com a administração.' : 'Não foi possível enviar o cadastro.');
    }
    const { error: eSol } = await adm.from('solicitacoes_imobiliaria').insert({ ...dados, ip, user_id: criado.data.user.id });
    if (eSol) {
      await adm.auth.admin.deleteUser(criado.data.user.id);
      return erro('Não foi possível enviar o cadastro.');
    }
    return json({ ok: true });
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
    const cpf = digitos(corpo.cpf);
    const creci = creciLimpo(corpo.creci);
    if (comImob) {
      if (!nome || !nomeCompleto(nome)) return erro('Informe o nome completo.');
      if (!cpfValido(cpf)) return erro('O CPF não é válido. Confira os números.');
      if (!creci) return erro('Informe o CRECI.');
    }

    const criado = await adm.auth.admin.createUser({ email, password: senha, email_confirm: true });
    if (criado.error || !criado.data.user) {
      const msg = criado.error?.message || '';
      return erro(/already|registered|exists/i.test(msg) ? 'Já existe um login com este e-mail.' : 'Não foi possível criar o login.');
    }
    const { error: ePerfil } = await adm.from('perfis').insert({
      user_id: criado.data.user.id, email, nome, papel,
      imobiliaria_id: comImob ? imobiliaria_id : null, trocar_senha: true,
      cpf: comImob ? cpf : null, creci: comImob ? creci : null,
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

const LIMITE_LEITURA = 30 * 1024 * 1024; // 30 MB (a IA aceita até 32 MB por pedido)

/**
 * Leitura com IA. O navegador da equipe já monta o pedido (documentos reduzidos);
 * aqui só conferimos quem pede e repassamos à IA com a chave secreta, sem abrir o conteúdo
 * (abrir arquivos grandes estouraria o tempo de processamento do servidor).
 */
async function lerDocumentos(req: Request, env: Env, url: URL): Promise<Response> {
  if (req.method !== 'POST') return erro('Método não permitido.', 405);
  if (!env.ANTHROPIC_API_KEY) return erro('A leitura com IA ainda não foi configurada (chave da IA ausente).', 500);
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return erro('Faça login novamente.', 401);
  const tamanho = Number(req.headers.get('content-length') || 0);
  if (!tamanho || tamanho > LIMITE_LEITURA) return erro('Os documentos passam do limite de 30 MB por leitura.', 413);
  const comoUsuario = createClient(env.SUPABASE_URL, env.SUPABASE_PUBLISHABLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  // o banco confere: login da equipe + proposta aprovada nesta pasta
  const { error } = await comoUsuario.rpc('documentos_para_leitura', { p_pasta: url.searchParams.get('pasta') || '' });
  if (error) return erro(error.message === 'PROPOSTA_NAO_APROVADA' ? 'A leitura só fica disponível depois da proposta aprovada.' : 'Somente a equipe de vendas pode usar a leitura com IA.', 403);
  const resp = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'x-api-key': env.ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: await req.arrayBuffer(),   // só copia os bytes, sem interpretar
  });
  return new Response(resp.body, { status: resp.status, headers: { 'content-type': resp.headers.get('content-type') || 'application/json' } });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname.replace(/\/+$/, '') === '/api/contrato/ler') {
      try { return await lerDocumentos(req, env, url); }
      catch { return erro('Não foi possível falar com a IA agora. Tente de novo em instantes.', 502); }
    }
    if (url.pathname.startsWith('/api/')) {
      try { return await api(req, env, url.pathname.replace(/\/+$/, '')); }
      catch { return erro('Erro inesperado no servidor.', 500); }
    }
    return env.ASSETS.fetch(req);
  },
};
