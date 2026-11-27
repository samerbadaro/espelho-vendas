// Tabela de vendas em PDF: uma seção por tabela, uma linha por unidade, com o valor de cada parcela.
import type { RowInput } from 'jspdf-autotable';
import { carregarContexto } from './dadosProposta';
import { fmtMes, precoUnidade, rotuloPeriodicidade, somarMeses } from './motor';

const real = (v: number) => v.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const pct = (v: number) => `${(v * 100).toLocaleString('pt-BR', { maximumFractionDigits: 2 })}%`;
const hex = (c: string) => { const m = c.replace('#', '').match(/.{2}/g) ?? ['94', '87', '4A']; return m.map((x) => parseInt(x, 16)) as [number, number, number]; };

export async function baixarTabelaVendas(opcoes: { soDisponiveis: boolean }) {
  const ctx = await carregarContexto();
  if ('erro' in ctx) throw new Error(ctx.erro);
  const [{ jsPDF }, { default: autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
  const doc = new jsPDF({ orientation: 'landscape', unit: 'mm', format: 'a4' });
  const cor = hex(ctx.corDestaque);
  const L = doc.internal.pageSize.getWidth();
  const { cfg } = ctx;

  doc.setFont('helvetica', 'bold'); doc.setFontSize(15);
  doc.text(`Tabela de vendas — ${ctx.nome}`, 12, 15);
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(90);
  doc.text(`Mês da tabela: ${fmtMes(cfg.mesTabela)}  ·  Entrega: ${fmtMes(cfg.mesEntrega)}  ·  ${opcoes.soDisponiveis ? 'Unidades disponíveis' : 'Todas as unidades'}  ·  Gerada em ${new Date().toLocaleDateString('pt-BR')}`, 12, 21);
  doc.setTextColor(0);

  let y = 27;
  const nomes = Object.keys(cfg.tabelas).sort();
  for (const t of nomes) {
    const us = ctx.unidades.filter((u) => u.tabela === t && (!opcoes.soDisponiveis || u.status === 'disponivel'))
      .sort((a, b) => a.numero.localeCompare(b.numero, 'pt-BR', { numeric: true }));
    if (!us.length) continue;
    const series = cfg.tabelas[t];
    const mesDe = (s: (typeof series)[number]) => somarMeses(s.inicio.base === 'venda' ? cfg.mesTabela : cfg.mesEntrega, s.inicio.meses);
    const head: RowInput[] = [[
      'Unidade', 'Andar', 'Área (m2)', 'Preço total (R$)',
      ...series.map((s) => `${s.qtd}× ${s.rotulo || rotuloPeriodicidade(s.periodicidade)}\n${pct(s.percentual)} · ${s.qtd > 1 ? 'a partir de ' : ''}${fmtMes(mesDe(s))}`),
    ]];
    const body: RowInput[] = us.map((u) => {
      const preco = precoUnidade(cfg, u);
      return [u.numero, u.andar != null ? `${u.andar}º` : '-', real(u.area), real(preco), ...series.map((s) => real((s.percentual * preco) / s.qtd))];
    });
    if (y > 170) { doc.addPage(); y = 15; }
    doc.setFont('helvetica', 'bold'); doc.setFontSize(11); doc.text(`${t} — ${us.length} unidade${us.length > 1 ? 's' : ''}`, 12, y);
    autoTable(doc, {
      startY: y + 2, head, body, theme: 'grid', margin: { left: 12, right: 12 },
      styles: { font: 'helvetica', fontSize: 7.5, cellPadding: 1.4, halign: 'right', lineColor: [210, 210, 210], lineWidth: 0.1 },
      headStyles: { fillColor: cor, textColor: 255, fontStyle: 'bold', halign: 'center', valign: 'middle', fontSize: 7 },
      columnStyles: { 0: { halign: 'center', fontStyle: 'bold' }, 1: { halign: 'center' } },
      alternateRowStyles: { fillColor: [247, 246, 242] },
    });
    y = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 9;
  }
  const n = doc.getNumberOfPages();
  for (let i = 1; i <= n; i++) {
    doc.setPage(i); doc.setFontSize(7.5); doc.setTextColor(110);
    doc.text('Valor de cada parcela, em R$. Valores sujeitos a alteração sem aviso prévio e a reajuste conforme o contrato.', 12, doc.internal.pageSize.getHeight() - 7);
    doc.text(`${i}/${n}`, L - 12, doc.internal.pageSize.getHeight() - 7, { align: 'right' });
  }
  doc.save(`Tabela de vendas - ${ctx.nome.split(/\s+[–—-]\s+/)[0]} - ${fmtMes(cfg.mesTabela).replace('/', '-')}.pdf`);
}
