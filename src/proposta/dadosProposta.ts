// Carrega do banco os parâmetros comerciais, a tabela de vendas e as unidades,
// no formato do motor, e grava as propostas.
import { supabase } from '../dados';
import type { ConfigEmpreendimento, Periodicidade, Serie, SerieTabela, Unidade, Resultado } from './motor';

export interface Comercial {
  mes_tabela: string; mes_entrega: string; taxa_vp: number; comissao_pct: number; parte_sinal: number;
  limite_captacao: number; dias_vencimento: number[]; vendedora: string | null; vendedora_cnpj: string | null;
  cidade_carta: string | null; forma_sinal: string; forma_parcelas: string; validade_dias: number;
  texto_abertura: string; texto_condicoes: string;
  vaga?: string; escaninho?: string; coordenacao_comercial?: string | null;
  alcada_automatica?: boolean; alcada_auto_pv?: number; alcada_vendas_pv?: number;
}

export interface UnidadeComercial extends Unidade { id: string; status: string; versao: number; andar: number | null }

export interface Contexto { cfg: ConfigEmpreendimento; comercial: Comercial; unidades: UnidadeComercial[]; nome: string; logoUrl: string | null; corDestaque: string }

export async function carregarContexto(): Promise<Contexto | { erro: string }> {
  const [c, p, s, u, cfgMarca] = await Promise.all([
    supabase.from('comercial').select('*').eq('id', 1).maybeSingle(),
    supabase.from('precos_tipo').select('tipo, preco_m2'),
    supabase.from('tabelas_series').select('tabela, ordem, rotulo, periodicidade, qtd, percentual, base, meses').order('ordem'),
    supabase.from('unidades').select('id, numero, andar, area_privativa, tipo_preco, peso, tabela, status, versao').order('andar').order('posicao'),
    supabase.from('config').select('nome_empreendimento, logo_url, cor_destaque').eq('id', 1).maybeSingle(),
  ]);
  const erro = c.error || p.error || s.error || u.error;
  if (erro) return { erro: erro.message.includes('does not exist') ? 'O banco ainda não tem a estrutura de propostas (migração 022).' : erro.message };
  if (!c.data) return { erro: 'Parâmetros comerciais não cadastrados.' };
  const comercial = c.data as Comercial;

  const tabelas: Record<string, SerieTabela[]> = {};
  for (const x of (s.data ?? []) as { tabela: string; rotulo: string; periodicidade: Periodicidade; qtd: number; percentual: number; base: 'venda' | 'entrega'; meses: number }[]) {
    (tabelas[x.tabela] ??= []).push({ rotulo: x.rotulo, periodicidade: x.periodicidade, qtd: x.qtd, percentual: Number(x.percentual), inicio: { base: x.base, meses: x.meses } });
  }
  const precoM2PorTipo = Object.fromEntries(((p.data ?? []) as { tipo: string; preco_m2: number }[]).map((x) => [x.tipo, Number(x.preco_m2)]));
  const unidades: UnidadeComercial[] = ((u.data ?? []) as {
    id: string; numero: string; andar: number | null; area_privativa: number | null; tipo_preco: string | null; peso: number | null; tabela: string | null; status: string; versao: number;
  }[])
    .filter((x) => x.area_privativa && x.tipo_preco && x.peso && x.tabela && tabelas[x.tabela] && precoM2PorTipo[x.tipo_preco])
    .map((x) => ({ id: x.id, numero: x.numero, area: Number(x.area_privativa), tipo: x.tipo_preco!, peso: Number(x.peso), tabela: x.tabela!, status: x.status, versao: x.versao, andar: x.andar }));
  if (!unidades.length) return { erro: 'Nenhuma unidade com preço configurado (tipo, peso e tabela).' };

  const marca = cfgMarca.data as { nome_empreendimento: string; logo_url: string | null; cor_destaque: string | null } | null;
  const nome = marca?.nome_empreendimento || 'Empreendimento';
  const cfg: ConfigEmpreendimento = {
    nome,
    mesTabela: comercial.mes_tabela.slice(0, 7),
    mesEntrega: comercial.mes_entrega.slice(0, 7),
    taxaVP: Number(comercial.taxa_vp),
    precoM2PorTipo,
    tabelas,
    unidades,
    comissao: { percentual: Number(comercial.comissao_pct), parteDoSinal: Number(comercial.parte_sinal) },
    limiteVariacaoCaptacao: Number(comercial.limite_captacao),
  };
  return { cfg, comercial, unidades, nome, logoUrl: marca?.logo_url ?? null, corDestaque: marca?.cor_destaque ?? '#94874A' };
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
  series: Omit<Serie, 'id'>[]; resumo: Resumo; observacoes: string | null; comissao_pct: number | null; parte_sinal: number | null;
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
  PERMUTA_SEM_OBSERVACAO: 'Descreva a permuta nas observações da proposta antes de enviar.',
};
export const traduzirErro = (msg: string) => ERROS[Object.keys(ERROS).find((k) => msg.includes(k)) ?? ''] ?? msg;
