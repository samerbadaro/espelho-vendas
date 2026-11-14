// Carrega do banco os parâmetros comerciais, a tabela de vendas e as unidades,
// no formato do motor, e grava as propostas.
import { supabase } from '../dados';
import { hojeISO, resolverCaptacao, type ConfigEmpreendimento, type Periodicidade, type Serie, type SerieCaptacao, type SerieTabela, type Unidade, type Resultado } from './motor';

export interface Comercial {
  mes_tabela: string; mes_entrega: string; taxa_vp: number; comissao_pct: number; parte_sinal: number;
  limite_captacao: number; dias_vencimento: number[]; vendedora: string | null; vendedora_cnpj: string | null;
  cidade_carta: string | null; forma_sinal: string; forma_parcelas: string; validade_dias: number;
  texto_abertura: string; texto_condicoes: string;
  vaga?: string; escaninho?: string; coordenacao_comercial?: string | null;
  alcada_automatica?: boolean; alcada_auto_pv?: number; alcada_vendas_pv?: number;
}

export interface UnidadeComercial extends Unidade { id: string; status: string; versao: number; andar: number | null; tipologia: string | null }

export type SituacaoTabela = 'rascunho' | 'agendada' | 'vigente' | 'encerrada';
export interface TabelaResumo {
  id: string; nome: string; mes_referencia: string; vigente_desde: string | null; situacao: SituacaoTabela;
  origem: string; observacao: string | null; unidades: number; vgv: number; criada_por: string | null; criada_em: string;
  ativada_por: string | null; atualizada_em: string; base_id: string | null;
}
export const ROTULO_SITUACAO: Record<SituacaoTabela, string> = { rascunho: 'Rascunho', agendada: 'Agendada', vigente: 'Vigente', encerrada: 'Encerrada' };

export interface Contexto {
  cfg: ConfigEmpreendimento; comercial: Comercial; unidades: UnidadeComercial[]; nome: string; logoUrl: string | null; corDestaque: string;
  tabela: TabelaResumo; vigente: TabelaResumo | null; proxima: TabelaResumo | null; mesVenda: string;
}

export interface CaptacaoBanco { numero: number; nome: string; series: SerieCaptacao[] }

/** Captações de uma tabela, como cadastradas (quantidade fixa ou automática). */
export async function carregarCaptacoes(tabelaId: string): Promise<CaptacaoBanco[]> {
  const [c, s] = await Promise.all([
    supabase.from('captacoes').select('numero, nome').eq('tabela_id', tabelaId).order('numero'),
    supabase.from('captacoes_series').select('captacao, ordem, rotulo, periodicidade, percentual, qtd, base, meses, fim_meses').eq('tabela_id', tabelaId).order('ordem'),
  ]);
  const series = (s.data ?? []) as { captacao: number; rotulo: string; periodicidade: Periodicidade; percentual: number; qtd: number | null; base: 'venda' | 'entrega'; meses: number; fim_meses: number | null }[];
  return ((c.data ?? []) as { numero: number; nome: string }[]).map((x) => ({
    numero: x.numero, nome: x.nome,
    series: series.filter((y) => y.captacao === x.numero).map((y) => ({
      rotulo: y.rotulo, periodicidade: y.periodicidade, percentual: Number(y.percentual), qtd: y.qtd, fimMeses: y.fim_meses,
      inicio: { base: y.base, meses: y.meses },
    })),
  }));
}

/** Mês da venda: o mês da data (hoje, ou a da proposta), nunca antes do mês de referência da tabela. */
export const mesDaVenda = (t: Pick<TabelaResumo, 'mes_referencia'>, data: string) => {
  const a = t.mes_referencia.slice(0, 7), b = data.slice(0, 7);
  return a > b ? a : b;
};

/**
 * Parâmetros, tabela de vendas e unidades, no formato do motor.
 * Sem tabelaId, usa a vigente. A data define o mês da venda (quantidade de parcelas da captação).
 */
