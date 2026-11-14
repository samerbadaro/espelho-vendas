// Tabela de vendas: arquivo base (Excel) para baixar e carregar, e PDF da tabela.
import { logoPng } from './carta';
import { fmtMes, somarMeses, type SerieTabela } from './motor';

export interface LinhaUnidade {
  unidade_id: string; numero: string; andar: number | null; tipologia: string | null; area: number | null;
  status: string; preco: number | null; captacao: number | null;
}
export interface LinhaArquivo { numero: string; preco: number; captacao: number; area?: number; tipologia?: string }
export interface Leitura { linhas: LinhaArquivo[]; erros: string[]; ignoradas: number }

const CABECALHO = ['Unidade', 'Andar', 'Tipologia', 'Área privativa (m²)', 'Preço (R$)', 'Captação', 'Status no espelho (não alterar)'];
const STATUS: Record<string, string> = {
  disponivel: 'Disponível', reservada: 'Reservada', proposta: 'Proposta recebida', contrato: 'Contrato', vendida: 'Vendida', bloqueada: 'Bloqueada', permutante: 'Permutante',
};

/** Arquivo base: uma linha por unidade, já com os valores da tabela escolhida. */
export async function baixarArquivoBase(nomeArquivo: string, linhas: LinhaUnidade[], captacoes: { numero: number; nome: string }[]) {
  const { default: escrever } = await import('write-excel-file/browser');
  const negrito = (v: string) => ({ value: v, fontWeight: 'bold' as const, backgroundColor: '#EEEAE0' });
  const dados = [
    CABECALHO.map(negrito),
    ...linhas.map((l) => [
      { value: l.numero, type: String },
      l.andar ?? null,
      l.tipologia ?? null,
      l.area != null ? { value: l.area, format: '#,##0.00' } : null,
      l.preco != null ? { value: l.preco, format: '#,##0.00' } : null,
      l.captacao ?? null,
      { value: STATUS[l.status] ?? l.status, color: '#888888' },
    ]),
  ];
  const instrucoes = [
    [negrito('Como preencher')],
    ['1. Na aba "Unidades", preencha o preço (em reais) e a captação de cada unidade. Área e tipologia são opcionais: se vierem preenchidas, atualizam o cadastro da unidade.'],
    ['2. Não mude a coluna "Unidade": ela identifica a unidade no espelho. Linhas sem preço são ignoradas.'],
    ['3. Salve e use "Carregar arquivo" na tabela em rascunho. Antes de gravar, o sistema mostra o que vai mudar.'],
    [''],
    [negrito('Captações desta tabela')],
    ...captacoes.map((c) => [`${c.numero} = ${c.nome}`]),
  ];
  await escrever([
    { sheet: 'Unidades', data: dados as never, columns: [{ width: 11 }, { width: 8 }, { width: 16 }, { width: 18 }, { width: 16 }, { width: 11 }, { width: 26 }], stickyRowsCount: 1 },
    { sheet: 'Instruções', data: instrucoes as never, columns: [{ width: 120 }] },
  ] as never).toFile(nomeArquivo);
}

const normalizar = (s: unknown) => String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();

