// Campos do cadastro "Dados para contrato" do empreendimento (vendedora, registros, textos fixos).
// Os valores-exemplo são FICTÍCIOS: servem para testar a emissão até chegar o modelo oficial.
export interface CampoEmp { chave: string; rotulo: string; grupo: string; longo?: boolean; exemplo: string; soAssinatura?: boolean }

export const CAMPOS_EMPREENDIMENTO: CampoEmp[] = [
  { grupo: 'Vendedora', chave: 'vendedora.razao_social', rotulo: 'Razão social', exemplo: 'INCORPORADORA EXEMPLO SPE LTDA' },
  { grupo: 'Vendedora', chave: 'vendedora.cnpj', rotulo: 'CNPJ', exemplo: '11.222.333/0001-81' },
  { grupo: 'Vendedora', chave: 'vendedora.endereco', rotulo: 'Endereço da sede', longo: true, exemplo: 'Rua Fictícia, nº 100, Sala 1, Centro, Rio Verde – Goiás, CEP 75.900-000' },
  { grupo: 'Vendedora', chave: 'vendedora.junta', rotulo: 'Junta comercial', exemplo: 'JUCEG' },
  { grupo: 'Vendedora', chave: 'vendedora.registro', rotulo: 'Nº do registro do contrato social', exemplo: '52200000000' },
  { grupo: 'Vendedora', chave: 'vendedora.registro_data', rotulo: 'Data do registro', exemplo: '02/01/2025' },
  { grupo: 'Vendedora', chave: 'vendedora.assinante', rotulo: 'Nome na assinatura da vendedora', exemplo: 'INCORPORADORA EXEMPLO SPE LTDA' },

  { grupo: 'Incorporadora', chave: 'incorporadora.razao_social', rotulo: 'Razão social da incorporadora (item 1 do Quadro Resumo)', exemplo: 'CONSTRUTORA EXEMPLO LTDA' },
  { grupo: 'Incorporadora', chave: 'incorporadora.cnpj', rotulo: 'CNPJ da incorporadora', exemplo: '44.555.666/0001-81' },
  { grupo: 'Incorporadora', chave: 'incorporadora.endereco', rotulo: 'Endereço da sede da incorporadora', longo: true, exemplo: 'Rua Modelo, nº 200, Sala 2, Centro, nesta cidade' },

  { grupo: 'Empreendimento', chave: 'empreendimento.nome', rotulo: 'Nome do empreendimento', exemplo: 'RESIDENCIAL MODELO' },
  { grupo: 'Empreendimento', chave: 'empreendimento.endereco', rotulo: 'Localização', longo: true, exemplo: 'Avenida Exemplo, nº 1.000, Quadra 1, Lote 1, Setor Modelo, Rio Verde – Goiás' },
  { grupo: 'Empreendimento', chave: 'empreendimento.descricao', rotulo: 'Descrição curta (item 2.1)', longo: true, exemplo: 'formado por 01 (uma) torre residencial com 173 (cento e setenta e três) unidades autônomas do tipo studio' },
  { grupo: 'Empreendimento', chave: 'empreendimento.torre', rotulo: 'Torre (quando a planilha de áreas não informar)', exemplo: 'TORRE ÚNICA' },
  { grupo: 'Empreendimento', chave: 'empreendimento.cidade', rotulo: 'Cidade', exemplo: 'Rio Verde' },
  { grupo: 'Empreendimento', chave: 'empreendimento.cidade_uf', rotulo: 'Cidade – UF', exemplo: 'Rio Verde – Goiás' },
  { grupo: 'Empreendimento', chave: 'empreendimento.foro', rotulo: 'Foro (comarca)', exemplo: 'Rio Verde – Goiás' },
  { grupo: 'Empreendimento', chave: 'empreendimento.email_arrependimento', rotulo: 'E-mail para o direito de arrependimento (Quadro Resumo 7.3)', exemplo: 'contratos@exemplo.com' },
  { grupo: 'Empreendimento', chave: 'empreendimento.prazo_obra', rotulo: 'Prazo de conclusão das obras', exemplo: '30/06/2030' },

  { grupo: 'Registros', chave: 'empreendimento.cartorio', rotulo: 'Cartório de registro de imóveis', exemplo: 'Cartório de Registro de Imóveis de Rio Verde – Goiás' },
  { grupo: 'Registros', chave: 'empreendimento.matricula', rotulo: 'Matrícula do terreno', exemplo: '00.000' },
  { grupo: 'Registros', chave: 'empreendimento.registro_incorporacao', rotulo: 'Registro do memorial de incorporação', exemplo: 'R-1-00.000' },
  { grupo: 'Registros', chave: 'empreendimento.registro_incorporacao_data', rotulo: 'Data do registro do memorial', exemplo: '02/02/2026' },
  { grupo: 'Registros', chave: 'empreendimento.afetacao', rotulo: 'Averbação do patrimônio de afetação', exemplo: 'AV-2-00.000' },
  { grupo: 'Registros', chave: 'empreendimento.afetacao_data', rotulo: 'Data da averbação', exemplo: '02/02/2026' },
  { grupo: 'Registros', chave: 'empreendimento.area_construida', rotulo: 'Área total construída', exemplo: '15.000,00 metros quadrados' },
  { grupo: 'Registros', chave: 'empreendimento.alvara', rotulo: 'Alvará de construção nº', exemplo: '00.000' },
  { grupo: 'Registros', chave: 'empreendimento.alvara_data', rotulo: 'Data do alvará', exemplo: '05/01/2026' },

  { grupo: 'Textos do contrato', chave: 'empreendimento.subcondominios', rotulo: 'Item 2.5 do Quadro Resumo (condomínio)', longo: true, exemplo: 'O(s) COMPRADOR(ES) declara(m) ciência de que o empreendimento é composto por condomínio único, com administração, orçamento, rateio de despesas e gestão observadas as disposições da Convenção de Condomínio.' },
  { grupo: 'Textos do contrato', chave: 'empreendimento.composicao', rotulo: 'Normas 2.4 (composição)', longo: true, exemplo: 'será constituído de 01 (uma) torre residencial, composta no total de 173 (cento e setenta e três) unidades autônomas do tipo studio.' },
  { grupo: 'Textos do contrato', chave: 'empreendimento.pavimentos', rotulo: 'Normas 2.5 (pavimentos)', longo: true, exemplo: 'A torre residencial é composta de 18 (dezoito) pavimentos, sendo: subsolo (garagem), térreo, 1º pavimento (lazer), 2º ao 17º pavimentos (tipo) e ático (barrilete/casa de máquinas e reservatório superior).' },
  { grupo: 'Textos do contrato', chave: 'empreendimento.vagas', rotulo: 'Normas 2.6 (vagas)', longo: true, exemplo: 'O empreendimento possui 120 (cento e vinte) vagas de garagem, situadas no subsolo e no térreo.' },
  { grupo: 'Textos do contrato', chave: 'empreendimento.comercial', rotulo: 'Normas 2.7 (unidades comerciais)', longo: true, exemplo: 'O empreendimento não possui unidades comerciais.' },
  { grupo: 'Textos do contrato', chave: 'empreendimento.escaninhos', rotulo: 'Normas 2.11 (escaninhos)', longo: true, exemplo: 'Os escaninhos existentes no empreendimento constituem áreas acessórias vinculadas às respectivas unidades autônomas, conforme o quadro de áreas, não sendo objeto de matrícula individualizada.' },
  { grupo: 'Textos do contrato', chave: 'empreendimento.vagas_matricula', rotulo: 'Normas 2.12 (matrícula das vagas)', longo: true, exemplo: 'As vagas de garagem do empreendimento não terão matrículas individualizadas, sendo vinculadas, como área acessória, às unidades autônomas, conforme o quadro de áreas.' },
  { grupo: 'Textos do contrato', chave: 'empreendimento.indice_obra', rotulo: 'Índice de correção durante a obra', exemplo: 'INCC-DI (Índice Nacional de Custos da Construção Civil), calculado e divulgado pela FGV (Fundação Getúlio Vargas)' },
  { grupo: 'Textos do contrato', chave: 'empreendimento.indice_pos_obra', rotulo: 'Índice de correção após o Habite-se', exemplo: 'IGP-M (Índice Geral de Preços – Mercado), calculado e divulgado pela FGV' },

  { grupo: 'Assinaturas', chave: 'assinatura.plataforma', rotulo: 'Plataforma de assinatura eletrônica', exemplo: 'D4Sign' },
  { grupo: 'Assinaturas', chave: 'assinatura.cofre', rotulo: 'Cofre na D4Sign (nome)', exemplo: 'Duo Haus – Contratos', soAssinatura: true },
  { grupo: 'Coordenação de vendas', chave: 'coordenacao.razao_social', rotulo: 'Razão social da coordenação de vendas (comissão, item 9.3)', exemplo: 'COORDENAÇÃO EXEMPLO LTDA', soAssinatura: true },
  { grupo: 'Coordenação de vendas', chave: 'coordenacao.cnpj', rotulo: 'CNPJ da coordenação de vendas', exemplo: '44.555.666/0001-81', soAssinatura: true },
  { grupo: 'Coordenação de vendas', chave: 'coordenacao.signatario_nome', rotulo: 'Quem assina pela coordenação — nome', exemplo: 'SÓCIO EXEMPLO', soAssinatura: true },
  { grupo: 'Coordenação de vendas', chave: 'coordenacao.signatario_email', rotulo: 'Quem assina pela coordenação — e-mail (entra no envelope para assinar a intermediação)', exemplo: 'coordenacao@exemplo.com', soAssinatura: true },
  { grupo: 'Assinaturas', chave: 'vendedora.signatario_nome', rotulo: 'Quem assina pela incorporadora — nome', exemplo: 'REPRESENTANTE EXEMPLO', soAssinatura: true },
  { grupo: 'Assinaturas', chave: 'vendedora.signatario_email', rotulo: 'Quem assina pela incorporadora — e-mail', exemplo: 'incorporadora@exemplo.com', soAssinatura: true },
  { grupo: 'Assinaturas', chave: 'testemunha1.nome', rotulo: 'Testemunha 1 — nome', exemplo: 'TESTEMUNHA EXEMPLO UM' },
  { grupo: 'Assinaturas', chave: 'testemunha1.cpf', rotulo: 'Testemunha 1 — CPF', exemplo: '000.000.001-91' },
  { grupo: 'Assinaturas', chave: 'testemunha1.email', rotulo: 'Testemunha 1 — e-mail', exemplo: 'testemunha1@exemplo.com', soAssinatura: true },
  { grupo: 'Assinaturas', chave: 'testemunha2.nome', rotulo: 'Testemunha 2 — nome', exemplo: 'TESTEMUNHA EXEMPLO DOIS' },
  { grupo: 'Assinaturas', chave: 'testemunha2.cpf', rotulo: 'Testemunha 2 — CPF', exemplo: '000.000.002-72' },
  { grupo: 'Assinaturas', chave: 'testemunha2.email', rotulo: 'Testemunha 2 — e-mail', exemplo: 'testemunha2@exemplo.com', soAssinatura: true },
];

export const DADOS_EXEMPLO: Record<string, string> = Object.fromEntries(CAMPOS_EMPREENDIMENTO.map((c) => [c.chave, c.exemplo]));

/** Colunas da planilha do quadro de áreas (ordem do modelo para download). */
export const COLUNAS_AREAS = [
  ['numero', 'Unidade'], ['torre', 'Torre'], ['pavimento', 'Pavimento'], ['area_privativa', 'Área privativa principal'],
  ['area_acessoria', 'Área acessória (vagas)'], ['area_privativa_total', 'Área privativa total'], ['area_comum', 'Área comum'],
  ['area_total', 'Área total real'], ['fracao_ideal', 'Fração ideal'], ['vagas', 'Vagas / localização'],
  ['escaninho', 'Escaninho'], ['escaninho_local', 'Local do escaninho'], ['escaninho_area', 'Área do escaninho'],
] as const;
export type ChaveArea = (typeof COLUNAS_AREAS)[number][0];
export type Areas = Partial<Record<ChaveArea, string | number | null>>;
