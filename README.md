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
29. `supabase/migrations/029_corretor_responsavel.sql` (corretor responsável pela pasta: equipe e imobiliária atribuem)
30. `supabase/migrations/030_treinamentos.sql` (agenda de treinamentos 18 e 19/11: inscrição por horário, presença e relatórios)
31. `supabase/migrations/031_treinamentos_ajuste.sql` (18/11 a partir das 14h, 19/11 a partir das 9h, turmas de 20)
32. `supabase/migrations/032_recepcionista.sql` (perfil Recepcionista: acesso só ao Meeting)
33. `supabase/migrations/033_treinamentos_horarios.sql` (administrador adiciona e exclui horários de treinamento)
34. `supabase/migrations/034_portal_premiacao.sql` (Portal do Corretor: categoria Regras da premiação)
35. `supabase/manutencao/035_backup_antes.sql` e depois `supabase/migrations/035_propostas.sql` (Propostas, trazidas da v2; módulo começa desligado). Para voltar atrás: `supabase/manutencao/035_reverter.sql`.
36. `supabase/migrations/036_propostas_permissao.sql` (libera salvar a chave Propostas em Empreendimento)
37. `supabase/migrations/037_rodadas_convite.sql` (convite da rodada: o administrador anexa; baixa quem tem cliente confirmado)
38. `supabase/migrations/038_dados_contrato.sql` (dados para contrato com leitura dos documentos por IA; requer o secret ANTHROPIC_API_KEY no Cloudflare)
39. `supabase/migrations/039_regime_bens.sql` (regime de bens; em separação total/obrigatória o cônjuge pode ficar fora do contrato)
40. `supabase/migrations/040_pessoa_juridica.sql` (comprador pessoa jurídica: razão social, CNPJ, representante legal e documentos da empresa)
41. `supabase/migrations/041_contratos.sql` (módulo Contratos: dados da incorporação, quadro de áreas, conferência do pagamento e documentos emitidos)
42. `supabase/migrations/042_contratos_versoes.sql` (contratos: Word editável e versões ajustadas antes da assinatura)
43. `supabase/migrations/043_modelos_contrato.sql` (modelos de contrato em Word com marcadores, um ativo por documento)
44. `supabase/migrations/044_d4sign.sql` (assinatura eletrônica D4Sign: assinantes, situações, PDF assinado; requer D4SIGN_TOKEN e D4SIGN_CRYPTKEY no Cloudflare)
45. `supabase/migrations/045_pix_sinal.sql` (Pix do sinal: comprovante anexado ou Pix gerado pelo sistema, configurável; provedor simulado para testes)

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

## Homologação (teste antes da produção)

| | Homologação | Produção |
|---|---|---|
| Endereço | homolog.gestorlm.com.br | casa7.gestorlm.com.br |
| Branch | `homologacao` | `main` |
| Supabase | duo-haus-homolog (`iujmvrnxfwsyqpzktfjr`) | `mtlzwuiqznsyqasmdkew` |
| Cloudflare | `espelho-vendas-homolog` (`wrangler.homolog.jsonc`, `npm run build:homolog`) | `espelho-vendas` |

Fluxo: tudo entra primeiro na `homologacao` (e o SQL no banco de homologação); depois de aprovado, vai para a `main` e o mesmo SQL é rodado na produção.
Banco novo de homologação: `sh supabase/homolog/montar.sh` gera `estrutura_completa.sql` (todas as migrações) e depois roda-se `supabase/homolog/semente.sql` (dados fictícios; tem trava contra produção).
