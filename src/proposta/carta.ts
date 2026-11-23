// Carta proposta em PDF — modelo "Carta proposta - exemplo" (imóvel em grade,
// proponentes, séries com intervalo de vencimentos, intermediação destacada
// do sinal, condições gerais e aceite da vendedora).
import type { RowInput } from 'jspdf-autotable';
import type { Item } from '../contrato/gerador';
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
  /** Dados conferidos (leitura com IA) — quando informados, substituem os da pasta e preenchem tudo (RG, endereço, regime…). */
  partes?: PartesCarta | null;
  /** Data do local e data (ex.: data do contrato). Sem ela, vale a data da proposta. */
  dataDocumento?: string | null;
}
export interface ProponenteCarta {
  nome?: string; cpf?: string; rg?: string; nascimento?: string; nacionalidade?: string; estado_civil?: string; regime_bens?: string;
  profissao?: string; telefone?: string; email?: string; endereco?: string; cep?: string;
}
export interface PartesCarta {
  empresa?: { razao_social?: string; cnpj?: string; telefone?: string; email?: string; endereco?: string; cep?: string } | null;
  proponentes: ProponenteCarta[];
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


// ---------------------------------------------------------------------
// Conteúdo da carta, independente do formato (PDF ou Word)
// ---------------------------------------------------------------------
type Campo = { r: string; v: string; span?: number };
type Bloco =
  | { k: 'destinatario'; t: string }
  | { k: 'texto'; t: string; tam?: number; cinza?: boolean }
  | { k: 'secao'; t: string; minimo?: number }
  | { k: 'campos'; linhas: Campo[][] }
  | { k: 'tabela'; head: string[]; body: RowInput[]; colunas: Record<number, object> }
  | { k: 'condicoes'; itens: string[] }
  | { k: 'assinaturas'; quem: { nome: string; sub: string }[]; corretor: { nome: string; sub: string }; vendedora: string };

const vazio = (v: string) => !v || v === '—' || v.includes('____');

/** Opções: `simples` tira campos em branco e as assinaturas (resumo para o cliente). */
export interface OpcoesCarta { blob?: boolean; simples?: boolean; /** recebe onde ficou cada linha de assinatura (mm, A4) */ aoAssinaturas?: (p: { pagina: number; x: number; y: number; largura: number; nomes: string[] }[]) => void }

function conteudo(d: DadosCarta, simples: boolean): Bloco[] {
  const c = d.comercial;
  const b: Bloco[] = [];
  const campos = (linhas: Campo[][]) => {
    const l = simples ? linhas.map((x) => x.filter((f) => !vazio(f.v))).filter((x) => x.length) : linhas;
    if (l.length) b.push({ k: 'campos', linhas: l });
  };

  if (!simples || c.vendedora) b.push({ k: 'destinatario', t: `À ${c.vendedora || 'SPE ' + branco}${c.vendedora_cnpj ? ` (CNPJ ${c.vendedora_cnpj})` : ''}.` });
  if (simples) b.push({ k: 'texto', t: 'Resumo da proposta para conferência. Não é o documento para assinatura.', tam: 8.5, cinza: true });
  else b.push({ k: 'texto', t: c.texto_abertura });

  // Imóvel
  b.push({ k: 'secao', t: 'Imóvel' });
  campos([
    [{ r: 'Empreendimento', v: d.empreendimento, span: 2 }, { r: 'Unidade', v: d.unidade.numero }],
    [{ r: 'Pavimento', v: d.unidade.andar != null ? `${d.unidade.andar}º` : '—' }, { r: 'Área privativa', v: `${fmtNum(d.unidade.area)} m²` }, { r: 'Vaga', v: c.vaga ?? 'Não inclui' }],
    [{ r: 'Escaninho', v: c.escaninho ?? 'Não inclui' }, { r: 'Valor da proposta', v: fmtReal(d.resultado.proposta.total) }],
  ]);

  // Proponentes
  const p = d.pasta;
  const civil = p ? ESTADO_CIVIL[p.estado_civil] ?? p.estado_civil : '';
  const proponente = (n: number, nome: string | null, doc_: string | null, nasc: string | null, prof: string | null, fone: string | null, email: string | null) => {
    b.push({ k: 'secao', t: `Proponente ${n}` });
    campos([
      [{ r: 'Nome', v: nome || branco, span: 2 }, { r: 'CPF', v: cpf(doc_) || branco }],
      [{ r: 'RG / órgão emissor', v: branco }, { r: 'Nascimento', v: nasc ? fmtData(nasc) : branco }, { r: 'Nacionalidade', v: branco }],
      [{ r: 'Estado civil', v: civil ? (simples ? civil : `${civil} · regime ${'_'.repeat(10)}`) : branco }, { r: 'Profissão', v: prof || branco }, { r: 'Celular', v: tel(fone) || branco }],
      [{ r: 'E-mail', v: email || branco }, { r: 'Endereço', v: `${'_'.repeat(38)} · CEP ${'_'.repeat(9)}`, span: 2 }],
    ]);
  };
  const pt = d.partes;
  const nascTxt = (v?: string) => (!v ? branco : /^\d{4}-\d{2}-\d{2}/.test(v) ? fmtData(v.slice(0, 10)) : v);
  const completo = (titulo: string, x: ProponenteCarta) => {
    b.push({ k: 'secao', t: titulo });
    campos([
      [{ r: 'Nome', v: x.nome || branco, span: 2 }, { r: 'CPF', v: cpf((x.cpf ?? '').replace(/\D/g, '')) || branco }],
      [{ r: 'RG / órgão emissor', v: x.rg || branco }, { r: 'Nascimento', v: nascTxt(x.nascimento) }, { r: 'Nacionalidade', v: x.nacionalidade || branco }],
      [{ r: 'Estado civil', v: x.estado_civil ? `${x.estado_civil}${x.regime_bens ? ` · ${x.regime_bens}` : ''}` : branco }, { r: 'Profissão', v: x.profissao || branco }, { r: 'Celular', v: tel((x.telefone ?? '').replace(/\D/g, '')) || x.telefone || branco }],
      [{ r: 'E-mail', v: x.email || branco }, { r: 'Endereço', v: x.endereco ? `${x.endereco}${x.cep ? ` · CEP ${x.cep}` : ''}` : `${'_'.repeat(38)} · CEP ${'_'.repeat(9)}`, span: 2 }],
    ]);
  };
  if (pt) {
    if (pt.empresa) {
      const e = pt.empresa;
      b.push({ k: 'secao', t: 'Proponente (pessoa jurídica)' });
      campos([
        [{ r: 'Razão social', v: e.razao_social || branco, span: 2 }, { r: 'CNPJ', v: cnpj(e.cnpj) || branco }],
        [{ r: 'E-mail', v: e.email || branco }, { r: 'Endereço', v: e.endereco ? `${e.endereco}${e.cep ? ` · CEP ${e.cep}` : ''}` : branco, span: 2 }],
      ]);
      pt.proponentes.forEach((x, i) => completo(pt.proponentes.length > 1 ? `Representante legal ${i + 1}` : 'Representante legal', x));
    } else pt.proponentes.forEach((x, i) => completo(`Proponente ${i + 1}`, x));
  } else if (p || !simples) {
    proponente(1, p?.comprador_nome ?? null, p?.comprador_cpf ?? null, p?.comprador_nascimento ?? null, p?.comprador_profissao ?? null, p?.comprador_telefone ?? null, p?.comprador_email ?? null);
    if (p?.conjuge_nome)
      proponente(2, p.conjuge_nome, p.conjuge_cpf, p.conjuge_nascimento, p.conjuge_profissao, p.conjuge_telefone, p.conjuge_email);
  }

  // Preço e forma de pagamento
  b.push({ k: 'secao', t: 'Preço e forma de pagamento', minimo: 50 });
  const ROTULO: Record<string, string> = { Sinal: 'Sinal', Mensais: 'Mensal', Bimestrais: 'Bimestral', Trimestrais: 'Trimestral', Semestrais: 'Semestral', Anuais: 'Anual', Unica: 'Única', Permuta: 'Permuta', Financiamento: 'Única' };
  const linhaSerie = (s: Serie): RowInput => {
    const ultimo = dataDaParcela(s, s.qtd - 1);
    const venc = s.qtd > 1 ? `${fmtData(s.vencimento)} a ${fmtData(ultimo).slice(3)}` : fmtData(s.vencimento);
    const fin = s.periodicidade === 'Financiamento';
    return [
      ROTULO[s.periodicidade] ?? s.periodicidade, String(s.qtd), venc, fmtReal(s.valor), fmtReal(s.valor * s.qtd),
      s.periodicidade === 'Sinal' ? 'Fixa' : fin || s.periodicidade === 'Permuta' ? '—' : 'INCC até o habite-se',
      s.periodicidade === 'Sinal' ? c.forma_sinal : fin ? 'Financiamento bancário' : s.periodicidade === 'Permuta' ? 'Permuta (ver observações)' : c.forma_parcelas,
    ];
  };
  const ordenar = (l: Serie[]) => [...l].sort((a, z) => a.vencimento.localeCompare(z.vencimento));
  const direto = ordenar(d.series.filter((s) => s.periodicidade !== 'Financiamento'));
  const fin = ordenar(d.series.filter((s) => s.periodicidade === 'Financiamento'));
  const soma = (l: Serie[]) => l.reduce((t, s) => t + s.valor * s.qtd, 0);
  b.push({
    k: 'tabela',
    head: ['Série', 'Parc.', 'Vencimentos', 'Valor da parcela', 'Total da série', 'Correção', 'Pagamento'],
    body: [
      ...direto.map(linhaSerie),
      totalLinha('Total até as chaves', fmtReal(soma(direto)), 7, 4),
      ...fin.map(linhaSerie),
      ...(fin.length ? [totalLinha('Total pós-chaves / financiamento', fmtReal(soma(fin)), 7, 4)] : []),
      totalLinha('Total da proposta nesta data', fmtReal(d.resultado.proposta.total), 7, 4, true),
    ],
    colunas: { 1: { halign: 'right', cellWidth: 11 }, 3: { halign: 'right' }, 4: { halign: 'right' } },
  });

  // Intermediação
  const linhasCom = d.resultado.comissao.linhas.filter((l) => l.comissao > 0);
  if (!simples || linhasCom.length) {
    b.push({ k: 'secao', t: 'Intermediação imobiliária', minimo: 50 });
    b.push({ k: 'texto', t: 'Paga com o sinal de negócio e destacada do valor da proposta.', tam: 8.5, cinza: true });
    const total = d.resultado.proposta.total;
    b.push({
      k: 'tabela',
      head: ['Intermediador', 'Função', '%', 'Valor', 'Vencimento'],
      body: [
        ...linhasCom.map((l): RowInput => [d.imobiliaria || (simples ? 'Venda direta' : branco), 'Imobiliária', total > 0 ? pct(l.comissao / total) : '—', fmtReal(l.comissao), fmtData(l.data)]),
        totalLinha('Total da intermediação', fmtReal(d.resultado.comissao.destacada), 5, 3),
      ],
      colunas: { 2: { halign: 'right' }, 3: { halign: 'right' } },
    });
  }
  campos([[{ r: 'Imobiliária', v: d.imobiliaria || branco }, { r: 'Corretor', v: d.corretor || branco }, { r: 'Coordenação comercial', v: c.coordenacao_comercial || branco }]]);

  // Observações e condições
  if (d.observacoes?.trim()) { b.push({ k: 'secao', t: 'Observações' }); b.push({ k: 'texto', t: d.observacoes.trim() }); }
  const condicoes = c.texto_condicoes.split(/\n+/).map((t) => t.replace(/^\s*\d+\s*[-.)]\s*/, '').trim()).filter(Boolean);
  if (condicoes.length) { b.push({ k: 'secao', t: 'Condições gerais' }); b.push({ k: 'condicoes', itens: condicoes }); }
  const [aa, mm, dd] = (d.dataDocumento || d.dataProposta).split('-').map(Number);
  const local = c.cidade_carta || (simples ? '' : branco);
  b.push({ k: 'texto', t: `${local ? `${local}, ` : ''}${dd} de ${MESES[mm - 1]} de ${aa}.` });