export async function carregarContexto(op: { tabelaId?: string | null; data?: string; proxima?: boolean } = {}): Promise<Contexto | { erro: string }> {
  const [c, t, u, cfgMarca] = await Promise.all([
    supabase.from('comercial').select('*').eq('id', 1).maybeSingle(),
    supabase.from('tabelas_preco_resumo').select('*').neq('situacao', 'rascunho').order('vigente_desde', { ascending: false }),
    supabase.from('unidades').select('id, numero, andar, area_privativa, tipologia, status, versao').order('andar').order('posicao'),
    supabase.from('config').select('nome_empreendimento, logo_url, cor_destaque').eq('id', 1).maybeSingle(),
  ]);
  const erro = c.error || t.error || u.error;
  if (erro) return { erro: erro.message.includes('does not exist') ? 'O banco ainda não tem a tabela de vendas (migração 110).' : erro.message };
  if (!c.data) return { erro: 'Parâmetros comerciais não cadastrados.' };
  const comercial = c.data as Comercial;
  const publicadas = (t.data ?? []) as TabelaResumo[];
  const vigente = publicadas.find((x) => x.situacao === 'vigente') ?? null;
  const proxima = publicadas.find((x) => x.situacao === 'agendada') ?? null;
  let tabela = op.proxima ? proxima : op.tabelaId ? publicadas.find((x) => x.id === op.tabelaId) ?? null : vigente;
  if (!tabela && op.tabelaId) {
    const { data } = await supabase.from('tabelas_preco_resumo').select('*').eq('id', op.tabelaId).maybeSingle();
    tabela = (data as TabelaResumo | null) ?? null;
  }
  if (!tabela) return { erro: 'Nenhuma tabela de vendas vigente. Cadastre e ative uma tabela em "Tabela de vendas".' };

  const [itens, caps] = await Promise.all([
    supabase.from('tabelas_preco_itens').select('unidade_id, preco, captacao').eq('tabela_id', tabela.id),
    carregarCaptacoes(tabela.id),
  ]);
  if (itens.error) return { erro: itens.error.message };
  const mesVenda = mesDaVenda(tabela, op.data ?? hojeISO());
  const mesEntrega = comercial.mes_entrega.slice(0, 7);
  const tabelas: Record<string, SerieTabela[]> = {};
  const nomesTabelas: Record<string, string> = {};
  for (const cap of caps) { tabelas[String(cap.numero)] = resolverCaptacao(cap.series, mesVenda, mesEntrega); nomesTabelas[String(cap.numero)] = cap.nome; }

  const porUnidade = new Map(((itens.data ?? []) as { unidade_id: string; preco: number; captacao: number }[]).map((x) => [x.unidade_id, x]));
  const unidades: UnidadeComercial[] = ((u.data ?? []) as {
    id: string; numero: string; andar: number | null; area_privativa: number | null; tipologia: string | null; status: string; versao: number;
  }[])
    .filter((x) => porUnidade.has(x.id) && tabelas[String(porUnidade.get(x.id)!.captacao)])
    .map((x) => {
      const it = porUnidade.get(x.id)!;
      return {
        id: x.id, numero: x.numero, area: Number(x.area_privativa ?? 0), tipo: x.tipologia ?? '', peso: 1, tabela: String(it.captacao),
        preco: Number(it.preco), status: x.status, versao: x.versao, andar: x.andar, tipologia: x.tipologia,
      };
    });
  if (!unidades.length) return { erro: `A tabela "${tabela.nome}" não tem unidades com preço.` };

  const marca = cfgMarca.data as { nome_empreendimento: string; logo_url: string | null; cor_destaque: string | null } | null;
  const nome = marca?.nome_empreendimento || 'Empreendimento';
  const cfg: ConfigEmpreendimento = {
    nome,
    mesTabela: mesVenda,
    mesEntrega,
    taxaVP: Number(comercial.taxa_vp),
    precoM2PorTipo: {},
    tabelas,
    nomesTabelas,
    unidades,
    comissao: { percentual: Number(comercial.comissao_pct), parteDoSinal: Number(comercial.parte_sinal) },
    limiteVariacaoCaptacao: Number(comercial.limite_captacao),
  };
  return { cfg, comercial, unidades, nome, logoUrl: marca?.logo_url ?? null, corDestaque: marca?.cor_destaque ?? '#94874A', tabela, vigente, proxima, mesVenda };
}