/** Número no formato do Excel ou digitado em pt-BR ("R$ 1.234,56"). */
function numero(v: unknown): number | null {
  if (v == null || v === '') return null;
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  let s = String(v).replace(/[R$\s]/g, '');
  if (/,\d{1,2}$/.test(s) || (s.includes(',') && s.includes('.'))) s = s.replace(/\./g, '').replace(',', '.');
  else s = s.replace(',', '.');
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

export async function lerArquivo(arquivo: File, unidadesConhecidas: Set<string>, captacoesValidas: Set<number>): Promise<Leitura> {
  const { readSheet } = await import('read-excel-file/browser');
  let linhas: unknown[][];
  try { linhas = (await readSheet(arquivo, 'Unidades')) as unknown[][]; }
  catch { linhas = (await readSheet(arquivo)) as unknown[][]; }
  const iCab = linhas.findIndex((l) => l.some((c) => normalizar(c) === 'unidade'));
  if (iCab < 0) return { linhas: [], erros: ['Não achei a coluna "Unidade". Use o arquivo base baixado do sistema.'], ignoradas: 0 };
  const cab = linhas[iCab].map(normalizar);
  const col = (inicio: string) => cab.findIndex((c) => c.startsWith(inicio));
  const cU = col('unidade'), cP = col('preco'), cC = col('captac'), cA = col('area'), cT = col('tipolog');
  if (cP < 0 || cC < 0) return { linhas: [], erros: ['O arquivo precisa das colunas "Preço (R$)" e "Captação".'], ignoradas: 0 };

  const erros: string[] = [];
  const saida: LinhaArquivo[] = [];
  const vistos = new Set<string>();
  let ignoradas = 0;
  linhas.slice(iCab + 1).forEach((l, i) => {
    const n = String(l[cU] ?? '').trim();
    const linha = iCab + i + 2;
    if (!n) return;
    const preco = numero(l[cP]);
    if (preco == null) { ignoradas++; return; }
    const cap = numero(l[cC]);
    const area = cA >= 0 ? numero(l[cA]) : null;
    const tip = cT >= 0 && l[cT] != null ? String(l[cT]).trim() : '';
    if (!unidadesConhecidas.has(n)) erros.push(`Linha ${linha}: unidade ${n} não existe no espelho`);
    else if (vistos.has(n)) erros.push(`Linha ${linha}: unidade ${n} repetida`);
    else if (preco <= 0) erros.push(`Linha ${linha}: preço da unidade ${n} inválido`);
    else if (cap == null || !captacoesValidas.has(cap)) erros.push(`Linha ${linha}: captação ${l[cC] ?? '(vazia)'} da unidade ${n} não está cadastrada`);
    else if (area != null && area <= 0) erros.push(`Linha ${linha}: área da unidade ${n} inválida`);
    else saida.push({ numero: n, preco: Math.round(preco * 100) / 100, captacao: cap, ...(area != null ? { area } : {}), ...(tip ? { tipologia: tip } : {}) });
    vistos.add(n);
  });
  return { linhas: saida, erros, ignoradas };
}

// ---------------------------------------------------------------------
// PDF
// ---------------------------------------------------------------------
export interface DadosPdfTabela {
  empreendimento: string; tabela: string; vigencia: string; mesVenda: string; mesEntrega: string;
  logoUrl?: string | null; corDestaque?: string;
  captacoes: { numero: number; nome: string; series: SerieTabela[] }[];
  unidades: { numero: string; andar: number | null; tipologia: string | null; area: number | null; preco: number; captacao: number; status: string }[];
  somenteDisponiveis?: boolean;
}

const hex = (h: string): [number, number, number] => { const n = parseInt(h.replace('#', ''), 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; };
const pctTxt = (v: number) => `${(Math.round(v * 10000) / 100).toLocaleString('pt-BR', { maximumFractionDigits: 2 })}%`;
const num = (v: number) => v.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

export async function gerarPdfTabela(d: DadosPdfTabela) {
  const [{ jsPDF }, { default: autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
  const doc = new jsPDF({ unit: 'mm', format: 'a4', orientation: 'landscape' });
  const L = doc.internal.pageSize.getWidth(), A = doc.internal.pageSize.getHeight(), m = 12;
  const destaque = hex(d.corDestaque || '#94874A');
  const cinza: [number, number, number] = [115, 115, 108];
  const logo = d.logoUrl ? await logoPng(d.logoUrl) : null;

  const cabecalho = () => {
    let x = m;
    if (logo) { const h = 11, w = Math.min(40, (logo.w / logo.h) * h); doc.addImage(logo.dados, 'PNG', m, 8, w, h); x = m + w + 5; }
    doc.setFont('helvetica', 'bold'); doc.setFontSize(14); doc.setTextColor(20);
    doc.text(`Tabela de vendas · ${d.empreendimento}`, x, 13);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(...cinza);
    doc.text(`${d.tabela} · ${d.vigencia} · parcelas para vendas em ${fmtMes(d.mesVenda)} · entrega ${fmtMes(d.mesEntrega)}`, x, 18);
    doc.setDrawColor(...destaque); doc.setLineWidth(0.4); doc.line(m, 22, L - m, 22);
  };

  const unidades = d.unidades.filter((u) => !d.somenteDisponiveis || u.status === 'disponivel');
  let primeira = true;
  for (const cap of d.captacoes) {
    const us = unidades.filter((u) => u.captacao === cap.numero).sort((a, b) => (a.andar ?? 0) - (b.andar ?? 0) || a.numero.localeCompare(b.numero, 'pt-BR', { numeric: true }));
    if (!us.length) continue;
    if (!primeira) doc.addPage();
    primeira = false;
    cabecalho();
    doc.setFont('helvetica', 'bold'); doc.setFontSize(10.5); doc.setTextColor(20);
    doc.text(cap.nome, m, 29);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8); doc.setTextColor(...cinza);
    const resumo = cap.series.map((s) => {
      const ini = s.inicio.base === 'venda' ? somarMeses(d.mesVenda, s.inicio.meses) : somarMeses(d.mesEntrega, s.inicio.meses);
      return `${s.rotulo} ${pctTxt(s.percentual)}${s.qtd > 1 ? ` (${s.qtd}×, a partir de ${fmtMes(ini)})` : ` (${fmtMes(ini)})`}`;
    }).join('  ·  ');
    doc.text(doc.splitTextToSize(resumo, L - 2 * m) as string[], m, 34);

    autoTable(doc, {
      startY: 40, margin: { left: m, right: m, top: 26 }, theme: 'plain',
      head: [['Unidade', 'Andar', 'Tipologia', 'Área (m2)', 'Preço', 'R$ por m2', ...cap.series.map((s) => `${s.rotulo}${s.qtd > 1 ? ` ${s.qtd}×` : ''}`)]],
      body: us.map((u) => [
        u.numero, u.andar != null ? `${u.andar}º` : '', u.tipologia ?? '', u.area ? num(u.area) : '', num(u.preco),
        u.area ? num(u.preco / u.area) : '', ...cap.series.map((s) => num((s.percentual * u.preco) / s.qtd)),
      ]),
      styles: { font: 'helvetica', fontSize: 7.6, cellPadding: { top: 1.4, bottom: 1.4, left: 1.2, right: 1.2 }, textColor: 25, halign: 'right' },
      headStyles: { fontSize: 7, textColor: cinza, fontStyle: 'bold', halign: 'right' },
      columnStyles: { 0: { halign: 'left', fontStyle: 'bold' }, 1: { halign: 'left' }, 2: { halign: 'left' } },
      didParseCell: (h) => { if (h.section === 'head' && h.column.index <= 2) h.cell.styles.halign = 'left'; },
      didDrawCell: (h) => {
        doc.setDrawColor(226, 226, 220); doc.setLineWidth(0.15);
        doc.line(h.cell.x, h.cell.y + h.cell.height, h.cell.x + h.cell.width, h.cell.y + h.cell.height);
      },
      willDrawPage: (h) => { if (h.pageNumber > 1) cabecalho(); },
    });
  }
  if (primeira) { cabecalho(); doc.setFontSize(10); doc.setTextColor(20); doc.text('Nenhuma unidade para listar.', m, 32); }

  const total = doc.getNumberOfPages();
  for (let i = 1; i <= total; i++) {
    doc.setPage(i);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(7); doc.setTextColor(...cinza);
    doc.text(
      'Valores de cada parcela em R$. A quantidade de parcelas mensais e semestrais acompanha o mês da venda: quanto mais perto da entrega, menos parcelas. Tabela sujeita a alteração sem aviso prévio; reajustes conforme as condições gerais da carta proposta.',
      m, A - 7, { maxWidth: L - 2 * m - 20 });
    doc.text(`${i}/${total}`, L - m, A - 7, { align: 'right' });
  }
  doc.save(`Tabela de vendas - ${d.tabela.replace(/[\\/:*?"<>|]/g, '-')}.pdf`);
}

