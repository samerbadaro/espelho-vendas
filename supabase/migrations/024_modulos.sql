-- =====================================================================
-- 024 — Ligar e desligar cada módulo do sistema (tela Empreendimento)
--  * Antes só as Pastas podiam ser desligadas. Agora cada estrutura tem
--    o seu interruptor. Desligar só esconde: nenhum dado é apagado.
-- Executar uma única vez no SQL Editor do Supabase.
-- =====================================================================

alter table public.config
  add column if not exists modulo_funil      boolean not null default true,
  add column if not exists modulo_portal     boolean not null default true,
  add column if not exists modulo_rodadas    boolean not null default true,
  add column if not exists modulo_meeting    boolean not null default true,
  add column if not exists modulo_tv         boolean not null default true,
  add column if not exists modulo_cadastro   boolean not null default true,
  add column if not exists modulo_espelho_parceiros boolean not null default true;

comment on column public.config.modulo_funil is 'Funil de vendas (depende das Pastas)';
comment on column public.config.modulo_espelho_parceiros is 'Espelho visível para imobiliárias e corretores no painel';
comment on column public.config.modulo_cadastro is 'Página pública /cadastro para imobiliárias pedirem acesso';

grant update (modulo_funil, modulo_portal, modulo_rodadas, modulo_meeting, modulo_tv,
              modulo_cadastro, modulo_espelho_parceiros) on public.config to authenticated;
