// Leitura dos documentos da pasta com IA (Claude), para preencher os dados do contrato.
// O navegador da equipe baixa os documentos, reduz as fotos e monta o pedido; o servidor
// (/api/contrato/ler) confere o login e repassa à IA com a chave secreta.
import { supabase } from '../dados';
import { cpfValido, soDigitos, chamarApi, REGIMES } from '../util';

export const MODELO_IA = 'claude-sonnet-5-5';

export const CAMPOS_PESSOA = [
  ['nome', 'Nome completo'], ['nacionalidade', 'Nacionalidade'], ['naturalidade', 'Naturalidade'],
  ['profissao', 'Profissão'], ['estado_civil', 'Estado civil'], ['regime_bens', 'Regime de bens'],
  ['rg', 'RG'], ['rg_orgao', 'Órgão expedidor'], ['rg_uf', 'UF do RG'], ['cpf', 'CPF'], ['nascimento', 'Data de nascimento'],
  ['email', 'E-mail'], ['telefone', 'Telefone'],
] as const;
export const CAMPOS_ENDERECO = [
  ['logradouro', 'Rua / avenida'], ['numero', 'Número'], ['complemento', 'Complemento'], ['bairro', 'Bairro'],
  ['cidade', 'Cidade'], ['uf', 'UF'], ['cep', 'CEP'],
] as const;

export type Pessoa = Partial<Record<(typeof CAMPOS_PESSOA)[number][0], string>> & { endereco?: Partial<Record<(typeof CAMPOS_ENDERECO)[number][0], string>> };
export interface DadosContrato { comprador?: Pessoa; conjuge?: Pessoa }
export interface Alerta { nivel: 'atencao' | 'info'; texto: string }

interface DocInfo { id: string; caminho: string; arquivo: string; mime: string | null; tipo: string; pessoa: string }
interface Contexto {
  pasta: { codigo: string; estado_civil: string; regime_bens: string | null; conjuge_no_contrato: boolean; comprador: Record<string, string | null>; conjuge: Record<string, string | null> };
  documentos: DocInfo[];
}

const LADO_MAX = 1800;          // px: suficiente para ler documentos
const PDF_MAX = 12 * 1024 * 1024;

const paraBase64 = (buf: ArrayBuffer) => {
  let s = ''; const b = new Uint8Array(buf);
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
  return btoa(s);
};

async function reduzirFoto(blob: Blob): Promise<Blob | null> {
  const bmp = await createImageBitmap(blob, { imageOrientation: 'from-image' }).catch(() => null);
  if (!bmp) return null;
  const esc = Math.min(1, LADO_MAX / Math.max(bmp.width, bmp.height));
  const c = document.createElement('canvas');
  c.width = Math.round(bmp.width * esc); c.height = Math.round(bmp.height * esc);
  c.getContext('2d')!.drawImage(bmp, 0, 0, c.width, c.height);
  bmp.close();
  const out = await new Promise<Blob | null>((ok) => c.toBlob(ok, 'image/jpeg', 0.88));
  c.width = 0; c.height = 0;
  return out;
}

const pessoaSchema = {
  type: 'object',
  properties: {
    ...Object.fromEntries(CAMPOS_PESSOA.map(([k]) => [k, { type: 'string' }])),
    endereco: { type: 'object', properties: Object.fromEntries(CAMPOS_ENDERECO.map(([k]) => [k, { type: 'string' }])) },
  },
};
const FERRAMENTA = {
  name: 'registrar_dados',
  description: 'Registra os dados extraídos dos documentos para o contrato de compra e venda.',
  input_schema: {
    type: 'object',
    required: ['comprador', 'fontes', 'alertas'],
    properties: {
      comprador: pessoaSchema,
      conjuge: pessoaSchema,
      fontes: { type: 'object', description: 'Para cada campo preenchido, o código do documento de onde veio (ex.: {"comprador.rg": "D1", "comprador.endereco.cep": "D2"}).', additionalProperties: { type: 'string' } },
      alertas: {
        type: 'array',
        items: { type: 'object', required: ['nivel', 'texto'], properties: { nivel: { type: 'string', enum: ['atencao', 'info'] }, texto: { type: 'string' } } },
      },
    },
  },
};

