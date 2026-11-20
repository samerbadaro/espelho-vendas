// Gera o Quadro Resumo e as Normas Contratuais em PDF a partir dos modelos (marcação simples)
// e dos dados conferidos: partes (leitura com IA), unidade (quadro de áreas), proposta aprovada
// (fluxo de pagamento) e cadastro do empreendimento.
import type { jsPDF as JsPDF } from 'jspdf';
import type { RowInput, UserOptions } from 'jspdf-autotable';
import { formatarCNPJ, formatarCPF, soDigitos } from '../util';
import { dataDaParcela, fmtData, fmtNum, fmtReal, type Periodicidade } from '../proposta/motor';
import { extensoReais, qtdExtenso } from './extenso';
import type { Areas } from './campos';
import type { Pessoa } from './leitura';

export interface Endereco { logradouro?: string; numero?: string; complemento?: string; bairro?: string; cidade?: string; uf?: string; cep?: string }
export interface Empresa { razao_social?: string; cnpj?: string; atividade?: string; registro_junta?: string; data_abertura?: string; telefone?: string; email?: string; endereco?: Endereco }
export interface Comissao { nome: string; documento: string; valor: number; forma: string }
export interface SerieContrato { periodicidade: Periodicidade; qtd: number; valor: number; vencimento: string }
export interface ContextoContrato {
  campos: Record<string, string>;
  tipoPessoa: 'pf' | 'pj';
  empresa?: Empresa | null;
  comprador: Pessoa;
  conjuge?: Pessoa | null;
  unidade: string;
  areas: Areas | null;
  series: SerieContrato[];
  comissao: Comissao[];
  data: string;        // AAAA-MM-DD
  referencia: string;  // aparece no rodapé
}
export type TipoDocumento = 'quadro_resumo' | 'normas';
export const NOME_DOCUMENTO: Record<TipoDocumento, string> = { quadro_resumo: 'Quadro Resumo', normas: 'Normas Contratuais' };

// ---------- formatação ----------
const MESES = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
const up = (s?: string | null) => (s ?? '').toLocaleUpperCase('pt-BR');
const data = (s?: string | null) => (!s ? '' : /^\d{4}-\d{2}-\d{2}/.test(s) ? fmtData(s.slice(0, 10)) : s);
const real = (v: number) => fmtReal(v).replace(/ /g, ' ');
const valorExt = (v: number) => `${real(v)} (${extensoReais(v)})`;
const cep = (s?: string) => { const d = soDigitos(s ?? ''); return d.length === 8 ? `${d.slice(0, 5)}-${d.slice(5)}` : (s ?? ''); };
export function enderecoTexto(e?: Endereco | null) {
  if (!e) return '';
  const p = [e.logradouro, e.numero ? `nº ${e.numero}` : '', e.complemento, e.bairro].filter(Boolean).join(', ');
  const cid = [e.cidade, e.uf].filter(Boolean).join(' – ');
  return [p, cid, e.cep ? `CEP ${cep(e.cep)}` : ''].filter(Boolean).join(', ');
}
const ROMANOS = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII', 'XIII', 'XIV', 'XV', 'XVI', 'XVII', 'XVIII', 'XIX', 'XX'];
const ROTULO_PER: Record<string, string> = { Unica: 'ÚNICA', Financiamento: 'FINANCIAMENTO' };

// ---------- motor de layout ----------
const A4 = { w: 210, h: 297 }, M = 20, LARG = A4.w - 2 * M, TOPO = 20, BASE = A4.h - 18;
type AutoTable = (doc: JsPDF, o: UserOptions) => void;