  // Assinaturas (só na carta completa)
  if (!simples) {
    const quem = pt
      ? pt.empresa
        ? [{ nome: pt.empresa.razao_social || 'Proponente', sub: `p.p. ${pt.proponentes.map((x) => x.nome).filter(Boolean).join(' e ')}${pt.empresa.cnpj ? ` · CNPJ ${cnpj(pt.empresa.cnpj)}` : ''}` }]
        : pt.proponentes.map((x) => ({ nome: x.nome || 'Proponente', sub: `Proponente${x.cpf ? ` · CPF ${cpf(x.cpf.replace(/\D/g, ''))}` : ''}` }))
      : [
        { nome: p?.comprador_nome || 'Proponente', sub: `Proponente${p?.comprador_cpf ? ` · CPF ${cpf(p.comprador_cpf)}` : ''}` },
        ...(p?.conjuge_nome ? [{ nome: p.conjuge_nome, sub: `Proponente${p.conjuge_cpf ? ` · CPF ${cpf(p.conjuge_cpf)}` : ''}` }] : []),
      ];
    b.push({ k: 'assinaturas', quem: quem.slice(0, 2), corretor: { nome: d.corretor || 'Corretor', sub: `Corretor${d.imobiliaria ? ` · ${d.imobiliaria}` : ''}` }, vendedora: c.vendedora || 'Vendedora' });
  }
  return b;
}