function instrucoes(hoje: string) {
  return `Você é assistente da equipe de vendas de uma incorporadora no Brasil. Leia os documentos pessoais do comprador (e do cônjuge, se houver) e extraia os dados para o contrato.

Regras:
- Use SOMENTE o que estiver escrito e legível nos documentos. Nunca invente nem deduza. Se não encontrar, deixe o campo vazio ("").
- Datas no formato AAAA-MM-DD. CPF e CEP só com números. UF com 2 letras maiúsculas.
- Naturalidade = cidade/UF de nascimento (ex.: "Rio Verde/GO"), normalmente no RG ou na certidão.
- Nacionalidade: escreva por extenso (ex.: "brasileira"). Só preencha se o documento permitir concluir.
- Estado civil e regime de bens: da certidão de casamento, quando houver. Se o regime da certidão for diferente do informado na pasta, gere um alerta.
- Se a pasta disser que o cônjuge NÃO participa do contrato, não preencha "conjuge".
- Endereço: do comprovante de endereço.
- Em "fontes", indique de qual documento (D1, D2...) veio cada campo preenchido.
- Em "alertas" (nivel "atencao"), aponte em português simples:
  * CPF, nome ou data de nascimento diferentes do que foi digitado na pasta;
  * nome escrito de forma diferente entre os documentos;
  * comprovante de endereço com data de emissão anterior a 90 dias da data de hoje (${hoje});
  * documento ilegível, cortado, sem o verso, vencido ou que parece ser de outra pessoa;
  * documento que não corresponde ao tipo informado.
- Use nivel "info" para observações úteis que não são problema.
Responda chamando a ferramenta registrar_dados.`;
}

// ---------- Padronização: primeira letra de cada palavra maiúscula ----------
const LIGACOES = new Set(['de', 'da', 'do', 'das', 'dos', 'e', 'em', 'na', 'no', 'nas', 'nos', 'a', 'o', 'à', 'ao', 'aos']);
export function capitalizar(t: string): string {
  return t.trim().replace(/\s+/g, ' ').replace(/[\p{L}\p{N}]+/gu, (w, pos: number) => {
    if (/^\p{Lu}{1,2}$/u.test(w) || /\d/.test(w)) return w;            // siglas curtas (GO, SN) e números ficam como estão
    const m = w.toLocaleLowerCase('pt-BR');
    if (pos > 0 && LIGACOES.has(m)) return m;
    return m.charAt(0).toLocaleUpperCase('pt-BR') + m.slice(1);
  });
}
const CAPITALIZAR = ['nome', 'nacionalidade', 'naturalidade', 'profissao', 'estado_civil', 'regime_bens'] as const;
const CAPITALIZAR_END = ['logradouro', 'complemento', 'bairro', 'cidade'] as const;
const MAIUSCULAS = ['rg_orgao', 'rg_uf'] as const;
export function padronizar(d: DadosContrato): DadosContrato {
  const um = (p?: Pessoa): Pessoa | undefined => {
    if (!p) return p;
    const n: Pessoa = { ...p, endereco: p.endereco ? { ...p.endereco } : undefined };
    for (const k of CAPITALIZAR) if (n[k]) n[k] = capitalizar(n[k]!);
    for (const k of MAIUSCULAS) if (n[k]) n[k] = n[k]!.trim().toUpperCase();
    if (n.endereco) {
      for (const k of CAPITALIZAR_END) if (n.endereco[k]) n.endereco[k] = capitalizar(n.endereco[k]!);
      if (n.endereco.uf) n.endereco.uf = n.endereco.uf.trim().toUpperCase();
    }
    return n;
  };
  return { ...d, comprador: um(d.comprador), conjuge: um(d.conjuge) };
}

