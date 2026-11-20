// Marcadores dos modelos de contrato em Word: dados disponíveis, preenchimento e conferência.
// No Word, escreva {comprador.nome}, {preco.completo}…; listas usam {#series} … {/series}
// e trechos condicionais {#tem_conjuge} … {/tem_conjuge}.
import { formatarCNPJ, formatarCPF, formatarTelefone, soDigitos } from '../util';
import { fmtNum } from '../proposta/motor';
import { CAMPOS_EMPREENDIMENTO, DADOS_EXEMPLO, type Areas } from './campos';
import { calcularPagamento, data, enderecoTexto, MESES, nomesCompradores, real, up, type ContextoContrato, type Endereco } from './gerador';
import type { Pessoa } from './leitura';

type Dados = Record<string, unknown>;

function aninhar(plano: Record<string, string>): Dados {
  const out: Dados = {};
  for (const [k, v] of Object.entries(plano)) {
    const partes = k.split('.');
    let o = out;
    partes.slice(0, -1).forEach((p) => { o = (o[p] ??= {}) as Dados; });
    o[partes[partes.length - 1]] = v;
  }
  return out;
}

const pessoa = (p?: Pessoa | null) => {
  const x = p ?? {};
  const orgao = [x.rg_orgao, x.rg_uf].filter(Boolean).join('/');
  return {
    nome: up(x.nome), nacionalidade: up(x.nacionalidade), naturalidade: up(x.naturalidade), profissao: up(x.profissao),
    estado_civil: up(x.estado_civil), regime_bens: up(x.regime_bens) || '-', cpf: formatarCPF(x.cpf), rg: up(x.rg),
    rg_orgao: up(x.rg_orgao), rg_uf: up(x.rg_uf), rg_completo: `${up(x.rg)}${orgao ? ` ${up(orgao)}` : ''}`,
    nascimento: data(x.nascimento), telefone: x.telefone ? formatarTelefone(x.telefone) : '', email: (x.email ?? '').toLowerCase(),
    endereco: up(enderecoTexto(x.endereco as Endereco)),
  };
};

/** Monta o objeto com todos os marcadores a partir do contexto do contrato. */
export function dadosParaModelo(ctx: ContextoContrato): Dados {
  const a: Areas = ctx.areas ?? {};
  const m4 = (v: unknown) => (v == null || v === '' ? '-' : fmtNum(Number(v), 4));
  const g = calcularPagamento(ctx.series);
  const pj = ctx.tipoPessoa === 'pj';
  const temConj = !pj && !!ctx.conjuge?.nome;
  const assin = nomesCompradores(ctx).map(([nome, papel]) => ({ nome, papel }));
  const d = ctx.data;
  const dataExt = `${Number(d.slice(8, 10))} de ${MESES[Number(d.slice(5, 7)) - 1]} de ${d.slice(0, 4)}`;
  const com = ctx.comissao.filter((c) => c.nome || c.valor);
  const doc = (x: string) => { const s = soDigitos(x ?? ''); return s.length === 14 ? formatarCNPJ(s) : s.length === 11 ? formatarCPF(s) : x ?? ''; };
  const emp = ctx.empresa ?? {};
  const base = aninhar(ctx.campos);
  return {
    ...base,
    eh_pf: !pj, eh_pj: pj, tem_conjuge: temConj,
    comprador: pessoa(ctx.comprador),
    conjuge: temConj ? pessoa(ctx.conjuge) : pessoa(null),
    empresa: {
      razao_social: up(emp.razao_social), cnpj: formatarCNPJ(emp.cnpj), atividade: up(emp.atividade), registro_junta: up(emp.registro_junta),
      data_abertura: data(emp.data_abertura), telefone: emp.telefone ? formatarTelefone(emp.telefone) : '', email: (emp.email ?? '').toLowerCase(), endereco: up(enderecoTexto(emp.endereco)),
    },
    unidade: {
      numero: ctx.unidade, torre: up(String(a.torre ?? '') || ctx.campos['empreendimento.torre'] || ''), pavimento: up(String(a.pavimento ?? '-')),
      vagas: up(String(a.vagas ?? '-')), area_privativa: m4(a.area_privativa), area_acessoria: m4(a.area_acessoria),
      area_privativa_total: m4(a.area_privativa_total), area_comum: m4(a.area_comum), area_total: m4(a.area_total),
      fracao_ideal: a.fracao_ideal == null || a.fracao_ideal === '' ? '-' : `${fmtNum(Number(a.fracao_ideal) * 100, 5)}%`,
      escaninho: up(String(a.escaninho || '-')), escaninho_local: up(String(a.escaninho_local ?? '')),
      escaninho_area: a.escaninho_area ? fmtNum(Number(a.escaninho_area), 2) : '-',
    },
    preco: { total: g.totalTexto, extenso: g.totalExtenso, completo: g.totalCompleto },
    series: g.tabela,
    sinal: { total: g.sinal.total, extenso: g.sinal.extenso, completo: g.sinal.completo, pct: g.sinal.pct, item_quitacao: g.sinal.itemQuitacao },
    sinal_parcelas: g.parcelasSinal,
    demais_series: g.demais.map(({ item, texto }) => ({ item, texto })),
    habite_se: { item: g.habite.item, texto: g.habite.texto },
    boletos: { item: g.itemBoletos },
    comissao: (com.length ? com : [{ nome: '-', documento: '-', valor: 0, forma: '-' }]).map((c) => ({ nome: up(c.nome), documento: doc(c.documento), valor: real(Number(c.valor || 0)), forma: c.forma || 'TED / PIX' })),
    comissao_total: real(com.reduce((t, c) => t + Number(c.valor || 0), 0)),
    compradores_assinatura: assin,
    data: { curta: data(d), extenso: dataExt },
    local_data: `${ctx.campos['empreendimento.cidade_uf'] ?? ''}, ${dataExt}.`,
    contrato: { referencia: ctx.referencia },
  };
}

