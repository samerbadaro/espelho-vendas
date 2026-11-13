# Espelho de Vendas

Espelho de unidades em tempo real, para uso interno da Launch.

| Endereço | Para quem | Login |
|---|---|---|
| `/` | Link público (corretores e clientes, no celular) | Não |
| `/tv` | TV do salão de vendas | Não |
| `/painel` | Sec. Vendas e administradores: espelho, pastas, imobiliárias e logins. Imobiliárias: as próprias pastas e o espelho | Sim |

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
4. `supabase/migrations/004_pastas.sql` (imobiliárias, pastas, documentos, armazenamento privado e isolamento entre imobiliárias)
5. `supabase/migrations/005_corretores.sql` (corretor vê só as pastas que criou; a imobiliária vê todas as dela e cria os logins dos corretores)
6. `supabase/migrations/006_submissao.sql` (submissão ao incorporador com código PA, comprovante do PIX, telefone/e-mail/profissão obrigatórios)
7. `supabase/migrations/007_correcao_obrigatorios.sql` (campos obrigatórios só ao criar/editar)
8. `supabase/migrations/008_marca_e_visualizacoes.sql` (marca configurável, módulo de pastas opcional, registro de visualização de documentos, indicadores)
9. `supabase/migrations/009_relatorios.sql` (Sec. Vendas vê os nomes dos logins, para relatórios e exportação)
10. `supabase/migrations/010_profissao_conjuge.sql` (profissão do cônjuge; submissão exige nome, CPF e profissão do cônjuge)
11. `supabase/migrations/011_identidade_duohaus.sql` (cor de apoio e fonte configuráveis; identidade visual do Duo Haus)
12. `supabase/migrations/012_funil_e_download.sql` (funil de vendas em kanban; download de todos os documentos com nomes padronizados)
13. `supabase/migrations/013_funil_espelho.sql` (funil ligado ao espelho: mover o card muda o status da unidade)
14. `supabase/migrations/014_reserva_com_pasta.sql` (reserva no espelho exige pasta com documentação aprovada)
15. `supabase/migrations/015_varias_unidades.sql` (uma pasta com várias unidades; um card por unidade no funil)
16. `supabase/migrations/016_permutante.sql` (status Permutante, que funciona como Bloqueada)

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
psql -d espelho -f supabase/tests/testes_pastas.sql       # 61 testes de pastas, submissão e isolamento entre imobiliárias e corretores
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
- Os dados públicos do Supabase estão em `.env.production`.
- Secret obrigatório no Cloudflare (Settings → Variables and Secrets): `SUPABASE_SECRET_KEY`, a chave **secret** do Supabase. Ela é usada só pelo servidor (`worker/index.ts`) para criar logins e trocar senhas.

## Arquivos

- `src/dados.ts`: conexão com o Supabase, carregamento e tempo real (com reconexão automática)
- `src/Predio.tsx`: desenho do prédio e legenda
- `src/Publico.tsx`, `src/TV.tsx`, `src/Painel.tsx`: as três telas
- `src/Pastas.tsx`: pastas, documentos e análise
- `src/Imobiliarias.tsx`: cadastro de imobiliárias e logins
- `worker/index.ts`: servidor (site + criação de logins)
- `src/Inicio.tsx`: tela inicial com indicadores
- `src/Funil.tsx`: funil de vendas (kanban)
- `src/Empreendimento.tsx`: nome, marca e módulos
- `src/ui.tsx`: marca, confirmações, avisos e saída por inatividade
- `src/estilo.css`: visual