class Escritor {
  y = TOPO;
  faltando = new Set<string>();
  constructor(public doc: JsPDF, public tabela: AutoTable, public ctx: ContextoContrato) {
    doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5); doc.setTextColor(20);
  }
  garantir(h: number) { if (this.y + h > BASE) { this.doc.addPage(); this.y = TOPO; } }
  campo(t: string) {
    return t.replace(/\{\{([\w.]+)\}\}/g, (_, k: string) => {
      const v = this.ctx.campos[k];
      if (v == null || v === '') { this.faltando.add(k); return `[${k}]`; }
      return v;
    });
  }
  /** Parágrafo justificado com quebra de página. */
  para(texto: string, o: { negrito?: boolean; centro?: boolean; recuo?: number; tam?: number; italico?: boolean; antes?: number; depois?: number } = {}) {
    const { doc } = this;
    const tam = o.tam ?? 9.5, lh = tam * 0.46, recuo = o.recuo ?? 0, larg = LARG - recuo, x = M + recuo;
    doc.setFont('helvetica', o.negrito ? (o.italico ? 'bolditalic' : 'bold') : o.italico ? 'italic' : 'normal');
    doc.setFontSize(tam);
    this.y += o.antes ?? 0;
    for (const bloco of this.campo(texto).split('\n')) {
      const linhas: string[] = doc.splitTextToSize(bloco, larg);
      linhas.forEach((l, i) => {
        this.garantir(lh);
        if (o.centro) doc.text(l, A4.w / 2, this.y, { align: 'center' });
        else if (i < linhas.length - 1) this.justificar(l, x, larg);
        else doc.text(l, x, this.y);
        this.y += lh;
      });
    }
    this.y += o.depois ?? 2.2;
    doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5);
  }
  private justificar(linha: string, x: number, larg: number) {
    const { doc } = this;
    const palavras = linha.trim().split(/\s+/);
    if (palavras.length < 2) { doc.text(linha, x, this.y); return; }
    const total = palavras.reduce((s, p) => s + doc.getTextWidth(p), 0);
    const esp = (larg - total) / (palavras.length - 1);
    if (esp > 4) { doc.text(linha, x, this.y); return; }
    let cx = x;
    for (const p of palavras) { doc.text(p, cx, this.y); cx += doc.getTextWidth(p) + esp; }
  }
  tabelaDados(linhas: [string, string, string?, string?][]) {
    const body: RowInput[] = linhas.map(([a, b, c, d]) => c === undefined
      ? [{ content: a, styles: { fontStyle: 'bold', fillColor: [242, 242, 242] } }, { content: b, colSpan: 3 }]
      : [{ content: a, styles: { fontStyle: 'bold', fillColor: [242, 242, 242] } }, b, { content: c, styles: { fontStyle: 'bold', fillColor: [242, 242, 242] } }, d ?? '']);
    this.autoTabela({ body, columnStyles: { 0: { cellWidth: 40 }, 2: { cellWidth: 36 } } });
  }
  autoTabela(o: UserOptions) {
    this.garantir(12);
    this.tabela(this.doc, {
      startY: this.y, margin: { left: M, right: M, top: TOPO, bottom: A4.h - BASE }, theme: 'grid',
      styles: { font: 'helvetica', fontSize: 8.3, cellPadding: 1.3, lineColor: [160, 160, 160], lineWidth: 0.1, textColor: 20, overflow: 'linebreak' },
      headStyles: { fillColor: [230, 230, 230], textColor: 20, fontStyle: 'bold', halign: 'center' },
      ...o,
    });
    this.y = (this.doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 3.5;
  }
  assinaturas(nomes: string[][], colunas = 2) {
    const { doc } = this;
    const w = (LARG - (colunas - 1) * 10) / colunas;
    for (let i = 0; i < nomes.length; i += colunas) {
      const grupo = nomes.slice(i, i + colunas);
      const h = 14 + Math.max(...grupo.map((g) => g.length)) * 4;
      this.garantir(h);
      grupo.forEach((linhas, k) => {
        const x = M + k * (w + 10);
        doc.setDrawColor(60); doc.setLineWidth(0.2);
        doc.line(x, this.y + 10, x + w, this.y + 10);
        linhas.forEach((t, j) => {
          doc.setFont('helvetica', j === 0 ? 'bold' : 'normal'); doc.setFontSize(8.3);
          doc.text(doc.splitTextToSize(t, w)[0], x + w / 2, this.y + 14 + j * 4, { align: 'center' });
        });
      });
      this.y += h + 5;
    }
    doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5);
  }
}

// ---------- blocos ----------
function nomesCompradores(c: ContextoContrato): string[][] {
  if (c.tipoPessoa === 'pj') return [[up(c.empresa?.razao_social), `p.p. ${up(c.comprador.nome)}`]];
  return [[up(c.comprador.nome), 'COMPRADOR(A)'], ...(c.conjuge?.nome ? [[up(c.conjuge.nome), 'COMPRADOR(A)']] : [])];
}

