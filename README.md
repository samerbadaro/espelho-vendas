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
17. `supabase/migrations/017_rodadas.sql` (rodadas de negócios: confirmação de clientes por imobiliária, com limite de vagas)
18. `supabase/migrations/018_rodadas_convidados.sql` (nome completo de cada convidado; só o corretor edita os seus)
19. `supabase/migrations/019_rodadas_limite_3.sql` (no máximo 3 pessoas por cliente nas rodadas)
20. `supabase/migrations/020_recepcao.sql` (recepção de eventos: check-in dos convidados; a lista de cada evento é carregada à parte)
21. `supabase/migrations/021_portal_corretor.sql` (Portal do Corretor: materiais de venda por categoria)
22. `supabase/migrations/022_cadastro_imobiliaria.sql` (cadastro de imobiliárias pelo link público, com aprovação do administrador)
23. `supabase/migrations/023_dados_intermediacao.sql` (CPF, CRECI PF, CNPJ e CRECI PJ obrigatórios para imobiliárias e corretores, usados no contrato de intermediação)
24. `supabase/migrations/024_modulos.sql` (ligar e desligar cada módulo na tela Empreendimento)
25. `supabase/migrations/025_meeting_editar.sql` (editar nome, imobiliária e telefone de convidados no Meeting)
26. `supabase/migrations/026_simulador_logs.sql` (preços e fluxos do simulador; registros de simulações e downloads do portal)
27. `supabase/migrations/027_rodadas_vagas_pessoas.sql` (limite das rodadas conta pessoas: cliente + acompanhantes)
28. `supabase/migrations/028_funil_parceiros.sql` (imobiliária e corretor acompanham as próprias negociações no funil, só leitura)

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

## Propostas (v2, em testes)

Painel → **Propostas**. O corretor monta a proposta (grade como a planilha, botões de preenchimento, "⟲ ajustar" para PV zero), vincula a pasta e envia. A Sec. Vendas aprova, devolve para ajuste ou recusa; aprovar leva a unidade para **Proposta recebida** no espelho, com o valor e o PV. A **carta proposta** sai em PDF com os dados da pasta.

- `supabase/migrations/101_propostas.sql`: parâmetros comerciais, tabelas de venda, propostas, envio e análise.
- `supabase/migrations/102_dados_comerciais_duohaus.sql`: dados da planilha `Compacto_Studio.xlsm` (preço do m² por tipo, Tabelas 1 e 2, peso e tabela de cada unidade).
- `supabase/v2/instalar_v2.sql`: as migrações num arquivo só, para um projeto novo do Supabase.
- `src/proposta/motor.ts`: cálculo (preço, fluxo, VPL, captação, comissão pelo sinal, validações, modelos, PV zero).
- `src/proposta/Proposta.tsx` (editor), `Propostas.tsx` (lista e página), `carta.ts` (PDF), `dadosProposta.ts` (banco).

Regras: nenhum vencimento antes da data da proposta (o dia em que foi criada, no horário de Brasília); proposta enviada só volta a ser editada se a equipe devolver; uma proposta aprovada por unidade; o financiamento entra no VPL no mês seguinte à entrega (securitizado), como na planilha.

Testes: `npm run testar:proposta` (motor × planilha) e `psql -d espelho -f supabase/tests/testes_propostas.sql` (15 testes do banco).

### Ambiente de testes da v2

- `.env.v2` e `wrangler.v2.jsonc`: URL e chave publishable do projeto de testes do Supabase.
- Build: `npm run build:v2`. Deploy: `npx wrangler deploy -c wrangler.v2.jsonc` (Worker `espelho-vendas-v2`, separado da produção).

### Alçadas, escolha de unidades e painéis (v2)