export type StatusProposta = 'rascunho' | 'enviada' | 'aprovada' | 'recusada' | 'devolvida' | 'cancelada';
export const STATUS_PROPOSTA: { valor: StatusProposta; rotulo: string }[] = [
  { valor: 'rascunho', rotulo: 'Rascunho' },
  { valor: 'enviada', rotulo: 'Em análise' },
  { valor: 'devolvida', rotulo: 'Devolvida para ajuste' },
  { valor: 'aprovada', rotulo: 'Aprovada' },
  { valor: 'recusada', rotulo: 'Recusada' },
  { valor: 'cancelada', rotulo: 'Cancelada' },
];
export const rotuloProposta = (s: StatusProposta) => STATUS_PROPOSTA.find((x) => x.valor === s)?.rotulo ?? s;

export interface PropostaSalva {
  id: string; codigo: string; unidade_id: string; pasta_id: string | null; imobiliaria_id: string | null;
  criado_por_id: string | null; criado_por: string | null; criado_por_nome?: string | null; data_proposta: string; status: StatusProposta;
  series: Omit<Serie, 'id'>[]; resumo: Resumo; tabela_id?: string | null; observacoes: string | null; comissao_pct: number | null; parte_sinal: number | null;
  motivo_analise: string | null; analisada_por: string | null; analisada_em: string | null; enviada_em: string | null;
  versao: number; criada_em: string; atualizada_em: string; alcada?: Alcada | null;
}

export type Alcada = 'automatica' | 'vendas' | 'admin';
export const ROTULO_ALCADA: Record<Alcada, string> = { automatica: 'Aprovação automática', vendas: 'Sec. Vendas', admin: 'Administrador' };

/** Alçada prevista para a proposta (a definitiva é calculada pelo banco no envio). */
export function alcadaPrevista(c: Comercial, pvPct: number, comissaoCoberta: boolean): Alcada {
  if ((c.alcada_automatica ?? true) && pvPct >= Number(c.alcada_auto_pv ?? 100) && comissaoCoberta) return 'automatica';
  if (pvPct >= Number(c.alcada_vendas_pv ?? 98)) return 'vendas';
  return 'admin';
}

export interface Resumo {
  total?: number; preco_tabela?: number; vpl_tabela?: number; vpl_proposta?: number; pv_pct?: number;
  diferenca_vpl?: number; comissao?: number; avisos?: string[];
}

export function resumoDe(r: Resultado): Resumo {
  const c2 = (v: number) => Math.round(v * 100) / 100;
  return {
    total: c2(r.proposta.total), preco_tabela: c2(r.preco), vpl_tabela: c2(r.tabela.vpl), vpl_proposta: c2(r.proposta.vpl),
    pv_pct: Math.round((r.proposta.vpl / r.tabela.vpl) * 10000) / 100, diferenca_vpl: c2(r.diferencaVPL),
    comissao: r.comissao.devida, avisos: r.avisos.map((a) => a.texto),
  };
}

export const paraBanco = (series: Serie[]) =>
  series.map(({ qtd, periodicidade, vencimento, valor }) => ({ qtd, periodicidade, vencimento, valor: Math.round(valor * 100) / 100 }));

