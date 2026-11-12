-- =====================================================================
-- 011 — Cor de apoio e fonte configuráveis + identidade do Duo Haus
--  cor_apoio: cor neutra da marca (faixas do prédio, fundos suaves)
--  fonte: família do Google Fonts usada no sistema
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================
alter table public.config
  add column if not exists cor_apoio text not null default '#CFCBC2' check (cor_apoio ~ '^#[0-9A-Fa-f]{6}$'),
  add column if not exists fonte text not null default 'Archivo' check (fonte ~ '^[A-Za-z0-9 ]{2,40}$');
grant update (cor_apoio, fonte) on public.config to authenticated;

-- Identidade visual do Duo Haus – Wellness + Life (book de marca Casa 7)
update public.config set
  cor_primaria     = '#000000',   -- Duo Black
  cor_destaque     = '#F07F40',   -- Duo Laranja
  cor_apoio        = '#D0BFAE',   -- Duo Areia
  fonte            = '42dot Sans',
  logo_url         = '/marca/duohaus-logo.svg',
  logo_escuro_url  = '/marca/duohaus-logo-escuro.svg',
  imagem_login_url = '/marca/duohaus-login.jpg',
  cidade           = coalesce(cidade, 'Rio Verde, GO'),
  atualizado_em    = now()
where id = 1;