function tabelaPessoa(e: Escritor, p: Pessoa) {
  const rg = [p.rg_orgao, p.rg_uf].filter(Boolean).join('/');
  e.tabelaDados([
    ['Nome:', up(p.nome)],
    ['Nacionalidade:', up(p.nacionalidade), 'Naturalidade:', up(p.naturalidade)],
    ['Profissão:', up(p.profissao), 'Estado civil:', up(p.estado_civil)],
    ['Regime de bens:', up(p.regime_bens) || '-', 'Data de nascimento:', data(p.nascimento)],
    ['CPF nº:', formatarCPF(p.cpf), 'Cédula de identidade nº:', `${up(p.rg)}${rg ? ` ${up(rg)}` : ''}`],
    ['Telefone(s):', p.telefone ?? '', 'E-mail:', (p.email ?? '').toLowerCase()],
    ['Domicílio e residência:', up(enderecoTexto(p.endereco as Endereco))],
  ]);
}

function blocoPartes(e: Escritor) {
  const c = e.ctx;
  if (c.tipoPessoa === 'pj') {
    const m = c.empresa ?? {};
    e.tabelaDados([
      ['Razão social:', up(m.razao_social)],
      ['CNPJ:', formatarCNPJ(m.cnpj), 'Data de abertura:', data(m.data_abertura)],
      ['Atividade econômica:', up(m.atividade)],
      ['Registro na junta comercial:', up(m.registro_junta)],
      ['Telefone(s):', m.telefone ?? '', 'E-mail:', (m.email ?? '').toLowerCase()],
      ['Endereço:', up(enderecoTexto(m.endereco))],
    ]);
    e.para('QUALIFICAÇÃO DO(S) REPRESENTANTE(S) LEGAL(IS):', { negrito: true });
    tabelaPessoa(e, c.comprador);
    return;
  }
  tabelaPessoa(e, c.comprador);
  if (c.conjuge?.nome) {
    e.para('Qualificação do cônjuge, que aqui também comparece como adquirente:', { negrito: true });
    tabelaPessoa(e, c.conjuge);
  }
}

function blocoUnidade(e: Escritor) {
  const a = e.ctx.areas ?? {};
  const m2 = (k: keyof Areas) => (a[k] == null || a[k] === '' ? '-' : fmtNum(Number(a[k]), 4));
  const fr = a.fracao_ideal == null || a.fracao_ideal === '' ? '-' : `${fmtNum(Number(a.fracao_ideal) * 100, 5)}%`;
  e.tabelaDados([
    ['Empreendimento:', e.campo('{{empreendimento.nome}}')],
    ['Localização:', e.campo('{{empreendimento.endereco}}')],
    ['Torre:', up(String(a.torre ?? '') || e.campo('{{empreendimento.torre}}')), 'Unidade:', e.ctx.unidade],
    ['Pavimento:', up(String(a.pavimento ?? '-'))],
    ['Número das vagas/localização:', up(String(a.vagas ?? '-'))],
    ['Área total privativa:', m2('area_privativa_total'), 'Vagas (área acessória):', m2('area_acessoria')],
    ['Área privativa principal:', m2('area_privativa'), 'Área comum:', m2('area_comum')],
    ['Área total real:', m2('area_total'), 'Fração ideal:', fr],
    ['Escaninho:', up(String(a.escaninho ?? '-')) + (a.escaninho_local ? ` (${up(String(a.escaninho_local))})` : ''), 'Área total do escaninho:', a.escaninho_area ? fmtNum(Number(a.escaninho_area), 2) : '-'],
  ]);
}

