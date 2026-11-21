# Regras do projeto (Gestor Launch Machine)

## Manual do sistema — obrigatório em toda entrega

O sistema tem um manual dentro do painel (`/painel/manual`). O texto fica em
`src/manual/conteudo.ts`. **Toda entrega que cria, muda ou remove um recurso visível
para o usuário atualiza o manual no mesmo commit:**

1. Atualize (ou crie) o capítulo do módulo em `CAPITULOS`:
   - `papeis`: quem vê o capítulo; `modulo`: de qual módulo ele depende.
   - Blocos com `papeis` aparecem só para esses perfis. Escreva passo a passo,
     com os nomes exatos dos botões e campos da tela.
   - `responsabilidades`: o que se espera de cada perfil naquele módulo.
2. Acrescente uma linha no topo de `NOVIDADES` (data, título, itens; `papeis`
   quando a novidade for só da equipe).
3. Atualize `REVISAO_MANUAL` com a data.
4. Módulo novo: inclua o id em `ModuloManual` e a regra de visibilidade em
   `modulosDe` (`src/Painel.tsx`), igual à regra do menu.

Os vídeos não ficam no código: o administrador cola o link na própria tela do
manual (tabela `manual_videos`, um por capítulo; use o `id` do capítulo).

## Fluxo de publicação

- Tudo vai primeiro para a homologação (branch `homologacao`, banco de homologação).
- Produção só depois da aprovação do Samer: ele roda o SQL na base principal e só
  então a branch `main` é publicada.
- Cada migração nova tem teste em `supabase/tests/teste_NNN.sql`.

## Segurança

- Nunca pedir nem aceitar chaves secretas no chat (Supabase secret, Anthropic,
  D4Sign, Brevo): elas vão como segredos no Cloudflare ou no Supabase.
- Homologação usa só dados fictícios. Dados pessoais não entram no repositório.
- Funções internas do banco: `revoke ... from public, anon, authenticated`
  (o Supabase libera funções novas para usuários logados por padrão).
