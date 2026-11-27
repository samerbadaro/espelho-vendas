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
export const REVISAO_MANUAL = '27/11/2026';

export const NOVIDADES: { data: string; titulo: string; itens: string[]; papeis?: PapelManual[] }[] = [
  {
    data: '27/11/2026', titulo: 'Ajustes na proposta',
    itens: [
      'Proposta conjunta com unidades de tabelas diferentes: as séries iguais agora são somadas (antes apareciam repetidas).',
      'Campo “Nome da proposta”, que aparece na lista e entra na busca.',
      'A grade fica em ordem de data, com o financiamento sempre por último.',
      'Erro quando a série tem mais parcelas do que cabem até a entrega.',
      'Funil: a coluna da proposta aprovada passa a se chamar “Proposta aprovada”.',
      'Parâmetros da proposta: o administrador edita as tabelas de venda (séries, percentuais e início) e os meses da tabela e da entrega.',
      'Análise: se a documentação da pasta não estiver aprovada, o quadro avisa e o botão “Aprovar” fica desligado até a pasta ser aprovada.',
    ],
  },
  {
    data: '26/11/2026', titulo: 'Intermediação Imobiliária no contrato', papeis: ['admin', 'vendas'],
    itens: [
      'Em Contratos, a Intermediação Imobiliária é emitida com os demais documentos e entra no envelope logo depois da Carta Proposta.',
      'Contratadas (imobiliária e coordenação), valores e parcelas saem da proposta aprovada; pela imobiliária assina o gestor.',
      'O Word dos documentos emitidos agora traz todos os quadros do PDF (unidade, pagamento e comissão).',
      'Contratos: botão “Baixar tudo em um PDF” junta os documentos e anexos na ordem do envelope, para conferir antes de assinar.',
    ],
  },
  {
    data: '26/11/2026', titulo: 'Contraproposta',
    itens: [
      'Na análise, “Devolver com contraproposta” libera a grade para a equipe alterar a proposta antes de devolver.',
      'O corretor vê a proposta original e a contraproposta (abas e quadro “O que mudou”) e pode aceitar com um clique: a proposta é aprovada na hora.',
    ],
  },
  {
    data: '26/11/2026', titulo: 'Proposta conjunta: várias unidades numa simulação só',
    itens: [
      'Na proposta, “Adicionar unidade” junta mais unidades para o mesmo cliente: a simulação é feita sobre o total.',
      'Ao salvar, cada unidade vira a sua proposta, com as parcelas divididas pelo preço de tabela de cada uma.',
      'As propostas do conjunto são enviadas e analisadas juntas; as abas mostram a visão conjunta ou cada unidade sozinha.',
    ],
  },
  {
    data: '25/11/2026', titulo: 'Espelho em 3D',
    itens: [
      'No Espelho, o botão “3D” mostra o prédio em três dimensões — o modelo real da fachada do Duo Haus —, com cada apartamento na cor do status, em tempo real. Arraste para girar, use a roda (ou dois dedos) para aproximar, passe o mouse para ver os dados e clique para abrir a unidade. “Fachada” volta para a visão de antes; o navegador lembra a escolha.',
      'Na legenda, clique num status para destacar só essas unidades.',
    ],
  },
  {
    data: '25/11/2026', titulo: 'Contrato na minuta r02 do jurídico', papeis: EQUIPE,
    itens: [
      'Quadro Resumo e Normas Contratuais seguem a revisão r02: cláusulas novas (índices, tributação, LGPD, assinatura eletrônica, declarações do comprador), vaga rotativa no item 3 e aceites do comprador depois das cláusulas 6, 7 e 10.6 do Quadro Resumo e da cláusula 3 das Normas, com as assinaturas da D4Sign nas linhas.',
    ],
  },
  {
    data: '23/11/2026', titulo: 'Contrato por unidade', papeis: EQUIPE,
    itens: [
      'Cliente com mais de uma unidade na mesma pasta: cada unidade tem sua própria situação, conferência do fluxo de pagamento e comissão, documentos e envelope de assinatura. A conferência das partes (comprador e cônjuge) vale para todas as unidades da pasta.',
      'Dá para emitir com dados do empreendimento pendentes: eles saem em branco no documento, para completar no Word.',
      'Carta Proposta como o contrato: o sinal aparece líquido para a vendedora e a intermediação vem separada, com preço do imóvel + intermediação = total da proposta.',
      'Envelope: a assinatura da VENDEDORA cai na linha da SPE, e as assinaturas ficam logo acima da linha, sem cobrir o nome impresso.',
    ],
  },
  {
    data: '23/11/2026', titulo: 'Comissão com coordenação de vendas e contrato na minuta final',
    itens: [
      'A comissão passa a ter duas partes: imobiliária (5%) e coordenação de vendas (0,5%), pagas com 70% de cada parcela do sinal. A coordenação recebe primeiro, em 2 parcelas (0,25% + 0,25%); a equipe pode mudar para 1 ou 3 parcelas na proposta.',
      'O sinal mínimo para cobrir a comissão passa a ser 7,86% do valor.',
      'Quadro Resumo e Normas Contratuais seguem a minuta final do Duo Haus, com a qualificação do comprador em quadro e a comissão com as duas partes no item 9.3 (forma: conforme contrato de intermediação).',
      'No contrato, o sinal sai líquido para a vendedora (já sem a comissão, que o comprador paga direto aos intermediários) e o preço do item 4 também é líquido.',
      'A data base da correção (item 4.3.4) é sempre o dia 01 do mês da data do contrato. Para uma exceção, baixe o Word e ajuste.',
      'O item 3 traz unidade, área total e área privativa; o 3.1 descreve o direito de uso de uma vaga rotativa na garagem coletiva.',
      'Coordenação de vendas em Dados para contrato (razão social, CNPJ e quem assina): a empresa entra na linha da comissão do item 9.3 e quem assina entra sozinho no envelope, como “Coordenação de vendas”, para assinar a intermediação.',
    ],
  },
  {
    data: '23/11/2026', titulo: 'Espelho acompanha o envelope de assinatura', papeis: EQUIPE,
    itens: [
      'Ao enviar o envelope, a unidade passa sozinha para “Contrato em assinatura” no espelho; quando todos assinam, vira “Vendida”; se o envelope for cancelado, volta para “Proposta recebida”.',
      'Na lista de Contratos, a situação mostra “Envelope montado”, “Contrato enviado” e “Contrato assinado”.',
      'Botão “Atualizar status” no painel de Assinaturas: consulta a D4Sign para todos os envelopes em assinatura de uma vez.',
    ],
  },
  {
    data: '23/11/2026', titulo: 'Painel de assinaturas', papeis: ['admin', 'vendas'],
    itens: ['Menu “Assinaturas”: todos os envelopes em colunas por etapa (comprador, imobiliária, incorporadora, testemunhas, assinado), com quem falta e há quantos dias está parado.'],
  },
  {
    data: '23/11/2026', titulo: 'Assinaturas no lugar certo', papeis: ['admin', 'vendas'],
    itens: [
      'Na D4Sign, cada assinatura vai para a linha com o nome do assinante no Quadro Resumo, nas Normas e na Carta Proposta.',
      'Envelope num PDF só, na ordem Carta Proposta, Intermediação, Quadro Resumo, Normas e demais, com o nome “unidade - empreendimento - cliente”.',
    ],
  },
  {
    data: '22/11/2026', titulo: 'Cliente desistiu e devolução de Pix',
    itens: [
      'Botão “Cliente desistiu” na pasta, com motivo.',
      'Com Pix cadastrado, a pasta vai para “Devolução de Pix”; sem Pix, fica “Cliente cancelado”.',
    ],
  },
  {
    data: '22/11/2026', titulo: 'Fluxo consolidado', papeis: ['admin'],
    itens: ['Fluxo mensal das propostas aprovadas, com a comissão abatida, filtros, estatísticas e exportação.'],
  },
  {
    data: '21/11/2026', titulo: 'Pastas de empresa: 2º representante e estado civil',
    itens: [
      'Pasta de pessoa jurídica pede o comprovante de estado civil do representante.',
      'Botão “+ Adicionar 2º representante”, com dados e documentos próprios.',
      'Os dois representantes entram na leitura com IA, no Quadro Resumo, na Carta Proposta e no envelope de assinatura.',
    ],
  },
  {
    data: '21/11/2026', titulo: 'Propostas: busca, ajuste nominal e resumo',
    itens: [
      'Busca na lista de propostas por unidade, cliente, imobiliária, corretor ou código.',
      '“Ajustar para”: zerar o PV ou zerar o valor nominal da tabela.',
      'Comparativo com diferença em R$, desconto nominal e em valor presente, e captação até as chaves (tabela × proposta).',
      'Resumo da proposta em PDF ou Word, sem campos em branco e sem assinaturas.',
    ],
  },
  {
    data: '21/11/2026', titulo: 'Reserva, parâmetros e data do contrato', papeis: ['admin', 'vendas'],
    itens: [
      'Espelho: “Reservar e simular proposta” reserva e abre a proposta com a unidade e a pasta.',
      'Administrador: “Parâmetros da proposta” para dias de vencimento e alçadas de aprovação.',
      'Contratos: data do contrato (hoje ou outra) aplicada a todos os documentos; Carta Proposta também em Word.',
    ],
  },
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
          'Contrato em assinatura: envelope enviado para assinatura na D4Sign (o sistema muda sozinho ao enviar; ao assinarem todos, vira Vendida).',
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
          'Ao reservar, você pode clicar em “Reservar e simular proposta”: a unidade fica reservada e a proposta abre já com a unidade e a pasta escolhida (aparece quando o módulo de Propostas está liberado).',
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
          'Pessoa jurídica: razão social, CNPJ e os dados do representante legal (quem assina pela empresa), com o estado civil dele.',
          'Se a empresa assina com dois representantes, clique em “+ Adicionar 2º representante” e preencha nome, CPF, profissão e estado civil (telefone e e-mail são opcionais). Para tirar, use “Remover” e salve.',
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
          'Pessoa jurídica: o cônjuge do representante não é informado nem assina. Basta o “Comprovante de estado civil” de cada representante (certidão de nascimento, casamento, averbação de divórcio ou óbito, ou escritura de união estável), que serve só para qualificá-lo no contrato.',
        ],
      },
      {
        titulo: 'Documentos',
        passos: [
          'Na pasta, cada documento aparece com a etiqueta Obrigatório ou Opcional (a lista muda conforme estado civil e tipo de comprador).',
          'Pessoa jurídica: aparecem os documentos da empresa e do representante e, se houver 2º representante, o bloco “Documentos do 2º representante” (RG ou CNH, comprovante de endereço e comprovante de estado civil).',
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
        titulo: 'Cliente desistiu', papeis: [...PARCEIROS, ...EQUIPE],
        passos: [
          'Abra a pasta e clique em “Cliente desistiu”.',
          'Escreva o motivo da desistência e clique em “Registrar desistência”. Confirme.',
          'Se a pasta tinha Pix cadastrado (comprovante anexado ou Pix pago pelo sistema), ela vai para “Devolução de Pix”. Sem Pix, fica como “Cliente cancelado”.',
          'A pasta deixa de receber documentos e sai do funil.',
        ],
        atencao: 'Se a pasta tem unidade em negociação no espelho, libere a unidade primeiro. O Pix é devolvido em até 48 horas depois da desistência.',
      },
      {
        titulo: 'Devolução de Pix', papeis: EQUIPE,
        passos: [
          'Em Pastas, filtre o status “Devolução de Pix” (o Início mostra quantas estão na fila).',
          'Devolva o Pix ao cliente pelo banco.',
          'Abra a pasta, escreva uma observação se quiser (por exemplo, a data da devolução) e clique em “Pix devolvido: mover para Cliente cancelado”.',
        ],
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
          'Proposta aprovada: proposta aprovada, contrato sendo preparado (espelho: Proposta recebida).',
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
    resumo: 'A proposta montada sobre a tabela de vendas, com PV, comissão, aprovação por alçada e resumo da proposta em PDF ou Word.',
    responsabilidades: {
      corretor: ['Montar a proposta com o fluxo combinado com o cliente, vincular a pasta e enviar para análise.', 'Ajustar e reenviar as propostas devolvidas; levar as contrapropostas ao cliente e aceitar só com o ok dele.'],
      imobiliaria: ['Acompanhar as propostas dos seus corretores e montar propostas quando necessário.'],
      vendas: ['Analisar as propostas na sua alçada: aprovar, devolver para ajuste ou recusar, sempre com o motivo.'],
      admin: ['Analisar as propostas abaixo da alçada da Sec. Vendas e acompanhar os descontos concedidos.', 'Manter os parâmetros da proposta: dias de vencimento e alçadas de aprovação.'],
    },
    blocos: [
      {
        titulo: 'Montar uma proposta', papeis: TODOS,
        passos: [
          'Em Propostas, clique em “Nova proposta” e escolha a unidade.',
          'Dê um nome à proposta no campo “Nome da proposta” (ex.: “Samer – Lote do Parque do Cerrado”). Ele aparece na lista e entra na busca, para achar rascunhos e saber de qual tratativa é.',
          'O fluxo da tabela já vem montado. Use “Modelo da tabela”, “Mensais até a entrega”, “Semestrais”, “Anuais” ou “Até as chaves” para trocar o modelo, ou edite as séries (quantidade, periodicidade, 1º vencimento e valor). A grade se reorganiza sozinha em ordem de data (ao sair do campo de data, ao trocar a periodicidade e ao incluir série), com o financiamento sempre por último.',
          'Toda parcela antes das chaves precisa vencer até o mês da entrega. Se a série tiver parcelas demais, a linha fica vermelha e o sistema diz quantas cabem (ex.: “Cabem 7 parcelas semestrais até a entrega (out/2030); a série tem 8”). Com erro, a proposta não pode ser enviada.',
          'Em “Ajustar para”, escolha “Zerar PV” (o valor presente fica igual ao da tabela) ou “Zerar nominal” (o valor total fica igual ao da tabela; o PV pode ficar abaixo). Depois clique em “⟲ ajustar” na série que vai absorver a diferença. O preço nunca passa do preço de tabela: se zerar o PV exigir isso, a série para no preço de tabela e o sistema avisa que, com essa condição, não dá para chegar ao PV 0 (antecipe parcelas para melhorar). Se por qualquer motivo o preço passar da tabela (por exemplo, depois de “Aumentar o ato”), a proposta mostra um erro e não pode ser enviada até voltar ao preço de tabela.',
          'Acompanhe o comparativo tabela × proposta: valor total, PV (valor presente), preço do m² e captação até as chaves, cada um com a variação em % e a diferença em R$. Logo abaixo aparecem o desconto nominal e o desconto em valor presente, em R$.',
          'A tabela “Captação acumulada” mostra o % recebido em cada marco (3, 6, 12... meses e até a entrega).',
          'Confira a comissão. Ela sai das parcelas do sinal: de cada parcela, 70% vai para a comissão e 30% para o incorporador. Dentro da comissão, a coordenação de vendas (0,5%) recebe primeiro, dividida em 2 parcelas (0,25% + 0,25%), e o restante vai para a imobiliária (5%), até completar 5,5%. A tabela mostra quanto vai para cada um em cada parcela.',
          'Se o sinal cobre a comissão inteira numa parcela só, a coordenação recebe os 0,5% nela. A equipe pode mudar, numa proposta, em quantas parcelas a coordenação recebe (1, 2 ou 3).',
          'O sinal precisa ser de pelo menos 7,86% do valor (5,5% ÷ 70%). Se não cobrir, use “Aumentar o ato para cobrir a comissão”.',
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
          'A proposta pode ser enviada mesmo com PV abaixo da tabela: ela não é aprovada sozinha e fica “Enviada, aguardando” a Sec. Vendas ou o Administrador, conforme o desconto. Vale para propostas feitas por corretor, imobiliária ou gerente.',
          'O que bloqueia o envio são só os erros da grade (vencimento, parcelas, valor) e a permuta sem descrição.',
        ],
      },
      {
        titulo: 'Proposta conjunta (várias unidades para o mesmo cliente)', papeis: TODOS,
        passos: [
          'Na proposta, depois de escolher a primeira unidade, clique em “Adicionar unidade” para cada unidade a mais. Para tirar uma, clique no “×” ao lado dela.',
          'A simulação passa a ser do conjunto: área, preço de tabela e fluxo da tabela somados. Monte o fluxo sobre 100% do total, como numa proposta comum (modelos, “⟲ ajustar”, comissão).',
          'Abaixo das unidades aparece a divisão: o peso de cada uma é o preço de tabela dela dividido pela soma. Ex.: unidades de R$ 400 mil, R$ 400 mil e R$ 200 mil ficam com 40%, 40% e 20%.',
          'Ao clicar em “Salvar rascunho” ou “Enviar para análise”, cada unidade vira uma proposta própria, com as mesmas datas e quantidades e cada parcela dividida pelo peso. Os centavos do arredondamento ficam na última unidade, para a soma bater com a simulação.',
          'Na proposta salva, use as abas no topo: “Conjunta” mostra tudo junto (e é onde se edita); cada aba com código e unidade mostra a proposta daquela unidade sozinha.',
          'O “Resumo da proposta” sai do que está na tela: na aba “Conjunta”, com todas as unidades e o fluxo total; na aba de uma unidade, só com ela.',
          'Na lista de Propostas, o conjunto aparece numa linha só, marcada “conjunta”, com as unidades, o valor somado e o PV do conjunto.',
        ],
        atencao: 'As propostas de um conjunto são enviadas e analisadas juntas: a alçada é calculada pelo PV do conjunto, e aprovar, devolver ou recusar vale para todas as unidades. Depois de aprovadas, cada unidade segue sozinha para contrato e assinatura.',
      },
      {
        titulo: 'Analisar uma proposta conjunta', papeis: ['vendas', 'admin'],
        passos: [
          'Abra a proposta e fique na aba “Conjunta”. O quadro “Análise da proposta conjunta” vale para todas as unidades.',
          'Clique em “Aprovar”, “Devolver com contraproposta” ou “Recusar” (com o motivo). A contraproposta é feita sobre o total, na aba “Conjunta”, e dividida entre as unidades pelo preço de tabela. Se uma unidade não puder ser aprovada (por exemplo, já negociada no espelho), nenhuma é aprovada e o sistema avisa o motivo.',
          'Para cancelar uma unidade só depois da aprovação (desistência de uma delas), abra a aba da unidade e clique em “Cancelar só esta unidade”. “Cancelar a proposta conjunta”, na aba “Conjunta”, cancela todas.',
        ],
      },
      {
        titulo: 'Buscar propostas', papeis: TODOS,
        texto: 'Na lista de Propostas, use o campo de busca para encontrar pelo nome da proposta, unidade, nome do cliente, imobiliária, corretor ou código. A busca não diferencia acentos nem maiúsculas e funciona junto com o filtro de status.',
      },
      {
        titulo: 'Parâmetros da proposta', papeis: ['admin'],
        passos: [
          'Em “Tabelas de venda” (no fim de Parâmetros da proposta), ajuste o mês da tabela e o mês da entrega e clique em “Salvar meses”.',
          'Escolha a tabela (TABELA 1, TABELA 2) e edite cada série: nome, periodicidade, número de parcelas, % do preço, a partir de quando (tabela ou entrega) e quantos meses depois (use número negativo para antes da entrega; ex.: Única 12 meses antes = entrega, −12). As colunas “1ª parcela” e “Última” mostram o mês de cada uma.',
          'Os percentuais precisam somar 100%, e só as parcelas do financiamento podem passar da entrega. Clique em “Salvar TABELA …”. A mudança vale para as próximas propostas abertas e para o PV calculado no envio.',
          'Em Propostas, clique em “Parâmetros da proposta”.',
          'Dias de vencimento: marque os dias do mês permitidos nas parcelas (o ato, na data da proposta, fica de fora). Esses dias aparecem como opção em “Vencimento” no editor.',
          'Alçadas: ligue ou desligue a aprovação automática e defina o PV mínimo (em % do VPL da tabela) para aprovação automática e para a Sec. Vendas. Abaixo do percentual da Sec. Vendas, só o administrador aprova.',
          'Clique em “Salvar parâmetros”. Vale para as próximas propostas abertas.',
        ],
      },
      {
        titulo: 'Proposta devolvida ou recusada', papeis: PARCEIROS,
        texto: 'A proposta devolvida volta a ser editável e mostra o motivo no topo: ajuste e envie de novo. Proposta recusada ou cancelada fica só para consulta.',
      },
      {
        titulo: 'Contraproposta recebida', papeis: PARCEIROS,
        passos: [
          'Quando a equipe devolve com contraproposta, a proposta aparece como “Devolvida para ajuste” com a marca “com contraproposta” na lista.',
          'No quadro “Contraproposta”, veja quem fez, quando e o motivo. A tabela “O que mudou” compara a proposta original com a contraproposta: valor total, PV sobre a tabela, sinal e comissão. Abaixo, as séries que saíram aparecem riscadas e as que entraram, em negrito.',
          'Use as abas “Contraproposta” e “Proposta original” para ver cada versão completa na grade, com o comparativo e a captação.',
          'Se o cliente aceitar, clique em “Aceitar contraproposta”: a proposta é aprovada na hora e a unidade vai para “Proposta recebida”. Vincule a pasta antes.',
          'Se o cliente pedir outra condição, altere a grade e clique em “Enviar para análise”: ela volta para a equipe, com a alçada calculada de novo.',
        ],
        atencao: 'Depois de alterar a grade, o botão “Aceitar contraproposta” fica desligado: o que foi alterado precisa passar pela análise.',
      },
      {
        titulo: 'Resumo da proposta', papeis: TODOS,
        texto: 'O botão “Resumo da proposta” gera um PDF (e o botão “Word”, o mesmo em .docx) com o imóvel, os proponentes, o fluxo de pagamento, a intermediação e as condições gerais. É um resumo para o cliente conferir: sai só com os campos preenchidos e sem assinaturas. A carta para assinatura, com os dados conferidos pela IA, é emitida em Contratos.',
      },
      {
        titulo: 'Analisar propostas', papeis: EQUIPE,
        passos: [
          'Abra a proposta enviada. Confira o PV, o fluxo e a comissão (a equipe pode ajustar a comissão).',
          'Aprovar: a unidade vai para “Proposta recebida” no espelho, com valor e PV.',
          'Devolver com contraproposta: a grade fica liberada para você. Altere séries, valores, vencimentos e, se precisar, a comissão; escreva o motivo e clique em “Devolver com contraproposta”. O corretor verá a original e a sua versão lado a lado, e pode aceitar com um clique (aprovação na hora).',
          'Se você não alterar a grade, o botão só devolve a proposta para ajuste, com o motivo. “Desistir” descarta as alterações.',
          'A Sec. Vendas só faz contraproposta dentro da sua alçada (PV a partir do limite dela); abaixo disso, só o administrador.',
          'Recusar ou cancelar: o motivo é obrigatório.',
        ],
        dica: 'Com o módulo desligado, só o administrador vê Propostas (para testar). Tabela e taxa são configuradas pela Launch; dias de vencimento, alçadas, comissão da imobiliária, coordenação de vendas (percentual e em quantas parcelas) e a parte do sinal para a comissão, pelo administrador em “Parâmetros da proposta”.',
      },
    ],
  },

  // =========================================================================
  {
    id: 'fluxo', modulo: 'propostas', titulo: 'Fluxo consolidado', papeis: ['admin'],
    resumo: 'O fluxo de recebimento do incorporador com todas as propostas aprovadas, mês a mês, já sem a comissão.',
    responsabilidades: { admin: ['Acompanhar a curva de recebimento e exportar o fluxo para as análises de caixa.'] },
    blocos: [
      {
        titulo: 'O que entra no fluxo',
        texto: 'Entram as propostas aprovadas (a mais recente de cada unidade). Ficam de fora as pastas de clientes que desistiram. Os valores são nominais, sem correção pelo INCC. A comissão sai do sinal; o que o sinal não cobre sai das parcelas seguintes. Permutas não entram no caixa.',
      },
      {
        titulo: 'Usar a tela',
        passos: [
          'No menu, abra “Fluxo consolidado”.',
          'Filtre por Unidade, Imobiliária, Cliente, Tipologia ou Final. O botão “Consolidado” limpa os filtros.',
          'Os quadros mostram unidades, VGV aprovado, comissão, líquido do incorporador, quanto entra até as chaves e quanto vem do financiamento.',
          'Na “Curva de recebimento”, escolha “Mensal” ou “Anual”. As barras são o líquido do período; a linha é o % acumulado.',
          'A tabela mostra bruto, comissão, líquido, acumulado e % acumulado de cada período. “Exportar CSV” baixa essa tabela para o Excel.',
          'Em “Estatísticas”, agrupe por imobiliária, tipologia ou final para ver unidades, VGV, ticket médio, R$/m², comissão e líquido.',
        ],
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
          'Clique em ler os documentos com IA. Ela lê RG, CNH, certidões, comprovantes e, para empresas, contrato social e cartão CNPJ. Com 2º representante, os dados dele aparecem em um quadro próprio para conferir.',
          'Confira cada campo sugerido (nome, nacionalidade, profissão, documento, endereço, regime de bens). Corrija o que for preciso.',
          'Marque como conferido. Só dados conferidos vão para os documentos.',
        ],
        atencao: 'A IA sugere; a responsabilidade pela conferência é da equipe. Compare com os documentos originais.',
      },
      {
        titulo: '2. Unidade e 3. Pagamento',
        itens: [
          'A unidade usa o quadro de áreas importado pelo administrador (área privativa, comum, fração ideal, vagas e escaninho).',
          'Confira as séries do fluxo aprovado e os beneficiários da comissão (nome, documento, valor e forma), e marque o fluxo como conferido. A comissão já vem com duas linhas: a imobiliária da proposta (5%) e a coordenação de vendas (0,5%). Elas saem no item 9.3 do Quadro Resumo como pagas diretamente pelo comprador. Por isso o sinal do contrato (item 4.1, alínea a) e o preço já saem sem a comissão: de cada parcela de sinal sai até 70% para a comissão, na ordem, e o restante é o que fica no contrato. A data base da correção (4.3.4) é o dia 01 do mês da data do contrato.',
        ],
      },
      {
        titulo: '4. Emissão',
        passos: [
          'Marque o que emitir: Intermediação Imobiliária, Quadro Resumo, Normas e Carta Proposta. O sistema sugere só o que ainda não foi emitido.',
          'A Intermediação Imobiliária sai pronta: contratante(s) da pasta conferida; imobiliária (nome, CNPJ, CRECI-J) e coordenação de vendas com percentual e valor; valor total da negociação dividido em preço do imóvel + intermediação; e uma linha por parcela do sinal com a parte da imobiliária e da coordenação, tiradas da proposta aprovada. O pagamento é descrito como cobrança mensal única pela Imobitech, que distribui para cada parte.',
          'Pela imobiliária assina sempre o gestor, nunca o corretor. Se a proposta foi feita pelo próprio gestor, é ele; senão, o gestor da imobiliária da proposta. A vendedora não assina a intermediação.',
          'Use “Pré-visualizar” para conferir antes.',
          'Em “Data do contrato”, escolha “Hoje” ou “Outra data” e informe a data. Ela sai no local e data de todos os documentos (Intermediação, Quadro Resumo, Normas e Carta Proposta).',
          'Clique em “Emitir documentos” e confira a data na confirmação. Cada documento ganha um número e fica aguardando validação. Todos saem em PDF e em Word, com os mesmos quadros.',
          'Precisa ajustar a formatação? Baixe o Word, edite e use “Enviar ajuste”. A versão sobe e a validação volta para pendente.',
          'Para conferir tudo de uma vez, clique em “Baixar tudo em um PDF”: os documentos ativos e os anexos fixos saem num arquivo só, na mesma ordem do envelope da D4Sign. Documento que só existe em Word fica de fora, e o sistema avisa qual.',
          'Confira e clique em “Validar” em cada documento.',
        ],
      },
      {
        titulo: '5. Envelope de assinatura (D4Sign)',
        passos: [
          'Com todos os documentos validados, clique em “Montar envelope na D4Sign”. Os documentos marcados viram um PDF só, nesta ordem: Carta Proposta, Intermediação Imobiliária, Quadro Resumo, Normas Contratuais e os demais documentos fixos. Na D4Sign o arquivo aparece como “unidade - empreendimento - cliente” (ex.: 206 - Duo Haus - Fulano de Tal).',
          'Confira a prévia (PDF do envelope ou o pacote completo em ZIP). Se algo estiver errado, use “Descartar e ajustar”.',
          'Revise os assinantes e a ordem: cliente e cônjuge, imobiliária (o gestor), coordenação de vendas, incorporadora e testemunhas. Cada um pode receber por e-mail ou WhatsApp.',
          'A assinatura de cada pessoa vai para a linha com o nome dela nos documentos gerados pelo sistema. Por isso, o nome do assinante tem que ser o mesmo que aparece embaixo da linha. Quem não tiver linha com o nome assina na folha de assinaturas da D4Sign.',
          'Clique em “Enviar para assinatura”. A unidade passa sozinha para “Contrato em assinatura” no espelho e a lista de Contratos mostra “Contrato enviado”. Acompanhe quem já assinou e use “Reenviar” para quem está pendente.',
          'Quando todos assinarem, a unidade vira “Vendida” no espelho e o contrato aparece como “Contrato assinado”. Baixe o pacote assinado (ZIP).',
          'Se cancelar o envelope (aqui ou na D4Sign), a unidade volta para “Proposta recebida”. Uma unidade já vendida não muda sozinha.',
        ],
        dica: 'Para acompanhar todos os envelopes de uma vez, use o menu “Assinaturas”. Todos os documentos do envelope precisam estar em PDF. Documentos emitidos antes de 23/11/2026 não têm a posição das assinaturas: emita de novo para posicionar. A D4Sign limita as chamadas por hora da chave de API; se aparecer o aviso de limite, aguarde e tente de novo.',
        atencao: 'Enquanto o envelope estiver montado ou em assinatura, os documentos ficam travados. Para mudar algo, descarte (antes do envio) ou cancele o envelope.',
      },
      {
        titulo: 'Painel de assinaturas', papeis: EQUIPE,
        passos: [
          'No menu, abra “Assinaturas”.',
          'Os quadros mostram quantos contratos estão em assinatura, quantos estão parados há 2 dias ou mais, quantos já foram assinados (com o tempo médio) e quantos estão montados sem envio.',
          'As colunas mostram em quem cada contrato está parado: Comprador (inclui cônjuge e representantes), Imobiliária, Incorporadora, Testemunhas e Assinado.',
          'Cada cartão mostra a unidade, o cliente, a imobiliária, uma barrinha por assinante (verde: assinou; laranja: é a vez dele), quem falta e há quantos dias está parado. Em vermelho, os parados há 2 dias ou mais.',
          'O painel se atualiza sozinho com o aviso da D4Sign. Se alguma assinatura demorar a aparecer, clique em “Atualizar status” no topo: o sistema consulta a D4Sign para todos os envelopes em assinatura (uma consulta por envelope; a D4Sign limita as consultas por hora).',
          'Clique no cartão para abrir o contrato e usar “Reenviar” ou “Atualizar status”. Use a busca para achar por cliente, unidade, imobiliária ou proposta, e “Mostrar cancelados” para ver os envelopes cancelados.',
        ],
        dica: 'O painel usa o retorno automático da D4Sign e não gasta chamadas da API ao abrir.',
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
