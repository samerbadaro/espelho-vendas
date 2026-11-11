-- Simula o mínimo do Supabase (auth.users, auth.uid(), papéis anon/authenticated)
-- APENAS para testes locais. Não executar no Supabase.
create extension if not exists pgcrypto;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;
grant usage on schema public, auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
-- No Supabase, por padrão, anon/authenticated recebem tudo no schema public.
alter default privileges in schema public grant all on tables to anon, authenticated;