function blocoPagamento(e: Escritor) {
  const s = e.ctx.series.filter((x) => x.qtd > 0 && x.valor > 0);
  const total = s.reduce((t, x) => t + x.qtd * x.valor, 0);
  e.para(`4.1. O preço, certo e ajustado, para aquisição e pagamento da unidade autônoma de apartamento indicada no item “3.1” acima é de ${valorExt(total)}, que deverá ser integralmente pago ou amortizado pelo(s) COMPRADOR(ES) nas seguintes condições:`);
  e.autoTabela({
    head: [['Série', 'Periodicidade', 'Quant.', 'Valor unitário', 'Valor total', '%', '1º vencimento', 'Correção']],
    body: [
      ...s.map((x, i): RowInput => [ROMANOS[i] ?? String(i + 1), ROTULO_PER[x.periodicidade] ?? up(x.periodicidade), String(x.qtd), real(x.valor),
        real(x.qtd * x.valor), `${fmtNum((x.qtd * x.valor * 100) / total, 2)}%`, fmtData(x.vencimento), x.periodicidade === 'Sinal' ? 'Fixa' : 'Reajustável']),
      [{ content: 'Total', colSpan: 4, styles: { fontStyle: 'bold' } }, { content: real(total), styles: { fontStyle: 'bold' } }, { content: '100,00%', styles: { fontStyle: 'bold' } }, { content: '', colSpan: 2 }],
    ],
    styles: { fontSize: 8, cellPadding: 1.2, halign: 'center', lineColor: [160, 160, 160], lineWidth: 0.1, textColor: 20 },
  });

  // 4.2 sinal — cada parcela do sinal vira um subitem
  const sinal = s.filter((x) => x.periodicidade === 'Sinal');
  const totSinal = sinal.reduce((t, x) => t + x.qtd * x.valor, 0);
  e.para(`4.2. ARRAS/SINAL: Neste ato o(s) COMPRADOR(ES) se obriga(m) a pagar a importância total de ${valorExt(totSinal)}, a título de arras/sinal, valor este que representa o percentual de ${fmtNum((totSinal * 100) / (total || 1), 2)}% do valor total do preço previsto no item “4.1” acima, sendo que a primeira parcela será paga pelo(s) COMPRADOR(ES) através de TED/PIX e as demais parcelas deverão ser pagas por meio de boleto bancário, conforme subitens abaixo, tudo conforme disposto nos artigos 418 e 419 do Código Civil, cuja quitação dar-se-á somente após a compensação e efetiva liberação do crédito bancário em favor da VENDEDORA.`);
  let n = 0;
  for (const x of sinal) for (let k = 0; k < x.qtd; k++) {
    n++;
    e.para(`4.2.${n}) Parcela no valor unitário de ${valorExt(x.valor)}, com vencimento no dia ${fmtData(dataDaParcela(x, k))}.`, { recuo: 6 });
  }
  e.para(`4.2.${n + 1}) A quitação da parcela de arras/sinal se dará automaticamente com a compensação financeira e efetiva liberação do crédito bancário em favor da VENDEDORA. Em caso de não quitação no vencimento do valor acordado à título de arras/sinal, estará convalidado o inadimplemento contratual do(s) COMPRADOR(ES), ficando automaticamente rescindido o presente contrato e também rescindida a proposta de compra e venda, podendo a VENDEDORA, a partir de então, dar à unidade autônoma a destinação que melhor lhe aprouver.`, { recuo: 6 });

  // 4.3 em diante — demais séries
  let item = 3;
  const PLURAL: Record<string, [string, string]> = { Bimestrais: ['bimestrais', 'bimestres'], Trimestrais: ['trimestrais', 'trimestres'], Semestrais: ['semestrais', 'semestres'], Anuais: ['anuais', 'anos'] };
  for (const x of s.filter((v) => !['Sinal', 'Financiamento'].includes(v.periodicidade))) {
    const v = `R$ ${fmtNum(x.valor, 2)} (${extensoReais(x.valor)})`;
    const venc = fmtData(x.vencimento);
    let t: string;
    if (x.periodicidade === 'Mensais') t = `PARCELAS MENSAIS: ${qtdExtenso(x.qtd)} parcelas, mensais e sucessivas, cada qual no valor originário de ${v}, reajustáveis na forma deste contrato, vencendo a primeira em ${venc} e as demais no mesmo dia dos meses subsequentes até final quitação.`;
    else if (PLURAL[x.periodicidade]) t = `PARCELAS INTERMEDIÁRIAS: ${qtdExtenso(x.qtd)} parcelas ${PLURAL[x.periodicidade][0]}, cada qual no valor originário de ${v}, reajustáveis na forma deste contrato, com pagamentos concomitantes ao pagamento das demais parcelas, vencendo a primeira em ${venc} e as demais no mesmo dia dos ${PLURAL[x.periodicidade][1]} subsequentes até final quitação.`;
    else if (x.periodicidade === 'Permuta') t = `PARCELA EM PERMUTA: ${qtdExtenso(x.qtd)} parcela(s) no valor de ${v}, a ser(em) quitada(s) por meio de permuta, com vencimento em ${venc}, conforme instrumento próprio.`;
    else t = `PARCELA ÚNICA: ${qtdExtenso(x.qtd)} parcela única, no valor originário de ${v}, com pagamento concomitante ao pagamento das demais parcelas, reajustável na forma deste contrato, com vencimento em ${venc}.`;
    e.para(`4.${item}. ${t}`); item++;
  }
  const fin = s.find((x) => x.periodicidade === 'Financiamento');
  e.para(fin
    ? `4.${item}. PARCELA “DE HABITE-SE”: 01 (uma) parcela “de Habite-se”, no valor originário de ${valorExt(fin.valor * fin.qtd)}, reajustável na forma deste contrato, a ser paga pelo(s) COMPRADOR(ES) em ${fmtData(fin.vencimento)}.`
    : `4.${item}. PARCELA “DE HABITE-SE”: Sem efeito.`);
  e.para(`4.${item}.1. A parcela “de Habite-se” poderá ser paga com recursos próprios ou, a critério do(s) COMPRADOR(ES), por meio de financiamento bancário junto a instituição financeira idônea, sendo que o(s) COMPRADOR(ES) declara(m) estar ciente(s) de que a responsabilidade pela obtenção de eventual financiamento bancário competirá única e exclusivamente a ele(s), COMPRADOR(ES), sem qualquer responsabilidade ou participação da VENDEDORA, especialmente no que se refere à obtenção dos documentos que venham a ser exigidos pela instituição financeira. O não pagamento desta parcela “de Habite-se” na data prevista de seu vencimento, independentemente do motivo, colocará o(s) COMPRADOR(ES) em automática mora, sujeitando-o às penalidades previstas nas normas contratuais.`, { recuo: 6 });
  e.para(`4.${item}.2. O(s) COMPRADOR(ES) declara(m) ter conhecimento que a utilização de recursos do FGTS para pagamento de parte do preço somente será aceita para quitação do saldo devedor e apenas para as parcelas cujo vencimento seja posterior à emissão do habite-se do empreendimento e averbação deste junto ao Cartório de Registro de Imóveis competente, sendo rigorosamente certo que o pagamento só será considerado efetivamente realizado e o valor quitado na data em que a quantia correspondente for liberada para uso imediato pela VENDEDORA. A responsabilidade pela apresentação de todos e quaisquer documentos necessários e exigidos pela instituição financeira para liberação e saque de recursos do FGTS competirá única e exclusivamente ao(s) COMPRADOR(ES), não tendo a VENDEDORA nenhuma responsabilidade nesse sentido.`, { recuo: 6 });
  e.para(`4.${item + 1}. Todas as parcelas deverão ser pagas através de boleto bancário ou outra forma definida exclusivamente pela VENDEDORA, que será enviado ao(s) COMPRADOR(ES), ao endereço de e-mail indicado no item “1.2” supra, sendo de responsabilidade do(s) COMPRADOR(ES) a comunicação à VENDEDORA de qualquer alteração do endereço de e-mail.`);
}

