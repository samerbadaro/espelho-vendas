# Espelho de Vendas

Espelho de unidades em tempo real, para uso interno da Launch.

| Endereço | Para quem | Login |
|---|---|---|
| `/` | Link público (corretores e clientes, no celular) | Não |
| `/tv` | TV do salão de vendas | Não |
| `/painel` | Sec. Vendas e administradores alteram o status | Sim |

O sistema não guarda nenhum dado pessoal de comprador.

## Status e dados exigidos

| Status | O painel pede |
|---|---|
| Reservada | Imobiliária, corretor e cliente |
| Proposta recebida | Valor da venda e PV aprovado (%) |
| Contrato em assinatura | Nada |
| Vendida | Nada |
| Disponível ou Bloqueada (desfazendo negociação) | Motivo |

## Tecnologia

- **Supabase**: banco PostgreSQL, login e tempo real. Toda alteração passa pela função `alterar_status`, que confere permissão, trava a unidade, detecta edição simultânea (erro `CONFLITO`) e grava o histórico.
- **React + Vite**: site estático hospedado no Cloudflare Pages.

## Banco de dados

Rode no **SQL Editor** do Supabase, nesta ordem:

1. `supabase/migrations/001_estrutura.sql`
2. `supabase/migrations/002_unidades.sql` (173 unidades, do 2º ao 17º andar)
3. `supabase/migrations/003_negociacoes.sql` (status Proposta recebida e Contrato em assinatura; dados da negociação visíveis só para a equipe)

### Criar usuário da equipe

1. No Supabase, abra **Authentication → Users → Add user → Create new user**. Informe e-mail e senha e marque **Auto Confirm User**.
2. No SQL Editor, rode:

```sql
insert into public.perfis (user_id, email, papel)
select id, email, 'admin' from auth.users where email = 'email@exemplo.com';
-- use 'vendas' em vez de 'admin' para quem só altera unidades
```

3. Em **Authentication → Sign In / Providers**, desligue **Allow new users to sign up**.

### Testes locais do banco

Com PostgreSQL 16 local, aplique `supabase/tests/stub_supabase.sql` e as migrações num banco `espelho`. Depois rode:

```bash
psql -d espelho -f supabase/tests/testes_permissoes.sql   # 23 testes de permissão e de fluxo
./supabase/tests/teste_simultaneo.sh                      # duas alterações ao mesmo tempo
```

## Rodar o site localmente

```bash
cp .env.example .env    # preencher com a URL e a chave anon/publishable do Supabase
npm install
npm run dev
```

## Publicar no Cloudflare Pages

Conecte o repositório no Cloudflare Pages com estas configurações:

- Build command: `npm run build`
- Output: `dist`
- Variáveis: `VITE_SUPABASE_URL` e `VITE_SUPABASE_ANON_KEY`

## Arquivos

- `src/dados.ts`: conexão com o Supabase, carregamento e tempo real (com reconexão automática)
- `src/Predio.tsx`: desenho do prédio e legenda
- `src/Publico.tsx`, `src/TV.tsx`, `src/Painel.tsx`: as três telas
- `src/estilo.css`: visual
