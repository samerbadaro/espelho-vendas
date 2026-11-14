// Carta proposta em PDF (modelo da aba C.Proposta da planilha), com os dados
// da pasta do comprador e as condições de pagamento da proposta.
import type { RowInput } from 'jspdf-autotable';
import type { Comercial } from './dadosProposta';
import { dataDaParcela, fmtData, fmtNum, fmtPct, fmtReal, PERIODICIDADES, type Resultado, type Serie } from './motor';

export interface DadosPasta {
  codigo: string; comprador_nome: string; comprador_cpf: string; comprador_nascimento: string | null;
  comprador_telefone: string | null; comprador_email: string | null; comprador_profissao: string | null;
  estado_civil: string; conjuge_nome: string | null; conjuge_cpf: string | null; conjuge_nascimento: string | null;
  conjuge_telefone: string | null; conjuge_email: string | null; conjuge_profissao: string | null;
}

export interface DadosCarta {
  codigo: string; dataProposta: string; empreendimento: string; comercial: Comercial;
  unidade: { numero: string; area: number }; pasta: DadosPasta | null;
  imobiliaria: string; corretor: string; series: Serie[]; resultado: Resultado; observacoes: string | null;
}

const ESTADO_CIVIL: Record<string, string> = {
  solteiro: 'Solteiro(a)', casado: 'Casado(a)', uniao_estavel: 'União estável', divorciado: 'Divorciado(a)', viuvo: 'Viúvo(a)',
};
const cpf = (s: string | null) => (s ? s.replace(/(\d{3})(\d{3})(\d{3})(\d{2})/, '$1.$2.$3-$4') : '');
const tel = (s: string | null) => (s ? s.replace(/(\d{2})(\d{4,5})(\d{4})/, '($1) $2-$3') : '');
const linha = '____________________';

