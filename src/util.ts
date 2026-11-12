import { useEffect, useState } from 'react';
import { supabase } from './dados';

// ---------- Rotas internas do painel (/painel, /painel/pastas, /painel/pastas/<id>, ...) ----------
export function useRota() {
  const [rota, setRota] = useState(window.location.pathname);
  useEffect(() => {
    const aoVoltar = () => setRota(window.location.pathname);
    window.addEventListener('popstate', aoVoltar);
    return () => window.removeEventListener('popstate', aoVoltar);
  }, []);
  return rota.replace(/\/+$/, '') || '/';
}
export function ir(caminho: string) {
  window.history.pushState({}, '', caminho);
  window.dispatchEvent(new PopStateEvent('popstate'));
  window.scrollTo(0, 0);
}

// ---------- Formatação ----------
export const soDigitos = (s: string) => s.replace(/\D/g, '');

export function formatarCPF(s: string | null | undefined) {
  const d = soDigitos(s || '').slice(0, 11);
  return d.replace(/(\d{3})(\d)/, '$1.$2').replace(/(\d{3})(\d)/, '$1.$2').replace(/(\d{3})(\d{1,2})$/, '$1-$2');
}

export function cpfValido(s: string) {
  const d = soDigitos(s);
  if (d.length !== 11 || /^(\d)\1{10}$/.test(d)) return false;
  const dv = (n: number) => {
    let soma = 0;
    for (let i = 0; i < n; i++) soma += Number(d[i]) * (n + 1 - i);
    const r = (soma * 10) % 11;
    return r === 10 ? 0 : r;
  };
  return dv(9) === Number(d[9]) && dv(10) === Number(d[10]);
}

export function formatarTelefone(s: string | null | undefined) {
  const d = soDigitos(s || '').slice(0, 11);
  if (d.length <= 10) return d.replace(/(\d{2})(\d)/, '($1) $2').replace(/(\d{4})(\d{1,4})$/, '$1-$2');
  return d.replace(/(\d{2})(\d)/, '($1) $2').replace(/(\d{5})(\d{1,4})$/, '$1-$2');
}

export const formatarData = (iso: string | null | undefined) =>
  iso ? new Date(iso.length === 10 ? iso + 'T12:00:00' : iso).toLocaleDateString('pt-BR') : '—';

export const formatarTamanho = (b: number | null | undefined) =>
  b == null ? '' : b < 1024 * 1024 ? `${Math.max(1, Math.round(b / 1024))} KB` : `${(b / 1024 / 1024).toFixed(1).replace('.', ',')} MB`;

// ---------- Domínio das pastas ----------
export type EstadoCivil = 'solteiro' | 'casado' | 'uniao_estavel' | 'divorciado' | 'viuvo';
export const ESTADOS_CIVIS: { valor: EstadoCivil; rotulo: string }[] = [
  { valor: 'solteiro', rotulo: 'Solteiro(a)' },
  { valor: 'casado', rotulo: 'Casado(a)' },
  { valor: 'uniao_estavel', rotulo: 'União estável' },
  { valor: 'divorciado', rotulo: 'Divorciado(a)' },
  { valor: 'viuvo', rotulo: 'Viúvo(a)' },
];
export const temConjuge = (e: EstadoCivil) => e === 'casado' || e === 'uniao_estavel';

export type StatusPasta = 'incompleta' | 'pronta' | 'aguardando_analise' | 'em_analise' | 'pendente_correcao' | 'aprovada';
export const STATUS_PASTA: { valor: StatusPasta; rotulo: string }[] = [
  { valor: 'incompleta', rotulo: 'Incompleta' },
  { valor: 'pronta', rotulo: 'Pronta para submeter' },
  { valor: 'aguardando_analise', rotulo: 'Aguardando análise' },
  { valor: 'em_analise', rotulo: 'Em análise' },
  { valor: 'pendente_correcao', rotulo: 'Pendente de correção' },
  { valor: 'aprovada', rotulo: 'Documentação aprovada' },
];
export const rotuloPasta = (s: StatusPasta) => STATUS_PASTA.find((x) => x.valor === s)?.rotulo ?? s;

export type StatusDocumento = 'enviado' | 'em_analise' | 'aprovado' | 'recusado';
export const ROTULO_DOC: Record<StatusDocumento | 'pendente', string> = {
  pendente: 'Pendente', enviado: 'Enviado', em_analise: 'Em análise', aprovado: 'Aprovado', recusado: 'Recusado',
};

export interface Perfil {
  user_id: string;
  email: string;
  nome: string | null;
  papel: 'admin' | 'vendas' | 'imobiliaria' | 'corretor';
  imobiliaria_id: string | null;
  trocar_senha: boolean;
}

/** Chama o servidor (/api) com o login atual. */
export async function chamarApi(caminho: string, corpo: unknown): Promise<{ ok?: boolean; erro?: string }> {
  const { data } = await supabase.auth.getSession();
  try {
    const r = await fetch(caminho, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${data.session?.access_token ?? ''}` },
      body: JSON.stringify(corpo),
    });
    return await r.json();
  } catch {
    return { erro: 'Sem conexão com o servidor. Verifique a internet.' };
  }
}

export function gerarSenha() {
  const letras = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';
  const v = new Uint32Array(10);
  crypto.getRandomValues(v);
  return Array.from(v, (n) => letras[n % letras.length]).join('');
}