// ---------- catálogo de marcadores (tela "Marcadores disponíveis") ----------
export interface Marcador { tag: string; descricao: string; grupo: string; lista?: string[] }
const P = (pref: string, grupo: string, quem: string): Marcador[] => [
  ['nome', 'Nome completo'], ['nacionalidade', 'Nacionalidade'], ['naturalidade', 'Naturalidade'], ['profissao', 'Profissão'],
  ['estado_civil', 'Estado civil'], ['regime_bens', 'Regime de bens'], ['cpf', 'CPF'], ['rg_completo', 'RG com órgão/UF'],
  ['rg', 'RG'], ['rg_orgao', 'Órgão expedidor'], ['rg_uf', 'UF do RG'], ['nascimento', 'Data de nascimento'],
  ['telefone', 'Telefone'], ['email', 'E-mail'], ['endereco', 'Endereço completo'],
].map(([k, d]) => ({ tag: `${pref}.${k}`, descricao: `${d} ${quem}`, grupo }));

export const MARCADORES: Marcador[] = [
  { tag: 'eh_pf', descricao: 'Condição: comprador pessoa física. Use {#eh_pf} … {/eh_pf}', grupo: 'Condições' },
  { tag: 'eh_pj', descricao: 'Condição: comprador pessoa jurídica. Use {#eh_pj} … {/eh_pj}', grupo: 'Condições' },
  { tag: 'tem_conjuge', descricao: 'Condição: cônjuge participa do contrato. Use {#tem_conjuge} … {/tem_conjuge}', grupo: 'Condições' },
  ...P('comprador', 'Comprador (ou representante legal, se PJ)', 'do comprador'),
  ...P('conjuge', 'Cônjuge', 'do cônjuge'),
  ...[['razao_social', 'Razão social'], ['cnpj', 'CNPJ'], ['atividade', 'Atividade econômica'], ['registro_junta', 'Registro na junta'], ['data_abertura', 'Data de abertura'], ['telefone', 'Telefone'], ['email', 'E-mail'], ['endereco', 'Endereço']]
    .map(([k, d]) => ({ tag: `empresa.${k}`, descricao: `${d} da empresa compradora`, grupo: 'Empresa compradora (PJ)' })),
  ...[['numero', 'Número da unidade'], ['torre', 'Torre'], ['pavimento', 'Pavimento'], ['vagas', 'Vagas / localização'], ['area_privativa', 'Área privativa principal'], ['area_acessoria', 'Área acessória (vagas)'], ['area_privativa_total', 'Área privativa total'], ['area_comum', 'Área comum'], ['area_total', 'Área total real'], ['fracao_ideal', 'Fração ideal (%)'], ['escaninho', 'Escaninho'], ['escaninho_local', 'Local do escaninho'], ['escaninho_area', 'Área do escaninho']]
    .map(([k, d]) => ({ tag: `unidade.${k}`, descricao: d, grupo: 'Unidade (quadro de áreas)' })),
  { tag: 'preco.total', descricao: 'Preço total (R$)', grupo: 'Preço e pagamento' },
  { tag: 'preco.extenso', descricao: 'Preço total por extenso', grupo: 'Preço e pagamento' },
  { tag: 'preco.completo', descricao: 'Preço total com extenso entre parênteses', grupo: 'Preço e pagamento' },
  { tag: 'series', descricao: 'Lista das séries (uma linha da tabela por série). Na linha da tabela: {#series}{serie} … {correcao}{/series}', grupo: 'Preço e pagamento', lista: ['serie', 'periodicidade', 'qtd', 'valor', 'total', 'pct', 'vencimento', 'correcao'] },
  { tag: 'sinal.completo', descricao: 'Total do sinal com extenso', grupo: 'Preço e pagamento' },
  { tag: 'sinal.total', descricao: 'Total do sinal (R$)', grupo: 'Preço e pagamento' },
  { tag: 'sinal.pct', descricao: 'Percentual do sinal sobre o preço', grupo: 'Preço e pagamento' },
  { tag: 'sinal_parcelas', descricao: 'Lista das parcelas do sinal, já numeradas (4.2.1, 4.2.2…): {#sinal_parcelas} … {/sinal_parcelas}', grupo: 'Preço e pagamento', lista: ['item', 'valor', 'valor_extenso', 'valor_completo', 'vencimento'] },
  { tag: 'sinal.item_quitacao', descricao: 'Número do item da quitação do sinal (ex.: 4.2.5)', grupo: 'Preço e pagamento' },
  { tag: 'demais_series', descricao: 'Lista das demais séries (mensais, intermediárias, única), numeradas a partir de 4.3; só aparece o que existe na proposta: {#demais_series}{item}. {texto}{/demais_series}', grupo: 'Preço e pagamento', lista: ['item', 'texto'] },
  { tag: 'habite_se.item', descricao: 'Número do item do habite-se (vem logo depois das demais séries)', grupo: 'Preço e pagamento' },
  { tag: 'habite_se.texto', descricao: 'Texto do habite-se (todas as parcelas de financiamento, ou "Sem efeito")', grupo: 'Preço e pagamento' },
  { tag: 'boletos.item', descricao: 'Número do item seguinte ao habite-se', grupo: 'Preço e pagamento' },
  { tag: 'comissao', descricao: 'Lista dos beneficiários da comissão: {#comissao}{nome} … {/comissao}', grupo: 'Comissão', lista: ['nome', 'documento', 'valor', 'forma'] },
  { tag: 'comissao_total', descricao: 'Total da comissão', grupo: 'Comissão' },
  { tag: 'compradores_assinatura', descricao: 'Lista de quem assina como comprador: {#compradores_assinatura}{nome} {papel}{/compradores_assinatura}', grupo: 'Assinaturas', lista: ['nome', 'papel'] },
  { tag: 'local_data', descricao: 'Cidade e data por extenso', grupo: 'Assinaturas' },
  { tag: 'data.extenso', descricao: 'Data da emissão por extenso', grupo: 'Assinaturas' },
  { tag: 'data.curta', descricao: 'Data da emissão (dd/mm/aaaa)', grupo: 'Assinaturas' },
  { tag: 'contrato.referencia', descricao: 'Pasta e proposta (para rodapé)', grupo: 'Assinaturas' },
  ...CAMPOS_EMPREENDIMENTO.map((c) => ({ tag: c.chave, descricao: c.rotulo, grupo: `Cadastro: ${c.grupo}` })),
];