- **Alçadas** (`105`): no envio, o banco recalcula o PV (`pv_proposta`) e define quem aprova. PV ≥ `alcada_auto_pv` e sinal cobrindo a comissão → aprovada na hora; PV ≥ `alcada_vendas_pv` → Sec. Vendas; abaixo → só administrador. Limites na tabela `comercial`.
- **Escolha de unidades** (`106`, menu "Escolha de unidades"): fila de pastas aprovadas (ordem PA), liberadas em lotes (ex.: 10 a cada 30 min). O corretor reserva a unidade com a própria pasta liberada. Liga/desliga em `fila_config` pela tela (administrador).
- **Painéis** (`107`, menu "Painéis"): visão geral, vendas (VSO, funil), rankings de imobiliárias e corretores (unidades e VGV), carteira de recebíveis (propostas aprovadas) e propostas.
- Testes: `supabase/tests/testes_alcadas_fila.sql` (22).
- Atualização do banco de testes: `supabase/v2/atualizar_v2_alcadas_fila_paineis.sql`.

### Meeting (v2)

- Menu **Meeting** (antes "Recepção"): criar o meeting, abrir/fechar inscrições, vagas, link público, inscritos (exportar) e **Confirmação de presença**.
- Página pública de inscrição: `/meeting/<endereço>` (sem login): nome completo, e-mail, celular, imobiliária. Não aceita e-mail nem celular repetidos no mesmo meeting.
- Banco: `108_meeting.sql`. Testes: `supabase/tests/testes_meeting.sql` (16).

### Vários empreendimentos (Fase 1, em andamento)

Decisões de 14/11/2026: **um banco por incorporadora** (o subdomínio escolhe o banco); dentro dela, vários empreendimentos; imobiliárias e corretores veem todos os empreendimentos, com bloqueio opcional por empreendimento; pastas numeradas por empreendimento com sigla (DH-PA-001).

- Etapa A (`109_empreendimentos.sql`, testes `testes_empreendimentos.sql`): tabela de empreendimentos, campo `empreendimento_id` nas tabelas de lançamento (preenchido com o empreendimento padrão), bloqueio por imobiliária. Nenhuma tela muda.
- Tabela de vendas (`110_tabelas_preco.sql`, testes `testes_tabelas.sql`; tela em Painel → Tabela de vendas):
  - versões de tabela (rascunho → agendada → vigente → encerrada); a vigente é a última cuja data de início já passou (sem rotina agendada);
  - preço por unidade e até 3 captações por tabela; parcelas mensais/semestrais em quantidade automática até a entrega, recalculadas pelo mês da venda;
  - arquivo base em Excel para baixar/carregar (preço, captação, área, tipologia), com prévia antes de gravar;
  - reajuste por % em todas, nas filtradas ou nas selecionadas; agendar a próxima tabela para um dia (0h de Brasília) ou ativar na hora;
  - propostas guardam a tabela; depois da virada, rascunhos da tabela antiga precisam ser atualizados para a vigente antes do envio; consulta da próxima tabela na tela da proposta;
  - PDF da tabela (todas as unidades ou só as disponíveis).
- Simulador do Portal com cenários livres (`111_simulador_cenarios.sql`): de 1 a 30 cenários (tipologia, metragem, posição), cada um com 1 a 6 preços de referência, captação mínima e fluxo padrão; quantidade máxima de parcelas calculada pela entrega (semestrais e anuais até um mês antes). Poente/Nascente antigos viram dois cenários.
- Etapas B a E (`112_empreendimento_atual.sql`, testes `testes_multi.sql`): cada login trabalha num empreendimento atual (troca no topo do menu); o banco filtra espelho, pastas, propostas, tabela, Meeting, Portal e fila por ele. Configuração, dados comerciais e fila por empreendimento; códigos das pastas com sigla (DH-P-001, DH-PA-001); painel consolidado; cadastro de empreendimentos com acesso por imobiliária. Empreendimento hipotético para testes: `supabase/v2/seed_residencial_teste.sql` (RT, 25 × 5 unidades).
- Vitrine (`113_vitrine_empreendimentos.sql`): com mais de um empreendimento, o painel abre na vitrine (cards com fachada, "a partir de", entrega, espelho, VSO e avisos; consolidado da incorporadora para a equipe). Ao entrar, o endereço passa a ser `/e/<empreendimento>/painel/...` e cada pedido ao banco leva o cabeçalho `x-empreendimento`: abas diferentes podem ficar em empreendimentos diferentes. Empreendimento ganha fase, cidade e foto da fachada.
