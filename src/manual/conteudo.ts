/**
 * MANUAL DO SISTEMA — conteúdo.
 *
 * Regra do projeto: toda entrega que cria ou muda um recurso atualiza este arquivo
 * (capítulo do módulo + uma linha em NOVIDADES) no mesmo commit. Veja CLAUDE.md.
 *
 * Cada capítulo diz para quais perfis aparece (papeis) e de qual módulo depende (modulo).
 * Na tela, a pessoa só vê os capítulos dos módulos visíveis para ela, e dentro de cada
 * capítulo só os blocos do seu perfil. Os vídeos são cadastrados pelo administrador na
 * própria tela do manual (tabela manual_videos), pelo id do capítulo.
 */

export type PapelManual = 'admin' | 'vendas' | 'imobiliaria' | 'corretor' | 'recepcao';
export type ModuloManual =
  | 'geral' | 'inicio' | 'espelho' | 'pastas' | 'funil' | 'propostas' | 'contratos' | 'leads'
  | 'portal' | 'rodadas' | 'treinamentos' | 'meeting' | 'tv' | 'corretores' | 'imobiliarias' | 'empreendimento';

export interface Bloco {
  titulo: string;
  papeis?: PapelManual[];   // vazio = todos os perfis do capítulo
  texto?: string;
  passos?: string[];        // lista numerada
  itens?: string[];         // lista simples
  dica?: string;
  atencao?: string;
}
export interface Capitulo {
  id: string;
  modulo: ModuloManual;
  titulo: string;
  papeis: PapelManual[];
  resumo: string;
  /** O que se espera de cada perfil neste módulo (aparece no topo do capítulo). */
  responsabilidades?: Partial<Record<PapelManual, string[]>>;
  blocos: Bloco[];
}

export const ROTULO_PAPEL: Record<PapelManual, string> = {
  admin: 'Administrador', vendas: 'Sec. Vendas', imobiliaria: 'Imobiliária', corretor: 'Corretor', recepcao: 'Recepcionista',
};

const EQUIPE: PapelManual[] = ['admin', 'vendas'];
const PARCEIROS: PapelManual[] = ['imobiliaria', 'corretor'];
const TODOS: PapelManual[] = ['admin', 'vendas', 'imobiliaria', 'corretor'];

/** Atualizado a cada entrega (data da última revisão do manual). */
export const REVISAO_MANUAL = '21/11/2026';

export const NOVIDADES: { data: string; titulo: string; itens: string[]; papeis?: PapelManual[] }[] = [
  {
    data: '21/11/2026', titulo: 'Manual do sistema',
    itens: ['Manual dentro do sistema, com o conteúdo de cada módulo para o seu perfil e espaço para vídeos explicativos.'],
  },
  {
    data: '20/11/2026', titulo: 'Leads das campanhas',
    itens: [
      'Leads do Meta chegam pela planilha e são distribuídos por rodízio (cota por imobiliária e lista de corretores).',
      'Prazo para assumir, funil de atendimento, motivos de perda e conversão em pasta.',
    ],
  },
  {
    data: '20/11/2026', titulo: 'Contratos e assinatura em envelope único', papeis: EQUIPE,
    itens: [
      'Emissão do Quadro Resumo, das Normas e da Carta Proposta a partir da proposta aprovada.',
      'Envelope único por venda na D4Sign, com os documentos fixos do empreendimento.',
      'Modelos em Word com marcadores, enviados pelo administrador.',
    ],
  },
  {
    data: '19/11/2026', titulo: 'Pastas: regime de bens e comprador pessoa jurídica',
    itens: [
      'Casado em separação total ou obrigatória de bens pode seguir sem o cônjuge no contrato.',
      'Pastas para empresas (pessoa jurídica), com documentos próprios.',
    ],
  },
];