function blocoComissao(e: Escritor) {
  const linhas = e.ctx.comissao.filter((c) => c.nome || c.valor);
  const total = linhas.reduce((t, c) => t + Number(c.valor || 0), 0);
  const doc = (d: string) => { const s = soDigitos(d); return s.length === 14 ? formatarCNPJ(s) : s.length === 11 ? formatarCPF(s) : d; };
  e.autoTabela({
    head: [['Nome do beneficiário', 'Valor da comissão', 'Forma de pagamento', 'CPF / CNPJ']],
    body: [
      ...(linhas.length ? linhas : [{ nome: '-', valor: 0, forma: '-', documento: '-' }]).map((c): RowInput => [up(c.nome), real(Number(c.valor || 0)), c.forma || 'TED / PIX', doc(c.documento)]),
      [{ content: 'TOTAL COMISSÃO', styles: { fontStyle: 'bold' } }, { content: real(total), styles: { fontStyle: 'bold' } }, { content: '', colSpan: 2 }],
    ],
  });
}

function blocoRubrica(e: Escritor) {
  e.para('Assinatura do(s) COMPRADOR(ES):', { negrito: true, antes: 2 });
  e.assinaturas(nomesCompradores(e.ctx));
}

function blocoLocalData(e: Escritor) {
  const d = e.ctx.data;
  e.para(`${e.campo('{{empreendimento.cidade_uf}}')}, ${Number(d.slice(8, 10))} de ${MESES[Number(d.slice(5, 7)) - 1]} de ${d.slice(0, 4)}.`);
}