/** Valores-exemplo para mostrar na tela (contrato fictício). */
export function contextoExemplo(campos: Record<string, string> = DADOS_EXEMPLO): ContextoContrato {
  return {
    campos, tipoPessoa: 'pf', empresa: null,
    comprador: { nome: 'Fulano de Tal Exemplo', nacionalidade: 'Brasileiro', naturalidade: 'Rio Verde/GO', profissao: 'Empresário', estado_civil: 'Casado', regime_bens: 'Comunhão Parcial de Bens', rg: '1234567', rg_orgao: 'SSP', rg_uf: 'GO', cpf: '52998224725', nascimento: '1987-01-28', email: 'fulano@exemplo.com', telefone: '(64) 99999-0000', endereco: { logradouro: 'Rua Exemplo', numero: '10', bairro: 'Centro', cidade: 'Rio Verde', uf: 'GO', cep: '75900000' } },
    conjuge: { nome: 'Beltrana de Tal Exemplo', nacionalidade: 'Brasileira', naturalidade: 'Goiânia/GO', profissao: 'Arquiteta', estado_civil: 'Casada', regime_bens: 'Comunhão Parcial de Bens', cpf: '11144477735', nascimento: '1989-05-10' },
    unidade: '206', areas: { torre: 'Torre Única', pavimento: '2º PAVIMENTO', area_privativa: 34.93, area_acessoria: 12, area_privativa_total: 46.93, area_comum: 17.83, area_total: 64.76, fracao_ideal: 0.0057801, vagas: 'Vaga 12 / Subsolo 1', escaninho: 'E-03', escaninho_local: 'Subsolo 1', escaninho_area: 2.5 },
    series: [{ qtd: 1, valor: 17056.55, vencimento: '2026-11-20', periodicidade: 'Sinal' }, { qtd: 3, valor: 5685.52, vencimento: '2026-12-10', periodicidade: 'Sinal' }, { qtd: 44, valor: 629.93, vencimento: '2027-03-10', periodicidade: 'Mensais' }, { qtd: 7, valor: 9442.02, vencimento: '2027-04-10', periodicidade: 'Semestrais' }, { qtd: 1, valor: 21320.69, vencimento: '2030-07-10', periodicidade: 'Unica' }, { qtd: 1, valor: 277168.89, vencimento: '2030-11-10', periodicidade: 'Financiamento' }],
    comissao: [{ nome: 'Imobiliária Exemplo', documento: '11222333000181', valor: 22386.72, forma: 'TED / PIX' }],
    data: new Date().toISOString().slice(0, 10), referencia: 'P-001 · PR-0001',
  };
}