const cnpj = (s?: string) => { const x = (s ?? '').replace(/\D/g, ''); return x.length === 14 ? x.replace(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '$1.$2.$3/$4-$5') : s ?? ''; };
const totalLinha = (rotulo: string, valor: string, colunas: number, colValor: number, forte = false): RowInput => {
  const fundo: [number, number, number] = forte ? [255, 255, 255] : [244, 244, 240];
  return [
    { content: rotulo, colSpan: colValor, styles: { fontStyle: 'bold', fillColor: fundo } },
    { content: valor, styles: { fontStyle: 'bold', halign: 'right', fillColor: fundo } },
    ...(colunas - colValor - 1 > 0 ? [{ content: '', colSpan: colunas - colValor - 1, styles: { fillColor: fundo } }] : []),
  ];
};
const nomeArquivo = (d: DadosCarta, ext: string, simples = false) => `${simples ? 'resumo' : 'carta'}-proposta-${d.codigo}-unidade-${d.unidade.numero}.${ext}`;

/** Gera a carta proposta em PDF. Por padrão baixa o arquivo; com `{ blob: true }` devolve o arquivo (emissão do contrato). */
export async function gerarCarta(d: DadosCarta, o: OpcoesCarta = {}): Promise<Blob | void> {
  const [{ jsPDF }, { default: autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
  const doc = new jsPDF({ unit: 'mm', format: 'a4' });
  const L = doc.internal.pageSize.getWidth();
  const A = doc.internal.pageSize.getHeight();
  const m = 16;
  const util = L - 2 * m;
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
  const campos = (linhas: Campo[][]) => {
    const col = util / 3;
    for (const linha of linhas) {
      let x = m; let alt = 0;
      const blocos = linha.map((f) => {
        const w = col * (f.span ?? 1) - 3;
        doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5);
        const v = doc.splitTextToSize(f.v || '—', w) as string[];
        alt = Math.max(alt, 4 + v.length * 4.2);
        const bl = { f, v, x };
        x += col * (f.span ?? 1);
        return bl;
      });
      garantir(alt + 2);
      for (const bl of blocos) {
        doc.setFont('helvetica', 'normal'); doc.setFontSize(7); doc.setTextColor(...cinza);
        doc.text(bl.f.r, bl.x, y);
        doc.setFontSize(9.5); doc.setTextColor(20);
        if (bl.v.length === 1 && bl.v[0].endsWith('m²')) {
          // a fonte do PDF não tem "²": escreve o 2 pequeno e elevado
          const base = bl.v[0].slice(0, -1);
          doc.text(base, bl.x, y + 4.3);
          doc.setFontSize(6); doc.text('2', bl.x + doc.getStringUnitWidth(base) * 9.5 / doc.internal.scaleFactor, y + 2.9);
        } else doc.text(bl.v, bl.x, y + 4.3);
      }
      y += alt + 2.5;
    }
  };

  const paragrafo = (t: string, tam = 9, cor: [number, number, number] = [30, 30, 28], negrito = false) => {
    doc.setFont('helvetica', negrito ? 'bold' : 'normal'); doc.setFontSize(tam); doc.setTextColor(...cor);
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

  const posicoes: { pagina: number; x: number; y: number; largura: number; nomes: string[] }[] = [];
  const assinatura = (x: number, w: number, nome: string, sub: string) => {
    doc.setDrawColor(60); doc.setLineWidth(0.25); doc.line(x, y, x + w, y);
    posicoes.push({ pagina: doc.getNumberOfPages(), x: Math.round(x * 10) / 10, y: Math.round(y * 10) / 10, largura: Math.round(w * 10) / 10, nomes: [nome, sub].filter(Boolean) });
    doc.setFont('helvetica', 'bold'); doc.setFontSize(9); doc.setTextColor(20); doc.text(nome, x, y + 4.5);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(7); doc.setTextColor(...cinza); doc.text(sub, x, y + 8);
  };

  // ---------- Cabeçalho ----------
  const logo = d.logoUrl ? await logoPng(d.logoUrl) : null;
  if (logo) { const h = 12; doc.addImage(logo.dados, 'PNG', m, y - 6, (logo.w / logo.h) * h, h); }
  doc.setFont('helvetica', 'bold'); doc.setFontSize(18); doc.setTextColor(20);
  doc.text(o.simples ? 'Resumo da proposta' : 'Carta proposta', L - m, y + 1, { align: 'right' });
  doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(...cinza);
  doc.text(`N.º ${d.codigo} · ${fmtData(d.dataProposta)}`, L - m, y + 6, { align: 'right' });
  y += 16;

  for (const bl of conteudo(d, !!o.simples)) {
    if (bl.k === 'destinatario') {
      doc.setFont('helvetica', 'bold'); doc.setFontSize(9); doc.setTextColor(20);
      const ld = doc.splitTextToSize(bl.t, util) as string[];
      doc.text(ld, m, y + 3);
      y += ld.length * 4.2 + 0.5;
    } else if (bl.k === 'texto') {
      if (bl.t.endsWith('.') && /\d{4}\.$/.test(bl.t) && !bl.cinza) y += 3; // local e data
      paragrafo(bl.t, bl.tam ?? 9, bl.cinza ? cinza : [30, 30, 28]);
    } else if (bl.k === 'secao') secao(bl.t, bl.minimo);
    else if (bl.k === 'campos') campos(bl.linhas);
    else if (bl.k === 'tabela') tabela(bl.head, bl.body, bl.colunas);
    else if (bl.k === 'condicoes') {
      bl.itens.forEach((t, i) => {
        doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(30);
        const l = doc.splitTextToSize(t, util - 5) as string[];
        garantir(l.length * 3.9 + 1.5);
        doc.text(`${i + 1}.`, m, y + 3);
        doc.text(l, m + 5, y + 3);
        y += l.length * 3.9 + 1.5;
      });
    } else if (bl.k === 'assinaturas') {
      const metade = (util - 12) / 2;
      garantir(30); y += 14;
      bl.quem.forEach((q, i) => assinatura(m + i * (metade + 12), metade, q.nome, q.sub));
      y += 12;
      garantir(26); y += 12;
      assinatura(m, metade, bl.corretor.nome, bl.corretor.sub);
      y += 14;
      garantir(36);
      doc.setDrawColor(190); doc.setLineDashPattern([1, 1], 0); doc.line(m, y, L - m, y); doc.setLineDashPattern([], 0);
      y += 7;
      doc.setFont('helvetica', 'bold'); doc.setFontSize(10); doc.setTextColor(20); doc.text('Aceite da vendedora', m, y);
      y += 16;
      assinatura(m, metade, bl.vendedora, 'Data: ____/____/______');
    }
  }

  // rodapé
  const n = doc.getNumberOfPages();
  for (let i = 1; i <= n; i++) {
    doc.setPage(i); doc.setFont('helvetica', 'normal'); doc.setFontSize(7); doc.setTextColor(150);
    doc.text(`${d.empreendimento} · ${d.codigo} · unidade ${d.unidade.numero} · página ${i} de ${n}`, L - m, A - 8, { align: 'right' });
  }
  o.aoAssinaturas?.(posicoes);
  if (o.blob) return doc.output('blob');
  doc.save(nomeArquivo(d, 'pdf', o.simples));
}

/** Carta proposta em Word (.docx), com o mesmo conteúdo do PDF. Com `{ blob: true }` devolve o arquivo. */
export async function gerarCartaWord(d: DadosCarta, o: OpcoesCarta = {}): Promise<Blob | void> {
  const { renderizarWord } = await import('../contrato/gerador');
  const itens: Item[] = [];
  const para = (texto: string, op: Extract<Item, { k: 'p' }>['o'] = {}) => itens.push({ k: 'p', texto, o: op });
  const rotuloValor = (f: Campo) => ({ content: `${f.r}\n${f.v || '—'}`, colSpan: f.span ?? 1 });
  para(o.simples ? 'RESUMO DA PROPOSTA' : 'CARTA PROPOSTA', { negrito: true, centro: true, tam: 13, depois: 1 });
  para(`N.º ${d.codigo} · ${fmtData(d.dataProposta)}`, { centro: true, tam: 8.5, depois: 5 });
  for (const bl of conteudo(d, !!o.simples)) {
    if (bl.k === 'destinatario') para(bl.t, { negrito: true, depois: 1 });
    else if (bl.k === 'texto') para(bl.t, { tam: bl.tam ?? 9, italico: bl.cinza, antes: /\d{4}\.$/.test(bl.t) && !bl.cinza ? 3 : 0 });
    else if (bl.k === 'secao') para(bl.t.toLocaleUpperCase('pt-BR'), { negrito: true, antes: 4, depois: 1.5, secao: true });
    else if (bl.k === 'campos') {
      // cada linha do PDF vira uma linha da tabela, com 3 colunas
      const body = bl.linhas.map((l) => {
        const cel = l.map(rotuloValor);
        const usadas = l.reduce((t, f) => t + (f.span ?? 1), 0);
        return usadas < 3 ? [...cel, { content: '', colSpan: 3 - usadas }] : cel;
      });
      itens.push({ k: 'tabela', o: { body } });
    } else if (bl.k === 'tabela') {
      const cs: Record<number, object> = {};
      for (const [k, v] of Object.entries(bl.colunas)) if ((v as { cellWidth?: number }).cellWidth) cs[Number(k)] = { cellWidth: (v as { cellWidth: number }).cellWidth };
      itens.push({ k: 'tabela', o: { head: [bl.head], body: bl.body, columnStyles: cs } });
    } else if (bl.k === 'condicoes') bl.itens.forEach((t, i) => para(`${i + 1}. ${t}`, { tam: 8.5, recuo: 2, depois: 1.2 }));
    else if (bl.k === 'assinaturas') {
      itens.push({ k: 'assin', nomes: bl.quem.map((q) => [q.nome, q.sub]), colunas: 2 });
      itens.push({ k: 'assin', nomes: [[bl.corretor.nome, bl.corretor.sub]], colunas: 2 });
      para('ACEITE DA VENDEDORA', { negrito: true, antes: 6, secao: true });
      itens.push({ k: 'assin', nomes: [[bl.vendedora, 'Data: ____/____/______']], colunas: 2 });
    }
  }
  const blob = await renderizarWord(itens, `${d.empreendimento} · ${d.codigo} · unidade ${d.unidade.numero}`, o.simples ? 'Resumo da proposta' : 'Carta proposta');
  if (o.blob) return blob;
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = nomeArquivo(d, 'docx', o.simples); a.click();
}
