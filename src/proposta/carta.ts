// Carta proposta em PDF — modelo "Carta proposta - exemplo" (imóvel em grade,
// proponentes, séries com intervalo de vencimentos, intermediação destacada
// do sinal, condições gerais e aceite da vendedora).
import type { RowInput } from 'jspdf-autotable';
import type { Comercial } from './dadosProposta';
import { dataDaParcela, fmtData, fmtNum, fmtReal, type Resultado, type Serie } from './motor';

export interface DadosPasta {
  codigo: string; comprador_nome: string; comprador_cpf: string; comprador_nascimento: string | null;
  comprador_telefone: string | null; comprador_email: string | null; comprador_profissao: string | null;
  estado_civil: string; conjuge_nome: string | null; conjuge_cpf: string | null; conjuge_nascimento: string | null;
  conjuge_telefone: string | null; conjuge_email: string | null; conjuge_profissao: string | null;
}

export interface DadosCarta {
  codigo: string; dataProposta: string; empreendimento: string; comercial: Comercial;
  unidade: { numero: string; area: number; andar: number | null }; pasta: DadosPasta | null;
  imobiliaria: string; corretor: string; series: Serie[]; resultado: Resultado; observacoes: string | null;
  logoUrl?: string | null; corDestaque?: string;
}

const ESTADO_CIVIL: Record<string, string> = {
  solteiro: 'Solteiro(a)', casado: 'Casado(a)', uniao_estavel: 'União estável', divorciado: 'Divorciado(a)', viuvo: 'Viúvo(a)',
};
const MESES = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
const cpf = (s: string | null) => (s ? s.replace(/(\d{3})(\d{3})(\d{3})(\d{2})/, '$1.$2.$3-$4') : '');
const tel = (s: string | null) => (s ? s.replace(/(\d{2})(\d{4,5})(\d{4})/, '($1) $2-$3') : '');
const branco = '________________________';
const pct = (v: number) => `${(Math.round(v * 10000) / 100).toLocaleString('pt-BR', { maximumFractionDigits: 2 })}%`;
const hex = (h: string): [number, number, number] => { const n = parseInt(h.replace('#', ''), 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; };

/** Logo (inclusive SVG) convertido em PNG para o PDF. */
async function logoPng(url: string): Promise<{ dados: string; w: number; h: number } | null> {
  try {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    await new Promise<void>((ok, erro) => { img.onload = () => ok(); img.onerror = () => erro(); img.src = url; });
    const w0 = img.naturalWidth || 400, h0 = img.naturalHeight || 200;
    const escala = 480 / w0;
    const cv = document.createElement('canvas');
    cv.width = Math.round(w0 * escala); cv.height = Math.round(h0 * escala);
    cv.getContext('2d')!.drawImage(img, 0, 0, cv.width, cv.height);
    return { dados: cv.toDataURL('image/png'), w: cv.width, h: cv.height };
  } catch { return null; }
}

export async function gerarCarta(d: DadosCarta) {
  const [{ jsPDF }, { default: autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
  const doc = new jsPDF({ unit: 'mm', format: 'a4' });
  const L = doc.internal.pageSize.getWidth();
  const A = doc.internal.pageSize.getHeight();
  const m = 16;
  const util = L - 2 * m;
  const c = d.comercial;
  const destaque = hex(d.corDestaque || '#C9A27A');
  const cinza: [number, number, number] = [120, 120, 112];
  let y = 16;

  const garantir = (h: number) => { if (y + h > A - 16) { doc.addPage(); y = 18; } };
  const fimTabela = () => (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY;

  const secao = (titulo: string, minimo = 18) => {
    garantir(minimo);
    y += 3;
    doc.setFont('helvetica', 'bold'); doc.setFontSize(11); doc.setTextColor(20);
    doc.text(titulo, m, y);
    doc.setDrawColor(...destaque); doc.setLineWidth(0.3); doc.line(m, y + 1.8, L - m, y + 1.8);
    y += 6.5;
  };

  /** Linhas de campos em 3 colunas: rótulo pequeno cinza, valor embaixo. */
  const campos = (linhas: { r: string; v: string; span?: number }[][]) => {
    const col = util / 3;
    for (const linha of linhas) {
      let x = m; let alt = 0;
      const blocos = linha.map((f) => {
        const w = col * (f.span ?? 1) - 3;
        doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5);
        const v = doc.splitTextToSize(f.v || '—', w) as string[];
        alt = Math.max(alt, 4 + v.length * 4.2);
        const b = { f, v, x };
        x += col * (f.span ?? 1);
        return b;
      });
      garantir(alt + 2);
      for (const b of blocos) {
        doc.setFont('helvetica', 'normal'); doc.setFontSize(7); doc.setTextColor(...cinza);
        doc.text(b.f.r, b.x, y);
        doc.setFontSize(9.5); doc.setTextColor(20);
        if (b.v.length === 1 && b.v[0].endsWith('m²')) {
          // a fonte do PDF não tem "²": escreve o 2 pequeno e elevado
          const base = b.v[0].slice(0, -1);
          doc.text(base, b.x, y + 4.3);
          doc.setFontSize(6); doc.text('2', b.x + doc.getStringUnitWidth(base) * 9.5 / doc.internal.scaleFactor, y + 2.9);
        } else doc.text(b.v, b.x, y + 4.3);
      }
      y += alt + 2.5;
    }
  };

  const paragrafo = (t: string, tam = 9, cor: [number, number, number] = [30, 30, 28]) => {
    doc.setFont('helvetica', 'normal'); doc.setFontSize(tam); doc.setTextColor(...cor);
    const l = doc.splitTextToSize(t, util) as string[];
    garantir(l.length * 4.2);
    doc.text(l, m, y + 3); y += l.length * 4.2 + 2;
  };

  const tabela = (head: string[], body: RowInput[], colunas: Record<number, object>) => {
    autoTable(doc, {
      startY: y, head: [head], body, theme: 'plain', margin: { left: m, right: m },
      styles: { font: 'helvetica', fontSize: 8.5, cellPadding: { top: 2, bottom: 2, left: 1.5, right: 1.5 }, textColor: 25 },
      headStyles: { fontSize: 7.5, textColor: cinza, fontStyle: 'normal' },
      columnStyles: colunas,
      didDrawCell: (h) => {
        doc.setDrawColor(222, 222, 216); doc.setLineWidth(0.2);
        doc.line(h.cell.x, h.cell.y + h.cell.height, h.cell.x + h.cell.width, h.cell.y + h.cell.height);
      },
    });
    y = fimTabela() + 4;
  };
  const totalLinha = (rotulo: string, valor: string, colunas: number, colValor: number, forte = false): RowInput => {
    const fundo: [number, number, number] = forte ? [255, 255, 255] : [244, 244, 240];
    return [
      { content: rotulo, colSpan: colValor, styles: { fontStyle: 'bold', fillColor: fundo } },
      { content: valor, styles: { fontStyle: 'bold', halign: 'right', fillColor: fundo } },
      ...(colunas - colValor - 1 > 0 ? [{ content: '', colSpan: colunas - colValor - 1, styles: { fillColor: fundo } }] : []),
    ];
  };

  // ---------- Cabeçalho ----------
  const logo = d.logoUrl ? await logoPng(d.logoUrl) : null;
  if (logo) { const h = 12; doc.addImage(logo.dados, 'PNG', m, y - 6, (logo.w / logo.h) * h, h); }
  doc.setFont('helvetica', 'bold'); doc.setFontSize(18); doc.setTextColor(20);
  doc.text('Carta proposta', L - m, y + 1, { align: 'right' });
  doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(...cinza);
  doc.text(`N.º ${d.codigo} · ${fmtData(d.dataProposta)}`, L - m, y + 6, { align: 'right' });
  y += 16;

  // abertura: "À <SPE> (CNPJ ...)." + texto
  const destinatario = `À ${c.vendedora || 'SPE ' + branco}${c.vendedora_cnpj ? ` (CNPJ ${c.vendedora_cnpj})` : ''}.`;
  doc.setFont('helvetica', 'bold'); doc.setFontSize(9); doc.setTextColor(20);
  const ld = doc.splitTextToSize(destinatario, util) as string[];
  doc.text(ld, m, y + 3);
  y += ld.length * 4.2 + 0.5;
  paragrafo(c.texto_abertura);

  // ---------- Imóvel ----------
  secao('Imóvel');
  campos([
    [{ r: 'Empreendimento', v: d.empreendimento, span: 2 }, { r: 'Unidade', v: d.unidade.numero }],
    [{ r: 'Pavimento', v: d.unidade.andar != null ? `${d.unidade.andar}º` : '—' }, { r: 'Área privativa', v: `${fmtNum(d.unidade.area)} m²` }, { r: 'Vaga', v: c.vaga ?? 'Não inclui' }],
    [{ r: 'Escaninho', v: c.escaninho ?? 'Não inclui' }, { r: 'Valor da proposta', v: fmtReal(d.resultado.proposta.total) }],
  ]);

  // ---------- Proponentes ----------
  const p = d.pasta;
  const civil = p ? ESTADO_CIVIL[p.estado_civil] ?? p.estado_civil : '';
  const proponente = (n: number, nome: string | null, doc_: string | null, nasc: string | null, prof: string | null, fone: string | null, email: string | null) => {
    secao(`Proponente ${n}`);
    campos([
      [{ r: 'Nome', v: nome || branco, span: 2 }, { r: 'CPF', v: cpf(doc_) || branco }],
      [{ r: 'RG / órgão emissor', v: branco }, { r: 'Nascimento', v: nasc ? fmtData(nasc) : branco }, { r: 'Nacionalidade', v: branco }],
      [{ r: 'Estado civil', v: civil ? `${civil} · regime ${'_'.repeat(10)}` : branco }, { r: 'Profissão', v: prof || branco }, { r: 'Celular', v: tel(fone) || branco }],
      [{ r: 'E-mail', v: email || branco }, { r: 'Endereço', v: `${'_'.repeat(38)} · CEP ${'_'.repeat(9)}`, span: 2 }],
    ]);
  };
  proponente(1, p?.comprador_nome ?? null, p?.comprador_cpf ?? null, p?.comprador_nascimento ?? null, p?.comprador_profissao ?? null, p?.comprador_telefone ?? null, p?.comprador_email ?? null);
  if (p?.conjuge_nome)
    proponente(2, p.conjuge_nome, p.conjuge_cpf, p.conjuge_nascimento, p.conjuge_profissao, p.conjuge_telefone, p.conjuge_email);

  // ---------- Preço e forma de pagamento ----------
  secao('Preço e forma de pagamento', 50);
  const ROTULO: Record<string, string> = { Sinal: 'Sinal', Mensais: 'Mensal', Semestrais: 'Semestral', Anuais: 'Anual', Unica: 'Única', Financiamento: 'Única' };
  const linhaSerie = (s: Serie): RowInput => {
    const ultimo = dataDaParcela(s, s.qtd - 1);
    const venc = s.qtd > 1 ? `${fmtData(s.vencimento)} a ${fmtData(ultimo).slice(3)}` : fmtData(s.vencimento);
    const fin = s.periodicidade === 'Financiamento';
    return [
      ROTULO[s.periodicidade] ?? s.periodicidade, String(s.qtd), venc, fmtReal(s.valor), fmtReal(s.valor * s.qtd),
      s.periodicidade === 'Sinal' ? 'Fixa' : fin ? '—' : 'INCC até o habite-se',
      s.periodicidade === 'Sinal' ? c.forma_sinal : fin ? 'Financiamento bancário' : c.forma_parcelas,
    ];
  };
  const ordenar = (l: Serie[]) => [...l].sort((a, b) => a.vencimento.localeCompare(b.vencimento));
  const direto = ordenar(d.series.filter((s) => s.periodicidade !== 'Financiamento'));
  const fin = ordenar(d.series.filter((s) => s.periodicidade === 'Financiamento'));
  const soma = (l: Serie[]) => l.reduce((t, s) => t + s.valor * s.qtd, 0);
  tabela(
    ['Série', 'Parc.', 'Vencimentos', 'Valor da parcela', 'Total da série', 'Correção', 'Pagamento'],
    [
      ...direto.map(linhaSerie),
      totalLinha('Total até as chaves', fmtReal(soma(direto)), 7, 4),
      ...fin.map(linhaSerie),
      ...(fin.length ? [totalLinha('Total pós-chaves / financiamento', fmtReal(soma(fin)), 7, 4)] : []),
      totalLinha('Total da proposta nesta data', fmtReal(d.resultado.proposta.total), 7, 4, true),
    ],
    { 1: { halign: 'right', cellWidth: 11 }, 3: { halign: 'right' }, 4: { halign: 'right' } },
  );

  // ---------- Intermediação ----------
  secao('Intermediação imobiliária', 50);
  paragrafo('Paga com o sinal de negócio e destacada do valor da proposta.', 8.5, cinza);
  const total = d.resultado.proposta.total;
  const linhasCom = d.resultado.comissao.linhas.filter((l) => l.comissao > 0);
  tabela(
    ['Intermediador', 'Função', '%', 'Valor', 'Vencimento'],
    [
      ...linhasCom.map((l): RowInput => [d.imobiliaria || branco, 'Imobiliária', total > 0 ? pct(l.comissao / total) : '—', fmtReal(l.comissao), fmtData(l.data)]),
      totalLinha('Total da intermediação', fmtReal(d.resultado.comissao.destacada), 5, 3),
    ],
    { 2: { halign: 'right' }, 3: { halign: 'right' } },
  );
  campos([[{ r: 'Imobiliária', v: d.imobiliaria || branco }, { r: 'Corretor', v: d.corretor || branco }, { r: 'Coordenação comercial', v: c.coordenacao_comercial || branco }]]);

  // ---------- Observações e condições ----------
  if (d.observacoes?.trim()) { secao('Observações'); paragrafo(d.observacoes.trim()); }
  const condicoes = c.texto_condicoes.split(/\n+/).map((t) => t.replace(/^\s*\d+\s*[-.)]\s*/, '').trim()).filter(Boolean);
  if (condicoes.length) {
    secao('Condições gerais');
    condicoes.forEach((t, i) => {
      doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(30);
      const l = doc.splitTextToSize(t, util - 5) as string[];
      garantir(l.length * 3.9 + 1.5);
      doc.text(`${i + 1}.`, m, y + 3);
      doc.text(l, m + 5, y + 3);
      y += l.length * 3.9 + 1.5;
    });
  }
  const [aa, mm, dd] = d.dataProposta.split('-').map(Number);
  y += 3;
  paragrafo(`${c.cidade_carta || branco}, ${dd} de ${MESES[mm - 1]} de ${aa}.`, 9);

  // ---------- Assinaturas ----------
  const assinatura = (x: number, w: number, nome: string, sub: string) => {
    doc.setDrawColor(60); doc.setLineWidth(0.25); doc.line(x, y, x + w, y);
    doc.setFont('helvetica', 'bold'); doc.setFontSize(9); doc.setTextColor(20); doc.text(nome, x, y + 4.5);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(7); doc.setTextColor(...cinza); doc.text(sub, x, y + 8);
  };
  const metade = (util - 12) / 2;
  garantir(30); y += 14;
  assinatura(m, metade, p?.comprador_nome || 'Proponente', `Proponente${p?.comprador_cpf ? ` · CPF ${cpf(p.comprador_cpf)}` : ''}`);
  if (p?.conjuge_nome) assinatura(m + metade + 12, metade, p.conjuge_nome, `Proponente${p.conjuge_cpf ? ` · CPF ${cpf(p.conjuge_cpf)}` : ''}`);
  y += 12;
  garantir(26); y += 12;
  assinatura(m, metade, d.corretor || 'Corretor', `Corretor${d.imobiliaria ? ` · ${d.imobiliaria}` : ''}`);
  y += 14;
  garantir(36);
  doc.setDrawColor(190); doc.setLineDashPattern([1, 1], 0); doc.line(m, y, L - m, y); doc.setLineDashPattern([], 0);
  y += 7;
  doc.setFont('helvetica', 'bold'); doc.setFontSize(10); doc.setTextColor(20); doc.text('Aceite da vendedora', m, y);
  y += 16;
  assinatura(m, metade, c.vendedora || 'Vendedora', 'Data: ____/____/______');

  // rodapé
  const n = doc.getNumberOfPages();
  for (let i = 1; i <= n; i++) {
    doc.setPage(i); doc.setFont('helvetica', 'normal'); doc.setFontSize(7); doc.setTextColor(150);
    doc.text(`${d.empreendimento} · ${d.codigo} · unidade ${d.unidade.numero} · página ${i} de ${n}`, L - m, A - 8, { align: 'right' });
  }
  doc.save(`carta-proposta-${d.codigo}-unidade-${d.unidade.numero}.pdf`);
}
