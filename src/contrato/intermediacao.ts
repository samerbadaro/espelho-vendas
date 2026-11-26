// Dados do instrumento de intermediação: imobiliária, gestor que assina por ela e parcelas da comissão.
import { supabase } from '../dados';
import { carregarContexto } from '../proposta/dadosProposta';
import { comissao, parcelas, total, type Serie } from '../proposta/motor';
import type { DadosIntermediacao, SerieContrato } from './gerador';

export interface PropostaIntermediacao {
  id: string; series: SerieContrato[]; parte_sinal?: number | null; comissao_pct?: number | null;
  coordenacao_pct?: number | null; coordenacao_parcelas?: number | null; imobiliaria_id?: string | null; criado_por_id?: string | null;
}

/**
 * Quem assina pela imobiliária: sempre um gestor (perfil "imobiliária"), nunca o corretor.
 * Se a proposta foi feita pelo próprio gestor, é ele; senão, o gestor da imobiliária da proposta.
 */
export async function gestorDaProposta(p: { imobiliaria_id?: string | null; criado_por_id?: string | null }): Promise<{ nome: string; email: string } | null> {
  if (p.criado_por_id) {
    const { data } = await supabase.from('perfis').select('nome, email, papel').eq('user_id', p.criado_por_id).maybeSingle();
    const autor = data as { nome: string | null; email: string; papel: string } | null;
    if (autor?.papel === 'imobiliaria') return { nome: autor.nome ?? '', email: autor.email };
  }
  if (!p.imobiliaria_id) return null;
  const { data } = await supabase.from('perfis').select('nome, email').eq('imobiliaria_id', p.imobiliaria_id).eq('papel', 'imobiliaria').order('email').limit(1).maybeSingle();
  const g = data as { nome: string | null; email: string } | null;
  return g ? { nome: g.nome ?? '', email: g.email } : null;
}

export async function dadosIntermediacao(p: PropostaIntermediacao): Promise<DadosIntermediacao | null> {
  const ctx = await carregarContexto();
  if ('erro' in ctx) return null;
  const series: Serie[] = (p.series ?? []).map((s, i) => ({ id: `c${i}`, qtd: Number(s.qtd), periodicidade: s.periodicidade, vencimento: s.vencimento, valor: Number(s.valor) }));
  const ps = parcelas(ctx.cfg, series);
  const valor = total(ps);
  const c = comissao(ps, valor, Number(p.comissao_pct ?? ctx.cfg.comissao.percentual), Number(p.parte_sinal ?? ctx.cfg.comissao.parteDoSinal),
    Number(p.coordenacao_pct ?? ctx.cfg.comissao.coordenacao ?? 0), Number(p.coordenacao_parcelas ?? ctx.cfg.comissao.coordenacaoParcelas ?? 2));
  const [{ data: im }, gestor] = await Promise.all([
    p.imobiliaria_id ? supabase.from('imobiliarias').select('nome, cnpj, creci_pj').eq('id', p.imobiliaria_id).maybeSingle() : Promise.resolve({ data: null }),
    gestorDaProposta(p),
  ]);
  const i = im as { nome: string; cnpj: string | null; creci_pj: string | null } | null;
  return {
    imobiliaria: { nome: i?.nome ?? '', cnpj: i?.cnpj ?? '', creci: i?.creci_pj ?? '' },
    gestor: gestor ?? { nome: '', email: '' },
    linhas: c.linhas.filter((l) => l.comissao > 0).map((l) => ({ data: l.data, imobiliaria: l.imobiliaria, coordenacao: l.coordenacao })),
    totalNegociacao: Math.round(valor * 100) / 100,
  };
}