export interface ResultadoLeitura { dados: DadosContrato; fontes: Record<string, string>; alertas: Alerta[]; lidos: number; ignorados: string[]; tokensEntrada: number; tokensSaida: number }

/** Baixa, prepara e envia os documentos à IA. `progresso` recebe mensagens para a tela. */
export async function lerDocumentosComIA(pastaId: string, progresso: (t: string) => void): Promise<ResultadoLeitura> {
  const { data, error } = await supabase.rpc('documentos_para_leitura', { p_pasta: pastaId });
  if (error) throw new Error(error.message === 'PROPOSTA_NAO_APROVADA' ? 'A leitura só fica disponível depois da proposta aprovada.' : 'Você não tem acesso a esta leitura.');
  const ctx = data as Contexto;
  if (!ctx.documentos.length) throw new Error('Esta pasta não tem documentos para ler.');

  const hoje = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Sao_Paulo' });
  const rotuloRegime = REGIMES.find((x) => x.valor === ctx.pasta.regime_bens)?.rotulo ?? '';
  const temConj = ctx.pasta.conjuge_no_contrato !== false && ['casado', 'uniao_estavel'].includes(ctx.pasta.estado_civil);
  const conteudo: unknown[] = [{
    type: 'text',
    text: `Pasta ${ctx.pasta.codigo}. Estado civil informado: ${ctx.pasta.estado_civil}.${ctx.pasta.regime_bens ? ` Regime de bens informado: ${rotuloRegime}.` : ''}${temConj ? '' : ' O cônjuge NÃO participa do contrato.'}\nDados digitados na pasta (para comparar):\n${JSON.stringify({ comprador: ctx.pasta.comprador, conjuge: ctx.pasta.conjuge })}\n\nDocumentos a seguir:`,
  }];
  const ignorados: string[] = [];
  const nomes: Record<string, string> = {};
  let lidos = 0;
  for (let i = 0; i < ctx.documentos.length; i++) {
    const d = ctx.documentos[i];
    const codigo = `D${i + 1}`;
    if (/pix/i.test(d.tipo)) continue;   // comprovante de pagamento não entra no contrato
    nomes[codigo] = d.tipo;
    progresso(`Preparando ${i + 1} de ${ctx.documentos.length}: ${d.tipo}…`);
    // mesmo caminho do botão "abrir": o servidor confere a permissão e registra a visualização
    const link = await chamarApi('/api/documentos/link', { documento_id: d.id });
    if (!link.url) { ignorados.push(`${d.tipo} (${d.arquivo}): ${link.erro || 'não foi possível baixar'}`); continue; }
    const blob = await fetch(link.url).then((r) => (r.ok ? r.blob() : null)).catch(() => null);
    if (!blob) { ignorados.push(`${d.tipo} (${d.arquivo}): não foi possível baixar`); continue; }
    const ehPdf = (d.mime || blob.type) === 'application/pdf' || /\.pdf$/i.test(d.arquivo);
    let bloco: unknown;
    if (ehPdf) {
      if (blob.size > PDF_MAX) { ignorados.push(`${d.tipo} (${d.arquivo}): PDF maior que 12 MB`); continue; }
      bloco = { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: paraBase64(await blob.arrayBuffer()) } };
    } else {
      const foto = await reduzirFoto(blob);
      if (!foto) { ignorados.push(`${d.tipo} (${d.arquivo}): formato que o navegador não abre (ex.: HEIC). Peça em JPG ou PDF.`); continue; }
      bloco = { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: paraBase64(await foto.arrayBuffer()) } };
    }
    const dono = d.pessoa === 'conjuge' ? 'cônjuge' : d.pessoa === 'comprador' ? 'comprador' : 'geral';
    conteudo.push({ type: 'text', text: `${codigo}: ${d.tipo} (${dono}), arquivo "${d.arquivo}"` }, bloco);
    lidos++;
  }
  if (!lidos) throw new Error('Nenhum documento pôde ser preparado para leitura. ' + ignorados.join(' '));

  progresso(`Lendo ${lidos} documento(s) com IA… (pode levar até 1 minuto)`);
  const corpo = JSON.stringify({
    model: MODELO_IA, max_tokens: 4000, system: instrucoes(hoje),
    tools: [FERRAMENTA], tool_choice: { type: 'auto' },
    messages: [{ role: 'user', content: [...conteudo, { type: 'text', text: `Responda chamando a ferramenta ${FERRAMENTA.name}, uma única vez, sem texto antes.` }] }],
  });
  const { data: sessao } = await supabase.auth.getSession();
  const resp = await fetch(`/api/contrato/ler?pasta=${encodeURIComponent(pastaId)}`, {
    method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${sessao.session?.access_token ?? ''}` }, body: corpo,
  });
  const r = await resp.json().catch(() => null);
  if (!resp.ok || !r) {
    const m = r?.erro || r?.error?.message || `erro ${resp.status}`;
    throw new Error(/credit|balance/i.test(m) ? 'Os créditos da IA acabaram. Recarregue em platform.claude.com.' : `A IA não respondeu: ${m}`);
  }
  let uso = r.content?.find((c: { type: string }) => c.type === 'tool_use')?.input;
  if (!uso) {   // se a IA respondeu em texto, tenta achar o JSON nele
    const txt = (r.content ?? []).filter((c: { type: string }) => c.type === 'text').map((c: { text: string }) => c.text).join('\n');
    const m = txt.match(/\{[\s\S]*\}/);
    try { uso = m ? JSON.parse(m[0]) : null; } catch { uso = null; }
  }
  if (!uso) throw new Error('A IA não devolveu os dados. Tente de novo.');

  const dados: DadosContrato = { comprador: uso.comprador ?? {}, conjuge: temConj ? uso.conjuge ?? undefined : undefined };
  if (rotuloRegime) for (const q of ['comprador', 'conjuge'] as const) { const p = dados[q]; if (p && !p.regime_bens) p.regime_bens = rotuloRegime; }
  const alertas: Alerta[] = Array.isArray(uso.alertas) ? uso.alertas : [];
  // completa com o que já está na pasta (e-mail, telefone, profissão) quando a IA não achou
  for (const quem of ['comprador', 'conjuge'] as const) {
    const base = ctx.pasta[quem];
    if (quem === 'conjuge' && (!temConj || !base?.nome)) continue;
    const p: Pessoa = (dados[quem] ??= {});
    for (const k of ['email', 'telefone', 'profissao'] as const) if (!p[k] && base?.[k]) p[k] = String(base[k]);
    // conferências que não dependem da IA
    if (p.cpf && !cpfValido(p.cpf)) alertas.push({ nivel: 'atencao', texto: `CPF lido do ${quem === 'conjuge' ? 'cônjuge' : 'comprador'} (${p.cpf}) não é válido. Confira no documento.` });
    if (p.cpf && base?.cpf && soDigitos(p.cpf) !== soDigitos(String(base.cpf)))
      alertas.push({ nivel: 'atencao', texto: `CPF do ${quem === 'conjuge' ? 'cônjuge' : 'comprador'} no documento é diferente do digitado na pasta.` });
  }
  ignorados.forEach((t) => alertas.push({ nivel: 'atencao', texto: `Não lido: ${t}` }));
  // troca D1, D2… pelo nome do documento, para a equipe saber de onde veio
  const fontes: Record<string, string> = {};
  for (const [campo, cod] of Object.entries((uso.fontes ?? {}) as Record<string, string>)) fontes[campo] = nomes[cod] ?? cod;
  return { dados: padronizar(dados), fontes, alertas, lidos, ignorados, tokensEntrada: r.usage?.input_tokens ?? 0, tokensSaida: r.usage?.output_tokens ?? 0 };
}