let seq = 0;
export const doBanco = (series: Omit<Serie, 'id'>[]): Serie[] => series.map((s) => ({ ...s, id: `b${seq++}`, valor: Number(s.valor), qtd: Number(s.qtd) }));

const ERROS: Record<string, string> = {
  VENCIMENTO_ANTERIOR: 'Há vencimento anterior à data da proposta.',
  SERIE_INVALIDA: 'Há série sem parcelas ou com valor zerado.',
  PROPOSTA_BLOQUEADA: 'Esta proposta já foi enviada e não pode mais ser editada.',
  PASTA_OBRIGATORIA: 'Vincule a pasta do comprador antes de enviar.',
  PASTA_NAO_ENCONTRADA: 'Pasta não encontrada.',
  PASTA_NAO_APROVADA: 'A pasta do comprador ainda não está aprovada.',
  MOTIVO_OBRIGATORIO: 'Informe o motivo.',
  PROPOSTA_NAO_ENVIADA: 'A proposta não está em análise.',
  UNIDADE_COM_PROPOSTA_APROVADA: 'Esta unidade já tem outra proposta aprovada.',
  UNIDADE_INDISPONIVEL: 'A unidade está em outra etapa no espelho (contrato ou vendida).',
  UNIDADE_COM_OUTRA_PASTA: 'A unidade está negociada com outra pasta no espelho.',
  SEM_PERMISSAO: 'Sem permissão para esta ação.',
  ALCADA_ADMIN: 'PV abaixo do limite da Sec. Vendas: só o administrador aprova esta proposta.',
  UNIDADE_SEM_PRECO: 'A unidade não tem preço de tabela configurado (tipo, peso e tabela).',
  FILA_DESLIGADA: 'A escolha de unidades pela fila está desligada.',
  PASTA_AINDA_NAO_LIBERADA: 'Esta pasta ainda não foi liberada na fila.',
  PASTA_FORA_DA_FILA: 'Esta pasta não está na fila de escolha.',
  LIMITE_DE_UNIDADES_DA_PASTA: 'Esta pasta já atingiu o limite de unidades reservadas.',
  INICIO_OBRIGATORIO: 'Informe a data e a hora de início da fila.',
  TABELA_ENCERRADA: 'A tabela desta proposta não está mais vigente. Clique em "Atualizar para a tabela vigente" e revise os valores.',
  TABELA_NAO_VIGENTE: 'A proposta só pode ir para a tabela vigente.',
  TABELA_JA_VIGENTE: 'Tabela vigente ou encerrada não muda. Crie uma nova tabela a partir dela.',
  TABELA_INCOMPLETA: 'Há unidades sem preço nesta tabela.',
  TABELA_SEM_CAPTACAO: 'Cadastre ao menos uma captação.',
  CAPTACAO_NAO_SOMA_100: 'Cada captação precisa somar 100%.',
  CAPTACAO_EM_USO: 'Há unidades ligadas à captação removida. Troque a captação delas antes.',
  CAPTACAO_INEXISTENTE: 'Captação não cadastrada nesta tabela.',
  CAPTACOES_1_A_3: 'São de 1 a 3 captações por tabela.',
  JA_EXISTE_TABELA_AGENDADA: 'Já existe outra tabela agendada. Cancele o agendamento dela antes.',
  TABELA_AGENDADA: 'Cancele o agendamento antes de excluir.',
  TABELA_COM_PROPOSTAS: 'Esta tabela já tem propostas e não pode ser excluída.',
  REAJUSTE_INVALIDO: 'Percentual de reajuste inválido.',
  PRECO_INVALIDO: 'Preço inválido.',
  ARQUIVO_VAZIO: 'O arquivo não tem linhas.',
  PERMUTA_SEM_OBSERVACAO: 'Descreva a permuta nas observações da proposta antes de enviar.',
};
export const traduzirErro = (msg: string) => ERROS[Object.keys(ERROS).find((k) => msg.includes(k)) ?? ''] ?? msg;
