// Carta proposta gerada na emissão do contrato, a partir da proposta aprovada (mesmo layout da tela de propostas).
import { supabase } from '../dados';
import { calcular, type Serie } from '../proposta/motor';
import { carregarContexto, doBanco } from '../proposta/dadosProposta';
import { gerarCarta, gerarCartaWord, type DadosPasta, type PartesCarta, type ProponenteCarta, type OpcoesCarta } from '../proposta/carta';
import { enderecoTexto } from './gerador';
import type { DadosContrato, Pessoa } from './leitura';

/** Converte os dados conferidos (leitura com IA) no formato da carta. */
export function partesDaLeitura(d: DadosContrato, comConjuge: boolean, pj: boolean): PartesCarta {
  const pessoa = (x?: Pessoa): ProponenteCarta => ({
    nome: x?.nome, cpf: x?.cpf, nascimento: x?.nascimento, nacionalidade: x?.nacionalidade,
    rg: x?.rg ? [x.rg, [x.rg_orgao, x.rg_uf].filter(Boolean).join('/')].filter(Boolean).join(' · ') : undefined,
    estado_civil: x?.estado_civil, regime_bens: x?.regime_bens, profissao: x?.profissao, telefone: x?.telefone, email: x?.email,
    endereco: enderecoTexto(x?.endereco as Parameters<typeof enderecoTexto>[0]) || undefined,
  });
  const e = d.empresa;
  return {
    empresa: pj && e ? { razao_social: e.razao_social, cnpj: e.cnpj, telefone: e.telefone, email: e.email, endereco: enderecoTexto(e.endereco as Parameters<typeof enderecoTexto>[0]) || undefined } : null,
    proponentes: [pessoa(d.comprador), ...(comConjuge && !pj && d.conjuge?.nome ? [pessoa(d.conjuge)] : []), ...(pj && d.representante2?.nome ? [pessoa(d.representante2)] : [])],
  };
}

export async function cartaDaProposta(propostaId: string, partes?: PartesCarta | null, emp: Record<string, string> = {}, o: { data?: string; formato?: 'pdf' | 'docx'; aoAssinaturas?: OpcoesCarta['aoAssinaturas'] } = {}): Promise<Blob> {
  const { data: p } = await supabase.from('propostas')
    .select('codigo, data_proposta, unidade_id, pasta_id, imobiliaria_id, criado_por, series, observacoes, comissao_pct, parte_sinal')
    .eq('id', propostaId).maybeSingle();
  if (!p) throw new Error('Proposta não encontrada.');
  const pr = p as { codigo: string; data_proposta: string; unidade_id: string; pasta_id: string | null; imobiliaria_id: string | null; criado_por: string | null;
    series: Omit<Serie, 'id'>[]; observacoes: string | null; comissao_pct: number | null; parte_sinal: number | null };
  const ctx = await carregarContexto();
  if ('erro' in ctx) throw new Error(ctx.erro);
  const unidade = ctx.unidades.find((u) => u.id === pr.unidade_id);
  if (!unidade) throw new Error('A unidade da proposta não tem preço configurado.');
  const [{ data: pasta }, { data: im }] = await Promise.all([
    pr.pasta_id
      ? supabase.from('pastas').select('codigo, comprador_nome, comprador_cpf, comprador_nascimento, comprador_telefone, comprador_email, comprador_profissao, estado_civil, conjuge_nome, conjuge_cpf, conjuge_nascimento, conjuge_telefone, conjuge_email, conjuge_profissao').eq('id', pr.pasta_id).maybeSingle()
      : Promise.resolve({ data: null }),
    pr.imobiliaria_id ? supabase.from('imobiliarias').select('nome').eq('id', pr.imobiliaria_id).maybeSingle() : Promise.resolve({ data: null }),
  ]);
  const series = doBanco(pr.series ?? []);
  const resultado = calcular(ctx.cfg, unidade, series, {
    dataMinima: pr.data_proposta,
    comissaoPercentual: pr.comissao_pct != null ? Number(pr.comissao_pct) : undefined,
    parteDoSinal: pr.parte_sinal != null ? Number(pr.parte_sinal) : undefined,
    diasVencimento: ctx.comercial.dias_vencimento, observacoes: pr.observacoes,
  });
  const blob = await (o.formato === 'docx' ? gerarCartaWord : gerarCarta)({
    codigo: pr.codigo, dataProposta: pr.data_proposta, empreendimento: ctx.nome,
    comercial: { ...ctx.comercial, vendedora: ctx.comercial.vendedora || emp['vendedora.razao_social'] || null, vendedora_cnpj: ctx.comercial.vendedora_cnpj || emp['vendedora.cnpj'] || null },
    unidade: { numero: unidade.numero, area: unidade.area, andar: unidade.andar }, pasta: (pasta as DadosPasta | null) ?? null,
    imobiliaria: (im as { nome: string } | null)?.nome ?? '', corretor: pr.criado_por ?? '',
    series, resultado, observacoes: pr.observacoes, logoUrl: ctx.logoUrl, corDestaque: ctx.corDestaque, partes, dataDocumento: o.data ?? null,
  }, { blob: true, aoAssinaturas: o.aoAssinaturas });
  if (!blob) throw new Error('Não foi possível gerar a carta proposta.');
  return blob;
}
