// Versões leves das imagens do Portal do Corretor, geradas no navegador.
// A original nunca é alterada: as versões ficam ao lado dela no armazenamento,
// com o mesmo nome e um final diferente (".mini.webp" e ".media.webp").
import { supabase } from './dados';

export const VERSOES = { mini: { lado: 480, qualidade: 0.78 }, media: { lado: 1600, qualidade: 0.82 } } as const;
export type Versao = keyof typeof VERSOES;
export const caminhoVersao = (caminho: string, v: Versao) => `${caminho}.${v}.webp`;

const LEGIVEIS = /^image\/(jpeg|png|webp|gif|bmp|avif)$/;
export const podeOtimizar = (tipo: string | null | undefined) => !!tipo && LEGIVEIS.test(tipo);

async function reduzir(bmp: ImageBitmap, lado: number, qualidade: number): Promise<Blob | null> {
  const escala = Math.min(1, lado / Math.max(bmp.width, bmp.height));
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.round(bmp.width * escala));
  c.height = Math.max(1, Math.round(bmp.height * escala));
  const ctx = c.getContext('2d');
  if (!ctx) return null;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(bmp, 0, 0, c.width, c.height);
  let blob = await new Promise<Blob | null>((ok) => c.toBlob(ok, 'image/webp', qualidade));
  // navegador sem WebP devolve PNG: usa JPG, que é bem menor
  if (!blob || blob.type !== 'image/webp') blob = await new Promise<Blob | null>((ok) => c.toBlob(ok, 'image/jpeg', qualidade));
  c.width = 0; c.height = 0;   // libera a memória do canvas (importante no celular)
  return blob;
}

/** Gera miniatura e versão média. Devolve null se o navegador não conseguir ler a imagem. */
export async function gerarVersoes(arquivo: Blob): Promise<Record<Versao, Blob> | null> {
  const bmp = await createImageBitmap(arquivo, { imageOrientation: 'from-image' }).catch(() => null);
  if (!bmp) return null;
  try {
    const media = await reduzir(bmp, VERSOES.media.lado, VERSOES.media.qualidade);
    const mini = await reduzir(bmp, VERSOES.mini.lado, VERSOES.mini.qualidade);
    return media && mini ? { media, mini } : null;
  } finally {
    bmp.close();
  }
}

/** Gera e envia as versões de uma imagem já guardada. Falhar aqui nunca impede o uso da original. */
export async function enviarVersoes(caminho: string, arquivo: Blob): Promise<boolean> {
  const v = await gerarVersoes(arquivo);
  if (!v) return false;
  for (const k of ['mini', 'media'] as Versao[]) {
    const { error } = await supabase.storage.from('portal').upload(caminhoVersao(caminho, k), v[k], { contentType: v[k].type, upsert: false });
    // "já existe" conta como pronto
    if (error && !/exist|duplicate/i.test(error.message)) return false;
  }
  return true;
}

// ---------------------------------------------------------------------
// Links temporários reaproveitados: o navegador guarda a imagem em cache
// em vez de baixar de novo a cada visita.
// ---------------------------------------------------------------------
const CHAVE = 'portal-links-v1';
const VALIDADE = 24 * 3600;           // segundos
const SOBRA = 2 * 3600 * 1000;        // reusa enquanto faltar mais de 2 h para vencer
type Guardados = Record<string, { url: string; vence: number }>;
const ler = (): Guardados => { try { return JSON.parse(localStorage.getItem(CHAVE) || '{}'); } catch { return {}; } };
const gravar = (g: Guardados) => {
  const agora = Date.now();
  for (const k of Object.keys(g)) if (g[k].vence - SOBRA < agora) delete g[k];
  try { localStorage.setItem(CHAVE, JSON.stringify(g)); } catch { /* armazenamento cheio ou bloqueado */ }
};

/** Links para vários caminhos; o que não existir volta sem link. */
export async function linksGuardados(caminhos: string[]): Promise<Record<string, string>> {
  const g = ler();
  const agora = Date.now();
  const res: Record<string, string> = {};
  const faltam = caminhos.filter((c) => { const x = g[c]; if (x && x.vence - SOBRA > agora) { res[c] = x.url; return false; } return true; });
  if (faltam.length) {
    const { data } = await supabase.storage.from('portal').createSignedUrls(faltam, VALIDADE);
    (data ?? []).forEach((d, k) => {
      if (d.signedUrl && !d.error) { res[faltam[k]] = d.signedUrl; g[faltam[k]] = { url: d.signedUrl, vence: agora + VALIDADE * 1000 }; }
    });
    gravar(g);
  }
  return res;
}

/** Esquece os links de caminhos removidos ou recriados. */
export function esquecerLinks(caminhos: string[]) {
  const g = ler();
  caminhos.forEach((c) => delete g[c]);
  gravar(g);
}
