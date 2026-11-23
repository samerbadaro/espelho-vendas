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

## Mapa do sistema (contexto para conversas novas)

Sistema de vendas do Duo Haus – Wellness + Life (Casa 7 Incorporadora, Rio Verde-GO),
mantido pela Launch Machine (Samer). O usuário fala português do Brasil: responda em pt-BR,
direto, sem jargão técnico desnecessário.

### Ambientes

| | Homologação | Produção |
| --- | --- | --- |
| Branch | `homologacao` | `main` |
| Site | homolog.gestorlm.com.br | casa7.gestorlm.com.br |
| Worker Cloudflare | `espelho-vendas-homolog` (`wrangler.homolog.jsonc`) | `espelho-vendas` (`wrangler.jsonc`) |
| Supabase | `iujmvrnxfwsyqpzktfjr` (acesso pelo conector) | `mtlzwuiqznsyqasmdkew` (sem acesso: o Samer roda o SQL) |

D4Sign: os dois ambientes usam a API real (`D4SIGN_AMBIENTE=producao`); a homologação usa a conta
pessoal de testes do Samer e a produção, a conta da Casa 7 (chaves e cofre diferentes).

O push na branch publica sozinho (cerca de 1 minuto). Segredos do servidor no Cloudflare:
`ANTHROPIC_API_KEY`, `BREVO_API_KEY`, chaves da D4Sign.

### Como publicar uma entrega

1. Código e migração na `homologacao`; migração aplicada no banco de homologação; teste
   `supabase/tests/teste_NNN.sql`; manual atualizado (`src/manual/conteudo.ts`).
2. Gerar `PRODUCAO_NNN_<assunto>.sql` (a migração + uma consulta de conferência que devolve
   colunas `*_ok` = true) e entregar ao Samer.
3. Só depois que o Samer confirmar que rodou: merge de `homologacao` em `main` e push.
   Se a entrega não tem migração, pode ir direto para a `main` com o ok dele.
   Nunca publique na `main` código que dependa de coluna ou função que ainda não está em produção.

### Onde fica cada coisa

- `src/Painel.tsx`: menu, rotas, espelho e diálogo de status da unidade; `modulosDe` (visibilidade).
- `src/Pastas.tsx` (pastas e documentos, PF e PJ), `src/PixSinal.tsx`, `src/Funil.tsx`, `src/Leads.tsx`,
  `src/Portal.tsx`, `src/Rodadas.tsx`, `src/Treinamentos.tsx`, `src/Recepcao.tsx`, `src/TV.tsx`.
- `src/proposta/`: motor da proposta (`motor.ts`), editor, lista, parâmetros, carta/resumo (`carta.ts`, PDF e Word).
- `src/contrato/`: leitura com IA (`leitura.ts`), conferência de dados, Quadro Resumo e Normas
  (`gerador.ts`, `marcadores.ts`), envelope D4Sign (`Envelope.tsx`), data do contrato.
- `src/manual/`: manual por perfil (`conteudo.ts`) e página (`Manual.tsx`).
- `worker/`: `index.ts` (rotas e cron), `d4sign.ts`, `leads.ts` (entrada da planilha e avisos Brevo).
- `supabase/migrations/001…050`: 035 propostas, 041–046 contratos/D4Sign/Pix, 047 leads,
  048 vídeos do manual, 049 PJ com 2º representante, 050 desistência (Devolução de Pix → Cliente cancelado).
- `src/proposta/Fluxo.tsx`: fluxo consolidado do incorporador (só admin, /painel/fluxo).
- Testes locais do banco: `/tmp/rodar.sh` (Postgres local) quando existir; senão, rode os testes no banco de homologação.
- Prévia local: `.preview/` (Supabase simulado; `?logado`, `&imob`, `&corretor`, `&contrato`).

### Regras de negócio que já confundiram

- Alçada da proposta: aprova sozinha com PV ≥ `alcada_auto_pv` (100%) e sinal cobrindo a comissão;
  Sec. Vendas a partir de `alcada_vendas_pv` (98%); abaixo, só o administrador. Editável em
  Propostas › Parâmetros da proposta (tabela `comercial`, id 1).
- PJ: o cônjuge do representante não entra; vale o comprovante de estado civil. 2º representante
  em `pastas.representante2` (jsonb) e documentos com `pessoa = 'representante2'`.
- Exportações escondem CPF, telefone e e-mail por padrão.

### Roadmap

Lista viva de prioridades (Agora / Próximo / Depois):
https://claude.ai/artifact/KsezRiztqawJi8498yHyGd — leia antes de propor trabalho novo e
atualize o status do item ao entregar.