export const CAPITULOS: Capitulo[] = [
  // =========================================================================
  {
    id: 'primeiros-passos', modulo: 'geral', titulo: 'Primeiros passos', papeis: [...TODOS, 'recepcao'],
    resumo: 'Como entrar no sistema, criar a sua senha, completar o cadastro e se orientar pelo menu.',
    blocos: [
      {
        titulo: 'Primeiro acesso',
        passos: [
          'Abra o endereço do sistema e entre com o e-mail e a senha provisória que você recebeu.',
          'O sistema pede para você criar uma senha própria, com pelo menos 8 caracteres. Senhas muito fracas ou que já vazaram na internet são recusadas.',
          'Pronto: a partir daí, use sempre o seu e-mail e a senha que você criou.',
        ],
        atencao: 'A senha provisória aparece uma única vez para quem criou o seu acesso. Se você perdeu, peça uma nova para quem criou o login (Sec. Vendas, administrador ou o gestor da sua imobiliária).',
      },
      {
        titulo: 'Completar o cadastro', papeis: PARCEIROS,
        texto: 'No primeiro acesso, imobiliárias e corretores preenchem nome completo, CPF e CRECI. A imobiliária informa também o CNPJ e o CRECI PJ. Esses dados entram nos documentos da venda (por exemplo, a comissão no contrato), então preencha com cuidado. Enquanto faltar algum dado, o sistema mostra essa tela antes de liberar o painel.',
      },
      {
        titulo: 'Esqueci a senha',
        passos: [
          'Na tela de login, clique em “Esqueci minha senha”.',
          'Informe o e-mail do seu login. Chega um link para criar uma nova senha, válido por 1 hora.',
          'Não chegou? Veja as pastas de spam e promoções antes de pedir de novo.',
        ],
      },
      {
        titulo: 'Menu e uso no celular',
        itens: [
          'No computador, o menu fica à esquerda. No celular, abra pelo ícone de menu no topo.',
          'Você só vê os módulos liberados para o seu perfil. Se algo que você espera ver não aparece, fale com a equipe de vendas.',
          'Por segurança, a sessão se encerra sozinha depois de 60 minutos sem uso.',
          'Depois de uma atualização do sistema, a página se recarrega sozinha se for preciso.',
        ],
      },
      {
        titulo: 'Este manual',
        texto: 'O manual mostra só o que vale para o seu perfil e para os módulos ligados. Ele é atualizado a cada recurso novo; veja o que mudou em “Novidades”. Os capítulos com vídeo mostram o player no topo.',
      },
    ],
  },

  // =========================================================================
  {
    id: 'inicio', modulo: 'inicio', titulo: 'Início (painel da equipe)', papeis: EQUIPE,
    resumo: 'Resumo do dia: unidades por status, pastas, atalhos e as últimas movimentações do espelho.',
    blocos: [
      {
        titulo: 'O que aparece',
        itens: [
          'Unidades: total por status (disponível, reservada, proposta recebida, contrato em assinatura, vendida, bloqueada, permutante), com a barra de distribuição e as reservas e vendas dos últimos 7 dias.',
          'Pastas de compradores: quantas foram submetidas, quantas estão em análise e quantas ainda estão em preparação nas imobiliárias.',
          'Atalhos para o espelho, as pastas e o Modo TV.',
          'Últimas movimentações: cada mudança de status no espelho, com quem fez e quando.',
        ],
      },
    ],
  },

  // =========================================================================
  {
    id: 'espelho', modulo: 'espelho', titulo: 'Espelho de unidades', papeis: TODOS,
    resumo: 'A disponibilidade das unidades em tempo real, andar por andar.',
    responsabilidades: {
      vendas: ['Manter o status das unidades sempre atualizado: cada reserva, proposta, contrato e venda passa pelo espelho (ou pelo funil, que atualiza o espelho).'],
      admin: ['Definir quem vê o espelho (módulo “Espelho para imobiliárias e corretores”) e acompanhar as movimentações.'],
      imobiliaria: ['Consultar a disponibilidade antes de oferecer uma unidade.'],
      corretor: ['Consultar a disponibilidade antes de oferecer uma unidade.'],
    },
    blocos: [
      {
        titulo: 'Status das unidades', papeis: EQUIPE,
        itens: [
          'Disponível: livre para venda.',
          'Reservada: segurada para um cliente com pasta de documentação aprovada.',
          'Proposta recebida: proposta aprovada, com valor e PV registrados.',
          'Contrato em assinatura: contrato emitido e enviado para assinatura.',
          'Vendida: contrato assinado.',
          'Bloqueada: fora de venda (decisão da incorporadora).',
          'Permutante: unidade dada em permuta (por exemplo, ao dono do terreno).',
        ],
      },
      {
        titulo: 'Mudar o status de uma unidade', papeis: EQUIPE,
        passos: [
          'Clique (ou toque) na unidade. Aparecem área, tipologia, status atual e, se houver, a negociação (imobiliária, corretor, cliente, valor e PV).',
          'Escolha o novo status.',
          'Para reservar, proposta, contrato ou vendida, escolha a pasta do cliente. Só aparecem pastas com documentação aprovada.',
          'Para “Proposta recebida”, informe o valor da venda e o PV aprovado.',
          'Para desfazer uma negociação (voltar a disponível, bloquear ou permutar), o motivo é obrigatório.',
          'Confirme. A mudança aparece na hora para todos e fica no histórico da unidade.',
        ],
        atencao: 'Se outra pessoa alterou a mesma unidade enquanto a janela estava aberta, o sistema avisa e não salva. Feche, confira o status atual e faça de novo.',
        dica: 'Quando a proposta é aprovada pelo módulo de Propostas, a unidade vai sozinha para “Proposta recebida”.',
      },
      {
        titulo: 'Regras de vínculo', papeis: EQUIPE,
        itens: [
          'Cada unidade em negociação fica ligada a uma única pasta.',
          'Um cliente pode comprar mais de uma unidade: reserve cada unidade no espelho com a mesma pasta.',
          'Para trocar o cliente de uma unidade, libere a unidade antes.',
        ],
      },
      {
        titulo: 'O que você vê', papeis: PARCEIROS,
        texto: 'Para imobiliárias e corretores, o espelho mostra só “Disponível” ou “Vendida” (qualquer negociação em andamento aparece como vendida). As unidades que acabaram de mudar ficam destacadas por alguns instantes. Para reservar uma unidade, fale com a Sec. Vendas ou siga pelo módulo de Propostas, se estiver liberado.',
      },
    ],
  },

  // =========================================================================
  {
    id: 'tv', modulo: 'tv', titulo: 'Modo TV', papeis: EQUIPE,
    resumo: 'Espelho em tela cheia para as TVs do plantão e do stand.',
    blocos: [
      {
        titulo: 'Como usar',
        passos: [
          'No menu, clique em “Modo TV” (ou abra o endereço /tv na TV).',
          'Deixe a página aberta em tela cheia. Ela se atualiza sozinha a cada mudança no espelho.',
        ],
        dica: 'O Modo TV mostra só disponível e vendida, como o espelho dos parceiros. Ele pode ser desligado em Empreendimento → Módulos.',
      },
    ],
  },

  // =========================================================================
  {
    id: 'pastas', modulo: 'pastas', titulo: 'Pastas de compradores', papeis: TODOS,
    resumo: 'A documentação de cada comprador, do cadastro à aprovação pelo incorporador. Sem pasta aprovada não há reserva.',
    responsabilidades: {
      corretor: [
        'Criar a pasta do seu cliente com os dados corretos e anexar todos os documentos obrigatórios.',
        'Corrigir rapidamente os documentos recusados.',
        'Submeter a pasta ao incorporador quando estiver completa.',
      ],
      imobiliaria: [
        'Acompanhar as pastas de todos os corretores da imobiliária e garantir que sejam submetidas completas.',
        'Definir o corretor responsável por cada pasta.',
      ],
      vendas: [
        'Analisar cada documento (em análise, aprovado ou recusado com motivo) assim que a pasta for submetida.',
        'Acompanhar as pendências de correção até a aprovação.',
      ],
      admin: ['Acompanhar o volume e a qualidade das pastas por imobiliária e decidir sobre exceções.'],
    },
    blocos: [
      {
        titulo: 'Situações da pasta',
        itens: [
          'Incompleta: faltam dados ou documentos obrigatórios.',
          'Pronta para submeter: tudo anexado; falta enviar ao incorporador.',
          'Aguardando análise: submetida, com o código de aprovação (PA), esperando a equipe.',
          'Em análise: a equipe está conferindo os documentos.',
          'Pendente de correção: algum documento foi recusado; veja o motivo e envie outro.',
          'Documentação aprovada: pode reservar unidade e seguir para proposta e contrato.',
        ],
      },
      {
        titulo: 'Criar uma pasta', papeis: [...PARCEIROS, ...EQUIPE],
        passos: [
          'Em Pastas, clique em “Nova pasta”.',
          'Escolha se o comprador é pessoa física ou pessoa jurídica (empresa).',
          'Pessoa física: nome completo, CPF, nascimento, telefone, e-mail, profissão e estado civil. Se casado ou em união estável, informe o regime de bens.',
          'Pessoa jurídica: razão social, CNPJ e os dados do representante legal (quem assina pela empresa).',
          'Clique em “Criar pasta e seguir para os documentos”.',
        ],
        dica: 'Pasta criada a partir de um lead (módulo Leads) já vem com nome, telefone e e-mail preenchidos.',
      },
      {
        titulo: 'Cônjuge e regime de bens',
        itens: [
          'Casado ou em união estável: em regra, o cônjuge também assina e precisa dos dados e documentos dele.',
          'Separação total ou obrigatória de bens: o sistema pergunta se o cônjuge também assina. Respondendo “Não, só o comprador”, os documentos do cônjuge deixam de ser obrigatórios.',
          'Sem o regime de bens informado, a pasta não pode ser submetida.',
        ],
      },
      {
        titulo: 'Documentos',
        passos: [
          'Na pasta, cada documento aparece com a etiqueta Obrigatório ou Opcional (a lista muda conforme estado civil e tipo de comprador).',
          'Clique em “Enviar arquivo” e escolha o arquivo: PDF, JPG, PNG ou HEIC, até 15 MB.',
          'Documento recusado mostra o motivo. Envie um arquivo novo no lugar.',
        ],
        atencao: 'Documentos em análise ou aprovados não podem ser substituídos. Os arquivos ficam em armazenamento privado e só abrem para quem tem acesso à pasta.',
      },
      {
        titulo: 'Pix do sinal',
        itens: [
          'Modo “comprovante”: anexe o comprovante do Pix do sinal como um documento da pasta.',
          'Modo “Pix gerado pelo sistema” (quando ligado pelo administrador): a pasta mostra o QR Code e o “copia e cola”. Assim que o pagamento é confirmado, o recibo entra na pasta sozinho. Sem o Pix pago, a pasta não pode ser submetida.',
        ],
      },
      {
        titulo: 'Submeter ao incorporador', papeis: [...PARCEIROS, ...EQUIPE],
        passos: [
          'Com todos os obrigatórios anexados, a pasta fica “Pronta para submeter”.',
          'Clique em “Submeter ao incorporador” e confirme.',
          'A pasta recebe o código de aprovação (PA) e vai para a análise da equipe.',
        ],
        atencao: 'Depois de submetida, a imobiliária e o corretor não editam mais os dados do comprador; só substituem documentos recusados. Para corrigir um dado, fale com a Sec. Vendas.',
      },
      {
        titulo: 'Corretor responsável', papeis: ['imobiliaria', ...EQUIPE],
        texto: 'Na pasta, escolha o corretor que acompanha a venda. Ele passa a ver a pasta, o funil e o andamento das unidades daquela venda. A imobiliária vê as pastas de todos os seus corretores.',
      },
      {
        titulo: 'O que o corretor vê', papeis: ['corretor'],
        texto: 'Você vê as pastas que criou e as que a imobiliária atribuiu a você. O resumo por corretor e a exportação ficam com a imobiliária.',
      },
      {
        titulo: 'Analisar documentos', papeis: EQUIPE,
        passos: [
          'Na aba “Submetidas ao incorporador”, abra a pasta.',
          'Para cada documento, use “Em análise”, “Aprovar” ou “Recusar”. Na recusa, o motivo é obrigatório e aparece para a imobiliária e o corretor.',
          'Quando todos os obrigatórios estiverem aprovados, a pasta fica “Documentação aprovada” e já pode reservar no espelho.',
          'Use “Baixar todos (.zip)” para levar os documentos ao incorporador ou ao banco.',
        ],
        dica: 'A aba “Todas as pastas criadas” mostra também o que ainda está em preparação nas imobiliárias. O “Resumo por imobiliária” e o “Exportar planilha” respeitam os filtros da tela.',
      },
      {
        titulo: 'Resumo e exportação', papeis: ['imobiliaria'],
        texto: 'Use “Resumo por corretor” para ver quantas pastas cada um tem em cada situação, e “Exportar planilha” para baixar a lista filtrada.',
      },
    ],
  },

  // =========================================================================
  {
    id: 'funil', modulo: 'funil', titulo: 'Funil de vendas', papeis: TODOS,
    resumo: 'Cada venda em um quadro por etapa, da pasta aprovada ao contrato assinado. O espelho acompanha as mudanças.',
    responsabilidades: {
      vendas: ['Mover cada venda de etapa assim que ela avança, para o espelho e os relatórios ficarem corretos.'],
      imobiliaria: ['Acompanhar o andamento das vendas da imobiliária.'],
      corretor: ['Acompanhar o andamento das suas vendas.'],
    },
    blocos: [
      {
        titulo: 'Etapas',
        itens: [
          'Pasta aprovada: documentação aprovada, ainda sem unidade.',
          'Reserva: unidade reservada (espelho: Reservada).',
          'Contrato em confecção: proposta aprovada, contrato sendo preparado (espelho: Proposta recebida).',
          'Enviado para assinatura (espelho: Contrato em assinatura).',
          'Assinado / Vendido (espelho: Vendida).',
        ],
      },
      {
        titulo: 'Mover uma venda', papeis: EQUIPE,
        passos: [
          'Arraste o card para a nova etapa.',
          'Saindo de “Pasta aprovada”, escolha a unidade. O sistema confere se ela está livre.',
          'Para desfazer, use “Liberar unidade” no card. A unidade volta para disponível no espelho.',
        ],
        dica: 'Cada unidade em negociação é um card. Para outra unidade do mesmo cliente, reserve pelo espelho.',
      },
      {
        titulo: 'Somente leitura', papeis: PARCEIROS,
        texto: 'Você acompanha as suas negociações, mas as mudanças de etapa são feitas pela equipe de vendas.',
      },
    ],
  },

  // =========================================================================
  {
    id: 'propostas', modulo: 'propostas', titulo: 'Propostas', papeis: TODOS,
    resumo: 'A proposta montada sobre a tabela de vendas, com PV, comissão, aprovação por alçada e carta proposta em PDF.',
    responsabilidades: {
      corretor: ['Montar a proposta com o fluxo combinado com o cliente, vincular a pasta e enviar para análise.', 'Ajustar e reenviar as propostas devolvidas.'],
      imobiliaria: ['Acompanhar as propostas dos seus corretores e montar propostas quando necessário.'],
      vendas: ['Analisar as propostas na sua alçada: aprovar, devolver para ajuste ou recusar, sempre com o motivo.'],
      admin: ['Analisar as propostas abaixo da alçada da Sec. Vendas e acompanhar os descontos concedidos.'],
    },
    blocos: [
      {
        titulo: 'Montar uma proposta', papeis: TODOS,
        passos: [
          'Em Propostas, clique em “Nova proposta” e escolha a unidade.',
          'O fluxo da tabela já vem montado. Use “Modelo da tabela”, “Mensais até a entrega”, “Semestrais”, “Anuais” ou “Até as chaves” para trocar o modelo, ou edite as séries (quantidade, periodicidade, 1º vencimento e valor).',
          'Use “⟲ ajustar” em uma série para ela absorver a diferença e voltar o PV ao alvo.',
          'Acompanhe o comparativo tabela × proposta: valor total, preço do m², PV (valor presente) e captação acumulada.',
          'Confira a comissão e a parte do sinal que vai para a imobiliária. Se o sinal não cobre a comissão, use “Aumentar o ato para cobrir a comissão”.',
          'Vincule a pasta do comprador (só pastas da sua imobiliária) e escreva as observações (saem na carta).',
          'Clique em “Salvar rascunho” ou “Enviar para análise”.',
        ],
        atencao: 'Permuta exige descrição nas observações (bem, valor de avaliação). A grade precisa estar sem erros (vencimentos e parcelas) para enviar.',
      },
      {
        titulo: 'Quem aprova (alçada)', papeis: TODOS,
        itens: [
          'Aprovação automática: PV dentro da tabela e sinal cobrindo a comissão. A proposta é aprovada na hora e a unidade vai para “Proposta recebida”.',
          'Sec. Vendas: PV um pouco abaixo da tabela (dentro do limite definido pela incorporadora).',
          'Administrador: descontos maiores.',
          'A tela mostra antes do envio quem vai aprovar a proposta.',
        ],
      },
      {
        titulo: 'Proposta devolvida ou recusada', papeis: PARCEIROS,
        texto: 'A proposta devolvida volta a ser editável e mostra o motivo no topo: ajuste e envie de novo. Proposta recusada ou cancelada fica só para consulta.',
      },
      {
        titulo: 'Carta proposta', papeis: TODOS,
        texto: 'O botão “Carta proposta” gera o PDF com os dados do imóvel, dos proponentes, o fluxo de pagamento, a intermediação e as condições gerais, pronto para o cliente assinar.',
      },
      {
        titulo: 'Analisar propostas', papeis: EQUIPE,
        passos: [
          'Abra a proposta enviada. Confira o PV, o fluxo e a comissão (a equipe pode ajustar a comissão).',
          'Aprovar: a unidade vai para “Proposta recebida” no espelho, com valor e PV.',
          'Devolver para ajuste: escreva o que o corretor deve mudar.',
          'Recusar ou cancelar: o motivo é obrigatório.',
        ],
        dica: 'Com o módulo desligado, só o administrador vê Propostas (para testar). Os parâmetros comerciais (tabela, taxa, comissão e alçadas) são configurados pela Launch.',
      },
    ],
  },

  // =========================================================================
  {
    id: 'contratos', modulo: 'contratos', titulo: 'Contratos e assinatura', papeis: EQUIPE,
    resumo: 'Da proposta aprovada ao contrato assinado: conferência das partes com IA, emissão dos documentos e envelope único na D4Sign.',
    responsabilidades: {
      vendas: [
        'Conferir as partes (leitura com IA), o fluxo de pagamento e a comissão de cada venda.',
        'Emitir, conferir e validar os documentos, montar o envelope e acompanhar as assinaturas.',
      ],
      admin: [
        'Manter os dados do empreendimento para contrato, o quadro de áreas, os modelos em Word e os documentos fixos.',
        'Acompanhar os contratos em assinatura.',
      ],
    },
    blocos: [
      {
        titulo: 'Quando a venda aparece aqui',
        texto: 'Em Contratos aparecem as propostas aprovadas cuja pasta está com a documentação aprovada. Abra a venda para seguir as etapas.',
      },
      {
        titulo: '1. Partes do contrato (leitura com IA)',
        passos: [
          'Clique em ler os documentos com IA. Ela lê RG, CNH, certidões, comprovantes e, para empresas, contrato social e cartão CNPJ.',
          'Confira cada campo sugerido (nome, nacionalidade, profissão, documento, endereço, regime de bens). Corrija o que for preciso.',
          'Marque como conferido. Só dados conferidos vão para os documentos.',
        ],
        atencao: 'A IA sugere; a responsabilidade pela conferência é da equipe. Compare com os documentos originais.',
      },
      {
        titulo: '2. Unidade e 3. Pagamento',
        itens: [
          'A unidade usa o quadro de áreas importado pelo administrador (área privativa, comum, fração ideal, vagas e escaninho).',
          'Confira as séries do fluxo aprovado e os beneficiários da comissão (nome, documento, valor e forma), e marque o fluxo como conferido.',
        ],
      },
      {
        titulo: '4. Emissão',
        passos: [
          'Marque o que emitir: Quadro Resumo, Normas e Carta Proposta. O sistema sugere só o que ainda não foi emitido.',
          'Use “Pré-visualizar” para conferir antes.',
          'Clique em “Emitir documentos”. Cada um ganha um número e fica aguardando validação.',
          'Precisa ajustar a formatação? Baixe o Word, edite e use “Enviar ajuste”. A versão sobe e a validação volta para pendente.',
          'Confira e clique em “Validar” em cada documento.',
        ],
      },
      {
        titulo: '5. Envelope de assinatura (D4Sign)',
        passos: [
          'Com todos os documentos validados, clique em “Montar envelope na D4Sign”. O Quadro Resumo é o principal; Normas, Carta Proposta e documentos fixos vão como anexos.',
          'Confira a prévia (PDF do principal ou o pacote completo em ZIP). Se algo estiver errado, use “Descartar e ajustar”.',
          'Revise os assinantes e a ordem: cliente e cônjuge, imobiliária, incorporadora e testemunhas. Cada um pode receber por e-mail ou WhatsApp.',
          'Clique em “Enviar para assinatura”. Acompanhe quem já assinou e use “Reenviar” para quem está pendente.',
          'Quando todos assinarem, baixe o pacote assinado (ZIP).',
        ],
        atencao: 'Enquanto o envelope estiver montado ou em assinatura, os documentos ficam travados. Para mudar algo, descarte (antes do envio) ou cancele o envelope.',
      },
      {
        titulo: 'Configuração (Empreendimento)', papeis: ['admin'],
        itens: [
          'Dados para contrato: dados da incorporadora, do empreendimento, signatários e testemunhas.',
          'Quadro de áreas: importe a planilha (xlsx ou csv) com as áreas de cada unidade.',
          'Modelos do contrato: baixe o modelo atual, envie o Word do jurídico com os marcadores ou volte ao padrão. A lista de marcadores fica na mesma tela.',
          'Documentos fixos do contrato: memorial, plantas, convenção e outros iguais para todas as vendas, na ordem em que entram no envelope.',
        ],
      },
    ],
  },

  // =========================================================================
  {
    id: 'leads', modulo: 'leads', titulo: 'Leads das campanhas', papeis: TODOS,
    resumo: 'Leads do Meta chegam pela planilha, são distribuídos por rodízio e acompanhados até virar pasta ou ser perdidos (com motivo).',
    responsabilidades: {
      corretor: [
        'Assumir o lead dentro do prazo (padrão: 15 minutos em horário comercial).',
        'Fazer o primeiro contato logo e registrar cada contato e etapa.',
        'Criar a pasta quando o cliente avançar, ou marcar como perdido com o motivo correto.',
      ],
      imobiliaria: [
        'Manter atualizada a lista de corretores que recebem leads (aba Rodízio).',
        'Cobrar o atendimento e redirecionar leads dentro da equipe quando preciso.',
      ],
      vendas: ['Distribuir os leads que ficam sem corretor e acompanhar os indicadores de atendimento.'],
      admin: ['Definir as cotas por imobiliária e as regras do rodízio, e manter a ligação com a planilha do Meta.'],
    },
    blocos: [
      {
        titulo: 'Como o lead chega até você', papeis: TODOS,
        itens: [
          'O formulário do Meta grava o lead numa planilha do Google. A cada minuto, o sistema traz os leads novos.',
          'Primeiro, o lead vai para a imobiliária que está mais abaixo da sua cota. Dentro dela, vai para o corretor da lista que está há mais tempo sem receber.',
          'O corretor recebe um e-mail e o lead aparece em Leads, com o prazo para assumir.',
          'Se o prazo acabar, o lead vai para o próximo corretor da mesma imobiliária; depois, para outra imobiliária. Após o limite de tentativas, fica com a Sec. Vendas.',
          'Cliente que volta (mesmo telefone ou e-mail) vai direto para o corretor que já o atendeu.',
          'Fora do horário comercial, o lead chega, mas o prazo só começa a contar na abertura.',
        ],
      },
      {
        titulo: 'Atender um lead', papeis: ['corretor', 'imobiliaria', ...EQUIPE],
        passos: [
          'Abra o lead e clique em “Assumir lead”. Só então aparecem telefone e e-mail.',
          'Fale com o cliente (botões de WhatsApp, ligação e e-mail) e clique em “Registrar contato”, com o canal e um resumo da conversa.',
          'Avance as etapas: Em atendimento → Visita agendada → Visita realizada → Proposta.',
          'Cliente avançou? Clique em “Criar pasta com este cliente”: a pasta já vem com nome, telefone e e-mail, e o lead vira “Virou pasta” ao salvar.',
          'Não avançou? Escolha o motivo da perda (sem interesse, preço, renda ou crédito, localização, comprou outro imóvel, só pesquisando, contato inválido, não atende, duplicado ou outro) e marque como perdido.',
        ],
        atencao: 'Se você não registrar o primeiro contato no prazo (padrão: 2 horas), o gestor da imobiliária é avisado. Pasta criada com o mesmo telefone ou e-mail do lead converte o lead sozinha.',
      },
      {
        titulo: 'Rodízio da imobiliária', papeis: ['imobiliaria'],
        passos: [
          'Em Leads, abra a aba “Rodízio”.',
          'Ligue (“Recebe”) os corretores que devem receber leads e desligue quem estiver de férias ou fora do plantão.',
          'Para mandar um lead a outro corretor da equipe, abra o lead e use “Redirecionar”.',
        ],
      },
      {
        titulo: 'Leads sem corretor e redistribuição', papeis: EQUIPE,
        passos: [
          'Filtre por “Aguardando Sec. Vendas” no topo da lista.',
          'Abra o lead e escolha o corretor em “Distribuir este lead”, ou use “Devolver ao rodízio” para recomeçar as tentativas.',
          'Lead perdido ou convertido pode ser reaberto se necessário.',
        ],
        dica: 'Os indicadores mostram o tempo médio para assumir, quantos viraram pasta e os principais motivos de perda, com filtro por campanha, imobiliária e período.',
      },
      {
        titulo: 'Cotas e regras (administrador)', papeis: ['admin'],
        itens: [
          'Rodízio → Cotas por imobiliária: peso de cada uma (ex.: 2, 1, 1). Cota zero não recebe. A tabela mostra o % previsto e o % real.',
          'Configuração e planilha → Regras: prazo para assumir, prazo para o primeiro contato, tentativas antes da Sec. Vendas, dias em que o cliente fica com o mesmo corretor, horário comercial (ou plantão 24h) e quem recebe os leads sem corretor.',
          'Avisos por e-mail: preencha o remetente validado na Brevo. A chave da Brevo fica no Cloudflare (segredo BREVO_API_KEY).',
          'Planilha do Meta: copie o código do script e instale na planilha (Extensões → Apps Script → função “instalar”). “Gerar nova chave” invalida o script antigo.',
          'Com o módulo desligado, só o administrador vê Leads.',
        ],
      },
    ],
  },

  // =========================================================================
  {
    id: 'portal', modulo: 'portal', titulo: 'Portal do Corretor', papeis: TODOS,
    resumo: 'Os materiais de venda do empreendimento, organizados por categoria, e o simulador de pagamento.',
    responsabilidades: {
      vendas: ['Manter os materiais atualizados (book, ficha técnica, imagens, plantas, vídeos, regras da premiação).'],
      corretor: ['Usar sempre a versão mais recente dos materiais do portal com os clientes.'],
    },
    blocos: [
      {
        titulo: 'Categorias',
        itens: ['Book e apresentações', 'Ficha técnica', 'Fotos do decorado', 'Imagens do empreendimento', 'Materiais de apoio', 'Material para redes sociais', 'Plantas', 'Regras da premiação', 'Simulador', 'Tour virtual', 'Vídeos'],
      },
      {
        titulo: 'Baixar materiais', papeis: PARCEIROS,
        texto: 'Abra a categoria e use Visualizar, Baixar ou Abrir (links). Em galerias, “Baixar tudo (.zip)” leva todas as imagens de uma vez. Os downloads ficam registrados para a equipe.',
      },
      {
        titulo: 'Simulador de pagamento', papeis: TODOS,
        passos: [
          'Abra a categoria Simulador e escolha a posição da unidade.',
          'O fluxo padrão aparece montado; ajuste parcelas e percentuais com o cliente.',
          'Use “Baixar imagem” para enviar a simulação ao cliente. Os valores são estimados, sem correção.',
        ],
        dica: 'A simulação é só uma conversa inicial. A proposta oficial é feita no módulo Propostas.',
      },
      {
        titulo: 'Publicar materiais', papeis: EQUIPE,
        passos: [
          'Abra a categoria e clique em “Adicionar”.',
          'Envie arquivos (vários de uma vez; cada arquivo vira um item) ou informe um link (YouTube, Vimeo, tour virtual, Google Drive).',
          'Edite título e descrição, ou remova o item (os parceiros deixam de ver).',
          'Em “Registros de downloads”, veja quem baixou o quê e quando, e exporte em PDF.',
        ],
        dica: 'No simulador, o administrador usa “Configurar simulador” para definir preços, captação mínima e o fluxo padrão de cada posição.',
      },
    ],
  },

  // =========================================================================
  {
    id: 'rodadas', modulo: 'rodadas', titulo: 'Rodadas de negócios', papeis: TODOS,
    resumo: 'Eventos com vagas limitadas, em que os corretores confirmam os clientes convidados.',
    responsabilidades: {
      vendas: ['Criar as rodadas, escolher as imobiliárias convidadas, anexar o convite e controlar a presença no dia.'],
      corretor: ['Confirmar os seus clientes dentro do prazo e enviar o convite a eles.'],
      imobiliaria: ['Acompanhar as confirmações da imobiliária.'],
    },
    blocos: [
      {
        titulo: 'Confirmar um cliente', papeis: PARCEIROS,
        passos: [
          'Abra a rodada liberada para a sua imobiliária.',
          'Clique em “Confirmar cliente” e informe o nome completo do cliente (e o telefone, se tiver).',
          'O cliente pode levar acompanhantes: no máximo 3 pessoas contando com ele, todas com nome e sobrenome.',
          'Depois da confirmação, baixe o convite e envie ao cliente.',
        ],
        atencao: 'Quando as vagas acabam ou as confirmações são encerradas, só a Sec. Vendas consegue incluir alguém.',
      },
      {
        titulo: 'Criar e gerenciar rodadas', papeis: EQUIPE,
        passos: [
          'Clique em “Nova rodada”: nome, data e hora, limite de pessoas e imobiliárias convidadas (ou todas).',
          'Anexe o convite (imagem ou PDF). Ele fica disponível para quem tem cliente confirmado.',
          'Abra ou encerre as confirmações quando quiser. Para abrir mais vagas, edite o limite.',
          'No dia, marque a presença e baixe a planilha ou o PDF dos participantes.',
        ],
      },
    ],
  },

  // =========================================================================
  {
    id: 'treinamentos', modulo: 'treinamentos', titulo: 'Treinamentos', papeis: TODOS,
    resumo: 'Agenda de turmas de treinamento, com inscrição, presença e relatórios.',
    responsabilidades: {
      corretor: ['Inscrever-se em um horário e comparecer.'],
      imobiliaria: ['Garantir que os corretores da imobiliária façam o treinamento.'],
      vendas: ['Montar os horários, abrir e encerrar inscrições e registrar a presença.'],
    },
    blocos: [
      {
        titulo: 'Inscrever-se', papeis: PARCEIROS,
        passos: [
          'Escolha um horário com vaga e clique em “Inscrever-me”. Cada pessoa fica em um único horário.',
          'Para trocar, cancele a inscrição atual e escolha outro horário.',
        ],
        atencao: 'Depois que a presença é confirmada, a inscrição não pode mais ser cancelada.',
      },
      {
        titulo: 'Inscritos da imobiliária', papeis: ['imobiliaria'],
        texto: 'A imobiliária vê quais corretores se inscreveram e em qual horário.',
      },
      {
        titulo: 'Configurar e conduzir', papeis: EQUIPE,
        passos: [
          'Em “Configurar horários”, informe o dia, o primeiro e o último horário, o intervalo e as pessoas por turma. O sistema cria as turmas.',
          'Inclua pessoas manualmente (com ou sem login) e marque a presença.',
          'Encerre ou reabra as inscrições.',
          'Baixe o relatório do dia ou o consolidado em PDF.',
        ],
      },
    ],
  },

  // =========================================================================
  {
    id: 'meeting', modulo: 'meeting', titulo: 'Meeting (recepção do evento)', papeis: [...EQUIPE, 'recepcao'],
    resumo: 'Lista de convidados e confirmação de presença na entrada do evento.',
    responsabilidades: {
      recepcao: ['Confirmar a chegada de cada convidado e incluir na hora quem não está na lista.'],
      vendas: ['Acompanhar a presença e emitir a lista final por imobiliária.'],
    },
    blocos: [
      {
        titulo: 'Na entrada',
        passos: [
          'Busque o convidado pelo nome na aba “Aguardando” e clique em “Confirmar”.',
          'Não está na lista? Use “Incluir pessoa”: nome, imobiliária (ou autônomo, ou cadastre uma nova) e telefone. A pessoa entra já confirmada.',
          'Para corrigir dados de alguém, use “Editar dados do convidado”.',
        ],
      },
      {
        titulo: 'Relatório', papeis: EQUIPE,
        texto: '“Lista de presença (PDF)” traz os convidados na lista, quantos compareceram, os incluídos na hora e a presença por imobiliária, com o horário de chegada.',
      },
    ],
  },

  // =========================================================================
  {
    id: 'corretores', modulo: 'corretores', titulo: 'Corretores da imobiliária', papeis: ['imobiliaria'],
    resumo: 'Os logins dos corretores da sua imobiliária.',
    responsabilidades: {
      imobiliaria: ['Criar o acesso de cada corretor e remover quem sair da imobiliária.'],
    },
    blocos: [
      {
        titulo: 'Criar o acesso de um corretor',
        passos: [
          'Em Corretores, clique em “Novo corretor” e informe o e-mail (e o nome, se quiser).',
          'O sistema mostra uma senha provisória uma única vez. Envie ao corretor por um canal seguro.',
          'No primeiro acesso, ele cria a senha própria e completa nome, CPF e CRECI.',
        ],
      },
      {
        titulo: 'Senha e remoção',
        itens: [
          '“Nova senha” gera outra senha provisória (o acesso anterior deixa de valer).',
          '“Remover” tira o acesso na hora. As pastas que ele criou continuam com a imobiliária.',
          'Cada corretor vê só as pastas atribuídas a ele; você vê as de todos.',
        ],
      },
    ],
  },

  // =========================================================================
  {
    id: 'imobiliarias', modulo: 'imobiliarias', titulo: 'Imobiliárias e logins', papeis: ['admin'],
    resumo: 'Cadastro das imobiliárias parceiras, aprovação de pedidos de acesso e todos os logins do sistema.',
    responsabilidades: {
      admin: ['Aprovar ou recusar os pedidos de cadastro, criar logins da equipe e desativar acessos de quem sair.'],
    },
    blocos: [
      {
        titulo: 'Pedidos de cadastro',
        passos: [
          'Compartilhe o link de cadastro (botão “Copiar link”) com os donos de imobiliária.',
          'O pedido aparece em “Solicitações”. Confira CNPJ, CRECI e o responsável.',
          'Aprovar: cadastre como nova imobiliária ou vincule a uma já existente. O responsável entra com a senha que criou.',
          'Recusar: escreva o motivo. O responsável vê o motivo e pode corrigir e enviar de novo.',
        ],
      },
      {
        titulo: 'Logins',
        itens: [
          'Novo login: escolha o perfil (Administrador, Sec. Vendas, Imobiliária, Corretor ou Recepcionista). A senha provisória aparece uma única vez.',
          'Imobiliária vê todas as pastas dela; corretor vê as atribuídas a ele; recepcionista só o Meeting.',
          '“Nova senha” gera outra senha provisória. “Remover” tira o acesso na hora; pastas e histórico continuam guardados.',
          'Desativar uma imobiliária tira o acesso dela e dos corretores, sem apagar dados.',
        ],
      },
    ],
  },

  // =========================================================================
  {
    id: 'empreendimento', modulo: 'empreendimento', titulo: 'Empreendimento (configurações)', papeis: ['admin'],
    resumo: 'Nome, identidade visual, módulos ligados, Pix do sinal e configurações de contrato.',
    blocos: [
      {
        titulo: 'Identidade e módulos',
        itens: [
          'Nome do empreendimento, cidade, cores, fonte, logos e imagem do login. As mudanças aparecem no painel e na TV.',
          'Módulos: ligue ou desligue cada parte do sistema. Desligar só tira do menu; nenhum dado é apagado.',
          'Propostas e Leads desligados continuam visíveis só para o administrador, para configurar e testar.',
        ],
      },
      {
        titulo: 'Pix do sinal',
        itens: [
          'Comprovante anexado: o corretor anexa o comprovante na pasta.',
          'Pix gerado pelo sistema: a pasta gera o Pix com valor e validade definidos aqui, e o recibo entra sozinho ao pagar. Depende da integração com o banco.',
        ],
      },
      {
        titulo: 'Contratos',
        texto: 'Dados para contrato, quadro de áreas, modelos em Word e documentos fixos. Veja o capítulo “Contratos e assinatura”.',
      },
    ],
  },
];