/** Pega um valor pelo caminho com pontos, procurando também nos níveis de fora (listas). */
const parser = (tag: string) => ({
  get(scope: unknown, context: { scopeList: unknown[] }) {
    if (tag === '.') return scope;
    const caminho = tag.trim().split('.');
    const pegar = (o: unknown) => caminho.reduce<unknown>((x, k) => (x == null ? undefined : (x as Dados)[k]), o);
    let v = pegar(scope);
    for (let i = context.scopeList.length - 1; v === undefined && i >= 0; i--) v = pegar(context.scopeList[i]);
    return v;
  },
});

/** Preenche um modelo .docx com os dados. Devolve o Word pronto e os marcadores sem valor. */
export async function preencherModelo(modelo: ArrayBuffer, dados: Dados): Promise<{ docx: Blob; vazios: string[] }> {
  const [{ default: PizZip }, { default: Docxtemplater }] = await Promise.all([import('pizzip'), import('docxtemplater')]);
  const vazios = new Set<string>();
  const doc = new Docxtemplater(new PizZip(modelo), {
    paragraphLoop: true, linebreaks: true, parser,
    nullGetter: (part: { value?: string; module?: string }) => { if (!part.module && part.value) vazios.add(part.value); return ''; },
  });
  doc.render(dados);
  const docx = doc.getZip().generate({ type: 'blob', compression: 'DEFLATE', mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }) as Blob;
  return { docx, vazios: [...vazios] };
}

/** Confere um modelo enviado: erros de marcação e marcadores que não existem. */
export async function conferirModelo(modelo: ArrayBuffer): Promise<{ erros: string[]; desconhecidos: string[]; usados: number }> {
  const [{ default: PizZip }, { default: Docxtemplater }] = await Promise.all([import('pizzip'), import('docxtemplater')]);
  const erros: string[] = [];
  const usados = new Set<string>();
  const conhecidos = new Set(MARCADORES.map((m) => m.tag));
  const internos = new Set(MARCADORES.flatMap((m) => m.lista ?? []));
  let doc: InstanceType<typeof Docxtemplater>;
  try {
    doc = new Docxtemplater(new PizZip(modelo), { paragraphLoop: true, linebreaks: true, parser: (t: string) => { usados.add(t.trim()); return parser(t); } });
    doc.render(dadosParaModelo(contextoExemplo()));
  } catch (e) {
    const lista = (e as { properties?: { errors?: { properties?: { explanation?: string } }[] } }).properties?.errors;
    if (lista?.length) lista.forEach((x) => erros.push(x.properties?.explanation ?? 'Erro de marcação.'));
    else erros.push((e as Error).message || 'Não consegui ler o arquivo. Ele precisa ser um Word (.docx).');
  }
  const desconhecidos = [...usados].filter((t) => t !== '.' && !conhecidos.has(t) && !internos.has(t));
  return { erros, desconhecidos, usados: usados.size };
}