function blocoAssinaturasFinais(e: Escritor) {
  e.y += 4;
  e.para('VENDEDORA', { negrito: true });
  e.assinaturas([[up(e.campo('{{vendedora.assinante}}')), 'VENDEDORA']], 1);
  e.para('COMPRADOR(ES):', { negrito: true });
  e.assinaturas(nomesCompradores(e.ctx));
  e.para('TESTEMUNHAS', { negrito: true });
  e.assinaturas([
    [`NOME: ${up(e.campo('{{testemunha1.nome}}'))}`, `CPF: ${e.campo('{{testemunha1.cpf}}')}`],
    [`NOME: ${up(e.campo('{{testemunha2.nome}}'))}`, `CPF: ${e.campo('{{testemunha2.cpf}}')}`],
  ]);
}

const BLOCOS: Record<string, (e: Escritor) => void> = {
  partes: blocoPartes, quadro_unidade: blocoUnidade, pagamento: blocoPagamento, tabela_comissao: blocoComissao,
  rubrica_compradores: blocoRubrica, local_data: blocoLocalData, assinaturas_finais: blocoAssinaturasFinais,
};

/** Gera o PDF. Devolve o arquivo e os campos do cadastro que estavam vazios. */
export async function gerarDocumento(tipo: TipoDocumento, ctx: ContextoContrato): Promise<{ pdf: Blob; faltando: string[] }> {
  const [{ jsPDF }, { default: autoTable }, modelo] = await Promise.all([
    import('jspdf'), import('jspdf-autotable'),
    tipo === 'quadro_resumo' ? import('./modelos/quadroResumo').then((m) => m.QUADRO_RESUMO) : import('./modelos/normas').then((m) => m.NORMAS),
  ]);
  const doc = new jsPDF({ unit: 'mm', format: 'a4', compress: true });
  const e = new Escritor(doc, autoTable as unknown as AutoTable, ctx);
  for (const bruto of modelo.split(/\n\s*\n/)) {
    const p = bruto.trim();
    if (!p) continue;
    if (p.startsWith('@')) { BLOCOS[p.slice(1)]?.(e); continue; }
    if (p.startsWith('== ')) { e.garantir(14); e.para(p.slice(3), { negrito: true, antes: 2.5, depois: 1.6 }); continue; }
    if (p.startsWith('= ')) { e.para(p.slice(2), { negrito: true, centro: true, tam: 11, depois: 3 }); continue; }
    if (p.startsWith('## ')) { e.para(p.slice(3), { negrito: true, depois: 1.6 }); continue; }
    if (p.startsWith('~ ')) { e.para(p.slice(2), { italico: true, tam: 8, depois: 2 }); continue; }
    if (p.startsWith('> ')) { e.para(p.slice(2), { recuo: 8 }); continue; }
    e.para(p);
  }
  // rodapé
  const n = doc.getNumberOfPages();
  for (let i = 1; i <= n; i++) {
    doc.setPage(i); doc.setFont('helvetica', 'normal'); doc.setFontSize(7.5); doc.setTextColor(120);
    doc.text(`${NOME_DOCUMENTO[tipo]} · Unidade ${ctx.unidade} · ${ctx.referencia}`, M, A4.h - 10);
    doc.text(`Página ${i} de ${n}`, A4.w - M, A4.h - 10, { align: 'right' });
  }
  return { pdf: doc.output('blob'), faltando: [...e.faltando] };
}