export async function gerarCarta(d: DadosCarta) {
  const [{ jsPDF }, { default: autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
  const doc = new jsPDF({ unit: 'mm', format: 'a4' });
  const larg = doc.internal.pageSize.getWidth();
  const alt = doc.internal.pageSize.getHeight();
  const m = 14;
  const c = d.comercial;
  let y = 16;

  const titulo = (t: string) => {
    if (y > alt - 30) { doc.addPage(); y = 16; }
    doc.setFont('helvetica', 'bold'); doc.setFontSize(9.5); doc.setFillColor(29, 30, 25); doc.setTextColor(255);
    doc.rect(m, y, larg - 2 * m, 6, 'F'); doc.text(t.toUpperCase(), m + 2, y + 4.2); doc.setTextColor(0);
    y += 8;
  };
  const paragrafo = (t: string, tam = 8.5) => {
    doc.setFont('helvetica', 'normal'); doc.setFontSize(tam);
    const l = doc.splitTextToSize(t, larg - 2 * m) as string[];
    if (y + l.length * 3.6 > alt - 16) { doc.addPage(); y = 16; }
    doc.text(l, m, y + 3); y += l.length * 3.6 + 3;
  };
  const tabela = (body: (string | number)[][], opcoes: Record<string, unknown> = {}) => {
    autoTable(doc, {
      startY: y, body: body.map((r) => r.map(String)), theme: 'grid',
      styles: { font: 'helvetica', fontSize: 8.5, cellPadding: 1.6, lineColor: [210, 210, 205], lineWidth: 0.1, textColor: 20 },
      margin: { left: m, right: m }, ...opcoes,
    });
    y = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 4;
  };

  // ---------- Cabeçalho ----------
  doc.setFont('helvetica', 'bold'); doc.setFontSize(16); doc.text('CARTA PROPOSTA', m, y);
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(90);
  doc.text(`${d.codigo} · ${fmtData(d.dataProposta)}`, larg - m, y, { align: 'right' }); doc.setTextColor(0);
  y += 7;
  paragrafo(`À ${c.vendedora || linha + linha}${c.vendedora_cnpj ? `, CNPJ ${c.vendedora_cnpj}` : ''}`, 9);
  paragrafo(c.texto_abertura);

  // ---------- Proponentes ----------
  titulo('Dados do(s) proponente(s)');
  const p = d.pasta;
  const pessoa = (nome: string | null, doc_: string | null, nasc: string | null, email: string | null, fone: string | null, prof: string | null, civil?: string) => [
    ['Proponente', nome || linha, 'CPF', cpf(doc_) || linha],
    ['Nascimento', nasc ? fmtData(nasc) : linha, 'Estado civil', civil ?? linha],
    ['RG / órgão emissor', linha, 'Nacionalidade', linha],
    ['E-mail', email || linha, 'Celular', tel(fone) || linha],
    ['Profissão', prof || linha, 'Regime de bens', linha],
    ['Endereço', linha + linha, 'CEP', linha],
  ];
  const rotulos = { 0: { fontStyle: 'bold' as const, cellWidth: 32, fillColor: [244, 244, 240] }, 2: { fontStyle: 'bold' as const, cellWidth: 30, fillColor: [244, 244, 240] } };
  tabela(pessoa(p?.comprador_nome ?? null, p?.comprador_cpf ?? null, p?.comprador_nascimento ?? null, p?.comprador_email ?? null,
    p?.comprador_telefone ?? null, p?.comprador_profissao ?? null, p ? ESTADO_CIVIL[p.estado_civil] : undefined), { columnStyles: rotulos });
  if (p?.conjuge_nome)
    tabela(pessoa(p.conjuge_nome, p.conjuge_cpf, p.conjuge_nascimento, p.conjuge_email, p.conjuge_telefone, p.conjuge_profissao, ESTADO_CIVIL[p.estado_civil]),
      { columnStyles: rotulos });

  // ---------- Imóvel ----------
  titulo('Imóvel');
  tabela([
    ['Empreendimento', d.empreendimento, 'Unidade', d.unidade.numero],
    ['Área privativa', `${fmtNum(d.unidade.area)} m2`, 'Preço proposto', fmtReal(d.resultado.proposta.total)],
  ], { columnStyles: rotulos });

  // ---------- Pagamento ----------
  titulo('Preço e forma de pagamento');
  const rot = (s: Serie) => PERIODICIDADES.find((x) => x.valor === s.periodicidade)?.rotulo ?? s.periodicidade;
  const fin = d.series.filter((s) => s.periodicidade === 'Financiamento');
  const direto = d.series.filter((s) => s.periodicidade !== 'Financiamento');
  const corpo = (l: Serie[]) => l.map((s) => [
    String(s.qtd), rot(s), fmtData(s.vencimento), s.qtd > 1 ? fmtData(dataDaParcela(s, s.qtd - 1)) : '—',
    fmtNum(s.valor), fmtNum(s.valor * s.qtd),
    s.periodicidade === 'Sinal' ? 'Fixas e irreajustáveis' : 'Reajustáveis',
    s.periodicidade === 'Sinal' ? c.forma_sinal : s.periodicidade === 'Financiamento' ? 'Financiamento bancário' : c.forma_parcelas,
  ]);
  const soma = (l: Serie[]) => l.reduce((t, s) => t + s.valor * s.qtd, 0);
  autoTable(doc, {
    startY: y, theme: 'grid', margin: { left: m, right: m },
    head: [['Nº', 'Periodicidade', '1º vencimento', 'Último', 'Valor unitário', 'Total da série', 'Atualização', 'Forma']],
    body: ([
      ...corpo(direto),
      [{ content: 'Total direto com a Vendedora', colSpan: 5, styles: { fontStyle: 'bold' as const, halign: 'right' as const } }, { content: fmtNum(soma(direto)), styles: { fontStyle: 'bold' as const } }, '', ''],
      ...corpo(fin),
      ...(fin.length ? [[{ content: 'Total financiamento', colSpan: 5, styles: { fontStyle: 'bold' as const, halign: 'right' as const } }, { content: fmtNum(soma(fin)), styles: { fontStyle: 'bold' as const } }, '', '']] : []),
      [{ content: 'TOTAL DA PROPOSTA', colSpan: 5, styles: { fontStyle: 'bold' as const, halign: 'right', fillColor: [244, 244, 240] } }, { content: fmtReal(d.resultado.proposta.total), styles: { fontStyle: 'bold' as const, fillColor: [244, 244, 240] } }, { content: '', colSpan: 2, styles: { fillColor: [244, 244, 240] } }],
    ] as RowInput[]),
    styles: { font: 'helvetica', fontSize: 8, cellPadding: 1.5, lineColor: [210, 210, 205], lineWidth: 0.1, textColor: 20 },
    headStyles: { fillColor: [235, 235, 230], textColor: 20, fontStyle: 'bold' as const },
    columnStyles: { 0: { halign: 'right', cellWidth: 9 }, 4: { halign: 'right' as const }, 5: { halign: 'right' as const } },
  });
  y = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 4;

  // ---------- Intermediação ----------
  titulo('Intermediação imobiliária');
  paragrafo(`Honorários de ${fmtPct(d.resultado.comissao.devida / d.resultado.proposta.total, 2)} sobre o valor total, pagos com o sinal de negócio no ato da assinatura desta proposta.`);
  autoTable(doc, {
    startY: y, theme: 'grid', margin: { left: m, right: m },
    head: [['Vencimento', 'Parcela de sinal', 'Honorários (intermediação)', 'Vendedora']],
    body: ([
      ...d.resultado.comissao.linhas.map((l) => [fmtData(l.data), fmtNum(l.parcela), fmtNum(l.comissao), fmtNum(l.incorporador)]),
      [{ content: 'Total', styles: { fontStyle: 'bold' as const } }, fmtNum(d.resultado.comissao.linhas.reduce((t, l) => t + l.parcela, 0)),
        { content: fmtNum(d.resultado.comissao.devida - d.resultado.comissao.naoCoberta), styles: { fontStyle: 'bold' as const } },
        fmtNum(d.resultado.comissao.linhas.reduce((t, l) => t + l.incorporador, 0))],
    ] as RowInput[]),
    styles: { font: 'helvetica', fontSize: 8.5, cellPadding: 1.5, lineColor: [210, 210, 205], lineWidth: 0.1, textColor: 20 },
    headStyles: { fillColor: [235, 235, 230], textColor: 20, fontStyle: 'bold' as const },
    columnStyles: { 1: { halign: 'right' as const }, 2: { halign: 'right' as const }, 3: { halign: 'right' as const } },
  });
  y = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 4;
  tabela([['Imobiliária', d.imobiliaria || linha, 'Corretor', d.corretor || linha]], { columnStyles: rotulos });

  // ---------- Observações e condições ----------
  if (d.observacoes?.trim()) { titulo('Observações'); paragrafo(d.observacoes.trim()); }
  if (c.texto_condicoes.trim()) { titulo('Considerações gerais'); c.texto_condicoes.trim().split(/\n+/).forEach((t) => paragrafo(t)); }
  paragrafo(`Esta proposta é válida por ${c.validade_dias} dias a partir de ${fmtData(d.dataProposta)}.`);

  // ---------- Assinaturas ----------
  if (y > alt - 60) { doc.addPage(); y = 20; }
  y += 4;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9);
  doc.text(`${c.cidade_carta || linha}, ${fmtData(d.dataProposta)}`, m, y);
  y += 18;
  const assinaturas = [
    [p?.comprador_nome || 'Proponente', ...(p?.conjuge_nome ? [p.conjuge_nome] : [])],
    [d.corretor ? `Corretor: ${d.corretor}` : 'Corretor', d.imobiliaria ? `Imobiliária: ${d.imobiliaria}` : 'Imobiliária'],
    [c.vendedora || 'Vendedora'],
  ];
  const w = (larg - 2 * m - 10) / 2;
  for (const par of assinaturas) {
    if (y > alt - 20) { doc.addPage(); y = 30; }
    par.forEach((nome, i) => {
      const x = m + i * (w + 10);
      doc.line(x, y, x + w, y);
      doc.setFontSize(8); doc.text(String(nome), x + w / 2, y + 4, { align: 'center', maxWidth: w });
    });
    y += 20;
  }

  // rodapé
  const n = doc.getNumberOfPages();
  for (let i = 1; i <= n; i++) {
    doc.setPage(i); doc.setFontSize(7.5); doc.setTextColor(130);
    doc.text(`${d.empreendimento} · ${d.codigo} · unidade ${d.unidade.numero} · página ${i} de ${n}`, larg - m, alt - 8, { align: 'right' });
    doc.setTextColor(0);
  }
  doc.save(`carta-proposta-${d.codigo}-unidade-${d.unidade.numero}.pdf`);
}
